#!/usr/bin/env bash
# Acceptance tests for the git transport (decision 0015): multi-host boards over a git remote.
# Uses a local bare repo as `origin` (file://-style) — no network required.
#
#   node A / node B = two independent checkouts of the same board repo.
#   Every board CLI command pulls before dispatch and pushes writes after.
#
# Prints a per-test PASS/FAIL line and a summary. Exit 0 iff all pass.
set -uo pipefail   # NOT -e: we capture non-zero exit codes deliberately.

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
BOARD="$REPO/bin/board"

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT
unset OB_HOME OB_BOARD OB_AGENT 2>/dev/null || true

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf 'PASS  %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf 'FAIL  %s\n    %s\n' "$1" "${2:-}"; }
G() { git -c user.name=t -c user.email=t@t "$@"; }   # git with a throwaway identity

# ---------------------------------------------------------------------------
# setup: bare origin + node A (init'd, pushed) + node B (cloned)
# ---------------------------------------------------------------------------
BARE="$TMPROOT/origin.git"; git init -q --bare -b main "$BARE"
A="$TMPROOT/nodeA"; mkdir -p "$A"
"$BOARD" init --transport git "$A" >/dev/null 2>&1
( cd "$A" && git init -q -b main . && G add -A && G commit -qm "board: genesis" \
  && git remote add origin "$BARE" && git push -qu origin main ) 2>/dev/null
B="$TMPROOT/nodeB"; git clone -q "$BARE" "$B" 2>/dev/null

# --- 1: init --transport git is recorded; .gitignore keeps generated files per-node
if grep -q 'OB_BOARD_TRANSPORT=git' "$A/.openboard/project" \
   && grep -q 'board/digest.md' "$A/.gitignore" && grep -q 'board/inbox/' "$A/.gitignore"; then
  ok "1 init --transport git: project config + per-node .gitignore"
else bad "1 init --transport git"; fi

# --- 2: a write on A auto-commits and auto-pushes to origin
( cd "$A" && OB_AGENT=alice "$BOARD" post propose hello -m "first cross-host message" >/dev/null 2>&1 )
if git -C "$BARE" log --oneline main 2>/dev/null | head -1 | grep -q 'board: alice'; then
  ok "2 write on node A auto-commits + pushes (author=agent)"
else bad "2 auto-push" "$(git -C "$BARE" log --oneline main 2>/dev/null | head -2)"; fi

# --- 3: node B sees A's message WITHOUT any manual git command (pre-dispatch pull)
out=$(cd "$B" && OB_AGENT=bob "$BOARD" read -n 5 2>/dev/null)
if printf '%s' "$out" | grep -q 'first cross-host message'; then
  ok "3 node B reads A's message via automatic pull"
else bad "3 auto-pull on read" "$out"; fi

# --- 4: reverse direction — B posts, A sees it
( cd "$B" && OB_AGENT=bob "$BOARD" post answer reply -m "reply from the other host" >/dev/null 2>&1 )
out=$(cd "$A" && OB_AGENT=alice "$BOARD" read -n 5 2>/dev/null)
if printf '%s' "$out" | grep -q 'reply from the other host'; then
  ok "4 B -> origin -> A round trip"
else bad "4 reverse direction" "$out"; fi

# --- 5: ref race — local commits ahead + remote ahead resolves via rebase+retry
( cd "$B" && OB_AGENT=bob "$BOARD" post propose race-remote -m "remote moved first" >/dev/null 2>&1 )
( cd "$A" \
  && printf 'x\n' > tasks/local-ahead.md && G add tasks/local-ahead.md \
  && G commit -qm "board: manual local commit" \
  && OB_AGENT=alice "$BOARD" post propose race-local -m "local was ahead" >/dev/null 2>&1 )
in_bare=$(git -C "$BARE" ls-tree -r --name-only main 2>/dev/null)
if printf '%s' "$in_bare" | grep -q 'race-remote' && printf '%s' "$in_bare" | grep -q 'race-local' \
   && printf '%s' "$in_bare" | grep -q 'tasks/local-ahead.md'; then
  ok "5 ref race: rebase + retry lands both sides' commits"
else bad "5 ref race" "$in_bare"; fi

# --- 6: offline tolerance — write succeeds locally (exit 0 + warning), syncs when back online
( cd "$A" && git remote set-url origin "$TMPROOT/gone.git" )
w=$(cd "$A" && OB_AGENT=alice "$BOARD" post propose offline-msg -m "written while offline" 2>&1 >/dev/null); wrc=$?
( cd "$A" && git remote set-url origin "$BARE" )
( cd "$A" && OB_AGENT=alice "$BOARD" post propose online-again -m "back online" >/dev/null 2>&1 )
in_bare=$(git -C "$BARE" ls-tree -r --name-only main 2>/dev/null)
if [ "$wrc" -eq 0 ] && printf '%s' "$w" | grep -q 'push failed' \
   && printf '%s' "$in_bare" | grep -q 'offline-msg' && printf '%s' "$in_bare" | grep -q 'online-again'; then
  ok "6 offline: exit 0 + warning; backlog syncs on next write"
else bad "6 offline tolerance" "rc=$wrc w=$w"; fi

# --- 7: generated files stay per-node — digest --write pushes nothing
before=$(git -C "$BARE" rev-parse main 2>/dev/null)
( cd "$A" && OB_AGENT=alice "$BOARD" digest --write >/dev/null 2>&1 )
after=$(git -C "$BARE" rev-parse main 2>/dev/null)
clean=$(cd "$A" && git status --porcelain 2>/dev/null | grep -v '^??' || true)
if [ "$before" = "$after" ] && [ -z "$clean" ]; then
  ok "7 digest --write is node-local: no commit, no push"
else bad "7 generated files leak" "before=$before after=$after dirty=$clean"; fi

# --- 8: doctor on a git-transport node is green; no-upstream case FAILs with a hint
d1=$(cd "$B" && OB_AGENT=bob "$BOARD" doctor 2>&1); rc1=$?
C="$TMPROOT/nodeC"; mkdir -p "$C"
"$BOARD" init --transport git "$C" >/dev/null 2>&1
( cd "$C" && git init -q -b main . && G add -A && G commit -qm genesis ) 2>/dev/null
d2=$(cd "$C" && OB_AGENT=carol "$BOARD" doctor 2>&1); rc2=$?
if [ "$rc1" -eq 0 ] && printf '%s' "$d1" | grep -q 'origin reachable' \
   && [ "$rc2" -ne 0 ] && printf '%s' "$d2" | grep -q 'no upstream'; then
  ok "8 doctor: green with upstream; FAIL + hint without one"
else bad "8 doctor transport checks" "rc1=$rc1 rc2=$rc2 d2=$(printf '%s' "$d2" | grep transport)"; fi

echo "-----------------------------------------"
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
