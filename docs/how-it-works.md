# How it works / Как это устроено

## Data source / Источник данных

Claude Code's `/usage` command queries `GET https://api.anthropic.com/api/oauth/usage`
with the subscription OAuth token and the `anthropic-beta: oauth-2025-04-20` header.
This project uses the same endpoint. The token is read from the macOS Keychain
item `Claude Code-credentials` (`security find-generic-password`), so no extra
credentials are ever stored.

Relevant response fragment:

```json
{
  "five_hour": {"utilization": 56.0, "resets_at": "2026-07-16T15:00:00+00:00"},
  "seven_day": {"utilization": 6.0,  "resets_at": "2026-07-17T07:00:00+00:00"},
  "limits": [
    {"kind": "session",       "percent": 56, "resets_at": "...", "scope": null},
    {"kind": "weekly_all",    "percent": 6,  "resets_at": "...", "scope": null},
    {"kind": "weekly_scoped", "percent": 2,  "resets_at": "...",
     "scope": {"model": {"display_name": "Fable"}}}
  ]
}
```

The monitor iterates over `limits[]`, so any new limit kinds Anthropic adds
will be picked up automatically (with the raw `kind` as the label).

⚠️ The endpoint is undocumented and may change. All failures are silent by
design: a broken response means "no data this cycle", never a broken hook or
statusline.

**Team/organization accounts:** the live endpoint returns `403 forbidden` for
OAuth tokens with `subscriptionType: "team"` even with correct headers — this
looks like a fingerprint/gate on Anthropic's side, not something a header
change can fix. When the live call fails, the monitor falls back to reading
`~/.claude.json` → `.cachedUsageUtilization.utilization`, which Claude Code's
own `/usage` command already populates locally (same `.limits[]` shape).
Data is only as fresh as the last time `/usage` ran or the CLI refreshed it
itself — there is no live push for these accounts — so fallback data older
than 1 hour is treated as stale and skipped rather than used.

**Corporate proxy/VPN:** if your shell profile (`~/.zshrc` or similar) sets
`HTTP_PROXY`/`HTTPS_PROXY` to reach `api.anthropic.com`, the `launchd` agent
won't see it on its own — launchd doesn't source shell profiles, so cron
ticks start with a bare environment (the same class of issue the `PATH`
fallback in `resolve_claude_bin()` already works around). Both `install.sh`
and `update.sh` auto-detect `HTTP_PROXY`/`HTTPS_PROXY`/`ALL_PROXY`/`NO_PROXY`
(and their lowercase variants) from the shell they're run in and bake them
into the agent's `EnvironmentVariables` (plist permissions restricted to
`600`, since a proxy URL can embed credentials); pass `--proxy <url>` to set
it explicitly regardless of the current shell, or `--proxy ""` to disable
passthrough entirely. Re-run `update.sh` from a shell with the proxy active
if the proxy config changes — it isn't otherwise tracked, though a
previously-baked-in value is preserved across plain `update.sh` runs that
don't happen to have it in their environment.

## Components / Компоненты

```
                 api.anthropic.com/api/oauth/usage
                              │
                    usage-monitor.sh (fetch + cache 60s)
                    │                │               │
              mode: hook        mode: cron      mode: status
                    │                │               │
        Claude Code hooks      launchd agent     terminal
        (Stop, SessionStart)   (every 5 min)
                    │                │
          systemMessage in UI   macOS notification (osascript)
                    │
                    └── usage-monitor-cache.json ──> statusline-with-limits.sh
```

- **`usage-monitor.sh`** — the core. Fetches usage, compares against thresholds,
  maintains state, emits notifications.
- **`statusline-with-limits.sh`** — statusline wrapper. Read-only: renders the
  cached percentages; never touches the network. If
  `~/.claude/scripts/statusline-base.cmd` exists, its content is executed as the
  base statusline and the limits are appended after a `|` separator.
- **launchd agent** (`com.claude.usage-monitor`) — runs `usage-monitor.sh cron`
  every 5 minutes. This is what makes reset notifications work while Claude Code
  is closed, and what keeps the statusline cache fresh between turns.
- **`notify-attention.sh`** — independent of the limit monitor. Hooked to
  `Notification` (Claude waits for a permission/answer) and `Stop` (turn
  finished). Reads the hook event JSON from stdin, resolves the session identity
  (session name from `~/.claude/sessions/*.json`, project dir, git branch, last
  user prompt from the transcript) and shows a macOS banner + plays a sound via
  `afplay` (sound works even without Notification Center permission).

## State machine / Логика уведомлений

State is kept per limit kind in `~/.claude/scripts/usage-monitor-state.json`:

```json
{"session": {"percent": 82, "resets_at": "...", "notified": 80}}
```

On every check, for each limit:

1. **Reset detection** — the window is considered rolled over when `resets_at`
   moved by **more than 2 minutes** (epoch comparison; the API recomputes
   `resets_at` on every request with ±1s jitter, so exact comparison would
   produce false resets). A ♻️ notification is emitted only if the stored
   `percent` was ≥ `UM_RESET_MIN` (default 50) **and** the current percent is
   lower than the stored one. `notified` is cleared.
2. **Thresholds** — if `percent ≥ UM_CRIT` (95) and we haven't notified at that
   level in this window → 🔴. Else if `percent ≥ UM_WARN` (80) → 🟡.
   `notified` stores the highest announced threshold, so each fires at most
   once per window.

Multiple messages from one check are combined into a single notification.

## Limit reset: Claude Code does it itself / Сброс лимита

A usage limit does not end the session — the turn is aborted (the CLI fires
`StopFailure`, not `Stop`) and the process stays alive at the prompt. Claude
Code 2.1+ can then wait out the reset and continue on its own: the "Continue
automatically at usage limit" toggle in `/config`, stored as
`autoContinueAtUsageLimit` in `~/.claude/settings.json`.

Versions up to 0.4.0 of this project did the same from the outside
(`auto-resume.sh` plus a recorded-session state file). That is removed in
0.5.0: an external worker cannot beat the built-in one — it needs the session
to be exited first, and running alongside it would resume a single
conversation twice, in two terminals. `install.sh` and `update.sh` delete the
leftover `auto-resume.sh`, `auto-resume-state.json` and lock files.

The monitor still warns at `UM_WARN`/`UM_CRIT` before a limit runs out, which
is what gives you the chance to wrap up or switch models.

## Compact advisor / Подсказка о `/compact`

**A hook cannot run `/compact`.** The hook output schema is limited to
`systemMessage`, `continue`, `stopReason`, `decision`, `reason` and
`hookSpecificOutput` — there is no compaction verb — and `/compact` is not
exposed to the model as a tool. So `compact-advisor.sh` is a *signal*, timed
to arrive when compacting is cheapest.

On every `Stop` it takes the last `assistant` record in the transcript and
sums `usage.input_tokens + cache_read_input_tokens + cache_creation_input_tokens`
— the real input size of that request. The denominator is
`UM_CONTEXT_WINDOW` (default 200000), or your own `autoCompactWindow` from
`settings.json` when set, so the percentage refers to where the built-in
compaction will actually fire.

It speaks up only when all three hold: the percentage is at or above
`UM_COMPACT_WARN` (default 70); the last assistant message contains no
`tool_use` (the turn ended with an answer, not mid-edit); and no task under
`~/.claude/tasks/<session_id>/` is still unfinished. One signal per 10-point
step (70 / 80 / 90) per session.

For a fully automatic backstop, `install.sh --auto-compact-window <tokens>`
writes `autoCompactWindow` into `~/.claude/settings.json` (accepted range
100000–1000000) so Claude Code's own auto-compact fires earlier. This is
opt-in because it changes behaviour for every session, not just this project's.
`CLAUDE_CODE_AUTO_COMPACT_WINDOW`, if set, takes precedence over the setting.

## Model in the statusline / Модель в statusline

```
<base statusline> | Opus 5/high · ctx 72% · ⇢ Haiku 4.5 | 5h 66% · 7d 7% · wk Fable 4%
```

The model segment costs no I/O: `.model.display_name`, `.effort.level` and
`.context_window.used_percentage` all arrive in the statusline's own stdin,
which the script already reads. Each piece disappears on its own when absent
(a model without reasoning effort, a session with no messages yet), and with
no model in stdin the output is what it always was, apart from the new
`wk`/`нед.` prefix on the scoped weekly limit. The `ctx`
percentage is coloured with `UM_COMPACT_WARN` (70) / 90 — the same threshold
`compact-advisor.sh` signals on.

`⇢ Haiku 4.5` names a **subagent** running on a different model than the
session. Subagents write their own transcripts under
`~/.claude/projects/<slug>/<session_id>/subagents/agent-<id>.jsonl`; a
subagent counts as running when that file was written within
`UM_SUBAGENT_TTL` seconds (default 180). The seemingly better signal — an
`Agent` `tool_use` with no matching `tool_result` in the main transcript —
does not work, because subagents run in the background by default and their
`tool_result` lands immediately while the agent keeps going. The scan itself
looks only at the 12 most-recently-modified transcripts under
`<project>/<session_id>/subagents/` and collects at most 8 live, non-session-
model entries — enough headroom for any realistic number of concurrent
subagents without `stat`-ing a directory full of long-stale ones from past
sessions. The trade-off of the mtime approach: a subagent that stays silent
longer than the TTL (one long tool call) drops off the statusline, and a
just-finished one lingers for up to the TTL. Same-model subagents are never
shown; several on one model are collapsed into `⇢ 2× Haiku 4.5`.

`adv Fable` names the model configured via Claude Code's `/advisor` command
(`advisorModel` in `settings.json`), shown only when its family differs from
the session's. Models are compared in full when both sides carry a
version, so Sonnet 4 and Sonnet 4.5 stay distinct; the comparison falls back to
the family only when one side is a bare alias with no version to compare
against. That case is real: the setting stores an alias (`fable`) while the
statusline receives the session model as a full id (`claude-opus-5`), and a
subagent's `meta.json` also stores an alias — comparing rendered forms there
would call `opus` and `Opus 5` different models. Advisor calls are separate requests with
their own context: they do not fill the session window, so they are deliberately
excluded from `ctx` and from the compact advisor's arithmetic.

`wk Fable 4%` is the weekly model-**scoped limit**, not a running model. The
`wk` / `нед.` prefix was added precisely because a real model name now shares
the line.

The statusline redraws on `refreshInterval` (60s as installed) and on events,
so a subagent that only lives for a few seconds may never make it onto the
line at all.

Turn it off with `install.sh --no-statusline-model` (whole segment) or
`--no-subagent-model` (keep the session model, drop `⇢ …`).

## Plugin mode / Режим плагина

The same scripts ship two ways: `install.sh` copies them into
`~/.claude/scripts`, and the plugin runs them straight from the plugin root
(`source: "./"` — the repository root *is* the plugin). Only the paths differ.

Те же скрипты, два способа доставки: `install.sh` копирует их в
`~/.claude/scripts`, плагин запускает прямо из корня плагина (`source: "./"` —
корень репозитория и есть плагин). Отличаются только пути.

### Three execution contexts / Три контекста исполнения

| Context | Gets `CLAUDE_PLUGIN_*` | Needs a stable path |
|---|---|---|
| Hooks (`Stop`, `SessionStart`, `Notification`) | yes | no |
| Statusline command | no | **yes** |
| launchd job | no | **yes** |

Hooks are fine: `${CLAUDE_PLUGIN_ROOT}` is re-resolved on every run. The other
two start outside Claude Code, so they receive no `CLAUDE_PLUGIN_*` variables at
all — and the plugin cache is version-stamped
(`~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/`), so any path
written into `settings.json` or a plist would die at the next plugin update.

Хуки живут спокойно: `${CLAUDE_PLUGIN_ROOT}` вычисляется заново при каждом
запуске. Два других контекста стартуют вне Claude Code, переменных
`CLAUDE_PLUGIN_*` не получают вовсе, а кэш плагина версионирован — путь,
записанный в `settings.json` или в plist, умрёт при первом же обновлении.

### The bridge / Мост

`scripts/plugin-bootstrap.sh` (hook `SessionStart`) mirrors the two scripts
those surfaces need into the update-stable data directory and generates
wrappers there. A wrapper is the only place that knows both the data directory
and the resolved options:

```bash
export UM_STATE_DIR="$HOME/.claude/plugins/data/limit-alerts-.../"
export UM_LANG="ru"
exec bash ".../bin/usage-monitor.sh" "$@"
```

The two mirrored scripts are re-copied when `bin/.version` differs from
`VERSION` at the plugin root. The wrappers, by contrast, are rewritten on
**every session start**: they carry the resolved options, and those change
whenever the user edits the plugin configuration. Gating them on the version
would leave the statusline and the background agent on stale language and
thresholds until the next release.

Options are resolved environment-first, then from
`pluginConfigs` in `~/.claude/settings.json` — the skills run the bootstrap from
a plain shell, which receives no `CLAUDE_PLUGIN_OPTION_*` at all. For the two
settings that write outside the plugin the option is tri-state: `true` applies,
`false` removes, and unset does nothing, so running the bootstrap from a shell
can never tear down a statusline the user just enabled.

`notify-attention.sh` and `compact-advisor.sh` are deliberately **not**
mirrored: they only ever run from hooks, where `${CLAUDE_PLUGIN_ROOT}` already
resolves correctly.

### State directory / Каталог состояния

```
DIR="${UM_STATE_DIR:-$HOME/.claude/scripts}"
```

`CLAUDE_PLUGIN_DATA` is **not** in this chain, on purpose. It is exported by
whichever plugin owns the running hook and leaks into unrelated shells — a
plain terminal inside a Claude Code session can carry
`CLAUDE_PLUGIN_DATA=~/.claude/plugins/data/<some other plugin>`. Consulting it
would make a classic install silently relocate its state into an unrelated
plugin's data directory. `hooks.json` and both wrappers always pass
`UM_STATE_DIR` explicitly, so nothing is lost.

`CLAUDE_PLUGIN_DATA` в цепочке нет намеренно: её экспортирует тот плагин, чей
хук выполняется, и она протекает в посторонние шеллы. Классическая установка в
сессии с любым другим включённым плагином иначе молча унесла бы состояние в
чужой каталог.

### Plugin data layout / Раскладка данных плагина

`~/.claude/plugins/data/limit-alerts-claude-code-limit-alerts/`:

| Path | Purpose |
|---|---|
| `bin/.version` | version of the mirrored copies |
| `bin/usage-monitor.sh`, `bin/statusline-with-limits.sh` | mirrored copies |
| `bin/cron.sh`, `bin/statusline.sh` | generated env wrappers |
| `usage-monitor-cache.json`, `usage-monitor-state.json` | as in the classic install |
| `compact-advisor-state.json`, `statusline-base.cmd` | as in the classic install |
| `.bootstrap-state.json` | one-shot flags (double-install warning) |

### Options / Настройки

`userConfig` values reach hooks as `CLAUDE_PLUGIN_OPTION_<KEY>`; booleans arrive
as the literal strings `true` / `false`. A `default` declared in the manifest is
**never materialised into the environment** — with no `pluginConfigs` entry, not
one of those variables is exported. So every default also lives in bash, and an
unset variable means "use the script default".

Дефолт из манифеста в окружение не попадает: пока пользователь не открыл диалог
настройки, ни одной переменной `CLAUDE_PLUGIN_OPTION_*` нет. Поэтому каждый
дефолт продублирован в bash, а отсутствие переменной означает «взять
скриптовый».

### Coexistence / Сосуществование

The plugin's launchd agent uses a separate label,
`com.claude.usage-monitor.plugin`, so it never overwrites the plist
`install.sh` owns. Its statusline ownership marker is the data directory path,
distinct from the classic `statusline-with-limits` marker `uninstall.sh` greps
for. If a classic install is detected, the plugin refuses to touch either
surface and warns once — two installations would fire every hook twice and keep
separate anti-spam state, duplicating every notification.

## Files / Файлы

| Path | Purpose |
|---|---|
| `~/.claude/scripts/usage-monitor.sh` | monitor (hook / cron / status) |
| `~/.claude/scripts/statusline-with-limits.sh` | statusline wrapper |
| `~/.claude/scripts/notify-attention.sh` | attention notifications (banner + sound) |
| `~/.claude/scripts/compact-advisor.sh` | Stop hook: `/compact` signal |
| `~/.claude/scripts/statusline-base.cmd` | preserved previous statusline command (optional) |
| `~/.claude/scripts/usage-monitor-cache.json` | cached API response |
| `~/.claude/scripts/usage-monitor-state.json` | notification state |
| `~/.claude/scripts/compact-advisor-state.json` | compact-signal anti-spam state |
| `~/.claude/scripts/.limit-alerts-options` | options chosen at install time |
| `~/Library/LaunchAgents/com.claude.usage-monitor.plist` | background agent |
| `/tmp/claude-usage-monitor.err` | agent stderr (normally empty) |
| `~/Library/LaunchAgents/com.claude.usage-monitor.plugin.plist` | background agent, plugin mode |
| `/tmp/claude-usage-monitor-plugin.err` | agent stderr, plugin mode |
| `~/.claude/plugins/data/limit-alerts-*/` | all plugin-mode state (see Plugin mode above) |

## Claude Code integration / Интеграция

In plugin mode Claude Code registers the hooks itself from `hooks/hooks.json`
and `~/.claude/settings.json` is not touched at all. В режиме плагина хуки
регистрирует сам Claude Code, `settings.json` не правится.

`install.sh` merges this into `~/.claude/settings.json` (existing entries are
preserved):

```json
{
  "hooks": {
    "Stop":        [{"hooks": [{"type": "command", "command": "bash \"$HOME/.claude/scripts/usage-monitor.sh\" hook", "timeout": 20}]}],
    "SessionStart": [{"hooks": [{"type": "command", "command": "bash \"$HOME/.claude/scripts/usage-monitor.sh\" hook", "timeout": 20}]}]
  },
  "statusLine": {
    "type": "command",
    "command": "bash \"$HOME/.claude/scripts/statusline-with-limits.sh\"",
    "refreshInterval": 60
  }
}
```

In `hook` mode the script prints `{"systemMessage": "..."}` only when there is
something to announce; Claude Code displays it in the UI. Silence otherwise.

## Gotchas / Грабли

- **bash 3.2 (macOS default)** mis-parses `$var` immediately followed by a
  multibyte character (e.g. `«$label»` → "unbound variable"). Always use
  `${var}` in strings with non-ASCII text.
- **`resets_at` jitters**: the API recomputes it on every request, so two
  consecutive responses for the same window differ by up to ~1 second. Never
  compare the timestamps for equality — use an epoch delta with tolerance.
- `date -jf`/`date -r`/`stat -f` are BSD variants — one of the reasons the
  scripts are macOS-only for now.
- Claude Code's settings watcher only reloads hook config for directories that
  already had a settings file at session start; after installing, restart
  Claude Code or open `/hooks` once.
