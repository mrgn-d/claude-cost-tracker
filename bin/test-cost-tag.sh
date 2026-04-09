#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COST_TAG="$SCRIPT_DIR/cost-tag"

# ── Setup temp dir ────────────────────────────────────────────────────────────
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

mkdir -p "$TMPDIR/tags"

# Empty sessions.json
echo '{}' > "$TMPDIR/tags/sessions.json"

# Config
cat > "$TMPDIR/config.json" <<'EOF'
{
  "ticketPattern": "[A-Z]{2,6}-\\d+",
  "autoTagPatterns": { "ticketFromBranch": true, "ticketFromMessage": true, "inferStage": true }
}
EOF

# Mock activity.jsonl: sess-1 (no inline ticket), sess-2 (has inline ticket ENG-100)
cat > "$TMPDIR/activity.jsonl" <<'EOF'
{"timestamp":"2026-04-07T10:00:00Z","event":"session_start","sessionId":"sess-1","project":"/home/user/myproject","tags":{}}
{"timestamp":"2026-04-07T10:01:00Z","event":"tool_call","sessionId":"sess-1","toolName":"Read","project":"/home/user/myproject","tags":{}}
{"timestamp":"2026-04-07T10:02:00Z","event":"tool_call","sessionId":"sess-1","toolName":"Edit","project":"/home/user/myproject","tags":{}}
{"timestamp":"2026-04-07T11:00:00Z","event":"session_start","sessionId":"sess-2","project":"/home/user/otherproject","tags":{"ticket":"ENG-100"}}
{"timestamp":"2026-04-07T11:01:00Z","event":"tool_call","sessionId":"sess-2","toolName":"Bash","project":"/home/user/otherproject","tags":{"ticket":"ENG-100"}}
EOF

export COST_TRACKER_DIR="$TMPDIR"

PASS=0
FAIL=0

check() {
  local desc="$1"
  local result="$2"
  local expected="$3"
  if echo "$result" | grep -qF "$expected"; then
    echo "  PASS: $desc"
    ((PASS++)) || true
  else
    echo "  FAIL: $desc"
    echo "    Expected to find: $expected"
    echo "    Got: $result"
    ((FAIL++)) || true
  fi
}

# ── Test 1: Tag sess-1 with ticket ENG-456 ────────────────────────────────────
echo "Test 1: --session sess-1 --ticket ENG-456"
OUT=$("$COST_TAG" --session sess-1 --ticket ENG-456)
check "confirmation printed" "$OUT" "Tagged session sess-1"
check "ticket shown in output" "$OUT" "ENG-456"

# Verify sessions.json updated
SESSIONS=$(cat "$TMPDIR/tags/sessions.json")
check "sessions.json has sess-1" "$SESSIONS" "sess-1"
check "sessions.json has ENG-456" "$SESSIONS" "ENG-456"

# ── Test 2: Add stage to sess-1 ───────────────────────────────────────────────
echo "Test 2: --session sess-1 --stage research"
OUT=$("$COST_TAG" --session sess-1 --stage research)
check "confirmation printed" "$OUT" "Tagged session sess-1"
check "stage shown in output" "$OUT" "research"

SESSIONS=$(cat "$TMPDIR/tags/sessions.json")
check "sessions.json has stage research" "$SESSIONS" "research"
# ticket should still be present
check "sessions.json still has ENG-456" "$SESSIONS" "ENG-456"

# ── Test 3: --list-untagged ───────────────────────────────────────────────────
echo "Test 3: --list-untagged"
OUT=$("$COST_TAG" --list-untagged)

# sess-1 is now tagged — should NOT appear
if echo "$OUT" | grep -qF "sess-1"; then
  echo "  FAIL: sess-1 should NOT appear in untagged list"
  ((FAIL++)) || true
else
  echo "  PASS: sess-1 correctly absent from untagged list"
  ((PASS++)) || true
fi

# sess-2 has no sessions.json entry — should appear
check "sess-2 appears in untagged list" "$OUT" "sess-2"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
