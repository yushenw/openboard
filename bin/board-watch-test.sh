#!/usr/bin/env bash
# board-watch-test.sh — minimal test for board-watch
# Creates a TEMP board dir; never touches the real shared board.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCH="$SCRIPT_DIR/board-watch"

# ---------------------------------------------------------------------------
# Temp environment
# ---------------------------------------------------------------------------
TMPDIR_ROOT="$(mktemp -d /tmp/board-watch-test-XXXXXX)"
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

export OB_HOME="$TMPDIR_ROOT/repo"
export OB_BOARD="$OB_HOME/board"
export OB_STATE="$TMPDIR_ROOT/state"
MESSAGES="$OB_BOARD/messages"
AGENTS_DIR="$OB_BOARD/agents"
INBOX="$OB_BOARD/inbox"

mkdir -p "$MESSAGES" "$AGENTS_DIR" "$OB_STATE" "$INBOX"

PASS=0
FAIL=0

ok()   { echo "  PASS: $*"; ((PASS++)) || true; }
fail() { echo "  FAIL: $*"; ((FAIL++)) || true; }

# Helper: write a fake message file
write_msg() {
    local id="$1" author="$2" type="$3" body="$4"
    local f="$MESSAGES/${id}.md"
    cat > "$f" <<EOF
---
id: $id
author: $author
type: $type
time: ${id%%-*}
refs: []
status: open
---
$body
EOF
}

# Helper: register a fake agent
register_agent() {
    local name="$1"
    printf '# %s\nupdated: 20260627T000000Z\nstatus: online\n' "$name" > "$AGENTS_DIR/${name}.md"
}

# ---------------------------------------------------------------------------
# Test 1: --once with no messages produces no inbox entries
# ---------------------------------------------------------------------------
echo "Test 1: empty board -> no output"
out="$("$WATCH" --once 2>/dev/null)"
if [[ -z "$out" ]]; then
    ok "no output on empty board"
else
    fail "expected no output, got: $out"
fi

# ---------------------------------------------------------------------------
# Test 2: @mention fires for the mentioned agent
# ---------------------------------------------------------------------------
echo "Test 2: @mention fires for mentioned agent"
register_agent "alice"
register_agent "bob"

write_msg "20260627T010000Z-charlie-hello" "charlie" "propose" "Hey @alice check this out"

"$WATCH" --once 2>/dev/null

if [[ -f "$INBOX/alice.md" ]] && grep -q "20260627T010000Z-charlie-hello" "$INBOX/alice.md"; then
    ok "alice inbox has the @mention"
else
    fail "alice inbox missing @mention notice"
fi

if [[ -f "$INBOX/bob.md" ]]; then
    fail "bob should NOT have an inbox entry (not mentioned)"
else
    ok "bob inbox correctly absent"
fi

# ---------------------------------------------------------------------------
# Test 3: second --once sees nothing new (cursor advanced)
# ---------------------------------------------------------------------------
echo "Test 3: cursor prevents re-delivery"
out2="$("$WATCH" --once 2>/dev/null)"
if [[ -z "$out2" ]]; then
    ok "no duplicate delivery after cursor advance"
else
    fail "got output on second --once: $out2"
fi

# ---------------------------------------------------------------------------
# Test 4: type=question notifies all registered agents except author
# ---------------------------------------------------------------------------
echo "Test 4: type=question broadcasts to all registered agents"

write_msg "20260627T020000Z-charlie-q1" "charlie" "question" "Does anyone know how to sync?"

"$WATCH" --once 2>/dev/null

if [[ -f "$INBOX/alice.md" ]] && grep -q "20260627T020000Z-charlie-q1" "$INBOX/alice.md"; then
    ok "alice received question broadcast"
else
    fail "alice missing question broadcast"
fi

if [[ -f "$INBOX/bob.md" ]] && grep -q "20260627T020000Z-charlie-q1" "$INBOX/bob.md"; then
    ok "bob received question broadcast"
else
    fail "bob missing question broadcast"
fi

# charlie is the author; should NOT receive notice about their own question
if [[ -f "$INBOX/charlie.md" ]] && grep -q "20260627T020000Z-charlie-q1" "$INBOX/charlie.md"; then
    fail "charlie (author) should NOT receive their own question broadcast"
else
    ok "charlie (author) correctly skipped"
fi

# ---------------------------------------------------------------------------
# Test 5: type=review notifies all registered agents except author
# ---------------------------------------------------------------------------
echo "Test 5: type=review broadcasts to all registered agents"

write_msg "20260627T030000Z-alice-review1" "alice" "review" "score: 8, verdict: pass"

"$WATCH" --once 2>/dev/null

if [[ -f "$INBOX/bob.md" ]] && grep -q "20260627T030000Z-alice-review1" "$INBOX/bob.md"; then
    ok "bob received review broadcast"
else
    fail "bob missing review broadcast"
fi

if [[ -f "$INBOX/alice.md" ]] && grep -q "20260627T030000Z-alice-review1" "$INBOX/alice.md"; then
    fail "alice (author) should NOT get their own review"
else
    ok "alice (author) correctly skipped for their own review"
fi

# ---------------------------------------------------------------------------
# Test 6: multiple @mentions in one message
# ---------------------------------------------------------------------------
echo "Test 6: multiple @mentions in one message"

write_msg "20260627T040000Z-charlie-multi" "charlie" "propose" "Hey @alice and @bob please review"

"$WATCH" --once 2>/dev/null

alice_count=$(grep -c "20260627T040000Z-charlie-multi" "$INBOX/alice.md" 2>/dev/null || echo 0)
bob_count=$(grep -c "20260627T040000Z-charlie-multi" "$INBOX/bob.md" 2>/dev/null || echo 0)

if [[ "$alice_count" -eq 1 ]]; then
    ok "alice notified exactly once (multi-mention)"
else
    fail "alice notice count=$alice_count (expected 1)"
fi

if [[ "$bob_count" -eq 1 ]]; then
    ok "bob notified exactly once (multi-mention)"
else
    fail "bob notice count=$bob_count (expected 1)"
fi

# ---------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
