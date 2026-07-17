# Версионность и update.sh — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Дать проекту номер версии + changelog и лёгкий `update.sh`, который синхронизирует уже установленные в `~/.claude/` файлы с текущей локальной копией репозитория, не трогая то, что пользователь не устанавливал.

**Architecture:** `VERSION` (repo root) — источник истины. `~/.claude/scripts/.limit-alerts-version` — установленная версия. `lib/hooks.sh` — общая для `install.sh` и `update.sh` логика регистрации хуков (устраняет дублирование). `update.sh` сравнивает версии, перекладывает файлы, которые уже присутствуют у пользователя, перезагружает launchd при изменении plist, дозаявляет хуки идемпотентно, печатает относящийся diff из `CHANGELOG.md`.

**Tech Stack:** bash, jq, launchd, macOS `security`/`launchctl`. Без тестового фреймворка — весь проект на чистом bash без раннера тестов, проверка каждого шага — ручная (реальные shell-команды с ожидаемым выводом), как уже принято в этом репозитории.

## Global Constraints

- Только macOS (как и весь остальной проект).
- `jq` обязателен — при отсутствии печатать `jq is required. Install it with: brew install jq` и выходить с кодом 1 (та же формулировка, что уже в `install.sh`).
- `update.sh` НЕ делает `git pull`/`fetch` сам — только синхронизирует уже присутствующую локальную копию репозитория.
- `update.sh` не включает функции, которые не были установлены изначально (`--no-attention`/`--no-statusline`/`--no-launchd` уважаются постфактум через проверку наличия файла/plist).
- Версии сравниваются только по номеру (semver-строка), без хэширования содержимого файлов.
- Любые правки, трогающие реальный `~/.claude/settings.json` или реальный launchd-агент во время тестирования шагов, ДОЛЖНЫ выполняться с переопределённым `HOME` (sandboxed), а не против настоящего окружения пользователя.

---

### Task 1: `VERSION` и `CHANGELOG.md`

**Files:**
- Create: `VERSION`
- Create: `CHANGELOG.md`

**Interfaces:**
- Produces: `VERSION` — файл из одной строки `0.2.0` (без дополнительных символов кроме завершающего перевода строки), читаемый как `$(cat VERSION)` из `install.sh`/`update.sh`. `CHANGELOG.md` — формат Keep a Changelog, секции `## [X.Y.Z] - YYYY-MM-DD`, читаемые построчно через `awk` в `update.sh` (Task 4).

- [ ] **Step 1: Создать `VERSION`**

```
0.2.0
```

- [ ] **Step 2: Создать `CHANGELOG.md`**

```markdown
# Changelog

Формат — [Keep a Changelog](https://keepachangelog.com/ru/1.1.0/), версии — [SemVer](https://semver.org/lang/ru/).

## [0.2.0] - 2026-07-17

### Added
- Версионность проекта (`VERSION`, этот `CHANGELOG.md`).
- `update.sh` — синхронизирует установленные скрипты, launchd-агент и хуки с текущим состоянием локальной копии репозитория, без `git pull` внутри себя. Поддерживает `--dry-run`.
- `usage-monitor.sh status` теперь первой строкой печатает установленную версию.

### Changed
- Логика регистрации хуков (`add_hook` и обёртки над ней) вынесена в `lib/hooks.sh`, используется и `install.sh`, и `update.sh` — раньше была продублирована.

## [0.1.0] - 2026-07-16

### Added
- Мониторинг лимитов Claude Code (сессия 5ч, неделя): уведомления и сообщения в интерфейсе Claude Code при приближении к порогам 80%/95% и при сбросе окна.
- Уведомления «требуется внимание» (баннер + звук) на события Notification/Stop.
- Statusline-обёртка с процентами всех лимитов.
- Фоновый launchd-агент (проверка каждые 5 минут), `install.sh`/`uninstall.sh`.

### Fixed
- Ложные алерты о сбросе окна из-за ±1с джиттера `resets_at` в ответе API.
- Тихие сбои опроса (`fetch_usage`) теперь пишутся в `usage-monitor.log` с указанием причины, вместо молчаливого `exit 0`.
- Для team/org-аккаунтов (403 на живом эндпойнте) и протухших OAuth-токенов — принудительное обновление локального кэша через `claude -p "/usage"` в режимах `cron`/`status`.
```

- [ ] **Step 3: Проверить**

```bash
cat VERSION
# Ожидается: 0.2.0
grep -c '^## \[' CHANGELOG.md
# Ожидается: 2
```

- [ ] **Step 4: Commit**

```bash
git add VERSION CHANGELOG.md
git commit -m "chore: add VERSION and CHANGELOG.md"
```

---

### Task 2: `lib/hooks.sh`

**Files:**
- Create: `lib/hooks.sh`

**Interfaces:**
- Consumes: ничего (чистая библиотека, только глобальные переменные `$JQ`/`$SETTINGS`, устанавливаемые вызывающим скриптом).
- Produces:
  - `resolve_jq()` — устанавливает глобальную `$JQ`; если `jq` не найден в `PATH`, печатает ошибку в stderr и завершает процесс (`exit 1`).
  - `add_hook "$event" "$hook_json"` — идемпотентно добавляет хук в `$SETTINGS` (JSON-файл).
  - `register_monitor_hooks()` — регистрирует хуки `Stop`+`SessionStart` на `usage-monitor.sh hook`.
  - `register_attention_hooks()` — регистрирует хуки `Notification`+`Stop` на `notify-attention.sh`.
  - Все четыре функции ожидают, что `$JQ` и (для `add_hook`/`register_*`) `$SETTINGS` уже установлены вызывающим кодом.

- [ ] **Step 1: Написать `lib/hooks.sh`**

```bash
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
```

- [ ] **Step 2: Синтаксическая проверка**

```bash
mkdir -p lib
bash -n lib/hooks.sh
```
Ожидается: без вывода (успех).

- [ ] **Step 3: Функциональная проверка в песочнице (без касания реального `~/.claude`)**

```bash
SCRATCH=$(mktemp -d)
echo '{}' > "$SCRATCH/settings.json"
(
  source lib/hooks.sh
  resolve_jq
  SETTINGS="$SCRATCH/settings.json"
  register_monitor_hooks
  register_attention_hooks
  # второй вызов должен быть идемпотентным — без дублей
  register_monitor_hooks
  register_attention_hooks
)
jq '.hooks.Stop | length, (.hooks.Stop[0].hooks | length), .hooks.SessionStart[0].hooks | length, .hooks.Notification[0].hooks | length' "$SCRATCH/settings.json"
rm -rf "$SCRATCH"
```
Ожидается: `.hooks.Stop[0].hooks` содержит ровно 2 записи (usage-monitor + notify-attention stop), `.hooks.SessionStart[0].hooks` — 1, `.hooks.Notification[0].hooks` — 1 (несмотря на двойной вызов — дублей нет).

- [ ] **Step 4: Commit**

```bash
git add lib/hooks.sh
git commit -m "refactor: extract hook registration into lib/hooks.sh"
```

---

### Task 3: `install.sh` — использовать `lib/hooks.sh`, писать версию

**Files:**
- Modify: `install.sh`

**Interfaces:**
- Consumes: `lib/hooks.sh` (Task 2) — `resolve_jq`, `register_monitor_hooks`, `register_attention_hooks`. `VERSION` (Task 1).
- Produces: `~/.claude/scripts/.limit-alerts-version` — файл с содержимым `VERSION` репозитория, создаётся при каждой установке.

- [ ] **Step 1: Заменить блок определения `jq` и вставить `source lib/hooks.sh`**

```bash
old_string:
JQ="$(command -v jq || true)"
if [ -z "$JQ" ]; then
  echo "jq is required. Install it with: brew install jq" >&2
  exit 1
fi

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS_DIR="$HOME/.claude/scripts"
SETTINGS="$HOME/.claude/settings.json"

new_string:
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$REPO_DIR/lib/hooks.sh"
resolve_jq

SCRIPTS_DIR="$HOME/.claude/scripts"
SETTINGS="$HOME/.claude/settings.json"
```

- [ ] **Step 2: Записать версию сразу после копирования скриптов**

```bash
old_string:
if [ "$WITH_ATTENTION" = "1" ]; then
  cp "$REPO_DIR/scripts/notify-attention.sh" "$SCRIPTS_DIR/"
  chmod +x "$SCRIPTS_DIR/notify-attention.sh"
fi

new_string:
if [ "$WITH_ATTENTION" = "1" ]; then
  cp "$REPO_DIR/scripts/notify-attention.sh" "$SCRIPTS_DIR/"
  chmod +x "$SCRIPTS_DIR/notify-attention.sh"
fi

cp "$REPO_DIR/VERSION" "$SCRIPTS_DIR/.limit-alerts-version"
```

- [ ] **Step 3: Удалить инлайновую `add_hook()` и заменить вызовы на функции из `lib/hooks.sh`**

```bash
old_string:
add_hook() { # $1 = event name, $2 = hook json (with .command)
  local cmd updated
  cmd=$(echo "$2" | "$JQ" -r '.command')
  updated=$("$JQ" --arg cmd "$cmd" --argjson h "$2" --arg ev "$1" '
    .hooks //= {} |
    .hooks[$ev] //= [{hooks: []}] |
    if ([.hooks[$ev][].hooks[]?.command] | index($cmd)) then .
    else .hooks[$ev][0].hooks += [$h] end
  ' "$SETTINGS")
  echo "$updated" > "$SETTINGS"
}

MONITOR_HOOK=$("$JQ" -n '{type: "command",
  command: "bash \"$HOME/.claude/scripts/usage-monitor.sh\" hook", timeout: 20}')
add_hook "Stop" "$MONITOR_HOOK"
add_hook "SessionStart" "$MONITOR_HOOK"
echo "    Limit hooks added: Stop, SessionStart"

if [ "$WITH_ATTENTION" = "1" ]; then
  add_hook "Notification" "$("$JQ" -n '{type: "command",
    command: "bash \"$HOME/.claude/scripts/notify-attention.sh\" notification", async: true}')"
  add_hook "Stop" "$("$JQ" -n '{type: "command",
    command: "bash \"$HOME/.claude/scripts/notify-attention.sh\" stop", async: true}')"
  echo "    Attention hooks added: Notification, Stop"
fi

new_string:
register_monitor_hooks
echo "    Limit hooks added: Stop, SessionStart"

if [ "$WITH_ATTENTION" = "1" ]; then
  register_attention_hooks
  echo "    Attention hooks added: Notification, Stop"
fi
```

- [ ] **Step 4: Синтаксическая проверка**

```bash
bash -n install.sh
```
Ожидается: без вывода.

- [ ] **Step 5: Функциональная проверка в песочнице (fake HOME, без launchd/реального settings.json)**

```bash
FAKE_HOME=$(mktemp -d)
HOME="$FAKE_HOME" ./install.sh --no-launchd
ls "$FAKE_HOME/.claude/scripts/"
cat "$FAKE_HOME/.claude/scripts/.limit-alerts-version"
jq '.hooks.Stop[0].hooks | length, .hooks.SessionStart[0].hooks | length, .hooks.Notification[0].hooks | length' "$FAKE_HOME/.claude/settings.json"
rm -rf "$FAKE_HOME"
```
Ожидается:
- `ls` показывает `usage-monitor.sh`, `statusline-with-limits.sh`, `notify-attention.sh`.
- `.limit-alerts-version` содержит `0.2.0`.
- `.hooks.Stop[0].hooks` — 2, `.hooks.SessionStart[0].hooks` — 1, `.hooks.Notification[0].hooks` — 1.

- [ ] **Step 6: Commit**

```bash
git add install.sh
git commit -m "refactor: install.sh uses lib/hooks.sh, writes version marker"
```

---

### Task 4: `update.sh`

**Files:**
- Create: `update.sh`

**Interfaces:**
- Consumes: `lib/hooks.sh` (Task 2), `VERSION`/`CHANGELOG.md` (Task 1), `~/.claude/scripts/.limit-alerts-version` (Task 3).
- Produces: обновлённые файлы в `~/.claude/scripts/`, при необходимости перезагруженный launchd-агент и дозаявленные хуки, обновлённый `.limit-alerts-version`. CLI: `./update.sh [--dry-run]`.

- [ ] **Step 1: Написать `update.sh`**

```bash
#!/usr/bin/env bash
# update.sh — синхронизирует установленный claude-code-limit-alerts с текущим
# состоянием локальной копии репозитория. НЕ делает git pull/fetch сам —
# обновите репозиторий (git pull) перед запуском.
#
# Флаги:
#   --dry-run   показать, что будет сделано, ничего не меняя

set -euo pipefail

if [ "$(uname -s)" != "Darwin" ]; then
  echo "Only macOS is supported for now (Windows/Linux support is planned)." >&2
  exit 1
fi

DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
  shift
done

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$REPO_DIR/lib/hooks.sh"
resolve_jq

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
  NEW_PLIST_CONTENT=$(sed "s|__HOME__|$HOME|g" "$REPO_DIR/launchd/com.claude.usage-monitor.plist.template")
  if ! diff -q <(echo "$NEW_PLIST_CONTENT") "$PLIST" >/dev/null 2>&1; then
    if [ "$DRY_RUN" = "1" ]; then
      echo "    would reload launchd agent (plist changed)"
    else
      echo "$NEW_PLIST_CONTENT" > "$PLIST"
      launchctl bootout "gui/$(id -u)/com.claude.usage-monitor" 2>/dev/null || true
      launchctl bootstrap "gui/$(id -u)" "$PLIST"
      echo "    launchd agent reloaded"
    fi
  fi
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
```

- [ ] **Step 2: Сделать исполняемым, синтаксическая проверка**

```bash
chmod +x update.sh
bash -n update.sh
```
Ожидается: без вывода.

- [ ] **Step 3: Проверка «не установлено»**

```bash
FAKE_HOME=$(mktemp -d)
HOME="$FAKE_HOME" ./update.sh; echo "exit=$?"
rm -rf "$FAKE_HOME"
```
Ожидается: сообщение `Похоже, проект не установлен — запустите ./install.sh` в stderr, `exit=1`.

- [ ] **Step 4: Проверка полного цикла обновления в песочнице**

```bash
FAKE_HOME=$(mktemp -d)
HOME="$FAKE_HOME" ./install.sh --no-launchd >/dev/null
echo "0.1.0" > "$FAKE_HOME/.claude/scripts/.limit-alerts-version"   # симулируем старую установку

echo "--- dry-run ---"
HOME="$FAKE_HOME" ./update.sh --dry-run
cat "$FAKE_HOME/.claude/scripts/.limit-alerts-version"   # должно остаться 0.1.0 (dry-run ничего не пишет)

echo "--- real run ---"
HOME="$FAKE_HOME" ./update.sh
cat "$FAKE_HOME/.claude/scripts/.limit-alerts-version"   # должно стать 0.2.0

echo "--- second run (idempotent) ---"
HOME="$FAKE_HOME" ./update.sh
jq '.hooks.Stop[0].hooks | length' "$FAKE_HOME/.claude/settings.json"   # без дублей

rm -rf "$FAKE_HOME"
```
Ожидается:
- `--dry-run`: печатает `would update: .../usage-monitor.sh` и т.д., `.limit-alerts-version` остаётся `0.1.0`.
- Реальный прогон: `.limit-alerts-version` становится `0.2.0`, в конце печатается блок `## [0.2.0]` из `CHANGELOG.md` (без блока `## [0.1.0]`, так как он был «уже установлен»).
- Повторный прогон: печатает `Уже установлена последняя версия (v0.2.0)`, `.hooks.Stop[0].hooks` остаётся равным значению после первого `install.sh` (без дублирования).
- Файл `notify-attention.sh` был установлен (не передавали `--no-attention`), значит после `update.sh` он тоже обновлён — проверить `diff scripts/notify-attention.sh "$FAKE_HOME/.claude/scripts/notify-attention.sh"` (до `rm -rf`) даёт пустой вывод.

- [ ] **Step 5: Commit**

```bash
git add update.sh
git commit -m "feat: add update.sh to sync installed files with the local repo checkout"
```

---

### Task 5: Версия в `usage-monitor.sh status`

**Files:**
- Modify: `scripts/usage-monitor.sh`

**Interfaces:**
- Consumes: `$DIR/.limit-alerts-version` (файл, создаётся `install.sh`/`update.sh` из Task 3/4). `$DIR` уже определена в начале файла как `$HOME/.claude/scripts`.
- Produces: первая строка вывода `usage-monitor.sh status` — `claude-code-limit-alerts vX.Y.Z`, если файл-метка присутствует; иначе — без этой строки (существующее поведение не ломается).

- [ ] **Step 1: Добавить печать версии в начало status-блока**

```bash
old_string:
if [ "$MODE" = "status" ]; then
  while IFS='|' read -r kind percent resets scope; do
    [ -n "$kind" ] || continue
    reset_local=$(to_local "$resets" "+%d.%m %H:%M")

new_string:
if [ "$MODE" = "status" ]; then
  if [ -f "$DIR/.limit-alerts-version" ]; then
    printf 'claude-code-limit-alerts v%s\n' "$(cat "$DIR/.limit-alerts-version")"
  fi
  while IFS='|' read -r kind percent resets scope; do
    [ -n "$kind" ] || continue
    reset_local=$(to_local "$resets" "+%d.%m %H:%M")
```

- [ ] **Step 2: Синтаксическая проверка**

```bash
bash -n scripts/usage-monitor.sh
```
Ожидается: без вывода.

- [ ] **Step 3: Функциональная проверка (без файла-метки — старое поведение)**

```bash
FAKE_HOME=$(mktemp -d)
mkdir -p "$FAKE_HOME/.claude/scripts"
cp ~/.claude/scripts/usage-monitor-cache.json "$FAKE_HOME/.claude/scripts/" 2>/dev/null || true
HOME="$FAKE_HOME" bash scripts/usage-monitor.sh status
rm -rf "$FAKE_HOME"
```
Ожидается: вывод БЕЗ строки `claude-code-limit-alerts v...` (файла-метки нет).

- [ ] **Step 4: Функциональная проверка (с файлом-меткой)**

```bash
FAKE_HOME=$(mktemp -d)
mkdir -p "$FAKE_HOME/.claude/scripts"
cp ~/.claude/scripts/usage-monitor-cache.json "$FAKE_HOME/.claude/scripts/" 2>/dev/null || true
echo "0.2.0" > "$FAKE_HOME/.claude/scripts/.limit-alerts-version"
HOME="$FAKE_HOME" bash scripts/usage-monitor.sh status
rm -rf "$FAKE_HOME"
```
Ожидается: первая строка вывода — `claude-code-limit-alerts v0.2.0`, дальше — как обычно проценты лимитов.

- [ ] **Step 5: Commit**

```bash
git add scripts/usage-monitor.sh
git commit -m "feat: print installed version in usage-monitor.sh status"
```

---

### Task 6: `uninstall.sh` — удалять файл-метку версии

**Files:**
- Modify: `uninstall.sh`

**Interfaces:**
- Consumes: ничего нового.
- Produces: `uninstall.sh` дополнительно удаляет `$SCRIPTS_DIR/.limit-alerts-version`.

- [ ] **Step 1: Добавить файл-метку в список удаляемых**

```bash
old_string:
echo "==> Removing scripts and state"
rm -f "$SCRIPTS_DIR/usage-monitor.sh" \
      "$SCRIPTS_DIR/statusline-with-limits.sh" \
      "$SCRIPTS_DIR/notify-attention.sh" \
      "$SCRIPTS_DIR/statusline-base.cmd" \
      "$SCRIPTS_DIR/usage-monitor-state.json" \
      "$SCRIPTS_DIR/usage-monitor-cache.json"

new_string:
echo "==> Removing scripts and state"
rm -f "$SCRIPTS_DIR/usage-monitor.sh" \
      "$SCRIPTS_DIR/statusline-with-limits.sh" \
      "$SCRIPTS_DIR/notify-attention.sh" \
      "$SCRIPTS_DIR/statusline-base.cmd" \
      "$SCRIPTS_DIR/usage-monitor-state.json" \
      "$SCRIPTS_DIR/usage-monitor-cache.json" \
      "$SCRIPTS_DIR/.limit-alerts-version"
```

- [ ] **Step 2: Синтаксическая проверка**

```bash
bash -n uninstall.sh
```
Ожидается: без вывода.

- [ ] **Step 3: Функциональная проверка в песочнице**

```bash
FAKE_HOME=$(mktemp -d)
HOME="$FAKE_HOME" ./install.sh --no-launchd >/dev/null
HOME="$FAKE_HOME" ./uninstall.sh >/dev/null
ls "$FAKE_HOME/.claude/scripts/" 2>/dev/null | grep -c limit-alerts-version
rm -rf "$FAKE_HOME"
```
Ожидается: `0` (файла-метки больше нет).

- [ ] **Step 4: Commit**

```bash
git add uninstall.sh
git commit -m "chore: remove version marker on uninstall"
```

---

### Task 7: README — секция «Обновление»/«Update»

**Files:**
- Modify: `README.md`
- Modify: `README.en.md`

**Interfaces:** нет (только документация).

- [ ] **Step 1: Добавить секцию в `README.md` между «## Установка» и «## Настройка»**

```bash
old_string:
После установки перезапустите Claude Code (или откройте один раз `/hooks`),
чтобы подхватились новые хуки. Перед изменением `~/.claude/settings.json`
создаётся бэкап.

## Настройка

new_string:
После установки перезапустите Claude Code (или откройте один раз `/hooks`),
чтобы подхватились новые хуки. Перед изменением `~/.claude/settings.json`
создаётся бэкап.

## Обновление

```bash
git pull
./update.sh
```

Сверяет установленную версию (`~/.claude/scripts/.limit-alerts-version`) с
`VERSION` в репозитории, перекладывает изменившиеся скрипты, перезагружает
launchd-агент при изменении конфигурации и дозаявляет хуки — без
переустановки того, что вы не ставили (`--no-statusline`/`--no-launchd`/
`--no-attention` по-прежнему уважаются). Флаг `--dry-run` показывает, что
будет сделано, ничего не меняя. Список изменений между версиями — в
[CHANGELOG.md](CHANGELOG.md).

## Настройка
```

- [ ] **Step 2: Добавить секцию в `README.en.md` между «## Installation» и «## Configuration»**

```bash
old_string:
Restart Claude Code afterwards (or open `/hooks` once) so the new hooks are
picked up. A backup of `~/.claude/settings.json` is created before any change.

## Configuration

new_string:
Restart Claude Code afterwards (or open `/hooks` once) so the new hooks are
picked up. A backup of `~/.claude/settings.json` is created before any change.

## Update

```bash
git pull
./update.sh
```

Compares the installed version (`~/.claude/scripts/.limit-alerts-version`)
against `VERSION` in the repo, re-copies changed scripts, reloads the
launchd agent if its config changed, and re-checks hook registration —
without installing anything you opted out of (`--no-statusline`/
`--no-launchd`/`--no-attention` are still respected). `--dry-run` shows what
would change without changing anything. See [CHANGELOG.md](CHANGELOG.md)
for what changed between versions.

## Configuration
```

- [ ] **Step 3: Проверить, что секции вставились ровно один раз**

```bash
grep -c "^## Обновление$" README.md
grep -c "^## Update$" README.en.md
```
Ожидается: `1` для каждой команды.

- [ ] **Step 4: Commit**

```bash
git add README.md README.en.md
git commit -m "docs: document update.sh in README"
```

---

## После выполнения плана

Все семь задач вместе дают полностью рабочий `update.sh`. Чтобы применить его к реальному окружению (а не к песочнице из тестов), нужно осознанно запустить `./update.sh` (или сначала `./update.sh --dry-run`) — это не входит в задачи плана, так как трогает настоящий `~/.claude/settings.json` и, возможно, launchd-агент пользователя.
