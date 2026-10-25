#!/usr/bin/env bash
# fanout-guard.sh — asks before a subagent starts while the week is almost
# spent. PreToolUse hook, matcher "Agent|Task"; the event JSON arrives on
# stdin.
#
# A weekly limit that runs out stops work for days, while a 5-hour one resets
# within hours and Claude Code continues on its own
# (autoContinueAtUsageLimit). Subagents are what spends a week fastest:
# several run at once, each with its own context. So once a weekly window is
# at UM_CRIT, starting one is asked about instead of just happening. The
# decision stays with the user: "ask", never "deny".
#
# Off by default. On with UM_GUARD_FANOUT=1, the plugin option guard_fanout,
# or install.sh --guard-fanout.
#
# Weekly windows that count:
#   weekly_all    — always: every model spends it;
#   weekly_scoped — only when the subagent is explicitly given that model
#                   (tool_input.model); a subagent on the session model
#                   cannot be matched, the hook does not know which it is.
#
# It reads the monitor's cache only, never the endpoint: a tool call must not
# wait on the network. A cache older than 15 minutes, or another account's,
# is no ground for asking, and then the hook stays silent.
#
# Environment overrides:
#   UM_GUARD_FANOUT=0  UM_CRIT=95  UM_LANG=ru|en

set -u

# See usage-monitor.sh: nothing to guard inside its headless /usage refresh.
[ "${UM_INTERNAL:-}" = "1" ] && exit 0

ENABLED="${UM_GUARD_FANOUT:-0}"
CRIT="${UM_CRIT:-95}"
LANG_UM="${UM_LANG:-ru}"

# See usage-monitor.sh: plugin options are honoured only when this file is the
# copy inside the limit-alerts plugin, never when they leak from another one.
FROM_PLUGIN=0
case "${BASH_SOURCE[0]}" in "${CLAUDE_PLUGIN_ROOT:-/nonexistent}"/*) FROM_PLUGIN=1 ;; esac
if [ "$FROM_PLUGIN" = "1" ]; then
  [ "${CLAUDE_PLUGIN_OPTION_GUARD_FANOUT:-}" = "true" ] && ENABLED="${UM_GUARD_FANOUT:-1}"
  [ -n "${CLAUDE_PLUGIN_OPTION_CRIT:-}" ] && CRIT="${UM_CRIT:-$CLAUDE_PLUGIN_OPTION_CRIT}"
  [ -n "${CLAUDE_PLUGIN_OPTION_LANG:-}" ] && LANG_UM="${UM_LANG:-$CLAUDE_PLUGIN_OPTION_LANG}"
fi
[ "$ENABLED" = "1" ] || exit 0

# See usage-monitor.sh for why CLAUDE_PLUGIN_DATA is not part of this chain.
DIR="${UM_STATE_DIR:-$HOME/.claude/scripts}"
CACHE="$DIR/usage-monitor-cache.json"
CACHE_MAX_AGE=900

JQ="$(command -v jq || echo /opt/homebrew/bin/jq)"
[ -x "$JQ" ] || exit 0
[ -f "$CACHE" ] || exit 0
[ $(( $(date +%s) - $(stat -f %m "$CACHE" 2>/dev/null || echo 0) )) -le "$CACHE_MAX_AGE" ] || exit 0

input=$(cat 2>/dev/null) || exit 0

# The cache is trusted only for the account it was fetched for (see
# usage-monitor.sh cache_is_mine): an untagged one only without a sign-in, and
# none while .claude.json does not parse.
# Claude Code's configuration directory and global config, CLAUDE_CONFIG_DIR
# honoured the way Claude Code does it (see usage-monitor.sh).
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
CLAUDE_JSON="${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json"
[ -s "$CLAUDE_DIR/.config.json" ] && CLAUDE_JSON="$CLAUDE_DIR/.config.json"
ACCOUNT=""
if [ -f "$CLAUDE_JSON" ]; then
  ACCOUNT=$("$JQ" -r '.oauthAccount // {} | select(.accountUuid != null)
    | "\(.accountUuid):\(.organizationUuid // "")"' "$CLAUDE_JSON" 2>/dev/null) || exit 0
fi
"$JQ" -e --arg a "$ACCOUNT" '(._account // "") == $a' "$CACHE" >/dev/null 2>&1 || exit 0

model=$(printf '%s' "$input" | "$JQ" -r '.tool_input.model // empty | ascii_downcase' 2>/dev/null)

# The first weekly window at CRIT that this subagent would spend:
# "kind|percent|reset epoch|scope model".
IFS='|' read -r kind pct reset scope <<< "$("$JQ" -r --argjson crit "$CRIT" --arg m "$model" '
  def epoch: (. // "") | sub("\\.[0-9]+"; "") | sub("(\\+00:00|Z)$"; "Z")
    | (try fromdateiso8601 catch 0);
  [ .limits[]?
    | select((.percent | type) == "number" and .percent >= $crit)
    | (.resets_at | epoch) as $r
    | select($r == 0 or $r > now)
    | (.scope.model.display_name // "" | ascii_downcase) as $d
    | select(.kind == "weekly_all"
             or (.kind == "weekly_scoped" and $m != "" and $d != ""
                 and (($m | contains($d)) or ($d | contains($m)))))
    | [ .kind, (.percent | floor), $r, (.scope.model.display_name // "") ] | map(tostring) | join("|") ]
  | first // empty' "$CACHE" 2>/dev/null)"
[ -n "${kind:-}" ] || exit 0

when="?"
[ "${reset:-0}" -gt 0 ] 2>/dev/null && when=$(date -r "$reset" "+%d.%m %H:%M")
if [ "$LANG_UM" = "en" ]; then
  if [ "$kind" = "weekly_scoped" ]; then label="Week ($scope)"; else label="Week (all models)"; fi
  reason="limit-alerts: ${label} is at ${pct}%, resets ${when}. Subagents spend a week fastest — start this one?"
else
  if [ "$kind" = "weekly_scoped" ]; then label="Неделя ($scope)"; else label="Неделя (все модели)"; fi
  reason="limit-alerts: «${label}» — ${pct}%, сброс ${when}. Субагенты расходуют неделю быстрее всего — запустить этого?"
fi

"$JQ" -n --arg r "$reason" '{hookSpecificOutput: {hookEventName: "PreToolUse",
  permissionDecision: "ask", permissionDecisionReason: $r}}'
exit 0
