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

## Auto-resume after a limit reset / Авто-продолжение сессии

`usage-monitor.sh hook` reads the hook event JSON on stdin and records the
active session (`session_id`, `cwd`, `transcript_path`) in
`auto-resume-state.json`. Hook stdin is used rather than "the newest
transcript under `~/.claude/projects`", which just as often points at a
subagent or another window.

When the `session` limit reaches `UM_BLOCK_PCT` (default 99) and that recorded
session is younger than `UM_SESSION_TTL` (default 1800s), the monitor arms the
state, emits a 🚫 notification with the reset time, and copies the resume
command to the clipboard. This fires at most once per limit window.

`auto-resume.sh` is the waiting worker. It sleeps until `resets_at`, then —
crucially — re-checks the *actual* limits with `UM_CACHE_TTL=0
usage-monitor.sh limits` instead of trusting the clock: a weekly limit
routinely outlives a 5h window, and resuming into a still-blocked account
would fail immediately. Once the `session` limit is below 95% and no other
limit is at 100%, it `exec`s `claude --resume <id> "<prompt>"` in the
session's original directory. Because this is an interactive `claude` (not
`-p`), the session continues in a terminal you can see and permission prompts
work normally. A pid lock file prevents two workers waiting on one session.

With `--auto-resume-autostart` the monitor opens a **new** terminal window
(iTerm2 if running, otherwise Terminal.app) and starts the worker there
automatically. It never types into an existing window.

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
the session's. Comparison is by family rather than by rendered name, because
the setting stores an alias (`fable`) while the statusline receives the session
model as a full id (`claude-opus-5`) — comparing the rendered forms would call
`opus` and `Opus 5` different models. Advisor calls are separate requests with
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

## Files / Файлы

| Path | Purpose |
|---|---|
| `~/.claude/scripts/usage-monitor.sh` | monitor (hook / cron / status) |
| `~/.claude/scripts/statusline-with-limits.sh` | statusline wrapper |
| `~/.claude/scripts/notify-attention.sh` | attention notifications (banner + sound) |
| `~/.claude/scripts/auto-resume.sh` | waiting worker: resumes a session after a limit reset |
| `~/.claude/scripts/compact-advisor.sh` | Stop hook: `/compact` signal |
| `~/.claude/scripts/statusline-base.cmd` | preserved previous statusline command (optional) |
| `~/.claude/scripts/usage-monitor-cache.json` | cached API response |
| `~/.claude/scripts/usage-monitor-state.json` | notification state |
| `~/.claude/scripts/auto-resume-state.json` | last active session + resume plan (`resets_at`, `notified_for`); `armed` is written when the monitor arms but nothing currently reads it back |
| `~/.claude/scripts/compact-advisor-state.json` | compact-signal anti-spam state |
| `~/.claude/scripts/.limit-alerts-options` | options chosen at install time |
| `~/Library/LaunchAgents/com.claude.usage-monitor.plist` | background agent |
| `/tmp/claude-usage-monitor.err` | agent stderr (normally empty) |

## Claude Code integration / Интеграция

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
