---
name: release
description: Bump VERSION, write a Keep a Changelog entry, and tag a release for claude-code-limit-alerts
---

# Release

A simple single-package release (not a monorepo) — sources of truth are
`VERSION` (repo root) and `CHANGELOG.md`, formatted per
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) +
[SemVer](https://semver.org/).

**Irreversible steps (tag, push) only after the user explicitly confirms
the proposed version and entry text.**

## 1. Preflight

- [ ] `git status --porcelain` is empty, or only release files (VERSION,
  CHANGELOG.md) remain uncommitted.
- [ ] `git log --oneline -20` — what landed since the last tag/CHANGELOG.md
  entry:
  ```bash
  git log --oneline "$(cat VERSION 2>/dev/null | sed 's/^/v/')"..HEAD 2>/dev/null || git log --oneline -20
  ```
- [ ] Run the `check-scripts` skill — syntax/shellcheck must be clean.

## 2. Determine the bump

Conventional-commit prefixes this repo already uses
(`feat:`, `fix:`, `refactor:`, `chore:`, `docs:`):

- Breaking behavior for already-installed users (new mandatory flag,
  incompatible hook/plist format) → **minor** (project is still < 1.0.0,
  as was the case for 0.1.0→0.2.0), or discuss major if already on 1.x.
- Contains `feat:` → **minor**.
- Only `fix:`/`refactor:`/`chore:`/`docs:` → **patch**.

## 3. Draft the CHANGELOG.md entry

Format matches existing entries (`## [X.Y.Z] - YYYY-MM-DD`, subsections
`### Added` / `### Changed` / `### Fixed`, written in Russian — matching
the language of existing entries — one bullet per change, no references to
internal implementation details invisible to the user).

Show the draft to the user and wait for `ok` or edits.

## 4. After confirmation

```bash
echo -n "<X.Y.Z>" > VERSION
# add a section to CHANGELOG.md (after the title, before the previous version)
git add VERSION CHANGELOG.md
git commit -m "chore: bump version to <X.Y.Z>"
git tag -a "v<X.Y.Z>" -m "v<X.Y.Z>"
```

- [ ] `git push` and `git push origin "v<X.Y.Z>"` — only if the user
  explicitly asked to push, not merely confirmed the entry text.

## Idempotency

- Tag `v<X.Y.Z>` already exists → stop, ask the user.
- `VERSION` already equals the target version → the release is likely
  already done, stop.
