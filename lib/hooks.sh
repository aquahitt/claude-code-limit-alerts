#!/usr/bin/env bash
# lib/hooks.sh — общая логика регистрации хуков для install.sh и update.sh.
# Не копируется в ~/.claude — подключается через `source` прямо из репозитория.

resolve_jq() {
  JQ="$(command -v jq || true)"
  if [ -z "$JQ" ]; then
    echo "jq is required. Install it with: brew install jq" >&2
    exit 1
  fi
}

# $1 = имя события ("Stop", "SessionStart", "Notification"),
# $2 = JSON-объект хука (обязательно с полем .command).
# Требует $JQ и $SETTINGS.
add_hook() {
  local event="$1" hook_json="$2" cmd updated
  cmd=$(echo "$hook_json" | "$JQ" -r '.command')
  updated=$("$JQ" --arg cmd "$cmd" --argjson h "$hook_json" --arg ev "$event" '
    .hooks //= {} |
    .hooks[$ev] //= [{hooks: []}] |
    if ([.hooks[$ev][].hooks[]?.command] | index($cmd)) then .
    else .hooks[$ev][0].hooks += [$h] end
  ' "$SETTINGS")
  echo "$updated" > "$SETTINGS"
}

# Регистрирует Stop/SessionStart -> usage-monitor.sh hook. Требует $JQ, $SETTINGS.
register_monitor_hooks() {
  local hook
  hook=$("$JQ" -n '{type: "command",
    command: "bash \"$HOME/.claude/scripts/usage-monitor.sh\" hook", timeout: 20}')
  add_hook "Stop" "$hook"
  add_hook "SessionStart" "$hook"
}

# Регистрирует Notification/Stop -> notify-attention.sh. Требует $JQ, $SETTINGS.
register_attention_hooks() {
  add_hook "Notification" "$("$JQ" -n '{type: "command",
    command: "bash \"$HOME/.claude/scripts/notify-attention.sh\" notification", async: true}')"
  add_hook "Stop" "$("$JQ" -n '{type: "command",
    command: "bash \"$HOME/.claude/scripts/notify-attention.sh\" stop", async: true}')"
}

# Регистрирует Stop -> compact-advisor.sh. Требует $JQ, $SETTINGS.
register_compact_advisor_hook() {
  add_hook "Stop" "$("$JQ" -n '{type: "command",
    command: "bash \"$HOME/.claude/scripts/compact-advisor.sh\"", timeout: 10}')"
}

# Удаляет из hooks (Stop/SessionStart/Notification) все записи, чья команда
# содержит подстроку $1 (например "compact-advisor.sh") — форма фильтра как
# в uninstall.sh. Нужна install.sh, чтобы повторная установка с --no-* флагом
# действительно отключала хук, а не просто переставала переустанавливать
# скрипт. Требует $JQ, $SETTINGS.
remove_hook_matching() {
  local pattern="$1" updated
  updated=$("$JQ" --arg p "$pattern" '
    .hooks //= {} |
    (.hooks.Stop, .hooks.SessionStart, .hooks.Notification) |=
      (if . then map(.hooks |= map(select(.command // "" | contains($p) | not)))
             | map(select(.hooks | length > 0))
       else . end) |
    .hooks |= with_entries(select(.value != null and .value != []))
  ' "$SETTINGS")
  echo "$updated" > "$SETTINGS"
}
