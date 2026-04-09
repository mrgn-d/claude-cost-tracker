#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Use a temp dir for test isolation
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

export COST_TRACKER_DIR="$TEST_DIR"

# Setup
mkdir -p "$TEST_DIR/tags"
cp "$BASE_DIR/config.json" "$TEST_DIR/config.json"
echo '{}' > "$TEST_DIR/tags/sessions.json"
touch "$TEST_DIR/activity.jsonl"

HOOK="$SCRIPT_DIR/hook-prompt-submit.js"
PASS=0
FAIL=0

run_test() {
  local name="$1"
  local payload="$2"
  local check_fn="$3"

  # Reset sessions.json between tests
  echo '{}' > "$TEST_DIR/tags/sessions.json"
  > "$TEST_DIR/activity.jsonl"

  echo "$payload" | node "$HOOK"

  if $check_fn; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name"
    ((FAIL++)) || true
  fi
}

# ── Test 1: ticket extraction ────────────────────────────────────────────────
check_test1() {
  local sessions
  sessions="$(cat "$TEST_DIR/tags/sessions.json")"
  # Should contain the ticket ENG-456
  echo "$sessions" | grep -q '"ticket"' && echo "$sessions" | grep -q 'ENG-456'
}

run_test \
  "Ticket extracted from message with ENG-456" \
  '{"session_id":"sess-001","user_prompt":"Working on ENG-456 auth refactor"}' \
  check_test1

# ── Test 2: stage extraction from hashtag ────────────────────────────────────
check_test2() {
  local sessions
  sessions="$(cat "$TEST_DIR/tags/sessions.json")"
  echo "$sessions" | grep -q '"stage"' && echo "$sessions" | grep -q '"research"'
}

run_test \
  "Stage extracted from #research hashtag" \
  '{"session_id":"sess-002","user_prompt":"Starting #research on the new API design"}' \
  check_test2

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
