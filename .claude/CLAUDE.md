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
  `install.sh` and `update.sh`; never copied into `~/.claude/scripts`. It does
  ship inside the plugin, though — `source: "./"` puts the whole repository,
  `lib/` included, into the plugin cache.
- `lib/launchd.sh` — shared launchd plist generation (`generate_plist`,
  `print_proxy_status`), including proxy-env passthrough for corporate
  proxy/VPN setups; sourced by `install.sh` and `update.sh` the same way as
  `lib/hooks.sh`.
- `scripts/usage-monitor.sh`, `scripts/notify-attention.sh`,
  `scripts/statusline-with-limits.sh`, `scripts/compact-advisor.sh` — the
  files actually copied into `~/.claude/scripts/` and run by
  hooks/launchd/statusline. `compact-advisor.sh` is a `Stop` hook.
- **Don't reintroduce auto-resume.** 0.5.0 removed `auto-resume.sh` because
  Claude Code does it natively ("Continue automatically at usage limit" in
  `/config`, `autoContinueAtUsageLimit` in `~/.claude/settings.json`). An
  external worker needs the session exited first and, alongside the built-in
  one, resumes one conversation twice. This project warns about limits; it
  does not manage sessions.
- `launchd/com.claude.usage-monitor.plist.template` — plist template.
  `__LABEL__`, `__SCRIPT__`, `__ERRLOG__` (and legacy `__HOME__`) are
  substituted by `generate_plist`, whose 5th-7th parameters are optional and
  default to the classic install's values — that is what lets `install.sh` and
  `update.sh` keep calling it with four arguments.
- `docs/how-it-works.md` — data source (`/api/oauth/usage` endpoint,
  Keychain), hook logic, and anti-spam rules.
- `docs/superpowers/plans/`, `docs/superpowers/specs/` — plans and specs left
  behind by the `superpowers:writing-plans` / `superpowers:brainstorming`
  skills. Local working drafts, gitignored — not committed to the
  repository.

### Plugin surface

The repository root **is** the plugin (`source: "./"`), so `scripts/` is reused
from the same files with no copy.

- `.claude-plugin/plugin.json` — manifest and `userConfig`;
  `.claude-plugin/marketplace.json` — single-entry catalogue.
- `hooks/hooks.json` — Stop / SessionStart / Notification. Every command passes
  `UM_STATE_DIR="${CLAUDE_PLUGIN_DATA}"` explicitly.
- `skills/{status,setup,uninstall}/SKILL.md` — thin triggers; logic stays in
  bash. (`.claude/skills/` is a different thing entirely — those are
  development skills for this repository and are not shipped to plugin users.)
- `scripts/plugin-bootstrap.sh` — `SessionStart` hook.
- **The one constraint to remember:** `${CLAUDE_PLUGIN_ROOT}` points into a
  version-stamped cache, so any path written outside the plugin (the statusline
  command, the launchd plist) must go through `${CLAUDE_PLUGIN_DATA}/bin/`
  instead. The bootstrap re-copies those scripts on a version change, but
  rewrites the generated wrappers on every session start — they carry the
  resolved options, which change whenever the user edits the configuration.
- **`statusline` and `launchd` are tri-state**, not boolean: `true` applies,
  `false` removes, unset is a no-op. The skills run the bootstrap from a plain
  shell where `CLAUDE_PLUGIN_OPTION_*` is absent, and defaulting to `false`
  there would destroy the statusline the user just enabled. Options resolve
  environment-first, then from `pluginConfigs` in `~/.claude/settings.json`.
- **Never add `CLAUDE_PLUGIN_DATA` to the state-directory chain.** It is
  exported by whichever plugin owns the running hook and leaks into unrelated
  shells; a classic install would silently relocate its state into another
  plugin's data directory. `UM_STATE_DIR` is the only knob.
- `userConfig` defaults are never materialised into the environment — an unset
  `CLAUDE_PLUGIN_OPTION_*` is the normal case, so every default is duplicated in
  bash. Booleans arrive as the literal strings `true` / `false`.
- The plugin's launchd label is `com.claude.usage-monitor.plugin`, deliberately
  distinct from the classic one, and `UM_NO_LAUNCHCTL=1` makes the bootstrap
  generate the plist without touching launchd (which ignores `HOME`, so this is
  the only way to verify that path safely).

### Experimental mod

- `mods/limit-alerts-status/` — a separate plugin of TypeScript function hooks
  (a Claude Code "mod"), not part of the `limit-alerts` plugin and not listed
  in `marketplace.json`. It shows the limits via `$.ui.status` instead of
  writing `statusLine` into `settings.json`: a fresh
  `usage-monitor-cache.json` first (same directory chain as the bash scripts,
  then `~/.claude/plugins/data/limit-alerts-*`), else the engine's own
  `$.session.usage().rateLimits` (5h/7d only, no scoped weekly limit), else a
  stale cache marked with its age.
- The mod API is early access and changes between Claude Code releases —
  that is why it stays out of the shipped plugin. Load it with
  `claude --plugin-dir mods/limit-alerts-status`; check it with
  `claude plugin validate` and `claude plugin test` on that folder.
  `.claude-plugin/types/` inside it is generated by the engine and gitignored.
- It is the one place in the repository that is not bash; the "no test
  framework" rule below covers the shell scripts, the mod has its own
  `*.test.ts`.

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
