---
name: uninstall
description: Use when the user wants to remove limit-alerts, disable the plugin cleanly, or undo the statusline and background agent it configured.
---

# Remove what the plugin wrote outside itself

Disabling a plugin does not undo writes it made elsewhere. Two things outlive it: the `statusLine` entry in `~/.claude/settings.json` and the launchd agent `com.claude.usage-monitor.plugin`.

Remove both by turning the options off and re-running the bootstrap:

```bash
UM_STATE_DIR="${CLAUDE_PLUGIN_DATA}" \
CLAUDE_PLUGIN_OPTION_STATUSLINE=false \
CLAUDE_PLUGIN_OPTION_LAUNCHD=false \
bash "${CLAUDE_PLUGIN_ROOT}/scripts/plugin-bootstrap.sh"
```

This restores whatever statusline was in place before the plugin took over, or removes the key if there was none, and unloads and deletes the agent's plist.

Then tell the user to disable or uninstall the plugin itself with `/plugin`.

State and cache live in `${CLAUDE_PLUGIN_DATA}` and go away with the plugin's data directory. Do not delete that directory while the plugin is still enabled — the next session start would just recreate it.
