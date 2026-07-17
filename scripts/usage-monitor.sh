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
WARN="${UM_WARN:-80}"
CRIT="${UM_CRIT:-95}"
RESET_MIN="${UM_RESET_MIN:-50}"
CACHE_TTL="${UM_CACHE_TTL:-60}"
LANG_UM="${UM_LANG:-ru}"

DIR="$HOME/.claude/scripts"
STATE="$DIR/usage-monitor-state.json"
CACHE="$DIR/usage-monitor-cache.json"

JQ="$(command -v jq || echo /opt/homebrew/bin/jq)"
[ -x "$JQ" ] || exit 0

log_note() {
  [ "$MODE" = "status" ] && return 0
  echo "$(date '+%F %T') [$MODE] $1" >> "$DIR/usage-monitor.log"
}
log_fetch_fail() { log_note "fetch failed: $1"; } # silent fetch failures used to leave no trace at all

# Portable timeout: macOS ships neither `timeout` nor `gtimeout` by default,
# but /usr/bin/perl is always present. alarm() fires in the perl process and
# its default disposition (terminate) survives exec into the real command.
run_with_timeout() { # $1 = seconds, rest = command + args
  local secs="$1"; shift
  perl -e 'alarm shift @ARGV; exec @ARGV' "$secs" "$@"
}

# Force-refreshes ~/.claude.json's cachedUsageUtilization by running the
# /usage slash command headlessly. Slash commands are handled locally by the
# CLI (0 tokens, no model call, ~0.5s) and -p skips the workspace-trust
# prompt, so this is safe to run unattended — confirmed empirically: it
# updates cachedUsageUtilization.fetchedAtMs to "now" and its .utilization
# shape matches what the fallback below already parses. This also fires the
# headless session's own Stop/SessionStart hooks, recursing once into
# `usage-monitor.sh hook` — safe because hook mode never calls this itself,
# so the recursion doesn't go any deeper. Only call this from cron/status:
# calling it from hook mode would add ~0.5s to every real Claude Code turn.
refresh_via_cli() {
  command -v claude >/dev/null 2>&1 || return 1
  ( cd "$HOME" && run_with_timeout 15 claude -p "/usage" --output-format json ) >/dev/null 2>&1
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
  local resp http_code
  if [ -n "$token" ]; then
    resp=$(curl -sS --max-time 10 -w '\n%{http_code}' https://api.anthropic.com/api/oauth/usage \
      -H "Authorization: Bearer $token" \
      -H "anthropic-beta: oauth-2025-04-20" 2>/dev/null)
    http_code="${resp##*$'\n'}"
    resp="${resp%$'\n'*}"
    if [ "$http_code" = "200" ] && echo "$resp" | "$JQ" -e '.limits' >/dev/null 2>&1; then
      echo "$resp" > "$CACHE"
      echo "$resp"
      return 0
    fi
    log_fetch_fail "live endpoint returned HTTP ${http_code:-?} (token likely expired/invalid — refreshes only while Claude Code is active)"
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
  if [ "$MODE" = "cron" ] || [ "$MODE" = "status" ]; then
    if refresh_via_cli; then
      log_note "refreshed local usage cache via 'claude -p /usage'"
    else
      log_note "'claude -p /usage' refresh unavailable or failed"
    fi
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
  osascript -e "display notification \"$2\" with title \"$1\" sound name \"Glass\"" >/dev/null 2>&1 || true
}

to_local() { # $1 = ISO8601 UTC timestamp, $2 = output format
  local epoch
  epoch=$(TZ=UTC date -jf "%Y-%m-%dT%H:%M:%S" "${1%%.*}" "+%s" 2>/dev/null) || { echo "?"; return; }
  date -r "$epoch" "$2"
}

USAGE=$(fetch_usage) || exit 0

# limits[] -> "kind|percent|resets_at|scope" lines
LIMITS=$(echo "$USAGE" | "$JQ" -r \
  '.limits[] | [.kind, (.percent // 0), (.resets_at // ""), (.scope.model.display_name // "")] | join("|")')

if [ "$MODE" = "status" ]; then
  while IFS='|' read -r kind percent resets scope; do
    [ -n "$kind" ] || continue
    reset_local=$(to_local "$resets" "+%d.%m %H:%M")
    if [ "$LANG_UM" = "en" ]; then
      printf "%-22s %3s%%  resets: %s\n" "$(label_for "$kind" "$scope")" "$percent" "$reset_local"
    else
      printf "%-22s %3s%%  сброс: %s\n" "$(label_for "$kind" "$scope")" "$percent" "$reset_local"
    fi
  done <<< "$LIMITS"
  exit 0
fi

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
    e_prev=$(TZ=UTC date -jf "%Y-%m-%dT%H:%M:%S" "${prev_resets%%.*}" "+%s" 2>/dev/null || echo 0)
    e_cur=$(TZ=UTC date -jf "%Y-%m-%dT%H:%M:%S" "${resets%%.*}" "+%s" 2>/dev/null || echo 0)
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
  echo "$(date '+%F %T') [$MODE] ${BODY//$'\n'/ | }" >> "$DIR/usage-monitor.log"
  notify_mac "$(notif_title)" "$BODY"
  if [ "$MODE" = "hook" ]; then
    "$JQ" -n --arg msg "$BODY" '{systemMessage: $msg}'
  fi
fi
exit 0
