#!/usr/bin/env bash
# usage-monitor.sh — Claude Code usage-limit monitor (macOS).
#
# Watches the session (5h) and weekly usage limits of your Claude
# subscription and notifies you when a limit is close to exhaustion and
# when a window resets.
#
# Modes:
#   hook   — called from Claude Code hooks (Stop / SessionStart); prints
#            {"systemMessage": "..."} JSON only when there is news
#   cron   — called from launchd every N minutes; sends macOS notifications
#   status — human-readable snapshot of all limits
#   limits — machine-readable snapshot: one "kind|percent|resets_at|scope"
#            line per limit, no header, no localization (pair with
#            UM_CACHE_TTL=0 to bypass the cache)
#
# Notifications are sent once per threshold per window (no spam):
#   WARN  (default 80%)  🟡
#   CRIT  (default 95%)  🔴
#   reset ♻️  — when a window rolls over and usage was >= RESET_MIN (50%)
#
# Environment overrides:
#   UM_WARN=80  UM_CRIT=95  UM_RESET_MIN=50  UM_CACHE_TTL=60  UM_LANG=ru|en

set -u

MODE="${1:-status}"

# refresh_via_cli below runs `claude -p /usage`, a full headless session that
# fires this plugin's own hooks. They must not run there: each would make one
# more request to the usage endpoint (exactly when it is already failing, or
# rate limiting us), and the Stop hooks would banner a session nobody sees.
[ "${UM_INTERNAL:-}" = "1" ] && exit 0
WARN="${UM_WARN:-80}"
CRIT="${UM_CRIT:-95}"
RESET_MIN="${UM_RESET_MIN:-50}"
CACHE_TTL="${UM_CACHE_TTL:-60}"
LANG_UM="${UM_LANG:-ru}"

# Plugin userConfig bridge. An explicit UM_* environment variable always wins;
# the plugin option is only a fallback. Measured: a userConfig default is never
# materialised, so an unset CLAUDE_PLUGIN_OPTION_* is the normal case and the
# script's own default has to carry it. These lines sit AFTER the assignments
# above on purpose — install.sh rewrites those literals with sed.
# CLAUDE_PLUGIN_OPTION_* are generic names that, like CLAUDE_PLUGIN_DATA,
# leak from whichever plugin owns the running hook. They are honoured only
# when this very file is the copy inside the limit-alerts plugin, so another
# plugin's LANG/WARN/... can never reconfigure (or switch off) a classic
# install. A leaked CLAUDE_PLUGIN_ROOT points at that other plugin and does not
# match.
FROM_PLUGIN=0
case "${BASH_SOURCE[0]}" in "${CLAUDE_PLUGIN_ROOT:-/nonexistent}"/*) FROM_PLUGIN=1 ;; esac
if [ "$FROM_PLUGIN" = "1" ]; then
  [ -n "${CLAUDE_PLUGIN_OPTION_LANG:-}" ] && LANG_UM="${UM_LANG:-$CLAUDE_PLUGIN_OPTION_LANG}"
  [ -n "${CLAUDE_PLUGIN_OPTION_WARN:-}" ] && WARN="${UM_WARN:-$CLAUDE_PLUGIN_OPTION_WARN}"
  [ -n "${CLAUDE_PLUGIN_OPTION_CRIT:-}" ] && CRIT="${UM_CRIT:-$CLAUDE_PLUGIN_OPTION_CRIT}"
fi

# Resolution order: an explicit override, then the directory install.sh
# creates. In plugin mode hooks.json and the generated wrappers always pass
# UM_STATE_DIR, so CLAUDE_PLUGIN_DATA is deliberately NOT consulted here: that
# variable is exported by whichever plugin owns the current hook, so a classic
# install running inside a session that has any other plugin enabled would
# silently relocate its state into that plugin's data directory.
DIR="${UM_STATE_DIR:-$HOME/.claude/scripts}"
mkdir -p "$DIR" 2>/dev/null || true
STATE="$DIR/usage-monitor-state.json"
CACHE="$DIR/usage-monitor-cache.json"

JQ="$(command -v jq || echo /opt/homebrew/bin/jq)"
[ -x "$JQ" ] || exit 0

LOG="$DIR/usage-monitor.log"
LOG_MAX_BYTES=$((1024 * 1024)) # 1MB
LOG_KEEP_LINES=2000

# Caps unbounded growth from a long-running cron job — keeps only the most
# recent lines once the log crosses LOG_MAX_BYTES, instead of never shrinking.
rotate_log_if_needed() {
  [ -f "$LOG" ] || return 0
  local size
  size=$(stat -f %z "$LOG" 2>/dev/null || echo 0)
  [ "$size" -gt "$LOG_MAX_BYTES" ] || return 0
  tail -n "$LOG_KEEP_LINES" "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
}
rotate_log_if_needed

log_note() {
  case "$MODE" in status|limits) return 0 ;; esac
  echo "$(date '+%F %T') [$MODE] $1" >> "$LOG"
}
log_fetch_fail() { log_note "fetch failed: $1"; } # silent fetch failures used to leave no trace at all

# Backoff after HTTP 429. Without it every hook (past the 60 s cache) and every
# cron tick asks again, which keeps the rate limit alive. The pause follows
# Retry-After when the server sends a number of seconds, and otherwise doubles
# from 5 minutes, capped at an hour. A successful fetch clears it.
BACKOFF="$DIR/usage-monitor-backoff.json"
BACKOFF_FIRST=300
BACKOFF_MAX=3600

backoff_until() { # prints the epoch the backoff ends at, 0 when none
  "$JQ" -r '.until // 0' "$BACKOFF" 2>/dev/null || echo 0
}

backoff_active() {
  [ -f "$BACKOFF" ] || return 1
  [ "$(date +%s)" -lt "$(backoff_until)" ]
}

backoff_start() { # $1 = Retry-After value from the response, may be empty
  local prev delay
  prev=$("$JQ" -r '.delay // 0' "$BACKOFF" 2>/dev/null || echo 0)
  case "$1" in
    ''|*[!0-9]*)  # absent, or an HTTP-date: fall back to doubling
      if [ "$prev" -gt 0 ] 2>/dev/null; then delay=$(( prev * 2 )); else delay=$BACKOFF_FIRST; fi ;;
    *) delay="$1" ;;
  esac
  [ "$delay" -lt 60 ] && delay=60
  [ "$delay" -gt "$BACKOFF_MAX" ] && delay=$BACKOFF_MAX
  "$JQ" -n --argjson u "$(( $(date +%s) + delay ))" --argjson d "$delay" \
    '{until: $u, delay: $d}' > "$BACKOFF" 2>/dev/null || true
  echo "$delay"
}

backoff_clear() { rm -f "$BACKOFF"; }

# Portable timeout: macOS ships neither `timeout` nor `gtimeout` by default,
# but /usr/bin/perl is always present. alarm() fires in the perl process and
# its default disposition (terminate) survives exec into the real command.
run_with_timeout() { # $1 = seconds, rest = command + args
  local secs="$1"; shift
  perl -e 'alarm shift @ARGV; exec @ARGV' "$secs" "$@"
}

# launchd runs the cron job with a bare PATH (/usr/bin:/bin:/usr/sbin:/sbin)
# — no user profile, so `command -v claude` alone misses installs under
# ~/.local/bin or Homebrew, which is exactly where it silently failed
# ("refresh unavailable or failed" on every cron tick, confirmed via
# usage-monitor.log). Same fallback pattern already used for jq above.
resolve_claude_bin() {
  command -v claude 2>/dev/null && return 0
  local candidate
  for candidate in "$HOME/.local/bin/claude" /opt/homebrew/bin/claude /usr/local/bin/claude; do
    [ -x "$candidate" ] && { echo "$candidate"; return 0; }
  done
  return 1
}

# Force-refreshes ~/.claude.json's cachedUsageUtilization by running the
# /usage slash command headlessly. Slash commands are handled locally by the
# CLI (0 tokens, no model call, ~0.5s) and -p skips the workspace-trust
# prompt, so this is safe to run unattended — its .utilization shape matches
# what the fallback below already parses. It's supposed to update
# cachedUsageUtilization.fetchedAtMs to "now", but during an outage (seen
# with a Team subscription blocked for non-payment for a week) the CLI can
# exit 0 without actually refreshing anything — it just serves its own stale
# cache — so this compares fetchedAtMs before/after instead of trusting the
# exit code, otherwise every cron tick logs a false "refreshed" while the
# cache silently stays days old. The headless session fires its own
# Stop/SessionStart hooks; UM_INTERNAL=1 makes every hook of this project
# exit at once there, so the refresh never turns into another request to the
# usage endpoint. Only call this from cron/status: calling it from hook mode
# would add ~0.5s to every real Claude Code turn.
refresh_via_cli() {
  local claude_bin
  claude_bin=$(resolve_claude_bin) || { log_note "'claude -p /usage' refresh unavailable: claude binary not found"; return 1; }
  local claude_json="$HOME/.claude.json"
  local before after
  before=$("$JQ" -r '.cachedUsageUtilization.fetchedAtMs // 0' "$claude_json" 2>/dev/null || echo 0)
  if ! ( cd "$HOME" && UM_INTERNAL=1 run_with_timeout 15 "$claude_bin" -p "/usage" --output-format json ) >/dev/null 2>&1; then
    log_note "'claude -p /usage' refresh failed to run (timeout or error)"
    return 1
  fi
  after=$("$JQ" -r '.cachedUsageUtilization.fetchedAtMs // 0' "$claude_json" 2>/dev/null || echo 0)
  if [ "$after" = "$before" ]; then
    if [ "$after" = "0" ]; then
      log_note "'claude -p /usage' ran but ~/.claude.json still has no cachedUsageUtilization"
    else
      local age=$(( $(date +%s) - after / 1000 ))
      log_note "'claude -p /usage' ran but did not refresh cachedUsageUtilization (still ${age}s old)"
    fi
    return 1
  fi
  log_note "refreshed local usage cache via 'claude -p /usage'"
}

fetch_usage() {
  # cache keeps the Stop hook from hitting the API on every turn
  if [ -f "$CACHE" ]; then
    local age=$(( $(date +%s) - $(stat -f %m "$CACHE" 2>/dev/null || echo 0) ))
    if [ "$age" -lt "$CACHE_TTL" ] && [ "$MODE" != "cron" ]; then
      cat "$CACHE"
      return 0
    fi
  fi
  local token
  token=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null \
    | "$JQ" -r '.claudeAiOauth.accessToken // empty')
  local resp http_code headers retry_after delay
  if backoff_active; then
    # Rate limited a moment ago: no live request and no CLI refresh (it asks
    # the same endpoint). Only the local fallback below, which costs nothing.
    [ "$MODE" = "cron" ] && log_fetch_fail "rate limited, live requests paused until $(date -r "$(backoff_until)" '+%H:%M')"
  elif [ -n "$token" ]; then
    headers=$(mktemp "$DIR/.usage-headers.XXXXXX" 2>/dev/null) || headers=/dev/null
    resp=$(curl -sS --max-time 10 -D "$headers" -w '\n%{http_code}' https://api.anthropic.com/api/oauth/usage \
      -H "Authorization: Bearer $token" \
      -H "anthropic-beta: oauth-2025-04-20" 2>/dev/null)
    http_code="${resp##*$'\n'}"
    resp="${resp%$'\n'*}"
    retry_after=$(awk -F': *' 'tolower($1) == "retry-after" { gsub(/\r/, "", $2); print $2 }' "$headers" 2>/dev/null | tail -1)
    [ "$headers" != /dev/null ] && rm -f "$headers"
    if [ "$http_code" = "200" ] && echo "$resp" | "$JQ" -e '.limits' >/dev/null 2>&1; then
      backoff_clear
      echo "$resp" > "$CACHE"
      echo "$resp"
      return 0
    fi
    # The reason matters for diagnosis: 401/403 point at the token, 429 only
    # means too many requests in a short window (hooks, cron and `status`
    # together can get there) and clears up on its own.
    case "$http_code" in
      401|403) log_fetch_fail "live endpoint returned HTTP $http_code (token likely expired/invalid — refreshes only while Claude Code is active)" ;;
      429)     delay=$(backoff_start "$retry_after")
               log_fetch_fail "live endpoint returned HTTP 429 (rate limited — pausing live requests for $(( delay / 60 )) min${retry_after:+, Retry-After: $retry_after})" ;;
      *)       log_fetch_fail "live endpoint returned HTTP ${http_code:-?}" ;;
    esac
  else
    log_fetch_fail "no OAuth token in keychain"
  fi
  # Team/organization OAuth tokens get a 403 from the live endpoint (seen
  # with subscriptionType "team" — a client-fingerprint gate on Anthropic's
  # side, not something fixable with headers/tokens from a plain script). A
  # personal token can also 401 here if it expired while Claude Code wasn't
  # running to refresh it. Either way, try to force a fresh local read via
  # the CLI itself before falling back to whatever's already cached — only
  # from cron/status, never from hook (see refresh_via_cli comment).
  if { [ "$MODE" = "cron" ] || [ "$MODE" = "status" ]; } && ! backoff_active; then
    refresh_via_cli
  fi
  # Fall back to the same data Claude Code's own /usage command already
  # cached locally. Same response shape (.limits[]), but only as fresh as
  # the last time /usage ran (just above, or previously) — treat data older
  # than 1h as stale and skip rather than alert on outdated numbers.
  local claude_json="$HOME/.claude.json"
  if [ ! -f "$claude_json" ]; then
    log_fetch_fail "fallback unavailable: ~/.claude.json not found"
    return 1
  fi
  local util fetched_ms age
  util=$("$JQ" -c '.cachedUsageUtilization // empty' "$claude_json" 2>/dev/null)
  if [ -z "$util" ] || [ "$util" = "null" ]; then
    log_fetch_fail "fallback unavailable: no cachedUsageUtilization in ~/.claude.json"
    return 1
  fi
  fetched_ms=$(echo "$util" | "$JQ" -r '.fetchedAtMs // 0')
  age=$(( $(date +%s) - fetched_ms / 1000 ))
  if [ "$age" -ge 3600 ]; then
    log_fetch_fail "fallback stale: cachedUsageUtilization is ${age}s old (>=3600s), skipping"
    return 1
  fi
  resp=$(echo "$util" | "$JQ" -c '.utilization')
  if ! echo "$resp" | "$JQ" -e '.limits' >/dev/null 2>&1; then
    log_fetch_fail "fallback malformed: cachedUsageUtilization has no .limits"
    return 1
  fi
  echo "$resp" > "$CACHE"
  echo "$resp"
}

label_for() { # $1 kind, $2 scope model name
  if [ "$LANG_UM" = "en" ]; then
    case "$1" in
      session)       echo "Session (5h)" ;;
      weekly_all)    echo "Week (all models)" ;;
      weekly_scoped) echo "Week ($2)" ;;
      *)             echo "$1" ;;
    esac
  else
    case "$1" in
      session)       echo "Сессия (5ч)" ;;
      weekly_all)    echo "Неделя (все модели)" ;;
      weekly_scoped) echo "Неделя ($2)" ;;
      *)             echo "$1" ;;
    esac
  fi
}

msg_warn() { # $1 label, $2 pct, $3 reset time
  if [ "$LANG_UM" = "en" ]; then echo "🟡 ${1} limit: ${2}%, resets at ${3}"
  else echo "🟡 Лимит «${1}»: ${2}%, сброс в ${3}"; fi
}
msg_crit() {
  if [ "$LANG_UM" = "en" ]; then echo "🔴 ${1} limit: ${2}% — almost exhausted, resets at ${3}"
  else echo "🔴 Лимит «${1}»: ${2}% — почти исчерпан, сброс в ${3}"; fi
}
msg_reset() { # $1 label, $2 old pct, $3 new pct
  if [ "$LANG_UM" = "en" ]; then echo "♻️ ${1} limit was reset (was ${2}%, now ${3}%)"
  else echo "♻️ Лимит «${1}» сброшен (было ${2}%, сейчас ${3}%)"; fi
}
notif_title() {
  if [ "$LANG_UM" = "en" ]; then echo "Claude Code — usage limits"
  else echo "Claude Code — лимиты"; fi
}

notify_mac() { # $1 title, $2 body
  # sound played directly — works even without Notification Center permission
  afplay "/System/Library/Sounds/Glass.aiff" >/dev/null 2>&1 || true
  # `on run argv` form (same as compact-advisor.sh): title/body are passed as
  # argv items instead of being interpolated into the AppleScript source. A
  # body containing a literal `"` would otherwise terminate the AppleScript
  # string literal early, making osascript exit non-zero —
  # swallowed by `|| true`, so the notification (and every other message
  # batched into the same $2) silently never reached the screen.
  osascript -e 'on run argv' \
    -e 'display notification (item 2 of argv) with title (item 1 of argv) sound name "Glass"' \
    -e 'end run' -- "$1" "$2" >/dev/null 2>&1 || true
}

# Converts an ISO8601 UTC timestamp (as returned in resets_at) to epoch
# seconds; empty output on a parse failure. The window-rollover check below
# compares two resets_at values with tolerance rather than as exact strings —
# the API recomputes resets_at on every request with ±1s jitter.
to_epoch() { # $1 = ISO8601 UTC timestamp
  TZ=UTC date -jf "%Y-%m-%dT%H:%M:%S" "${1%%.*}" "+%s" 2>/dev/null
}

to_local() { # $1 = ISO8601 UTC timestamp, $2 = output format
  local epoch
  epoch=$(TZ=UTC date -jf "%Y-%m-%dT%H:%M:%S" "${1%%.*}" "+%s" 2>/dev/null) || { echo "?"; return; }
  date -r "$epoch" "$2"
}

# `status` is read by a person, so it always says something: the version
# first, then live numbers, or the last cached numbers marked with their age,
# or a line saying there is no data. hook and cron must never act on stale
# numbers, so for them a failed fetch still means silence.
if [ "$MODE" = "status" ]; then
  # install.sh writes .limit-alerts-version into the state directory; in plugin
  # mode nobody does, and VERSION at the plugin root is the source of truth.
  # It is found relative to this file rather than through CLAUDE_PLUGIN_ROOT:
  # the status skill runs this from a plain shell, where that variable is only
  # substituted into the command text, never exported.
  VERSION_FILE=""
  PLUGIN_VERSION="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)/VERSION"
  if   [ -f "$DIR/.limit-alerts-version" ]; then
    VERSION_FILE="$DIR/.limit-alerts-version"
  elif [ -f "$PLUGIN_VERSION" ] && [ -f "$(dirname "$PLUGIN_VERSION")/.claude-plugin/plugin.json" ]; then
    VERSION_FILE="$PLUGIN_VERSION"
  fi
  if [ -n "$VERSION_FILE" ]; then
    printf 'claude-code-limit-alerts v%s\n' "$(cat "$VERSION_FILE")"
  fi
fi

if ! USAGE=$(fetch_usage); then
  [ "$MODE" = "status" ] || exit 0
  if [ -s "$CACHE" ] && "$JQ" -e '.limits' "$CACHE" >/dev/null 2>&1; then
    USAGE=$(cat "$CACHE")
    cache_mtime=$(stat -f %m "$CACHE" 2>/dev/null || echo 0)
    age_min=$(( ($(date +%s) - cache_mtime) / 60 ))
    if [ "$age_min" -lt 60 ]; then
      age_ru="${age_min} мин"; age_en="${age_min} min"
    else
      age_ru="$(( age_min / 60 )) ч"; age_en="$(( age_min / 60 )) h"
    fi
    cache_at=$(date -r "$cache_mtime" "+%d.%m %H:%M")
    next_en=""; next_ru=""
    if backoff_active; then
      next_at=$(date -r "$(backoff_until)" '+%H:%M')
      next_en=" Rate limited, next attempt at ${next_at}."
      next_ru=" Запросы ограничены, следующая попытка в ${next_at}."
    fi
    if [ "$LANG_UM" = "en" ]; then
      echo "⚠ No live data — showing the cache from ${cache_at} (${age_en} ago).${next_en} Details: $LOG"
    else
      echo "⚠ Свежих данных нет — показан кэш от ${cache_at} (${age_ru} назад).${next_ru} Подробности: $LOG"
    fi
  else
    if [ "$LANG_UM" = "en" ]; then
      echo "No usage data: the request failed and there is no cache yet. Details: $LOG"
    else
      echo "Нет данных о лимитах: запрос не удался, а кэша ещё нет. Подробности: $LOG"
    fi
    exit 0
  fi
fi

# limits[] -> "kind|percent|resets_at|scope" lines
LIMITS=$(echo "$USAGE" | "$JQ" -r \
  '.limits[] | [.kind, (.percent // 0), (.resets_at // ""), (.scope.model.display_name // "")] | join("|")')

if [ "$MODE" = "limits" ]; then
  printf '%s\n' "$LIMITS"
  exit 0
fi

if [ "$MODE" = "status" ]; then
  while IFS='|' read -r kind percent resets scope; do
    [ -n "$kind" ] || continue
    reset_local=$(to_local "$resets" "+%d.%m %H:%M")
    # From a stale cache, a window whose reset time has already passed has
    # rolled over since: its percent no longer says anything, so say so.
    passed=""
    if [ -n "${cache_at:-}" ] && [ -n "$resets" ]; then
      reset_epoch=$(to_epoch "$resets")
      if [ -n "$reset_epoch" ] && [ "$reset_epoch" -le "$(date +%s)" ]; then
        if [ "$LANG_UM" = "en" ]; then passed=" (already reset)"; else passed=" (уже сброшен)"; fi
      fi
    fi
    if [ "$LANG_UM" = "en" ]; then
      printf "%-22s %3s%%  resets: %s%s\n" "$(label_for "$kind" "$scope")" "$percent" "$reset_local" "$passed"
    else
      printf "%-22s %3s%%  сброс: %s%s\n" "$(label_for "$kind" "$scope")" "$percent" "$reset_local" "$passed"
    fi
  done <<< "$LIMITS"
  exit 0
fi

# One state update at a time. The Stop hook, SessionStart and the launchd job
# can run at the same moment — a freshly loaded agent's RunAtLoad fires right
# as the session's own SessionStart check does. Without a lock both read the
# same state, both see a threshold as new, and the warning arrives twice. A run
# that cannot get the lock just leaves: the holder is reporting the same news.
LOCK="$DIR/usage-monitor.lock"
acquire_lock() {
  local _
  for _ in $(seq 1 50); do
    mkdir "$LOCK" 2>/dev/null && return 0
    # A lock older than a minute was left by a run that got killed.
    if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
      rmdir "$LOCK" 2>/dev/null || true
      continue
    fi
    sleep 0.1
  done
  return 1
}
acquire_lock || exit 0
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

[ -f "$STATE" ] || echo '{}' > "$STATE"
MESSAGES=()
NEW_STATE=$(cat "$STATE")

while IFS='|' read -r kind percent resets scope; do
  [ -n "$kind" ] || continue
  pct=${percent%%.*}
  key="$kind"
  prev_resets=$(echo "$NEW_STATE" | "$JQ" -r --arg k "$key" '.[$k].resets_at // ""')
  prev_pct=$(echo "$NEW_STATE" | "$JQ" -r --arg k "$key" '.[$k].percent // 0')
  notified=$(echo "$NEW_STATE" | "$JQ" -r --arg k "$key" '.[$k].notified // 0')
  label=$(label_for "$kind" "$scope")

  # window rollover: resets_at moved by more than 2 min. The API recomputes
  # resets_at on every request with ±1s jitter, so a plain string comparison
  # produces false "reset" alerts and re-arms threshold notifications.
  if [ -n "$prev_resets" ]; then
    e_prev=$(to_epoch "$prev_resets" || echo 0)
    e_cur=$(to_epoch "$resets" || echo 0)
    diff=$(( e_cur - e_prev )); [ "$diff" -lt 0 ] && diff=$(( -diff ))
    if [ "$diff" -gt 120 ]; then
      # the window really rolled over; announce only if usage actually dropped
      if [ "${prev_pct%%.*}" -ge "$RESET_MIN" ] && [ "$pct" -lt "${prev_pct%%.*}" ]; then
        MESSAGES+=("$(msg_reset "$label" "${prev_pct%%.*}" "$pct")")
      fi
      notified=0
    fi
  fi

  # thresholds: one notification per threshold per window
  if [ "$pct" -ge "$CRIT" ] && [ "$notified" -lt "$CRIT" ]; then
    MESSAGES+=("$(msg_crit "$label" "$pct" "$(to_local "$resets" "+%H:%M")")")
    notified=$CRIT
  elif [ "$pct" -ge "$WARN" ] && [ "$notified" -lt "$WARN" ]; then
    MESSAGES+=("$(msg_warn "$label" "$pct" "$(to_local "$resets" "+%H:%M")")")
    notified=$WARN
  fi

  NEW_STATE=$(echo "$NEW_STATE" | "$JQ" --arg k "$key" --argjson p "$pct" --arg r "$resets" --argjson n "$notified" \
    '.[$k] = {percent: $p, resets_at: $r, notified: $n}')
done <<< "$LIMITS"

echo "$NEW_STATE" > "$STATE"

if [ "${#MESSAGES[@]}" -gt 0 ]; then
  BODY=$(printf '%s\n' "${MESSAGES[@]}")
  echo "$(date '+%F %T') [$MODE] ${BODY//$'\n'/ | }" >> "$LOG"
  notify_mac "$(notif_title)" "$BODY"
  if [ "$MODE" = "hook" ]; then
    "$JQ" -n --arg msg "$BODY" '{systemMessage: $msg}'
  fi
fi
exit 0
