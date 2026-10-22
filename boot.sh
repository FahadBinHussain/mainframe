#!/usr/bin/env bash
# Minimal Linux setup, not a restore of Windows machine-state archives.
set -euo pipefail

fail() { printf 'FATAL: %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == Linux ]] || fail 'boot.sh supports Linux only.'
[[ -r /etc/os-release ]] || fail 'Cannot identify Linux distribution: /etc/os-release is missing.'
# shellcheck source=/dev/null
. /etc/os-release
case " ${ID:-} ${ID_LIKE:-} " in
    *' debian '*|*' ubuntu '*) ;;
    *) fail "Unsupported Linux distribution: ${ID:-unknown}. This bootstrap supports Debian/Ubuntu and their derivatives only." ;;
esac
command -v apt-get >/dev/null || fail 'apt-get is required on this Debian/Ubuntu system.'
mainframe_dir="$HOME/Downloads/mainframe"
# Never replace or update an existing checkout (it may contain local work).
[[ ! -e "$mainframe_dir" ]] || fail "$mainframe_dir already exists. Review it manually; nothing has been changed."

printf 'mainframe: Linux -> Debian/Ubuntu native setup\n'
printf 'Installs git, curl, ca-certificates and clones source into %s.\n' "$mainframe_dir"
printf 'Does not restore Windows archives, accounts, browser state, services, or tasks.\n'
if [[ "$(id -u)" == 0 ]]; then
    elevate=()
else
    command -v sudo >/dev/null || fail 'sudo is required; rerun with appropriate privileges.'
    elevate=(sudo)
fi
"${elevate[@]}" apt-get update
"${elevate[@]}" apt-get install -y git curl ca-certificates
mkdir -p "$(dirname "$mainframe_dir")"
git clone https://github.com/FahadBinHussain/mainframe.git "$mainframe_dir"
printf 'mainframe: Linux tools and source ready. Windows restore was not run.\n'
