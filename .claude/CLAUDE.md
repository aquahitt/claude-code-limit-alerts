# claude-code-limit-alerts

Pure bash tooling for macOS: monitors Claude Code subscription usage limits
and sends notifications. No framework, test runner, or build step — the whole
project lives in shell scripts installed into `~/.claude/`.

## Documentation language

- `.claude/` (this file, agents, skills, hooks) — **English**. This is
  operational documentation for Claude Code itself; English gives the best
  model performance.
- `docs/` (user-facing documentation, e.g. `docs/how-it-works.md`) — the
  project's user-facing languages, currently **RU + EN** (mirrors
  `README.md`/`README.en.md`). Keep both in sync when either changes.

## Structure

- `install.sh` / `uninstall.sh` / `update.sh` — manage files in
  `~/.claude/scripts/`, hooks in `~/.claude/settings.json`, and the launchd
  agent (`~/Library/LaunchAgents/com.claude.usage-monitor.plist`).
- `lib/hooks.sh` — shared hook-registration logic (`add_hook`,
  `register_monitor_hooks`, `register_attention_hooks`), sourced by
  `install.sh` and `update.sh`; never itself copied into `~/.claude`.
- `lib/launchd.sh` — shared launchd plist generation (`generate_plist`,
  `print_proxy_status`), including proxy-env passthrough for corporate
  proxy/VPN setups; sourced by `install.sh` and `update.sh` the same way as
  `lib/hooks.sh`.
- `scripts/usage-monitor.sh`, `scripts/notify-attention.sh`,
  `scripts/statusline-with-limits.sh` — the files actually copied into
  `~/.claude/scripts/` and run by hooks/launchd/statusline.
- `launchd/com.claude.usage-monitor.plist.template` — plist template
  (`__HOME__` substituted via `sed`).
- `docs/how-it-works.md` — data source (`/api/oauth/usage` endpoint,
  Keychain), hook logic, and anti-spam rules.
- `docs/superpowers/plans/`, `docs/superpowers/specs/` — plans and specs left
  behind by the `superpowers:writing-plans` / `superpowers:brainstorming`
  skills. Local working drafts, gitignored — not committed to the
  repository.

## Conventions

- **macOS only.** Scripts may rely on `launchctl`, `security`, `osascript`,
  `afplay`. Linux/Windows are on the roadmap but not supported yet — don't
  add cross-platform shims unless that's the actual task.
- **`set -euo pipefail`** at the top of every executable script — never
  remove it.
- **`jq` is required** — resolved via `resolve_jq()` in `lib/hooks.sh`; if
  missing, a script must fail with a clear message
  (`jq is required. Install it with: brew install jq`), not continue
  silently.
- **install/update idempotency.** `install.sh`, `update.sh`, and `add_hook()`
  must be safe to re-run — no duplicate hooks in `settings.json`, no
  duplicate launchd registrations. `update.sh` respects the flags used at
  install time (`--no-statusline` / `--no-launchd` / `--no-attention`) —
  don't enable something that wasn't installed.
- **The user's `~/.claude/settings.json` is someone else's file.** Any edit
  from `install.sh` must be preceded by a backup; existing hooks and
  statusline are preserved, never overwritten.
- **No test framework.** Verification is manual, with real commands and
  expected output, plus `bash -n` for syntax. When manually verifying steps
  that touch `~/.claude/settings.json` or the real launchd agent, do it with
  an overridden `HOME` (sandboxed), never against the user's real
  environment.
- **Versioning:** `VERSION` (repo root) is the source of truth,
  `CHANGELOG.md` follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
  + [SemVer](https://semver.org/). Every behavioral change in
  `install.sh`/`uninstall.sh`/`update.sh`/`lib/`/`scripts/` gets its own
  `CHANGELOG.md` entry and, if warranted, a `VERSION` bump. See the
  `release` skill.
- **README is bilingual.** `README.md` (Russian, primary) and `README.en.md`
  (English) must stay structurally in sync — same sections, same order. See
  the `sync-readmes` skill.
- **Commits:** conventional-style prefixes (`feat:`, `fix:`, `refactor:`,
  `chore:`, `docs:`) — matches the existing project history.

## Before committing

Skill `check-scripts` — `bash -n` (+ `shellcheck`, if installed) over every
changed `*.sh`.
