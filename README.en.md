# claude-code-limit-alerts

[Русский](README.md) | **English**

Notifications for Claude Code: subscription usage-limit monitoring (approaching
exhaustion, window resets, live percentages in your statusline) and "needs your
attention" — a banner with sound when Claude waits for a permission, a reply,
or finishes a task.

> 🍎 **macOS only for now.** Windows and Linux support is planned — see [Roadmap](#roadmap).

## What you get

**macOS notifications and in-app messages in Claude Code** (with `--lang en`):

```
🟡 Session (5h) limit: 82%, resets at 18:00
🔴 Week (all models) limit: 96% — almost exhausted, resets at 10:00
♻️ Session (5h) limit was reset (was 96%, now 3%)
```

**Statusline with all limit percentages** (green / yellow ≥ 80% / red ≥ 95%):

```
[your statusline] | 5h 71% · 7d 7% · Fable 4%
```

**"Needs your attention" notifications** — when Claude waits for a permission
or a reply, or finishes a task, you get a banner with sound. The title carries
the session name (or project dir) and git branch, the subtitle carries your
last prompt — so you instantly know which terminal to switch to:

```
Claude: stroi-homes (develop)          ← which session
fix the notification bug…              ← what it works on
Needs permission or a reply            ← what happened   (sound: Funk)
Task finished                          ←                  (sound: Glass)
```

The sound is played directly via `afplay`, so it works even when banners are
not allowed in Notification Center.

**Manual check from the terminal:**

```
$ ~/.claude/scripts/usage-monitor.sh status
Session (5h)          71%  resets: 16.07 18:00
Week (all models)      7%  resets: 17.07 10:00
Week (Fable)           4%  resets: 17.07 10:00
```

## How it works

- The script polls the same endpoint the `/usage` command in Claude Code uses
  (`api.anthropic.com/api/oauth/usage`); the OAuth token is read from the macOS
  Keychain — no extra API keys or logins required.
- **Claude Code hooks** (`Stop` + `SessionStart`) surface warnings right in the
  UI after each turn and on session start.
- A **launchd agent** checks limits every 5 minutes in the background — the
  window-reset notification arrives even when Claude Code is closed.
- The **statusline wrapper** appends percentages to your existing statusline
  (which is preserved and keeps rendering) — data comes from a local cache,
  no network calls on the statusline path.
- No spam: one notification per threshold (80% and 95%) per window; a reset is
  only announced if usage was ≥ 50%.

Details in [docs/how-it-works.md](docs/how-it-works.md).

## Installation

Requirements: macOS, [jq](https://jqlang.github.io/jq/) (`brew install jq`),
Claude Code authenticated with a subscription (Pro/Max).

```bash
git clone https://github.com/aquahitt/claude-code-limit-alerts.git
cd claude-code-limit-alerts
./install.sh --lang en
```

Installer flags:

| Flag | Effect |
|---|---|
| `--no-statusline` | leave the statusline untouched |
| `--no-launchd` | skip the background agent (hooks only) |
| `--no-attention` | skip "needs your attention" notifications |
| `--lang en` | English notifications (default is Russian) |

Restart Claude Code afterwards (or open `/hooks` once) so the new hooks are
picked up. A backup of `~/.claude/settings.json` is created before any change.

## Configuration

Thresholds and behavior are controlled by environment variables (or by editing
the defaults at the top of `usage-monitor.sh`):

| Variable | Default | Meaning |
|---|---|---|
| `UM_WARN` | `80` | 🟡 warning threshold, % |
| `UM_CRIT` | `95` | 🔴 critical threshold, % |
| `UM_RESET_MIN` | `50` | minimum usage for a window reset to be announced |
| `UM_CACHE_TTL` | `60` | API response cache lifetime, seconds |
| `UM_LANG` | `ru` | message language: `ru` or `en` |

The background check interval is `StartInterval` (seconds) in
`~/Library/LaunchAgents/com.claude.usage-monitor.plist`.

## Uninstall

```bash
./uninstall.sh
```

Unloads the launchd agent, removes the hooks from settings, restores your
previous statusline, and deletes the scripts.

## FAQ

**Notifications don't show up.**
Make sure notifications from "Script Editor" are allowed in
macOS Settings → Notifications. The script sends them via `osascript`.

**Is this an official Anthropic tool?**
No. It relies on an undocumented endpoint that Claude Code itself uses for the
`/usage` command — the response format may change. If it does, the scripts
silently stop showing data (nothing breaks).

**Will the token expire?**
Claude Code refreshes the OAuth token itself; the script always reads the
current one from the Keychain. If the token is invalid, the check is silently
skipped until the next cycle.

## Roadmap

- [ ] **Linux** — credentials from `~/.claude/.credentials.json`, notifications via `notify-send`, `systemd` timer instead of launchd
- [ ] **Windows** — Credential Manager, toast notifications, Task Scheduler
- [ ] Optional Telegram notifications

## License

[MIT](LICENSE)
