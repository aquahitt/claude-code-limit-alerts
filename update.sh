#!/usr/bin/env bash
# update.sh — синхронизирует установленный claude-code-limit-alerts с текущим
# состоянием локальной копии репозитория. НЕ делает git pull/fetch сам —
# обновите репозиторий (git pull) перед запуском.
#
# Флаги:
#   --dry-run         показать, что будет сделано, ничего не меняя
#   --proxy <url>|""  прокси для launchd-агента (по умолчанию — auto-detect
#                     из HTTP_PROXY/HTTPS_PROXY/ALL_PROXY/NO_PROXY текущего
#                     шелла, без учёта регистра); "" отключает passthrough

set -euo pipefail

if [ "$(uname -s)" != "Darwin" ]; then
  echo "Only macOS is supported for now (Windows/Linux support is planned)." >&2
  exit 1
fi

DRY_RUN=0
PROXY_URL=""
PROXY_FLAG_SET=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --proxy)   shift; PROXY_URL="${1:-}"; PROXY_FLAG_SET=1 ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
  shift
done

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$REPO_DIR/lib/hooks.sh"
source "$REPO_DIR/lib/launchd.sh"
resolve_jq

PROXY_ARG="$PROXY_URL"
[ "$PROXY_FLAG_SET" = "1" ] && [ -z "$PROXY_URL" ] && PROXY_ARG="__DISABLE__"

SCRIPTS_DIR="$HOME/.claude/scripts"
SETTINGS="$HOME/.claude/settings.json"
VERSION_FILE="$SCRIPTS_DIR/.limit-alerts-version"
PLIST="$HOME/Library/LaunchAgents/com.claude.usage-monitor.plist"

if [ ! -d "$SCRIPTS_DIR" ]; then
  echo "Похоже, проект не установлен — запустите ./install.sh" >&2
  exit 1
fi

REPO_VERSION="$(cat "$REPO_DIR/VERSION")"
INSTALLED_VERSION="unknown"
[ -f "$VERSION_FILE" ] && INSTALLED_VERSION="$(cat "$VERSION_FILE")"

if [ "$INSTALLED_VERSION" = "$REPO_VERSION" ]; then
  echo "Уже установлена последняя версия (v$REPO_VERSION)"
  exit 0
fi

echo "==> Обновление: $INSTALLED_VERSION -> $REPO_VERSION"
[ "$DRY_RUN" = "1" ] && echo "    (--dry-run: изменения не применяются)"

for f in usage-monitor.sh statusline-with-limits.sh notify-attention.sh; do
  if [ -f "$SCRIPTS_DIR/$f" ]; then
    if [ "$DRY_RUN" = "1" ]; then
      echo "    would update: $SCRIPTS_DIR/$f"
    else
      cp "$REPO_DIR/scripts/$f" "$SCRIPTS_DIR/"
      chmod +x "$SCRIPTS_DIR/$f"
      echo "    updated: $SCRIPTS_DIR/$f"
    fi
  fi
done

if [ -f "$PLIST" ]; then
  NEW_PLIST_TMP=$(mktemp)
  generate_plist "$REPO_DIR/launchd/com.claude.usage-monitor.plist.template" "$NEW_PLIST_TMP" "$PROXY_ARG" "$PLIST"
  if ! diff -q "$NEW_PLIST_TMP" "$PLIST" >/dev/null 2>&1; then
    if [ "$DRY_RUN" = "1" ]; then
      echo "    would reload launchd agent (plist changed)"
    else
      cp "$NEW_PLIST_TMP" "$PLIST"
      chmod 600 "$PLIST"
      launchctl bootout "gui/$(id -u)/com.claude.usage-monitor" 2>/dev/null || true
      launchctl bootstrap "gui/$(id -u)" "$PLIST"
      print_proxy_status "$PLIST" "$PROXY_ARG"
      echo "    launchd agent reloaded"
    fi
  fi
  rm -f "$NEW_PLIST_TMP"
fi

if [ "$DRY_RUN" = "1" ]; then
  echo "    would re-check hook registration in $SETTINGS"
else
  cp "$SETTINGS" "$SETTINGS.bak.limit-alerts-update"
  register_monitor_hooks
  if [ -f "$SCRIPTS_DIR/notify-attention.sh" ]; then
    register_attention_hooks
  fi
  echo "    hooks reconciled (backup: $SETTINGS.bak.limit-alerts-update)"
fi

if [ "$DRY_RUN" = "1" ]; then
  echo "    would write $VERSION_FILE = $REPO_VERSION"
else
  echo "$REPO_VERSION" > "$VERSION_FILE"
  echo "    version marker updated"
fi

echo
echo "==> Что изменилось:"
if [ -f "$REPO_DIR/CHANGELOG.md" ]; then
  if [ "$INSTALLED_VERSION" = "unknown" ]; then
    awk -v repo="$REPO_VERSION" '
      /^## \[/ {
        ver=$0; sub(/^## \[/,"",ver); sub(/\].*/,"",ver)
        p = (ver == repo)
      }
      p
    ' "$REPO_DIR/CHANGELOG.md"
  else
    awk -v repo="$REPO_VERSION" -v installed="$INSTALLED_VERSION" '
      /^## \[/ {
        ver=$0; sub(/^## \[/,"",ver); sub(/\].*/,"",ver)
        if (ver == installed) { p=0 }
        else if (ver == repo) { p=1 }
      }
      p
    ' "$REPO_DIR/CHANGELOG.md"
  fi
fi
