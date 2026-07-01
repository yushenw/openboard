#!/usr/bin/env bash
# Tier-2 acceptance tests: task lifecycle / digest / verify. Isolated temp board+home.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BIN="$ROOT/bin/board.sh"
pass=0; fail=0
ok(){ if eval "$2"; then echo "PASS  $1"; pass=$((pass+1)); else echo "FAIL  $1"; fail=$((fail+1)); fi; }
setup(){ H=$(mktemp -d); export OB_HOME="$H" OB_BOARD="$H/board"; mkdir -p "$H/verifiers"; }
run(){ local a=$1; shift; OB_AGENT="$a" bash "$BIN" "$@"; }

echo "== Tier-2 acceptance tests =="

# 1 task new: immutable file, id == filename stem
setup
id=$(run alice task new --title "Do X" --type code)
f="$OB_HOME/tasks/$id.md"
ok "1 task new -> immutable file, id==stem" '[ -f "$f" ] && grep -q "^id: $id$" "$f"'

# 2 list shows open
ok "2 task list shows fresh task open" 'run alice task list | grep -q "$id .*open"'

# 3 claim -> claimed:alice ; second claim by bob exits 5
run alice task claim "$id" -m mine >/dev/null
ok "3a list shows claimed:alice" 'run bob task list | grep -q "claimed:alice"'
run bob task claim "$id" -m mine2 >/dev/null 2>&1; ec=$?
ok "3b second claim exits 5" '[ "$ec" = 5 ]'

# 4 result + passing review -> done
rid=$(printf 'ev\n' | run alice result --task "$id" --branch agent/a --sha deadbee --evidence -)
rid=$(basename "$rid" .md)
run bob review "$rid" --score 9 --verdict pass >/dev/null
ok "4 result + passing review -> done" 'run alice task list | grep -q " done "'

# 5 close -> closed
run alice task close "$id" --reason "done enough" >/dev/null
ok "5 task close -> closed" 'run alice task list | grep -q "closed"'

# 6 nonexistent id -> exit 4 (show/claim/verify)
run alice task show NOPE  >/dev/null 2>&1; ec=$?; ok "6a show missing -> 4"  '[ "$ec" = 4 ]'
run alice task claim NOPE >/dev/null 2>&1; ec=$?; ok "6b claim missing -> 4" '[ "$ec" = 4 ]'
run alice verify --task NOPE >/dev/null 2>&1; ec=$?; ok "6c verify missing -> 4" '[ "$ec" = 4 ]'

# 7 digest --write produces file with Agents + Tasks sections
run alice digest --write >/dev/null
ok "7 digest --write has Agents+Tasks" '[ -f "$OB_BOARD/digest.md" ] && grep -qi "Agents" "$OB_BOARD/digest.md" && grep -qi "Tasks" "$OB_BOARD/digest.md"'

# 8 verify pass (exit 0 + evidence) and fail (non-zero)
setup
run alice task new --title vp --type code --id TASK-900-vp >/dev/null
printf '#!/usr/bin/env bash\necho evidence-ok\nexit 0\n' > "$OB_HOME/verifiers/TASK-900-vp.sh"; chmod +x "$OB_HOME/verifiers/TASK-900-vp.sh"
run alice verify --task TASK-900-vp > "$OB_HOME/vp.out" 2>&1; ec=$?
ok "8a verify pass exit0 + evidence" '[ "$ec" = 0 ] && grep -q evidence-ok "$OB_HOME/vp.out"'
run alice task new --title vf --type code --id TASK-901-vf >/dev/null
printf '#!/usr/bin/env bash\necho boom\nexit 3\n' > "$OB_HOME/verifiers/TASK-901-vf.sh"; chmod +x "$OB_HOME/verifiers/TASK-901-vf.sh"
run alice verify --task TASK-901-vf >/dev/null 2>&1; ec=$?
ok "8b verify fail -> non-zero" '[ "$ec" != 0 ]'

# 9 --json valid for task list / show / digest
ok "9a task list --json valid" 'run alice task list --json | python3 -c "import sys,json;json.load(sys.stdin)"'
ok "9b task show --json valid"  'run alice task show TASK-900-vp --json | python3 -c "import sys,json;json.load(sys.stdin)"'
ok "9c digest --json valid"     'run alice digest --json | python3 -c "import sys,json;json.load(sys.stdin)"'

echo "-----------------------------------------"
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
