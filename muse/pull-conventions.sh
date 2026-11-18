#!/usr/bin/env bash
# pull-conventions.sh — pull the shared manager conventions from mainframe
# into this Muse account's workspace (~/workspace/manager/CONVENTIONS.md).
# run at restore time and whenever conventions change.
# usage: ./pull-conventions.sh [mainframe-clone-path]
# the clone defaults to ~/Downloads/mainframe (the standard clone location).
set -euo pipefail

CLONE="${1:-$HOME/Downloads/mainframe}"
DEST="$HOME/workspace/manager/CONVENTIONS.md"

if [ ! -d "$CLONE/.git" ]; then
  echo "FATAL: no mainframe clone at $CLONE" >&2
  echo "clone it first: git clone https://github.com/FahadBinHussain/mainframe.git $CLONE" >&2
  exit 1
fi

git -C "$CLONE" pull --ff-only || {
  echo "FATAL: git pull failed in $CLONE — fix the clone, then re-run" >&2
  exit 1
}

SRC="$CLONE/muse/CONVENTIONS.md"
if [ ! -f "$SRC" ]; then
  echo "FATAL: $SRC missing after pull" >&2
  exit 1
fi

mkdir -p "$(dirname "$DEST")"
cp "$SRC" "$DEST"
echo "conventions pulled: $SRC -> $DEST ($(wc -l < "$DEST") lines)"
