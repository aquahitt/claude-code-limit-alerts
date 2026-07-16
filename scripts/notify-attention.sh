#!/bin/bash
# notify-attention.sh — "Claude Code needs your attention" notifications (macOS).
#
# Called from Claude Code hooks; the event JSON arrives on stdin.
# Argument: notification | stop
#   notification — Claude is waiting for a permission or an answer (sound: Funk)
#   stop         — Claude finished the turn / task is done       (sound: Glass)
#
# The banner identifies the session so you know which terminal to switch to:
#   title:    Claude: <session name or project dir> (<git branch>)
#   subtitle: <last user prompt, truncated>
#   body:     what happened
#
# The sound is played directly via afplay, so it works even when banners are
# not permitted in Notification Center.
#
# Environment overrides: UM_LANG=ru|en

input=$(cat)
event="${1:-notification}"
LANG_UM="${UM_LANG:-ru}"

cwd=$(jq -r '.cwd // empty' <<<"$input" 2>/dev/null)
cwd=${cwd:-$PWD}
proj=$(basename "$cwd")
branch=$(git -C "$cwd" branch --show-current 2>/dev/null)

# Last textual user prompt from the transcript — identifies the session
last=""
tp=$(jq -r '.transcript_path // empty' <<<"$input" 2>/dev/null)
if [[ -n "$tp" && -f "$tp" ]]; then
  last=$(tail -n 500 "$tp" | jq -r '
    select(.type == "user" and .isMeta != true)
    | .message.content
    | if type == "string" then .
      elif type == "array" then (map(select(.type == "text") | .text) | first // empty)
      else empty end' 2>/dev/null \
    | grep -v '^[[:space:]]*<' | grep -v '^$' | tail -1 | tr '\n' ' ' | cut -c1-70)
fi

sid_full=$(jq -r '.session_id // empty' <<<"$input" 2>/dev/null)
sid=${sid_full:0:6}
msg=$(jq -r '.message // empty' <<<"$input" 2>/dev/null)

# Session name (as shown in the tab title) — from live session metadata
sname=""
if [[ -n "$sid_full" ]]; then
  sfile=$(grep -l "$sid_full" "$HOME/.claude/sessions/"*.json 2>/dev/null | head -1)
  [[ -n "$sfile" ]] && sname=$(jq -r '.name // empty' "$sfile" 2>/dev/null)
fi

if [[ "$event" == "stop" ]]; then
  if [[ "$LANG_UM" == "en" ]]; then body="Task finished"; else body="Задача завершена"; fi
  sound="Glass"
else
  if [[ "$LANG_UM" == "en" ]]; then body="${msg:-Needs permission or a reply}"
  else body="${msg:-Нужно разрешение или ответ}"; fi
  sound="Funk"
fi

if [[ "$LANG_UM" == "en" ]]; then sess_word="session"; else sess_word="сессия"; fi
title="Claude: ${sname:-$proj}${branch:+ ($branch)}"
subtitle="${last:-$sess_word ${sid:-?}}"

# Sound — played directly, independent of Notification Center permissions
afplay "/System/Library/Sounds/${sound}.aiff" 2>/dev/null || true

# Banner — works only if Script Editor is allowed in Notification Center
osascript \
  -e 'on run argv' \
  -e 'display notification (item 1 of argv) with title (item 2 of argv) subtitle (item 3 of argv)' \
  -e 'end run' \
  -- "$body" "$title" "$subtitle" 2>/dev/null || true
