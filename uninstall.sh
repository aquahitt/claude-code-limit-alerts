#!/usr/bin/env bash
# uninstall.sh — removes claude-code-limit-alerts.

set -euo pipefail

JQ="$(command -v jq || true)"
SCRIPTS_DIR="$HOME/.claude/scripts"
SETTINGS="$HOME/.claude/settings.json"
PLIST="$HOME/Library/LaunchAgents/com.claude.usage-monitor.plist"

echo "==> Unloading launchd agent"
launchctl bootout "gui/$(id -u)/com.claude.usage-monitor" 2>/dev/null || true
rm -f "$PLIST"

if [ -n "$JQ" ] && [ -f "$SETTINGS" ]; then
  echo "==> Removing hooks from $SETTINGS"
  cp "$SETTINGS" "$SETTINGS.bak.limit-alerts-uninstall"
  updated=$("$JQ" '
    .hooks //= {} |
    (.hooks.Stop, .hooks.SessionStart, .hooks.Notification) |=
      (if . then map(.hooks |= map(select(.command // ""
               | (contains("usage-monitor.sh") or contains("notify-attention.sh")) | not)))
             | map(select(.hooks | length > 0))
       else . end) |
    .hooks |= with_entries(select(.value != null and .value != []))
  ' "$SETTINGS")
  echo "$updated" > "$SETTINGS"

  # restore the previous statusline if we wrapped one
  CUR_SL=$("$JQ" -r '.statusLine.command // ""' "$SETTINGS")
  if echo "$CUR_SL" | grep -q "statusline-with-limits"; then
    if [ -f "$SCRIPTS_DIR/statusline-base.cmd" ]; then
      PREV_CMD=$(cat "$SCRIPTS_DIR/statusline-base.cmd")
      updated=$("$JQ" --arg cmd "$PREV_CMD" \
        '.statusLine = {type: "command", command: $cmd}' "$SETTINGS")
    else
      updated=$("$JQ" 'del(.statusLine)' "$SETTINGS")
    fi
    echo "$updated" > "$SETTINGS"
    echo "==> Statusline restored"
  fi
fi

echo "==> Removing scripts and state"
rm -f "$SCRIPTS_DIR/usage-monitor.sh" \
      "$SCRIPTS_DIR/statusline-with-limits.sh" \
      "$SCRIPTS_DIR/notify-attention.sh" \
      "$SCRIPTS_DIR/statusline-base.cmd" \
      "$SCRIPTS_DIR/usage-monitor-state.json" \
      "$SCRIPTS_DIR/usage-monitor-cache.json"

echo "Done. Restart Claude Code to apply."
