#!/usr/bin/env bash
# statusline-with-limits.sh — Claude Code statusline with usage limits.
#
# Renders:  <your existing statusline> | Opus 5/high · ctx 72% · ⇢ Haiku 4.5 | 5h 66% · 7d 7% · wk Fable 4%
#
# The model segment comes entirely from the statusline's own stdin JSON, so it
# costs no I/O. Every piece degrades on its own: no .effort in stdin drops
# "/high", a null .context_window.used_percentage drops "ctx N%", and no
# subagent on a different model drops the "⇢ …" part.
#
# "wk Fable 4%" is the weekly model-scoped LIMIT, not a running model — hence
# the prefix, now that a real model name shares the line.
#
# The 5h and 7d percentages come from this statusline's own stdin: Claude Code
# passes .rate_limits (five_hour / seven_day, from the headers of its last API
# response), so they are current and cost no request. The usage-monitor cache
# fills in what stdin lacks — the model-scoped weekly limit, which only the
# usage endpoint reports, and the first redraws of a session, before any API
# response. No network calls either way, so the statusline stays fast.
#
# If ~/.claude/scripts/statusline-base.cmd exists, its content is executed
# as the base statusline command (stdin JSON is passed through). Without it
# only the limits are shown. install.sh preserves your previous statusline
# command into that file automatically.
#
# Colors: green < WARN, yellow >= WARN (80), red >= CRIT (95). The context
# percentage uses UM_COMPACT_WARN (70) / 90 instead, and renders Claude
# Code's own .context_window.used_percentage. That's the same threshold
# *value* compact-advisor.sh signals on, but not the same *quantity*: the
# advisor computes last-assistant-turn tokens ÷ autoCompactWindow, a
# different denominator. With a custom --auto-compact-window (e.g. 140000)
# the advisor can fire while this segment still shows green.
#
# Environment overrides:
#   UM_WARN, UM_CRIT, UM_LANG=ru|en
#   UM_STATUSLINE_MODEL=1  0 hides the whole model segment
#   UM_STATUSLINE_CTX=1    0 hides "ctx N%"
#   UM_STATUSLINE_ADVISOR=1  0 hides "adv <model>" (the /advisor model, shown
#                          only when its family differs from the session's)
#   UM_SUBAGENT_MODEL=1    0 hides "⇢ <subagent model>"
#   UM_SUBAGENT_TTL=180    how recently a subagent transcript must have been
#                          written for the subagent to count as running, sec

INPUT=$(cat)

WARN="${UM_WARN:-80}"
CRIT="${UM_CRIT:-95}"
LANG_UM="${UM_LANG:-ru}"
# No CLAUDE_PLUGIN_OPTION_LANG here: in plugin mode this file runs as the copy
# in ${CLAUDE_PLUGIN_DATA}/bin, through a wrapper that already exports UM_LANG,
# so a plugin option seen here could only be another plugin's, leaked.
SL_MODEL="${UM_STATUSLINE_MODEL:-1}"
SL_CTX="${UM_STATUSLINE_CTX:-1}"
SL_ADVISOR="${UM_STATUSLINE_ADVISOR:-1}"
SL_SUBAGENT="${UM_SUBAGENT_MODEL:-1}"
SUBAGENT_TTL="${UM_SUBAGENT_TTL:-180}"
SETTINGS="$HOME/.claude/settings.json"

# Real ESC bytes, not the literal text "\033[...]". The final render uses
# printf '%s', never '%b': everything on this line is attacker-adjacent data —
# the base statusline command's output, the model display name, advisorModel
# from a hand-editable settings.json — and %b would expand any backslash
# sequence inside it. A stray "\n" would split the status line; "\c" would
# silently truncate everything after it.
DIM=$'\033[2m'
RST=$'\033[0m'
COMPACT_WARN="${UM_COMPACT_WARN:-70}"

BASE=""
# See usage-monitor.sh for why CLAUDE_PLUGIN_DATA is not part of this chain.
UM_DIR="${UM_STATE_DIR:-$HOME/.claude/scripts}"
BASE_CMD_FILE="$UM_DIR/statusline-base.cmd"
if [ -f "$BASE_CMD_FILE" ]; then
  BASE=$(echo "$INPUT" | bash -c "$(cat "$BASE_CMD_FILE")" 2>/dev/null)
fi

CACHE="$UM_DIR/usage-monitor-cache.json"
JQ="$(command -v jq || echo /opt/homebrew/bin/jq)"

if [ "$LANG_UM" = "en" ]; then L5="5h"; L7="7d"; WK="wk"; else L5="5ч"; L7="7д"; WK="нед."; fi

colorize() { # percent -> colored "N%"
  if   [ "$1" -ge "$CRIT" ]; then printf '\033[31m%s%%\033[0m' "$1"
  elif [ "$1" -ge "$WARN" ]; then printf '\033[33m%s%%\033[0m' "$1"
  else                            printf '\033[32m%s%%\033[0m' "$1"
  fi
}

colorize_ctx() { # context percent -> colored "N%"
  if   [ "$1" -ge 90 ];            then printf '\033[31m%s%%\033[0m' "$1"
  elif [ "$1" -ge "$COMPACT_WARN" ]; then printf '\033[33m%s%%\033[0m' "$1"
  else                                  printf '\033[32m%s%%\033[0m' "$1"
  fi
}

# claude-haiku-4-5-20251001 -> "Haiku 4.5";  claude-opus-5 -> "Opus 5";
# bare alias "haiku" -> "Haiku". A pure string transform on purpose: a lookup
# table would need editing every time a model ships.
prettify_model() {
  local m="$1" family rest first
  m="${m#claude-}"
  case "$m" in
    *-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) m="${m%-*}" ;;
  esac
  family="${m%%-*}"
  if [ "$family" = "$m" ]; then rest=""; else rest="${m#*-}"; fi
  first=$(printf '%s' "${family%"${family#?}"}" | tr '[:lower:]' '[:upper:]')
  family="${first}${family#?}"
  if [ -n "$rest" ]; then
    printf '%s %s' "$family" "$(printf '%s' "$rest" | tr '-' '.')"
  else
    printf '%s' "$family"
  fi
}

# Lowercase family token, for comparing models that may arrive in different
# shapes: settings.json stores the advisor as an alias ("fable"), the
# statusline receives the session model as a full id ("claude-opus-5"), and a
# subagent's meta.json also carries an alias. Comparing prettified names
# would call "opus" and "Opus 5" different models. Leading numeric segments
# are skipped so legacy claude-<version>-<family> ids resolve to the family
# too ("3-5-sonnet" -> "sonnet").
model_family() { # $1 = model id or alias -> lowercase family, or $1 unchanged
  local m tok
  m=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  m="${m#claude-}"
  case "$m" in
    *-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) m="${m%-*}" ;;
  esac
  while [ -n "$m" ]; do
    tok="${m%%-*}"
    case "$tok" in
      *[!0-9]*) printf '%s' "$tok"; return 0 ;;
    esac
    [ "$m" = "${m#*-}" ] && break
    m="${m#*-}"
  done
  printf '%s' "$1"
}

# Does this id carry a version, or is it a bare family alias? "claude-opus-5"
# and "haiku-4-5" do; "fable" does not.
model_has_version() { # $1 = model id or alias -> 0 if versioned
  local m tok
  m=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  m="${m#claude-}"
  case "$m" in
    *-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) m="${m%-*}" ;;
  esac
  while : ; do
    tok="${m%%-*}"
    case "$tok" in
      ''|*[!0-9]*) ;;
      *) return 0 ;;
    esac
    [ "$m" = "${m#*-}" ] && return 1
    m="${m#*-}"
  done
}

# Whether two model identifiers denote the same model, given that they can
# arrive in different shapes. Compare in full when both carry a version, so
# Sonnet 4 and Sonnet 4.5 stay distinct; fall back to the family only when one
# side is a bare alias and simply has no version to compare against — that is
# the alias-vs-full-id case (settings.json stores "fable", a subagent's
# meta.json stores "haiku"), where a full comparison would call identical
# models different.
models_same() { # $1, $2 = model ids or aliases -> 0 if the same model
  if model_has_version "$1" && model_has_version "$2"; then
    [ "$(prettify_model "$1")" = "$(prettify_model "$2")" ]
  else
    [ "$(model_family "$1")" = "$(model_family "$2")" ]
  fi
}

# The model configured via /advisor, when it is a different family from the
# session's. Read from settings.json, the same file the ctx denominator's
# autoCompactWindow comes from. Advisor calls are separate requests with their
# own context — they do not fill the session window — so this is purely a
# "what am I consulting" indicator.
advisor_suffix() { # $1 = session model id
  [ "$SL_ADVISOR" = "1" ] || return 0
  [ -f "$SETTINGS" ] || return 0
  local adv
  # Must be a string scalar: settings.json is hand-editable, and a non-string
  # advisorModel would otherwise be rendered as raw multi-line JSON, breaking
  # the status line into several lines.
  adv=$("$JQ" -r 'if (.advisorModel | type) == "string" then .advisorModel else empty end' \
    "$SETTINGS" 2>/dev/null) || return 0
  case "$adv" in ''|*[![:print:]]*) return 0 ;; esac
  models_same "$adv" "$1" && return 0
  printf 'adv %s' "$(prettify_model "$adv")"
}

# Live subagents whose model differs from the session's, deduplicated with a
# count. Liveness is the transcript's mtime: a background subagent's
# tool_result lands in the main transcript immediately, so "unmatched
# tool_use" would report finished agents as running, and the main transcript
# is far too large to parse on every statusline redraw anyway.
#
# Two bounds, doing two different jobs: the `ls -t | head -n 12` enumerates
# at most the 12 newest files (so a directory full of long-stale subagents
# from past sessions never gets `stat`-ed one-by-one), and `n -ge 8` caps how
# many *collected* (live, non-session-model) entries get rendered. Newest-
# first ordering is what makes 12 safe — a live subagent is by definition
# one written within UM_SUBAGENT_TTL, so it's always among the newest files.
subagent_suffix() { # $1 transcript_path, $2 session_id, $3 session model id
  [ "$SL_SUBAGENT" = "1" ] || return 0
  [ -n "$1" ] && [ "$1" != "-" ] && [ -n "$2" ] && [ "$2" != "-" ] || return 0
  local dir cutoff f mt mid pretty session_model models="" n=0
  dir="$(dirname "$1")/$2/subagents"
  [ -d "$dir" ] || return 0
  cutoff=$(( $(date +%s) - SUBAGENT_TTL ))
  session_model="$3"
  # shellcheck disable=SC2045  # agent-<hex>.jsonl names are whitespace-free by construction
  for f in $(ls -t "$dir"/agent-*.jsonl 2>/dev/null | head -n 12); do
    [ -f "$f" ] || continue
    [ "$n" -ge 8 ] && break
    mt=$(stat -f %m "$f" 2>/dev/null || echo 0)
    [ "$mt" -ge "$cutoff" ] || continue
    mid=$(tail -n 50 "$f" 2>/dev/null | "$JQ" -r 'select(.type == "assistant") | .message.model // empty' 2>/dev/null | tail -1)
    [ -n "$mid" ] || mid=$("$JQ" -r '.model // empty' "${f%.jsonl}.meta.json" 2>/dev/null)
    [ -n "$mid" ] || continue
    pretty=$(prettify_model "$mid")
    models_same "$mid" "$session_model" && continue
    models="${models}${pretty}
"
    n=$(( n + 1 ))
  done
  [ -n "$models" ] || return 0
  printf '⇢ %s' "$(printf '%s' "$models" | sort | uniq -c | awk '
    { c = $1; $1 = ""; sub(/^ /, "")
      printf "%s%s", (NR > 1 ? ", " : ""), (c > 1 ? c "× " $0 : $0) }')"
}

MODEL_SEG=""
if [ "$SL_MODEL" = "1" ] && [ -x "$JQ" ]; then
  # tab-joined: display names ("Claude 3.5 Sonnet") and paths contain spaces
  IFS=$'\t' read -r M_NAME M_ID M_EFF M_CTX M_SID M_TP <<< "$(printf '%s' "$INPUT" | "$JQ" -r '
      [ (.model.display_name // "-"),
        (.model.id // "-"),
        (.effort.level // "-"),
        ((.context_window.used_percentage // -1) | floor | tostring),
        (.session_id // "-"),
        (.transcript_path // "-") ] | join("\t")' 2>/dev/null)"
  if [ -n "${M_NAME:-}" ] && [ "$M_NAME" != "-" ]; then
    MODEL_SEG="$M_NAME"
    [ "${M_EFF:--}" != "-" ] && MODEL_SEG="$MODEL_SEG/$M_EFF"
    ADV=$(advisor_suffix "${M_ID:--}")
    [ -n "$ADV" ] && MODEL_SEG="$MODEL_SEG ${DIM}·${RST} $ADV"
    if [ "$SL_CTX" = "1" ] && [ "${M_CTX:--1}" -ge 0 ] 2>/dev/null; then
      MODEL_SEG="$MODEL_SEG ${DIM}·${RST} ctx $(colorize_ctx "$M_CTX")"
    fi
    SUB=$(subagent_suffix "${M_TP:--}" "${M_SID:--}" "${M_ID:--}")
    [ -n "$SUB" ] && MODEL_SEG="$MODEL_SEG ${DIM}·${RST} $SUB"
  fi
fi

LIMITS=""
s=""; w=""; f="-1"; SCOPED_MODEL=""
if [ -x "$JQ" ]; then
  # Both windows or neither: one live and one cached number side by side would
  # silently mix two moments.
  read -r s w <<< "$(printf '%s' "$INPUT" | "$JQ" -r '
    [.rate_limits.five_hour.used_percentage, .rate_limits.seven_day.used_percentage]
    | if all(type == "number") then (map(floor | tostring) | join(" ")) else "" end' 2>/dev/null)"
  if [ -f "$CACHE" ]; then
    # The scoped limit is shown only while its window is still open: from a
    # cache that outlived its reset, the number no longer means anything.
    IFS=$'\t' read -r cs cw f SCOPED_MODEL <<< "$("$JQ" -r '
      ([.limits[]? | select(.kind == "weekly_scoped")][0]) as $sc
      | (($sc.resets_at // "") | sub("\\.[0-9]+"; "") | sub("(\\+00:00|Z)$"; "Z")
         | (try fromdateiso8601 catch 0)) as $reset
      | [ (.five_hour.utilization // 0 | floor),
          (.seven_day.utilization // 0 | floor),
          (if $sc != null and ($sc.percent | type) == "number" and ($reset == 0 or $reset > now)
             then ($sc.percent | floor) else -1 end),
          ($sc.scope.model.display_name // "") ]
      | map(tostring) | join("\t")' "$CACHE" 2>/dev/null)"
    if [ -z "$s" ]; then s="${cs:-}"; w="${cw:-}"; fi
  fi
  if [ -n "$s" ] && [ -n "$w" ]; then
    LIMITS="${L5} $(colorize "$s") ${DIM}·${RST} ${L7} $(colorize "$w")"
    # model-scoped weekly limit (-1 = absent or expired, hidden). The WK
    # prefix keeps this from reading as "the model currently running".
    if [ "$f" -ge 0 ] 2>/dev/null && [ -n "$SCOPED_MODEL" ]; then
      LIMITS="$LIMITS ${DIM}·${RST} ${WK} ${SCOPED_MODEL} $(colorize "$f")"
    fi
  fi
fi

# Segments joined with " | ", each one skipped when empty.
SEP=" ${DIM}|${RST} "
OUT="$BASE"
for seg in "$MODEL_SEG" "$LIMITS"; do
  [ -n "$seg" ] || continue
  [ -n "$OUT" ] && OUT="${OUT}${SEP}"
  OUT="${OUT}${seg}"
done

printf '%s' "$OUT"
