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
    --proxy)
      [ $# -ge 2 ] || { echo "--proxy requires a value" >&2; exit 1; }
      shift; PROXY_URL="$1"; PROXY_FLAG_SET=1 ;;
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

# Опции, выбранные при установке. Для установок, сделанных до появления
# файла, новые фичи считаются выключенными — update.sh не включает то,
# чего пользователь не ставил.
OPTIONS_FILE="$SCRIPTS_DIR/.limit-alerts-options"
OPT_COMPACT_ADVISOR=0
OPT_GUARD_FANOUT=0
# Numbers chosen at install time; empty means the script's own default.
opt_value() { sed -n "s/^$1=\([0-9][0-9]*\)$/\1/p" "$OPTIONS_FILE" 2>/dev/null | tail -n 1; }
OPT_WARN=$(opt_value WARN)
OPT_CRIT=$(opt_value CRIT)
OPT_INTERVAL=$(opt_value INTERVAL)
OPT_COMPACT_WARN=$(opt_value COMPACT_WARN)
if [ -f "$OPTIONS_FILE" ]; then
  if grep -q '^COMPACT_ADVISOR=1$' "$OPTIONS_FILE"; then OPT_COMPACT_ADVISOR=1; fi
  if grep -q '^GUARD_FANOUT=1$' "$OPTIONS_FILE"; then OPT_GUARD_FANOUT=1; fi
fi

if [ -f "$PLIST" ]; then
  NEW_PLIST_TMP=$(mktemp)
  generate_plist "$REPO_DIR/launchd/com.claude.usage-monitor.plist.template" "$NEW_PLIST_TMP" "$PROXY_ARG" "$PLIST" \
    "" "" "" "$OPT_INTERVAL"
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

if [ "$INSTALLED_VERSION" = "$REPO_VERSION" ]; then
  echo "Уже установлена последняя версия (v$REPO_VERSION)"
  exit 0
fi

echo "==> Обновление: $INSTALLED_VERSION -> $REPO_VERSION"
[ "$DRY_RUN" = "1" ] && echo "    (--dry-run: изменения не применяются)"

UPDATE_FILES="usage-monitor.sh statusline-with-limits.sh notify-attention.sh"
if [ "$OPT_COMPACT_ADVISOR" = "1" ]; then UPDATE_FILES="$UPDATE_FILES compact-advisor.sh"; fi
if [ "$OPT_GUARD_FANOUT" = "1" ]; then UPDATE_FILES="$UPDATE_FILES fanout-guard.sh"; fi

# Остатки от <= 0.4.0: авто-продолжение убрано, его делает сам Claude Code
# («Continue automatically at usage limit» в /config). Файлы удаляются, иначе
# рядом с обновлёнными скриптами останется рабочий auto-resume.sh поверх
# состояния, которое больше никто не пишет.
if [ -f "$SCRIPTS_DIR/auto-resume.sh" ] || [ -f "$SCRIPTS_DIR/auto-resume-state.json" ]; then
  if [ "$DRY_RUN" = "1" ]; then
    echo "    would remove: auto-resume.sh и его состояние (фича удалена в 0.5.0)"
  else
    rm -f "$SCRIPTS_DIR/auto-resume.sh" "$SCRIPTS_DIR/auto-resume-state.json"
    rm -f "$SCRIPTS_DIR"/auto-resume-*.lock
    echo "    removed: auto-resume.sh — теперь это умеет сам Claude Code (/config)"
  fi
fi

# shellcheck disable=SC2086  # deliberate word splitting over a space-separated list
for f in $UPDATE_FILES; do
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

OPT_LANG=""
if [ -f "$OPTIONS_FILE" ]; then
  OPT_LANG=$(sed -n 's/^LANG=//p' "$OPTIONS_FILE")
fi

if [ "$DRY_RUN" = "1" ]; then
  echo "    would re-apply install-time defaults (--lang / statusline and notification flags)"
else
  if [ -n "$OPT_LANG" ] && [ "$OPT_LANG" != "ru" ]; then
    # shellcheck disable=SC2086  # deliberate word splitting over a space-separated list
    for f in $UPDATE_FILES; do
      [ -f "$SCRIPTS_DIR/$f" ] && \
        sed -i '' "s/\${UM_LANG:-ru}/\${UM_LANG:-$OPT_LANG}/" "$SCRIPTS_DIR/$f"
    done
  fi
  if [ -f "$SCRIPTS_DIR/statusline-with-limits.sh" ]; then
    if grep -q '^STATUSLINE_MODEL=0$' "$OPTIONS_FILE" 2>/dev/null; then
      sed -i '' 's/\${UM_STATUSLINE_MODEL:-1}/\${UM_STATUSLINE_MODEL:-0}/' \
        "$SCRIPTS_DIR/statusline-with-limits.sh"
    fi
    if grep -q '^SUBAGENT_MODEL=0$' "$OPTIONS_FILE" 2>/dev/null; then
      sed -i '' 's/\${UM_SUBAGENT_MODEL:-1}/\${UM_SUBAGENT_MODEL:-0}/' \
        "$SCRIPTS_DIR/statusline-with-limits.sh"
    fi
    if grep -q '^STATUSLINE_PACE=0$' "$OPTIONS_FILE" 2>/dev/null; then
      sed -i '' 's/\${UM_STATUSLINE_PACE:-1}/\${UM_STATUSLINE_PACE:-0}/' \
        "$SCRIPTS_DIR/statusline-with-limits.sh"
    fi
  fi
  # An options file from before these keys existed has neither line, and
  # both stay on, as they were installed.
  if [ -f "$SCRIPTS_DIR/usage-monitor.sh" ]; then
    if grep -q '^FORECAST=0$' "$OPTIONS_FILE" 2>/dev/null; then
      sed -i '' 's/\${UM_FORECAST:-1}/\${UM_FORECAST:-0}/' "$SCRIPTS_DIR/usage-monitor.sh"
    fi
    if grep -q '^SPEND_ALERT=0$' "$OPTIONS_FILE" 2>/dev/null; then
      sed -i '' 's/\${UM_SPEND_ALERT:-1}/\${UM_SPEND_ALERT:-0}/' "$SCRIPTS_DIR/usage-monitor.sh"
    fi
    if grep -q '^UNUSED_ALERT=0$' "$OPTIONS_FILE" 2>/dev/null; then
      sed -i '' 's/\${UM_UNUSED_ALERT:-1}/\${UM_UNUSED_ALERT:-0}/' "$SCRIPTS_DIR/usage-monitor.sh"
    fi
    if grep -q '^MODEL_HINT=1$' "$OPTIONS_FILE" 2>/dev/null; then
      sed -i '' 's/\${UM_MODEL_HINT:-0}/\${UM_MODEL_HINT:-1}/' "$SCRIPTS_DIR/usage-monitor.sh"
    fi
  fi
  if [ -n "$OPT_WARN" ]; then
    for f in usage-monitor.sh statusline-with-limits.sh; do
      [ -f "$SCRIPTS_DIR/$f" ] && sed -i '' "s/\${UM_WARN:-80}/\${UM_WARN:-$OPT_WARN}/" "$SCRIPTS_DIR/$f"
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
  # Installed only with --guard-fanout, and switched on there (see install.sh).
  if [ -f "$SCRIPTS_DIR/fanout-guard.sh" ]; then
    sed -i '' 's/\${UM_GUARD_FANOUT:-0}/\${UM_GUARD_FANOUT:-1}/' "$SCRIPTS_DIR/fanout-guard.sh"
  fi
  echo "    install-time defaults re-applied"
fi

if [ "$DRY_RUN" = "1" ]; then
  echo "    would re-check hook registration in $SETTINGS"
else
  cp "$SETTINGS" "$SETTINGS.bak.limit-alerts-update"
  register_monitor_hooks
  if [ -f "$SCRIPTS_DIR/notify-attention.sh" ]; then
    register_attention_hooks
  fi
  if [ "$OPT_COMPACT_ADVISOR" = "1" ] && [ -f "$SCRIPTS_DIR/compact-advisor.sh" ]; then
    register_compact_advisor_hook
  fi
  if [ "$OPT_GUARD_FANOUT" = "1" ] && [ -f "$SCRIPTS_DIR/fanout-guard.sh" ]; then
    register_fanout_guard_hook
  fi
  echo "    hooks reconciled (backup: $SETTINGS.bak.limit-alerts-update)"
fi

if [ "$DRY_RUN" = "1" ]; then
  echo "    would write $VERSION_FILE = $REPO_VERSION"
else
  echo "$REPO_VERSION" > "$VERSION_FILE"
  echo "    version marker updated"
fi

if [ ! -f "$OPTIONS_FILE" ]; then
  echo
  echo "==> Новое в этой версии (не включено, т.к. установка сделана раньше):"
  echo "    авто-продолжение сессии после сброса лимита и подсказка о /compact."
  echo "    Включить: ./install.sh (перечитает настройки, существующие хуки сохранятся)"
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
