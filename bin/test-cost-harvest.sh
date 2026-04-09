#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COST_TRACKER_DIR="$(dirname "$SCRIPT_DIR")"

# Create temp dir
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "=== Test: cost-harvest.js ==="
echo "Temp dir: $TMP_DIR"

# Copy config to temp dir
cp "$COST_TRACKER_DIR/config.json" "$TMP_DIR/config.json"

# Create mock stats-cache.json with known values
cat > "$TMP_DIR/stats-cache.json" << 'EOF'
{
  "modelUsage": {
    "claude-opus-4-6": {
      "inputTokens": 506,
      "outputTokens": 2737,
      "cacheReadInputTokens": 27902102,
      "cacheCreationInputTokens": 2138188
    },
    "claude-sonnet-4-6": {
      "inputTokens": 1000,
      "outputTokens": 500,
      "cacheReadInputTokens": 0,
      "cacheCreationInputTokens": 0
    }
  }
}
EOF

# Run cost-harvest with env vars pointing to temp dir
STATS_CACHE="$TMP_DIR/stats-cache.json" \
COST_TRACKER_DIR="$TMP_DIR" \
  node "$SCRIPT_DIR/cost-harvest.js"

COSTS_FILE="$TMP_DIR/costs.jsonl"

# Verify costs.jsonl was created
if [ ! -f "$COSTS_FILE" ]; then
  echo "FAIL: costs.jsonl not created"
  exit 1
fi

echo ""
echo "--- costs.jsonl contents ---"
cat "$COSTS_FILE"
echo ""

# Parse and verify each line has required fields
PASS=true

while IFS= read -r line; do
  if [ -z "$line" ]; then continue; fi

  # Check required fields exist
  for field in model inputTokens outputTokens cacheReadTokens cacheCreationTokens estimatedCost harvestedAt; do
    if ! echo "$line" | node -e "
      const d = JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
      const field = '$field';
      if (!(field in d)) { console.error('Missing field: ' + field); process.exit(1); }
      if (field === 'estimatedCost' && (typeof d[field] !== 'number' || d[field] <= 0)) {
        console.error('estimatedCost must be positive number, got: ' + d[field]);
        process.exit(1);
      }
    " 2>&1; then
      echo "FAIL: line missing or invalid field '$field': $line"
      PASS=false
    fi
  done
done < "$COSTS_FILE"

# Verify opus cost calculation manually:
# inputTokens=506, outputTokens=2737, cacheRead=27902102, cacheCreate=2138188
# pricing: input=15.0, output=75.0, cacheRead=1.875, cacheWrite=18.75 (per million)
# cost = (506*15 + 2737*75 + 27902102*1.875 + 2138188*18.75) / 1000000
EXPECTED_OPUS=$(node -e "
  const cost = (506*15 + 2737*75 + 27902102*1.875 + 2138188*18.75) / 1000000;
  console.log(cost.toFixed(6));
")

ACTUAL_OPUS=$(node -e "
  const fs = require('fs');
  const lines = fs.readFileSync('$COSTS_FILE', 'utf8').trim().split('\n');
  const opus = lines.map(l => JSON.parse(l)).find(e => e.model === 'claude-opus-4-6');
  console.log(opus.estimatedCost.toFixed(6));
")

if [ "$EXPECTED_OPUS" != "$ACTUAL_OPUS" ]; then
  echo "FAIL: opus cost mismatch. Expected=$EXPECTED_OPUS Actual=$ACTUAL_OPUS"
  PASS=false
else
  echo "PASS: opus estimatedCost=$ACTUAL_OPUS (expected=$EXPECTED_OPUS)"
fi

# Verify sonnet cost
EXPECTED_SONNET=$(node -e "
  const cost = (1000*3.0 + 500*15.0 + 0 + 0) / 1000000;
  console.log(cost.toFixed(6));
")

ACTUAL_SONNET=$(node -e "
  const fs = require('fs');
  const lines = fs.readFileSync('$COSTS_FILE', 'utf8').trim().split('\n');
  const s = lines.map(l => JSON.parse(l)).find(e => e.model === 'claude-sonnet-4-6');
  console.log(s.estimatedCost.toFixed(6));
")

if [ "$EXPECTED_SONNET" != "$ACTUAL_SONNET" ]; then
  echo "FAIL: sonnet cost mismatch. Expected=$EXPECTED_SONNET Actual=$ACTUAL_SONNET"
  PASS=false
else
  echo "PASS: sonnet estimatedCost=$ACTUAL_SONNET (expected=$EXPECTED_SONNET)"
fi

if $PASS; then
  echo ""
  echo "=== ALL TESTS PASSED ==="
  exit 0
else
  echo ""
  echo "=== TESTS FAILED ==="
  exit 1
fi
