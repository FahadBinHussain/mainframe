#!/usr/bin/env bash
set -euo pipefail
root=$(mktemp -d)
trap 'rm -rf -- "$root"' EXIT
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cp "$repo/bootstrap.sh" "$root/bootstrap.sh"
export MOCK_ARGUMENTS="$root/arguments" MOCK_STATUS=0
cat > "$root/boot.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$MOCK_ARGUMENTS"
exit "$MOCK_STATUS"
EOF
bash "$root/bootstrap.sh" -- --restore --quick 'archive with spaces.zip' > "$root/output"
printf '%s\n' --restore --quick 'archive with spaces.zip' > "$root/expected"
cmp "$root/expected" "$MOCK_ARGUMENTS"
rm "$MOCK_ARGUMENTS"
bash "$root/bootstrap.sh" --dry-run -- --restore --quick missing.zip > "$root/output"
[[ ! -e "$MOCK_ARGUMENTS" ]]
export MOCK_STATUS=23
set +e
bash "$root/bootstrap.sh" -- --packages --help > "$root/output" 2>&1
status=$?
set -e
[[ $status == 23 ]]
printf 'PASS: 3 argument-forwarding checks; child was an inert fixture.\n'
