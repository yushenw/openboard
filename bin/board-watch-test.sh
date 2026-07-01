#!/usr/bin/env bash
# board-watch-test.sh — tests for board-watch (Tier-1 mentions/broadcast + Tier-2 task events).
# Creates a TEMP board+home dir; never touches the real shared board.
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
TASKS="$OB_HOME/tasks"

mkdir -p "$MESSAGES" "$AGENTS_DIR" "$OB_STATE" "$INBOX" "$TASKS"

PASS=0
FAIL=0
ok()   { echo "  PASS: $*"; ((PASS++)) || true; }
fail() { echo "  FAIL: $*"; ((FAIL++)) || true; }

# Helper: write a fake message file
write_msg() {
    # write_msg <id> <author> <type> <body> [slug] [refs]
    local id="$1" author="$2" type="$3" body="$4" slug="${5:-}" refs="${6:-[]}"
    local f="$MESSAGES/${id}.md"
    {
        echo "---"
        echo "id: $id"
        echo "author: $author"
        echo "type: $type"
        echo "time: ${id%%-*}"
        echo "refs: $refs"
        [[ -n "$slug" ]] && echo "slug: $slug"
        echo "status: open"
        echo "---"
        echo "$body"
    } > "$f"
}

# Helper: register a fake agent
register_agent() {
    printf '# %s\nupdated: 20260627T000000Z\nstatus: online\n' "$1" > "$AGENTS_DIR/${1}.md"
}

# Helper: write a fake task spec file
write_task() {
    # write_task <id> <created_by>
    local id="$1" creator="$2"
    cat > "$TASKS/${id}.md" <<EOF
---
id: $id
title: test task
type: code
created_by: $creator
time: 20260627T000000Z
verifier: none
status_hint: open
---
spec body
EOF
}

# ---------------------------------------------------------------------------
# Test 1: empty board -> no output
# ---------------------------------------------------------------------------
echo "Test 1: empty board -> no output"
out="$("$WATCH" --once 2>/dev/null)"
[[ -z "$out" ]] && ok "no output on empty board" || fail "expected no output, got: $out"

# ---------------------------------------------------------------------------
# Test 2: @mention fires for the mentioned agent only
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
if [[ -f "$INBOX/bob.md" ]]; then fail "bob should NOT have an inbox entry"; else ok "bob inbox correctly absent"; fi

# ---------------------------------------------------------------------------
# Test 3: cursor prevents re-delivery
# ---------------------------------------------------------------------------
echo "Test 3: cursor prevents re-delivery"
out2="$("$WATCH" --once 2>/dev/null)"
[[ -z "$out2" ]] && ok "no duplicate delivery after cursor advance" || fail "got output on second --once: $out2"

# ---------------------------------------------------------------------------
# Test 4: type=question broadcasts to all registered agents except author
# ---------------------------------------------------------------------------
echo "Test 4: type=question broadcasts to all registered agents"
write_msg "20260627T020000Z-charlie-q1" "charlie" "question" "Does anyone know how to sync?"
"$WATCH" --once 2>/dev/null

grep -q "20260627T020000Z-charlie-q1" "$INBOX/alice.md" 2>/dev/null && ok "alice received question" || fail "alice missing question"
grep -q "20260627T020000Z-charlie-q1" "$INBOX/bob.md" 2>/dev/null && ok "bob received question" || fail "bob missing question"
if grep -q "20260627T020000Z-charlie-q1" "$INBOX/charlie.md" 2>/dev/null; then
    fail "charlie (author) should NOT receive their own question"
else
    ok "charlie (author) correctly skipped"
fi

# ---------------------------------------------------------------------------
# Test 5: type=review broadcasts to all registered agents except author
# ---------------------------------------------------------------------------
echo "Test 5: type=review broadcasts to all registered agents"
write_msg "20260627T030000Z-alice-review1" "alice" "review" "score: 8, verdict: pass"
"$WATCH" --once 2>/dev/null

grep -q "20260627T030000Z-alice-review1" "$INBOX/bob.md" 2>/dev/null && ok "bob received review" || fail "bob missing review"
if grep -q "20260627T030000Z-alice-review1" "$INBOX/alice.md" 2>/dev/null; then
    fail "alice (author) should NOT get their own review"
else
    ok "alice (author) correctly skipped"
fi

# ---------------------------------------------------------------------------
# Test 6: multiple @mentions, each agent notified exactly once
# ---------------------------------------------------------------------------
echo "Test 6: multiple @mentions in one message"
write_msg "20260627T040000Z-charlie-multi" "charlie" "propose" "Hey @alice and @bob please review"
"$WATCH" --once 2>/dev/null

ac=$(grep -c "20260627T040000Z-charlie-multi" "$INBOX/alice.md" 2>/dev/null || echo 0)
bc=$(grep -c "20260627T040000Z-charlie-multi" "$INBOX/bob.md" 2>/dev/null || echo 0)
[[ "$ac" -eq 1 ]] && ok "alice notified exactly once (multi-mention)" || fail "alice count=$ac (expected 1)"
[[ "$bc" -eq 1 ]] && ok "bob notified exactly once (multi-mention)" || fail "bob count=$bc (expected 1)"

# ---------------------------------------------------------------------------
# Test 7: new tasks/TASK-*.md file -> broadcast to all registered except creator
# ---------------------------------------------------------------------------
echo "Test 7: new task file broadcasts to registered agents except creator"
write_task "TASK-007-widget" "alice"
"$WATCH" --once 2>/dev/null

grep -q "new task TASK-007-widget" "$INBOX/bob.md" 2>/dev/null && ok "bob notified of new task" || fail "bob missing new-task notice"
if grep -q "new task TASK-007-widget" "$INBOX/alice.md" 2>/dev/null; then
    fail "alice (creator) should NOT be notified of own task"
else
    ok "alice (creator) correctly skipped"
fi

# ---------------------------------------------------------------------------
# Test 8: type=claim with a TASK slug -> "task <id> claimed" broadcast
# ---------------------------------------------------------------------------
echo "Test 8: task claim event broadcasts 'claimed'"
write_msg "20260627T050000Z-bob-task-007-widget" "bob" "claim" "claiming task-007-widget" "task-007-widget"
"$WATCH" --once 2>/dev/null

if grep -q "task task-007-widget claimed" "$INBOX/alice.md" 2>/dev/null; then
    ok "alice notified of task claim"
else
    fail "alice missing task-claim notice"
fi
if grep -q "task task-007-widget claimed" "$INBOX/bob.md" 2>/dev/null; then
    fail "bob (claimer) should NOT be notified of own claim"
else
    ok "bob (claimer) correctly skipped"
fi

# ---------------------------------------------------------------------------
# Test 9: a NON-task claim must NOT produce a task-event notice
# ---------------------------------------------------------------------------
echo "Test 9: ordinary (non-task) claim produces no task notice"
write_msg "20260627T060000Z-charlie-sync-notify" "charlie" "claim" "claiming sync-notify" "sync-notify"
"$WATCH" --once 2>/dev/null

if grep -q "20260627T060000Z-charlie-sync-notify" "$INBOX/alice.md" 2>/dev/null; then
    fail "ordinary claim should NOT notify anyone"
else
    ok "ordinary claim correctly produced no notice"
fi

# ---------------------------------------------------------------------------
# Test 10: type=decision ref'ing a TASK -> "task <id> closed" broadcast
# ---------------------------------------------------------------------------
echo "Test 10: task close (decision ref) broadcasts 'closed'"
write_msg "20260627T070000Z-alice-close-007" "alice" "decision" "closing it" "" "[TASK-007-widget]"
"$WATCH" --once 2>/dev/null

if grep -q "task TASK-007-widget closed" "$INBOX/bob.md" 2>/dev/null; then
    ok "bob notified of task close"
else
    fail "bob missing task-close notice"
fi

# ---------------------------------------------------------------------------
# Test 11: --digest skips when CLI has no digest subcommand
# ---------------------------------------------------------------------------
echo "Test 11: --digest capability check (no digest subcommand -> skip)"
STUB_NO="$TMPDIR_ROOT/board-nodigest"
cat > "$STUB_NO" <<'EOF'
#!/usr/bin/env bash
# stub CLI WITHOUT a digest subcommand
case "${1:-}" in
  help) echo "usage: board {who|read|post}"; exit 0 ;;
  digest) echo "wrote digest" > "$OB_BOARD/digest.md"; exit 0 ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$STUB_NO"

OB_BOARD_CLI="$STUB_NO" "$WATCH" --once --digest >/dev/null 2>&1
if [[ ! -f "$OB_BOARD/digest.md" ]]; then
    ok "digest skipped (capability check: no 'digest' in help)"
else
    fail "digest should have been skipped but digest.md exists"
fi

# ---------------------------------------------------------------------------
# Test 12: --digest runs when CLI advertises a digest subcommand
# ---------------------------------------------------------------------------
echo "Test 12: --digest runs when CLI supports digest"
STUB_YES="$TMPDIR_ROOT/board-digest"
cat > "$STUB_YES" <<'EOF'
#!/usr/bin/env bash
# stub CLI WITH a digest subcommand
case "${1:-}" in
  help) echo "usage: board {who|read|post|digest}"; exit 0 ;;
  digest) echo "DIGEST OK" > "$OB_BOARD/digest.md"; exit 0 ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$STUB_YES"

rm -f "$OB_BOARD/digest.md"
OB_BOARD_CLI="$STUB_YES" "$WATCH" --once --digest >/dev/null 2>&1
if [[ -f "$OB_BOARD/digest.md" ]] && grep -q "DIGEST OK" "$OB_BOARD/digest.md"; then
    ok "digest written via capable CLI"
else
    fail "digest.md not written by capable CLI"
fi

# ---------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
