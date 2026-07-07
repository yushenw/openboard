#!/usr/bin/env bash
# Acceptance tests for the cold-start layer (decision 0012): init / brief / doctor / join.
# Runs against TEMP roots so it NEVER touches the real shared board.
#
#   bin under test: $REPO/bin/board  $REPO/bin/board-join  $REPO/bin/board-hook
#   board data:     throwaway mktemp roots
#
# Prints a per-test PASS/FAIL line and a summary. Exit 0 iff all pass.
set -uo pipefail   # NOT -e: we capture non-zero exit codes deliberately.

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
BOARD="$REPO/bin/board"
JOIN="$REPO/bin/board-join"
HOOK="$REPO/bin/board-hook"

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT
# no leaked OB_* from the calling shell: every test sets what it needs explicitly
unset OB_HOME OB_BOARD OB_AGENT 2>/dev/null || true

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf 'PASS  %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf 'FAIL  %s\n    %s\n' "$1" "${2:-}"; }
json_valid() { printf '%s' "$1" | python3 -c 'import sys,json; json.load(sys.stdin)' 2>/dev/null; }

# ---------------------------------------------------------------------------
# init
# ---------------------------------------------------------------------------
P1="$TMPROOT/proj1"; mkdir -p "$P1"

out=$("$BOARD" init "$P1" 2>&1)
if [ -f "$P1/.openboard/project" ] && [ -d "$P1/board/messages" ] && [ -d "$P1/tasks" ] \
   && [ -f "$P1/board/digest.md" ]; then
  ok "1 init scaffolds a fresh root (marker + config + board skeleton)"
else bad "1 init scaffolds a fresh root" "$out"; fi

out=$("$BOARD" init "$P1" 2>&1)
if printf '%s' "$out" | grep -q 'already present' && ! printf '%s' "$out" | grep -q '^created:'; then
  ok "2 init is idempotent (kept, nothing re-created)"
else bad "2 init is idempotent" "$out"; fi

( cd "$P1" && OB_AGENT=alice "$BOARD" register --role tester >/dev/null 2>&1 \
           && OB_AGENT=alice "$BOARD" post propose hi -m "hello" >/dev/null 2>&1 )
if ls "$P1"/board/messages/*-alice-hi.md >/dev/null 2>&1 && [ -f "$P1/board/agents/alice.md" ]; then
  ok "3 marker resolution: register+post from inside the root land in ITS board/"
else bad "3 marker resolution routes writes into the init'd root"; fi

# ---------------------------------------------------------------------------
# brief — single onboarding source
# ---------------------------------------------------------------------------
out=$(cd "$P1" && OB_AGENT=alice "$BOARD" brief --hook --role tester 2>&1)
if printf '%s' "$out" | grep -q 'agent "alice" (role: tester)' \
   && printf '%s' "$out" | grep -q 'OpenBoard digest' \
   && printf '%s' "$out" | grep -q 'Work loop:'; then
  ok "4 brief --hook renders agent/role + digest + work loop"
else bad "4 brief --hook content" "$out"; fi

out=$(cd "$P1" && env -u OB_AGENT "$BOARD" brief --paste --role builder 2>&1)
if printf '%s' "$out" | grep -q "Board root: $P1" && printf '%s' "$out" | grep -q '<NAME>'; then
  ok "5 brief --paste fills the REAL root path; placeholder when agent unknown"
else bad "5 brief --paste path filling" "$out"; fi

out=$(cd "$P1" && OB_AGENT=alice "$BOARD" brief --json 2>&1)
if json_valid "$out" && printf '%s' "$out" | python3 -c '
import sys,json; d=json.load(sys.stdin)
assert d["agent"]=="alice" and d["role"]=="tester" and "Work loop" in d["brief"]' 2>/dev/null; then
  ok "6 brief --json valid; role auto-resolved from the agent registration"
else bad "6 brief --json + role fallback" "$out"; fi

# ---------------------------------------------------------------------------
# doctor
# ---------------------------------------------------------------------------
out=$(cd "$P1" && OB_AGENT=alice "$BOARD" doctor 2>&1); rc=$?
if [ $rc -eq 0 ] && printf '%s' "$out" | grep -q 'RESULT: ok'; then
  ok "7 doctor green on a healthy root (exit 0)"
else bad "7 doctor green on healthy root" "rc=$rc: $out"; fi

out=$(cd "$P1" && env -u OB_AGENT "$BOARD" doctor 2>&1); rc=$?
if [ $rc -ne 0 ] && printf '%s' "$out" | grep -q 'FAIL identity'; then
  ok "8 doctor without identity: non-zero exit + FAIL identity line"
else bad "8 doctor missing-identity detection" "rc=$rc: $out"; fi

n_before=$(ls "$P1/board/messages" | wc -l)
( cd "$P1" && OB_AGENT=alice "$BOARD" doctor >/dev/null 2>&1 )
n_after=$(ls "$P1/board/messages" | wc -l)
if [ "$n_before" = "$n_after" ] && ! ls "$P1"/board/.probe-* >/dev/null 2>&1; then
  ok "9 doctor pollutes nothing: no messages posted, no probe residue"
else bad "9 doctor probe hygiene" "msgs $n_before->$n_after"; fi

# ---------------------------------------------------------------------------
# join — worktree + register + doctor gate
# ---------------------------------------------------------------------------
P2="$TMPROOT/proj2"; mkdir -p "$P2"
"$BOARD" init "$P2" >/dev/null 2>&1
( cd "$P2" && git init -q -b main . \
  && git add -A && git -c user.email=t@t -c user.name=t commit -qm init ) 2>/dev/null

out=$(OB_HOME="$P2" "$JOIN" bob builder 2>&1); rc=$?
if [ $rc -eq 0 ] && [ -d "$TMPROOT/ob-bob" ] \
   && git -C "$P2" show-ref --verify --quiet refs/heads/agent/bob \
   && [ "$(cat "$TMPROOT/ob-bob/.ob-agent")" = bob ] \
   && grep -q "OB_HOME=$P2" "$TMPROOT/ob-bob/.openboard/local" \
   && grep -q 'role: builder' "$P2/board/agents/bob.md"; then
  ok "10 join provisions worktree+branch+identity+redirect, registers, doctor green"
else bad "10 join full provisioning" "rc=$rc: $out"; fi

out=$(OB_HOME="$P2" "$JOIN" bob builder 2>&1); rc=$?
if [ $rc -eq 0 ] && printf '%s' "$out" | grep -q 'already present, kept'; then
  ok "11 join re-run is idempotent (worktree kept, still green)"
else bad "11 join idempotency" "rc=$rc: $out"; fi

( cd "$TMPROOT/ob-bob" && env -u OB_HOME OB_AGENT=bob "$BOARD" post claim wt-msg -m "from worktree" >/dev/null 2>&1 )
if ls "$P2"/board/messages/*-bob-wt-msg.md >/dev/null 2>&1 \
   && ! ls "$TMPROOT/ob-bob"/board/messages/*-bob-wt-msg.md >/dev/null 2>&1; then
  ok "12 worktree redirect: post lands ONLY in the shared board"
else bad "12 worktree redirect isolation"; fi

out=$(OB_HOME="$P2" "$JOIN" carol tester --no-worktree 2>&1); rc=$?
if [ $rc -eq 0 ] && [ ! -d "$TMPROOT/ob-carol" ] && [ -f "$P2/board/agents/carol.md" ]; then
  ok "13 join --no-worktree registers without provisioning"
else bad "13 join --no-worktree" "rc=$rc: $out"; fi

# ---------------------------------------------------------------------------
# hook join emits brief-sourced context (single source, end to end)
# ---------------------------------------------------------------------------
h=$(printf '{}' | OB_HOME="$P1" OB_AGENT=alice bash "$HOOK" join 2>/dev/null)
if printf '%s' "$h" | python3 -c '
import sys,json; d=json.load(sys.stdin)["hookSpecificOutput"]
assert d["hookEventName"]=="SessionStart"
c=d["additionalContext"]
assert "agent \"alice\"" in c and "Work loop" in c and "OpenBoard digest" in c' 2>/dev/null; then
  ok "14 board-hook join context comes from brief (single source, e2e)"
else bad "14 hook join via brief" "$h"; fi

# ---------------------------------------------------------------------------
# OB_NO_FALLBACK: plugin installs must never fall back to the toolkit's own board
# ---------------------------------------------------------------------------
out=$(cd "$TMPROOT" && OB_NO_FALLBACK=1 "$BOARD" whoami 2>&1); rc=$?
h=$(cd "$TMPROOT" && printf '{}' | OB_NO_FALLBACK=1 OB_AGENT=ghost bash "$HOOK" join 2>/dev/null); hrc=$?
if [ $rc -eq 2 ] && printf '%s' "$out" | grep -q 'cannot locate' \
   && [ $hrc -eq 0 ] && [ -z "$h" ]; then
  ok "15 OB_NO_FALLBACK: CLI refuses (exit 2); hook stays silent (exit 0, no output)"
else bad "15 OB_NO_FALLBACK guard" "rc=$rc hrc=$hrc out=$out h=$h"; fi

echo "-----------------------------------------"
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
