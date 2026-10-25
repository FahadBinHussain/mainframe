#!/usr/bin/env bash
# Real-mode activation test: synthetic quick zip -> live (temp) HOME.
# apt-get is mocked; git stays real because the git-config converter
# parses with `git config --file -` (stdin only, no repo touched).
set -euo pipefail
root=$(mktemp -d)
trap 'rm -rf -- "$root"' EXIT
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
mkdir -p "$root/bin" "$root/home" "$root/backup"
for command in apt-get sudo; do
    cat > "$root/bin/$command" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$root/bin/$command"
done
export PATH="$root/bin:$PATH" HOME="$root/home"
python3 - "$root/backup" <<'EOF'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1] + '/mainframe-quick.zip', 'w') as z:
    z.writestr('.gitconfig', '[core]\n\tautocrlf = true\n[color]\n\tui = auto\n')
EOF
printf '[user]\n\tname = Old Name\n' > "$root/home/.gitconfig"
python3 "$repo/linux_real.py" --skip-vault --skip-packages \
    --backup-root "$root/backup" --yes > "$root/output" 2>&1
grep -Fq 'autocrlf = input' "$root/home/.gitconfig" || {
    printf 'FAIL: converted gitconfig not activated\n' >&2
    cat "$root/output" >&2; exit 1; }
old=$(find "$root/home/.local/share/mainframe/restore-backup" -name '.gitconfig' -print -quit)
[[ -n "$old" ]] || { printf 'FAIL: overwritten file was not backed up\n' >&2; exit 1; }
grep -Fq 'Old Name' "$old" || { printf 'FAIL: backup content wrong\n' >&2; exit 1; }
printf 'PASS: real-mode activation into live HOME with backup\n'
