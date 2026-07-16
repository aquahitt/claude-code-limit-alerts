#!/usr/bin/env bash
# install.sh — installs claude-code-limit-alerts (macOS only).
#
# What it does:
#   1. Copies scripts to ~/.claude/scripts/
#   2. Adds Stop + SessionStart hooks to ~/.claude/settings.json
#      (existing hooks are preserved; a backup of settings.json is made)
#   3. Optionally replaces the statusline with the limits-aware wrapper
#      (your previous statusline command is preserved and keeps rendering)
#   4. Installs and loads a launchd agent (checks limits every 5 minutes,
#      catches window resets even when Claude Code is closed)
#
# Flags:
#   --no-statusline   skip statusline integration
#   --no-launchd      skip the background launchd agent
#   --lang en|ru      notification language (default: ru)

set -euo pipefail

if [ "$(uname -s)" != "Darwin" ]; then
  echo "Only macOS is supported for now (Windows/Linux support is planned)." >&2
  exit 1
fi

WITH_STATUSLINE=1
WITH_LAUNCHD=1
LANG_UM="ru"
while [ $# -gt 0 ]; do
  case "$1" in
    --no-statusline) WITH_STATUSLINE=0 ;;
    --no-launchd)    WITH_LAUNCHD=0 ;;
    --lang)          shift; LANG_UM="${1:-ru}" ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
  shift
done

JQ="$(command -v jq || true)"
if [ -z "$JQ" ]; then
  echo "jq is required. Install it with: brew install jq" >&2
  exit 1
fi

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS_DIR="$HOME/.claude/scripts"
SETTINGS="$HOME/.claude/settings.json"

echo "==> Installing scripts to $SCRIPTS_DIR"
mkdir -p "$SCRIPTS_DIR"
cp "$REPO_DIR/scripts/usage-monitor.sh" "$SCRIPTS_DIR/"
cp "$REPO_DIR/scripts/statusline-with-limits.sh" "$SCRIPTS_DIR/"
chmod +x "$SCRIPTS_DIR/usage-monitor.sh" "$SCRIPTS_DIR/statusline-with-limits.sh"

# persist language choice by prepending an env default (only if not ru)
if [ "$LANG_UM" != "ru" ]; then
  for f in usage-monitor.sh statusline-with-limits.sh; do
    sed -i '' "s/\${UM_LANG:-ru}/\${UM_LANG:-$LANG_UM}/" "$SCRIPTS_DIR/$f"
  done
fi

echo "==> Updating $SETTINGS"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
cp "$SETTINGS" "$SETTINGS.bak.limit-alerts"
echo "    (backup: $SETTINGS.bak.limit-alerts)"

HOOK_CMD='bash "$HOME/.claude/scripts/usage-monitor.sh" hook'
HOOK_JSON=$("$JQ" -n --arg cmd "$HOOK_CMD" \
  '{type: "command", command: $cmd, timeout: 20}')

add_hook() { # $1 = event name
  local updated
  updated=$("$JQ" --arg cmd "$HOOK_CMD" --argjson h "$HOOK_JSON" --arg ev "$1" '
    .hooks //= {} |
    .hooks[$ev] //= [{hooks: []}] |
    if ([.hooks[$ev][].hooks[]?.command] | index($cmd)) then .
    else .hooks[$ev][0].hooks += [$h] end
  ' "$SETTINGS")
  echo "$updated" > "$SETTINGS"
}
add_hook "Stop"
add_hook "SessionStart"
echo "    Hooks added: Stop, SessionStart"

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
  sed "s|__HOME__|$HOME|g" "$REPO_DIR/launchd/com.claude.usage-monitor.plist.template" > "$PLIST"
  launchctl bootout "gui/$(id -u)/com.claude.usage-monitor" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
  echo "    Agent loaded (checks every 5 minutes)"
fi

echo
echo "Done! Check current limits with:"
echo "  $SCRIPTS_DIR/usage-monitor.sh status"
echo
echo "Restart Claude Code (or open /hooks once) so it picks up the new hooks."
