#!/usr/bin/env bash
# Linux launcher for explicit native restore, package, and setup modes.

# Capture the load context before any caller environment can influence routing.
MAINFRAME_SOURCE_FILE=${BASH_SOURCE[0]:-}
MAINFRAME_TEMPORARY_DIRECTORY=''
MAINFRAME_CHILD_PID=''
MAINFRAME_SAVED_EXIT_TRAP=''
MAINFRAME_SAVED_HUP_TRAP=''
MAINFRAME_SAVED_INT_TRAP=''
MAINFRAME_SAVED_TERM_TRAP=''
MAINFRAME_TRAPS_INSTALLED=0

mainframe_usage() {
    cat <<'EOF'
Usage: bootstrap.sh [--dry-run] [--help] [-- BOOT_ARGUMENTS...]

Select and run the Linux boot.sh bootstrap. --dry-run only reports the route.
Use -- --restore ... or -- --packages ... from a reviewed checkout.
Use -- --setup-tools for prerequisite setup only (not a restore).
EOF
}

mainframe_platform() {
    uname -s
}

mainframe_dispatch() {
    local path=$1
    shift
    exec bash "$path" "$@"
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

mainframe_save_traps() {
    MAINFRAME_SAVED_EXIT_TRAP=$(trap -p EXIT)
    MAINFRAME_SAVED_HUP_TRAP=$(trap -p HUP)
    MAINFRAME_SAVED_INT_TRAP=$(trap -p INT)
    MAINFRAME_SAVED_TERM_TRAP=$(trap -p TERM)
}

mainframe_restore_traps() {
    if [[ -n "$MAINFRAME_SAVED_EXIT_TRAP" ]]; then eval "$MAINFRAME_SAVED_EXIT_TRAP"; else trap - EXIT; fi
    if [[ -n "$MAINFRAME_SAVED_HUP_TRAP" ]]; then eval "$MAINFRAME_SAVED_HUP_TRAP"; else trap - HUP; fi
    if [[ -n "$MAINFRAME_SAVED_INT_TRAP" ]]; then eval "$MAINFRAME_SAVED_INT_TRAP"; else trap - INT; fi
    if [[ -n "$MAINFRAME_SAVED_TERM_TRAP" ]]; then eval "$MAINFRAME_SAVED_TERM_TRAP"; else trap - TERM; fi
}

mainframe_cleanup_on_exit() {
    cleanup_mainframe_remote
    mainframe_restore_traps
}

mainframe_signal_exit() {
    local signal=$1
    local status=143
    case "$signal" in
        HUP) status=129 ;;
        INT) status=130 ;;
        TERM) status=143 ;;
    esac
    if [[ -n "$MAINFRAME_CHILD_PID" ]]; then
        kill -TERM "$MAINFRAME_CHILD_PID" 2>/dev/null || true
        wait "$MAINFRAME_CHILD_PID" 2>/dev/null || true
        MAINFRAME_CHILD_PID=''
    fi
    cleanup_mainframe_remote
    mainframe_restore_traps
    exit "$status"
}

mainframe_install_traps() {
    if ((MAINFRAME_TRAPS_INSTALLED)); then return; fi
    mainframe_save_traps
    MAINFRAME_TRAPS_INSTALLED=1
    trap mainframe_cleanup_on_exit EXIT
    trap 'mainframe_signal_exit HUP' HUP
    trap 'mainframe_signal_exit INT' INT
    trap 'mainframe_signal_exit TERM' TERM
}

mainframe_finish() {
    local status=$1
    cleanup_mainframe_remote
    mainframe_restore_traps
    MAINFRAME_TRAPS_INSTALLED=0
    return "$status"
}

mainframe_run() {
    local dry_run=0
    local -a boot_arguments=()
    while (($#)); do
        case "$1" in
            --dry-run) dry_run=1; shift ;;
            --help|-h) mainframe_usage; return 0 ;;
            --) shift; boot_arguments=("$@"); break ;;
            *) printf 'mainframe: unknown argument: %s\n' "$1" >&2; return 2 ;;
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
        mainframe_install_traps
        if ! mainframe_remote_source "$temporary_directory"; then
            printf 'mainframe: failed to download selected bootstrap.\n' >&2
            mainframe_finish 1
            return 1
        fi
        source_path="$temporary_directory/boot.sh"
    fi

    # Keep the launcher responsive to signals while the child is running.
    mainframe_install_traps
    mainframe_dispatch "$source_path" "${boot_arguments[@]}" &
    MAINFRAME_CHILD_PID=$!
    local status=0
    if wait "$MAINFRAME_CHILD_PID"; then
        status=0
    else
        status=$?
    fi
    MAINFRAME_CHILD_PID=''
    if ((status != 0)); then
        printf 'mainframe: Linux bootstrap failed (exit %s).\n' "$status" >&2
    fi
    mainframe_finish "$status"
    return "$status"
}

# A Bash -c payload has no source file, regardless of its chosen $0.
if [[ -z "${BASH_SOURCE[0]:-}" || "${BASH_SOURCE[0]}" == "$0" ]]; then
    mainframe_run "$@"
fi
