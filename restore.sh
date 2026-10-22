#!/usr/bin/env bash
# Inventory by default; recovery writes only a NEW offline export tree.
set -euo pipefail
fail() { printf 'FATAL: %s\n' "$*" >&2; exit 2; }
[[ "$(uname -s)" == Linux ]] || fail 'restore.sh supports Linux only.'
command -v python3 >/dev/null || fail 'Python 3.10 or newer is required; no runtime was installed.'
python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' || fail 'Python 3.10 or newer is required.'
self_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
[[ -f "$self_dir/linux_restore.py" ]] || fail 'Missing sibling linux_restore.py; no download fallback.'
exec python3 "$self_dir/linux_restore.py" "$@"
