---
name: cost-report
description: Show Claude Code cost report with session breakdowns, token counts, and ROI analysis
argument-hint: [--range YYYY-MM-DD:YYYY-MM-DD] [--session <id>] [--format summary|csv|justify|untagged]
allowed-tools: [Bash]
---

Run the cost tracker report. Pass through any arguments the user provides.

```bash
node ~/.claude/cost-tracker/bin/cost-report $ARGUMENTS
```

If no arguments given, run with no flags (shows all-time summary).

Common usage:
- `/cost-report` — full summary
- `/cost-report --range 2026-04-07:2026-04-08` — date range
- `/cost-report --session <8-char-id>` — session detail with stage/turn breakdown
- `/cost-report --format justify` — ROI justification report
- `/cost-report --format csv` — CSV export

After showing the report, offer to tag any untagged sessions if there are any.
