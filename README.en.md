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
[your statusline] | 5h 71% · 7d 7% · wk Fable 4%
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
claude-code-limit-alerts vX.Y.Z
Session (5h)          71%  resets: 16.07 18:00
Week (all models)      7%  resets: 17.07 10:00
Week (Fable)           4%  resets: 17.07 10:00
```

If live data can't be fetched (for example, the endpoint answers 429),
`status` shows the last cache marked "⚠ No live data — showing the cache from
… (N min ago)", and flags windows that have rolled over since with
"(already reset)". In the plugin, the `limit-alerts:status` skill does the same.

## How it works

- The script polls the same endpoint the `/usage` command in Claude Code uses
  (`api.anthropic.com/api/oauth/usage`); the OAuth token is read from the macOS
  Keychain — no extra API keys or logins required.
- **Claude Code hooks** (`Stop` + `SessionStart`) surface warnings right in the
  UI after each turn and on session start.
- A **launchd agent** checks limits every 5 minutes in the background — the
  window-reset notification arrives even when Claude Code is closed.
- **Two ways to run it.** The plugin registers its own hooks and keeps state in
  its own data directory; `install.sh` copies the scripts into
  `~/.claude/scripts` and appends hooks to `~/.claude/settings.json`. The
  monitoring logic is identical in both — they are the same files.
- The **statusline wrapper** appends percentages to your existing statusline
  (which is preserved and keeps rendering). Claude Code itself passes the 5h
  and 7d percentages to the statusline, current as of its last API response;
  the model-scoped weekly limit and the first moments of a session come from a
  local cache. The statusline makes no network calls. Once a window reaches
  the warning threshold, its reset time appears next to it: `5h 84% ↻00:20`.
- No spam: one notification per threshold (80% and 95%) per window; a reset is
  only announced if usage was ≥ 50%.

Details in [docs/how-it-works.md](docs/how-it-works.md).

## The compact signal and the model in the statusline

**Continuing after a limit reset is Claude Code's own job.** `/config` has a
"Continue automatically at usage limit" toggle (`autoContinueAtUsageLimit` in
`~/.claude/settings.json`): the session waits out the reset and carries on by
itself — no exit, no second terminal, no `--resume`. Up to 0.4.0 this project
did the same thing from the outside via `auto-resume.sh`; 0.5.0 removes it,
because an external worker cannot do it better and, running alongside the
built-in one, would resume a single conversation twice. `install.sh` and
`update.sh` clean up the files left behind by earlier versions.

**The `/compact` signal.** A hook cannot run `/compact` — the hook output
schema has no compaction verb. So `compact-advisor.sh` sends a signal at the
moment compacting is cheapest: context is past the threshold (70% by default),
the turn ended with an answer rather than a tool call, and no tasks are left
unfinished.

For a fully automatic backstop, move Claude Code's own threshold:

```bash
./install.sh --auto-compact-window 140000   # 100000..1000000 tokens
```

**The model in the statusline.** The status line shows the session's model,
its `effort` level and how full the context is — and, when a subagent runs on
a different model, that model too:

```
myproject (main) | Opus 5/high · adv Fable · ctx 72% · ⇢ Haiku 4.5 | 5h 66% · 7d 7% · wk Fable 4%
```

All of that arrives on the statusline's stdin, so the segment costs no network
or disk access. The one exception is the subagent model, read from
`~/.claude/projects/<project>/<session_id>/subagents/`, where "running right
now" means "written within `UM_SUBAGENT_TTL` seconds" (180 by default). A
subagent that stays silent longer than that — one long tool call — drops off
the line until it writes again. Subagents on the session's own model are never
shown; several on one model collapse into `⇢ 2× Haiku 4.5`.

`adv Fable` is Claude Code's own advisor model (the `/advisor` command, stored
as `advisorModel` in `settings.json`). It appears only when its family differs
from the session's, so `advisorModel: opus` under an Opus session adds nothing.
Advisor calls are separate requests with their own context — they do not fill
the session window and do not affect `ctx`.

`wk Fable 4%` is the weekly **model-scoped limit**, not a running model — the
prefix exists precisely because a real model name now shares the line. Do not
confuse it with `adv Fable`: the first is how much of that model's weekly quota
is left, the second is what you are consulting.

Turn any of it off: `./install.sh --no-compact-advisor`, `./install.sh --no-statusline-model`,
`./install.sh --no-subagent-model`.

## Installation

Requirements: macOS, [jq](https://jqlang.github.io/jq/) (`brew install jq`),
Claude Code authenticated with a subscription (Pro/Max).

Two ways. The plugin is the primary one; `install.sh` stays for anyone who
needs `--auto-compact-window` or an install without a marketplace.

### As a plugin (recommended)

```
/plugin marketplace add aquahitt/claude-code-limit-alerts
/plugin install limit-alerts@claude-code-limit-alerts
```

Claude Code registers the hooks itself — `~/.claude/settings.json` is not
touched. All state lives in the plugin's data directory and survives updates.

Configure it under `/plugin` → limit-alerts → Configure:

| Option | Default | Effect |
|---|---|---|
| `lang` | `ru` | notification language (`ru` / `en`) |
| `warn` | `80` | 🟡 threshold, percent |
| `crit` | `95` | 🔴 threshold, percent |
| `attention` | on | "needs your attention" notifications |
| `compact_advisor` | on | the `/compact` signal |
| `statusline` | **off** | limit percentages in the statusline |
| `launchd` | **off** | background agent, checks every 5 minutes |

The last two are off on purpose: they write outside the plugin — into
`~/.claude/settings.json` and `~/Library/LaunchAgents`. Turn them on in the
configuration dialog and the change applies at the next session start, or
immediately via `/limit-alerts:setup`. An existing statusline is not
overwritten: it is preserved, keeps rendering, and the percentages are
appended after it.

Plugin skills:

| Skill | Effect |
|---|---|
| `/limit-alerts:status` | show current limits |
| `/limit-alerts:setup` | apply the statusline and agent settings now |
| `/limit-alerts:uninstall` | remove the statusline and the agent before removing the plugin |

> ⚠️ Do not run the plugin and `install.sh` side by side: hooks fire twice and
> notifications get duplicated. The plugin detects this and warns once. It also
> leaves the statusline and the agent completely alone in that case.

### With `install.sh`

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
| `--no-compact-advisor` | skip the `/compact` signal |
| `--auto-compact-window <tokens>` | move Claude Code's own auto-compact threshold (100000–1000000); affects every session |
| `--no-statusline-model` | statusline shows limits only — no model / effort / context / subagent segment |
| `--no-subagent-model` | statusline keeps the session model but drops the subagent model |

Restart Claude Code afterwards (or open `/hooks` once) so the new hooks are
picked up. A backup of `~/.claude/settings.json` is created before any change.

## Update

The plugin updates through `/plugin` — Claude Code pulls the new version
itself. The script mirror in the data directory is rebuilt automatically on the
first session start after the update.

The classic install:

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

Thresholds and behavior are controlled by environment variables (or by editing
the defaults at the top of `usage-monitor.sh`):

| Variable | Default | Meaning |
|---|---|---|
| `UM_WARN` | `80` | 🟡 warning threshold, % |
| `UM_CRIT` | `95` | 🔴 critical threshold, % |
| `UM_RESET_MIN` | `50` | minimum usage for a window reset to be announced |
| `UM_CACHE_TTL` | `60` | API response cache lifetime, seconds |
| `UM_LANG` | `ru` | message language: `ru` or `en` |
| `UM_COMPACT_WARN` | `70` | `/compact` signal threshold, % of context |
| `UM_CONTEXT_WINDOW` | `200000` | context window used for the percentage (overridden by `autoCompactWindow` in `settings.json`) |
| `UM_STATUSLINE_MODEL` | `1` | show the model segment in the statusline |
| `UM_STATUSLINE_CTX` | `1` | show `ctx N%` inside the model segment |
| `UM_SUBAGENT_MODEL` | `1` | show the model of a running subagent |
| `UM_SUBAGENT_TTL` | `180` | how recently a subagent must have written for it to count as running, seconds |
| `UM_STATUSLINE_ADVISOR` | `1` | show the advisor model (`/advisor`) |
| `UM_STATUSLINE_RESET` | `1` | reset time next to a window that reached the warning threshold: `5h 84% ↻00:20`, the date `↻15.10` when it is over a day away |

The background check interval is `StartInterval` (seconds) in
`~/Library/LaunchAgents/com.claude.usage-monitor.plist`.

## Troubleshooting

Every notification sent and every failed attempt to fetch data (an expired
token, a 403 for team/org accounts, a stale local cache, etc.) is logged
with a reason:

```bash
cat ~/.claude/scripts/usage-monitor.log       # full log
grep "fetch failed" ~/.claude/scripts/usage-monitor.log | tail -30   # fetch failures only
tail -f ~/.claude/scripts/usage-monitor.log   # watch live
```

Seeing a run of `fetch failed: ...` lines isn't necessarily a bug — the live
endpoint may be unreachable (see FAQ below), and the local-cache fallback
waits for a fresh (under an hour old) `cachedUsageUtilization` in
`~/.claude.json` before it will use it.

Check the launchd agent's state:

```bash
launchctl list | grep com.claude.usage-monitor
```

## Uninstall

The plugin: run `/limit-alerts:uninstall` first, then remove the plugin with
`/plugin`. The order matters — disabling a plugin does not by itself remove the
statusline or unload the launchd agent, because those are writes outside the
plugin.

The classic install:

```bash
./uninstall.sh
```

Unloads the launchd agent, removes the hooks from settings, restores your
previous statusline, and deletes the scripts.

## Experimental: a status-line mod

`mods/limit-alerts-status/` holds a separate plugin of Claude Code TypeScript
hooks (a mod). It shows the limits in the plugin status line under the prompt
and **does not touch** `statusLine` in `~/.claude/settings.json`: no backups,
no wrappers.

```
5h 62% · 7d 9% · wk Fable 4%
```

There are no colors — the line is plain text — so severity is a leading mark:
`⚠` from the warning threshold, `⛔` from the critical one.

Where the numbers come from, in order:

1. A fresh `usage-monitor-cache.json` (under 15 minutes old) — from
   `UM_STATE_DIR`, `~/.claude/scripts`, or the `limit-alerts` plugin's data
   directory.
2. Otherwise the 5h/7d percentages Claude Code itself gets from API responses.
   This works even without the monitor, but lacks the model-scoped weekly
   limit.
3. Otherwise a stale cache marked with its age: `(2h ago)`.

To run it:

```bash
claude --plugin-dir mods/limit-alerts-status
```

Its options (`lang`, `warn`, `crit`, `state_dir`) show up in the config menu.
The mod is not part of the `limit-alerts` plugin or the marketplace: the mod
API is still early access and may change between Claude Code versions. If this
project's statusline is enabled too, the limits show up twice.

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
