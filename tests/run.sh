#!/usr/bin/env bash
# Acceptance tests for the Tier-1 board CLI (docs/board-cli-spec.md).
# Runs against a TEMP board so it NEVER touches the real shared board.
#
#   bin: $REPO/bin/board.sh        board CLI under test
#   board data: $OB_BOARD          a throwaway mktemp dir
#
# Prints a per-test PASS/FAIL line and a summary. Exit 0 iff all 9 pass.
set -uo pipefail   # NOT -e: we capture non-zero exit codes deliberately.

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
BOARD="$REPO/bin/board.sh"

TMPROOT=$(mktemp -d)
export OB_BOARD="$TMPROOT/board"
export OB_HOME="$TMPROOT"          # keep sync/anything off the real repo
unset OB_AGENT 2>/dev/null || true
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf 'PASS  %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf 'FAIL  %s\n    %s\n' "$1" "${2:-}"; }

# JSON validator: prefer python3, then jq, else crude bracket check.
json_valid() {
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$1" | python3 -c 'import sys,json; json.load(sys.stdin)' 2>/dev/null
  elif command -v jq >/dev/null 2>&1; then
    printf '%s' "$1" | jq -e . >/dev/null 2>&1
  else
    case "$1" in '['*']'|'{'*'}') return 0 ;; *) return 1 ;; esac
  fi
}
# Run a python snippet over JSON on stdin; exit status is the assertion.
jpy() { python3 -c "$1" 2>/dev/null; }

reset_board() { rm -rf "$OB_BOARD"; mkdir -p "$OB_BOARD"; }

# ---------------------------------------------------------------------------
echo "== board CLI acceptance tests =="
echo "OB_BOARD=$OB_BOARD"
echo

# ---- Test 1: empty OB_AGENT -> whoami exits 3 ------------------------------
reset_board
OB_AGENT= "$BOARD" whoami >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 3 ]; then ok "1 whoami with empty OB_AGENT exits 3"
else bad "1 whoami with empty OB_AGENT exits 3" "got exit $rc (want 3)"; fi

# ---- Test 2: register then who --json shows agent + role -------------------
reset_board
OB_AGENT=alice "$BOARD" register --role builder >/dev/null 2>&1
who=$(OB_AGENT=alice "$BOARD" who --json 2>/dev/null)
if json_valid "$who" && printf '%s' "$who" | \
   jpy 'import sys,json; d=json.load(sys.stdin); sys.exit(0 if any(a["name"]=="alice" and a["role"]=="builder" for a in d) else 1)'
then ok "2 register + who --json shows agent with role"
else bad "2 register + who --json shows agent with role" "who=$who"; fi

# ---- Test 3: post writes exactly one valid file, id == filename stem -------
reset_board
before=$(find "$OB_BOARD/messages" -name '*.md' 2>/dev/null | wc -l)
p=$(OB_AGENT=bob "$BOARD" post propose hello -m "hi there" 2>/dev/null)
after=$(find "$OB_BOARD/messages" -name '*.md' 2>/dev/null | wc -l)
delta=$((after - before))
idline=$(grep -m1 '^id: ' "$p" | sed 's/^id: //')
fstem=$(basename "$p" .md)
hasfm=1
for k in id author type time refs status; do grep -q "^$k: " "$p" || hasfm=0; done
if [ "$delta" -eq 1 ] && [ "$hasfm" -eq 1 ] && [ "$idline" = "$fstem" ]; then
  ok "3 post writes one valid file, id == filename stem"
else
  bad "3 post writes one valid file, id == filename stem" \
      "delta=$delta hasfm=$hasfm id=$idline stem=$fstem"
fi

# ---- Test 4: same-second posts by different agents never collide ----------
reset_board
SHIM="$TMPROOT/shim"; mkdir -p "$SHIM"
cat > "$SHIM/date" <<'EOS'
#!/bin/sh
printf '20260627T000000Z\n'
EOS
chmod +x "$SHIM/date"
pa=$(PATH="$SHIM:$PATH" OB_AGENT=alice "$BOARD" post propose race -m a 2>/dev/null)
pb=$(PATH="$SHIM:$PATH" OB_AGENT=bob   "$BOARD" post propose race -m b 2>/dev/null)
pc=$(PATH="$SHIM:$PATH" OB_AGENT=alice "$BOARD" post propose race -m a2 2>/dev/null)
if [ -f "$pa" ] && [ -f "$pb" ] && [ -f "$pc" ] \
   && [ "$pa" != "$pb" ] && [ "$pa" != "$pc" ] && [ "$pb" != "$pc" ]; then
  ok "4 same-second posts (diff agents + same agent) get distinct files"
else
  bad "4 same-second posts get distinct files" "pa=$pa pb=$pb pc=$pc"
fi

# ---- Test 5: new returns unseen then nothing on immediate re-call ----------
reset_board
OB_AGENT=zoe "$BOARD" post propose m1 -m one >/dev/null 2>&1
OB_AGENT=zoe "$BOARD" post propose m2 -m two >/dev/null 2>&1
n1=$(OB_AGENT=carol "$BOARD" new --json 2>/dev/null)
n2=$(OB_AGENT=carol "$BOARD" new --json 2>/dev/null)
c1=$(printf '%s' "$n1" | jpy 'import sys,json; print(len(json.load(sys.stdin)))')
if json_valid "$n1" && json_valid "$n2" && [ "${c1:-0}" -ge 2 ] && [ "$n2" = "[]" ]; then
  ok "5 new returns unseen msgs then nothing; cursor advances"
else
  bad "5 new returns unseen then nothing" "count1=$c1 n2=$n2"
fi

# ---- Test 6: read --type review filters; --author filters -----------------
reset_board
rid=$(OB_AGENT=dave "$BOARD" result --task feat --branch agent/dave --sha abc123 \
        --evidence - -m "done" <<<"all green" 2>/dev/null)
ridstem=$(basename "$rid" .md)
OB_AGENT=erin "$BOARD" review "$ridstem" --score 8 --verdict pass -m lgtm >/dev/null 2>&1
OB_AGENT=dave "$BOARD" post propose idea -m "let us" >/dev/null 2>&1
rev=$(OB_AGENT=dave "$BOARD" read --type review --json 2>/dev/null)
aut=$(OB_AGENT=dave "$BOARD" read --author erin --json 2>/dev/null)
rev_ok=$(printf '%s' "$rev" | jpy 'import sys,json; d=json.load(sys.stdin); print(1 if d and all(x["type"]=="review" for x in d) else 0)')
aut_ok=$(printf '%s' "$aut" | jpy 'import sys,json; d=json.load(sys.stdin); print(1 if d and all(x["author"]=="erin" for x in d) else 0)')
if [ "${rev_ok:-0}" = 1 ] && [ "${aut_ok:-0}" = 1 ]; then
  ok "6 read --type review and --author filter correctly"
else
  bad "6 read filters" "rev_ok=$rev_ok aut_ok=$aut_ok"
fi

# ---- Test 7: claim foo by A, then by B exits 5 ----------------------------
reset_board
OB_AGENT=amy "$BOARD" claim foo -m "mine" >/dev/null 2>&1; r1=$?
OB_AGENT=ben "$BOARD" claim foo -m "no mine" >/dev/null 2>&1; r2=$?
if [ "$r1" -eq 0 ] && [ "$r2" -eq 5 ]; then
  ok "7 second claim of same slug by other agent exits 5"
else
  bad "7 claim conflict exits 5" "r1=$r1 r2=$r2 (want 0 then 5)"
fi

# ---- Test 8: result --evidence - embeds stdin; bad review rejected --------
reset_board
MARK="EVIDENCE_MARKER_$RANDOM"
rp=$(OB_AGENT=fin "$BOARD" result --task ship --branch agent/fin --sha deadbeef \
       --evidence - <<<"$MARK" 2>/dev/null)
rpstem=$(basename "$rp" .md)
embedded=0; grep -q "$MARK" "$rp" 2>/dev/null && embedded=1
OB_AGENT=gus "$BOARD" review "$rpstem" --score 6 --verdict pass >/dev/null 2>&1; rrc=$?
if [ "$embedded" -eq 1 ] && [ "$rrc" -ne 0 ]; then
  ok "8 result embeds stdin evidence; review score 6 + pass rejected (exit $rrc)"
else
  bad "8 result evidence / review rejection" "embedded=$embedded review_rc=$rrc"
fi

# ---- Test 9: --json of who/read/new/post is valid JSON ---------------------
reset_board
OB_AGENT=ivy "$BOARD" register --role builder >/dev/null 2>&1
jp=$(OB_AGENT=ivy "$BOARD" post propose jx -m "body \"quoted\" and	tab" --json 2>/dev/null)
jw=$(OB_AGENT=ivy "$BOARD" who --json 2>/dev/null)
jr=$(OB_AGENT=ivy "$BOARD" read --json 2>/dev/null)
jn=$(OB_AGENT=ivy "$BOARD" new --json 2>/dev/null)
allok=1
for v in "$jp" "$jw" "$jr" "$jn"; do json_valid "$v" || allok=0; done
if [ "$allok" -eq 1 ]; then
  ok "9 --json of who/read/new/post is valid parseable JSON"
else
  bad "9 --json valid" "post=$jp who=$jw read=$jr new=$jn"
fi

# --- 10: cat prints one message in full (human + valid JSON); missing id exits 4
reset_board
cid=$(OB_AGENT=ivy "$BOARD" post propose catme -m "cat target body" --json 2>/dev/null \
      | jpy 'import sys,json; print(json.load(sys.stdin)["id"])')
h=$("$BOARD" cat "$cid" 2>/dev/null)
j=$("$BOARD" cat "$cid" --json 2>/dev/null)
"$BOARD" cat no-such-id >/dev/null 2>&1; rc4=$?
if printf '%s' "$h" | grep -q "cat target body" && json_valid "$j" && [ "$rc4" -eq 4 ]; then
  ok "10 cat shows full message; unknown id exits 4"
else
  bad "10 cat" "rc4=$rc4 h=$h"
fi

# --- 11: search matches body case-insensitively; no match exits 0 with notice
OB_AGENT=ivy "$BOARD" post propose s1 -m "UNIQUE-needle here" >/dev/null 2>&1
OB_AGENT=ivy "$BOARD" post propose s2 -m "nothing relevant" >/dev/null 2>&1
sh=$("$BOARD" search "unique-NEEDLE" 2>/dev/null)
sj=$("$BOARD" search "unique-needle" --json 2>/dev/null)
sn=$("$BOARD" search "zzz-no-match-zzz" 2>/dev/null); snrc=$?
if printf '%s' "$sh" | grep -q "s1" && json_valid "$sj" \
   && printf '%s' "$sj" | jpy 'import sys,json; d=json.load(sys.stdin); assert d["total"]==1' \
   && [ "$snrc" -eq 0 ] && printf '%s' "$sn" | grep -q "no matches"; then
  ok "11 search case-insensitive ERE + --json + clean no-match"
else
  bad "11 search" "rc=$snrc sh=$sh sj=$sj"
fi

# --- 12: version works, even outside any board root
v=$(cd / && "$BOARD" version 2>/dev/null)
if printf '%s' "$v" | grep -qE '^openboard [0-9]+\.[0-9]+\.[0-9]+'; then
  ok "12 version prints semver, works outside a root"
else
  bad "12 version" "$v"
fi

# ---------------------------------------------------------------------------
echo
echo "-----------------------------------------"
printf 'RESULT: %d/%d passed\n' "$PASS" $((PASS+FAIL))
[ "$FAIL" -eq 0 ]
