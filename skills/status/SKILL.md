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

The first line is the installed version. If a line starting with `⚠` follows, live data could not be fetched and the numbers come from the last cache — pass on its age, and treat a window marked "уже сброшен" / "already reset" as rolled over, its percent no longer current. If the output says there is no usage data, say so rather than guessing at numbers. Put `UM_CACHE_TTL=0` in front of the command when the user wants a reading that bypasses the cache.
