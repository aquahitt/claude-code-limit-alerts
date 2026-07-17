---
name: sync-readmes
description: Keep README.md (RU, primary) and README.en.md (EN) structurally in sync after either one changes
---

# Sync READMEs

`README.md` (Russian, primary) and `README.en.md` (English) describe the
same tool and must have identical structure — same sections, same order,
equivalent content (not a literal translation, but no factual drift: flags,
environment variables, paths, command versions).

## Steps

- [ ] Compare section headings (`## ...`) in both files:
  ```bash
  grep -n '^## ' README.md
  grep -n '^## ' README.en.md
  ```
  Same set of sections in the same order (headings in their own language is
  expected; composition/order is not).

- [ ] If only one file was edited — port the change (adapting language and
  tone) to the other. Technical details (flags, variable names, paths,
  commands, version numbers, thresholds) must match literally.

- [ ] Check the cross-links in the header — `[English](README.en.md)` in
  `README.md` and `[Русский](README.md)` in `README.en.md` — both present.

- [ ] Check that output examples (notifications, statusline,
  `usage-monitor.sh status`) are identical in numbers/structure; only the
  text language differs.

- [ ] If the versions/flags/environment-variables section changed, also
  cross-check `CHANGELOG.md` and `docs/how-it-works.md`, where it may be
  duplicated.

## Done?

Both READMEs read as the same page in two languages.
