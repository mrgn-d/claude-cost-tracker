#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COST_REPORT="$SCRIPT_DIR/cost-report"

# ── setup temp dir ────────────────────────────────────────────────────────────
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

mkdir -p "$TMPDIR/tags"

# config.json
cat > "$TMPDIR/config.json" <<'EOF'
{
  "roiMultiplier": 4,
  "engineerHourlyRate": 75,
  "ticketPattern": "[A-Z]{2,6}-\\d+",
  "autoTagPatterns": { "ticketFromBranch": true, "inferStage": true }
}
EOF

# activity.jsonl — 2 sessions, 2 projects, 2 tickets, mixed stages
cat > "$TMPDIR/activity.jsonl" <<'EOF'
{"timestamp":"2025-04-01T09:00:00.000Z","event":"session_start","sessionId":"sess-aaa","project":"/Users/dev/splice/platform","tags":{}}
{"timestamp":"2025-04-01T09:01:00.000Z","event":"tool_call","sessionId":"sess-aaa","toolName":"Read","project":"/Users/dev/splice/platform","tags":{"ticket":"PLAT-101","stage":"research"}}
{"timestamp":"2025-04-01T09:05:00.000Z","event":"tool_call","sessionId":"sess-aaa","toolName":"Edit","project":"/Users/dev/splice/platform","tags":{"ticket":"PLAT-101","stage":"implementation"}}
{"timestamp":"2025-04-01T09:10:00.000Z","event":"tool_call","sessionId":"sess-aaa","toolName":"Bash","project":"/Users/dev/splice/platform","tags":{"ticket":"PLAT-101","stage":"testing"}}
{"timestamp":"2025-04-01T09:30:00.000Z","event":"session_start","sessionId":"sess-bbb","project":"/Users/dev/splice/mobile","tags":{}}
{"timestamp":"2025-04-01T09:31:00.000Z","event":"tool_call","sessionId":"sess-bbb","toolName":"Grep","project":"/Users/dev/splice/mobile","tags":{"ticket":"MOB-42","stage":"research"}}
{"timestamp":"2025-04-01T09:35:00.000Z","event":"tool_call","sessionId":"sess-bbb","toolName":"Write","project":"/Users/dev/splice/mobile","tags":{"ticket":"MOB-42","stage":"implementation"}}
{"timestamp":"2025-04-01T09:40:00.000Z","event":"tool_call","sessionId":"sess-bbb","toolName":"Read","project":"/Users/dev/splice/mobile","tags":{"ticket":"MOB-42"}}
EOF

# costs.jsonl
cat > "$TMPDIR/costs.jsonl" <<'EOF'
{"model":"claude-sonnet-4-6","inputTokens":100000,"outputTokens":5000,"cacheReadTokens":20000,"cacheCreationTokens":0,"estimatedCost":0.375,"harvestedAt":"2025-04-01T10:00:00.000Z"}
{"model":"claude-opus-4-6","inputTokens":10000,"outputTokens":1000,"cacheReadTokens":0,"cacheCreationTokens":500,"estimatedCost":0.234,"harvestedAt":"2025-04-01T10:00:00.000Z"}
EOF

# tags/sessions.json — sess-aaa tagged, sess-bbb untagged
cat > "$TMPDIR/tags/sessions.json" <<'EOF'
{
  "sess-aaa": {
    "ticket": "PLAT-101",
    "project": "/Users/dev/splice/platform",
    "startedAt": "2025-04-01T09:00:00.000Z"
  }
}
EOF

PASS=0
FAIL=0

run_test() {
  local name="$1"
  local result="$2"
  local check="$3"
  if echo "$result" | grep -q "$check"; then
    echo "  PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $name"
    echo "        expected to find: $check"
    echo "        in output:"
    echo "$result" | sed 's/^/          /'
    FAIL=$((FAIL + 1))
  fi
}

echo ""
echo "Running cost-report tests..."
echo ""

# Test 1: Default summary report
T1=$(COST_TRACKER_DIR="$TMPDIR" node "$COST_REPORT" 2>&1)
run_test "Summary: shows Total estimated cost" "$T1" "Total estimated cost"
run_test "Summary: shows Sessions" "$T1" "Sessions"
run_test "Summary: shows project breakdown" "$T1" "splice"

# Test 2: CSV format
T2=$(COST_TRACKER_DIR="$TMPDIR" node "$COST_REPORT" --format csv 2>&1)
run_test "CSV: has date header" "$T2" "date"
run_test "CSV: has session_id header" "$T2" "session_id"
run_test "CSV: has project column" "$T2" "project"
run_test "CSV: has tool_name column" "$T2" "tool_name"
run_test "CSV: has data row" "$T2" "sess-aaa"

# Test 3: --justify
T3=$(COST_TRACKER_DIR="$TMPDIR" node "$COST_REPORT" --justify 2>&1)
run_test "Justify: shows ROI info" "$T3" "ROI"
run_test "Justify: shows Engineer cost" "$T3" "engineer"
run_test "Justify: shows ticket" "$T3" "PLAT-101"

# Test 4: --untagged
T4=$(COST_TRACKER_DIR="$TMPDIR" node "$COST_REPORT" --untagged 2>&1)
run_test "Untagged: runs without error" "$T4" "Untagged Sessions"
run_test "Untagged: lists untagged session" "$T4" "sess-bbb"

echo ""
echo "Results: $PASS passed, $FAIL failed"
echo ""

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
