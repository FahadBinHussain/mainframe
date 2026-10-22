#!/usr/bin/env bash
# No native bootstrap is executed here; all dispatch and HTTP operations are inert doubles.
set -u

TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/mainframe-bootstrap-tests.XXXXXX")
trap 'rm -rf -- "$TEST_ROOT"' EXIT
LAUNCHER=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/bootstrap.sh

checks=0
failures=0
assert_true() {
    if [[ $1 -eq 0 ]]; then
        printf 'FAIL: %s\n' "$2" >&2
        failures=$((failures + 1))
    else
        checks=$((checks + 1))
    fi
}
assert_contains() { if [[ $1 == *"$2"* ]]; then printf '1'; else printf '0'; fi; }

# An environment value must not change the source context captured while loading.
export MAINFRAME_SOURCE_FILE="$TEST_ROOT/not-the-launcher.sh"
# shellcheck source=/dev/null
source "$LAUNCHER"

reset_doubles() {
    test_platform=Linux
    downloads=0
    dispatches=0
    dispatch_path=''
    dispatch_status=0
    rm -f "$TEST_ROOT/dispatch.path"
}
curl() { downloads=$((downloads + 1)); return 99; }
uname() { printf '%s\n' "$test_platform"; }
mainframe_dispatch() {
    dispatches=$((dispatches + 1))
    dispatch_path=$1
    printf '%s' "$1" > "$TEST_ROOT/dispatch.path"
    return "$dispatch_status"
}

bash -n "$LAUNCHER"; syntax_status=$?
assert_true "$((syntax_status == 0))" 'launcher passes bash -n'
reset_doubles
help_file="$TEST_ROOT/help.txt"
mainframe_run --help >"$help_file" 2>&1; status=$?
help_output=$(cat "$help_file")
assert_true "$((status == 0))" 'help succeeds'
assert_true "$(assert_contains "$help_output" 'Usage: bootstrap.sh')" 'help is descriptive'
assert_true "$((downloads == 0))" 'help does not download'
assert_true "$((dispatches == 0))" 'help does not dispatch'
reset_doubles
unknown_file="$TEST_ROOT/unknown.txt"
mainframe_run --wat >"$unknown_file" 2>&1; status=$?
unknown_output=$(cat "$unknown_file")
assert_true "$((status == 2))" 'unknown argument is rejected'
assert_true "$(assert_contains "$unknown_output" 'unknown argument')" 'unknown argument names itself'

# Local route with spaces, local dry-run, missing child, and unsupported OS.
local_dir="$TEST_ROOT/local fixture with spaces"
mkdir -p "$local_dir"
printf '# inert local fixture\n' > "$local_dir/boot.sh"
MAINFRAME_SOURCE_FILE="$local_dir/bootstrap.sh"
reset_doubles
preview_file="$TEST_ROOT/local-preview.txt"
mainframe_run --dry-run >"$preview_file" 2>&1; status=$?
preview=$(cat "$preview_file")
assert_true "$((status == 0))" 'local dry-run succeeds'
assert_true "$(assert_contains "$preview" 'mainframe: selected Linux -> boot.sh')" 'Linux selection message is exact'
assert_true "$((downloads == 0))" 'local dry-run does not download'
assert_true "$((dispatches == 0))" 'local dry-run does not dispatch'
reset_doubles
caller_exit_trap=$(trap -p EXIT)
mainframe_run >"$TEST_ROOT/local-run.txt" 2>&1; status=$?
assert_true "$((status == 0))" 'local route succeeds'
assert_true "$([[ -f "$TEST_ROOT/dispatch.path" ]] && echo 1 || echo 0)" 'local route dispatches once'
dispatch_path=$(cat "$TEST_ROOT/dispatch.path")
assert_true "$(assert_contains "$dispatch_path" 'local fixture with spaces/boot.sh')" 'local route preserves spaces'
assert_true "$((downloads == 0))" 'local route does not download'
assert_true "$([[ "$(trap -p EXIT)" == "$caller_exit_trap" ]] && echo 1 || echo 0)" 'local dispatch preserves caller cleanup trap'
reset_doubles; dispatch_status=23
mainframe_run >"$TEST_ROOT/local-failure.txt" 2>&1; status=$?
assert_true "$((status == 23))" 'local child nonzero status propagates'
rm -f "$local_dir/boot.sh"
reset_doubles
mainframe_run >"$TEST_ROOT/missing.txt" 2>&1; status=$?
assert_true "$((status != 0))" 'missing local child fails'
assert_true "$((downloads == 0))" 'missing local child has no network fallback'
MAINFRAME_SOURCE_FILE="$local_dir/bootstrap.sh"
reset_doubles
test_platform=Darwin
mainframe_run >"$TEST_ROOT/unsupported.txt" 2>&1; status=$?
assert_true "$((status != 0))" 'unsupported OS fails'
assert_true "$((dispatches == 0))" 'unsupported OS does not dispatch'
assert_true "$((downloads == 0))" 'unsupported OS does not download'

# Sourced remote calls must restore all caller traps on every return path.
saved_remote_source=$(declare -f mainframe_remote_source)
mainframe_remote_source() { return "$download_status"; }
MAINFRAME_SOURCE_FILE=''
trap ':' HUP INT TERM
before_traps=$(trap -p EXIT HUP INT TERM)
for outcome in success download-failure child-failure; do
    reset_doubles
    download_status=0
    case "$outcome" in
        download-failure) download_status=7 ;;
        child-failure) dispatch_status=23 ;;
    esac
    mainframe_run >"$TEST_ROOT/traps-$outcome.txt" 2>&1; status=$?
    assert_true "$([[ "$(trap -p EXIT HUP INT TERM)" == "$before_traps" ]] && echo 1 || echo 0)" "remote $outcome restores all caller traps"
    assert_true "$([[ -z "$MAINFRAME_TEMPORARY_DIRECTORY" ]] && echo 1 || echo 0)" "remote $outcome cleans temporary directory"
done
trap - HUP INT TERM
eval "$saved_remote_source"

# External command doubles used by actual `bash -c "$payload" --` integration tests.
MOCK_BIN="$TEST_ROOT/mock-bin"
mkdir -p "$MOCK_BIN"
MOCK_UNAME_LOG="$TEST_ROOT/uname.log"
MOCK_CURL_LOG="$TEST_ROOT/curl.args"
MOCK_CURL_FIXTURE="$TEST_ROOT/remote-boot.sh"
MOCK_BOOT_MARKER="$TEST_ROOT/boot-ran.marker"
printf '# inert downloaded fixture\nprintf %%s remote > "$MOCK_BOOT_MARKER"\nif [[ ${MOCK_BOOT_WAIT:-0} == 1 ]]; then trap '\''printf %%s term > "$MOCK_BOOT_TERM_MARKER"; exit 143'\'' TERM; while :; do sleep 1; done; fi\nexit "${MOCK_BOOT_STATUS:-0}"\n' > "$MOCK_CURL_FIXTURE"
cat > "$MOCK_BIN/uname" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' Linux
EOF
cat > "$MOCK_BIN/curl" <<'EOF'
#!/usr/bin/env bash
: "${MOCK_CURL_LOG:?}"
printf '%s\n' "$@" >> "$MOCK_CURL_LOG"
out=''
while (($#)); do
    if [[ $1 == --output ]]; then out=$2; shift 2; else shift; fi
done
[[ -n "$out" ]] || exit 64
printf '%s\n' "$out" > "${MOCK_CURL_LOG}.output"
if [[ ${MOCK_CURL_PARTIAL:-0} == 1 ]]; then
    printf '%s\n' partial > "$out"
fi
if [[ ${MOCK_CURL_STATUS:-0} != 0 ]]; then exit "$MOCK_CURL_STATUS"; fi
cp -- "$MOCK_CURL_FIXTURE" "$out"
if [[ ${MOCK_CURL_WAIT:-0} == 1 ]]; then sleep 1; fi
EOF
chmod +x "$MOCK_BIN/uname" "$MOCK_BIN/curl"
payload=$(cat "$LAUNCHER")
mock_path="$MOCK_BIN:$PATH"

# Bash -c supplies $0=-- and an empty BASH_SOURCE[0]; the launcher must run.
rm -f "$MOCK_CURL_LOG" "$MOCK_CURL_LOG.output" "$MOCK_BOOT_MARKER"
subprocess_output="$TEST_ROOT/subprocess-output.txt"
PATH="$mock_path" MAINFRAME_SOURCE_FILE="$TEST_ROOT/evil/bootstrap.sh" \
    MOCK_CURL_LOG="$MOCK_CURL_LOG" MOCK_CURL_FIXTURE="$MOCK_CURL_FIXTURE" \
    MOCK_BOOT_MARKER="$MOCK_BOOT_MARKER" bash -c "$payload" -- >"$subprocess_output" 2>&1
status=$?
assert_true "$((status == 0))" 'Bash -c remote route succeeds'
assert_true "$([[ -e "$MOCK_BOOT_MARKER" ]] && echo 1 || echo 0)" 'downloaded inert fixture dispatches'
remote_temp=$(cat "$MOCK_CURL_LOG.output")
assert_true "$([[ ! -e "$(dirname -- "$remote_temp")" ]] && echo 1 || echo 0)" 'subprocess remote temp is cleaned'
assert_true "$(if grep -Fxq -- '--fail' "$MOCK_CURL_LOG"; then echo 1; else echo 0; fi)" 'curl receives --fail'
assert_true "$(if grep -Fxq -- '--show-error' "$MOCK_CURL_LOG"; then echo 1; else echo 0; fi)" 'curl receives --show-error'
assert_true "$(if grep -Fxq -- '--silent' "$MOCK_CURL_LOG"; then echo 1; else echo 0; fi)" 'curl receives --silent'
assert_true "$(if grep -Fxq -- '--location' "$MOCK_CURL_LOG"; then echo 1; else echo 0; fi)" 'curl receives --location'
assert_true "$(if grep -Fxq -- 'https://raw.githubusercontent.com/FahadBinHussain/mainframe/main/boot.sh' "$MOCK_CURL_LOG"; then echo 1; else echo 0; fi)" 'curl receives exact boot.sh URI'
assert_true "$(if grep -Fxq -- '--output' "$MOCK_CURL_LOG"; then echo 1; else echo 0; fi)" 'curl receives --output'

# Remote dry-run is also tested in a real subprocess and cannot invoke curl.
rm -f "$MOCK_CURL_LOG" "$MOCK_CURL_LOG.output" "$MOCK_BOOT_MARKER"
PATH="$mock_path" MOCK_CURL_LOG="$MOCK_CURL_LOG" MOCK_CURL_FIXTURE="$MOCK_CURL_FIXTURE" \
    MOCK_BOOT_MARKER="$MOCK_BOOT_MARKER" bash -c "$payload" -- --dry-run >"$TEST_ROOT/subprocess-dry-run.txt" 2>&1
status=$?
assert_true "$((status == 0))" 'Bash -c --dry-run succeeds'
assert_true "$([[ ! -e "$MOCK_CURL_LOG" ]] && echo 1 || echo 0)" 'subprocess dry-run does not download'
assert_true "$([[ ! -e "$MOCK_BOOT_MARKER" ]] && echo 1 || echo 0)" 'subprocess dry-run does not dispatch'

# A partial failed download must leave no temporary directory behind.
rm -f "$MOCK_CURL_LOG" "$MOCK_CURL_LOG.output"
PATH="$mock_path" MOCK_CURL_LOG="$MOCK_CURL_LOG" MOCK_CURL_FIXTURE="$MOCK_CURL_FIXTURE" \
    MOCK_CURL_PARTIAL=1 MOCK_CURL_STATUS=7 bash -c "$payload" -- >"$TEST_ROOT/partial.txt" 2>&1
status=$?
partial_temp=$(cat "$MOCK_CURL_LOG.output")
assert_true "$((status != 0))" 'partial download failure propagates'
assert_true "$([[ ! -e "$(dirname -- "$partial_temp")" ]] && echo 1 || echo 0)" 'partial download temp is cleaned'

# A failed inert child must propagate its status and clean the download directory.
rm -f "$MOCK_CURL_LOG" "$MOCK_CURL_LOG.output" "$MOCK_BOOT_MARKER"
PATH="$mock_path" MOCK_CURL_LOG="$MOCK_CURL_LOG" MOCK_CURL_FIXTURE="$MOCK_CURL_FIXTURE" \
    MOCK_BOOT_MARKER="$MOCK_BOOT_MARKER" MOCK_BOOT_STATUS=23 bash -c "$payload" -- >"$TEST_ROOT/child-failure.txt" 2>&1
status=$?
child_temp=$(cat "$MOCK_CURL_LOG.output")
assert_true "$((status == 23))" 'remote child nonzero status propagates'
assert_true "$([[ ! -e "$(dirname -- "$child_temp")" ]] && echo 1 || echo 0)" 'remote child failure temp is cleaned'

# TERM must clean the remote temp and terminate nonzero, rather than continue to boot.
rm -f "$MOCK_CURL_LOG" "$MOCK_CURL_LOG.output" "$MOCK_BOOT_MARKER"
PATH="$mock_path" MOCK_CURL_LOG="$MOCK_CURL_LOG" MOCK_CURL_FIXTURE="$MOCK_CURL_FIXTURE" \
    MOCK_BOOT_MARKER="$MOCK_BOOT_MARKER" MOCK_CURL_WAIT=1 bash -c "$payload" -- >"$TEST_ROOT/signal.txt" 2>&1 &
signal_pid=$!
for _ in {1..50}; do [[ -s "$MOCK_CURL_LOG.output" ]] && break; sleep 0.02; done
kill -TERM "$signal_pid" 2>/dev/null || true
wait "$signal_pid"; signal_status=$?
signal_temp=$(cat "$MOCK_CURL_LOG.output")
assert_true "$((signal_status != 0))" 'TERM exits nonzero'
assert_true "$([[ ! -e "$(dirname -- "$signal_temp")" ]] && echo 1 || echo 0)" 'TERM cleans remote temp'
assert_true "$([[ ! -e "$MOCK_BOOT_MARKER" ]] && echo 1 || echo 0)" 'TERM does not dispatch downloaded fixture'

# TERM while an inert child is running must reach the child before cleanup.
rm -f "$MOCK_CURL_LOG" "$MOCK_CURL_LOG.output" "$MOCK_BOOT_MARKER" "$TEST_ROOT/term-child.marker"
PATH="$mock_path" MOCK_CURL_LOG="$MOCK_CURL_LOG" MOCK_CURL_FIXTURE="$MOCK_CURL_FIXTURE" \
    MOCK_BOOT_MARKER="$MOCK_BOOT_MARKER" MOCK_BOOT_TERM_MARKER="$TEST_ROOT/term-child.marker" \
    MOCK_BOOT_WAIT=1 bash -c "$payload" -- >"$TEST_ROOT/child-signal.txt" 2>&1 &
child_signal_pid=$!
for _ in {1..50}; do [[ -s "$MOCK_BOOT_MARKER" ]] && break; sleep 0.02; done
kill -TERM "$child_signal_pid" 2>/dev/null || true
wait "$child_signal_pid"; child_signal_status=$?
assert_true "$((child_signal_status != 0))" 'TERM during child exits nonzero'
assert_true "$([[ -f "$TEST_ROOT/term-child.marker" ]] && echo 1 || echo 0)" 'TERM is forwarded to running child'
child_signal_temp=$(cat "$MOCK_CURL_LOG.output")
assert_true "$([[ ! -e "$(dirname -- "$child_signal_temp")" ]] && echo 1 || echo 0)" 'child TERM waits before cleaning remote temp'

launcher_text=$(cat "$LAUNCHER")
assert_true "$(assert_contains "$launcher_text" 'mainframe_signal_exit')" 'signal handler is installed'
assert_true "$(assert_contains "$launcher_text" 'MAINFRAME_SOURCE_FILE=${BASH_SOURCE[0]:-}')" 'source path is captured unconditionally'

if ((failures)); then
    printf 'FAIL: %d of %d checks failed.\n' "$failures" "$checks" >&2
    exit 1
fi
printf 'PASS: %d checks; no native bootstrap was executed.\n' "$checks"
