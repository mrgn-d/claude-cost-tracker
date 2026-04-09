#!/usr/bin/env bash
set -euo pipefail

# Test harness for hook-session-start.js
PASS=0
FAIL=0

# Use a temp directory to isolate test state
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# Set up a minimal cost-tracker dir
mkdir -p "$TMP_DIR/tags"
echo '{"ticketPattern":"[A-Z]{2,6}-\\d+","autoTagPatterns":{"ticketFromBranch":true}}' > "$TMP_DIR/config.json"
echo '{}' > "$TMP_DIR/tags/sessions.json"

HOOK="$(dirname "$0")/hook-session-start.js"

ok() {
  echo "  PASS: $1"
  PASS=$((PASS + 1))
}

fail() {
  echo "  FAIL: $1"
  FAIL=$((FAIL + 1))
}

# -------------------------------------------------------
# Test 1: Basic session_start entry in activity.jsonl
# -------------------------------------------------------
echo "Test 1: Creates activity.jsonl entry with event:session_start"

MOCK_JSON='{"session_id":"test-sess-001","transcript_path":"/tmp/transcript.jsonl"}'

COST_TRACKER_DIR="$TMP_DIR" \
  node "$HOOK" <<< "$MOCK_JSON"

if [ ! -f "$TMP_DIR/activity.jsonl" ]; then
  fail "activity.jsonl was not created"
else
  LINE=$(tail -1 "$TMP_DIR/activity.jsonl")

  if echo "$LINE" | node -e "
    const d = JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
    if (d.event !== 'session_start') process.exit(1);
    if (d.sessionId !== 'test-sess-001') process.exit(1);
    if (!d.timestamp) process.exit(1);
    if (!('project' in d)) process.exit(1);
    if (!('tags' in d)) process.exit(1);
  " 2>/dev/null; then
    ok "entry has event:session_start, sessionId, timestamp, project, tags"
  else
    fail "entry missing required fields"
    echo "    Got: $LINE"
  fi
fi

# -------------------------------------------------------
# Test 2: No ticket → sessions.json stays unchanged
# -------------------------------------------------------
echo "Test 2: No ticket found — sessions.json not modified"

SESSIONS_BEFORE=$(cat "$TMP_DIR/tags/sessions.json")

COST_TRACKER_DIR="$TMP_DIR" \
  node "$HOOK" <<< '{"session_id":"no-ticket-sess","transcript_path":"/tmp/x.jsonl"}'

SESSIONS_AFTER=$(cat "$TMP_DIR/tags/sessions.json")

if [ "$SESSIONS_BEFORE" = "$SESSIONS_AFTER" ]; then
  ok "sessions.json unchanged when no ticket"
else
  fail "sessions.json was modified unexpectedly"
  echo "    Before: $SESSIONS_BEFORE"
  echo "    After:  $SESSIONS_AFTER"
fi

# -------------------------------------------------------
# Test 3: Ticket found via git branch → sessions.json updated
# -------------------------------------------------------
echo "Test 3: Ticket from git branch → sessions.json updated"

# Create a fake git repo with a ticket branch
GIT_REPO="$TMP_DIR/repo"
mkdir -p "$GIT_REPO"
git -C "$GIT_REPO" init -q
git -C "$GIT_REPO" -c user.email="test@test.com" -c user.name="Test" commit -q --allow-empty -m "init"
git -C "$GIT_REPO" checkout -qb "feature/PROJ-42-my-feature"

COST_TRACKER_DIR="$TMP_DIR" CLAUDE_PROJECT_DIR="$GIT_REPO" \
  node "$HOOK" <<< '{"session_id":"ticket-sess-777","transcript_path":"/tmp/y.jsonl"}'

SESSIONS=$(cat "$TMP_DIR/tags/sessions.json")

if echo "$SESSIONS" | node -e "
  const d = JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
  const s = d['ticket-sess-777'];
  if (!s) process.exit(1);
  if (s.ticket !== 'PROJ-42') process.exit(1);
  if (!s.startedAt) process.exit(1);
  if (!('project' in s)) process.exit(1);
" 2>/dev/null; then
  ok "sessions.json has ticket:PROJ-42, startedAt, project for sessionId"
else
  fail "sessions.json missing expected ticket entry"
  echo "    Got: $SESSIONS"
fi

# Check activity.jsonl also has the ticket tag
LAST_LINE=$(tail -1 "$TMP_DIR/activity.jsonl")
if echo "$LAST_LINE" | node -e "
  const d = JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
  if (d.tags && d.tags.ticket === 'PROJ-42') process.exit(0);
  process.exit(1);
" 2>/dev/null; then
  ok "activity.jsonl entry has tags.ticket:PROJ-42"
else
  fail "activity.jsonl entry missing tags.ticket"
  echo "    Got: $LAST_LINE"
fi

# -------------------------------------------------------
# Test 4: Invalid JSON input — no crash, no output
# -------------------------------------------------------
echo "Test 4: Invalid JSON input does not crash the hook"

LINES_BEFORE=$(wc -l < "$TMP_DIR/activity.jsonl")

COST_TRACKER_DIR="$TMP_DIR" \
  node "$HOOK" <<< "not valid json" && EXITED=0 || EXITED=$?

LINES_AFTER=$(wc -l < "$TMP_DIR/activity.jsonl")

if [ "$LINES_BEFORE" -eq "$LINES_AFTER" ]; then
  ok "no new entry written for invalid JSON"
else
  fail "unexpected entry written for invalid JSON"
fi

# -------------------------------------------------------
# Summary
# -------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
