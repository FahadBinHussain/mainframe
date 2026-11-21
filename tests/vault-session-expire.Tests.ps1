# No Pester dependency. Runs under windows powershell 5.1 AND pwsh 7.
#
# session expiry LOCKS the CLI, it does not log it out (owner's rule,
# 2026-11-21): a lapsed TTL runs `bw lock` + purge, so the CLI stays signed
# in and the vault is merely locked - the panel shows a locked vault, not
# "signed out". this pins the behaviour down: expiry calls lock, never
# logout, and the first use after an expiry is an unlock, not a login.
#
# nothing here touches the network, the real vault or the phone: the bw CLI
# is faked and the profile root is a temp directory.
$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$secretModule = Join-Path $repo 'windows\vault-secret.psm1'

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
    # fake schedulers: log the full command line, exit 0 - so the unlock
    # in section 5 registers a scheduled expiry against the fakes, never
    # a real schtasks task / systemd timer.
    @('@echo off', "echo schtasks %*>>`"$root\sched-calls`"", 'exit /b 0') | Set-Content -LiteralPath (Join-Path $bin 'schtasks.cmd') -Encoding ASCII
    @('@echo off', "echo systemd-run %*>>`"$root\sched-calls`"", 'exit /b 0') | Set-Content -LiteralPath (Join-Path $bin 'systemd-run.cmd') -Encoding ASCII
    @('@echo off', "echo systemctl %*>>`"$root\sched-calls`"", 'exit /b 0') | Set-Content -LiteralPath (Join-Path $bin 'systemctl.cmd') -Encoding ASCII
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
    @(
        '#!/bin/sh'
        "echo `"schtasks `$*`" >> `"$root/sched-calls`""
        'exit 0'
    ) | Set-Content -LiteralPath (Join-Path $bin 'schtasks') -Encoding ASCII
    @(
        '#!/bin/sh'
        "echo `"systemd-run `$*`" >> `"$root/sched-calls`""
        'exit 0'
    ) | Set-Content -LiteralPath (Join-Path $bin 'systemd-run') -Encoding ASCII
    @(
        '#!/bin/sh'
        "echo `"systemctl `$*`" >> `"$root/sched-calls`""
        'exit 0'
    ) | Set-Content -LiteralPath (Join-Path $bin 'systemctl') -Encoding ASCII
    & chmod 755 (Join-Path $bin 'schtasks')
    & chmod 755 (Join-Path $bin 'systemd-run')
    & chmod 755 (Join-Path $bin 'systemctl')
}

$sessionFile = Join-Path (Join-Path (Join-Path $profile 'accounts') 'bitwarden') 'session.key'
$ttlFile = [System.IO.Path]::ChangeExtension($sessionFile, '.ttl')
$expiryFile = Join-Path (Join-Path (Join-Path $profile 'accounts') 'bitwarden') 'expiry.json'
$callsFile = Join-Path $root 'calls'
$schedCallsFile = Join-Path $root 'sched-calls'
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
    Remove-Item -LiteralPath $expiryFile -Force -ErrorAction SilentlyContinue
    Remove-Item -Path 'Env:\BW_SESSION' -ErrorAction SilentlyContinue
    Remove-Item -Path 'Env:\MAINFRAME_VAULT_SESSION_STARTED_UNIX' -ErrorAction SilentlyContinue
    Remove-Item -Path 'Env:\MAINFRAME_VAULT_APPROVED_TTL' -ErrorAction SilentlyContinue
}
function Get-Calls {
    if (Test-Path -LiteralPath $callsFile) { return (Get-Content -LiteralPath $callsFile -Raw) } else { return '' }
}
function Reset-SchedLog {
    if (Test-Path -LiteralPath $schedCallsFile) { Remove-Item -LiteralPath $schedCallsFile -Force }
}
function Get-SchedCalls {
    if (Test-Path -LiteralPath $schedCallsFile) { return (Get-Content -LiteralPath $schedCallsFile -Raw) } else { return '' }
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

    # 1. Expire-VaultSession LOCKS for real: `bw lock` runs, the files go,
    # and the CLI stays signed in - expiry never logs the CLI out.
    Reset-FakeBw -State 'locked'
    Set-Content -LiteralPath $sessionFile -Value 'fakesessionkey0123456789abcdef' -NoNewline
    Set-Content -LiteralPath $ttlFile -Value '720' -NoNewline
    $env:BW_SESSION = 'fakesessionkey0123456789abcdef'
    $locked = Expire-VaultSession
    Assert-True $locked 'Expire-VaultSession reports the lock succeeded'
    Assert-Contains (Get-Calls) 'lock' 'expiry calls bw lock'
    Assert-NotContains (Get-Calls) 'logout' 'expiry NEVER calls bw logout'
    Assert-True (-not (Test-Path -LiteralPath $sessionFile)) 'session.key is gone after expiry'
    Assert-True (-not (Test-Path -LiteralPath $ttlFile)) 'session.ttl is gone after expiry'
    Assert-True (-not $env:BW_SESSION) 'BW_SESSION is cleared after expiry'
    Assert-True (-not (Test-Path -LiteralPath $stateFile)) 'the CLI stays signed in after expiry'

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

    # 3. Get-VaultSession with a lapsed TTL expires the session (lock +
    # purge) and returns null - the old key is dead, not just unused.
    Reset-FakeBw -State 'locked'
    Set-Content -LiteralPath $sessionFile -Value 'fakesessionkey0123456789abcdef' -NoNewline
    Set-Content -LiteralPath $ttlFile -Value '720' -NoNewline
    (Get-Item -LiteralPath $sessionFile).LastWriteTime = (Get-Date).AddMinutes(-800)
    $expired = Get-VaultSession
    Assert-True ([string]::IsNullOrWhiteSpace($expired)) 'an expired session returns null'
    Assert-Contains (Get-Calls) 'lock' 'a lapsed TTL triggers bw lock'
    Assert-NotContains (Get-Calls) 'logout' 'a lapsed TTL never logs the CLI out'
    Assert-True (-not (Test-Path -LiteralPath $sessionFile)) 'the expired session.key is purged'

    # 4. Get-VaultSession with a fresh session returns the key and touches
    # nothing - no lock, no logout, no purge.
    Reset-FakeBw -State 'locked'
    Set-Content -LiteralPath $sessionFile -Value 'fakesessionkey0123456789abcdef' -NoNewline
    Set-Content -LiteralPath $ttlFile -Value '720' -NoNewline
    $fresh = Get-VaultSession
    Assert-Equal 'fakesessionkey0123456789abcdef' $fresh 'a fresh session returns its key'
    Assert-NotContains (Get-Calls) 'logout' 'a fresh session never logs out'
    Assert-NotContains (Get-Calls) 'lock' 'a fresh session never locks either'

    # 5. the first use after an expiry is an UNLOCK, not a login: the expiry
    # locked the cli and it stayed signed in.
    Reset-FakeBw -State 'locked'
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
    Assert-Contains (Get-Calls) 'unlock' 'the expired session is unlocked again'
    Assert-NotContains (Get-Calls) 'login' 'a signed-in cli does NOT need a login after an expiry'
    Assert-True (Test-Path -LiteralPath $sessionFile) 'a fresh session.key is cached after the unlock'
    Assert-True (-not (Test-Path -LiteralPath $stateFile)) 'the CLI is still signed in after the unlock'
    # 5b. the unlock registered the scheduled expiry (time-based, not
    # lazy): expiry.json exists and the fake scheduler was called.
    Assert-True (Test-Path -LiteralPath $expiryFile) 'the unlock registers a scheduled expiry (expiry.json exists)'
    if ($env:OS -eq 'Windows_NT') {
        Assert-Contains (Get-SchedCalls) '/Create' 'the unlock registration creates a schtasks task (fake schtasks)'
    } else {
        Assert-Contains (Get-SchedCalls) 'systemd-run --on-active=3600s' 'the unlock registration schedules 60 minutes out (fake systemd-run)'
    }
    $null = Unregister-VaultSessionExpiry
    Assert-True (-not (Test-Path -LiteralPath $expiryFile)) 'unregister removes expiry.json after the unlock'

    # 6. a manual lock cancels the pending scheduled expiry: re-register,
    # lock, and the job is gone (fake scheduler log proves the removal).
    Reset-SchedLog
    $ok = Register-VaultSessionExpiry -TtlMinutes 60
    Assert-True $ok 're-registration succeeds before the lock'
    Assert-True (Test-Path -LiteralPath $expiryFile) 'expiry.json exists before the lock'
    Reset-SchedLog
    Lock-VaultSession
    Assert-True (-not (Test-Path -LiteralPath $expiryFile)) 'a manual lock deletes expiry.json'
    if ($env:OS -eq 'Windows_NT') {
        Assert-Contains (Get-SchedCalls) '/Delete' 'a manual lock deletes the schtasks entry'
    } else {
        Assert-Contains (Get-SchedCalls) 'systemctl stop' 'a manual lock stops the systemd timer'
    }
} finally {
    $env:PATH = $savedPath
    $env:MAINFRAME_PROFILE_ROOT = $savedProfile
    $env:VAULT_TEST_ROOT = $savedTestRoot
    if ($null -ne $savedEmail) { $env:MAINFRAME_BW_EMAIL = $savedEmail } else { Remove-Item -Path 'Env:\MAINFRAME_BW_EMAIL' -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "vault-session-expire checks: $script:checks passed" -ForegroundColor Green
