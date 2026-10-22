#!/usr/bin/env bash
# All children and system-changing commands are inert doubles in a temp tree.
set -euo pipefail
root=$(mktemp -d)
trap 'rm -rf -- "$root"' EXIT
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
mkdir -p "$root/bin" "$root/checkout" "$root/home"
cp "$repo/boot.sh" "$root/checkout/boot.sh"
export HOME="$root/home" MOCK_LOG="$root/commands" MOCK_PLATFORM=Linux
for command in apt-get git sudo; do
    cat > "$root/bin/$command" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${0##*/}" "$@" >> "$MOCK_LOG"
exit 0
EOF
    chmod +x "$root/bin/$command"
done
cat > "$root/bin/uname" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$MOCK_PLATFORM"
EOF
cat > "$root/bin/id" <<'EOF'
#!/usr/bin/env bash
printf '0\n'
EOF
chmod +x "$root/bin/uname" "$root/bin/id"
export PATH="$root/bin:$PATH"
checks=0
pass() { checks=$((checks + 1)); }
expect_fail() {
    if bash "$root/checkout/boot.sh" "$@" > "$root/output" 2>&1; then
        printf 'FAIL: expected failure\n' >&2; exit 1
    fi
    [[ ! -e "$MOCK_LOG" ]] || { printf 'FAIL: unexpected system command\n' >&2; exit 1; }
    pass
}
expect_fail
expect_fail --unknown
expect_fail --restore --help
expect_fail --packages --help
expect_fail --setup-tools --unexpected
bash "$root/checkout/boot.sh" --help > "$root/output"
[[ ! -e "$MOCK_LOG" ]]; pass
MOCK_PLATFORM=Darwin expect_fail --setup-tools
cat > "$root/checkout/restore.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$HOME/restore-arguments"
exit 23
EOF
set +e
bash "$root/checkout/boot.sh" --restore --quick 'archive with spaces.zip' > "$root/output" 2>&1
status=$?
set -e
[[ $status == 23 ]]; pass
printf '%s\n' --quick 'archive with spaces.zip' > "$root/expected"
cmp "$root/expected" "$HOME/restore-arguments"; pass
[[ ! -e "$MOCK_LOG" ]]; pass
# Existing and dangling-symlink clone targets must fail before any apt invocation.
mkdir -p "$HOME/Downloads/mainframe"
expect_fail --setup-tools
rmdir "$HOME/Downloads/mainframe"
ln -s "$root/nonexistent" "$HOME/Downloads/mainframe"
expect_fail --setup-tools
rm "$HOME/Downloads/mainframe"
# Even an apparently successful apt install must not hide an old Python runtime.
cat > "$root/bin/python3" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' python3 "$@" >> "$MOCK_LOG"
exit "${MOCK_PYTHON_STATUS:-0}"
EOF
chmod +x "$root/bin/python3"
if MOCK_PYTHON_STATUS=1 bash "$root/checkout/boot.sh" --setup-tools > "$root/output" 2>&1; then
    printf 'FAIL: incompatible Python accepted\n' >&2; exit 1
fi
grep -Fq 'Python 3.10+' "$root/output"; pass
! grep -Fxq git "$MOCK_LOG"; pass
rm "$MOCK_LOG"
bash "$root/checkout/boot.sh" --setup-tools > "$root/output" 2>&1
grep -Fq "$HOME/Downloads/mainframe/docs/linux-restore-coverage.md" "$root/output"; pass
grep -Fq "bash $HOME/Downloads/mainframe/restore.sh --help" "$root/output"; pass
grep -Fq 'sys.version_info >= (3, 10)' "$MOCK_LOG"; pass
printf 'PASS: %s offline boot checks; no package installation or restore executed.\n' "$checks"
