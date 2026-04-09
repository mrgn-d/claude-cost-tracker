#!/bin/bash
# Test: hook-post-tool.js appends correct JSONL to activity.jsonl
set -e

TEST_DIR=$(mktemp -d)
export COST_TRACKER_DIR="$TEST_DIR"

# Need config for auto-tag
mkdir -p "$TEST_DIR/tags"
cp ~/.claude/cost-tracker/config.json "$TEST_DIR/config.json"

# Mock PostToolUse input
echo '{
  "tool_name": "Bash",
  "tool_input": {"command": "ls"},
  "session_id": "test-session-123",
  "transcript_path": "/tmp/transcript",
  "tool_response": "file1.txt\nfile2.txt"
}' | CLAUDE_PROJECT_DIR="/Users/test/project" node ~/.claude/cost-tracker/bin/hook-post-tool.js

# Verify output
if [ ! -f "$TEST_DIR/activity.jsonl" ]; then
  echo "FAIL: activity.jsonl not created"
  rm -rf "$TEST_DIR"
  exit 1
fi

LINE=$(cat "$TEST_DIR/activity.jsonl")
echo "$LINE" | node -e "
const entry = JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
const checks = [
  ['toolName', entry.toolName === 'Bash'],
  ['sessionId', entry.sessionId === 'test-session-123'],
  ['project', entry.project === '/Users/test/project'],
  ['has timestamp', !!entry.timestamp],
  ['event', entry.event === 'tool_call'],
];
let passed = true;
for (const [name, ok] of checks) {
  console.log(ok ? 'PASS' : 'FAIL', name);
  if (!ok) passed = false;
}
if (!passed) process.exit(1);
"

echo "All tests passed"
rm -rf "$TEST_DIR"
