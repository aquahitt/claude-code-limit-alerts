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
        (Stop, SessionStart)   (every 92 s)
                    │                │
          systemMessage in UI   macOS notification (osascript)
                    │
                    └── usage-monitor-cache.json ──> statusline-with-limits.sh
                                                            ▲
                         Claude Code stdin: rate_limits (5h, 7d) ┘
```

- **`usage-monitor.sh`** — the core. Fetches usage, compares against thresholds,
  maintains state, emits notifications.
- **`statusline-with-limits.sh`** — statusline wrapper. Read-only, never
  touches the network itself. Two sources for 5h and 7d: its own stdin, where
  Claude Code passes `rate_limits.five_hour` / `rate_limits.seven_day`
  (`used_percentage`, `resets_at` in epoch seconds) from the headers of its
  last API response — current while the session works, **frozen while it
  idles** (Claude Code does not poll usage in the background); and the cache,
  the usage endpoint's account-wide answer, which also sees work in other
  terminals, on other devices and on claude.ai. Neither carries a timestamp,
  but within one window usage only grows until the reset, so each window takes
  the reading with the later reset, and for the same window (resets within
  ten minutes) the higher percent; a window whose reset has passed is
  dropped. The cache alone has the model-scoped weekly limit (hidden once its
  window has reset).
  To keep an idle line current, a cache older than
  `UM_STATUSLINE_REFRESH_AFTER` (120 s) makes the statusline start
  `usage-monitor.sh hook` detached — the redraw never waits for it, and that
  mode keeps to the cache TTL, the 401/403/429 pause and the state lock. A
  stamp spaces spawns at least 30 s apart. With the launchd agent on, the
  cache rarely gets that old; with it off (the plugin's default), this is what
  refreshes it. `UM_STATUSLINE_BG_REFRESH=0` turns it off.
  Several sessions working at once each see their own last API response, so
  their stdin readings differ by what was spent in between. A shared file,
  `usage-monitor-observed`, keeps the freshest reading any of them has seen:
  every redraw merges its stdin into it (same rule, under a mkdir lock with a
  short retry, written via temp file + mv) and draws from the merged value, so
  all terminals show one number within a redraw.
  A window at or above `UM_WARN` gets its reset time, dim, after the percent
  (`↻HH:MM` within a day, `↻DD.MM` beyond); below the threshold the line stays
  short. `UM_STATUSLINE_RESET=0` turns it off.
  Для каждого окна statusline берёт более свежую цифру из stdin (ответ API этой
  сессии, застывает при простое) и кэша (данные всего аккаунта), а устаревший
  кэш обновляет в фоне. У окна, дошедшего до порога, показывается время сброса. If
  `~/.claude/scripts/statusline-base.cmd` exists, its content is executed as the
  base statusline and the limits are appended after a `|` separator.
- **launchd agent** (`com.claude.usage-monitor`) — runs `usage-monitor.sh cron`
  every 92 seconds by default (`interval` in the plugin, `--interval` for
  `install.sh`; a hand edit of `StartInterval` does not survive — the plugin
  regenerates the plist on every session start, `update.sh` on an update).
  This is what makes reset notifications work while Claude Code
  is closed, and what keeps the cache (the statusline's model-scoped weekly
  limit and its fallback) fresh between turns.
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
3. **Forecast** — if at the current pace the window runs out before it resets
   (see below) and it has not reached `UM_CRIT` yet → ⏳, once per window
   (`forecast` in the state; cleared with `notified` on a reset).
4. **Unused limit** — in the last 24 hours of a weekly window, if at the pace
   so far (the projection `status` shows, see below) 20 points or more would
   reset unused → ⌛, once per window (`unused` in the state). A subscription
   is paid for whether it is used or not; a day ahead there is still time to
   use the rest.

Multiple messages from one check are combined into a single notification.

A live request also runs under its own lock (`usage-monitor.fetch.lock`):
the agent, the Stop hooks of several working terminals and the background
refreshes of several idle statuslines may all decide to fetch at once. The
first takes the lock and asks; the rest wait for it (up to 12 s, above curl's
10 s) and read what it cached — one request instead of one per caller.

The read-modify-write of the state file runs under a lock (`usage-monitor.lock`,
a directory in the state directory). The Stop hook, `SessionStart` and the
launchd job can fire at the same moment; without the lock both would read the
same state, both would see a threshold as new, and the warning would arrive
twice. A run that cannot take the lock within ~5 s exits quietly — the holder
reports the same news. A lock older than a minute is treated as abandoned.

### Several accounts / Несколько аккаунтов

One machine can sign in to several accounts in turn, and one person can be
in several organizations (a personal plan and a Team seat) with separate
limits. Everything is keyed by **account + organization** — `accountUuid` and
`organizationUuid` from `oauthAccount` in `~/.claude.json`, the current
sign-in:

- the anti-spam state and the 401/403/429 pause live in one file per account
  (`usage-monitor-state.<key>.json`, `usage-monitor-backoff.<key>.json`), so
  switching accounts is no longer read as a window reset (a false ♻️) and
  does not re-arm the 🟡/🔴 warnings; switching back finds the account's own
  state, and one account's successful fetch does not lift another's pause;
- the cache carries an `_account` tag and is used only by its account; the
  statusline treats another account's cache as missing and refreshes it;
- the statuslines' shared observation carries the account too;
- the `claude -p /usage` fallback reads `cachedUsageUtilization` only when its
  `accountUuid` is the signed-in one, as Claude Code itself does.

The single state file of ≤ 0.9.0 is adopted by the first account seen and
retired. Without an OAuth sign-in nothing is tagged, as before.

Состояние антиспама, пауза после ошибок, кэш и общее наблюдение statusline
привязаны к аккаунту и организации из `~/.claude.json`: переключение
аккаунтов больше не выглядит как сброс окна и не показывает чужие цифры.

### Rate limiting / Ограничение частоты

When the usage endpoint answers **429, 403 or 401**, live requests pause: for
`Retry-After` seconds when the server sends a positive number, otherwise for 5
minutes, doubling on each further refusal, capped at an hour. The endpoint in
practice answers its 429s with `Retry-After: 0`; like Claude Code's own
client, a non-positive value counts as absent — taken literally it meant a
one-minute pause that never grew and kept the rate limit alive. 403 is treated like 429
because Claude Code's own client does the same; it has also been seen as a
standing answer for some Team/organization tokens, and without the pause the
92-second agent would ask, and spawn a CLI refresh, on every tick. On a 401 or
403 the `claude -p /usage` refresh still gets one try as the pause starts —
the CLI renews an expired token, and its own request may be served where this
script's is not; on a 429 it is skipped, since it would ask the same endpoint.
Whatever the failure, the CLI refresh runs at most once per 5 minutes
(`usage-monitor-cli-refresh` stamp): a lost network, a 5xx or a signed-out
keychain would otherwise start a headless Claude Code on every agent tick. The pause lives in
`usage-monitor-backoff.json` in the state directory and is cleared by the next
successful fetch. During it no live request and no `claude -p /usage` refresh
is made; hook and cron stay silent, and `status` shows the last cache with
the time of the next attempt.

`claude -p /usage` is a full headless session that fires this project's own
hooks. It runs with `UM_INTERNAL=1`, and every hook script exits at once when
it sees that — otherwise each refresh would send one more request to the very
endpoint that is failing, and the Stop hooks would banner a session nobody sees.

После ответа 429, 403 или 401 живые запросы приостанавливаются (по `Retry-After` или
5 → 10 → 20 … минут, не больше часа), а внутренний `claude -p /usage` не
запускает хуки проекта — иначе каждая проверка порождала бы ещё один запрос.

Обновление файла состояния идёт под блокировкой: иначе одновременные запуски
(Stop-хук, `SessionStart`, launchd) читали бы одно состояние и присылали одно
предупреждение дважды.

## History and forecast / История и прогноз

Every new reading — a live answer of the endpoint, or Claude Code's own
`cachedUsageUtilization` taken as a fallback — is appended to
`usage-history.<key>.jsonl` in the state directory, one file per account like
the state:

```json
{"t": 1792784649, "s": "api", "w": {"session": [34, 1792801800], "weekly_all": [98, 1792933200]}}
```

`t` is when the reading was taken (for the fallback, its `fetchedAtMs`), `w`
maps each limit kind to `[percent, resets_at]`, with `resets_at` as epoch
seconds rounded to the minute — the API's ±1s jitter would otherwise make
every reading look new. A line is written only when something changed, or at
least every 30 minutes while readings arrive, so a quiet stretch is recorded
as quiet rather than as a gap. Readings older than the last line are dropped.
Past 2 MB the file is cut to its last 12,000 lines — weeks of history.

The forecast reads the last 3,000 lines. For each window it takes samples from
the same window only (`resets_at` within 2 minutes) and a rate from:

- **session (5h):** the earliest sample of the last hour, if it is at least
  15 minutes old and the window has grown by at least 5 points since;
- **weekly:** the earliest sample of the last 24 hours, if it is at least 20
  hours old — a day's rate includes nights and breaks; otherwise, once the
  window is a day old, its average since it opened. Not below 25%, where a
  few points extrapolate to nonsense.

It reports a window only if the projected time is at least 10 minutes (5h) or
3 hours (weekly) before the reset. Whole-percent readings arrive in bursts;
these conditions handle that instead of smoothing, and the margin keeps a
forecast hovering around the reset from flapping. No forecast is better than
a false one.

**Pace** needs no history: the share of a weekly window that has elapsed is
where usage would be if the week were spent evenly. `status` and `/limits`
show it as "on pace: 38%" next to the percent. The statusline shows how far
off it the window is, from 5 points either way: `▲8` (yellow) ahead — it runs
out early — and `▼18` (cyan) behind — part of it resets unused. Behind by 5
points or more, `status` and `/limits` also project the window to its reset
(its percent scaled by the elapsed share): "~35% by reset (65% left unused)".
A subscription is paid for whether it is used or not, so unused limit is
worth pointing at as much as an early run-out. Not for the 5-hour window, and
not in a window's first half-day, when the comparison is noise. A linear pace
is pessimistic for someone who works only on weekdays; it is a reference
line, not a forecast.

The endpoint also returns a `severity` per limit (`normal` / `warning`). The
monitor does not use it: its thresholds are not documented, and `UM_WARN` /
`UM_CRIT` already cover the same ground under the user's control.

Каждый новый замер пишется в `usage-history.<key>.jsonl` (только при
изменении или раз в 30 минут). Прогноз берёт темп за последний час (5ч) или
за сутки (неделя) и говорит, только если лимит кончится заметно раньше сброса.
Темп недели — без истории: сравнение с долей прошедшей недели.

## Paid credits and the weekly split / Платные credits и разбивка недели

Two more fields of the usage response:

- `spend` — paid usage credits spent past the plan's limits
  (`used.amount_minor`, `used.exponent`, `used.currency`, `percent` of the
  spending limit). 💳 when spending starts, then at `UM_WARN` / `UM_CRIT`
  percent; state is `_spend` in the state file, and a smaller amount than the
  stored one means a new billing period and re-arms all three. `status` and
  `/limits` show the amount once it is above zero. `UM_SPEND_ALERT=0` turns
  the notification off.
- `seven_day_breakdown.rows` — the week split by product (`claude_code`,
  `chat`, `cowork`, `other`). Shares of what was spent, summing to 100, not
  shares of the limit. Shown in `status` and `/limits` once two or more
  products have usage — "Claude Code 100%" says nothing — products at 0%
  omitted.

Both are undocumented like the rest of the endpoint: a missing field just
means no line and no notification. The fallback through `~/.claude.json` does
not carry them.

`spend` — платные credits (уведомление при начале расхода и на порогах),
`seven_day_breakdown` — доли расхода недели по продуктам.

## Doctor / Диагностика

`usage-monitor.sh doctor` (the `limit-alerts:doctor` skill in the plugin)
checks the installation from files only — no request to the endpoint, so it
is safe during a pause: `jq`, the Keychain token (presence, plan, expiry —
never the token), the account key, the age and owner of the cache, an active
pause, the last failed check if nothing has succeeded since, the history,
the launchd agent (plist, `StartInterval`, whether it is loaded), the
statusline, the classic hooks, a plugin and a classic install active at once,
and a plugin session older than the installed copy. A script cannot read
whether macOS allows banners, so `doctor --notify` sends a test one.

`doctor` проверяет установку по файлам, без запросов к endpoint;
`doctor --notify` присылает тестовое уведомление.

## Switches / Переключатели

The forecast, the credits notification and the statusline pace each have a
switch in every installation, and it reaches every place the feature runs:

| | Environment | Plugin `userConfig` | `install.sh` |
|---|---|---|---|
| ⏳ forecast | `UM_FORECAST=0` | `forecast` | `--no-forecast` |
| 💳 credits | `UM_SPEND_ALERT=0` | `spend_alert` | `--no-spend-alert` |
| ⌛ unused limit | `UM_UNUSED_ALERT=0` | `unused_alert` | `--no-unused-alert` |
| `▲N` / `▼N` | `UM_STATUSLINE_PACE=0` | `statusline_pace` | `--no-statusline-pace` |
| subagent guard (off) | `UM_GUARD_FANOUT=1` | `guard_fanout` | `--guard-fanout` |
| model hint (off) | `UM_MODEL_HINT=1` | `model_hint` | `--model-hint` |

The same holds for every other feature since 0.11.0 — thresholds, the
`/compact` threshold, the statusline segments and the agent interval included;
README's "Configuration" lists where each is set in each installation.

An environment variable reaches hooks and the statusline but not the launchd
agent, which starts without the user's environment. So the plugin passes a
switched-off option to hooks through `CLAUDE_PLUGIN_OPTION_*` and to the agent
and the statusline through the generated wrappers in `bin/`; `install.sh`
bakes it into the installed scripts' defaults (the same `sed` as `--lang`),
records it in `.limit-alerts-options`, and `update.sh` re-applies it.

Прогноз, уведомление о credits и темп в statusline выключаются в любой
установке — переменной, опцией плагина или флагом `install.sh` — и
выключаются везде, включая фоновый агент.

## Safeguards / Страховки

Both are off by default: the project warns, it does not manage sessions, and
these two act at the moment of a decision — a question or a hint, never an
automatic action.

**Subagent guard** — `fanout-guard.sh`, a `PreToolUse` hook with the matcher
`Agent|Task`. Once a weekly window is at `UM_CRIT`, it answers
`permissionDecision: "ask"` with the reason, so Claude Code asks before the
subagent starts. Weekly windows only: a 5-hour one resets within hours and
Claude Code continues on its own (`autoContinueAtUsageLimit`); a week that
runs out stops work for days, and subagents — several at once, each with its
own context — spend it fastest. `weekly_all` always counts; `weekly_scoped`
only when `tool_input.model` names that model (a subagent on the session
model cannot be matched — the hook input does not carry the session model).
It reads only the monitor's cache, never the endpoint, and stays silent when
the cache is older than 15 minutes or another account's. The plugin always
registers the hook and the script exits at once unless the option is on;
`install.sh` installs and registers it only with `--guard-fanout`, and a
re-install without the flag removes both.

**Model hint** — a line added to the 🔴 of a model-scoped weekly limit:
another model does not spend that limit. Only while `weekly_all` is below
`UM_CRIT`, otherwise another model hits the same wall.

Обе страховки выключены по умолчанию. Вопрос перед субагентом — хук
`PreToolUse`, когда недельный лимит на `UM_CRIT`; подсказка сменить модель —
строка к 🔴 о недельном лимите по модели.

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

A session keeps the hooks of the plugin version it started with, so after an
update an older session still runs its old bootstrap on resume, `/clear` and
compaction. Before 0.9.3 that bootstrap copied its scripts over the newer
mirror and rewrote the plist from its old template, and the next newer session
copied them back — the background agent ran whichever version had spoken last.
Now a bootstrap whose `VERSION` is older than `bin/.version` (compared with
`sort -V`) leaves the mirror, the wrappers and the launchd agent alone and
tells the user to restart that session. Removal still goes through: an option
turned off is honoured whatever the version.

The launchd plist is regenerated on every session start too, but the agent is
reloaded only when the plist actually changed or the agent is not loaded.
`SessionStart` also fires on resume, `/clear` and compaction; reloading each
time would restart the agent (its `RunAtLoad` run racing the session's own
check) and hit launchd's bootout/bootstrap race, where a bootstrap issued too
soon fails with `5: Input/output error`. When a reload is needed, the bootstrap
is retried briefly for the same reason.

Options are resolved environment-first, then from
`pluginConfigs` in `~/.claude/settings.json` — the skills run the bootstrap from
a plain shell, which receives no `CLAUDE_PLUGIN_OPTION_*` at all. For the two
settings that write outside the plugin the option is tri-state: `true` applies,
`false` removes, and unset does nothing, so running the bootstrap from a shell
can never tear down a statusline the user just enabled. The `pluginConfigs`
lookup tests for the key with `has()`: jq's `//` would treat a stored boolean
`false` as missing and turn "off" into "unset".

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
| `.bootstrap-state.json` | one-shot flags (double-install warning, classic-surface notes) |

### Options / Настройки

`userConfig` values reach hooks as `CLAUDE_PLUGIN_OPTION_<KEY>`; booleans arrive
as the literal strings `true` / `false`. A `default` declared in the manifest is
**never materialised into the environment** — with no `pluginConfigs` entry, not
one of those variables is exported. So every default also lives in bash, and an
unset variable means "use the script default".

The names are generic (`CLAUDE_PLUGIN_OPTION_LANG`, not one per plugin) and,
like `CLAUDE_PLUGIN_DATA`, leak from whichever plugin owns the running hook. So
a script honours them only when it is itself the copy inside this plugin —
`${BASH_SOURCE[0]}` lies under `${CLAUDE_PLUGIN_ROOT}`. A classic install never
reads them, and another plugin's `LANG` or `ATTENTION=false` cannot reconfigure
it.

Дефолт из манифеста в окружение не попадает: пока пользователь не открыл диалог
настройки, ни одной переменной `CLAUDE_PLUGIN_OPTION_*` нет. Поэтому каждый
дефолт продублирован в bash, а отсутствие переменной означает «взять
скриптовый».

Имена переменных общие для всех плагинов и протекают в чужие хуки, поэтому
скрипт читает их, только если сам лежит внутри этого плагина. Классическая
установка их не видит.

### Coexistence / Сосуществование

The plugin's launchd agent uses a separate label,
`com.claude.usage-monitor.plugin`, so it never overwrites the plist
`install.sh` owns. Its statusline ownership marker is the data directory path,
distinct from the classic `statusline-with-limits` marker `uninstall.sh` greps
for.

Each opt-in surface is refused only when the classic install actually owns it:
the statusline when `statusLine.command` carries the classic
`statusline-with-limits` marker, the agent when the classic plist exists or its
label is loaded. An `install.sh --no-statusline` / `--no-launchd` leaves that
surface free, and the plugin takes it. Each refusal is said once per data
directory. Separately, classic hooks alongside the plugin get a one-time
warning: two installations would fire every hook twice and keep separate
anti-spam state, duplicating every notification.

## Files / Файлы

| Path | Purpose |
|---|---|
| `~/.claude/scripts/usage-monitor.sh` | monitor (hook / cron / status) |
| `~/.claude/scripts/statusline-with-limits.sh` | statusline wrapper |
| `~/.claude/scripts/notify-attention.sh` | attention notifications (banner + sound) |
| `~/.claude/scripts/compact-advisor.sh` | Stop hook: `/compact` signal |
| `~/.claude/scripts/statusline-base.cmd` | preserved previous statusline command (optional) |
| `~/.claude/scripts/usage-monitor-cache.json` | cached API response |
| `~/.claude/scripts/usage-monitor-state.<key>.json` | notification state, one per account (`usage-monitor-state.json` before 0.9.1) |
| `~/.claude/scripts/usage-monitor-backoff.<key>.json` | pause after HTTP 401/403/429, one per account (exists only while one runs) |
| `~/.claude/scripts/usage-monitor-cli-refresh` | stamp: last `claude -p /usage` refresh (at most one per 5 min) |
| `~/.claude/scripts/usage-monitor-sl-refresh` | stamp: last background refresh started by the statusline |
| `~/.claude/scripts/usage-monitor-observed` | freshest stdin reading seen by any session, shared by all statuslines |
| `~/.claude/scripts/usage-monitor.lock` | state-update lock (exists only while a check runs) |
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
