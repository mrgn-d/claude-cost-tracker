---
name: cost-harvest
description: Manually harvest costs from Claude Code session files into the cost tracker
argument-hint: ""
allowed-tools: [Bash]
---

Run a manual cost harvest to pick up costs from recent sessions.

```bash
echo '{}' | node ~/.claude/cost-tracker/bin/cost-harvest.js
```

The harvest normally runs automatically on SessionStart, but this forces an immediate update.
After harvesting, show the user a summary report for today.
