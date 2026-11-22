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
Usage: bootstrap.sh [--dry-run] [--bootstrap-link <url>] [--config-only] [--help] [-- BOOT_ARGUMENTS...]

Select and run the Linux boot.sh bootstrap. --dry-run only reports the route.
Use -- --restore ... or -- --packages ... from a reviewed checkout.
Use -- --setup-tools for prerequisite setup only (not a restore).
--bootstrap-link <url> downloads the config bundle from the relay
(permanent link from mainframe.ps1 vault bootstrap-link) and places it as
mainframe.config.json (0600) before the bootstrap runs. --config-only
places the config and stops (no bootstrap dispatched).
EOF
}

# One-link bootstrap: download the config bundle from the relay and
# place it as mainframe.config.json (0600, atomic). The link is
# permanent: GET is repeatable, so a failed download can simply be
# re-run. MAINFRAME_BOOTSTRAP_TEST_BUNDLE (a local file path) replaces
# the download - test hook only, never used in production.
mainframe_bootstrap_config() {
    local link=$1
    if [[ ! "$link" =~ ^https://[^/]+/bootstrap/[A-Za-z0-9_-]{22}$ ]]; then
        printf 'mainframe: not a bootstrap link: %s (expected https://<relay>/bootstrap/<22-char token>)\n' "$link" >&2
        return 2
    fi
    local profile_root=${MAINFRAME_PROFILE_ROOT:-$HOME/.config/mainframe}
    mkdir -p -- "$profile_root" || return
    local temp_file="$profile_root/.mainframe.config.json.tmp.$$.${RANDOM}"
    # 0600 from creation: the bundle holds the topic, so it must never sit
    # in the profile dir with default umask permissions, even briefly.
    : > "$temp_file" || return
    chmod 0600 -- "$temp_file" || { rm -f -- "$temp_file"; return 1; }
    if [[ -n "${MAINFRAME_BOOTSTRAP_TEST_BUNDLE:-}" ]]; then
        if ! cp -- "$MAINFRAME_BOOTSTRAP_TEST_BUNDLE" "$temp_file" 2>/dev/null; then
            rm -f -- "$temp_file"
            printf 'mainframe: test bundle not readable: %s\n' "$MAINFRAME_BOOTSTRAP_TEST_BUNDLE" >&2
            return 1
        fi
    else
        if ! curl --fail --show-error --silent --location "$link" --output "$temp_file"; then
            rm -f -- "$temp_file"
            printf 'mainframe: the bootstrap link download failed - check the link and your network, then re-run (the link is permanent, a failed download loses nothing).\n' >&2
            return 1
        fi
    fi
    # the relay validated the bundle at creation; this catches a corrupt or
    # truncated download (or an error page) before it becomes the config.
    if ! grep -q '"ntfyTopic"[[:space:]]*:[[:space:]]*"[a-z0-9]\{32\}"' "$temp_file"; then
        rm -f -- "$temp_file"
        printf 'mainframe: the downloaded bundle has no valid ntfyTopic - it is corrupt or not a config. re-run to retry the download; if it persists, the bundle itself is bad - re-push it from an existing machine (windows/mainframe.ps1 vault bootstrap-link -PushOnly) and re-run.\n' >&2
        return 1
    fi
    if command -v python3 >/dev/null 2>&1; then
        if ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$temp_file" 2>/dev/null; then
            rm -f -- "$temp_file"
            printf 'mainframe: the downloaded bundle is not valid JSON. re-run to retry the download; if it persists, the bundle itself is bad - re-push it from an existing machine (windows/mainframe.ps1 vault bootstrap-link -PushOnly) and re-run.\n' >&2
            return 1
        fi
    fi
    mv -f -- "$temp_file" "$profile_root/mainframe.config.json" || { rm -f -- "$temp_file"; return 1; }
    printf 'mainframe: bootstrap config placed at %s (0600)\n' "$profile_root/mainframe.config.json"
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
    local config_only=0
    local bootstrap_link=''
    local -a boot_arguments=()
    while (($#)); do
        case "$1" in
            --dry-run) dry_run=1; shift ;;
            --config-only) config_only=1; shift ;;
            --bootstrap-link)
                if (($# < 2)); then printf 'mainframe: --bootstrap-link needs a value\n' >&2; return 2; fi
                bootstrap_link=$2; shift 2 ;;
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
        if [[ -n "$bootstrap_link" ]]; then
            printf 'Dry run: would download the bootstrap bundle from the relay (no download happens on a dry run).\n'
        fi
        return 0
    fi

    if [[ -n "$bootstrap_link" ]]; then
        mainframe_bootstrap_config "$bootstrap_link"
        local cfg_status=$?
        if ((cfg_status != 0)); then
            return "$cfg_status"
        fi
        if ((config_only)); then
            printf 'mainframe: config placed, --config-only: no bootstrap dispatched.\n'
            return 0
        fi
    elif ((config_only)); then
        printf 'mainframe: --config-only needs --bootstrap-link (there is nothing to place without a link).\n' >&2
        return 2
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
