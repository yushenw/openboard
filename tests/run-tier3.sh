#!/usr/bin/env bash
# Tier-3 acceptance: objective contract + competing-results rank/promote. Temp board+home only.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BIN="$ROOT/bin/board.sh"
pass=0; fail=0
ok(){ if eval "$2"; then echo "PASS  $1"; pass=$((pass+1)); else echo "FAIL  $1"; fail=$((fail+1)); fi; }
setup(){ H=$(mktemp -d); export OB_HOME="$H" OB_BOARD="$H/board"; mkdir -p "$H/verifiers"; }
run(){ local a=$1; shift; OB_AGENT="$a" bash "$BIN" "$@"; }

echo "== Tier-3 acceptance tests =="
setup
id=$(run alice task new --title "speed" --type code --id TASK-777-speed --metric tps --metric-dir max)

# 1 objective recorded on task
ok "1 task new records metric/metric_dir" 'grep -q "^metric: tps$" "$OB_HOME/tasks/$id.md" && grep -q "^metric_dir: max$" "$OB_HOME/tasks/$id.md"'

# 2 structured verifier -> verify --json surfaces metrics + pass
cat > "$OB_HOME/verifiers/$id.sh" <<'V'
#!/usr/bin/env bash
echo "running bench..."
echo 'METRICS: {"tps":120,"quality":0.63}'
exit 0
V
chmod +x "$OB_HOME/verifiers/$id.sh"
run alice verify --task "$id" --json > "$OB_HOME/v.json" 2>&1
ok "2 verify --json has metrics+pass" 'python3 -c "import json,sys;d=json.load(open(sys.argv[1]));assert d[\"pass\"] is True and d[\"metrics\"][\"tps\"]==120" "$OB_HOME/v.json"'

# 3 result --metric recorded; task results shows it + verdict
r1=$(printf 'ev1\n' | run alice result --task "$id" --branch agent/a --sha aaa --evidence - --metric 120); r1=$(basename "$r1" .md)
r2=$(printf 'ev2\n' | run bob   result --task "$id" --branch agent/b --sha bbb --evidence - --metric 150); r2=$(basename "$r2" .md)
run carol review "$r1" --score 8 --verdict pass >/dev/null
run carol review "$r2" --score 9 --verdict pass >/dev/null
ok "3 task results lists both with metric" 'run alice task results "$id" | grep -q "$r1" && run alice task results "$id" | grep "$r2" | grep -q 150'

# 4 rank orders by max metric -> r2 (150) is #1
first=$(run alice task rank "$id" | awk '/#1/{print; exit}')
ok "4 rank #1 = r2 (150)" '[[ "$first" == *150* && "$first" == *"'"$r2"'"* ]]'

# 5 higher-metric result with NO passing review is excluded
r3=$(printf 'ev3\n' | run dave result --task "$id" --branch agent/c --sha ccc --evidence - --metric 999); r3=$(basename "$r3" .md)
ok "5 rank excludes unreviewed 999" '! run alice task rank "$id" | grep -q "$r3"'

# 6 promote -> status promoted:<rid>
run alice task promote "$id" "$r2" -m "fastest, quality ok" >/dev/null
ok "6a task list shows promoted:r2" 'run alice task list | grep -q "promoted:$r2"'
ok "6b task_status precedence promoted" 'run alice task list | grep "$id" | grep -q promoted'

# 7 promote error paths
run alice task promote "$id" NOPE >/dev/null 2>&1; ec=$?; ok "7a promote missing result -> 4" '[ "$ec" = 4 ]'
oid=$(run alice task new --title other --type code --id TASK-778-other)
ro=$(printf 'e\n' | run alice result --task "$oid" --branch agent/x --sha xxx --evidence - --metric 5); ro=$(basename "$ro" .md)
run alice task promote "$id" "$ro" >/dev/null 2>&1; ec=$?; ok "7b promote result-not-for-task -> 2" '[ "$ec" = 2 ]'

# 8 json valid
ok "8a task results --json valid" 'run alice task results "$id" --json | python3 -c "import sys,json;json.load(sys.stdin)"'
ok "8b task rank --json valid"    'run alice task rank "$id" --json | python3 -c "import sys,json;json.load(sys.stdin)"'

echo "-----------------------------------------"
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
