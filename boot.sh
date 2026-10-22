#!/usr/bin/env bash
# Native Linux entry point. No implicit setup or claim of Windows-state parity.
set -euo pipefail
fail() { printf 'FATAL: %s\n' "$*" >&2; exit 1; }
usage() {
    cat <<'EOF'
Usage: boot.sh --restore [restore.sh arguments]
       boot.sh --packages [linux_packages.py arguments]
       boot.sh --setup-tools
       boot.sh --help

Restore and package planning require a reviewed local checkout. Defaults are
read-only; recovery/installation require their own explicit action flags.
Windows-only state is reported as blocked, never silently skipped.
--setup-tools installs prerequisites and clones source; it is NOT a restore.
EOF
}
[[ "$(uname -s)" == Linux ]] || fail 'boot.sh supports Linux only.'
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
mode=${1:-}
if (($#)); then shift; fi
case "$mode" in
    --help|-h) usage; exit 0 ;;
    --restore)
        [[ -f "$script_dir/restore.sh" ]] || fail 'Restore requires a reviewed local checkout containing restore.sh. No download fallback was attempted.'
        exec bash "$script_dir/restore.sh" "$@"
        ;;
    --packages)
        [[ -f "$script_dir/linux_packages.py" ]] || fail 'Package restoration requires a reviewed local checkout containing linux_packages.py.'
        command -v python3 >/dev/null || fail 'Python 3 is required for Linux package planning.'
        exec python3 "$script_dir/linux_packages.py" "$@"
        ;;
    --setup-tools) (($# == 0)) || fail '--setup-tools accepts no extra arguments.' ;;
    '') usage >&2; fail 'Select --restore, --packages, or --setup-tools. Nothing has been changed.' ;;
    *) usage >&2; fail "Unknown mode: $mode" ;;
esac
[[ -r /etc/os-release ]] || fail 'Cannot identify Linux distribution: /etc/os-release is missing.'
# shellcheck source=/dev/null
. /etc/os-release
case " ${ID:-} ${ID_LIKE:-} " in
    *' debian '*|*' ubuntu '*) ;;
    *) fail "Unsupported Linux distribution: ${ID:-unknown}. Tool setup supports Debian/Ubuntu and their derivatives only." ;;
esac
command -v apt-get >/dev/null || fail 'apt-get is required on this Debian/Ubuntu system.'
mainframe_dir="$HOME/Downloads/mainframe"
[[ ! -e "$mainframe_dir" && ! -L "$mainframe_dir" ]] || fail "$mainframe_dir already exists. Review it manually; nothing has been changed."
printf 'mainframe: explicit Debian/Ubuntu prerequisite setup (NOT machine-state restore)\n'
if [[ "$(id -u)" == 0 ]]; then
    elevate=()
else
    command -v sudo >/dev/null || fail 'sudo is required; rerun with appropriate privileges.'
    elevate=(sudo)
fi
"${elevate[@]}" apt-get update
"${elevate[@]}" apt-get install -y git curl ca-certificates python3
python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' || fail 'Python 3.10+ is required. The distribution python3 package is too old or unavailable; provide a compatible runtime separately. Source preparation is incomplete.'
mkdir -p "$(dirname "$mainframe_dir")"
git clone https://github.com/FahadBinHussain/mainframe.git "$mainframe_dir"
printf 'mainframe: source ready. Review %s/docs/linux-restore-coverage.md\n' "$mainframe_dir"
printf 'Then run: bash %q --help\nNo backup has been restored.\n' "$mainframe_dir/restore.sh"
