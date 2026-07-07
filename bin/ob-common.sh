#!/usr/bin/env bash
# ob-common.sh — shared root-discovery + config loading for every OpenBoard entry point.
# Sourced by board.sh / board-hook / board-join. Defines FUNCTIONS ONLY: no side effects at
# source time and no `set` changes, so it is safe under both `set -euo pipefail` and `set -u`.
#
# Root resolution (function ob_resolve_home) replaces the old hard-coded OB_HOME default
# so the toolkit works from any checkout / any path. Precedence:
#   1. $OB_HOME env            — explicit override (tests, hooks, CI)
#   2. `.openboard/` marker    — walk up from CWD like git finds `.git`;
#                                its `project` (tracked) + `local` (gitignored) may redirect OB_HOME
#   3. the script's bin/.. dir — keeps a plain checkout working with no marker yet
#
# `.openboard/project` is the tracked, self-describing project config (transport, trust).
# `.openboard/local`   is the per-checkout override (gitignored): a worktree points OB_HOME at
#                      the SHARED board here. Both are plain KEY=VALUE, sourced as shell.

# ob_script_home <script-path> — derive OB_HOME from a bin/<script> location: <HOME>/bin/x -> <HOME>.
# Resolves a symlink chain without relying on `realpath` (may be absent on minimal systems).
ob_script_home() {
  local src=$1 dir
  while [ -h "$src" ]; do
    dir=$(cd -P "$(dirname "$src")" >/dev/null 2>&1 && pwd) || return 1
    src=$(readlink "$src"); case "$src" in /*) ;; *) src="$dir/$src" ;; esac
  done
  dir=$(cd -P "$(dirname "$src")/.." >/dev/null 2>&1 && pwd) || return 1
  printf '%s' "$dir"
}

# ob_walk_up_marker — from $PWD, print the nearest ancestor dir that contains `.openboard/`.
ob_walk_up_marker() {
  local d; d=$(pwd -P 2>/dev/null) || return 1
  while [ -n "$d" ] && [ "$d" != / ]; do
    [ -d "$d/.openboard" ] && { printf '%s' "$d"; return 0; }
    d=$(dirname "$d")
  done
  [ -d "/.openboard" ] && { printf '/'; return 0; }
  return 1
}

# ob_resolve_home <script-path> — set + export OB_HOME (see precedence above). Returns non-zero
# only if every strategy fails. Also normalises transport/trust defaults for downstream layers.
ob_resolve_home() {
  local script=${1:-} marker
  if [ -n "${OB_HOME:-}" ]; then :
  elif marker=$(ob_walk_up_marker); then
    [ -f "$marker/.openboard/project" ] && . "$marker/.openboard/project"
    [ -f "$marker/.openboard/local" ]   && . "$marker/.openboard/local"
    if [ -n "${OB_HOME:-}" ]; then
      case "$OB_HOME" in /*) ;; *) OB_HOME="$marker/$OB_HOME" ;; esac   # relative redirect -> absolute
    else
      OB_HOME="$marker"
    fi
  elif [ -n "$script" ] && [ -z "${OB_NO_FALLBACK:-}" ]; then
    # OB_NO_FALLBACK=1 disables this last resort (plugin installs set it: their own checkout
    # carries a dogfood board that must never silently receive a lost agent's writes)
    OB_HOME=$(ob_script_home "$script") || return 1
  else
    return 1
  fi
  : "${OB_BOARD_TRANSPORT:=local}"
  : "${OB_TRUST_LEVEL:=0}"
  export OB_HOME OB_BOARD_TRANSPORT OB_TRUST_LEVEL
}

# ---------------------------------------------------------------------------
# git transport (OB_BOARD_TRANSPORT=git; decision 0015). The board root is a git repo with an
# `origin` remote; every CLI command pulls before dispatch and auto-commits+pushes board writes
# after (board.sh wires both). Append-only one-file-per-message makes content merges conflict-
# free — only ref races remain, handled by pull --rebase + retry. Offline-tolerant: failures
# warn on stderr and leave the commit local; the next successful push syncs everything.
# Generated files (digest, inbox, cursors, probes) are per-node, NOT synced: each node rebuilds
# them, which removes the only realistic rebase-conflict source.
# ---------------------------------------------------------------------------
OB_GIT_TIMEOUT="${OB_GIT_TIMEOUT:-10}"
# shared board data only — everything else stays local to the node
OB_SYNC_PATHS="board/messages board/agents board/decisions tasks verifiers artifacts"

ob_git() { GIT_TERMINAL_PROMPT=0 timeout "$OB_GIT_TIMEOUT" git -C "$OB_HOME" "$@"; }
# identity ladder L1: author = the agent. Applied to commit AND rebase (replaying commits
# needs a committer too — a machine with no global git config would otherwise fail there).
ob_git_id() { ob_git -c user.name="${OB_AGENT:-openboard}" -c user.email="${OB_AGENT:-openboard}@openboard.local" "$@"; }

ob_git_pull() {
  [ "${OB_BOARD_TRANSPORT:-local}" = git ] || return 0
  ob_git_id pull --rebase -q >/dev/null 2>&1 || {
    ob_git rebase --abort >/dev/null 2>&1 || true   # 128 when no rebase in progress — harmless
    printf 'openboard: transport=git pull failed (offline? no upstream?) — using local state\n' >&2
  }
  return 0
}

ob_git_push() {
  [ "${OB_BOARD_TRANSPORT:-local}" = git ] || return 0
  local p add=() i
  for p in $OB_SYNC_PATHS; do [ -e "$OB_HOME/$p" ] && add+=("$p"); done
  [ ${#add[@]} -gt 0 ] || return 0
  ob_git add -- "${add[@]}" >/dev/null 2>&1 || true
  ob_git diff --cached --quiet 2>/dev/null && return 0    # nothing staged -> nothing to sync
  ob_git_id commit -q -m "board: ${OB_AGENT:-anon} @ $(date -u +%Y%m%dT%H%M%SZ)" >/dev/null 2>&1 || return 0
  for i in 1 2 3; do
    ob_git push -q >/dev/null 2>&1 && return 0
    ob_git_id pull --rebase -q >/dev/null 2>&1 || ob_git rebase --abort >/dev/null 2>&1 || true
  done
  printf 'openboard: transport=git push failed (3 tries) — committed locally, will sync on next write\n' >&2
  return 0
}
