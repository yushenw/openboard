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
OB_HOME="${OB_HOME:-/home/liaix/pjs/openboard}"
OB_BOARD="${OB_BOARD:-$OB_HOME/board}"
OB_AGENT="${OB_AGENT-}"                 # NO default: empty means "missing identity"

LOG="$OB_BOARD/messages"
AGENTS="$OB_BOARD/agents"
DECISIONS="$OB_BOARD/decisions"

mkdir -p "$LOG" "$AGENTS" "$DECISIONS"

VALID_TYPES="propose question answer result review claim decision"

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
  m_slug= m_branch= m_sha= m_task= m_result= m_score= m_verdict=
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
        verdict) m_verdict=$val ;;
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
  local task="" branch="" sha="" evidence="" msg=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --task)     task=${2:?}; shift 2 ;;
      --branch)   branch=${2:?}; shift 2 ;;
      --sha)      sha=${2:?}; shift 2 ;;
      --evidence) evidence=${2:?}; shift 2 ;;
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
    [ -n "$msg" ] && printf '%s\n' "$msg"
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
  whoami
  register --role <role> [--status <text>]
  who [--json]
  post <type> <slug> [-m <msg> | stdin] [--ref <id> ...] [--json]
  read [-n N] [--since <id>] [--type <t>] [--author <a>] [--json]
  new [--json]
  status <text>
  claim <slug> [-m <why>]
  result --task <slug> --branch <agent/x> --sha <sha> --evidence <file|-> [-m <msg>]
  review <result-id> --score <0-10> --verdict <pass|fail> [-m <msg>]
  sync [-m <msg>]
EOF
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
cmd="${1:-help}"; shift || true
case "$cmd" in
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
  help|-h|--help) usage ;;
  *) usage; exit 2 ;;
esac
