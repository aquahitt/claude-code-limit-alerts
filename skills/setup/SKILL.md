---
name: setup
description: Use when the user wants to turn the limit-alerts statusline or background agent on or off, or asks why limits are not showing in their statusline after changing the plugin configuration.
---

# Apply limit-alerts settings

The statusline and the background launchd agent are controlled by the `statusline` and `launchd` options in the plugin configuration (`/plugin` → limit-alerts → Configure). Changes normally take effect at the next session start; this skill applies them now.

Run:

```bash
UM_STATE_DIR="${CLAUDE_PLUGIN_DATA}" bash "${CLAUDE_PLUGIN_ROOT}/scripts/plugin-bootstrap.sh"
```

Report any message it prints. Silence means everything already matches the configuration.

Two things this will refuse to do, and both are deliberate:

- If `install.sh` is also installed, neither the statusline nor the agent is touched. The user has to pick one installation — `uninstall.sh` from the repository removes the classic one.
- A statusline the user set themselves is preserved, not replaced: it keeps rendering, with the limits appended after it.

A statusline change needs a Claude Code restart to show up.
