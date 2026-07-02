#!/usr/bin/env bash
# board-hook acceptance: auto-join + per-turn auto-sync emit valid Claude-Code hook JSON. Temp board.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
HOOK="$ROOT/bin/board-hook"
pass=0; fail=0
ok(){ if eval "$2"; then echo "PASS  $1"; pass=$((pass+1)); else echo "FAIL  $1"; fail=$((fail+1)); fi; }
H=$(mktemp -d); export OB_HOME="$ROOT" OB_BOARD="$H/board" OB_AGENT=tester

echo "== board-hook acceptance =="
j=$(printf '{}' | bash "$HOOK" join 2>/dev/null)
ok "1 join emits valid SessionStart JSON" 'printf "%s" "$j" | python3 -c "import sys,json;d=json.load(sys.stdin);assert d[\"hookSpecificOutput\"][\"hookEventName\"]==\"SessionStart\""'
ok "2 join auto-registered the agent"     '[ -f "$OB_BOARD/agents/tester.md" ] && grep -q "^role:" "$OB_BOARD/agents/tester.md"'

# a teammate posts; next sync must surface it
OB_AGENT=mate bash "$ROOT/bin/board" post question hi -m "anyone around?" >/dev/null
s=$(printf '{}' | bash "$HOOK" sync 2>/dev/null)
ok "3 sync surfaces new item (compact) as UserPromptSubmit JSON" 'printf "%s" "$s" | python3 -c "import sys,json;d=json.load(sys.stdin);c=d[\"hookSpecificOutput\"][\"additionalContext\"];assert d[\"hookSpecificOutput\"][\"hookEventName\"]==\"UserPromptSubmit\";assert \"mate\" in c and \"question\" in c"'

# nothing new -> sync emits nothing (no context injected)
s2=$(printf '{}' | bash "$HOOK" sync 2>/dev/null)
ok "4 sync with nothing new emits nothing" '[ -z "$s2" ]'

# beat updates heartbeat to idle, never fails
bash "$HOOK" beat >/dev/null 2>&1; ok "5 beat exits 0" '[ "$?" = 0 ]'
ok "6 beat set status idle" 'grep -q "idle" "$OB_BOARD/agents/tester.md"'

# agent-id derived from ob-<name> dir when OB_AGENT unset
d="$H/ob-zeta"; mkdir -p "$d"
z=$(cd "$d" && env -u OB_AGENT OB_HOME="$ROOT" OB_BOARD="$OB_BOARD" bash "$HOOK" join 2>/dev/null; true)
ok "7 derives agent from ob-<name> dir" '[ -f "$OB_BOARD/agents/zeta.md" ]'

echo "-----------------------------------------"
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
