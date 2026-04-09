# Claude Cost Tracker

Hook-based cost tracking for [Claude Code](https://docs.anthropic.com/en/docs/claude-code). Reads per-turn token usage from session files to compute accurate costs, broken down by session, project, ticket, and stage.

## What it does

- Tracks costs per session by reading Claude Code's internal session JSONL files
- Auto-tags sessions with ticket IDs from git branches and prompt text
- Infers work stages (research, implementation, execution, testing) from tool usage
- Generates reports: summary, per-session detail, CSV export, ROI justification
- Supports manual session tagging with summaries, tickets, and notes
- Calculates active time (excludes idle gaps) for ROI estimates

## Install

Add to your Claude Code `~/.claude/settings.json`:

```json
{
  "extraKnownMarketplaces": {
    "claude-cost-tracker": {
      "source": {
        "source": "github",
        "repo": "mrgn-d/claude-cost-tracker"
      }
    }
  }
}
```

Then enable the plugin:

```json
{
  "enabledPlugins": {
    "cost-tracker@claude-cost-tracker": true
  }
}
```

Run setup to initialize the data directory:

```bash
node ~/.claude/plugins/marketplaces/claude-cost-tracker/bin/setup.js
```

### Manual install

Clone the repo and register the hooks directly in `~/.claude/settings.json`:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "",
        "hooks": [
          { "type": "command", "command": "node /path/to/claude-cost-tracker/bin/hook-session-start.js" },
          { "type": "command", "command": "node /path/to/claude-cost-tracker/bin/cost-harvest.js" }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "",
        "hooks": [
          { "type": "command", "command": "node /path/to/claude-cost-tracker/bin/hook-post-tool.js" }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "matcher": "",
        "hooks": [
          { "type": "command", "command": "node /path/to/claude-cost-tracker/bin/hook-prompt-submit.js" }
        ]
      }
    ]
  }
}
```

## How it works

### Hooks

Three hooks run automatically:

| Hook | Script | Purpose |
|------|--------|---------|
| `SessionStart` | `hook-session-start.js` | Logs session start, auto-tags ticket from git branch |
| `SessionStart` | `cost-harvest.js` | Scans session JSONL files for token usage, computes costs |
| `PostToolUse` | `hook-post-tool.js` | Logs each tool call with inferred stage |
| `UserPromptSubmit` | `hook-prompt-submit.js` | Extracts `#summary`, `#stage`, and ticket IDs from prompts |

### Cost calculation

The harvester reads `~/.claude/projects/*/SESSION_ID.jsonl` files. Each assistant turn contains a `usage` object with exact token counts:

```
input_tokens, output_tokens, cache_read_input_tokens, cache_creation_input_tokens
```

These are multiplied by per-model pricing from `config.json` to compute costs. The harvest runs on every `SessionStart`, capturing costs from all sessions modified since the last harvest.

### Stage inference

Tool calls are automatically classified into stages:

| Tools | Stage |
|-------|-------|
| Read, Grep, Glob, WebSearch, WebFetch | `research` |
| Edit, Write, NotebookEdit | `implementation` |
| Bash (general) | `execution` |
| Bash (test/jest/pytest/spec) | `testing` |
| Bash (lint/eslint) | `review` |
| Agent | `agent` |

### Active time

ROI calculations use active time, not wall clock time. Consecutive events within a configurable idle threshold (default: 5 minutes) are counted as active. Gaps longer than the threshold are treated as idle and excluded.

## Usage

### Reports

```bash
# Summary report (all time)
cost-report

# Date range
cost-report --range 2026-04-07:2026-04-08

# Open-ended range (from date to now)
cost-report --range 2026-04-01:

# Single day
cost-report --range 2026-04-07:2026-04-07

# Session detail (stage breakdown, most expensive turns)
cost-report --session 293719ef

# ROI justification (grouped by ticket)
cost-report --format justify --range 2026-04-07:2026-04-08

# CSV export
cost-report --format csv --range 2026-04-01:2026-04-30

# List untagged sessions
cost-report --format untagged
```

### Tagging sessions

Tag sessions with tickets, summaries, stages, or notes:

```bash
# Tag with a ticket
cost-tag --session 293719ef-6d80-45ea-aa86-53fbd87cc333 --ticket AUD-1491

# Override the auto-detected summary
cost-tag --session 293719ef-6d80-45ea-aa86-53fbd87cc333 --summary "Cost tracker calibration"

# Multiple tags at once
cost-tag --session 293719ef-... --ticket AUD-1491 --summary "Build cost tracker" --note "initial prototype"

# List untagged sessions
cost-tag --list-untagged
```

#### In-session tagging

From within an active Claude Code session, include hashtags in your prompt:

```
#summary Build the cost tracker
Fix the bug in the harvest script
```

Supported inline tags:
- `#summary <text>` — sets the session summary
- `#research`, `#implementation`, `#testing`, `#review`, `#debug`, `#plan`, `#prd`, `#code` — sets the session stage
- Ticket patterns (e.g. `AUD-1491`, `ENG-123`) are auto-detected

### Manual harvest

The harvest runs automatically on session start. To force an immediate update:

```bash
echo '{}' | node /path/to/claude-cost-tracker/bin/cost-harvest.js
```

Or use the slash command within Claude Code: `/cost-harvest`

## Configuration

Copy `config.default.json` to your data directory as `config.json` and customize:

```json
{
  "pricing": {
    "claude-opus-4-6": {
      "input": 3.0,
      "output": 15.0,
      "cacheRead": 0.375,
      "cacheWrite": 3.75
    },
    "claude-sonnet-4-6": {
      "input": 3.0,
      "output": 15.0,
      "cacheRead": 0.375,
      "cacheWrite": 3.75
    }
  },
  "roiMultiplierByStage": {
    "research": 2,
    "implementation": 2,
    "execution": 2,
    "testing": 4,
    "review": 4,
    "thinking": 2,
    "agent": 2,
    "other": 2
  },
  "roiMultiplier": 2,
  "engineerHourlyRate": 100,
  "idleThresholdMinutes": 5,
  "nudgeAfterToolCalls": 20,
  "ticketPattern": "[A-Z]{2,6}-\\d+",
  "autoTagPatterns": {
    "ticketFromBranch": true,
    "ticketFromMessage": true,
    "inferStage": true
  }
}
```

### Pricing

Rates are per million tokens. The defaults above reflect Claude Max/Enterprise pricing where Opus is billed at Sonnet rates. For API usage, set Opus rates to `input: 15.0, output: 75.0, cacheRead: 1.875, cacheWrite: 18.75`.

### ROI multipliers

Per-stage multipliers estimate how much longer the work would take without Claude. A `testing: 4` multiplier means "writing tests takes 4x longer manually than with Claude assistance."

### Idle threshold

`idleThresholdMinutes` controls the gap threshold for active time calculation. Events within this window are counted as continuous work. Gaps longer than this are treated as idle time.

## Data files

All user data is stored in the data directory (default: `~/.claude/cost-tracker/`):

| File | Purpose |
|------|---------|
| `activity.jsonl` | Tool calls, session starts, prompt events |
| `costs.jsonl` | Per-session cost entries from harvests |
| `last-harvest.json` | Tracks which sessions have been harvested |
| `config.json` | User pricing and ROI configuration |
| `tags/sessions.json` | Manual session tags (tickets, summaries, notes) |

## License

MIT
