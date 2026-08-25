#!/usr/bin/env bash
# compact-advisor.sh — tells you when it is a good moment to run /compact.
#
# Called from the Claude Code Stop hook; the event JSON arrives on stdin.
#
# A hook cannot run /compact itself: the hook output schema is limited to
# systemMessage / continue / stopReason / decision / reason /
# hookSpecificOutput, with no compaction verb, and /compact is not exposed to
# the model as a tool. So this is a signal, deliberately delivered at a
# logical breakpoint, where compacting costs the least context.
#
# It speaks up only when all three hold:
#   1. context >= UM_COMPACT_WARN percent of the window
#   2. the last assistant message contains no tool_use (the turn ended with an
#      answer, not in the middle of an edit)
#   3. no unfinished tasks in ~/.claude/tasks/<session_id>/
#
# One signal per 10-point step (70 / 80 / 90) per session.
#
# Environment overrides:
#   UM_COMPACT_WARN=70  UM_CONTEXT_WINDOW=200000  UM_LANG=ru|en

set -u

WARN="${UM_COMPACT_WARN:-70}"
LANG_UM="${UM_LANG:-ru}"
DIR="$HOME/.claude/scripts"
STATE="$DIR/compact-advisor-state.json"
SETTINGS="$HOME/.claude/settings.json"

JQ="$(command -v jq || echo /opt/homebrew/bin/jq)"
[ -x "$JQ" ] || exit 0

input=$(cat 2>/dev/null) || exit 0
[ -n "$input" ] || exit 0

sid=$(printf '%s' "$input" | "$JQ" -r '.session_id // empty' 2>/dev/null) || exit 0
tp=$(printf '%s' "$input" | "$JQ" -r '.transcript_path // empty' 2>/dev/null) || exit 0
[ -n "$sid" ] || exit 0
[ -n "$tp" ] && [ -f "$tp" ] || exit 0

# Last assistant message: context size and whether the turn ended with a tool
# call. Both come from the same record, so they cannot disagree. The context
# size is the full input of that request: fresh input + cache reads + cache
# writes.
info=$(tail -n 400 "$tp" | "$JQ" -s -r '
  [ .[] | select(.type == "assistant" and (.message.usage != null)) ] | last
  | if . == null then "" else
      ((.message.usage
        | ((.input_tokens // 0) + (.cache_read_input_tokens // 0)
           + (.cache_creation_input_tokens // 0))) | tostring)
      + "|"
      + (if ((.message.content // []) | map(select(.type == "tool_use")) | length) > 0
         then "1" else "0" end)
    end' 2>/dev/null) || exit 0
[ -n "$info" ] || exit 0

tokens="${info%%|*}"
has_tool="${info##*|}"
case "$tokens" in ''|*[!0-9]*) exit 0 ;; esac
[ "$tokens" -gt 0 ] || exit 0

# condition 2: the turn ended with an answer, not mid-edit
[ "$has_tool" = "0" ] || exit 0

# condition 3: no unfinished tasks for this session
tasks_dir="$HOME/.claude/tasks/$sid"
if [ -d "$tasks_dir" ]; then
  for f in "$tasks_dir"/*.json; do
    [ -f "$f" ] || continue
    st=$("$JQ" -r '.status // "completed"' "$f" 2>/dev/null) || st="completed"
    [ "$st" = "completed" ] || exit 0
  done
fi

# Denominator: the user's own autoCompactWindow when set, so the percentage
# refers to where the built-in compaction will actually fire.
window="${UM_CONTEXT_WINDOW:-200000}"
if [ -f "$SETTINGS" ]; then
  cfg=$("$JQ" -r '.autoCompactWindow // empty' "$SETTINGS" 2>/dev/null) || cfg=""
  case "$cfg" in ''|*[!0-9]*) ;; *) window="$cfg" ;; esac
fi
[ "$window" -gt 0 ] || exit 0

pct=$(( tokens * 100 / window ))

# condition 1: threshold
[ "$pct" -ge "$WARN" ] || exit 0

# one signal per 10-point step per session
step=$(( pct / 10 * 10 ))
# A missing OR corrupt state file is treated the same way: recover to a
# clean object instead of leaving anti-spam permanently disabled. Without
# this, one bad write (interrupted, or a race between two hook invocations
# sharing this single global path across Claude Code windows) would corrupt
# the file forever — every future jq read would fail, prev would fall back
# to 0, and the hook would fire on every single turn past the threshold
# instead of once per 10-point step.
current='{}'
if [ -f "$STATE" ]; then
  existing=$(cat "$STATE" 2>/dev/null) || existing=""
  if [ -n "$existing" ] && printf '%s' "$existing" | "$JQ" -e . >/dev/null 2>&1; then
    current="$existing"
  fi
fi
prev=$(printf '%s' "$current" | "$JQ" -r --arg s "$sid" '.[$s].step // 0' 2>/dev/null) || prev=0
case "$prev" in ''|*[!0-9]*) prev=0 ;; esac
[ "$step" -gt "$prev" ] || exit 0

now=$(date +%s)
cutoff=$(( now - 604800 ))
new_state=$(printf '%s' "$current" | "$JQ" --arg s "$sid" --argjson st "$step" --argjson n "$now" --argjson c "$cutoff" '
    with_entries(select((.value.at // 0) > $c)) | .[$s] = {step: $st, at: $n}
  ' 2>/dev/null) || new_state=""
# Atomic write, matching the tmp+mv pattern in usage-monitor.sh — an
# interrupted write never leaves $STATE half-written or corrupt.
if [ -n "$new_state" ]; then
  printf '%s\n' "$new_state" > "$STATE.tmp" 2>/dev/null && mv "$STATE.tmp" "$STATE"
fi

tok_k=$(( tokens / 1000 ))
win_k=$(( window / 1000 ))
if [ "$LANG_UM" = "en" ]; then
  body="🧹 Context ${pct}% (${tok_k}k/${win_k}k). Good moment for /compact — the stage is closed."
  [ "$prev" -eq 0 ] && body="$body Compact earlier: /config -> Auto-compact window."
else
  body="🧹 Контекст ${pct}% (${tok_k}k/${win_k}k). Хороший момент для /compact — этап закрыт."
  [ "$prev" -eq 0 ] && body="$body Сжимать раньше: /config -> Auto-compact window."
fi

afplay "/System/Library/Sounds/Glass.aiff" >/dev/null 2>&1 || true
osascript -e 'on run argv' \
  -e 'display notification (item 1 of argv) with title "Claude Code"' \
  -e 'end run' -- "$body" >/dev/null 2>&1 || true

"$JQ" -n --arg msg "$body" '{systemMessage: $msg}'
exit 0
