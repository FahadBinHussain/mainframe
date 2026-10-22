#!/usr/bin/env bash
# Linux launcher for the native bootstrap only; Windows restore is not in scope.

# Capture the load context before any caller environment can influence routing.
MAINFRAME_SOURCE_FILE=${BASH_SOURCE[0]:-}
MAINFRAME_TEMPORARY_DIRECTORY=''

mainframe_usage() {
    cat <<'EOF'
Usage: bootstrap.sh [--dry-run] [--help]

Select and run the Linux boot.sh bootstrap. --dry-run only reports the route.
EOF
}

mainframe_platform() {
    uname -s
}

mainframe_dispatch() {
    local path=$1
    bash "$path"
}

mainframe_remote_source() {
    local destination=$1
    curl --fail --show-error --silent --location \
        'https://raw.githubusercontent.com/FahadBinHussain/mainframe/main/boot.sh' \
        --output "$destination/boot.sh"
}

cleanup_mainframe_remote() {
    if [[ -n "$MAINFRAME_TEMPORARY_DIRECTORY" ]]; then
        rm -rf -- "$MAINFRAME_TEMPORARY_DIRECTORY" || return
        MAINFRAME_TEMPORARY_DIRECTORY=''
    fi
}

mainframe_signal_exit() {
    local signal=$1
    local status=143
    case "$signal" in
        HUP) status=129 ;;
        INT) status=130 ;;
        TERM) status=143 ;;
    esac
    cleanup_mainframe_remote
    trap - EXIT HUP INT TERM
    exit "$status"
}

mainframe_run() {
    local dry_run=0
    local arg
    for arg in "$@"; do
        case "$arg" in
            --dry-run) dry_run=1 ;;
            --help|-h) mainframe_usage; return 0 ;;
            '') printf 'mainframe: unknown argument: %s\n' "$arg" >&2; return 2 ;;
            *) printf 'mainframe: unknown argument: %s\n' "$arg" >&2; return 2 ;;
        esac
    done

    local platform
    platform=$(mainframe_platform) || return
    if [[ "$platform" != Linux ]]; then
        printf 'mainframe: unsupported operating system: %s (Linux only)\n' "$platform" >&2
        return 1
    fi
    printf 'mainframe: selected Linux -> boot.sh\n'
    if ((dry_run)); then
        printf 'Dry run: no downloads, bootstrap execution, or machine changes.\n'
        return 0
    fi

    local source_path=''
    local temporary_directory=''
    if [[ -n "$MAINFRAME_SOURCE_FILE" ]]; then
        local source_directory
        source_directory=$(cd -- "$(dirname -- "$MAINFRAME_SOURCE_FILE")" && pwd) || return
        source_path="$source_directory/boot.sh"
        if [[ ! -f "$source_path" ]]; then
            printf 'mainframe: selected bootstrap is missing: %s\n' "$source_path" >&2
            return 1
        fi
    else
        temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/mainframe-launch.XXXXXX") || return
        MAINFRAME_TEMPORARY_DIRECTORY=$temporary_directory
        trap cleanup_mainframe_remote EXIT
        trap 'mainframe_signal_exit HUP' HUP
        trap 'mainframe_signal_exit INT' INT
        trap 'mainframe_signal_exit TERM' TERM
        if ! mainframe_remote_source "$temporary_directory"; then
            printf 'mainframe: failed to download selected bootstrap.\n' >&2
            cleanup_mainframe_remote
            trap - EXIT HUP INT TERM
            return 1
        fi
        source_path="$temporary_directory/boot.sh"
    fi

    if mainframe_dispatch "$source_path"; then
        if [[ -n "$temporary_directory" ]]; then
            cleanup_mainframe_remote || return
            trap - EXIT HUP INT TERM
        fi
        return 0
    else
        local status=$?
        printf 'mainframe: Linux bootstrap failed (exit %s).\n' "$status" >&2
        if [[ -n "$temporary_directory" ]]; then
            cleanup_mainframe_remote || return
            trap - EXIT HUP INT TERM
        fi
        return "$status"
    fi
}

# A Bash -c payload has no source file, regardless of its chosen $0.
if [[ -z "${BASH_SOURCE[0]:-}" || "${BASH_SOURCE[0]}" == "$0" ]]; then
    mainframe_run "$@"
fi
