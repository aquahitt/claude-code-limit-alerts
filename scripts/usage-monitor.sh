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
#   status — human-readable snapshot of all limits, with the pace and the
#            forecast, the weekly split by product and paid credits
#   doctor — checks the installation without asking the endpoint; with
#            --notify it also sends a test notification
#   limits — machine-readable snapshot: one "kind|percent|resets_at|scope"
#            line per limit, no header, no localization (pair with
#            UM_CACHE_TTL=0 to bypass the cache)
#
# Notifications are sent once per threshold per window (no spam):
#   WARN  (default 80%)  🟡
#   CRIT  (default 95%)  🔴
#   reset ♻️  — when a window rolls over and usage was >= RESET_MIN (50%)
#   forecast ⏳ — once per window, when at the current pace the limit runs
#            out before the window resets (see forecasts)
#   credits 💳 — when paid usage credits start being spent, and at WARN/CRIT
#            percent of the spending limit
#   unused ⌛ — once per weekly window, in its last day, when at the current
#            pace a good part of it would reset unused
#
# Environment overrides:
#   UM_WARN=80  UM_CRIT=95  UM_RESET_MIN=50  UM_CACHE_TTL=60  UM_LANG=ru|en
#   UM_FORECAST=1  UM_SPEND_ALERT=1  UM_UNUSED_ALERT=1  (0 turns it off)
#   UM_MODEL_HINT=0  (1 adds "carry on with another model" to a model-scoped
#                     weekly limit at CRIT)

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
FORECAST="${UM_FORECAST:-1}"
SPEND_ALERT="${UM_SPEND_ALERT:-1}"
UNUSED_ALERT="${UM_UNUSED_ALERT:-1}"
MODEL_HINT="${UM_MODEL_HINT:-0}"

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
  # Booleans arrive as the literal strings true / false.
  [ "${CLAUDE_PLUGIN_OPTION_FORECAST:-}" = "false" ] && FORECAST="${UM_FORECAST:-0}"
  [ "${CLAUDE_PLUGIN_OPTION_SPEND_ALERT:-}" = "false" ] && SPEND_ALERT="${UM_SPEND_ALERT:-0}"
  [ "${CLAUDE_PLUGIN_OPTION_UNUSED_ALERT:-}" = "false" ] && UNUSED_ALERT="${UM_UNUSED_ALERT:-0}"
  [ "${CLAUDE_PLUGIN_OPTION_MODEL_HINT:-}" = "true" ] && MODEL_HINT="${UM_MODEL_HINT:-1}"
fi

# Resolution order: an explicit override, then the directory install.sh
# creates. In plugin mode hooks.json and the generated wrappers always pass
# UM_STATE_DIR, so CLAUDE_PLUGIN_DATA is deliberately NOT consulted here: that
# variable is exported by whichever plugin owns the current hook, so a classic
# install running inside a session that has any other plugin enabled would
# silently relocate its state into that plugin's data directory.
DIR="${UM_STATE_DIR:-$HOME/.claude/scripts}"
mkdir -p "$DIR" 2>/dev/null || true

# This copy's own version: VERSION at the plugin (or repository) root, the
# .version the plugin bootstrap writes beside its bin/ mirror, or the marker
# install.sh leaves beside the classic copy. Empty when none is found.
OWN_VERSION=""
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)
if [ -f "$HERE/../VERSION" ] && [ -f "$HERE/../.claude-plugin/plugin.json" ]; then
  OWN_VERSION=$(cat "$HERE/../VERSION" 2>/dev/null)
elif [ -f "$HERE/.version" ]; then
  OWN_VERSION=$(cat "$HERE/.version" 2>/dev/null)
elif [ -f "$HERE/.limit-alerts-version" ]; then
  OWN_VERSION=$(cat "$HERE/.limit-alerts-version" 2>/dev/null)
fi

# A session keeps running the hooks of the plugin version it started with,
# until it is closed. Such an older copy rewrote the shared state in its older
# shape (dropping the forecast and unused flags, so the newer copy announced
# them again), paused on its older backoff rules and sent its older messages.
# The plugin bootstrap stamps the newest installed version into bin/.version;
# an older copy than that leaves the checks to the newer one — the background
# agent and the sessions started since — and only leaves a mark for doctor.
INSTALLED_VERSION=$(cat "$DIR/bin/.version" 2>/dev/null)
case "$MODE" in hook|cron)
  if [[ "$OWN_VERSION" =~ ^[0-9] ]] && [[ "$INSTALLED_VERSION" =~ ^[0-9] ]] && \
     [ "$OWN_VERSION" != "$INSTALLED_VERSION" ] && \
     [ "$(printf '%s\n%s\n' "$OWN_VERSION" "$INSTALLED_VERSION" | sort -V | head -n 1)" = "$OWN_VERSION" ]; then
    printf '%s\n' "$OWN_VERSION" > "$DIR/.stale-session" 2>/dev/null || true
    exit 0
  fi ;;
esac

STATE="$DIR/usage-monitor-state.json"
CACHE="$DIR/usage-monitor-cache.json"

JQ="$(command -v jq || echo /opt/homebrew/bin/jq)"
if [ ! -x "$JQ" ]; then
  # Hooks and the agent stay silent; a person running a command is told why.
  case "$MODE" in status|doctor) echo "jq is required. Install it with: brew install jq" ;; esac
  exit 0
fi

# Whose numbers these are. One machine can sign in to several accounts in
# turn, and one person can be in several organizations (a personal plan and a
# Team seat) with separate limits — so the key is account + organization, as
# ~/.claude.json names the current sign-in. The cache and the backoff carry
# it, and the anti-spam state and the pause after an error are kept per
# account (files named after ACCOUNT_KEY): without that, switching
# accounts read as a window reset ("♻️ 67% → 37%") and re-armed the warnings.
# Empty when there is no OAuth sign-in: then nothing is tagged, as before.
#
# Claude Code rewrites ~/.claude.json all the time (it is ~100 KB), and a
# read can land on half a file. An empty ACCOUNT from that used to write an
# untagged cache, which every account took for its own. So a failed parse is
# retried, and if the file stays unreadable the account counts as unknown
# (ACCOUNT_UNKNOWN=1): nothing is written for it — see below. A file that
# parses but has no oauthAccount is a real "no sign-in".
CLAUDE_JSON="$HOME/.claude.json"
ACCOUNT=""
ACCOUNT_UNKNOWN=0
if [ -f "$CLAUDE_JSON" ]; then
  ACCOUNT_UNKNOWN=1
  for _try in 1 2 3; do
    if ACCOUNT=$("$JQ" -r '.oauthAccount // {} | select(.accountUuid != null)
         | "\(.accountUuid):\(.organizationUuid // "")"' "$CLAUDE_JSON" 2>/dev/null); then
      ACCOUNT_UNKNOWN=0
      break
    fi
    ACCOUNT=""
    sleep 0.1
  done
fi
OAUTH_ACCOUNT="$ACCOUNT"

# The numbers come with the Keychain token, and ~/.claude.json names the
# sign-in — two files that a switch of accounts (/login, or a tool that swaps
# the Keychain entry) does not update at the same moment. In between, one
# account's numbers were stored under the other's key, which read as a reset
# and re-armed the warnings. So the token itself says whose it is: once per
# token, /api/oauth/profile names its account and organization, and the
# answer is remembered under a hash of the token (never the token):
#   usage-monitor-accounts.json
#   {"<sha256(token), 16 chars>": {"account": "<uuid>:<org uuid>", "at": epoch}
#                               | {"failed": epoch}}
# An access token lives for hours, so that is a few requests a day. When the
# profile cannot be had, ~/.claude.json decides, as before; a failed lookup
# is retried after PROFILE_RETRY seconds, not on every run.
ACCOUNTS_MAP="$DIR/usage-monitor-accounts.json"
ACCOUNTS_KEEP=10
PROFILE_RETRY=600
TOKEN=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null \
  | "$JQ" -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
TOKEN_ID=""
[ -n "$TOKEN" ] && TOKEN_ID=$(printf '%s' "$TOKEN" | shasum -a 256 2>/dev/null | cut -c1-16)

remember_token_account() { # $1 = JSON object to store for TOKEN_ID
  local map
  map=$("$JQ" -c 'if type == "object" then . else {} end' "$ACCOUNTS_MAP" 2>/dev/null) || map='{}'
  printf '%s' "$map" | "$JQ" -c --arg t "$TOKEN_ID" --argjson v "$1" --argjson keep "$ACCOUNTS_KEEP" '
    .[$t] = $v | to_entries | sort_by(.value.at // .value.failed // 0) | .[-$keep:] | from_entries' \
    > "$ACCOUNTS_MAP.$$.tmp" 2>/dev/null && mv -f "$ACCOUNTS_MAP.$$.tmp" "$ACCOUNTS_MAP" 2>/dev/null \
    || rm -f "$ACCOUNTS_MAP.$$.tmp"
}

# Prints "<uuid>:<org uuid>" for TOKEN, or nothing. The token goes to curl on
# stdin, so it never shows in the process list.
fetch_token_account() {
  local resp http_code
  resp=$(printf 'Authorization: Bearer %s\n' "$TOKEN" | curl -sS --max-time 5 -w '\n%{http_code}' \
    https://api.anthropic.com/api/oauth/profile -H @- -H "anthropic-beta: oauth-2025-04-20" 2>/dev/null)
  http_code="${resp##*$'\n'}"
  [ "$http_code" = "200" ] || return 1
  printf '%s' "${resp%$'\n'*}" | "$JQ" -r '
    select((.account.uuid | type) == "string" and (.organization.uuid | type) == "string")
    | "\(.account.uuid):\(.organization.uuid)"' 2>/dev/null
}

TOKEN_ACCOUNT=""
if [ -n "$TOKEN_ID" ]; then
  IFS='|' read -r TOKEN_ACCOUNT token_failed <<< "$("$JQ" -r --arg t "$TOKEN_ID" '
    .[$t] // {} | [ (.account // ""), (.failed // 0) ] | map(tostring) | join("|")' "$ACCOUNTS_MAP" 2>/dev/null)"
  case "${token_failed:-0}" in ''|*[!0-9]*) token_failed=0 ;; esac
  # doctor makes no requests; status, limits and the checks may.
  if [ -z "$TOKEN_ACCOUNT" ] && [ "$MODE" != "doctor" ] && \
     [ $(( $(date +%s) - token_failed )) -ge "$PROFILE_RETRY" ]; then
    if TOKEN_ACCOUNT=$(fetch_token_account) && [ -n "$TOKEN_ACCOUNT" ]; then
      remember_token_account "$("$JQ" -n -c --arg a "$TOKEN_ACCOUNT" --argjson at "$(date +%s)" '{account: $a, at: $at}')"
      [ -n "$OAUTH_ACCOUNT" ] && [ "$TOKEN_ACCOUNT" != "$OAUTH_ACCOUNT" ] && TOKEN_SOURCES_DIFFER=1
    else
      TOKEN_ACCOUNT=""
      remember_token_account "{\"failed\": $(date +%s)}"
      PROFILE_FAILED=1
    fi
  fi
fi
if [ -n "$TOKEN_ACCOUNT" ]; then
  ACCOUNT="$TOKEN_ACCOUNT"
  ACCOUNT_UNKNOWN=0
fi
ACCOUNT_KEY=$(printf '%s' "$ACCOUNT" | awk -F: 'NF { print substr($1, 1, 8) "-" substr($2, 1, 8) }')
if [ -n "$ACCOUNT_KEY" ]; then
  STATE="$DIR/usage-monitor-state.$ACCOUNT_KEY.json"
  # One-time move from the single shared state of <= 0.9.0: seed the first
  # account seen from it, then retire it so another account starts clean.
  if [ ! -f "$STATE" ] && [ -f "$DIR/usage-monitor-state.json" ]; then
    mv "$DIR/usage-monitor-state.json" "$STATE" 2>/dev/null || true
  fi
fi

# The cache file is shared, so it is trusted only for the account it was
# fetched for. An untagged cache belongs to an install with no sign-in at
# all; for a signed-in account it is someone else's (it used to count as
# anyone's, which mixed accounts), and the next fetch replaces it. With the
# account unknown, no cache is trusted.
cache_is_mine() {
  [ -f "$CACHE" ] || return 1
  [ "$ACCOUNT_UNKNOWN" = "1" ] && return 1
  "$JQ" -e --arg a "$ACCOUNT" '(._account // "") == $a' "$CACHE" >/dev/null 2>&1
}

write_cache() { # $1 = response JSON
  [ "$ACCOUNT_UNKNOWN" = "1" ] && return 0
  if [ -n "$ACCOUNT" ]; then
    printf '%s' "$1" | "$JQ" -c --arg a "$ACCOUNT" '. + {_account: $a}' > "$CACHE" 2>/dev/null \
      || printf '%s\n' "$1" > "$CACHE"
  else
    printf '%s\n' "$1" > "$CACHE"
  fi
}

# History of readings, the ground the forecast stands on: one JSON line
# whenever a percent or a window changes, and at least every
# HISTORY_HEARTBEAT seconds while readings arrive, so a quiet stretch is
# recorded as quiet rather than as a gap. Per account, like the state.
#   {"t": epoch of the reading, "s": "api" | "claude",
#    "w": {"<kind>": [percent, resets_at as epoch rounded to the minute]}}
# resets_at is rounded because the API recomputes it on every request with
# ±1s jitter; unrounded, every reading would look like a change.
HISTORY="$DIR/usage-history${ACCOUNT_KEY:+.$ACCOUNT_KEY}.jsonl"
HISTORY_HEARTBEAT=1800
HISTORY_MAX_BYTES=$((2 * 1024 * 1024))
HISTORY_KEEP_LINES=12000

# ISO 8601 resets_at -> epoch seconds, inside jq.
JQ_EPOCH='def epoch: (. // "") | sub("\\.[0-9]+"; "") | sub("(\\+00:00|Z)$"; "Z")
  | (try fromdateiso8601 catch 0);'

record_history() { # $1 = response JSON, $2 = epoch of the reading, $3 = source
  [ "$ACCOUNT_UNKNOWN" = "1" ] && return 0
  local line last
  line=$(printf '%s' "$1" | "$JQ" -c --argjson t "$2" --arg s "$3" "$JQ_EPOCH"'
    { t: $t, s: $s,
      w: ([ .limits[]? | select((.kind | type) == "string" and (.percent | type) == "number")
            | { key: .kind,
                value: [ .percent, (((.resets_at | epoch) + 30) / 60 | floor * 60) ] } ]
          | from_entries) }
    | select(.w != {})' 2>/dev/null) || return 0
  [ -n "$line" ] || return 0
  last=$(tail -n 1 "$HISTORY" 2>/dev/null)
  if [ -n "$last" ] && "$JQ" -e -n --argjson a "$last" --argjson b "$line" --argjson hb "$HISTORY_HEARTBEAT" \
       '$b.t <= $a.t or ($a.w == $b.w and $b.t - $a.t < $hb)' >/dev/null 2>&1; then
    return 0
  fi
  printf '%s\n' "$line" >> "$HISTORY" 2>/dev/null || return 0
  if [ "$(stat -f %z "$HISTORY" 2>/dev/null || echo 0)" -gt "$HISTORY_MAX_BYTES" ]; then
    tail -n "$HISTORY_KEEP_LINES" "$HISTORY" > "$HISTORY.tmp" 2>/dev/null && mv "$HISTORY.tmp" "$HISTORY"
  fi
}

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

# Each line carries the version that wrote it, so doctor can tell when a
# session on an older version is still writing.
log_note() {
  case "$MODE" in status|limits|doctor) return 0 ;; esac
  echo "$(date '+%F %T') [$MODE${OWN_VERSION:+ v$OWN_VERSION}] $1" >> "$LOG"
}
log_fetch_fail() { log_note "fetch failed: $1"; } # silent fetch failures used to leave no trace at all

[ "${PROFILE_FAILED:-0}" = "1" ] && log_note "account of the Keychain token unknown (/api/oauth/profile failed) — using ~/.claude.json"
[ "${TOKEN_SOURCES_DIFFER:-0}" = "1" ] && \
  log_note "Keychain token belongs to ${ACCOUNT_KEY}, ~/.claude.json names another account — keyed by the token"
# Whose numbers these would be is not known: the checks write nothing (no
# cache, state, history or pause), so another account's files stay intact.
if [ "$ACCOUNT_UNKNOWN" = "1" ]; then
  case "$MODE" in hook|cron)
    log_note "unreadable ~/.claude.json and the token's account unknown — check skipped"
    exit 0 ;;
  esac
fi

# Backoff after HTTP 401, 403 or 429. Without it every hook (past the 60 s cache) and every
# cron tick asks again, which keeps the rate limit alive. The pause follows
# Retry-After when the server sends a number of seconds, and otherwise doubles
# from 5 minutes, capped at an hour.
# A success does not wipe the slate. Clearing the pause on the first answer
# that got through restarted every pause at 5 minutes, and a live install sat
# in "5 min pause, one success, 429" for hours (252 refusals in a day). So for
# an hour after the last refusal the file remembers the delay, the next one
# doubles from it, and a success only spaces the next live request
# BACKOFF_FIRST out. An hour without a refusal forgets it all.
# One pause per account, like the state: another account has its own token
# and limits, and its successful fetch must not lift this account's pause.
#   {"until": epoch no live request before, "delay": last pause, s,
#    "at": epoch of the last refusal}
BACKOFF="$DIR/usage-monitor-backoff${ACCOUNT_KEY:+.$ACCOUNT_KEY}.json"
BACKOFF_FIRST=300
BACKOFF_MAX=3600
BACKOFF_MEMORY=3600

backoff_until() { # prints the epoch the backoff ends at, 0 when none
  "$JQ" -r '.until // 0' "$BACKOFF" 2>/dev/null || echo 0
}

backoff_active() {
  [ -f "$BACKOFF" ] || return 1
  [ "$(date +%s)" -lt "$(backoff_until)" ]
}

backoff_start() { # $1 = Retry-After value from the response, may be empty
  local prev delay now
  now=$(date +%s)
  # The last delay counts only while the refusal that set it is recent. A file
  # an older version wrote has no "at" and counts as recent once.
  prev=$("$JQ" -r --argjson now "$now" --argjson mem "$BACKOFF_MEMORY" '
    if ($now - (.at // $now)) < $mem then (.delay // 0) else 0 end' "$BACKOFF" 2>/dev/null || echo 0)
  case "$prev" in ''|*[!0-9]*) prev=0 ;; esac
  # The usage endpoint answers its 429s with "Retry-After: 0" (seen 34 times
  # in a row on a live install), and taken literally that meant a one-minute
  # pause that never grew — the monitor kept the rate limit alive. Claude
  # Code's own client treats a non-positive Retry-After as absent and waits
  # its default; so does this. Absent, zero or an HTTP-date: double from 5 min.
  case "$1" in
    ''|*[!0-9]*) delay="" ;;
    *) delay="$1"; [ "$delay" -gt 0 ] || delay="" ;;
  esac
  if [ -z "$delay" ]; then
    if [ "$prev" -gt 0 ] 2>/dev/null; then delay=$(( prev * 2 )); else delay=$BACKOFF_FIRST; fi
  fi
  [ "$delay" -lt 60 ] && delay=60
  [ "$delay" -gt "$BACKOFF_MAX" ] && delay=$BACKOFF_MAX
  "$JQ" -n --argjson u "$(( now + delay ))" --argjson d "$delay" --argjson a "$now" \
    '{until: $u, delay: $d, at: $a}' > "$BACKOFF" 2>/dev/null || true
  echo "$delay"
}

# After a success: within BACKOFF_MEMORY of the last refusal, keep the delay
# and space the next live request BACKOFF_FIRST out; past it, forget.
backoff_success() {
  [ -f "$BACKOFF" ] || return 0
  local now at
  now=$(date +%s)
  at=$("$JQ" -r '.at // 0' "$BACKOFF" 2>/dev/null || echo 0)
  case "$at" in ''|*[!0-9]*) at=0 ;; esac
  if [ $(( now - at )) -lt "$BACKOFF_MEMORY" ]; then
    "$JQ" --argjson u "$(( now + BACKOFF_FIRST ))" '.until = $u' "$BACKOFF" > "$BACKOFF.$$.tmp" 2>/dev/null \
      && mv -f "$BACKOFF.$$.tmp" "$BACKOFF" || rm -f "$BACKOFF.$$.tmp" "$BACKOFF"
  else
    rm -f "$BACKOFF"
  fi
}

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
# A headless Claude Code start is the expensive part of a failed check, so it
# runs at most once per CLI_REFRESH_MIN seconds whatever the failure was — a
# lost network, a 5xx or a signed-out keychain would otherwise start one on
# every 92-second agent tick, more often than the 5-minute agent ever did.
CLI_REFRESH_STAMP="$DIR/usage-monitor-cli-refresh"
CLI_REFRESH_MIN=300

refresh_via_cli() {
  local claude_bin last
  last=$(stat -f %m "$CLI_REFRESH_STAMP" 2>/dev/null || echo 0)
  if [ $(( $(date +%s) - last )) -lt "$CLI_REFRESH_MIN" ]; then
    return 1
  fi
  touch "$CLI_REFRESH_STAMP" 2>/dev/null || true
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

# One live request at a time across every caller — the agent, the Stop hooks
# of several working terminals, the background refreshes started by several
# idle statuslines. Whoever takes the lock asks the endpoint; whoever finds it
# taken waits (up to 12 s, above curl's 10 s) and then reads what the holder
# cached, instead of sending a duplicate request. A lock older than a minute
# was left by a killed run.
FETCH_LOCK="$DIR/usage-monitor.fetch.lock"
acquire_fetch_lock() {
  mkdir "$FETCH_LOCK" 2>/dev/null && return 0
  if [ -n "$(find "$FETCH_LOCK" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
    rmdir "$FETCH_LOCK" 2>/dev/null || true
    mkdir "$FETCH_LOCK" 2>/dev/null && return 0
  fi
  local _
  for _ in $(seq 1 120); do
    [ -d "$FETCH_LOCK" ] || break
    sleep 0.1
  done
  return 1
}

fetch_usage() {
  # cache keeps the Stop hook from hitting the API on every turn
  if cache_is_mine; then
    local age=$(( $(date +%s) - $(stat -f %m "$CACHE" 2>/dev/null || echo 0) ))
    if [ "$age" -lt "$CACHE_TTL" ] && [ "$MODE" != "cron" ]; then
      cat "$CACHE"
      return 0
    fi
  fi
  local token="$TOKEN"
  local resp http_code headers retry_after delay try_cli=0 fetch_started
  fetch_started=$(date +%s)
  if backoff_active; then
    # Rate limited a moment ago: no live request and no CLI refresh (it asks
    # the same endpoint). Only the local fallback below, which costs nothing.
    [ "$MODE" = "cron" ] && log_fetch_fail "rate limited, live requests paused until $(date -r "$(backoff_until)" '+%H:%M')"
  elif [ -n "$token" ] && ! acquire_fetch_lock; then
    # Another check fetched meanwhile: its answer is in the cache, or it failed
    # (then only the local fallback below — never a second request).
    if cache_is_mine && [ "$(stat -f %m "$CACHE" 2>/dev/null || echo 0)" -ge "$fetch_started" ]; then
      cat "$CACHE"
      return 0
    fi
  elif [ -n "$token" ]; then
    # The response headers (for Retry-After) go through a temporary file. A
    # run that is stopped mid-request removes it on the way out; one killed
    # outright (kill -9) cannot, so the next request sweeps what is left. A
    # request takes at most 10 s and runs under the fetch lock, so a file
    # older than a minute is nobody's.
    find "$DIR" -maxdepth 1 -name '.usage-headers.*' -mmin +1 -delete 2>/dev/null
    headers=$(mktemp "$DIR/.usage-headers.XXXXXX" 2>/dev/null) || headers=/dev/null
    # fetch_usage always runs in $(...), so the traps belong to that subshell;
    # the path is kept outside the local, which is gone by the time EXIT fires.
    if [ "$headers" != /dev/null ]; then
      HEADERS_TMP="$headers"
      trap 'rm -f "${HEADERS_TMP:-}"' EXIT
      trap 'rm -f "${HEADERS_TMP:-}"; exit 1' INT TERM HUP
    fi
    # The token goes to curl on stdin (-H @-), not in its arguments: those are
    # visible in the process list to every process of the user while the
    # request runs (up to 10 s).
    resp=$(printf 'Authorization: Bearer %s\n' "$token" \
      | curl -sS --max-time 10 -D "$headers" -w '\n%{http_code}' https://api.anthropic.com/api/oauth/usage \
          -H @- -H "anthropic-beta: oauth-2025-04-20" 2>/dev/null)
    http_code="${resp##*$'\n'}"
    resp="${resp%$'\n'*}"
    retry_after=$(awk -F': *' 'tolower($1) == "retry-after" { gsub(/\r/, "", $2); print $2 }' "$headers" 2>/dev/null | tail -1)
    [ "$headers" != /dev/null ] && rm -f "$headers"
    if [ "$http_code" = "200" ] && echo "$resp" | "$JQ" -e '.limits' >/dev/null 2>&1; then
      backoff_success
      write_cache "$resp"
      record_history "$resp" "$fetch_started" api
      # Released only once the cache holds the answer the waiters will read.
      rmdir "$FETCH_LOCK" 2>/dev/null || true
      echo "$resp"
      return 0
    fi
    rmdir "$FETCH_LOCK" 2>/dev/null || true
    # The reason matters for diagnosis: 401/403 point at the token, 429 only
    # means too many requests in a short window (hooks, cron and `status`
    # together can get there) and clears up on its own.
    # 401 and 403 pause like 429 — Claude Code's own client treats 403 and 429
    # as "rate limited" and stops asking, and a 401 does not heal by asking
    # again: the CLI refresh below renews the token. Without the pause, an account that the
    # endpoint keeps refusing (seen with Team/organization tokens) would be
    # asked again, and a headless `claude -p /usage` spawned, on every agent
    # tick. The CLI refresh still gets one try when a 403 pause starts: the
    # CLI's own request may be served where this script's is not.
    case "$http_code" in
      401) delay=$(backoff_start "$retry_after")
           log_fetch_fail "live endpoint returned HTTP 401 (token likely expired — the CLI refresh renews it; pausing live requests for $(( delay / 60 )) min)"
           try_cli=1 ;;
      403) delay=$(backoff_start "$retry_after")
           log_fetch_fail "live endpoint returned HTTP 403 (refused — pausing live requests for $(( delay / 60 )) min${retry_after:+, server Retry-After: $retry_after})"
           try_cli=1 ;;
      429) delay=$(backoff_start "$retry_after")
           log_fetch_fail "live endpoint returned HTTP 429 (rate limited — pausing live requests for $(( delay / 60 )) min${retry_after:+, server Retry-After: $retry_after})" ;;
      *)   log_fetch_fail "live endpoint returned HTTP ${http_code:-?}"
           try_cli=1 ;;
    esac
  else
    log_fetch_fail "no OAuth token in keychain"
    try_cli=1
  fi
  # Team/organization OAuth tokens have been seen getting a 403 here, and a
  # personal token can 401 if it expired while Claude Code wasn't running to
  # refresh it. Either way, try to force a fresh local read via the CLI itself
  # before falling back to whatever's already cached — only from cron/status,
  # never from hook (see refresh_via_cli comment), and never on a 429 or
  # inside a pause: the CLI would ask the same endpoint.
  if { [ "$MODE" = "cron" ] || [ "$MODE" = "status" ]; } && [ "$try_cli" = "1" ]; then
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
  # Claude Code stamps this with the accountUuid it was fetched for and drops
  # it when that is not the signed-in account; an entry without the stamp, or
  # with another account's, is not ours either. "Ours" is the account this run
  # is keyed by — the token's, which ~/.claude.json may not have caught up with.
  util=$("$JQ" -c --arg me "${ACCOUNT%%:*}" '(if $me == "" then (.oauthAccount.accountUuid // null) else $me end) as $me
    | .cachedUsageUtilization // empty
    | select($me == null or .accountUuid == $me)' "$claude_json" 2>/dev/null)
  if [ -z "$util" ] || [ "$util" = "null" ]; then
    log_fetch_fail "fallback unavailable: no cachedUsageUtilization for this account in ~/.claude.json"
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
  write_cache "$resp"
  record_history "$resp" "$(( fetched_ms / 1000 ))" claude
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

# printf's %-Ns pads by bytes in bash 3.2 (macOS /bin/bash): a Cyrillic label
# is two bytes a letter, so it got no padding and the status columns drifted.
# This pads by characters; wc -m counts them under a UTF-8 locale whatever the
# caller's environment is.
pad_right() { # $1 text, $2 width
  local n
  n=$(printf '%s' "$1" | LC_ALL=en_US.UTF-8 wc -m | tr -d ' ')
  printf '%s%*s' "$1" $(( $2 > n ? $2 - n : 0 )) ''
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
msg_forecast() { # $1 label, $2 pct, $3 when it runs out, $4 when it resets
  if [ "$LANG_UM" = "en" ]; then echo "⏳ ${1} limit: ${2}% — at this pace it runs out ~${3}, resets ${4}"
  else echo "⏳ Лимит «${1}»: ${2}% — при таком темпе кончится ~${3}, сброс ${4}"; fi
}
msg_unused() { # $1 label, $2 pct, $3 when it resets, $4 percent left unused
  if [ "$LANG_UM" = "en" ]; then echo "⌛ ${1} limit: ${2}%, resets ${3} — at this pace ~${4}% goes unused"
  else echo "⌛ Лимит «${1}»: ${2}%, сброс ${3} — при таком темпе ~${4}% останется неиспользованным"; fi
}
msg_spend_start() { # $1 amount
  if [ "$LANG_UM" = "en" ]; then echo "💳 Paid usage credits are being spent: ${1}"
  else echo "💳 Расходуются платные usage credits: ${1}"; fi
}
msg_spend_level() { # $1 amount, $2 percent of the spending limit
  if [ "$LANG_UM" = "en" ]; then echo "💳 Usage credits: ${1} — ${2}% of your spending limit"
  else echo "💳 Usage credits: ${1} — ${2}% лимита расходов"; fi
}
msg_model_hint() {
  if [ "$LANG_UM" = "en" ]; then echo "↪ You can carry on with another model (/model): it does not spend this limit"
  else echo "↪ Можно продолжить на другой модели (/model): этот лимит она не тратит"; fi
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

# When something happens, as a person reads it: "14:00" today, "Thu 14:00"
# within the coming six days (a weekday is unambiguous there), the date
# beyond. A weekly reset said as a bare "10:00" could be any of seven days.
fmt_when() { # $1 = epoch, "?" when unknown
  local d
  local -a days
  [ -n "${1:-}" ] || { echo "?"; return 0; }
  if [ "$(date -r "$1" +%F)" = "$(date +%F)" ]; then
    date -r "$1" +%H:%M
  elif [ $(( $1 - $(date +%s) )) -lt 518400 ]; then
    if [ "$LANG_UM" = "en" ]; then days=(Mon Tue Wed Thu Fri Sat Sun); else days=(пн вт ср чт пт сб вс); fi
    d=$(date -r "$1" +%u)
    printf '%s %s\n' "${days[$(( d - 1 ))]}" "$(date -r "$1" +%H:%M)"
  else
    date -r "$1" "+%d.%m %H:%M"
  fi
}

fmt_money() { # $1 amount in minor units, $2 exponent, $3 currency code
  local v
  v=$(awk -v m="$1" -v e="$2" 'BEGIN { printf("%." e "f", m / (10 ^ e)) }')
  case "$3" in
    USD) echo "\$$v" ;;
    EUR) echo "€$v" ;;
    GBP) echo "£$v" ;;
    *)   echo "$v${3:+ $3}" ;;
  esac
}

# Where a weekly window would be if the week were spent evenly: the percent
# of it that has elapsed. "46% against 38% on pace" says more than "46%" — the
# same number on Monday and on Friday are different situations. Weekly
# windows only: five hours are too short for "evenly" to mean anything. Empty
# for the first half-day of the window, when the comparison is all noise.
pace_expected() { # $1 kind, $2 reset epoch -> percent, or nothing
  local len=604800 elapsed
  case "$1" in weekly_*) ;; *) return 0 ;; esac
  [ "${2:-0}" -gt 0 ] 2>/dev/null || return 0
  elapsed=$(( $(date +%s) - ($2 - len) ))
  [ "$elapsed" -ge $(( len / 14 )) ] && [ "$elapsed" -le "$len" ] || return 0
  echo $(( elapsed * 100 / len ))
}

# The other side of the pace: where a weekly window ends up at its reset if
# the rest of the week goes like the part already gone — its percent scaled
# by the elapsed share. Below 100, the difference is limit that resets
# unused: a subscription paid for and left idle. Same guards as above.
pace_projected() { # $1 kind, $2 reset epoch, $3 percent -> percent, or nothing
  local len=604800 elapsed
  case "$1" in weekly_*) ;; *) return 0 ;; esac
  [ "${2:-0}" -gt 0 ] 2>/dev/null || return 0
  elapsed=$(( $(date +%s) - ($2 - len) ))
  [ "$elapsed" -ge $(( len / 14 )) ] && [ "$elapsed" -le "$len" ] || return 0
  echo $(( ${3%%.*} * len / elapsed ))
}

# When each window runs out at the current pace, from the history: one
# "kind|epoch" line per window that would run out before it resets. Silence
# otherwise — a forecast that cannot be trusted is worse than none, so the
# conditions are deliberately strict, and whole-percent readings that arrive
# in bursts are handled by these conditions rather than by smoothing:
#   session (5h): the rise over the last hour, measured across at least 15
#     minutes and at least 5 points;
#   weekly: the rise over the last 24 hours (a sample at least 20 hours old),
#     which takes nights and breaks into account; without that much history,
#     the average since the window opened, once it is a day old. Not below
#     25%, where extrapolating a few points says nothing.
# It has to run out at least 10 minutes (5h) or 3 hours (weekly) before the
# reset: the margin keeps a forecast that hovers around the reset from
# flapping.
forecasts() {
  [ -s "$HISTORY" ] || return 0
  tail -n 3000 "$HISTORY" | "$JQ" -rs '
    def wlen: if . == "session" then 18000 elif startswith("weekly") then 604800 else null end;
    [ .[] | select((.t | type) == "number" and (.w | type) == "object") ] as $all
    | ($all | last) as $cur
    | select($cur != null)
    | $cur.t as $tn
    | $cur.w | to_entries[]
    | .key as $k | .value[0] as $p | .value[1] as $r
    | ($k | wlen) as $len
    | select($len != null and $r > $tn and $p < 100)
    | [ $all[] | select(.w[$k] != null and ((.w[$k][1] - $r) | fabs) <= 120)
        | { t, p: .w[$k][0] } ] as $win
    | ( if $len == 18000 then
          ([ $win[] | select(.t >= $tn - 3600) ] | first) as $b
          | if $b != null and ($tn - $b.t) >= 900 and ($p - $b.p) >= 5 then $b else null end
        else
          ([ $win[] | select(.t >= $tn - 86400) ] | first) as $b
          | if $p < 25 then null
            elif $b != null and ($tn - $b.t) >= 72000 then $b
            elif ($tn - ($r - $len)) >= 86400 then { t: ($r - $len), p: 0 }
            else null end
        end ) as $base
    | select($base != null)
    | (($p - $base.p) / ($tn - $base.t)) as $rate
    | select($rate > 0)
    | ($tn + (100 - $p) / $rate | floor) as $eta
    | select($eta < $r - (if $len == 18000 then 600 else 10800 end))
    | "\($k)|\($eta)"' 2>/dev/null
}

forecast_for() { # $1 kind, $2 output of forecasts -> epoch, or nothing
  printf '%s\n' "$2" | awk -F'|' -v k="$1" '$1 == k { print $2; exit }'
}

# `status` is read by a person, so it always says something: the version
# first, then live numbers, or the last cached numbers marked with their age,
# or a line saying there is no data. hook and cron must never act on stale
# numbers, so for them a failed fetch still means silence.
if [ "$MODE" = "status" ] || [ "$MODE" = "doctor" ]; then
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

# doctor: what is installed and what state it is in, for when something does
# not show up. It reads files only — no request to the endpoint, so it is
# safe to run during a 429 pause and says what the monitor last saw instead.
if [ "$MODE" = "doctor" ]; then
  tr_() { if [ "$LANG_UM" = "en" ]; then printf '%s' "$1"; else printf '%s' "$2"; fi; }
  ok()   { echo "✓ $(tr_ "$1" "$2")"; }
  bad()  { echo "⚠ $(tr_ "$1" "$2")"; }
  info() { echo "· $(tr_ "$1" "$2")"; }
  ago() { # seconds -> "5 min" / "3 h" / "2 d"
    if   [ "$1" -lt 3600 ];   then tr_ "$(( $1 / 60 )) min" "$(( $1 / 60 )) мин"
    elif [ "$1" -lt 172800 ]; then tr_ "$(( $1 / 3600 )) h" "$(( $1 / 3600 )) ч"
    else                           tr_ "$(( $1 / 86400 )) d" "$(( $1 / 86400 )) д"; fi
  }
  NOW=$(date +%s)
  SETTINGS="$HOME/.claude/settings.json"
  case "$DIR" in
    */plugins/data/*) INSTALL=plugin; LABEL="com.claude.usage-monitor.plugin" ;;
    *)                INSTALL=classic; LABEL="com.claude.usage-monitor" ;;
  esac
  if [ "$INSTALL" = "plugin" ]; then
    info "Installation: plugin, state in $DIR" "Установка: плагин, состояние в $DIR"
  else
    info "Installation: install.sh, state in $DIR" "Установка: install.sh, состояние в $DIR"
  fi
  ok "jq: $JQ" "jq: $JQ"

  # Token: presence, plan and expiry only — never the token itself.
  creds=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)
  IFS='|' read -r tok_has tok_exp tok_plan <<< "$(printf '%s' "$creds" | "$JQ" -r '
    .claudeAiOauth // {} | [ ((.accessToken // "") != ""), ((.expiresAt // 0) / 1000 | floor),
      (.subscriptionType // "?") ] | map(tostring) | join("|")' 2>/dev/null)"
  if [ "${tok_has:-}" != "true" ]; then
    bad "No Claude Code token in the Keychain — sign in to Claude Code (/login)." \
        "В Keychain нет токена Claude Code — войдите в Claude Code (/login)."
  elif [ "${tok_exp:-0}" -gt 0 ] && [ "$tok_exp" -le "$NOW" ]; then
    bad "Keychain token (plan ${tok_plan}) expired $(ago $(( NOW - tok_exp ))) ago — Claude Code renews it when it runs." \
        "Токен в Keychain (план ${tok_plan}) истёк $(ago $(( NOW - tok_exp ))) назад — Claude Code обновит его при запуске."
  else
    ok "Keychain token: present, plan ${tok_plan}" "Токен в Keychain: есть, план ${tok_plan}"
  fi
  oauth_key=$(printf '%s' "$OAUTH_ACCOUNT" | awk -F: 'NF { print substr($1, 1, 8) "-" substr($2, 1, 8) }')
  if [ "$ACCOUNT_UNKNOWN" = "1" ]; then
    bad "Account: unknown — ~/.claude.json does not parse and the token's account is not known yet; checks are skipped until it does." \
        "Аккаунт: не определён — ~/.claude.json не читается, а аккаунт токена ещё не известен; проверки пропускаются, пока файл не прочитается."
  elif [ -n "$TOKEN_ACCOUNT" ] && [ -n "$OAUTH_ACCOUNT" ] && [ "$TOKEN_ACCOUNT" != "$OAUTH_ACCOUNT" ]; then
    bad "Account: $ACCOUNT_KEY by the Keychain token, but ~/.claude.json names $oauth_key — normal for a moment after switching accounts; if it lasts, sign in again (/login)." \
        "Аккаунт: $ACCOUNT_KEY по токену в Keychain, а в ~/.claude.json — $oauth_key. Сразу после смены аккаунта это нормально; если не проходит — войдите заново (/login)."
  elif [ -n "$TOKEN_ACCOUNT" ]; then
    ok "Account: $ACCOUNT_KEY" "Аккаунт: $ACCOUNT_KEY"
  elif [ -n "$ACCOUNT_KEY" ]; then
    ok "Account: $ACCOUNT_KEY (from ~/.claude.json; the token's own account is looked up on the next check)" \
       "Аккаунт: $ACCOUNT_KEY (по ~/.claude.json; аккаунт самого токена уточнится при следующей проверке)"
  else
    info "Account: unknown (no oauthAccount in ~/.claude.json) — state is shared by every sign-in." \
         "Аккаунт: не определён (в ~/.claude.json нет oauthAccount) — состояние общее для всех входов."
  fi

  cache_mtime=$(stat -f %m "$CACHE" 2>/dev/null || echo 0)
  if [ ! -f "$CACHE" ]; then
    bad "No usage data has been fetched yet." "Данные о лимитах ещё ни разу не получены."
  elif ! cache_is_mine; then
    bad "The cache belongs to another account; the next check refreshes it." \
        "Кэш принадлежит другому аккаунту; следующая проверка обновит его."
  elif [ $(( NOW - cache_mtime )) -lt 900 ]; then
    ok "Last data: $(ago $(( NOW - cache_mtime ))) ago" "Последние данные: $(ago $(( NOW - cache_mtime ))) назад"
  else
    bad "Last data: $(ago $(( NOW - cache_mtime ))) ago — checks have not succeeded since." \
        "Последние данные: $(ago $(( NOW - cache_mtime ))) назад — с тех пор проверки не удавались."
  fi
  if backoff_active; then
    bad "Live requests paused until $(date -r "$(backoff_until)" +%H:%M) after an error response (401/403/429)." \
        "Запросы приостановлены до $(date -r "$(backoff_until)" +%H:%M) после ответа с ошибкой (401/403/429)."
  fi
  # The last failure, if nothing has succeeded since — by its cause. A failed
  # check logs the cause first (an HTTP code, no token) and then why the
  # local fallback did not help either; during a pause only the fallback line
  # repeats, along with the agent's "paused until" notes. Those say nothing
  # about why, and the pause has its own line above, so they are skipped
  # unless the cause is older than the last success.
  log_time() { date -jf '%Y-%m-%d %H:%M:%S' "$(printf '%s' "$1" | cut -c1-19)" +%s 2>/dev/null || echo 0; }
  last_fail=$(grep 'fetch failed' "$LOG" 2>/dev/null \
    | grep -v -e 'fetch failed: fallback ' -e 'fetch failed: rate limited, live requests paused' | tail -n 1)
  if [ -z "$last_fail" ] || [ "$(log_time "$last_fail")" -le "$cache_mtime" ]; then
    last_fail=$(grep 'fetch failed' "$LOG" 2>/dev/null | tail -n 1)
  fi
  if [ -n "$last_fail" ]; then
    fail_at=$(log_time "$last_fail")
    if [ "$fail_at" -gt "$cache_mtime" ]; then
      bad "Last failed check: ${last_fail#*fetch failed: } ($(date -r "$fail_at" '+%d.%m %H:%M'))" \
          "Последняя неудачная проверка: ${last_fail#*fetch failed: } ($(date -r "$fail_at" '+%d.%m %H:%M'))"
    fi
  fi

  if [ -s "$HISTORY" ]; then
    hist_n=$(wc -l < "$HISTORY" | tr -d ' ')
    hist_first=$(head -n 1 "$HISTORY" | "$JQ" -r '.t // 0' 2>/dev/null || echo 0)
    # 1 замер, 2 замера, 5 замеров (11–14 always take the last form).
    case "$(( hist_n % 100 ))" in
      11|12|13|14) hist_ru="замеров" ;;
      *) case "$(( hist_n % 10 ))" in 1) hist_ru="замер" ;; 2|3|4) hist_ru="замера" ;; *) hist_ru="замеров" ;; esac ;;
    esac
    if [ "$hist_n" -eq 1 ]; then hist_en="reading"; else hist_en="readings"; fi
    ok "History: $hist_n $hist_en over $(ago $(( NOW - hist_first )))" \
       "История: $hist_n $hist_ru за $(ago $(( NOW - hist_first )))"
  else
    info "History: none yet — forecasts start once readings accumulate." \
         "История: пока пуста — прогноз появится, когда накопятся замеры."
  fi

  PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
  if [ -f "$PLIST" ]; then
    interval=$(plutil -extract StartInterval raw "$PLIST" 2>/dev/null || echo "?")
    if [ "${UM_NO_LAUNCHCTL:-0}" = "1" ] || launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
      ok "Background agent: on, every ${interval} s" "Фоновый агент: включён, каждые ${interval} с"
    else
      bad "Background agent: $PLIST exists but is not loaded." \
          "Фоновый агент: $PLIST есть, но не загружен."
    fi
  else
    info "Background agent: off — limits are checked on turns and by the statusline." \
         "Фоновый агент: выключен — лимиты проверяются на ходах и statusline."
  fi

  sl_cmd=$("$JQ" -r '.statusLine.command // ""' "$SETTINGS" 2>/dev/null)
  case "$INSTALL:$sl_cmd" in
    classic:*statusline-with-limits*|plugin:*"$DIR/bin/statusline.sh"*)
      ok "Statusline: on" "Statusline: включена" ;;
    *) info "Statusline: off" "Statusline: выключена" ;;
  esac

  classic_hooks=$("$JQ" -r '[.hooks // {} | .[]? | .[]? | .hooks[]? | .command // ""
    | select(contains("usage-monitor.sh"))] | length' "$SETTINGS" 2>/dev/null || echo 0)
  plugin_on=$("$JQ" -r '[.enabledPlugins // {} | to_entries[]
    | select((.key | startswith("limit-alerts@")) and .value == true)] | length' "$SETTINGS" 2>/dev/null || echo 0)
  if [ "$INSTALL" = "classic" ] && [ "${classic_hooks:-0}" -eq 0 ]; then
    bad "Hooks are not registered in ~/.claude/settings.json — re-run install.sh." \
        "Хуки не зарегистрированы в ~/.claude/settings.json — запустите install.sh ещё раз."
  fi
  if [ "${classic_hooks:-0}" -gt 0 ] && [ "${plugin_on:-0}" -gt 0 ]; then
    bad "Both the plugin and install.sh are active — every notification arrives twice. Run uninstall.sh to keep the plugin." \
        "Активны и плагин, и install.sh — каждое уведомление приходит дважды. Запустите uninstall.sh, чтобы остался плагин."
  fi

  # A session keeps the plugin version it started with (see
  # plugin-bootstrap.sh): the copies in bin/ may be newer than this script.
  if [ "$INSTALL" = "plugin" ] && [ -n "${VERSION_FILE:-}" ] && [ -f "$DIR/bin/.version" ]; then
    own_v=$(cat "$VERSION_FILE"); bin_v=$(cat "$DIR/bin/.version")
    if [ "$own_v" != "$bin_v" ] && \
       [ "$(printf '%s\n%s\n' "$own_v" "$bin_v" | sort -V | head -n 1)" = "$own_v" ]; then
      bad "This session runs plugin $own_v, $bin_v is installed — restart the session." \
          "Эта сессия работает на плагине $own_v, установлен $bin_v — перезапустите сессию."
    fi
  fi
  # Other sessions on an older version, within the last hour: those new enough
  # to skip their checks leave .stale-session; older ones still write, and
  # their log lines carry no version.
  if [ "$INSTALL" = "plugin" ]; then
    stale_at=$(stat -f %m "$DIR/.stale-session" 2>/dev/null || echo 0)
    if [ $(( NOW - stale_at )) -lt 3600 ]; then
      stale_v=$(cat "$DIR/.stale-session" 2>/dev/null)
      bad "Sessions on plugin ${stale_v:-?} are still open; their checks are skipped, so they show no warnings — restart them." \
          "Открыты сессии на плагине ${stale_v:-?}: их проверки пропускаются, предупреждений в них не будет — перезапустите их."
    fi
    old_line=$(tail -n 500 "$LOG" 2>/dev/null | grep -E '^[0-9-]+ [0-9:]+ \[(hook|cron)\] ' | tail -n 1)
    if [ -n "$old_line" ] && [ $(( NOW - $(log_time "$old_line") )) -lt 3600 ]; then
      bad "A session on an older plugin version still writes the shared state (it can repeat warnings) — restart sessions opened before the update." \
          "Сессия на старой версии плагина ещё пишет общее состояние (может повторять уведомления) — перезапустите сессии, открытые до обновления."
    fi
  fi

  if [ "${2:-}" = "--notify" ]; then
    notify_mac "$(notif_title)" "$(tr_ "Test notification" "Тестовое уведомление")"
    info "Test notification sent. No banner? Allow notifications for 'Script Editor' in System Settings → Notifications." \
         "Тестовое уведомление отправлено. Баннера нет — разрешите уведомления для «Script Editor» в Настройках → Уведомления."
  else
    info "Banners can't be checked from here: 'doctor --notify' sends a test one." \
         "Баннеры отсюда не проверить: 'doctor --notify' пришлёт тестовый."
  fi
  exit 0
fi

if ! USAGE=$(fetch_usage); then
  [ "$MODE" = "status" ] || exit 0
  next_en=""; next_ru=""
  if backoff_active; then
    next_at=$(date -r "$(backoff_until)" '+%H:%M')
    next_en=" Rate limited, next attempt at ${next_at}."
    next_ru=" Запросы ограничены, следующая попытка в ${next_at}."
  fi
  if cache_is_mine && [ -s "$CACHE" ] && "$JQ" -e '.limits' "$CACHE" >/dev/null 2>&1; then
    USAGE=$(cat "$CACHE")
    cache_mtime=$(stat -f %m "$CACHE" 2>/dev/null || echo 0)
    age_min=$(( ($(date +%s) - cache_mtime) / 60 ))
    if [ "$age_min" -lt 60 ]; then
      age_ru="${age_min} мин"; age_en="${age_min} min"
    else
      age_ru="$(( age_min / 60 )) ч"; age_en="$(( age_min / 60 )) h"
    fi
    cache_at=$(date -r "$cache_mtime" "+%d.%m %H:%M")
    if [ "$LANG_UM" = "en" ]; then
      echo "⚠ No live data — showing the cache from ${cache_at} (${age_en} ago).${next_en} Details: $LOG"
    else
      echo "⚠ Свежих данных нет — показан кэш от ${cache_at} (${age_ru} назад).${next_ru} Подробности: $LOG"
    fi
  else
    # Why there is nothing to show: no cache at all, a cache that is another
    # account's (or untagged, from before the account was known), or no way to
    # tell whose a cache is.
    if [ "$ACCOUNT_UNKNOWN" = "1" ]; then
      why_en="the account is unknown (~/.claude.json does not parse), so no cache can be trusted"
      why_ru="аккаунт не определён (~/.claude.json не читается), поэтому кэшу нельзя доверять"
    elif [ -f "$CACHE" ] && ! cache_is_mine; then
      why_en="the cache belongs to another account; the next successful check replaces it"
      why_ru="кэш принадлежит другому аккаунту; следующая удачная проверка заменит его"
    else
      why_en="there is no cache yet"
      why_ru="кэша ещё нет"
    fi
    if [ "$LANG_UM" = "en" ]; then
      echo "No usage data: the request failed and ${why_en}.${next_en} Details: $LOG"
    else
      echo "Нет данных о лимитах: запрос не удался, а ${why_ru}.${next_ru} Подробности: $LOG"
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
  # A forecast is made from live numbers only: the history's last reading is
  # as old as the stale cache, and a pace from then is not the pace now.
  FORECASTS=""
  [ -z "${cache_at:-}" ] && FORECASTS=$(forecasts)
  while IFS='|' read -r kind percent resets scope; do
    [ -n "$kind" ] || continue
    reset_epoch=$(to_epoch "$resets")
    # No resets_at: no window is open (the 5-hour one starts with the first
    # message after the last one ended), so there is no reset to show.
    if [ -z "$reset_epoch" ]; then
      if [ "$LANG_UM" = "en" ]; then reset_part="no window open"; else reset_part="окно не открыто"; fi
    elif [ "$LANG_UM" = "en" ]; then
      reset_part="resets: $(date -r "$reset_epoch" "+%d.%m %H:%M")"
    else
      reset_part="сброс: $(date -r "$reset_epoch" "+%d.%m %H:%M")"
    fi
    # From a stale cache, a window whose reset time has already passed has
    # rolled over since: its percent no longer says anything, so say so.
    passed=""
    if [ -n "${cache_at:-}" ] && [ -n "$reset_epoch" ] && [ "$reset_epoch" -le "$(date +%s)" ]; then
      if [ "$LANG_UM" = "en" ]; then passed=" (already reset)"; else passed=" (уже сброшен)"; fi
    fi
    extra=""
    if [ -z "$passed" ]; then
      expected=$(pace_expected "$kind" "$reset_epoch")
      if [ -n "$expected" ]; then
        if [ "$LANG_UM" = "en" ]; then extra="  · on pace: ${expected}%"; else extra="  · по графику ${expected}%"; fi
        # 5 or more points behind: say how much would reset unused.
        projected=$(pace_projected "$kind" "$reset_epoch" "$percent")
        if [ -n "$projected" ] && [ $(( ${percent%%.*} + 5 )) -le "$expected" ] && [ "$projected" -lt 100 ]; then
          if [ "$LANG_UM" = "en" ]; then extra="$extra  · ~${projected}% by reset ($(( 100 - projected ))% left unused)"
          else extra="$extra  · к сбросу ~${projected}% (останется $(( 100 - projected ))%)"; fi
        fi
      fi
      eta=$(forecast_for "$kind" "$FORECASTS")
      if [ -n "$eta" ]; then
        if [ "$LANG_UM" = "en" ]; then extra="$extra  · runs out ~$(fmt_when "$eta")"
        else extra="$extra  · кончится ~$(fmt_when "$eta")"; fi
      fi
    fi
    printf "%s %3s%%  %s%s%s\n" "$(pad_right "$(label_for "$kind" "$scope")" 22)" "$percent" "$reset_part" "$passed" "$extra"
  done <<< "$LIMITS"

  # The week split by product. These are shares of what was spent, summing
  # to 100 — not shares of the limit — and the line says so. Only with two
  # products or more: "Claude Code 100%" says nothing.
  BREAKDOWN=$(echo "$USAGE" | "$JQ" -r --arg lang "$LANG_UM" '
    def name: if $lang == "en" then (.display_name // .key)
      else ({claude_code: "Claude Code", chat: "чаты", cowork: "Cowork", other: "прочее"}[.key]
            // .display_name // .key) end;
    [ .seven_day_breakdown.rows[]? | select((.percent | type) == "number" and .percent > 0)
      | "\(name) \(.percent | floor)%" ] | select(length >= 2) | join(", ")' 2>/dev/null)
  if [ -n "$BREAKDOWN" ]; then
    if [ "$LANG_UM" = "en" ]; then echo "Weekly usage by product: $BREAKDOWN"
    else echo "Расход недели по продуктам: $BREAKDOWN"; fi
  fi

  # Paid credits, only once any are spent: a "$0.00" line on every status
  # would be noise for everyone who never goes past the plan.
  IFS='|' read -r sp_minor sp_exp sp_cur sp_pct <<< "$(echo "$USAGE" | "$JQ" -r '
    .spend // empty | select((.used.amount_minor | type) == "number" and .used.amount_minor > 0)
    | [ .used.amount_minor, (.used.exponent // 2), (.used.currency // ""), ((.percent // 0) | floor) ]
    | map(tostring) | join("|")' 2>/dev/null)"
  if [ -n "${sp_minor:-}" ]; then
    if [ "$LANG_UM" = "en" ]; then
      echo "Paid usage credits: $(fmt_money "$sp_minor" "$sp_exp" "$sp_cur") (${sp_pct}% of the spending limit)"
    else
      echo "Платные usage credits: $(fmt_money "$sp_minor" "$sp_exp" "$sp_cur") (${sp_pct}% лимита расходов)"
    fi
  fi
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

# A state that is not a JSON object — empty after a run killed mid-write, cut
# short by a full disk, edited by hand — starts over from {}. Read as it was,
# every field came out empty, every threshold test failed, and the same empty
# state was written back: no notification ever again.
NEW_STATE=$("$JQ" -c 'if type == "object" then . else error end' "$STATE" 2>/dev/null) || NEW_STATE=""
if [ -z "$NEW_STATE" ]; then
  [ -s "$STATE" ] && log_note "state unreadable, starting over: $STATE"
  NEW_STATE='{}'
fi
MESSAGES=()
FORECASTS=""
[ "$FORECAST" = "1" ] && FORECASTS=$(forecasts)
UNUSED_LEAD=86400 # the unused-limit notice: the last day of a weekly window
UNUSED_MIN=20     # and at least this many points that would go unused
# Another model is a way out of a model-scoped limit only while the limit for
# all models still has room.
ALL_PCT=$(printf '%s\n' "$LIMITS" | awk -F'|' '$1 == "weekly_all" { print int($2); exit }')

while IFS='|' read -r kind percent resets scope; do
  [ -n "$kind" ] || continue
  pct=${percent%%.*}
  key="$kind"
  # Each field falls back to its default unless it has the right type, so one
  # bad value cannot turn the threshold tests below into shell errors.
  IFS='|' read -r prev_resets prev_pct notified forecast unused <<< "$(echo "$NEW_STATE" | "$JQ" -r --arg k "$key" '
    def num: if type == "number" then floor else 0 end;
    .[$k] | (if type == "object" then . else {} end)
    | [ (.resets_at | if type == "string" then . else "" end),
        (.percent | num), (.notified | num), (.forecast | num), (.unused | num) ]
    | map(tostring) | join("|")')"
  label=$(label_for "$kind" "$scope")

  # window rollover: resets_at moved by more than 2 min. The API recomputes
  # resets_at on every request with ±1s jitter, so a plain string comparison
  # produces false "reset" alerts and re-arms threshold notifications.
  # A window also cannot end before its own reset time. When resets_at moves
  # while the stored one is still ahead, the numbers came from somewhere else
  # — another account's token, a session on an older version of this script —
  # and announcing that as a reset sent "♻️ was 97%, now 26%" in the middle of
  # a week and re-armed every warning. Such a reading says nothing, and its
  # thresholds count as already announced at the level it is at — silent now,
  # a later crossing still fires (keeping the old level could mute a window
  # for good).
  if [ -n "$prev_resets" ]; then
    e_prev=$(to_epoch "$prev_resets" || echo 0)
    e_cur=$(to_epoch "$resets" || echo 0)
    diff=$(( e_cur - e_prev )); [ "$diff" -lt 0 ] && diff=$(( -diff ))
    if [ "$diff" -gt 120 ] && [ "${e_prev:-0}" -gt 0 ] && [ "$(date +%s)" -lt $(( e_prev - 120 )) ]; then
      log_note "$kind: resets_at moved from $prev_resets to ${resets:-none} before it was due — another source, not a reset"
      if [ "$pct" -ge "$CRIT" ]; then notified=$CRIT; elif [ "$pct" -ge "$WARN" ]; then notified=$WARN; else notified=0; fi
    elif [ "$diff" -gt 120 ]; then
      # the window really rolled over; announce only if usage actually dropped
      if [ "${prev_pct%%.*}" -ge "$RESET_MIN" ] && [ "$pct" -lt "${prev_pct%%.*}" ]; then
        MESSAGES+=("$(msg_reset "$label" "${prev_pct%%.*}" "$pct")")
      fi
      notified=0
      forecast=0
      unused=0
    fi
  fi

  # thresholds: one notification per threshold per window
  if [ "$pct" -ge "$CRIT" ] && [ "$notified" -lt "$CRIT" ]; then
    MESSAGES+=("$(msg_crit "$label" "$pct" "$(fmt_when "$(to_epoch "$resets")")")")
    if [ "$MODEL_HINT" = "1" ] && [ "$kind" = "weekly_scoped" ] && [ "${ALL_PCT:-0}" -lt "$CRIT" ]; then
      MESSAGES+=("$(msg_model_hint)")
    fi
    notified=$CRIT
  elif [ "$pct" -ge "$WARN" ] && [ "$notified" -lt "$WARN" ]; then
    MESSAGES+=("$(msg_warn "$label" "$pct" "$(fmt_when "$(to_epoch "$resets")")")")
    notified=$WARN
  fi

  # forecast: once per window, and not once the window is at CRIT — "almost
  # exhausted" has already said it.
  if [ "$FORECAST" = "1" ] && [ "$forecast" = "0" ] && [ "$notified" -lt "$CRIT" ]; then
    eta=$(forecast_for "$kind" "$FORECASTS")
    if [ -n "$eta" ]; then
      MESSAGES+=("$(msg_forecast "$label" "$pct" "$(fmt_when "$eta")" "$(fmt_when "$(to_epoch "$resets")")")")
      forecast=1
    fi
  fi

  # unused: a subscription is paid for whether it is used or not. In the last
  # UNUSED_LEAD seconds of a weekly window, if at the pace so far (the same
  # projection status shows) at least UNUSED_MIN points would reset unused,
  # say so once — early enough to still use them, and only once a week.
  if [ "$UNUSED_ALERT" = "1" ] && [ "$unused" = "0" ]; then
    reset_epoch=$(to_epoch "$resets")
    if [ -n "$reset_epoch" ] && [ $(( reset_epoch - $(date +%s) )) -gt 0 ] && \
       [ $(( reset_epoch - $(date +%s) )) -le "$UNUSED_LEAD" ]; then
      projected=$(pace_projected "$kind" "$reset_epoch" "$pct")
      if [ -n "$projected" ] && [ $(( 100 - projected )) -ge "$UNUSED_MIN" ]; then
        MESSAGES+=("$(msg_unused "$label" "$pct" "$(fmt_when "$reset_epoch")" "$(( 100 - projected ))")")
        unused=1
      fi
    fi
  fi

  # A failed update keeps the previous state rather than emptying it.
  upd=$(echo "$NEW_STATE" | "$JQ" --arg k "$key" --argjson p "$pct" --arg r "$resets" --argjson n "$notified" \
    --argjson f "$forecast" --argjson u "$unused" \
    '.[$k] = {percent: $p, resets_at: $r, notified: $n, forecast: $f, unused: $u}' 2>/dev/null) && NEW_STATE="$upd"
done <<< "$LIMITS"

# Paid usage credits: money is being spent once the plan's limits are used
# up. Said when spending starts, then at WARN and CRIT percent of the spending
# limit. The amount only grows within a billing period, so a smaller one
# means a new period and re-arms all three.
if [ "$SPEND_ALERT" = "1" ]; then
  IFS='|' read -r sp_minor sp_exp sp_cur sp_pct <<< "$(echo "$USAGE" | "$JQ" -r '
    .spend // empty | select((.used.amount_minor | type) == "number")
    | [ .used.amount_minor, (.used.exponent // 2), (.used.currency // ""), ((.percent // 0) | floor) ]
    | map(tostring) | join("|")' 2>/dev/null)"
  if [ -n "${sp_minor:-}" ]; then
    IFS='|' read -r sp_prev sp_notified <<< "$(echo "$NEW_STATE" | "$JQ" -r '
      def num: if type == "number" then floor else 0 end;
      ._spend | (if type == "object" then . else {} end)
      | [ (.amount_minor | num), (.notified | num) ] | map(tostring) | join("|")')"
    [ "$sp_minor" -lt "$sp_prev" ] && sp_notified=0
    sp_amount=$(fmt_money "$sp_minor" "$sp_exp" "$sp_cur")
    if [ "$sp_pct" -ge "$CRIT" ] && [ "$sp_notified" -lt "$CRIT" ]; then
      MESSAGES+=("$(msg_spend_level "$sp_amount" "$sp_pct")"); sp_notified=$CRIT
    elif [ "$sp_pct" -ge "$WARN" ] && [ "$sp_notified" -lt "$WARN" ]; then
      MESSAGES+=("$(msg_spend_level "$sp_amount" "$sp_pct")"); sp_notified=$WARN
    elif [ "$sp_minor" -gt 0 ] && [ "$sp_notified" -lt 1 ]; then
      MESSAGES+=("$(msg_spend_start "$sp_amount")"); sp_notified=1
    fi
    upd=$(echo "$NEW_STATE" | "$JQ" --argjson a "$sp_minor" --argjson n "$sp_notified" \
      '._spend = {amount_minor: $a, notified: $n}' 2>/dev/null) && NEW_STATE="$upd"
  fi
fi

# Written whole or not at all: a temporary file beside it, then a rename, so a
# run killed mid-write leaves the previous state instead of an empty file.
if printf '%s' "$NEW_STATE" | "$JQ" -e 'type == "object"' >/dev/null 2>&1; then
  printf '%s\n' "$NEW_STATE" > "$STATE.$$.tmp" 2>/dev/null && mv -f "$STATE.$$.tmp" "$STATE" 2>/dev/null \
    || rm -f "$STATE.$$.tmp"
fi

if [ "${#MESSAGES[@]}" -gt 0 ]; then
  BODY=$(printf '%s\n' "${MESSAGES[@]}")
  echo "$(date '+%F %T') [$MODE${OWN_VERSION:+ v$OWN_VERSION}] ${BODY//$'\n'/ | }" >> "$LOG"
  notify_mac "$(notif_title)" "$BODY"
  if [ "$MODE" = "hook" ]; then
    "$JQ" -n --arg msg "$BODY" '{systemMessage: $msg}'
  fi
fi
exit 0
