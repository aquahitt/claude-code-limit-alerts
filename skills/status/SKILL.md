---
name: status
description: Use when the user asks about their current Claude usage limits, how much of the 5-hour or weekly window is left, or when a limit window resets.
---

# Current usage limits

Run:

```bash
UM_STATE_DIR="${CLAUDE_PLUGIN_DATA}" bash "${CLAUDE_PLUGIN_ROOT}/scripts/usage-monitor.sh" status
```

Report the output as-is. Each line is one limit: its name, the percent used, and when that window resets.

If the output is empty, the usage endpoint could not be reached — say so rather than guessing at numbers. Put `UM_CACHE_TTL=0` in front of the command when the user wants a reading that bypasses the cache.
