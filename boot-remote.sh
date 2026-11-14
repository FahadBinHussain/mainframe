#!/usr/bin/env bash
# mainframe universal restore, linux side. one paste:
#   curl -fsSL <link> | bash
# downloads boot.sh, asks quick/full (default full, like boot.ps1),
# then runs the live restore. MF_MODE=quick|full skips the prompt,
# MF_DRY_RUN=1 prints the restore command instead of running it.
#
# quick = machine state only (configs, skills, secrets, private repo),
# no package installs. full = everything, packages included.
# on a muse vm (/opt/muse exists) package installs do not apply, so
# full runs as quick with a loud note, and --muse-skills syncs the
# restored skills into ~/workspace/custom-skills.
set -euo pipefail
fail() { printf 'mainframe: %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == Linux ]] || fail "linux only (found $(uname -s)) - macOS is not supported yet, the restore is windows + debian/ubuntu only."

command -v curl >/dev/null || fail "curl is missing - install it, then rerun."
tmp="$(mktemp -d)" || fail "could not make a temp dir"
trap 'rm -rf "$tmp"' EXIT
curl -fsSL https://raw.githubusercontent.com/FahadBinHussain/mainframe/main/boot.sh \
    -o "$tmp/boot.sh" || fail "could not download boot.sh - check the network and rerun."
[[ -s "$tmp/boot.sh" ]] || fail "downloaded boot.sh is empty - check the network and rerun."

# muse vm? packages do not apply there, and skills need --muse-skills.
muse=0
[[ -d /opt/muse ]] && muse=1

mode="${MF_MODE:-}"
if [[ -z "$mode" ]]; then
    if [[ -r /dev/tty ]]; then
        printf '[F]ull = everything (packages + machine state)\n'
        printf '[Q]uick = essentials only (machine state, no package installs)\n'
        printf 'mode? [F]ull/[Q]uick (default F): '
        IFS= read -r pick </dev/tty || fail "could not read the mode"
        case "$pick" in
            q|Q|quick|Quick) mode=quick ;;
            *) mode=full ;;
        esac
    else
        fail "no terminal to ask quick/full and MF_MODE is not set - rerun with MF_MODE=quick or MF_MODE=full"
    fi
fi
case "$mode" in
    quick|full) ;;
    *) fail "MF_MODE must be quick or full (got '$mode')" ;;
esac

args=(--real --yes)
if [[ "$mode" == quick ]]; then
    args+=(--skip-packages)
elif [[ "$muse" == 1 ]]; then
    printf 'mainframe: muse vm - package installs do not apply here, full runs as quick\n'
    args+=(--skip-packages)
fi
[[ "$muse" == 1 ]] && args+=(--muse-skills)

printf 'mainframe: running boot.sh %s\n' "${args[*]}"
if [[ "${MF_DRY_RUN:-}" == 1 ]]; then
    printf 'mainframe: dry run - restore NOT started\n'
    exit 0
fi
bash "$tmp/boot.sh" "${args[@]}" || fail "restore failed - see the output above"
printf 'mainframe: restore finished\n'
