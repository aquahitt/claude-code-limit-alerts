#!/usr/bin/env bash
# lib/launchd.sh — общая генерация launchd plist для install.sh и update.sh,
# включая проброс прокси-переменных окружения (launchd не наследует шелл-
# профиль, поэтому HTTP_PROXY/HTTPS_PROXY из ~/.zshrc туда не попадают сами
# по себе). Не копируется в ~/.claude — подключается через `source` прямо из
# репозитория. Требует $JQ (resolve_jq из lib/hooks.sh).

LAUNCHD_PROXY_VAR_NAMES="HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY http_proxy https_proxy all_proxy no_proxy"

xml_escape() {
  local s="$1"
  s="${s//&/&amp;}"
  s="${s//</&lt;}"
  s="${s//>/&gt;}"
  printf '%s' "$s"
}

# $1 = путь к шаблону, $2 = путь для записи, $3 = explicit_proxy
# ("" | URL | "__DISABLE__"), $4 = путь к уже установленному plist (можно "").
generate_plist() {
  local template="$1" out="$2" explicit="${3:-}" existing="${4:-}"
  local existing_json="{}"
  if [ -n "$existing" ] && [ -f "$existing" ]; then
    existing_json=$(plutil -convert json -o - "$existing" 2>/dev/null) || existing_json="{}"
  fi

  local env_lines="" name value preserved
  if [ "$explicit" != "__DISABLE__" ]; then
    for name in $LAUNCHD_PROXY_VAR_NAMES; do
      value="${!name:-}"
      if [ -z "$value" ]; then
        preserved=$(printf '%s' "$existing_json" \
          | "$JQ" -r --arg k "$name" '.EnvironmentVariables[$k] // empty' 2>/dev/null) || preserved=""
        value="$preserved"
      fi
      case "$name" in
        HTTP_PROXY|http_proxy|HTTPS_PROXY|https_proxy)
          [ -n "$explicit" ] && value="$explicit"
          ;;
      esac
      if [ -n "$value" ]; then
        env_lines="${env_lines}        <key>$(xml_escape "$name")</key>
        <string>$(xml_escape "$value")</string>
"
      fi
    done
  fi

  local env_block=""
  if [ -n "$env_lines" ]; then
    env_block="    <key>EnvironmentVariables</key>
    <dict>
${env_lines}    </dict>
"
  fi

  : > "$out"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      *__ENV_VARS__*)
        [ -n "$env_block" ] && printf '%s' "$env_block" >> "$out"
        ;;
      *)
        printf '%s\n' "${line//__HOME__/$HOME}" >> "$out"
        ;;
    esac
  done < "$template"
  chmod 600 "$out"
}

# $1 = путь к сгенерированному plist, $2 = explicit_proxy (тот же, что был
# передан в generate_plist). Печатает только имена переменных, никогда сами
# значения (могут содержать креды вида user:pass@host).
print_proxy_status() {
  local plist="$1" explicit="${2:-}" keys
  if [ "$explicit" = "__DISABLE__" ]; then
    echo "    Proxy passthrough disabled for launchd agent"
    return 0
  fi
  keys=$(plutil -convert json -o - "$plist" 2>/dev/null \
    | "$JQ" -r '.EnvironmentVariables // {} | keys | join(", ")' 2>/dev/null) || keys=""
  [ -n "$keys" ] && echo "    Proxy config for launchd agent: $keys (plist permissions restricted to 600)"
  return 0
}
