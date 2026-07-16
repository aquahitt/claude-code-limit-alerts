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

## Files / Файлы

| Path | Purpose |
|---|---|
| `~/.claude/scripts/usage-monitor.sh` | monitor (hook / cron / status) |
| `~/.claude/scripts/statusline-with-limits.sh` | statusline wrapper |
| `~/.claude/scripts/notify-attention.sh` | attention notifications (banner + sound) |
| `~/.claude/scripts/statusline-base.cmd` | preserved previous statusline command (optional) |
| `~/.claude/scripts/usage-monitor-cache.json` | cached API response |
| `~/.claude/scripts/usage-monitor-state.json` | notification state |
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
