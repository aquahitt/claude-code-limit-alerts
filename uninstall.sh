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
               | (contains("usage-monitor.sh") or contains("notify-attention.sh")
                  or contains("compact-advisor.sh")) | not)))
             | map(select(.hooks | length > 0))
       else . end) |
    .hooks |= with_entries(select(.value != null and .value != []))
  ' "$SETTINGS")
  echo "$updated" > "$SETTINGS"

  # Only remove the auto-compact threshold if we were the ones who set it —
  # a value the user configured themselves is not ours to delete.
  if grep -q '^AUTO_COMPACT_WINDOW_SET=1$' "$SCRIPTS_DIR/.limit-alerts-options" 2>/dev/null; then
    updated=$("$JQ" 'del(.autoCompactWindow)' "$SETTINGS")
    echo "$updated" > "$SETTINGS"
    echo "==> Auto-compact window setting removed"
  fi

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
# auto-resume.sh, auto-resume-state.json and the lock files below belong to a
# feature removed in 0.5.0 — kept in this list because installs made with
# <= 0.4.0 may still have them lying around.
rm -f "$SCRIPTS_DIR/usage-monitor.sh" \
      "$SCRIPTS_DIR/statusline-with-limits.sh" \
      "$SCRIPTS_DIR/notify-attention.sh" \
      "$SCRIPTS_DIR/auto-resume.sh" \
      "$SCRIPTS_DIR/compact-advisor.sh" \
      "$SCRIPTS_DIR/statusline-base.cmd" \
      "$SCRIPTS_DIR/usage-monitor-state.json" \
      "$SCRIPTS_DIR/usage-monitor-cache.json" \
      "$SCRIPTS_DIR/auto-resume-state.json" \
      "$SCRIPTS_DIR/compact-advisor-state.json" \
      "$SCRIPTS_DIR/.limit-alerts-version" \
      "$SCRIPTS_DIR/.limit-alerts-options"
rm -f "$SCRIPTS_DIR"/auto-resume-*.lock
# usage-monitor.lock is a directory, and normally exists only while a check
# runs; a run killed mid-update can leave it behind.
rmdir "$SCRIPTS_DIR/usage-monitor.lock" 2>/dev/null || true

echo "Done. Restart Claude Code to apply."
