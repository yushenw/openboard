#!/usr/bin/env bash
# Private-holdout acceptance: promote is gated by re-running a private verifier. Temp board+home only.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BIN="$ROOT/bin/board.sh"
pass=0; fail=0
ok(){ if eval "$2"; then echo "PASS  $1"; pass=$((pass+1)); else echo "FAIL  $1"; fail=$((fail+1)); fi; }
setup(){ H=$(mktemp -d); export OB_HOME="$H" OB_BOARD="$H/board"; mkdir -p "$H/verifiers"; }
run(){ local a=$1; shift; OB_AGENT="$a" bash "$BIN" "$@"; }
# mk <task-id> <claimed-metric> -> makes task + a reviewed candidate result, echoes its result-id
mk(){
  run alice task new --title t --type code --id "$1" --metric tps --metric-dir max >/dev/null
  local rr; rr=$(printf 'ev\n' | run bob result --task "$1" --branch agent/b --sha bbb --evidence - --metric "$2")
  rr=$(basename "$rr" .md)
  run carol review "$rr" --score 9 --verdict pass >/dev/null
  echo "$rr"
}
# hold <task-id> <holdout-tps> <exit>
hold(){ printf '#!/usr/bin/env bash\necho "METRICS: {\\"tps\\":%s}"\nexit %s\n' "$2" "$3" > "$OB_HOME/verifiers/$1.holdout.sh"; chmod +x "$OB_HOME/verifiers/$1.holdout.sh"; }

echo "== private-holdout acceptance =="
setup

# A: no holdout defined -> verdict no-holdout, promote allowed
ra=$(mk TASK-HA 150)
ok "A1 holdout verdict = no-holdout"      'run alice task holdout TASK-HA "'"$ra"'" | grep -q no-holdout'
run alice task promote TASK-HA "$ra" >/dev/null 2>&1; ec=$?
ok "A2 promote allowed without holdout"   '[ "$ec" = 0 ]'
ok "A3 decision records holdout: none"    'run alice task list | grep -q "promoted:'"$ra"'"'

# B: holdout within tolerance -> confirmed, promote succeeds
rb=$(mk TASK-HB 150); hold TASK-HB 149 0
ok "B1 holdout verdict = confirmed"       'run alice task holdout TASK-HB "'"$rb"'" --tolerance 0.05 | grep -q confirmed'
run alice task promote TASK-HB "$rb" --tolerance 0.05 >/dev/null 2>&1; ec=$?
ok "B2 promote succeeds when confirmed"    '[ "$ec" = 0 ] && run alice task list | grep TASK-HB | grep -q promoted'

# C: holdout diverges (claim 150 vs holdout 100) -> refused; --force overrides
rc=$(mk TASK-HC 150); hold TASK-HC 100 0
ok "C1 holdout verdict = diverged"        'run alice task holdout TASK-HC "'"$rc"'" | grep -q diverged'
run alice task promote TASK-HC "$rc" >/dev/null 2>&1; ec=$?
ok "C2 promote refused on divergence -> 5" '[ "$ec" = 5 ]'
run alice task promote TASK-HC "$rc" --force >/dev/null 2>&1; ec=$?
ok "C3 --force overrides divergence"       '[ "$ec" = 0 ]'

# D: holdout guardrail-fail (exit != 0) -> refused
rd=$(mk TASK-HD 150); hold TASK-HD 150 1
ok "D1 holdout verdict = guardrail-fail"  'run alice task holdout TASK-HD "'"$rd"'" | grep -q guardrail-fail'
run alice task promote TASK-HD "$rd" >/dev/null 2>&1; ec=$?
ok "D2 promote refused on guardrail-fail -> 5" '[ "$ec" = 5 ]'

echo "-----------------------------------------"
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
