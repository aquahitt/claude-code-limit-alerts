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
    | "$JQ" -r '.claudeAiOauth.accessToken // empty') || return 1
  [ -n "$token" ] || return 1
  local resp
  resp=$(curl -sS --max-time 10 https://api.anthropic.com/api/oauth/usage \
    -H "Authorization: Bearer $token" \
    -H "anthropic-beta: oauth-2025-04-20" 2>/dev/null) || return 1
  echo "$resp" | "$JQ" -e '.limits' >/dev/null 2>&1 || return 1
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

  # window rolled over while usage was significant -> reset notification
  if [ -n "$prev_resets" ] && [ "$prev_resets" != "$resets" ]; then
    if [ "${prev_pct%%.*}" -ge "$RESET_MIN" ]; then
      MESSAGES+=("$(msg_reset "$label" "${prev_pct%%.*}" "$pct")")
    fi
    notified=0
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
  notify_mac "$(notif_title)" "$BODY"
  if [ "$MODE" = "hook" ]; then
    "$JQ" -n --arg msg "$BODY" '{systemMessage: $msg}'
  fi
fi
exit 0
