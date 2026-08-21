#!/usr/bin/env bash
# auto-resume.sh — waits out an exhausted Claude Code limit and continues the
# interrupted session (macOS).
#
# Usage:
#   auto-resume.sh [session_id] [--prompt "<text>"]
#
# With no session id it takes the last active session recorded by
# usage-monitor.sh (hook mode) in auto-resume-state.json.
#
# It waits until the session window's resets_at, then re-checks the *actual*
# limits before resuming: a weekly limit easily outlives a 5h window, and
# resuming into a still-blocked account would just fail again. When the reset
# is confirmed it replaces itself (exec) with an interactive
# `claude --resume <id> "<prompt>"` in the session's original directory, so
# the session continues in this very terminal, with permission prompts
# working normally. `--prompt ""` (or `UM_RESUME_PROMPT=""`) means resume
# with no first message at all — `claude --resume <id>` with no prompt
# argument — instead of falling back to the default recap prompt.
#
# Environment overrides:
#   UM_RESUME_PROMPT  first message sent to the resumed session (empty string
#                     resumes with no first message, see above)
#   UM_RESUME_MAX_WAIT  seconds to keep waiting after resets_at (default 28800)
#   UM_LANG=ru|en

set -euo pipefail

DIR="$HOME/.claude/scripts"
STATE="$DIR/auto-resume-state.json"
MONITOR="$DIR/usage-monitor.sh"
LANG_UM="${UM_LANG:-ru}"
MAX_WAIT="${UM_RESUME_MAX_WAIT:-28800}"

JQ="$(command -v jq || echo /opt/homebrew/bin/jq)"
if [ ! -x "$JQ" ]; then
  echo "jq is required. Install it with: brew install jq" >&2
  exit 1
fi

if [ "$LANG_UM" = "en" ]; then
  DEFAULT_PROMPT="Continue from where you stopped (the work was interrupted by a usage limit). Start with a one-line recap of where you left off."
else
  DEFAULT_PROMPT="Продолжай с того места, где остановился (работа была прервана лимитом). Сначала кратко скажи, на чём остановился."
fi

say() { # $1 = ru text, $2 = en text
  if [ "$LANG_UM" = "en" ]; then echo "$2"; else echo "$1"; fi
}

SID=""
PROMPT="${UM_RESUME_PROMPT:-$DEFAULT_PROMPT}"
while [ $# -gt 0 ]; do
  case "$1" in
    --prompt)
      [ $# -ge 2 ] || { say "У флага --prompt нет значения." "--prompt requires a value." >&2; exit 1; }
      shift; PROMPT="$1" ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    -*) echo "Unknown flag: $1" >&2; exit 1 ;;
    *) SID="$1" ;;
  esac
  shift
done

# launchd-spawned parents have a bare PATH, and this worker may inherit it —
# same fallback list as resolve_claude_bin() in usage-monitor.sh. Duplicated
# rather than sourced because usage-monitor.sh runs its whole monitoring flow
# at import time.
resolve_claude_bin() {
  command -v claude 2>/dev/null && return 0
  local candidate
  for candidate in "$HOME/.local/bin/claude" /opt/homebrew/bin/claude /usr/local/bin/claude; do
    [ -x "$candidate" ] && { echo "$candidate"; return 0; }
  done
  return 1
}

iso_to_epoch() { # $1 = ISO8601 UTC timestamp
  TZ=UTC date -jf "%Y-%m-%dT%H:%M:%S" "${1%%.*}" "+%s" 2>/dev/null || echo 0
}

# --- resolve the session ------------------------------------------------

if [ ! -f "$STATE" ]; then
  say "Нет данных о сессии ($STATE не найден). Запустите Claude Code хотя бы раз после установки." \
      "No session data ($STATE not found). Run Claude Code at least once after installing." >&2
  exit 1
fi

if [ -z "$SID" ]; then
  SID=$("$JQ" -r '.session_id // ""' "$STATE" 2>/dev/null) || SID=""
fi
if [ -z "$SID" ]; then
  say "В состоянии нет session_id — нечего продолжать." \
      "No session_id in state — nothing to resume." >&2
  exit 1
fi

CWD=$("$JQ" -r '.cwd // ""' "$STATE" 2>/dev/null) || CWD=""
TRANSCRIPT=$("$JQ" -r '.transcript_path // ""' "$STATE" 2>/dev/null) || TRANSCRIPT=""
RESETS=$("$JQ" -r '.resets_at // ""' "$STATE" 2>/dev/null) || RESETS=""

if [ -z "$CWD" ] || [ ! -d "$CWD" ]; then
  say "Рабочая директория сессии не найдена: ${CWD:-<пусто>}" \
      "Session working directory not found: ${CWD:-<empty>}" >&2
  exit 1
fi
if [ -n "$TRANSCRIPT" ] && [ ! -f "$TRANSCRIPT" ]; then
  say "Транскрипт сессии не найден: $TRANSCRIPT" \
      "Session transcript not found: $TRANSCRIPT" >&2
  exit 1
fi

CLAUDE_BIN=$(resolve_claude_bin) || {
  say "Не найден исполняемый файл claude." "claude binary not found." >&2
  exit 1
}

# --- lock ---------------------------------------------------------------

LOCK="$DIR/auto-resume-$SID.lock"
if [ -f "$LOCK" ]; then
  OTHER=$(cat "$LOCK" 2>/dev/null) || OTHER=""
  if [ -n "$OTHER" ] && kill -0 "$OTHER" 2>/dev/null; then
    say "Эту сессию уже ждёт другой воркер (pid $OTHER)." \
        "Another worker is already waiting for this session (pid $OTHER)." >&2
    exit 1
  fi
  rm -f "$LOCK"
fi
echo $$ > "$LOCK"
trap 'rm -f "$LOCK"' EXIT INT TERM

# --- wait for the reset time -------------------------------------------

TARGET=$(iso_to_epoch "$RESETS")
if [ "$TARGET" -gt 0 ]; then
  while :; do
    NOW=$(date +%s)
    [ "$NOW" -ge "$TARGET" ] && break
    REMAIN=$(( TARGET - NOW ))
    printf '\r%s %02d:%02d   ' \
      "$(say "⏳ до сброса лимита" "⏳ until limit reset")" \
      $(( REMAIN / 3600 )) $(( (REMAIN % 3600) / 60 ))
    sleep 60
  done
  printf '\n'
fi

# --- confirm the reset against real data, not the clock -----------------

# Ready when the session limit dropped below 95% AND no other limit
# (weekly_all / weekly_scoped) is at 100%. UM_CACHE_TTL=0 forces a live
# fetch: fetch_usage() otherwise serves usage-monitor-cache.json for up to
# CACHE_TTL seconds in every mode except cron.
#
# Return codes distinguish "genuinely still limited" from "could not read
# limits data at all" (missing/broken usage-monitor.sh, expired token, a 403
# on a Team account, no fallback available) — the two must never share a
# message, or the user is told a limit is busy when we simply have no data.
# READY_REASON carries the diagnostic for the caller to report. An unreadable
# condition keeps waiting rather than exiting immediately: it is frequently
# transient (an expired token refreshes the next time Claude Code itself
# runs), and this worker already has a MAX_WAIT ceiling.
#   0 = ready, 1 = genuinely still limited, 2 = could not read limits data
READY_REASON=""
limits_ready() {
  local out kind pct rest sess=100 blocked=0 status=0
  out=$(UM_CACHE_TTL=0 bash "$MONITOR" limits 2>/dev/null) || status=$?
  if [ "$status" -ne 0 ]; then
    READY_REASON="usage-monitor.sh exited with status $status"
    return 2
  fi
  if [ -z "$out" ]; then
    READY_REASON="usage-monitor.sh returned no limits data"
    return 2
  fi
  while IFS='|' read -r kind pct rest; do
    [ -n "$kind" ] || continue
    pct=${pct%%.*}
    case "$pct" in ''|*[!0-9]*) continue ;; esac
    if [ "$kind" = "session" ]; then
      sess="$pct"
    elif [ "$pct" -ge 100 ]; then
      blocked=1
    fi
  done <<< "$out"
  if [ "$sess" -lt 95 ] && [ "$blocked" -eq 0 ]; then
    return 0
  fi
  READY_REASON="limited"
  return 1
}

DEADLINE=$(( $(date +%s) + MAX_WAIT ))
while :; do
  # `limits_ready || RC=$?` rather than `if limits_ready; then break; fi`:
  # under set -e, an `if` with no else branch taken resets $? to 0 once
  # control reaches `fi`, which would silently collapse every failure into
  # "RC=0" and misreport a read failure as ready.
  RC=0
  limits_ready || RC=$?
  [ "$RC" -eq 0 ] && break
  NOW=$(date +%s)
  if [ "$NOW" -ge "$DEADLINE" ]; then
    if [ "$RC" -eq 2 ]; then
      say "Не удалось прочитать данные о лимитах (${READY_REASON}) за отведённое время — выходим." \
          "Could not read limits data (${READY_REASON}) within the allotted time — giving up." >&2
    else
      say "Лимиты так и не освободились за отведённое время — выходим." \
          "Limits did not free up within the allotted time — giving up." >&2
    fi
    exit 1
  fi
  if [ "$RC" -eq 2 ]; then
    say "Не удалось прочитать данные о лимитах (${READY_REASON}) — жду и попробую снова…" \
        "Could not read limits data (${READY_REASON}) — waiting and retrying…"
  else
    say "Лимит ещё занят (возможно, недельный) — жду дальше…" \
        "Still limited (weekly limit, most likely) — keep waiting…"
  fi
  # Bound the poll interval by the remaining wait time, not a flat 300s:
  # otherwise a short MAX_WAIT (e.g. in tests, or near its own deadline)
  # overshoots the deadline by up to 5 minutes before the next check.
  POLL=$(( DEADLINE - NOW ))
  [ "$POLL" -gt 300 ] && POLL=300
  sleep "$POLL"
done

# --- resume -------------------------------------------------------------

if [ -f "$STATE" ]; then
  NEW_STATE=$("$JQ" '.armed = false' "$STATE" 2>/dev/null) || NEW_STATE=""
  if [ -n "$NEW_STATE" ]; then
    # Atomic write (temp file + mv), matching the writers in
    # usage-monitor.sh: a plain `>` truncate risks a torn file if this
    # long-lived worker is killed mid-write (e.g. Ctrl-C), which is a
    # routine event for a script meant to sit in a terminal for hours.
    STATE_TMP="$STATE.tmp.$$"
    if printf '%s\n' "$NEW_STATE" > "$STATE_TMP" 2>/dev/null; then
      mv -f "$STATE_TMP" "$STATE" 2>/dev/null || rm -f "$STATE_TMP"
    else
      rm -f "$STATE_TMP"
    fi
  fi
fi

# exec does not run EXIT traps, so release the lock explicitly first.
rm -f "$LOCK"
trap - EXIT INT TERM

say "▶️ Лимит сброшен — продолжаю сессию $SID" "▶️ Limit reset — resuming session $SID"
cd "$CWD"
# An explicit --prompt "" (or UM_RESUME_PROMPT="") means "resume with no
# first message" — DEFAULT_PROMPT is always non-empty, so PROMPT can only be
# empty here by explicit user request, never by silent fallback.
if [ -n "$PROMPT" ]; then
  exec "$CLAUDE_BIN" --resume "$SID" "$PROMPT"
else
  exec "$CLAUDE_BIN" --resume "$SID"
fi
