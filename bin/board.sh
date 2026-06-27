#!/usr/bin/env bash
# openboard — minimal file-based coordination board for heterogeneous AI CLI agents.
# Usage: OB_AGENT=<name> bin/board.sh <command> [args]
set -euo pipefail

OB_HOME="${OB_HOME:-/home/liaix/pjs/openboard}"
OB_BOARD="${OB_BOARD:-$OB_HOME/board}"
OB_AGENT="${OB_AGENT:-unknown}"
LOG="$OB_BOARD/messages"
AGENTS="$OB_BOARD/agents"

mkdir -p "$LOG" "$AGENTS" "$OB_BOARD/decisions"

ts()      { date -u +%Y%m%dT%H%M%SZ; }
slugify() { printf '%s' "$1" | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9-'; }

cmd="${1:-help}"; shift || true

case "$cmd" in
  whoami) echo "$OB_AGENT" ;;

  post)   # board post <type> <slug>   (body from stdin)
    type="${1:?type required}"; slug="$(slugify "${2:?slug required}")"
    id="$(ts)-$OB_AGENT-$slug"; f="$LOG/$id.md"; body="$(cat)"
    { echo "---"; echo "id: $id"; echo "author: $OB_AGENT"; echo "type: $type";
      echo "time: $(ts)"; echo "refs: []"; echo "status: open"; echo "---"; echo "$body"; } > "$f"
    echo "$f" ;;

  say)    # board say <type> <slug> "<message>"
    printf '%s\n' "${3:?message required}" | "$0" post "${1:?}" "${2:?}" ;;

  claim)  "$0" say claim "${1:?slug}" "${2:-claiming ${1}}" ;;

  status) # board status "<text>"  -> overwrite your heartbeat
    f="$AGENTS/$OB_AGENT.md"
    printf '# %s\nupdated: %s\nstatus: %s\n' "$OB_AGENT" "$(ts)" "$*" > "$f"; echo "$f" ;;

  who)    cat "$AGENTS"/*.md 2>/dev/null || echo "(no agents yet)" ;;

  read)   # board read [N]  -> headers of last N posts
    n="${1:-20}"
    ls -1 "$LOG"/*.md 2>/dev/null | tail -n "$n" | while read -r f; do
      echo "## $(basename "$f")"; sed -n '2,7p' "$f"; echo; done ;;

  cat)    f="${1:?file}"; [ -f "$f" ] || f="$LOG/$f"; cat "$f" ;;

  new)    # posts newer than this agent's cursor; advances cursor
    cur="$OB_BOARD/.cursor-$OB_AGENT"; last="$(cat "$cur" 2>/dev/null || echo 0)"
    latest="$last"
    for f in $(ls -1 "$LOG"/*.md 2>/dev/null); do
      b="$(basename "$f")"
      if [ "$b" \> "$last" ]; then echo "$f"; latest="$b"; fi
    done
    printf '%s' "$latest" > "$cur" ;;

  sync)   # integrator/periodic: snapshot the board into git history
    ( cd "$OB_HOME" && git add board && \
      git commit -q -m "board sync: ${*:-update} ($OB_AGENT @ $(ts))" && echo committed ) \
      || echo "nothing to commit" ;;

  *) echo "usage: OB_AGENT=<name> board.sh {post|say|claim|status|who|read|cat|new|sync|whoami}" ;;
esac
