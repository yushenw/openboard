#!/usr/bin/env bash
# board-view acceptance: read-only dashboard renders agents/tasks/activity. Temp board only.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BIN="$ROOT/bin/board"; VIEW="$ROOT/bin/board-view"
H=$(mktemp -d); export OB_HOME="$H" OB_BOARD="$H/board" BOARD_BIN="$BIN"
OB_AGENT=alice bash "$BIN" register --role coder >/dev/null
OB_AGENT=alice bash "$BIN" task new --title "demo task" --type code --id TASK-001-demo >/dev/null
OB_AGENT=alice bash "$BIN" post question hello -m "anyone around?" >/dev/null
out=$(bash "$VIEW" --once 2>&1)
# board-view must not write to the board (read-only)
before=$(find "$OB_BOARD" -type f | wc -l)
bash "$VIEW" --once >/dev/null 2>&1
after=$(find "$OB_BOARD" -type f | wc -l)

pass=0; fail=0
chk(){ if printf '%s' "$out" | grep -q "$1"; then echo "PASS  $2"; pass=$((pass+1)); else echo "FAIL  $2"; fail=$((fail+1)); fi; }
chk "AGENTS"          "1 agents section"
chk "alice"           "2 shows agent alice"
chk "TASKS"           "3 tasks section"
chk "TASK-001-demo"   "4 shows task"
chk "RECENT ACTIVITY" "5 activity section"
chk "hello"           "6 shows recent message"
if [ "$before" = "$after" ]; then echo "PASS  7 read-only (no board writes)"; pass=$((pass+1)); else echo "FAIL  7 read-only"; fail=$((fail+1)); fi
echo "-----------------------------------------"
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
