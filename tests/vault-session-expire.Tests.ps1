# No Pester dependency. Runs under windows powershell 5.1 AND pwsh 7.
#
# session expiry is REAL, not policy: a lapsed TTL logs the CLI out
# (Expire-VaultSession: `bw logout` + purge), it does not just lock it.
# `bw lock` leaves the CLI logged in and the local vault cache on disk, so
# the old session key kept decrypting it for days after its TTL. this pins
# the difference down: expiry calls logout, lock does not, and the first use
# after an expiry is a full login, not an unlock.
#
# nothing here touches the network, the real vault or the phone: the bw CLI
# is faked and the profile root is a temp directory.
$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$secretModule = Join-Path $repo 'vault-secret.psm1'

$script:checks = 0
function Assert-True($Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:checks++
}
function Assert-Equal($Expected, $Actual, [string]$Message) {
    if ($Expected -ne $Actual) { throw "FAIL: $Message`n  expected: $Expected`n  actual:   $Actual" }
    $script:checks++
}
function Assert-Contains($Text, [string]$Needle, [string]$Message) {
    if ($Text -notmatch [regex]::Escape($Needle)) { throw "FAIL: $Message`n  text: $Text" }
    $script:checks++
}
function Assert-NotContains($Text, [string]$Needle, [string]$Message) {
    if ($Text -match [regex]::Escape($Needle)) { throw "FAIL: $Message`n  text: $Text" }
    $script:checks++
}

# the fake bw cli: state lives in files under $VAULT_TEST_ROOT, so `status`
# answers `locked` or `unauthenticated` depending on what `login`/`logout`
# did last, and every invocation is recorded in `calls`.
$root = Join-Path ([IO.Path]::GetTempPath()) ("vault-expire-test-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$bin = Join-Path $root 'bin'
$profile = Join-Path $root 'profile'
New-Item -ItemType Directory -Force -Path $bin, (Join-Path (Join-Path $profile 'accounts') 'bitwarden') | Out-Null

if ($env:OS -eq 'Windows_NT') {
    $bw = Join-Path $bin 'bw.cmd'
    @(
        '@echo off'
        'echo %1>>"%VAULT_TEST_ROOT%\calls"'
        'if "%1"=="status" ('
        '  if exist "%VAULT_TEST_ROOT%\state-unauth" (echo {"status":"unauthenticated","serverUrl":"https://example.invalid","userEmail":"t@example.invalid"}) else (echo {"status":"locked","serverUrl":"https://example.invalid","userEmail":"t@example.invalid"})'
        ') else if "%1"=="logout" ('
        '  echo x>"%VAULT_TEST_ROOT%\state-unauth"'
        '  echo You have logged out.'
        ') else if "%1"=="lock" ('
        '  echo Your vault is locked.'
        ') else if "%1"=="login" ('
        '  if exist "%VAULT_TEST_ROOT%\state-unauth" del "%VAULT_TEST_ROOT%\state-unauth"'
        '  echo You are logged in!'
        ') else if "%1"=="unlock" ('
        '  echo fakesessionkey0123456789abcdef'
        ') else if "%1"=="list" ('
        '  echo [{"name":"github.com/FahadBinHussain","notes":"token = ghp_0123456789012345678901"}]'
        ') else ('
        '  echo unknown command %1 1>&2'
        '  exit /b 1'
        ')'
    ) | Set-Content -LiteralPath $bw -Encoding ASCII
} else {
    $bw = Join-Path $bin 'bw'
    @(
        '#!/bin/sh'
        'echo "$1" >> "$VAULT_TEST_ROOT/calls"'
        'case "$1" in'
        '  status)'
        '    if [ -f "$VAULT_TEST_ROOT/state-unauth" ]; then echo ''{"status":"unauthenticated","serverUrl":"https://example.invalid","userEmail":"t@example.invalid"}'';'
        '    else echo ''{"status":"locked","serverUrl":"https://example.invalid","userEmail":"t@example.invalid"}''; fi;;'
        '  logout) touch "$VAULT_TEST_ROOT/state-unauth"; echo "You have logged out.";;'
        '  lock) echo "Your vault is locked.";;'
        '  login) rm -f "$VAULT_TEST_ROOT/state-unauth"; echo "You are logged in!";;'
        '  unlock) echo "fakesessionkey0123456789abcdef";;'
        '  list) echo ''[{"name":"github.com/FahadBinHussain","notes":"token = ghp_0123456789012345678901"}]'';;'
        '  *) echo "unknown command $1" >&2; exit 1;;'
        'esac'
    ) | Set-Content -LiteralPath $bw -Encoding ASCII
    & chmod 755 $bw
}

$sessionFile = Join-Path (Join-Path (Join-Path $profile 'accounts') 'bitwarden') 'session.key'
$ttlFile = [System.IO.Path]::ChangeExtension($sessionFile, '.ttl')
$callsFile = Join-Path $root 'calls'
$stateFile = Join-Path $root 'state-unauth'

function Reset-FakeBw {
    param([string]$State = 'locked')
    if (Test-Path -LiteralPath $callsFile) { Remove-Item -LiteralPath $callsFile -Force }
    if ($State -eq 'unauthenticated') {
        Set-Content -LiteralPath $stateFile -Value 'x' -NoNewline
    } else {
        Remove-Item -LiteralPath $stateFile -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $sessionFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $ttlFile -Force -ErrorAction SilentlyContinue
    Remove-Item -Path 'Env:\BW_SESSION' -ErrorAction SilentlyContinue
    Remove-Item -Path 'Env:\MAINFRAME_VAULT_APPROVED_TTL' -ErrorAction SilentlyContinue
}
function Get-Calls {
    if (Test-Path -LiteralPath $callsFile) { return (Get-Content -LiteralPath $callsFile -Raw) } else { return '' }
}

$savedPath = $env:PATH
$savedProfile = $env:MAINFRAME_PROFILE_ROOT
$savedTestRoot = $env:VAULT_TEST_ROOT
$savedEmail = $env:MAINFRAME_BW_EMAIL
try {
    $env:PATH = "$bin$([IO.Path]::PathSeparator)$savedPath"
    $env:MAINFRAME_PROFILE_ROOT = $profile
    $env:VAULT_TEST_ROOT = $root
    Remove-Item -Path 'Env:\MAINFRAME_BW_EMAIL' -ErrorAction SilentlyContinue

    Import-Module $secretModule -Force -DisableNameChecking

    # 1. Expire-VaultSession logs out for real: `bw logout` runs, the files
    # go, and the CLI ends up unauthenticated.
    Reset-FakeBw -State 'locked'
    Set-Content -LiteralPath $sessionFile -Value 'fakesessionkey0123456789abcdef' -NoNewline
    Set-Content -LiteralPath $ttlFile -Value '720' -NoNewline
    $env:BW_SESSION = 'fakesessionkey0123456789abcdef'
    $loggedOut = Expire-VaultSession
    Assert-True $loggedOut 'Expire-VaultSession reports the logout succeeded'
    Assert-Contains (Get-Calls) 'logout' 'expiry calls bw logout'
    Assert-True (-not (Test-Path -LiteralPath $sessionFile)) 'session.key is gone after expiry'
    Assert-True (-not (Test-Path -LiteralPath $ttlFile)) 'session.ttl is gone after expiry'
    Assert-True (-not $env:BW_SESSION) 'BW_SESSION is cleared after expiry'
    Assert-True (Test-Path -LiteralPath $stateFile) 'the CLI is unauthenticated after expiry'

    # 2. Lock-VaultSession is NOT an expiry: it locks, it purges the files,
    # and it never calls logout - the CLI stays logged in.
    Reset-FakeBw -State 'locked'
    Set-Content -LiteralPath $sessionFile -Value 'fakesessionkey0123456789abcdef' -NoNewline
    Set-Content -LiteralPath $ttlFile -Value '720' -NoNewline
    Lock-VaultSession
    Assert-Contains (Get-Calls) 'lock' 'lock calls bw lock'
    Assert-NotContains (Get-Calls) 'logout' 'lock does NOT call bw logout'
    Assert-True (-not (Test-Path -LiteralPath $sessionFile)) 'session.key is gone after lock'
    Assert-True (-not (Test-Path -LiteralPath $stateFile)) 'the CLI stays logged in after a lock'

    # 3. Get-VaultSession with a lapsed TTL expires the session (logout +
    # purge) and returns null - the old key is dead, not just unused.
    Reset-FakeBw -State 'locked'
    Set-Content -LiteralPath $sessionFile -Value 'fakesessionkey0123456789abcdef' -NoNewline
    Set-Content -LiteralPath $ttlFile -Value '720' -NoNewline
    (Get-Item -LiteralPath $sessionFile).LastWriteTime = (Get-Date).AddMinutes(-800)
    $expired = Get-VaultSession
    Assert-True ([string]::IsNullOrWhiteSpace($expired)) 'an expired session returns null'
    Assert-Contains (Get-Calls) 'logout' 'a lapsed TTL triggers bw logout'
    Assert-True (-not (Test-Path -LiteralPath $sessionFile)) 'the expired session.key is purged'

    # 4. Get-VaultSession with a fresh session returns the key and touches
    # nothing - no logout, no purge.
    Reset-FakeBw -State 'locked'
    Set-Content -LiteralPath $sessionFile -Value 'fakesessionkey0123456789abcdef' -NoNewline
    Set-Content -LiteralPath $ttlFile -Value '720' -NoNewline
    $fresh = Get-VaultSession
    Assert-Equal 'fakesessionkey0123456789abcdef' $fresh 'a fresh session returns its key'
    Assert-NotContains (Get-Calls) 'logout' 'a fresh session never logs out'

    # 5. the first use after an expiry is a full login: the CLI is logged
    # out, so Ensure-VaultSession logs in (not just unlocks) after the
    # phone approval hands over the password.
    Reset-FakeBw -State 'unauthenticated'
    $env:MAINFRAME_BW_EMAIL = 't@example.invalid'
    function global:Get-VaultMasterPassword {
        param([string]$PromptContext, [int]$TimeoutSeconds, [string]$Agent, [string]$Model, [DateTime]$StartTimeUtc)
        return 'TestPassword123!'
    }
    try {
        $ok = Ensure-VaultSession -TimeoutSeconds 5
    } finally {
        Remove-Item Function:\Get-VaultMasterPassword -ErrorAction SilentlyContinue
    }
    Assert-True $ok 'Ensure-VaultSession succeeds after an expiry'
    Assert-Contains (Get-Calls) 'login' 'an expired session logs in again, not just unlocks'
    Assert-Contains (Get-Calls) 'unlock' 'the login is followed by an unlock'
    Assert-True (Test-Path -LiteralPath $sessionFile) 'a fresh session.key is cached after the login'
    Assert-True (-not (Test-Path -LiteralPath $stateFile)) 'the CLI is logged in again after the login'
} finally {
    $env:PATH = $savedPath
    $env:MAINFRAME_PROFILE_ROOT = $savedProfile
    $env:VAULT_TEST_ROOT = $savedTestRoot
    if ($null -ne $savedEmail) { $env:MAINFRAME_BW_EMAIL = $savedEmail } else { Remove-Item -Path 'Env:\MAINFRAME_BW_EMAIL' -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "vault-session-expire checks: $script:checks passed" -ForegroundColor Green
