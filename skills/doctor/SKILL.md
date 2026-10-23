---
name: doctor
description: Use when limit-alerts seems not to work — no notifications, no limits in the statusline, stale or missing numbers — or the user asks to check or diagnose the installation.
---

# Check the limit-alerts installation

Run:

```bash
UM_STATE_DIR="${CLAUDE_PLUGIN_DATA}" bash "${CLAUDE_PLUGIN_ROOT}/scripts/usage-monitor.sh" doctor
```

It reads files only and makes no request to the usage endpoint, so it is safe to run at any time, including during a rate-limit pause.

Each line is one check: `✓` is fine, `⚠` needs attention, `·` is information. Report the `⚠` lines first, each with the fix the line itself names; if there are none, say the installation looks healthy and mention anything notable among the `·` lines (for example, the background agent being off).

macOS does not let a script read whether banners are allowed. When the user says notifications do not appear, add `--notify` at the end of the command: it sends a test notification. If the user does not see it, notifications for "Script Editor" have to be allowed in System Settings → Notifications.

A line saying the session runs an older plugin version than the one installed means the user should restart Claude Code.
