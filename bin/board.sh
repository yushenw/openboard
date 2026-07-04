#!/usr/bin/env bash
# openboard — Tier-1 file-based coordination board CLI for heterogeneous AI agents.
# Implements docs/board-cli-spec.md (AUTHORITATIVE). Pure bash; deps = coreutils + git only.
#
# Usage: OB_AGENT=<name> bin/board.sh <command> [args]
# Exit codes: 0 ok · 2 usage · 3 missing identity · 4 not-found · 5 conflict.
set -euo pipefail
export LC_ALL=C   # deterministic byte-order sorting + slugify ranges

# ---------------------------------------------------------------------------
# Environment / layout
# ---------------------------------------------------------------------------
# Resolve OB_HOME from env > `.openboard/` marker > this script's location (see bin/ob-common.sh),
# replacing the old hard-coded path so the toolkit runs from any checkout. Commands that must work
# OUTSIDE any root (init/help/version) skip resolution.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ob-common.sh"
case "${1:-help}" in
  init|help|-h|--help|version|--version) ;;
  *) ob_resolve_home "${BASH_SOURCE[0]}" || {
       printf 'board: cannot locate OpenBoard root (set OB_HOME, or run `board init` here)\n' >&2; exit 2; } ;;
esac
OB_HOME="${OB_HOME:-$(ob_script_home "${BASH_SOURCE[0]}")}"   # init/help/version: fall back to install dir
OB_BOARD="${OB_BOARD:-$OB_HOME/board}"
OB_AGENT="${OB_AGENT-}"                 # NO default: empty means "missing identity"

LOG="$OB_BOARD/messages"
AGENTS="$OB_BOARD/agents"
DECISIONS="$OB_BOARD/decisions"
TASKS="$OB_HOME/tasks"               # immutable task specs (shared, like board/)
VERIFIERS="$OB_HOME/verifiers"       # executable per-task verifier scripts
DIGEST="$OB_BOARD/digest.md"

mkdir -p "$LOG" "$AGENTS" "$DECISIONS" "$TASKS"

VALID_TYPES="propose question answer result review claim decision"
VALID_TASK_TYPES="code research build analysis other"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
ts()      { date -u +%Y%m%dT%H%M%SZ; }
die()     { printf 'board: %s\n' "$2" >&2; exit "$1"; }
slugify() { printf '%s' "$1" | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9-' \
            | sed -E 's/-+/-/g; s/^-+//; s/-+$//'; }

need_identity() { [ -n "$OB_AGENT" ] || die 3 "OB_AGENT unset (missing identity)"; }

valid_type() {
  local t=$1 v
  for v in $VALID_TYPES; do [ "$t" = "$v" ] && return 0; done
  return 1
}

# atomic_write <target>   (content on stdin) — temp file in same dir + rename.
atomic_write() {
  local target=$1 dir tmp
  dir=$(dirname "$target")
  tmp=$(mktemp "$dir/.tmp.XXXXXX")
  cat > "$tmp"
  mv -f "$tmp" "$target"
}

# JSON-escape a string argument (no surrounding quotes).
json_escape() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

# Convert a frontmatter refs VALUE ("[]" or "[a, b]") to a JSON array.
refs_to_json() {
  local r=$1
  r=${r#[}; r=${r%]}
  r=$(printf '%s' "$r" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
  if [ -z "$r" ]; then printf '[]'; return; fi
  local out="[" first=1 tok oldifs=$IFS
  IFS=','
  for tok in $r; do
    tok=$(printf '%s' "$tok" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
    [ $first -eq 1 ] || out+=","
    out+="\"$(json_escape "$tok")\""
    first=0
  done
  IFS=$oldifs
  out+="]"
  printf '%s' "$out"
}

# Compute a unique record id/path for the current agent. Sets REC_ID, REC_PATH.
# Caller sets TNOW so id-time and frontmatter-time agree; suffix on collision.
new_record_path() {
  local slug=$1 id f n=1
  id="$TNOW-$OB_AGENT-$slug"; f="$LOG/$id.md"
  while [ -e "$f" ]; do n=$((n+1)); id="$TNOW-$OB_AGENT-$slug-$n"; f="$LOG/$id.md"; done
  REC_ID=$id; REC_PATH=$f
}

# Parse a message file into m_* globals.
parse_msg() {
  local f=$1 line state=0 key val
  m_id= m_author= m_type= m_time= m_status= m_refs="[]" m_body=
  m_slug= m_branch= m_sha= m_task= m_result= m_score= m_verdict= m_winner= m_mval=
  local body=()
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$state" = 0 ]; then
      [ "$line" = "---" ] && state=1
      continue
    elif [ "$state" = 1 ]; then
      if [ "$line" = "---" ]; then state=2; continue; fi
      key=${line%%:*}; val=${line#*:}; val=${val# }
      case "$key" in
        id) m_id=$val ;; author) m_author=$val ;; type) m_type=$val ;;
        time) m_time=$val ;; status) m_status=$val ;; refs) m_refs=$val ;;
        slug) m_slug=$val ;; branch) m_branch=$val ;; sha) m_sha=$val ;;
        task) m_task=$val ;; result) m_result=$val ;; score) m_score=$val ;;
        verdict) m_verdict=$val ;; winner) m_winner=$val ;; metric_value) m_mval=$val ;;
      esac
    else
      body+=("$line")
    fi
  done < "$f"
  if [ ${#body[@]} -gt 0 ]; then m_body=$(printf '%s\n' "${body[@]}"); fi
}

# Emit current m_* as one JSON object.
msg_json() {
  printf '{"id":"%s","author":"%s","type":"%s","time":"%s","refs":%s,"status":"%s","body":"%s"}' \
    "$(json_escape "$m_id")" "$(json_escape "$m_author")" "$(json_escape "$m_type")" \
    "$(json_escape "$m_time")" "$(refs_to_json "$m_refs")" "$(json_escape "$m_status")" \
    "$(json_escape "$m_body")"
}

# Human block for current m_*.
msg_human() {
  printf '## %s\n' "$m_id"
  printf 'type: %s  author: %s  time: %s  status: %s  refs: %s\n' \
    "$m_type" "$m_author" "$m_time" "$m_status" "$m_refs"
  [ -n "$m_body" ] && printf '%s\n' "$m_body"
  printf '\n'
}

# Print all message files, one path per line, sorted ascending (chronological).
all_messages() {
  shopt -s nullglob
  local arr=( "$LOG"/*.md )
  shopt -u nullglob
  local f
  for f in "${arr[@]}"; do printf '%s\n' "$f"; done
}

stem() { local b; b=$(basename "$1"); printf '%s' "${b%.md}"; }

# ---------------------------------------------------------------------------
# Tier-2: task lifecycle / digest / verify
#   Principle: task FILES are immutable specs; STATUS is COMPUTED from the log.
# ---------------------------------------------------------------------------
task_file()   { printf '%s/%s.md' "$TASKS" "$1"; }
task_exists() { [ -f "$(task_file "$1")" ]; }
valid_task_type() { local t=$1 v; for v in $VALID_TASK_TYPES; do [ "$t" = "$v" ] && return 0; done; return 1; }

# parse a task spec file into t_* globals
parse_task() {
  local f=$1 line state=0 key val
  t_id= t_title= t_type= t_by= t_time= t_verifier= t_hint= t_metric= t_metric_dir=
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$state" = 0 ]; then [ "$line" = "---" ] && state=1; continue; fi
    [ "$line" = "---" ] && break
    key=${line%%:*}; val=${line#*:}; val=${val# }
    case "$key" in
      id) t_id=$val ;; title) t_title=$val ;; type) t_type=$val ;;
      created_by) t_by=$val ;; time) t_time=$val ;; verifier) t_verifier=$val ;;
      status_hint) t_hint=$val ;; metric) t_metric=$val ;; metric_dir) t_metric_dir=$val ;;
    esac
  done < "$f"
}

# authoritative status of a task id -> open | claimed:<who> | done | closed
task_status() {
  local tid; tid=$(slugify "$1")
  local f claimer="" closed="" done_flag="" winner=""
  local -a result_ids=()
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    parse_msg "$f"
    case "$m_type" in
      claim)    [ "$(slugify "$m_slug")" = "$tid" ] && [ "$m_status" = "open" ] && claimer=$m_author ;;
      result)   [ "$(slugify "$m_task")" = "$tid" ] && result_ids+=("$m_id") ;;
      decision) if [ "$(slugify "$m_task")" = "$tid" ]; then closed=1; [ -n "$m_winner" ] && winner=$m_winner; fi ;;
    esac
  done < <(all_messages)
  if [ ${#result_ids[@]} -gt 0 ]; then
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      parse_msg "$f"
      [ "$m_type" = "review" ] && [ "$m_verdict" = "pass" ] || continue
      local rid
      for rid in "${result_ids[@]}"; do [ "$m_result" = "$rid" ] && done_flag=1; done
    done < <(all_messages)
  fi
  if   [ -n "$winner" ];    then printf 'promoted:%s' "$winner"
  elif [ -n "$closed" ];    then printf 'closed'
  elif [ -n "$done_flag" ]; then printf 'done'
  elif [ -n "$claimer" ];   then printf 'claimed:%s' "$claimer"
  else printf 'open'; fi
}

cmd_task() {
  local sub=${1:-}; shift || true
  case "$sub" in
    new) task_new "$@" ;; list) task_list "$@" ;; show) task_show "$@" ;;
    claim) task_claim "$@" ;; close) task_close "$@" ;;
    results) task_results "$@" ;; rank) task_rank "$@" ;; promote) task_promote "$@" ;;
    holdout) task_holdout "$@" ;;
    *) die 2 "task: unknown subcommand '$sub' (want new|list|show|claim|close|results|rank|promote|holdout)" ;;
  esac
}

task_new() {
  need_identity
  local title="" ttype="" verifier="none" acc="" id="" json=0 metric="" mdir="max"
  while [ $# -gt 0 ]; do
    case "$1" in
      --title)      title=${2:?}; shift 2 ;;
      --type)       ttype=${2:?}; shift 2 ;;
      --verifier)   verifier=${2:?}; shift 2 ;;
      --acceptance) acc=${2:?}; shift 2 ;;
      --id)         id=${2:?}; shift 2 ;;
      --metric)     metric=${2:?}; shift 2 ;;
      --metric-dir) mdir=${2:?}; shift 2 ;;
      --json)       json=1; shift ;;
      *) die 2 "task new: unknown arg '$1'" ;;
    esac
  done
  [ -n "$title" ] || die 2 "task new: --title required"
  [ -n "$ttype" ] || die 2 "task new: --type required"
  valid_task_type "$ttype" || die 2 "task new: invalid type '$ttype' (want: $VALID_TASK_TYPES)"
  local body=""
  if [ "$acc" = "-" ]; then body=$(cat)
  elif [ -n "$acc" ] && [ -f "$acc" ]; then body=$(cat "$acc")
  elif [ -n "$acc" ]; then die 2 "task new: acceptance file not found '$acc'"; fi
  if [ -z "$id" ]; then
    shopt -s nullglob; local existing=( "$TASKS"/*.md ); shopt -u nullglob
    local n=$(( ${#existing[@]} + 1 ))
    id=$(printf 'TASK-%03d-%s' "$n" "$(slugify "$title")")
  fi
  local f; f=$(task_file "$id")
  [ -e "$f" ] && die 2 "task new: '$id' already exists (tasks are immutable)"
  {
    printf -- '---\n'
    printf 'id: %s\ntitle: %s\ntype: %s\ncreated_by: %s\ntime: %s\nverifier: %s\nstatus_hint: open\n' \
      "$id" "$title" "$ttype" "$OB_AGENT" "$(ts)" "$verifier"
    [ -n "$metric" ] && printf 'metric: %s\nmetric_dir: %s\n' "$metric" "$mdir"
    printf -- '---\n'
    printf '%s\n' "$body"
  } | atomic_write "$f"
  if [ $json -eq 1 ]; then
    printf '{"id":"%s","path":"%s"}\n' "$(json_escape "$id")" "$(json_escape "$f")"
  else printf '%s\n' "$id"; fi
}

task_list() {
  local fstatus="" json=0
  while [ $# -gt 0 ]; do case "$1" in
    --status) fstatus=${2:?}; shift 2 ;; --json) json=1; shift ;;
    *) die 2 "task list: unknown arg '$1'" ;; esac; done
  shopt -s nullglob; local files=( "$TASKS"/*.md ); shopt -u nullglob
  local f st
  if [ $json -eq 1 ]; then
    local out="[" first=1
    for f in "${files[@]}"; do
      parse_task "$f"; st=$(task_status "$t_id")
      [ -n "$fstatus" ] && [ "${st%%:*}" != "$fstatus" ] && continue
      [ $first -eq 1 ] || out+=","
      out+=$(printf '{"id":"%s","type":"%s","status":"%s","title":"%s"}' \
        "$(json_escape "$t_id")" "$(json_escape "$t_type")" "$(json_escape "$st")" "$(json_escape "$t_title")")
      first=0
    done
    out+="]"; printf '%s\n' "$out"
  else
    [ ${#files[@]} -eq 0 ] && { printf '(no tasks)\n'; return 0; }
    for f in "${files[@]}"; do
      parse_task "$f"; st=$(task_status "$t_id")
      [ -n "$fstatus" ] && [ "${st%%:*}" != "$fstatus" ] && continue
      printf '%-26s %-9s %-16s %s\n' "$t_id" "$t_type" "$st" "$t_title"
    done
  fi
}

task_show() {
  local id="" json=0
  while [ $# -gt 0 ]; do case "$1" in
    --json) json=1; shift ;; -*) die 2 "task show: unknown flag '$1'" ;;
    *) if [ -z "$id" ]; then id=$1; else die 2 "task show: too many args"; fi; shift ;; esac; done
  [ -n "$id" ] || die 2 "task show: <id> required"
  task_exists "$id" || die 4 "task show: '$id' not found"
  parse_task "$(task_file "$id")"
  local st; st=$(task_status "$id")
  if [ $json -eq 1 ]; then
    printf '{"id":"%s","title":"%s","type":"%s","status":"%s","created_by":"%s","verifier":"%s"}\n' \
      "$(json_escape "$t_id")" "$(json_escape "$t_title")" "$(json_escape "$t_type")" \
      "$(json_escape "$st")" "$(json_escape "$t_by")" "$(json_escape "$t_verifier")"
    return 0
  fi
  printf '# %s  [%s]\n\n' "$t_id" "$st"
  cat "$(task_file "$id")"
  printf '\n--- thread ---\n'
  local tid; tid=$(slugify "$id"); local f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    parse_msg "$f"
    if [ "$(slugify "$m_slug")" = "$tid" ] || [ "$(slugify "$m_task")" = "$tid" ]; then
      printf '%s  %-8s %s\n' "$m_id" "$m_type" "$m_author"
    fi
  done < <(all_messages)
}

task_claim() {
  need_identity
  local id="" why=""
  while [ $# -gt 0 ]; do case "$1" in
    -m) why=${2-}; shift 2 ;; -*) die 2 "task claim: unknown flag '$1'" ;;
    *) if [ -z "$id" ]; then id=$1; else die 2 "task claim: too many args"; fi; shift ;; esac; done
  [ -n "$id" ] || die 2 "task claim: <id> required"
  task_exists "$id" || die 4 "task claim: '$id' not found"
  if [ -n "$why" ]; then cmd_claim "$id" -m "$why"; else cmd_claim "$id"; fi
}

task_close() {
  need_identity
  local id="" reason=""
  while [ $# -gt 0 ]; do case "$1" in
    --reason) reason=${2:?}; shift 2 ;; -*) die 2 "task close: unknown flag '$1'" ;;
    *) if [ -z "$id" ]; then id=$1; else die 2 "task close: too many args"; fi; shift ;; esac; done
  [ -n "$id" ] || die 2 "task close: <id> required"
  task_exists "$id" || die 4 "task close: '$id' not found"
  local body="closed"
  if [ "$reason" = "-" ]; then body=$(cat)
  elif [ -n "$reason" ] && [ -f "$reason" ]; then body=$(cat "$reason")
  elif [ -n "$reason" ]; then body=$reason; fi
  TNOW=$(ts); new_record_path "$(slugify "$id")-close"
  {
    printf -- '---\n'
    printf 'id: %s\nauthor: %s\ntype: decision\ntime: %s\nrefs: []\ntask: %s\nstatus: resolved\n' \
      "$REC_ID" "$OB_AGENT" "$TNOW" "$id"
    printf -- '---\n'
    printf '%s\n' "$body"
  } | atomic_write "$REC_PATH"
  printf '%s\n' "$REC_PATH"
}

# ---------------------------------------------------------------------------
# Tier-3: objective-driven competing results (rank / promote)
# ---------------------------------------------------------------------------
# newest-pass-wins verdict for a result id: pass | fail | none
review_verdict() {
  local rid=$1 f seen=none
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    parse_msg "$f"
    [ "$m_type" = "review" ] || continue
    [ "$m_result" = "$rid" ] || continue
    [ "$m_verdict" = "pass" ] && { echo "pass"; return 0; }
    seen=fail
  done < <(all_messages)
  echo "$seen"
}

# fill RES_ROWS (caller-declared) with "resultid|author|metric|verdict" for a task
_collect_results() {
  local tid; tid=$(slugify "$1")
  RES_ROWS=()
  local f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    parse_msg "$f"
    [ "$m_type" = "result" ] || continue
    [ "$(slugify "$m_task")" = "$tid" ] || continue
    local rid=$m_id auth=$m_author mv=${m_mval:-} vd
    vd=$(review_verdict "$rid")
    RES_ROWS+=("$rid|$auth|${mv:--}|$vd")
  done < <(all_messages)
}

task_results() {
  local id="" json=0
  while [ $# -gt 0 ]; do case "$1" in
    --json) json=1; shift ;; -*) die 2 "task results: unknown flag '$1'" ;;
    *) if [ -z "$id" ]; then id=$1; else die 2 "task results: too many args"; fi; shift ;; esac; done
  [ -n "$id" ] || die 2 "task results: <id> required"
  task_exists "$id" || die 4 "task results: '$id' not found"
  local -a RES_ROWS; _collect_results "$id"
  if [ $json -eq 1 ]; then
    local out="[" first=1 row rid a mv vd
    for row in "${RES_ROWS[@]}"; do
      IFS='|' read -r rid a mv vd <<<"$row"
      [ $first -eq 1 ] || out+=","
      out+=$(printf '{"id":"%s","author":"%s","metric":"%s","review":"%s"}' \
        "$(json_escape "$rid")" "$(json_escape "$a")" "$(json_escape "$mv")" "$(json_escape "$vd")")
      first=0
    done
    out+="]"; printf '%s\n' "$out"
  else
    [ ${#RES_ROWS[@]} -eq 0 ] && { printf '(no results for %s)\n' "$id"; return 0; }
    printf '%-42s %-8s %-8s %s\n' RESULT AUTHOR METRIC REVIEW
    local row rid a mv vd
    for row in "${RES_ROWS[@]}"; do
      IFS='|' read -r rid a mv vd <<<"$row"
      printf '%-42s %-8s %-8s %s\n' "$rid" "$a" "$mv" "$vd"
    done
  fi
}

task_rank() {
  local id="" json=0
  while [ $# -gt 0 ]; do case "$1" in
    --json) json=1; shift ;; -*) die 2 "task rank: unknown flag '$1'" ;;
    *) if [ -z "$id" ]; then id=$1; else die 2 "task rank: too many args"; fi; shift ;; esac; done
  [ -n "$id" ] || die 2 "task rank: <id> required"
  task_exists "$id" || die 4 "task rank: '$id' not found"
  parse_task "$(task_file "$id")"
  local dir=${t_metric_dir:-max} mname=${t_metric:-metric_value}
  local -a RES_ROWS; _collect_results "$id"
  local -a cand=(); local row rid a mv vd
  for row in "${RES_ROWS[@]}"; do
    IFS='|' read -r rid a mv vd <<<"$row"
    [ "$vd" = "pass" ] || continue
    case "$mv" in ''|-|*[!0-9.]*) continue ;; esac
    cand+=("$mv|$rid|$a")
  done
  if [ ${#cand[@]} -eq 0 ]; then
    [ $json -eq 1 ] && { printf '[]\n'; return 0; }
    printf '(no ranked candidates for %s: need a passing review + numeric metric_value)\n' "$id"; return 0
  fi
  local sflag="-gr"; [ "$dir" = "min" ] && sflag="-g"
  local sorted; sorted=$(printf '%s\n' "${cand[@]}" | sort -t'|' -k1,1 $sflag)
  if [ $json -eq 1 ]; then
    local out="[" first=1 rank=0 v r au
    while IFS='|' read -r v r au; do
      [ -n "$v" ] || continue
      rank=$((rank+1)); [ $first -eq 1 ] || out+=","
      out+=$(printf '{"rank":%s,"metric":"%s","id":"%s","author":"%s"}' \
        "$rank" "$(json_escape "$v")" "$(json_escape "$r")" "$(json_escape "$au")")
      first=0
    done <<<"$sorted"
    out+="]"; printf '%s\n' "$out"
  else
    printf 'rank of %s by %s (%s):\n' "$id" "$mname" "$dir"
    local rank=0 v r au
    while IFS='|' read -r v r au; do
      [ -n "$v" ] || continue
      rank=$((rank+1)); printf '  #%-2s %-10s %-42s %s\n' "$rank" "$v" "$r" "$au"
    done <<<"$sorted"
  fi
}

# ---- private holdout: integrator re-verify a candidate before promote (anti-gaming) ----
# sets HV_VERDICT (confirmed|diverged|guardrail-fail|no-holdout), HV_HOLD, HV_CLAIM, HV_EXIT
run_holdout() {
  local id=$1 rid=$2 tol=${3:-0.05}
  HV_VERDICT="" HV_HOLD="" HV_CLAIM="" HV_EXIT=""
  local hv="$VERIFIERS/$id.holdout.sh"
  [ -f "$hv" ] || { HV_VERDICT="no-holdout"; return 0; }
  parse_msg "$LOG/$rid.md"
  local cbranch=$m_branch csha=$m_sha; HV_CLAIM=$m_mval
  parse_task "$(task_file "$id")"; local mn=${t_metric:-}
  local out ec
  if out=$(OB_TASK="$id" OB_CAND_BRANCH="$cbranch" OB_CAND_SHA="$csha" OB_CLAIMED_METRIC="$HV_CLAIM" bash "$hv" 2>&1); then ec=0; else ec=$?; fi
  HV_EXIT=$ec
  local metrics; metrics=$(printf '%s\n' "$out" | sed -n 's/^METRICS:[[:space:]]*//p' | tail -1)
  [ -n "$mn" ] && HV_HOLD=$(printf '%s' "$metrics" | sed -n 's/.*"'"$mn"'"[[:space:]]*:[[:space:]]*\([0-9.]*\).*/\1/p')
  if [ "$ec" != 0 ]; then HV_VERDICT="guardrail-fail"; return 0; fi
  if [ -z "$mn" ] || [ -z "$HV_CLAIM" ] || [ -z "$HV_HOLD" ]; then HV_VERDICT="confirmed"; return 0; fi
  local within; within=$(awk -v h="$HV_HOLD" -v c="$HV_CLAIM" -v t="$tol" 'BEGIN{if(c==0){print(h==0)?1:0;exit} d=(h>c)?(h-c):(c-h); print(d/c<=t)?1:0}')
  [ "$within" = 1 ] && HV_VERDICT="confirmed" || HV_VERDICT="diverged"
}

task_holdout() {
  local id="" rid="" tol=0.05 json=0
  while [ $# -gt 0 ]; do case "$1" in
    --tolerance) tol=${2:?}; shift 2 ;; --json) json=1; shift ;;
    -*) die 2 "task holdout: unknown flag '$1'" ;;
    *) if [ -z "$id" ]; then id=$1; elif [ -z "$rid" ]; then rid=$1; else die 2 "task holdout: too many args"; fi; shift ;; esac; done
  [ -n "$id" ]  || die 2 "task holdout: <id> required"
  [ -n "$rid" ] || die 2 "task holdout: <result-id> required"
  task_exists "$id" || die 4 "task holdout: task '$id' not found"
  [ -e "$LOG/$rid.md" ] || die 4 "task holdout: result '$rid' not found"
  run_holdout "$id" "$rid" "$tol"
  if [ $json -eq 1 ]; then
    printf '{"verdict":"%s","claimed":"%s","holdout":"%s","exit":"%s"}\n' \
      "$HV_VERDICT" "$(json_escape "${HV_CLAIM:-}")" "$(json_escape "${HV_HOLD:-}")" "${HV_EXIT:-}"
  else
    printf 'holdout %s %s: verdict=%s claimed=%s holdout=%s exit=%s\n' \
      "$id" "$rid" "$HV_VERDICT" "${HV_CLAIM:-–}" "${HV_HOLD:-–}" "${HV_EXIT:-–}"
  fi
  case "$HV_VERDICT" in confirmed|no-holdout) return 0 ;; *) return 1 ;; esac
}

task_promote() {
  need_identity
  local id="" rid="" why="" tol=0.05 force=0
  while [ $# -gt 0 ]; do case "$1" in
    -m) why=${2-}; shift 2 ;; --tolerance) tol=${2:?}; shift 2 ;; --force) force=1; shift ;;
    -*) die 2 "task promote: unknown flag '$1'" ;;
    *) if [ -z "$id" ]; then id=$1; elif [ -z "$rid" ]; then rid=$1; else die 2 "task promote: too many args"; fi; shift ;; esac; done
  [ -n "$id" ]  || die 2 "task promote: <id> required"
  [ -n "$rid" ] || die 2 "task promote: <result-id> required"
  task_exists "$id" || die 4 "task promote: task '$id' not found"
  [ -e "$LOG/$rid.md" ] || die 4 "task promote: result '$rid' not found"
  parse_msg "$LOG/$rid.md"
  [ "$m_type" = "result" ] || die 2 "task promote: '$rid' is not a result"
  [ "$(slugify "$m_task")" = "$(slugify "$id")" ] || die 2 "task promote: '$rid' is not a result for '$id'"
  run_holdout "$id" "$rid" "$tol"
  case "$HV_VERDICT" in
    guardrail-fail|diverged)
      [ $force -eq 1 ] || die 5 "promote refused: holdout $HV_VERDICT (claimed=${HV_CLAIM:-–} holdout=${HV_HOLD:-–} exit=${HV_EXIT:-–}); use --force to override" ;;
  esac
  [ -n "$why" ] || why="promoted $rid as winner of $id"
  TNOW=$(ts); new_record_path "$(slugify "$id")-promote"
  {
    printf -- '---\n'
    printf 'id: %s\nauthor: %s\ntype: decision\ntime: %s\nrefs: [%s]\ntask: %s\nwinner: %s\nholdout: %s\nstatus: resolved\n' \
      "$REC_ID" "$OB_AGENT" "$TNOW" "$rid" "$id" "$rid" "$HV_VERDICT"
    printf -- '---\n'
    printf '%s\n' "$why"
  } | atomic_write "$REC_PATH"
  printf '%s\n' "$REC_PATH"
}

cmd_digest() {
  local write=0 json=0
  while [ $# -gt 0 ]; do case "$1" in
    --write) write=1; shift ;; --json) json=1; shift ;;
    *) die 2 "digest: unknown arg '$1'" ;; esac; done
  local now; now=$(ts)
  shopt -s nullglob; local tfiles=( "$TASKS"/*.md ); shopt -u nullglob
  if [ $json -eq 1 ]; then
    local out; out=$(printf '{"time":"%s","agents":%s,"tasks":[' "$now" "$(cmd_who --json)")
    local first=1 f st
    for f in "${tfiles[@]}"; do
      parse_task "$f"; st=$(task_status "$t_id")
      [ $first -eq 1 ] || out+=","
      out+=$(printf '{"id":"%s","status":"%s"}' "$(json_escape "$t_id")" "$(json_escape "$st")"); first=0
    done
    out+="]}"; printf '%s\n' "$out"; return 0
  fi
  local tmp; tmp=$(mktemp)
  {
    printf '# OpenBoard digest — %s\n\n## Agents\n' "$now"
    cmd_who 2>/dev/null || true
    printf '\n## Tasks (open / claimed)\n'
    local f st any=0
    for f in "${tfiles[@]}"; do
      parse_task "$f"; st=$(task_status "$t_id")
      case "$st" in open|claimed:*) printf -- '- %s [%s] %s\n' "$t_id" "$st" "$t_title"; any=1 ;; esac
    done
    [ $any -eq 0 ] && printf '(none)\n'
    printf '\n## Recent results\n'
    cmd_read -n 5 --type result 2>/dev/null | grep -E '^## ' | sed 's/^## /- /' || true
    printf '\n## Recent decisions\n'
    cmd_read -n 5 --type decision 2>/dev/null | grep -E '^## ' | sed 's/^## /- /' || true
  } > "$tmp"
  if [ $write -eq 1 ]; then
    atomic_write "$DIGEST" < "$tmp"; printf '%s\n' "$DIGEST"
  else cat "$tmp"; fi
  rm -f "$tmp"
}

cmd_verify() {
  local id="" json=0
  while [ $# -gt 0 ]; do case "$1" in
    --task) id=${2:?}; shift 2 ;; --json) json=1; shift ;;
    *) die 2 "verify: unknown arg '$1'" ;; esac; done
  [ -n "$id" ] || die 2 "verify: --task required"
  task_exists "$id" || die 4 "verify: task '$id' not found"
  local v="$VERIFIERS/$id.sh"
  [ -f "$v" ] || die 2 "verify: no verifier at $v"
  local out ec
  if out=$(bash "$v" 2>&1); then ec=0; else ec=$?; fi
  local metrics; metrics=$(printf '%s\n' "$out" | sed -n 's/^METRICS:[[:space:]]*//p' | tail -1)
  [ -n "$metrics" ] || metrics='{}'
  if [ $json -eq 1 ]; then
    local pass=false; [ $ec -eq 0 ] && pass=true
    printf '{"task":"%s","pass":%s,"exit":%s,"metrics":%s,"output":"%s"}\n' \
      "$(json_escape "$id")" "$pass" "$ec" "$metrics" "$(json_escape "$out")"
  else
    if [ $ec -eq 0 ]; then printf 'PASS  %s\n' "$id"; else printf 'FAIL  %s (exit %s)\n' "$id" "$ec"; fi
    [ "$metrics" != '{}' ] && printf 'metrics: %s\n' "$metrics"
    printf '%s\n' "$out"
  fi
  return $ec
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------
cmd_whoami() {
  need_identity
  printf '%s\n' "$OB_AGENT"
}

cmd_register() {
  need_identity
  local role= status=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --role)   role=${2:?}; shift 2 ;;
      --status) status=${2:?}; shift 2 ;;
      *) die 2 "register: unknown arg '$1'" ;;
    esac
  done
  [ -n "$role" ] || die 2 "register: --role required"
  [ -n "$status" ] || status="registered"
  local f="$AGENTS/$OB_AGENT.md"
  printf 'name: %s\nrole: %s\nupdated: %s\nstatus: %s\n' \
    "$OB_AGENT" "$role" "$(ts)" "$status" | atomic_write "$f"
  printf '%s\n' "$f"
}

cmd_status() {
  need_identity
  [ $# -ge 1 ] || die 2 "status: <text> required"
  local text=$* f="$AGENTS/$OB_AGENT.md" role="unknown" line key val
  if [ -f "$f" ]; then
    while IFS= read -r line; do
      key=${line%%:*}; val=${line#*:}; val=${val# }
      [ "$key" = "role" ] && role=$val
    done < "$f"
  fi
  printf 'name: %s\nrole: %s\nupdated: %s\nstatus: %s\n' \
    "$OB_AGENT" "$role" "$(ts)" "$text" | atomic_write "$f"
  printf '%s\n' "$f"
}

cmd_who() {
  local json=0
  [ "${1:-}" = "--json" ] && json=1
  shopt -s nullglob
  local files=( "$AGENTS"/*.md ) f line key val
  shopt -u nullglob
  if [ $json -eq 1 ]; then
    local out="[" first=1 name role updated status
    for f in "${files[@]}"; do
      name=$(stem "$f"); role="unknown"; updated=""; status=""
      while IFS= read -r line; do
        key=${line%%:*}; val=${line#*:}; val=${val# }
        case "$key" in
          name) name=$val ;; role) role=$val ;; updated) updated=$val ;; status) status=$val ;;
        esac
      done < "$f"
      [ $first -eq 1 ] || out+=","
      out+=$(printf '{"name":"%s","role":"%s","updated":"%s","status":"%s"}' \
        "$(json_escape "$name")" "$(json_escape "$role")" "$(json_escape "$updated")" \
        "$(json_escape "$status")")
      first=0
    done
    out+="]"
    printf '%s\n' "$out"
  else
    [ ${#files[@]} -eq 0 ] && { printf '(no agents yet)\n'; return 0; }
    for f in "${files[@]}"; do
      local name role updated status
      name=$(stem "$f"); role="unknown"; updated=""; status=""
      while IFS= read -r line; do
        key=${line%%:*}; val=${line#*:}; val=${val# }
        case "$key" in
          name) name=$val ;; role) role=$val ;; updated) updated=$val ;; status) status=$val ;;
        esac
      done < "$f"
      printf '%-12s role=%-10s updated=%s  status=%s\n' "$name" "$role" "$updated" "$status"
    done
  fi
}

cmd_post() {
  need_identity
  local type="" slug="" msg="" have_msg=0 json=0
  local -a refs=()
  while [ $# -gt 0 ]; do
    case "$1" in
      -m)     msg=${2-}; have_msg=1; shift 2 ;;
      --ref)  refs+=("${2:?}"); shift 2 ;;
      --json) json=1; shift ;;
      --)     shift; break ;;
      -*)     die 2 "post: unknown flag '$1'" ;;
      *) if [ -z "$type" ]; then type=$1; elif [ -z "$slug" ]; then slug=$1;
         else die 2 "post: too many args"; fi; shift ;;
    esac
  done
  [ -n "$type" ] || die 2 "post: <type> required"
  [ -n "$slug" ] || die 2 "post: <slug> required"
  valid_type "$type" || die 2 "post: invalid type '$type' (want: $VALID_TYPES)"
  slug=$(slugify "$slug")
  [ -n "$slug" ] || die 2 "post: slug empty after slugify"
  local body
  if [ $have_msg -eq 1 ]; then body=$msg
  elif [ ! -t 0 ]; then body=$(cat)
  else body=""; fi
  local refs_fmt="[]"
  if [ ${#refs[@]} -gt 0 ]; then
    local joined; joined=$(printf '%s, ' "${refs[@]}"); joined=${joined%, }
    refs_fmt="[$joined]"
  fi
  TNOW=$(ts); new_record_path "$slug"
  {
    printf -- '---\n'
    printf 'id: %s\n' "$REC_ID"
    printf 'author: %s\n' "$OB_AGENT"
    printf 'type: %s\n' "$type"
    printf 'time: %s\n' "$TNOW"
    printf 'refs: %s\n' "$refs_fmt"
    printf 'status: open\n'
    printf -- '---\n'
    printf '%s\n' "$body"
  } | atomic_write "$REC_PATH"
  if [ $json -eq 1 ]; then
    printf '{"id":"%s","path":"%s"}\n' "$(json_escape "$REC_ID")" "$(json_escape "$REC_PATH")"
  else
    printf '%s\n' "$REC_PATH"
  fi
}

cmd_read() {
  local n=20 since="" ftype="" fauthor="" json=0
  while [ $# -gt 0 ]; do
    case "$1" in
      -n)       n=${2:?}; shift 2 ;;
      --since)  since=${2:?}; shift 2 ;;
      --type)   ftype=${2:?}; shift 2 ;;
      --author) fauthor=${2:?}; shift 2 ;;
      --json)   json=1; shift ;;
      *) die 2 "read: unknown arg '$1'" ;;
    esac
  done
  local -a matched=()
  local f s
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    s=$(stem "$f")
    if [ -n "$since" ] && [ ! "$s" \> "$since" ]; then continue; fi
    parse_msg "$f"
    if [ -n "$ftype" ]   && [ "$m_type" != "$ftype" ];     then continue; fi
    if [ -n "$fauthor" ] && [ "$m_author" != "$fauthor" ]; then continue; fi
    matched+=("$f")
  done < <(all_messages)
  local total=${#matched[@]} start=0
  [ "$total" -gt "$n" ] && start=$((total - n))
  if [ $json -eq 1 ]; then
    local out="[" first=1 i
    for ((i=start; i<total; i++)); do
      parse_msg "${matched[$i]}"
      [ $first -eq 1 ] || out+=","
      out+=$(msg_json); first=0
    done
    out+="]"; printf '%s\n' "$out"
  else
    local i
    for ((i=start; i<total; i++)); do parse_msg "${matched[$i]}"; msg_human; done
  fi
}

cmd_new() {
  need_identity
  local json=0
  [ "${1:-}" = "--json" ] && json=1
  local cur="$OB_BOARD/.cursor-$OB_AGENT" last="" maxstem=""
  [ -f "$cur" ] && last=$(cat "$cur")
  local -a matched=()
  local f s
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    s=$(stem "$f")
    if [ -z "$maxstem" ] || [ "$s" \> "$maxstem" ]; then maxstem=$s; fi
    if [ "$s" \> "$last" ]; then matched+=("$f"); fi
  done < <(all_messages)
  if [ $json -eq 1 ]; then
    local out="[" first=1 i
    for ((i=0; i<${#matched[@]}; i++)); do
      parse_msg "${matched[$i]}"
      [ $first -eq 1 ] || out+=","
      out+=$(msg_json); first=0
    done
    out+="]"; printf '%s\n' "$out"
  else
    local i
    for ((i=0; i<${#matched[@]}; i++)); do parse_msg "${matched[$i]}"; msg_human; done
  fi
  [ -n "$maxstem" ] && printf '%s' "$maxstem" | atomic_write "$cur"
  return 0
}

cmd_claim() {
  need_identity
  local slug="" why=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -m) why=${2-}; shift 2 ;;
      -*) die 2 "claim: unknown flag '$1'" ;;
      *)  if [ -z "$slug" ]; then slug=$1; else die 2 "claim: too many args"; fi; shift ;;
    esac
  done
  [ -n "$slug" ] || die 2 "claim: <slug> required"
  slug=$(slugify "$slug")
  [ -n "$slug" ] || die 2 "claim: slug empty after slugify"
  [ -n "$why" ] || why="claiming $slug"
  local f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    parse_msg "$f"
    [ "$m_type" = "claim" ]   || continue
    [ "$m_slug" = "$slug" ]   || continue
    [ "$m_status" = "open" ]  || continue
    [ "$m_author" != "$OB_AGENT" ] && die 5 "claim conflict: '$slug' already claimed by $m_author"
  done < <(all_messages)
  TNOW=$(ts); new_record_path "$slug"
  {
    printf -- '---\n'
    printf 'id: %s\n' "$REC_ID"
    printf 'author: %s\n' "$OB_AGENT"
    printf 'type: claim\n'
    printf 'time: %s\n' "$TNOW"
    printf 'refs: []\n'
    printf 'slug: %s\n' "$slug"
    printf 'status: open\n'
    printf -- '---\n'
    printf '%s\n' "$why"
  } | atomic_write "$REC_PATH"
  printf '%s\n' "$REC_PATH"
}

cmd_result() {
  need_identity
  local task="" branch="" sha="" evidence="" msg="" mval=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --task)     task=${2:?}; shift 2 ;;
      --branch)   branch=${2:?}; shift 2 ;;
      --sha)      sha=${2:?}; shift 2 ;;
      --evidence) evidence=${2:?}; shift 2 ;;
      --metric)   mval=${2:?}; shift 2 ;;
      -m)         msg=${2-}; shift 2 ;;
      *) die 2 "result: unknown arg '$1'" ;;
    esac
  done
  [ -n "$task" ]     || die 2 "result: --task required"
  [ -n "$branch" ]   || die 2 "result: --branch required"
  [ -n "$sha" ]      || die 2 "result: --sha required"
  [ -n "$evidence" ] || die 2 "result: --evidence required"
  local ev
  if [ "$evidence" = "-" ]; then ev=$(cat)
  elif [ -f "$evidence" ]; then ev=$(cat "$evidence")
  else die 2 "result: evidence file not found '$evidence'"; fi
  local slug; slug=$(slugify "$task")
  TNOW=$(ts); new_record_path "$slug"
  {
    printf -- '---\n'
    printf 'id: %s\n' "$REC_ID"
    printf 'author: %s\n' "$OB_AGENT"
    printf 'type: result\n'
    printf 'time: %s\n' "$TNOW"
    printf 'refs: []\n'
    printf 'task: %s\n' "$task"
    printf 'branch: %s\n' "$branch"
    printf 'sha: %s\n' "$sha"
    [ -n "$mval" ] && printf 'metric_value: %s\n' "$mval"
    printf 'status: open\n'
    printf -- '---\n'
    [ -n "$msg" ] && printf '%s\n\n' "$msg"
    printf 'evidence:\n%s\n' "$ev"
  } | atomic_write "$REC_PATH"
  printf '%s\n' "$REC_PATH"
}

cmd_review() {
  need_identity
  local rid="" score="" verdict="" msg=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --score)   score=${2:?}; shift 2 ;;
      --verdict) verdict=${2:?}; shift 2 ;;
      -m)        msg=${2-}; shift 2 ;;
      -*) die 2 "review: unknown flag '$1'" ;;
      *) if [ -z "$rid" ]; then rid=$1; else die 2 "review: too many args"; fi; shift ;;
    esac
  done
  [ -n "$rid" ]     || die 2 "review: <result-id> required"
  [ -n "$score" ]   || die 2 "review: --score required"
  [ -n "$verdict" ] || die 2 "review: --verdict required"
  [[ "$score" =~ ^[0-9]+$ ]] || die 2 "review: --score must be integer 0-10"
  { [ "$score" -ge 0 ] && [ "$score" -le 10 ]; } || die 2 "review: --score out of range 0-10"
  case "$verdict" in pass|fail) ;; *) die 2 "review: --verdict must be pass|fail" ;; esac
  if [ "$verdict" = "pass" ] && [ "$score" -lt 7 ]; then
    die 2 "review: a 'pass' verdict requires score >= 7 (got $score)"
  fi
  [ -e "$LOG/$rid.md" ] || die 4 "review: result '$rid' not found"
  local slug; slug=$(slugify "${rid}-review")
  TNOW=$(ts); new_record_path "$slug"
  {
    printf -- '---\n'
    printf 'id: %s\n' "$REC_ID"
    printf 'author: %s\n' "$OB_AGENT"
    printf 'type: review\n'
    printf 'time: %s\n' "$TNOW"
    printf 'refs: [%s]\n' "$rid"
    printf 'result: %s\n' "$rid"
    printf 'score: %s\n' "$score"
    printf 'verdict: %s\n' "$verdict"
    printf 'status: open\n'
    printf -- '---\n'
    [ -n "$msg" ] && printf '%s\n' "$msg" || :
  } | atomic_write "$REC_PATH"
  printf '%s\n' "$REC_PATH"
}

cmd_sync() {
  local msg="update"
  while [ $# -gt 0 ]; do
    case "$1" in -m) msg=${2:?}; shift 2 ;; *) shift ;; esac
  done
  ( cd "$OB_HOME" && git add board \
    && git commit -q -m "board sync: $msg (${OB_AGENT:-unknown} @ $(ts))" \
    && printf 'committed\n' ) || printf 'nothing to commit\n'
}

usage() {
  cat >&2 <<'EOF'
usage: OB_AGENT=<name> board.sh <command> [args]
  init [<dir>] [--json]        make <dir> (default CWD) an OpenBoard root
  brief [--hook|--paste|--json] [--role <r>]   onboarding text — single source for hook/paste/MCP
  doctor [--json]              cold-start self-check (home/identity/roundtrip/transport/deps/hooks)
  cat <id> [--json]            print one message in full
  search <pattern> [-n N] [--json]   case-insensitive ERE over all messages (last N hits, default 20)
  version                      print the toolkit version
  whoami
  register --role <role> [--status <text>]
  who [--json]
  post <type> <slug> [-m <msg> | stdin] [--ref <id> ...] [--json]
  read [-n N] [--since <id>] [--type <t>] [--author <a>] [--json]
  new [--json]
  status <text>
  claim <slug> [-m <why>]
  result --task <slug> --branch <agent/x> --sha <sha> --evidence <file|-> [--metric <value>] [-m <msg>]
  review <result-id> --score <0-10> --verdict <pass|fail> [-m <msg>]
  sync [-m <msg>]
  task new --title T --type X [--verifier V] [--acceptance <file|->] [--id ID] [--metric <name>] [--metric-dir max|min] [--json]
  task list [--status open|claimed|done|closed] [--json]
  task show <id> [--json]
  task claim <id> [-m <why>]
  task close <id> [--reason <file|->]
  digest [--write] [--json]
  verify --task <id> [--json]
  task results <id> [--json]
  task rank <id> [--json]
  task promote <id> <result-id> [--tolerance <frac>] [--force] [-m <why>]
  task holdout <id> <result-id> [--tolerance <frac>] [--json]
EOF
}

# ---------------------------------------------------------------------------
# init — make a directory an OpenBoard root (like `git init`): marker + config + board dirs.
# Idempotent: only creates what is missing; never clobbers. Does NOT install the CLI tooling.
# ---------------------------------------------------------------------------
cmd_init() {
  local target="" json=0
  while [ $# -gt 0 ]; do
    case "$1" in --json) json=1; shift ;; -*) die 2 "init: unknown flag '$1'" ;; *) target=$1; shift ;; esac
  done
  target="${target:-$PWD}"
  target=$(cd "$target" 2>/dev/null && pwd) || die 4 "init: no such directory '$target'"
  local made=() kept=()
  # marker + tracked, self-describing project config
  mkdir -p "$target/.openboard"
  if [ -f "$target/.openboard/project" ]; then kept+=(".openboard/project")
  else
    printf 'OB_SCHEMA=1\nOB_BOARD_TRANSPORT=local\nOB_TRUST_LEVEL=0\n' > "$target/.openboard/project"
    made+=(".openboard/project")
  fi
  # board data skeleton (+ sibling task/verifier/artifact dirs)
  local d
  for d in board/agents board/messages board/decisions board/inbox tasks verifiers artifacts; do
    if [ -d "$target/$d" ]; then kept+=("$d/")
    else mkdir -p "$target/$d"; : > "$target/$d/.gitkeep"; made+=("$d/"); fi
  done
  if [ -f "$target/board/digest.md" ]; then kept+=("board/digest.md")
  else printf '# OpenBoard digest\n\n(empty — run `board digest --write`)\n' > "$target/board/digest.md"; made+=("board/digest.md"); fi
  if [ $json -eq 1 ]; then
    local m j="" first=1
    printf '{"root":"%s","created":[' "$(json_escape "$target")"
    for m in ${made+"${made[@]}"}; do [ $first -eq 1 ] || printf ','; printf '"%s"' "$(json_escape "$m")"; first=0; done
    printf ']}\n'
    return 0
  fi
  printf 'OpenBoard root: %s\n' "$target"
  if [ ${#made[@]} -gt 0 ]; then printf 'created:\n'; for d in "${made[@]}"; do printf '  + %s\n' "$d"; done; fi
  if [ ${#kept[@]} -gt 0 ]; then printf 'already present (kept): %d item(s)\n' "${#kept[@]}"; fi
  cat <<EOF

next:
  cd $target
  OB_AGENT=<name> $(basename "$0") register --role <role>
  OB_AGENT=<name> $(basename "$0") task list
EOF
}

# ---------------------------------------------------------------------------
# brief — the SINGLE onboarding renderer (decision 0012 mech 2). Every channel calls this
# so the content can never drift: board-hook join (--hook), fresh-TUI paste block (--paste),
# MCP onboarding resource (--json). SELF_BIN = the canonical CLI path to print in the text.
# ---------------------------------------------------------------------------
SELF_BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/board"

brief_role() {   # resolved role: explicit > .ob-role in cwd > registered agent file > contributor
  local role=$1 r
  [ -n "$role" ] && { printf '%s' "$role"; return; }
  [ -f "$PWD/.ob-role" ] && { tr -d '[:space:]' < "$PWD/.ob-role"; return; }
  if [ -n "${OB_AGENT:-}" ] && [ -f "$AGENTS/$OB_AGENT.md" ]; then
    r=$(sed -n 's/^role: //p' "$AGENTS/$OB_AGENT.md" | head -1)
    [ -n "$r" ] && { printf '%s' "$r"; return; }
  fi
  printf 'contributor'
}

brief_hook_text() {   # $1=agent $2=role — injected as context on session start
  printf 'You are OpenBoard agent "%s" (role: %s). Coordinate via the shared board.\n' "$1" "$2"
  printf 'Current board state on join:\n\n'
  cmd_digest 2>/dev/null || true
  printf '\nWork loop: `%s task list` -> `%s task claim <id> -m ...` -> build -> `%s result ...` -> `%s review ...`.\n' \
    "$SELF_BIN" "$SELF_BIN" "$SELF_BIN" "$SELF_BIN"
}

brief_paste_text() {  # $1=agent $2=role — drop into a fresh TUI; paths come from config, never hand-written
  local agent=$1 role=$2 wt
  wt="$(dirname "$OB_HOME")/ob-$agent"
  cat <<EOF
You are agent $agent on OpenBoard. Board root: $OB_HOME.
Your code workspace is the git worktree $wt (branch agent/$agent) — build ONLY there
(provision it once with: $OB_HOME/bin/board-join $agent $role).
Communicate via the shared board using the stable CLI:
  export OB_HOME=$OB_HOME OB_AGENT=$agent
  $SELF_BIN register --role "$role"
  $SELF_BIN new           # read unread
  $SELF_BIN task list     # task board (computed status)
Read CONTRACT.md + docs/board-cli-spec*.md + board/decisions/ first.
Work loop: CLAIM (task claim <id> -m) -> BUILD in your worktree -> SHARE
(result --task <id> --branch agent/$agent --sha <sha> --evidence -) -> REVIEW others.
Never touch main or other worktrees. The integrator merges via the gate.
EOF
}

cmd_brief() {
  local mode=hook role="" agent t
  while [ $# -gt 0 ]; do
    case "$1" in
      --hook)  mode=hook; shift ;;
      --paste) mode=paste; shift ;;
      --json)  mode=json; shift ;;
      --role)  role=${2:?}; shift 2 ;;
      *) die 2 "brief: unknown arg '$1' (want --hook|--paste|--json [--role <r>])" ;;
    esac
  done
  role=$(brief_role "$role")
  agent="${OB_AGENT:-<NAME>}"
  case "$mode" in
    hook)  brief_hook_text "$agent" "$role" ;;
    paste) brief_paste_text "$agent" "$role" ;;
    json)
      t=$(brief_hook_text "$agent" "$role")
      printf '{"agent":"%s","role":"%s","home":"%s","brief":"%s"}\n' \
        "$(json_escape "$agent")" "$(json_escape "$role")" "$(json_escape "$OB_HOME")" "$(json_escape "$t")"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# doctor — cold-start self-check (decision 0012 mech 4): turn "silently wrote into the void"
# into a red line + a fix hint. board-join runs this last; a join counts only when it is green.
# Probes must NEVER pollute the message stream: roundtrip uses a throwaway board/.probe-* file.
# ---------------------------------------------------------------------------
cmd_doctor() {
  local json=0
  while [ $# -gt 0 ]; do
    case "$1" in --json) json=1; shift ;; *) die 2 "doctor: unknown arg '$1'" ;; esac
  done
  local fails=0 rows=()
  chk() { rows+=("$1|$2|$3"); [ "$1" = FAIL ] && fails=$((fails+1)) || true; }

  # 1 home resolved + board writable
  if [ -d "$OB_BOARD" ] && [ -w "$OB_BOARD" ]; then chk ok home "$OB_HOME (board writable)"
  else chk FAIL home "board dir missing/unwritable: $OB_BOARD — run \`board init\` there"; fi

  # 2 identity present and not anon
  if [ -n "$OB_AGENT" ] && [ "$OB_AGENT" != anon ]; then chk ok identity "$OB_AGENT"
  else chk FAIL identity "OB_AGENT unset/anon — export OB_AGENT=<name> or write .ob-agent"; fi

  # 3 write->read roundtrip via a throwaway probe (never a real message)
  local probe="$OB_BOARD/.probe-$$" out=""
  if printf 'ping' | atomic_write "$probe" 2>/dev/null; then out=$(cat "$probe" 2>/dev/null || true); fi
  rm -f "$probe" 2>/dev/null || true
  if [ "$out" = ping ]; then chk ok roundtrip "write->read ok"
  else chk FAIL roundtrip "cannot write+read in $OB_BOARD"; fi

  # 4 transport
  case "$OB_BOARD_TRANSPORT" in
    local) chk ok transport "local" ;;
    git)
      if GIT_TERMINAL_PROMPT=0 timeout 5 git -C "$OB_HOME" ls-remote --exit-code origin >/dev/null 2>&1; then
        chk ok transport "git (origin reachable)"
      else chk FAIL transport "git transport: remote 'origin' unreachable from $OB_HOME"; fi ;;
    *) chk FAIL transport "unknown OB_BOARD_TRANSPORT '$OB_BOARD_TRANSPORT' (want local|git)" ;;
  esac

  # 5 deps (core = hard requirement; python3 = MCP/JSON tooling only)
  local missing="" c
  for c in git awk sed sort; do command -v "$c" >/dev/null 2>&1 || missing="$missing $c"; done
  if [ -n "$missing" ]; then chk FAIL deps "missing:$missing"
  elif command -v python3 >/dev/null 2>&1; then chk ok deps "coreutils/git + python3"
  else chk warn deps "core ok; python3 missing (MCP + JSON validation degraded)"; fi

  # 6 hooks wiring (informational: absent is a valid manual-sync setup)
  if [ -f "$OB_HOME/.claude/settings.json" ] && grep -q board-hook "$OB_HOME/.claude/settings.json" 2>/dev/null; then
    chk ok hooks ".claude/settings.json wires board-hook"
  else chk skip hooks "no hook wiring (run \`board new\` at the top of each turn)"; fi

  local r st rest nm dt
  if [ $json -eq 1 ]; then
    printf '{"home":"%s","failures":%d,"checks":[' "$(json_escape "$OB_HOME")" "$fails"
    local first=1
    for r in "${rows[@]}"; do
      st=${r%%|*}; rest=${r#*|}; nm=${rest%%|*}; dt=${rest#*|}
      [ $first -eq 1 ] || printf ','
      printf '{"name":"%s","status":"%s","detail":"%s"}' \
        "$(json_escape "$nm")" "$(json_escape "$st")" "$(json_escape "$dt")"
      first=0
    done
    printf ']}\n'
  else
    printf 'board doctor — %s\n' "$OB_HOME"
    for r in "${rows[@]}"; do
      st=${r%%|*}; rest=${r#*|}; nm=${rest%%|*}; dt=${rest#*|}
      printf '  %-4s %-10s %s\n' "$st" "$nm" "$dt"
    done
    if [ $fails -eq 0 ]; then printf 'RESULT: ok (%d checks)\n' "${#rows[@]}"
    else printf 'RESULT: %d FAILURE(S)\n' "$fails"; fi
  fi
  [ "$fails" -eq 0 ]
}

# ---------------------------------------------------------------------------
# cat / search — read-only message inspection (no identity required).
# `board cat <id>` is what the per-turn hook sync tells agents to run for detail.
# ---------------------------------------------------------------------------
cmd_cat() {
  local id="" json=0
  while [ $# -gt 0 ]; do
    case "$1" in --json) json=1; shift ;; -*) die 2 "cat: unknown flag '$1'" ;; *) id=$1; shift ;; esac
  done
  [ -n "$id" ] || die 2 "cat: message id required"
  local f="$LOG/${id%.md}.md"
  [ -f "$f" ] || die 4 "cat: no such message '$id'"
  parse_msg "$f"
  if [ $json -eq 1 ]; then msg_json; printf '\n'; else msg_human; fi
}

cmd_search() {
  local pat="" json=0 n=20
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) json=1; shift ;;
      -n)     n=${2:?}; shift 2 ;;
      -*)     die 2 "search: unknown flag '$1'" ;;
      *)      pat=$1; shift ;;
    esac
  done
  [ -n "$pat" ] || die 2 "search: pattern required (case-insensitive ERE over id+frontmatter+body)"
  local f hits=()
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    grep -qiE -- "$pat" "$f" 2>/dev/null && hits+=("$f")
  done < <(all_messages)
  local total=${#hits[@]} start=0
  [ "$total" -gt "$n" ] && start=$((total - n))
  if [ $json -eq 1 ]; then
    printf '{"pattern":"%s","total":%d,"shown":%d,"hits":[' "$(json_escape "$pat")" "$total" $((total - start))
    local i first=1
    for (( i=start; i<total; i++ )); do
      parse_msg "${hits[$i]}"
      [ $first -eq 1 ] || printf ','
      msg_json; first=0
    done
    printf ']}\n'
  else
    [ "$total" -eq 0 ] && { printf 'no matches for: %s\n' "$pat"; return 0; }
    [ "$start" -gt 0 ] && printf '(%d matches, showing last %d — raise with -n)\n\n' "$total" "$n"
    local i
    for (( i=start; i<total; i++ )); do parse_msg "${hits[$i]}"; msg_human; done
  fi
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
cmd="${1:-help}"; shift || true
case "$cmd" in
  init)     cmd_init "$@" ;;
  brief)    cmd_brief "$@" ;;
  doctor)   cmd_doctor "$@" ;;
  cat)      cmd_cat "$@" ;;
  search)   cmd_search "$@" ;;
  version|--version)
    printf 'openboard %s\n' "$(cat "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/VERSION" 2>/dev/null || printf 'unknown')" ;;
  whoami)   cmd_whoami "$@" ;;
  register) cmd_register "$@" ;;
  who)      cmd_who "$@" ;;
  post)     cmd_post "$@" ;;
  read)     cmd_read "$@" ;;
  new)      cmd_new "$@" ;;
  status)   cmd_status "$@" ;;
  claim)    cmd_claim "$@" ;;
  result)   cmd_result "$@" ;;
  review)   cmd_review "$@" ;;
  sync)     cmd_sync "$@" ;;
  task)     cmd_task "$@" ;;
  digest)   cmd_digest "$@" ;;
  verify)   cmd_verify "$@" ;;
  help|-h|--help) usage ;;
  *) usage; exit 2 ;;
esac
