#!/usr/bin/env bash
# statusline-with-limits.sh — Claude Code statusline with usage limits.
#
# Renders:  <your existing statusline> | 5h 66% · 7d 7% · Fable 4%
#
# Reads percentages from the usage-monitor cache only — no network calls,
# so the statusline stays fast. The cache is refreshed by the launchd agent
# and by the usage-monitor hooks.
#
# If ~/.claude/scripts/statusline-base.cmd exists, its content is executed
# as the base statusline command (stdin JSON is passed through). Without it
# only the limits are shown. install.sh preserves your previous statusline
# command into that file automatically.
#
# Colors: green < WARN, yellow >= WARN (80), red >= CRIT (95).
# Environment overrides: UM_WARN, UM_CRIT, UM_LANG=ru|en

INPUT=$(cat)

WARN="${UM_WARN:-80}"
CRIT="${UM_CRIT:-95}"
LANG_UM="${UM_LANG:-ru}"

BASE=""
BASE_CMD_FILE="$HOME/.claude/scripts/statusline-base.cmd"
if [ -f "$BASE_CMD_FILE" ]; then
  BASE=$(echo "$INPUT" | bash -c "$(cat "$BASE_CMD_FILE")" 2>/dev/null)
fi

CACHE="$HOME/.claude/scripts/usage-monitor-cache.json"
JQ="$(command -v jq || echo /opt/homebrew/bin/jq)"

if [ "$LANG_UM" = "en" ]; then L5="5h"; L7="7d"; else L5="5ч"; L7="7д"; fi

LIMITS=""
if [ -f "$CACHE" ] && [ -x "$JQ" ]; then
  read -r s w f <<< "$("$JQ" -r \
    '[(.five_hour.utilization // 0), (.seven_day.utilization // 0),
      ([.limits[]? | select(.kind == "weekly_scoped")][0].percent // -1)] | map(floor) | join(" ")' \
    "$CACHE" 2>/dev/null)"
  if [ -n "$s" ]; then
    colorize() { # percent -> colored "N%"
      if   [ "$1" -ge "$CRIT" ]; then printf '\033[31m%s%%\033[0m' "$1"
      elif [ "$1" -ge "$WARN" ]; then printf '\033[33m%s%%\033[0m' "$1"
      else                            printf '\033[32m%s%%\033[0m' "$1"
      fi
    }
    SEP=""
    [ -n "$BASE" ] && SEP=" \033[2m|\033[0m "
    LIMITS="${SEP}${L5} $(colorize "$s") \033[2m·\033[0m ${L7} $(colorize "$w")"
    # model-scoped weekly limit (-1 = not present in cache, hidden)
    if [ "$f" -ge 0 ] 2>/dev/null; then
      MODEL=$("$JQ" -r '[.limits[]? | select(.kind == "weekly_scoped")][0].scope.model.display_name // ""' "$CACHE" 2>/dev/null)
      [ -n "$MODEL" ] && LIMITS="$LIMITS \033[2m·\033[0m ${MODEL} $(colorize "$f")"
    fi
  fi
fi

printf '%b%b' "$BASE" "$LIMITS"
