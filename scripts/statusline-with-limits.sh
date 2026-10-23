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
# The 5h and 7d percentages come from two places, and each window takes the
# fresher of them (see pick_window): this statusline's own stdin, where Claude
# Code passes .rate_limits from the headers of its last API response — current
# while the session works, frozen while it idles — and the usage-monitor
# cache, the account-wide answer of the usage endpoint, which also sees work
# done elsewhere. The cache alone has the model-scoped weekly limit. The
# statusline itself makes no network call; when the cache grows stale it only
# starts a detached refresh, so the line stays fast.
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
#   UM_STATUSLINE_RESET=1  0 hides the reset time shown next to a window that
#                          has reached UM_WARN ("5ч 84% ↻00:20"; past a day
#                          away, the date instead: "↻15.10")
#   UM_STATUSLINE_PACE=1   0 hides how far a weekly window is off an even pace:
#                          "7д 46% ▲8" — 8 points above the share of the week
#                          that has elapsed, so it runs out early; "7д 20% ▼18"
#                          — 18 points below, so part of it resets unused.
#                          Shown from 5 points either way
#   UM_STATUSLINE_BG_REFRESH=1  0 stops the statusline from refreshing a stale
#                          cache in the background (see the block near the end)
#   UM_STATUSLINE_REFRESH_AFTER=120  cache age, seconds, that triggers it
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
SL_RESET="${UM_STATUSLINE_RESET:-1}"
SL_PACE="${UM_STATUSLINE_PACE:-1}"
SL_BG_REFRESH="${UM_STATUSLINE_BG_REFRESH:-1}"
SL_REFRESH_AFTER="${UM_STATUSLINE_REFRESH_AFTER:-120}"
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

# Near a limit the question is "until when?", so a window at or above WARN
# gets its reset time, dim, after the percent: HH:MM within a day, the date
# beyond that. Below WARN the line stays as short as it was.
reset_suffix() { # $1 = percent, $2 = reset epoch (0 = unknown)
  [ "$SL_RESET" = "1" ] || return 0
  [ "$1" -ge "$WARN" ] 2>/dev/null || return 0
  local now
  now=$(date +%s)
  [ "${2:-0}" -gt "$now" ] 2>/dev/null || return 0
  if [ $(( $2 - now )) -lt 86400 ]; then
    printf ' %s↻%s%s' "$DIM" "$(date -r "$2" +%H:%M)" "$RST"
  else
    printf ' %s↻%s%s' "$DIM" "$(date -r "$2" +%d.%m)" "$RST"
  fi
}

# A weekly window off an even pace by 5 points or more gets an arrow: N
# points from the share of the week that has elapsed (usage-monitor.sh
# pace_expected, same rule). "▲N", yellow: spending faster than the week
# allows, it runs out before the reset — 46% on Monday is not 46% on
# Friday. "▼N", cyan: slower, part of the limit resets unused, and a
# subscription is paid for whether it is used or not. Nothing within 5
# points, and nothing in the window's first half-day, when the comparison
# is noise.
pace_suffix() { # $1 = percent, $2 = reset epoch of a weekly window
  [ "$SL_PACE" = "1" ] || return 0
  local len=604800 elapsed ahead
  [ "${2:-0}" -gt 0 ] 2>/dev/null || return 0
  elapsed=$(( $(date +%s) - ($2 - len) ))
  [ "$elapsed" -ge $(( len / 14 )) ] && [ "$elapsed" -le "$len" ] || return 0
  ahead=$(( $1 - elapsed * 100 / len ))
  if [ "$ahead" -ge 5 ]; then
    printf ' \033[33m▲%s%s' "$ahead" "$RST"
  elif [ "$ahead" -le -5 ]; then
    printf ' \033[36m▼%s%s' "$(( -ahead ))" "$RST"
  fi
}

# Each window is taken from whichever source is fresher, decided per window:
# stdin carries what Claude Code saw in this session's last API response —
# current while the session works, frozen while it idles; the cache holds the
# account-wide answer of the usage endpoint, refreshed by the agent and the
# hooks, so it also sees work in other terminals, on other devices, on
# claude.ai. Neither carries a timestamp, but within one window usage only
# grows until the reset: so the later reset wins, and for the same window
# (reset times within ten minutes) the higher percent. A window whose reset
# has passed has rolled over and is dropped.
NOW_S=$(date +%s)
pick_window() { # $1 pct A, $2 reset A, $3 pct B, $4 reset B ("" = absent) -> "pct reset"
  local pa="$1" ra="${2:-0}" pb="$3" rb="${4:-0}" gap
  if [ -n "$pa" ] && [ "$ra" -gt 0 ] && [ "$ra" -le "$NOW_S" ]; then pa=""; fi
  if [ -n "$pb" ] && [ "$rb" -gt 0 ] && [ "$rb" -le "$NOW_S" ]; then pb=""; fi
  if [ -z "$pa" ]; then [ -n "$pb" ] && echo "$pb $rb"; return 0; fi
  if [ -z "$pb" ]; then echo "$pa $ra"; return 0; fi
  gap=$(( ra - rb )); [ "$gap" -lt 0 ] && gap=$(( -gap ))
  if [ "$gap" -le 600 ]; then
    [ "$pa" -ge "$pb" ] && pb="$pa"
    [ "$ra" -ge "$rb" ] && rb="$ra"
    echo "$pb $rb"
  elif [ "$ra" -gt "$rb" ]; then
    echo "$pa $ra"
  else
    echo "$pb $rb"
  fi
}

# The signed-in account (account + organization, see usage-monitor.sh): the
# cache and the shared observations are used only when they belong to it, so
# switching accounts never shows the previous account's numbers.
ACCOUNT=""
[ -x "$JQ" ] && ACCOUNT=$("$JQ" -r '.oauthAccount // {} | select(.accountUuid != null)
  | "\(.accountUuid):\(.organizationUuid // "")"' "$HOME/.claude.json" 2>/dev/null)
CACHE_MINE=0
if [ -f "$CACHE" ] && [ -x "$JQ" ]; then
  if [ -z "$ACCOUNT" ] || "$JQ" -e --arg a "$ACCOUNT" '(._account // $a) == $a' "$CACHE" >/dev/null 2>&1; then
    CACHE_MINE=1
  fi
fi

LIMITS=""
s=""; w=""; r5=0; r7=0; f="-1"; rf=0; SCOPED_MODEL=""
s5=""; s7=""; sr5=0; sr7=0; cs=""; cw=""; cr5=0; cr7=0
if [ -x "$JQ" ]; then
  # resets_at arrives here as epoch seconds; "-" marks an absent window.
  read -r s5 s7 sr5 sr7 <<< "$(printf '%s' "$INPUT" | "$JQ" -r '
    .rate_limits as $rl
    | [ ($rl.five_hour.used_percentage | if type == "number" then floor else "-" end),
        ($rl.seven_day.used_percentage | if type == "number" then floor else "-" end),
        ($rl.five_hour.resets_at // 0), ($rl.seven_day.resets_at // 0) ]
    | map(tostring) | join(" ")' 2>/dev/null)"
  [ "${s5:-}" = "-" ] && s5=""
  [ "${s7:-}" = "-" ] && s7=""
  # Several sessions working at once each see their own last API response,
  # so their stdin readings differ by whatever was spent in between. A shared
  # file keeps the freshest reading any of them has seen: each redraw merges
  # its own stdin into it (same rule) and draws from the merged value, so all
  # terminals converge on one number within a redraw. Read-merge-write runs
  # under a mkdir lock, or a redraw holding an older reading could overwrite a
  # newer one. A redraw that finds the lock taken retries for up to ~0.3 s
  # (only ever under simultaneous redraws), then just reads. The write goes
  # through a temp file and mv, so a reader never sees half a line.
  observed="$UM_DIR/usage-monitor-observed"
  obs_lock="$observed.lock"
  have_obs_lock=0
  if [ -n "$(find "$obs_lock" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
    rmdir "$obs_lock" 2>/dev/null
  fi
  for _try in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    if mkdir "$obs_lock" 2>/dev/null; then have_obs_lock=1; break; fi
    sleep 0.02
  done
  o5=""; o7=""; or5=0; or7=0; oacct=""
  [ -f "$observed" ] && read -r oacct o5 or5 o7 or7 < "$observed"
  # Another account's reading (or a pre-0.9.1 line without one) is not ours.
  if [ "$oacct" != "${ACCOUNT:--}" ]; then o5=""; o7=""; or5=0; or7=0; fi
  [ "${o5:-}" = "-" ] && o5=""
  [ "${o7:-}" = "-" ] && o7=""
  read -r m5 mr5 <<< "$(pick_window "$s5" "${sr5:-0}" "$o5" "${or5:-0}")"
  read -r m7 mr7 <<< "$(pick_window "$s7" "${sr7:-0}" "$o7" "${or7:-0}")"
  merged="${ACCOUNT:--} ${m5:--} ${mr5:-0} ${m7:--} ${mr7:-0}"
  if [ "$have_obs_lock" = "1" ]; then
    if [ "$merged" != "${oacct:--} ${o5:--} ${or5:-0} ${o7:--} ${or7:-0}" ]; then
      tmp_obs=$(mktemp "$observed.XXXXXX" 2>/dev/null) \
        && printf '%s\n' "$merged" > "$tmp_obs" && mv -f "$tmp_obs" "$observed" 2>/dev/null
      [ -n "${tmp_obs:-}" ] && rm -f "$tmp_obs" 2>/dev/null
    fi
    rmdir "$obs_lock" 2>/dev/null
  fi
  s5="${m5:-}"; sr5="${mr5:-0}"; s7="${m7:-}"; sr7="${mr7:-0}"
  if [ "$CACHE_MINE" = "1" ]; then
    # The cache stores resets_at as ISO 8601. The scoped limit is shown only
    # while its window is still open: from a cache that outlived its reset,
    # the number no longer means anything. SCOPED_MODEL goes last because it
    # may be empty, and read collapses empty tab-separated fields.
    IFS=$'\t' read -r cs cw f cr5 cr7 rf SCOPED_MODEL <<< "$("$JQ" -r '
      def epoch: (. // "") | sub("\\.[0-9]+"; "") | sub("(\\+00:00|Z)$"; "Z")
                 | (try fromdateiso8601 catch 0);
      ([.limits[]? | select(.kind == "weekly_scoped")][0]) as $sc
      | ($sc.resets_at | epoch) as $reset
      | [ (.five_hour.utilization | if type == "number" then floor else "-" end),
          (.seven_day.utilization | if type == "number" then floor else "-" end),
          (if $sc != null and ($sc.percent | type) == "number" and ($reset == 0 or $reset > now)
             then ($sc.percent | floor) else -1 end),
          (.five_hour.resets_at | epoch), (.seven_day.resets_at | epoch), $reset,
          ($sc.scope.model.display_name // "") ]
      | map(tostring) | join("\t")' "$CACHE" 2>/dev/null)"
    # "-" marks a window the cache does not have (an empty field would shift
    # the rest under read's whitespace splitting). Never show it as 0%.
    [ "${cs:-}" = "-" ] && cs=""
    [ "${cw:-}" = "-" ] && cw=""
  fi
  read -r s r5 <<< "$(pick_window "$s5" "${sr5:-0}" "$cs" "${cr5:-0}")"
  read -r w r7 <<< "$(pick_window "$s7" "${sr7:-0}" "$cw" "${cr7:-0}")"
  seg5=""; seg7=""
  [ -n "$s" ] && seg5="${L5} $(colorize "$s")$(reset_suffix "$s" "${r5:-0}")"
  [ -n "$w" ] && seg7="${L7} $(colorize "$w")$(pace_suffix "$w" "${r7:-0}")$(reset_suffix "$w" "${r7:-0}")"
  for seg in "$seg5" "$seg7"; do
    [ -n "$seg" ] || continue
    [ -n "$LIMITS" ] && LIMITS="$LIMITS ${DIM}·${RST} "
    LIMITS="${LIMITS}${seg}"
  done
  # model-scoped weekly limit (-1 = absent or expired, hidden). The WK
  # prefix keeps this from reading as "the model currently running".
  if [ -n "$LIMITS" ] && [ "$f" -ge 0 ] 2>/dev/null && [ -n "$SCOPED_MODEL" ]; then
    LIMITS="$LIMITS ${DIM}·${RST} ${WK} ${SCOPED_MODEL} $(colorize "$f")$(pace_suffix "$f" "${rf:-0}")$(reset_suffix "$f" "${rf:-0}")"
  fi
fi

# Keep the account-wide numbers fresh while this terminal is merely open: the
# statusline redraws every refreshInterval even when the session idles, so a
# cache older than UM_STATUSLINE_REFRESH_AFTER starts `usage-monitor.sh hook`
# in the background — detached, the line never waits for it. That mode makes
# at most one request per UM_CACHE_TTL, honours the 401/403/429 pause and the
# state lock, and sends the same once-per-threshold notifications. With the
# launchd agent on, the cache rarely gets that old and this stays idle; with
# it off (the plugin's default), this is what keeps an idle line current.
# The stamp spaces out spawns from the many redraws of one busy minute.
if [ "$SL_BG_REFRESH" = "1" ]; then
  cache_mtime=$(stat -f %m "$CACHE" 2>/dev/null || echo 0)
  # Another account's cache is as good as none: refresh it for this one.
  [ "$CACHE_MINE" = "1" ] || cache_mtime=0
  spawn_stamp="$UM_DIR/usage-monitor-sl-refresh"
  spawn_mtime=$(stat -f %m "$spawn_stamp" 2>/dev/null || echo 0)
  monitor="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/usage-monitor.sh"
  if [ $(( NOW_S - cache_mtime )) -ge "$SL_REFRESH_AFTER" ] \
     && [ $(( NOW_S - spawn_mtime )) -ge 30 ] && [ -f "$monitor" ]; then
    touch "$spawn_stamp" 2>/dev/null || true
    ( nohup bash "$monitor" hook </dev/null >/dev/null 2>&1 & )
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
