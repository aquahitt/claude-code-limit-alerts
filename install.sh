#!/usr/bin/env bash
# install.sh — installs claude-code-limit-alerts (macOS only).
#
# What it does:
#   1. Copies scripts to ~/.claude/scripts/
#   2. Adds hooks to ~/.claude/settings.json
#      (existing hooks are preserved; a backup of settings.json is made):
#        - Stop + SessionStart -> usage-limit warnings in the Claude Code UI
#        - Notification + Stop -> "needs your attention" banner + sound
#   3. Optionally replaces the statusline with the limits-aware wrapper
#      (your previous statusline command is preserved and keeps rendering)
#   4. Installs and loads a launchd agent (checks limits every 92 seconds,
#      catches window resets even when Claude Code is closed)
#
# Flags:
#   --no-statusline   skip statusline integration
#   --no-launchd      skip the background launchd agent
#   --no-attention    skip "needs your attention" notifications
#   --lang en|ru      notification language (default: ru)
#   --warn <percent>  🟡 threshold (default: 80)
#   --crit <percent>  🔴 threshold (default: 95)
#   --interval <sec>  background check interval of the launchd agent,
#                     60..3600 (default: 92)
#   --compact-warn <percent>
#                     /compact advisor threshold, % of the context window
#                     (default: 70)
#   --proxy <url>|""  proxy for the launchd agent (default: auto-detected
#                     from HTTP_PROXY/HTTPS_PROXY/ALL_PROXY/NO_PROXY, case-
#                     insensitive, in the current shell); "" disables
#                     passthrough entirely
#   --no-compact-advisor
#                     skip compact-advisor.sh (the /compact signal)
#   --no-statusline-model
#                     statusline shows limits only (no model / effort /
#                     context / subagent segment)
#   --no-subagent-model
#                     statusline shows the session model but not the model of
#                     a running subagent
#   --no-forecast     no ⏳ notification when a limit would run out before it
#                     resets
#   --no-spend-alert  no 💳 notification about paid usage credits
#   --no-unused-alert no ⌛ reminder that a weekly limit would reset unused
#   --no-statusline-pace
#                     no ▲N / ▼N weekly pace next to the statusline percent
#   --guard-fanout    ask before a subagent starts once a weekly limit is at
#                     the critical threshold (off by default)
#   --model-hint      suggest another model when a model-scoped weekly limit
#                     is at the critical threshold (off by default)
#   --auto-compact-window <tokens>
#                     set Claude Code's own auto-compact threshold in
#                     ~/.claude/settings.json (100000..1000000). Off by
#                     default: this changes behaviour for ALL your sessions.

set -euo pipefail

if [ "$(uname -s)" != "Darwin" ]; then
  echo "Only macOS is supported for now (Windows/Linux support is planned)." >&2
  exit 1
fi

WITH_STATUSLINE=1
WITH_LAUNCHD=1
WITH_ATTENTION=1
WITH_COMPACT_ADVISOR=1
WITH_STATUSLINE_MODEL=1
WITH_SUBAGENT_MODEL=1
WITH_FORECAST=1
WITH_SPEND_ALERT=1
WITH_UNUSED_ALERT=1
WITH_STATUSLINE_PACE=1
WITH_GUARD_FANOUT=0
WITH_MODEL_HINT=0
AUTO_COMPACT_WINDOW=""
LANG_UM="ru"
OPT_WARN=""
OPT_CRIT=""
OPT_INTERVAL=""
OPT_COMPACT_WARN=""
PROXY_URL=""
PROXY_FLAG_SET=0
while [ $# -gt 0 ]; do
  case "$1" in
    --no-statusline) WITH_STATUSLINE=0 ;;
    --no-launchd)    WITH_LAUNCHD=0 ;;
    --no-attention)  WITH_ATTENTION=0 ;;
    --no-compact-advisor) WITH_COMPACT_ADVISOR=0 ;;
    --no-statusline-model) WITH_STATUSLINE_MODEL=0 ;;
    --no-subagent-model) WITH_SUBAGENT_MODEL=0 ;;
    --no-forecast) WITH_FORECAST=0 ;;
    --no-spend-alert) WITH_SPEND_ALERT=0 ;;
    --no-unused-alert) WITH_UNUSED_ALERT=0 ;;
    --no-statusline-pace) WITH_STATUSLINE_PACE=0 ;;
    --guard-fanout) WITH_GUARD_FANOUT=1 ;;
    --model-hint) WITH_MODEL_HINT=1 ;;
    --auto-compact-window)
      [ $# -ge 2 ] || { echo "--auto-compact-window requires a value" >&2; exit 1; }
      shift; AUTO_COMPACT_WINDOW="$1" ;;
    --lang)
      [ $# -ge 2 ] || { echo "--lang requires a value" >&2; exit 1; }
      shift; LANG_UM="$1" ;;
    --warn|--crit|--interval|--compact-warn)
      [ $# -ge 2 ] || { echo "$1 requires a value" >&2; exit 1; }
      case "$1" in
        --warn) OPT_WARN="$2" ;;
        --crit) OPT_CRIT="$2" ;;
        --interval) OPT_INTERVAL="$2" ;;
        --compact-warn) OPT_COMPACT_WARN="$2" ;;
      esac
      shift ;;
    --proxy)
      [ $# -ge 2 ] || { echo "--proxy requires a value" >&2; exit 1; }
      shift; PROXY_URL="$1"; PROXY_FLAG_SET=1 ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
  shift
done

# Range copied from the CLI's own parse error: "Expected 'auto' or 100k-1M
# tokens". Anything outside it would be silently clamped or ignored.
if [ -n "$AUTO_COMPACT_WINDOW" ]; then
  case "$AUTO_COMPACT_WINDOW" in
    ''|*[!0-9]*) echo "--auto-compact-window expects an integer number of tokens" >&2; exit 1 ;;
  esac
  if [ "$AUTO_COMPACT_WINDOW" -lt 100000 ] || [ "$AUTO_COMPACT_WINDOW" -gt 1000000 ]; then
    echo "--auto-compact-window must be between 100000 and 1000000 tokens" >&2
    exit 1
  fi
fi

# $1 flag, $2 value, $3..$4 allowed range.
check_number() {
  case "$2" in
    ''|*[!0-9]*) echo "$1 expects a whole number between $3 and $4" >&2; exit 1 ;;
  esac
  if [ "$2" -lt "$3" ] || [ "$2" -gt "$4" ]; then
    echo "$1 expects a whole number between $3 and $4" >&2
    exit 1
  fi
}
[ -n "$OPT_WARN" ] && check_number --warn "$OPT_WARN" 1 99
[ -n "$OPT_CRIT" ] && check_number --crit "$OPT_CRIT" 1 99
[ -n "$OPT_INTERVAL" ] && check_number --interval "$OPT_INTERVAL" 60 3600
[ -n "$OPT_COMPACT_WARN" ] && check_number --compact-warn "$OPT_COMPACT_WARN" 1 99
if [ "${OPT_WARN:-80}" -ge "${OPT_CRIT:-95}" ]; then
  echo "--warn (${OPT_WARN:-80}) must be below --crit (${OPT_CRIT:-95})" >&2
  exit 1
fi

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$REPO_DIR/lib/hooks.sh"
source "$REPO_DIR/lib/launchd.sh"
resolve_jq

PROXY_ARG="$PROXY_URL"
[ "$PROXY_FLAG_SET" = "1" ] && [ -z "$PROXY_URL" ] && PROXY_ARG="__DISABLE__"

SCRIPTS_DIR="$HOME/.claude/scripts"
SETTINGS="$HOME/.claude/settings.json"

echo "==> Installing scripts to $SCRIPTS_DIR"
mkdir -p "$SCRIPTS_DIR"
cp "$REPO_DIR/scripts/usage-monitor.sh" "$SCRIPTS_DIR/"
cp "$REPO_DIR/scripts/statusline-with-limits.sh" "$SCRIPTS_DIR/"
chmod +x "$SCRIPTS_DIR/usage-monitor.sh" "$SCRIPTS_DIR/statusline-with-limits.sh"
if [ "$WITH_ATTENTION" = "1" ]; then
  cp "$REPO_DIR/scripts/notify-attention.sh" "$SCRIPTS_DIR/"
  chmod +x "$SCRIPTS_DIR/notify-attention.sh"
fi
if [ "$WITH_COMPACT_ADVISOR" = "1" ]; then
  cp "$REPO_DIR/scripts/compact-advisor.sh" "$SCRIPTS_DIR/"
  chmod +x "$SCRIPTS_DIR/compact-advisor.sh"
else
  rm -f "$SCRIPTS_DIR/compact-advisor.sh"
fi
# Installed only when asked for, and then switched on: the script's own
# default is off, for the plugin, where the hook is always registered.
if [ "$WITH_GUARD_FANOUT" = "1" ]; then
  cp "$REPO_DIR/scripts/fanout-guard.sh" "$SCRIPTS_DIR/"
  chmod +x "$SCRIPTS_DIR/fanout-guard.sh"
  sed -i '' 's/\${UM_GUARD_FANOUT:-0}/\${UM_GUARD_FANOUT:-1}/' "$SCRIPTS_DIR/fanout-guard.sh"
else
  rm -f "$SCRIPTS_DIR/fanout-guard.sh"
fi

# Leftovers from <= 0.4.0, which shipped an auto-resume worker. Claude Code
# now waits out a limit and continues the session on its own ("Continue
# automatically at usage limit" in /config), so the feature is gone — but its
# files would otherwise sit in ~/.claude/scripts forever, and a stale
# auto-resume.sh is still runnable by hand against a state file nothing
# maintains any more.
rm -f "$SCRIPTS_DIR/auto-resume.sh" "$SCRIPTS_DIR/auto-resume-state.json"
rm -f "$SCRIPTS_DIR"/auto-resume-*.lock

cp "$REPO_DIR/VERSION" "$SCRIPTS_DIR/.limit-alerts-version"

# persist language choice by changing the env default (only if not ru)
if [ "$LANG_UM" != "ru" ]; then
  for f in usage-monitor.sh statusline-with-limits.sh notify-attention.sh compact-advisor.sh fanout-guard.sh; do
    [ -f "$SCRIPTS_DIR/$f" ] && sed -i '' "s/\${UM_LANG:-ru}/\${UM_LANG:-$LANG_UM}/" "$SCRIPTS_DIR/$f"
  done
fi

# Thresholds the same way: the launchd agent runs these copies without the
# user's environment, so a default baked in here is the only one it sees.
if [ -n "$OPT_WARN" ]; then
  for f in usage-monitor.sh statusline-with-limits.sh; do
    sed -i '' "s/\${UM_WARN:-80}/\${UM_WARN:-$OPT_WARN}/" "$SCRIPTS_DIR/$f"
  done
fi
if [ -n "$OPT_CRIT" ]; then
  for f in usage-monitor.sh statusline-with-limits.sh fanout-guard.sh; do
    [ -f "$SCRIPTS_DIR/$f" ] && sed -i '' "s/\${UM_CRIT:-95}/\${UM_CRIT:-$OPT_CRIT}/" "$SCRIPTS_DIR/$f"
  done
fi
if [ -n "$OPT_COMPACT_WARN" ]; then
  for f in compact-advisor.sh statusline-with-limits.sh; do
    [ -f "$SCRIPTS_DIR/$f" ] && sed -i '' "s/\${UM_COMPACT_WARN:-70}/\${UM_COMPACT_WARN:-$OPT_COMPACT_WARN}/" "$SCRIPTS_DIR/$f"
  done
fi

# Same sed-the-default mechanism as --lang above: baking the choice into the
# installed copy keeps the statusline free of a config read on every redraw.
if [ "$WITH_STATUSLINE_MODEL" = "0" ]; then
  sed -i '' 's/\${UM_STATUSLINE_MODEL:-1}/\${UM_STATUSLINE_MODEL:-0}/' "$SCRIPTS_DIR/statusline-with-limits.sh"
fi
if [ "$WITH_SUBAGENT_MODEL" = "0" ]; then
  sed -i '' 's/\${UM_SUBAGENT_MODEL:-1}/\${UM_SUBAGENT_MODEL:-0}/' "$SCRIPTS_DIR/statusline-with-limits.sh"
fi
# The launchd agent runs the same installed copy without the user's
# environment, so a switch baked in here is the only one it ever sees.
if [ "$WITH_FORECAST" = "0" ]; then
  sed -i '' 's/\${UM_FORECAST:-1}/\${UM_FORECAST:-0}/' "$SCRIPTS_DIR/usage-monitor.sh"
fi
if [ "$WITH_SPEND_ALERT" = "0" ]; then
  sed -i '' 's/\${UM_SPEND_ALERT:-1}/\${UM_SPEND_ALERT:-0}/' "$SCRIPTS_DIR/usage-monitor.sh"
fi
if [ "$WITH_UNUSED_ALERT" = "0" ]; then
  sed -i '' 's/\${UM_UNUSED_ALERT:-1}/\${UM_UNUSED_ALERT:-0}/' "$SCRIPTS_DIR/usage-monitor.sh"
fi
if [ "$WITH_STATUSLINE_PACE" = "0" ]; then
  sed -i '' 's/\${UM_STATUSLINE_PACE:-1}/\${UM_STATUSLINE_PACE:-0}/' "$SCRIPTS_DIR/statusline-with-limits.sh"
fi
if [ "$WITH_MODEL_HINT" = "1" ]; then
  sed -i '' 's/\${UM_MODEL_HINT:-0}/\${UM_MODEL_HINT:-1}/' "$SCRIPTS_DIR/usage-monitor.sh"
fi

echo "==> Updating $SETTINGS"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
cp "$SETTINGS" "$SETTINGS.bak.limit-alerts"
echo "    (backup: $SETTINGS.bak.limit-alerts)"

register_monitor_hooks
echo "    Limit hooks added: Stop, SessionStart"

if [ "$WITH_ATTENTION" = "1" ]; then
  register_attention_hooks
  echo "    Attention hooks added: Notification, Stop"
fi

if [ "$WITH_COMPACT_ADVISOR" = "1" ]; then
  register_compact_advisor_hook
  echo "    Compact advisor hook added: Stop"
else
  # Idempotent no-op on a fresh --no-compact-advisor install; on a re-install
  # this actually unregisters the Stop hook a previous run added — otherwise
  # the hook keeps firing against a script install.sh just deleted above.
  remove_hook_matching "compact-advisor.sh"
fi

if [ "$WITH_GUARD_FANOUT" = "1" ]; then
  register_fanout_guard_hook
  echo "    Subagent guard hook added: PreToolUse (Agent)"
else
  # Same as the compact advisor: a re-install without the flag takes it away.
  remove_hook_matching "fanout-guard.sh"
fi

# Carry forward a previous run's AUTO_COMPACT_WINDOW_SET when this run omits
# --auto-compact-window, instead of resetting it to 0. Without this, a plain
# re-install (the documented way to pick up new flags/updates) would forget
# that this project set ~/.claude/settings.json's autoCompactWindow, and
# uninstall.sh would then leave that value behind forever instead of
# removing it — a global Claude Code setting the project disowns but never
# cleans up.
AUTO_COMPACT_WINDOW_SET=0
if [ -f "$SCRIPTS_DIR/.limit-alerts-options" ] && \
   grep -q '^AUTO_COMPACT_WINDOW_SET=1$' "$SCRIPTS_DIR/.limit-alerts-options"; then
  AUTO_COMPACT_WINDOW_SET=1
fi
if [ -n "$AUTO_COMPACT_WINDOW" ]; then
  if [ -n "${CLAUDE_CODE_AUTO_COMPACT_WINDOW:-}" ]; then
    echo "    Warning: CLAUDE_CODE_AUTO_COMPACT_WINDOW is set in your environment and takes precedence over this setting"
  fi
  updated=$("$JQ" --argjson w "$AUTO_COMPACT_WINDOW" '.autoCompactWindow = $w' "$SETTINGS")
  echo "$updated" > "$SETTINGS"
  AUTO_COMPACT_WINDOW_SET=1
  echo "    Auto-compact window set to $AUTO_COMPACT_WINDOW tokens"
fi

# Recorded because update.sh cannot otherwise tell an opted-out feature from
# a not-yet-installed one — file presence says nothing about autostart.
cat > "$SCRIPTS_DIR/.limit-alerts-options" <<EOF
LANG=$LANG_UM
WARN=$OPT_WARN
CRIT=$OPT_CRIT
INTERVAL=$OPT_INTERVAL
COMPACT_WARN=$OPT_COMPACT_WARN
COMPACT_ADVISOR=$WITH_COMPACT_ADVISOR
AUTO_COMPACT_WINDOW_SET=$AUTO_COMPACT_WINDOW_SET
STATUSLINE_MODEL=$WITH_STATUSLINE_MODEL
SUBAGENT_MODEL=$WITH_SUBAGENT_MODEL
FORECAST=$WITH_FORECAST
SPEND_ALERT=$WITH_SPEND_ALERT
UNUSED_ALERT=$WITH_UNUSED_ALERT
STATUSLINE_PACE=$WITH_STATUSLINE_PACE
GUARD_FANOUT=$WITH_GUARD_FANOUT
MODEL_HINT=$WITH_MODEL_HINT
EOF

if [ "$WITH_STATUSLINE" = "1" ]; then
  # preserve the current statusline command so the wrapper keeps rendering it
  PREV_CMD=$("$JQ" -r '.statusLine.command // ""' "$SETTINGS")
  if [ -n "$PREV_CMD" ] && ! echo "$PREV_CMD" | grep -q "statusline-with-limits"; then
    printf '%s\n' "$PREV_CMD" > "$SCRIPTS_DIR/statusline-base.cmd"
    echo "    Previous statusline preserved in statusline-base.cmd"
  fi
  updated=$("$JQ" '.statusLine = {
      type: "command",
      command: "bash \"$HOME/.claude/scripts/statusline-with-limits.sh\"",
      refreshInterval: 60
    }' "$SETTINGS")
  echo "$updated" > "$SETTINGS"
  echo "    Statusline switched to statusline-with-limits.sh"
fi

if [ "$WITH_LAUNCHD" = "1" ]; then
  echo "==> Installing launchd agent"
  PLIST="$HOME/Library/LaunchAgents/com.claude.usage-monitor.plist"
  mkdir -p "$HOME/Library/LaunchAgents"
  EXISTING_PLIST_ARG=""
  [ -f "$PLIST" ] && EXISTING_PLIST_ARG="$PLIST"
  generate_plist "$REPO_DIR/launchd/com.claude.usage-monitor.plist.template" "$PLIST" "$PROXY_ARG" "$EXISTING_PLIST_ARG" \
    "" "" "" "$OPT_INTERVAL"
  print_proxy_status "$PLIST" "$PROXY_ARG"
  launchctl bootout "gui/$(id -u)/com.claude.usage-monitor" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
  echo "    Agent loaded (checks every ${OPT_INTERVAL:-92} seconds)"
fi

echo
echo "Done! Check current limits with:"
echo "  $SCRIPTS_DIR/usage-monitor.sh status"
echo
echo "Restart Claude Code (or open /hooks once) so it picks up the new hooks."
