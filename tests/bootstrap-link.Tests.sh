#!/usr/bin/env bash
# One-link bootstrap: the config bundle downloads and lands as
# mainframe.config.json (0600). No network, no real bootstrap: curl and
# the dispatch are inert doubles, and the bundle is an obvious fake.
set -u

TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/mainframe-bootstrap-link-tests.XXXXXX")
trap 'rm -rf -- "$TEST_ROOT"' EXIT
LAUNCHER=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/bootstrap.sh
FAKE_HOME="$TEST_ROOT/home"
mkdir -p -- "$FAKE_HOME"

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
assert_file() { if [[ -f "$1" ]]; then printf '1'; else printf '0'; fi; }
assert_no_file() { if [[ ! -e "$1" ]]; then printf '1'; else printf '0'; fi; }

FAKE_TOPIC='zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz'
FAKE_CONFIG="$TEST_ROOT/bundle.json"
printf '{"bitwardenEmail":"test@example.invalid","ntfyTopic":"%s","ntfyServer":"https://relay.example.invalid/ntfy","pagesBase":"https://example.invalid","vaultTtlMinutes":60}' "$FAKE_TOPIC" > "$FAKE_CONFIG"
BAD_CONFIG="$TEST_ROOT/bad-bundle.json"
printf '{"pagesBase":"https://example.invalid"}' > "$BAD_CONFIG"
LINK="https://relay.example.invalid/bootstrap/AAAAAAAAAAAAAAAAAAAAAA"
PLACED="$FAKE_HOME/.config/mainframe/mainframe.config.json"

export MAINFRAME_SOURCE_FILE="$TEST_ROOT/not-the-launcher.sh"
# shellcheck source=/dev/null
source "$LAUNCHER"

downloads=0
curl() {
    downloads=$((downloads + 1))
    local out=''
    local prev=''
    for arg in "$@"; do
        if [[ "$prev" == '--output' ]]; then out=$arg; fi
        prev=$arg
    done
    if [[ -n "$out" ]]; then cp -- "$FAKE_CONFIG" "$out"; fi
    return 0
}
# the dispatch runs backgrounded, so the double records via a file.
mainframe_dispatch() {
    printf '%s' "$1" > "$TEST_ROOT/dispatch.path"
    return 0
}
reset_state() {
    downloads=0
    rm -f "$TEST_ROOT/dispatch.path"
    rm -rf -- "$FAKE_HOME/.config"
    unset MAINFRAME_BOOTSTRAP_TEST_BUNDLE
    unset MAINFRAME_PROFILE_ROOT
}

bash -n "$LAUNCHER"; syntax_status=$?
assert_true "$((syntax_status == 0))" 'launcher passes bash -n'
export HOME="$FAKE_HOME"

# 1. --config-only with the test-bundle hook: config lands 0600, values
#    intact, no download, no dispatch, no temp files left behind.
reset_state
export MAINFRAME_BOOTSTRAP_TEST_BUNDLE="$FAKE_CONFIG"
out_file="$TEST_ROOT/out1.txt"
mainframe_run --bootstrap-link "$LINK" --config-only >"$out_file" 2>&1; status=$?
out=$(cat "$out_file")
assert_true "$((status == 0))" 'config-only succeeds'
assert_true "$(assert_contains "$out" 'bootstrap config placed')" 'config-only announces the placement'
assert_true "$(assert_file "$PLACED")" 'config lands in the profile root'
if cmp -s "$PLACED" "$FAKE_CONFIG"; then same=1; else same=0; fi
assert_true "$same" 'config lands byte-identical'
mode=$(stat -c %a "$PLACED" 2>/dev/null || echo '')
assert_true "$((mode == 600))" 'config lands mode 0600'
leftovers=$(find "$FAKE_HOME/.config/mainframe" -mindepth 1 ! -name 'mainframe.config.json' | wc -l)
assert_true "$((leftovers == 0))" 'no temp files left behind'
assert_true "$((downloads == 0))" 'the test hook does not download'
assert_true "$(assert_no_file "$TEST_ROOT/dispatch.path")" 'config-only does not dispatch'

# 2. the real download path (stubbed curl, no hook): one download, config lands.
reset_state
mainframe_run --bootstrap-link "$LINK" --config-only >"$out_file" 2>&1; status=$?
assert_true "$((status == 0))" 'curl-path config-only succeeds'
assert_true "$((downloads == 1))" 'the bundle downloads on this run'
assert_true "$(assert_file "$PLACED")" 'curl-path config lands'

# 3. full flow: config lands, then the bootstrap dispatches to boot.sh.
reset_state
export MAINFRAME_BOOTSTRAP_TEST_BUNDLE="$FAKE_CONFIG"
mainframe_run --bootstrap-link "$LINK" >"$out_file" 2>&1; status=$?
assert_true "$((status == 0))" 'full flow succeeds'
assert_true "$(assert_file "$PLACED")" 'full flow places the config first'
assert_true "$(assert_file "$TEST_ROOT/dispatch.path")" 'full flow dispatches after placement'
dispatch_target=$(cat "$TEST_ROOT/dispatch.path")
assert_true "$(assert_contains "$dispatch_target" 'boot.sh')" 'full flow dispatches to boot.sh'

# 4. a malformed link fails loudly before any download or placement.
reset_state
mainframe_run --bootstrap-link 'https://relay.example.invalid/bootstrap/short' --config-only >"$out_file" 2>&1; status=$?
out=$(cat "$out_file")
assert_true "$((status == 2))" 'malformed link exits 2'
assert_true "$(assert_contains "$out" 'not a bootstrap link')" 'malformed link names itself'
assert_true "$((downloads == 0))" 'malformed link does not download'
assert_true "$(assert_no_file "$PLACED")" 'malformed link places nothing'

# 5. a dry run downloads nothing: no download, no config, no dispatch.
reset_state
export MAINFRAME_BOOTSTRAP_TEST_BUNDLE="$FAKE_CONFIG"
mainframe_run --dry-run --bootstrap-link "$LINK" >"$out_file" 2>&1; status=$?
out=$(cat "$out_file")
assert_true "$((status == 0))" 'dry run succeeds'
assert_true "$(assert_contains "$out" 'no download happens on a dry run')" 'dry run says no download happens'
assert_true "$((downloads == 0))" 'dry run does not download'
assert_true "$(assert_no_file "$PLACED")" 'dry run places nothing'
assert_true "$(assert_no_file "$TEST_ROOT/dispatch.path")" 'dry run does not dispatch'

# 6. an invalid bundle fails loudly and places nothing.
reset_state
export MAINFRAME_BOOTSTRAP_TEST_BUNDLE="$BAD_CONFIG"
mainframe_run --bootstrap-link "$LINK" --config-only >"$out_file" 2>&1; status=$?
out=$(cat "$out_file")
assert_true "$((status != 0))" 'invalid bundle fails'
assert_true "$(assert_contains "$out" 'no valid ntfyTopic')" 'invalid bundle names the cause'
assert_true "$(assert_no_file "$PLACED")" 'invalid bundle places nothing'

# 7. --config-only without a link is a loud error, not a silent no-op.
reset_state
mainframe_run --config-only >"$out_file" 2>&1; status=$?
out=$(cat "$out_file")
assert_true "$((status == 2))" 'config-only without a link exits 2'
assert_true "$(assert_contains "$out" 'needs --bootstrap-link')" 'config-only without a link names itself'

# 8. MAINFRAME_PROFILE_ROOT moves the placement.
reset_state
export MAINFRAME_BOOTSTRAP_TEST_BUNDLE="$FAKE_CONFIG"
export MAINFRAME_PROFILE_ROOT="$TEST_ROOT/custom-profile"
mainframe_run --bootstrap-link "$LINK" --config-only >"$out_file" 2>&1; status=$?
assert_true "$((status == 0))" 'profile-root override succeeds'
assert_true "$(assert_file "$TEST_ROOT/custom-profile/mainframe.config.json")" 'profile-root override places the config there'
assert_true "$(assert_no_file "$PLACED")" 'profile-root override leaves the default alone'

if ((failures > 0)); then
    printf 'FAIL: %s of %s bootstrap-link checks failed\n' "$failures" "$((checks + failures))" >&2
    exit 1
fi
printf 'PASS: %s bootstrap-link checks; no real bootstrap was executed.\n' "$checks"
