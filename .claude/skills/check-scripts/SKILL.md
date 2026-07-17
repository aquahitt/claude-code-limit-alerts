---
name: check-scripts
description: Run the full shell quality gate (bash -n + shellcheck) before commit — this project has no test framework, this is the whole gate
---

# Check Scripts

This project is pure bash with no test runner. This is the entire quality
gate before a commit.

- [ ] **Syntax** — all changed `*.sh` files parse cleanly:
  ```bash
  git diff --name-only --diff-filter=ACM HEAD -- '*.sh' | xargs -I{} bash -n {}
  ```

- [ ] **shellcheck** (if installed — `brew install shellcheck`; if not,
  skip this step and say so explicitly, don't pretend it passed):
  ```bash
  git diff --name-only --diff-filter=ACM HEAD -- '*.sh' | xargs shellcheck -S warning
  ```
  Existing code may not be idiomatically shellcheck-clean — focus on
  new/changed lines, don't rewrite unrelated chunks just to satisfy the
  linter.

- [ ] **Manual behavior check.** There are no automated tests — wherever
  logic in `install.sh`/`uninstall.sh`/`update.sh`/`lib/hooks.sh` changed,
  exercise it with real commands and expected output. Edits that touch
  `~/.claude/settings.json` or launchd should be done with an overridden
  `HOME` (sandboxed), never against the real environment:
  ```bash
  env -i HOME=/tmp/fake-home PATH=/usr/bin:/bin:/usr/sbin:/sbin bash -c '...'
  ```

- [ ] If `install.sh`/`uninstall.sh`/`update.sh`/`lib/hooks.sh` changed —
  consider the `installer-safety-reviewer` skill/agent for idempotency and
  safety around editing the user's `settings.json`.

## All green?

Commit.
