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
  elif [ -n "$script" ]; then
    OB_HOME=$(ob_script_home "$script") || return 1
  else
    return 1
  fi
  : "${OB_BOARD_TRANSPORT:=local}"
  : "${OB_TRUST_LEVEL:=0}"
  export OB_HOME OB_BOARD_TRANSPORT OB_TRUST_LEVEL
}
