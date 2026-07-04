#!/usr/bin/env bash
# install.sh — put the OpenBoard CLIs on your PATH via symlinks.
#
#   git clone <repo> openboard && cd openboard && ./install.sh
#   ./install.sh --prefix ~/.local          # default; binaries land in <prefix>/bin
#   ./install.sh --uninstall
#
# Symlinks resolve back to this checkout (bin/ob-common.sh follows symlink chains),
# so `git pull` upgrades in place. Nothing is copied; uninstall removes only our links.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PREFIX="$HOME/.local"
UNINSTALL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --prefix)    PREFIX=${2:?}; shift 2 ;;
    --uninstall) UNINSTALL=1; shift ;;
    *) echo "usage: install.sh [--prefix <dir>] [--uninstall]" >&2; exit 2 ;;
  esac
done
BIN="$PREFIX/bin"
TOOLS="board board-join board-view board-watch board-hook"

if [ "$UNINSTALL" -eq 1 ]; then
  for t in $TOOLS; do
    if [ -L "$BIN/$t" ] && [ "$(readlink -f "$BIN/$t" 2>/dev/null)" = "$(readlink -f "$HERE/bin/$t")" ]; then
      rm -f "$BIN/$t"; echo "removed $BIN/$t"
    fi
  done
  exit 0
fi

mkdir -p "$BIN"
for t in $TOOLS; do
  ln -sf "$HERE/bin/$t" "$BIN/$t"
  echo "installed $BIN/$t -> $HERE/bin/$t"
done

case ":$PATH:" in
  *":$BIN:"*) ;;
  *) printf '\nNOTE: %s is not on your PATH. Add:\n  export PATH="%s:$PATH"\n' "$BIN" "$BIN" ;;
esac

cat <<EOF

openboard $(cat "$HERE/VERSION" 2>/dev/null || echo unknown) installed.

next:
  board init <dir>            # make a directory an OpenBoard root
  cd <dir> && board-join <your-name> <role>    # join it (worktree + register + doctor)
  board doctor                # verify everything is green
EOF
