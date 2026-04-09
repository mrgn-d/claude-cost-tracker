---
name: cost-tag
description: Tag a Claude Code session with a ticket, summary, or stage for cost tracking
argument-hint: --session <id> [--ticket TICKET] [--summary "text"] [--stage stage] [--note "text"]
allowed-tools: [Bash]
---

Tag a session for cost tracking. Pass through all arguments.

```bash
node ~/.claude/cost-tracker/bin/cost-tag $ARGUMENTS
```

If the user provides a session ID without flags, ask what they want to tag it with.

If the user says `--list-untagged`, show untagged sessions.
