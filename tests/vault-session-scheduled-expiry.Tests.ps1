# No Pester dependency. Runs under windows powershell 5.1 AND pwsh 7.
#
# scheduled expiry is REAL and TIME-based: an unlock registers a one-shot
# job (schtasks on windows, a systemd transient timer on linux, a detached
# sleeper as fallback) that runs the full Expire-VaultSession (bw lock +
# purge + verify) at the TTL mark with NO vault use in between. the lazy
# check in Get-VaultSession is only the backstop for the restart window.
#
# this pins down: (a) the env-only session ($env:BW_SESSION with no session
# file) is age-gated by MAINFRAME_VAULT_SESSION_STARTED_UNIX and refused
# when unmarked; (b) registration builds the right scheduler command and
# records expiry.json; (c) re-unlock replaces the pending job (old job
# cancelled first); (d) the wrapper stands down on a fresh/re-unlocked
# session and expires a due one; (e) with a 1-minute TTL the session file
# is gone and `bw status` reports locked (the cli stays signed in) after the
# mark with zero
# vault use in between - proven end to end for the sleeper and (where the
# system bus works) for the real systemd timer; (f) no orphaned task,
# timer, or sleeper is left behind.
#
# nothing here touches the network, the real vault, or the phone: the bw
# CLI is faked, the profile root is a temp directory, and the scheduler
# binaries are faked except in the one section that proves the real systemd
# timer on this VM (transient, self-cleaning, temp profile, fake bw).
$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$secretModule = Join-Path $repo 'windows\vault-secret.psm1'
$wrapperScript = Join-Path $repo 'windows\expire-vault-session.ps1'
$pwshExe = (Get-Process -Id $PID).Path

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

# the fake bw cli: state lives in files under $root, so `status` answers
# `locked` or `unauthenticated` depending on what `login`/`logout` did
# last, and every invocation is recorded in `calls`. the root path is
# BAKED into the script (not read from $env:VAULT_TEST_ROOT) because the
# systemd service that fires the wrapper does not inherit the test
# process's environment.
$root = Join-Path ([IO.Path]::GetTempPath()) ("vault-sched-test-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$bin = Join-Path $root 'bin'
$schedBin = Join-Path $root 'sched'
$profile = Join-Path $root 'profile'
New-Item -ItemType Directory -Force -Path $bin, $schedBin, (Join-Path (Join-Path $profile 'accounts') 'bitwarden') | Out-Null

if ($env:OS -eq 'Windows_NT') {
    $bw = Join-Path $bin 'bw.cmd'
    @(
        '@echo off'
        "echo %1>>`"$root\calls`""
        'if "%1"=="status" ('
        "  if exist `"$root\state-unauth`" (echo {`"status`":`"unauthenticated`",`"serverUrl`":`"https://example.invalid`",`"userEmail`":`"t@example.invalid`"}) else (echo {`"status`":`"locked`",`"serverUrl`":`"https://example.invalid`",`"userEmail`":`"t@example.invalid`"})"
        ') else if "%1"=="logout" ('
        "  echo x>`"$root\state-unauth`""
        '  echo You have logged out.'
        ') else if "%1"=="lock" ('
        '  echo Your vault is locked.'
        ') else if "%1"=="login" ('
        "  if exist `"$root\state-unauth`" del `"$root\state-unauth`""
        '  echo You are logged in!'
        ') else if "%1"=="unlock" ('
        '  echo fakesessionkey0123456789abcdef'
        ') else if "%1"=="list" ('
        '  echo []'
        ') else ('
        '  echo unknown command %1 1>&2'
        '  exit /b 1'
        ')'
    ) | Set-Content -LiteralPath $bw -Encoding ASCII
    # fake schedulers: log the full command line, exit 0. the fake
    # systemd-run fails when MF_FAKE_SYSTEMD_FAIL is set (fallback test).
    @('@echo off', "echo schtasks %*>>`"$root\sched-calls`"", 'exit /b 0') | Set-Content -LiteralPath (Join-Path $schedBin 'schtasks.cmd') -Encoding ASCII
    @('@echo off', 'if defined MF_FAKE_SYSTEMD_FAIL (echo systemd-run failed 1>&2 & exit /b 1)', "echo systemd-run %*>>`"$root\sched-calls`"", 'exit /b 0') | Set-Content -LiteralPath (Join-Path $schedBin 'systemd-run.cmd') -Encoding ASCII
    @('@echo off', "echo systemctl %*>>`"$root\sched-calls`"", 'exit /b 0') | Set-Content -LiteralPath (Join-Path $schedBin 'systemctl.cmd') -Encoding ASCII
} else {
    $bw = Join-Path $bin 'bw'
    @(
        '#!/bin/sh'
        "echo `"`$1`" >> `"$root/calls`""
        'case "$1" in'
        '  status)'
        "    if [ -f `"$root/state-unauth`" ]; then echo '{`"status`":`"unauthenticated`",`"serverUrl`":`"https://example.invalid`",`"userEmail`":`"t@example.invalid`"}';"
        '    else echo ''{"status":"locked","serverUrl":"https://example.invalid","userEmail":"t@example.invalid"}''; fi;;'
        "  logout) touch `"$root/state-unauth`"; echo `"You have logged out.`";;"
        '  lock) echo "Your vault is locked.";;'
        "  login) rm -f `"$root/state-unauth`"; echo `"You are logged in!`";;"
        '  unlock) echo "fakesessionkey0123456789abcdef";;'
        '  list) echo ''[]'';;'
        '  *) echo "unknown command $1" >&2; exit 1;;'
        'esac'
    ) | Set-Content -LiteralPath $bw -Encoding ASCII
    & chmod 755 $bw
    @(
        '#!/bin/sh'
        "echo `"schtasks `$*`" >> `"$root/sched-calls`""
        'exit 0'
    ) | Set-Content -LiteralPath (Join-Path $schedBin 'schtasks') -Encoding ASCII
    @(
        '#!/bin/sh'
        'if [ -n "$MF_FAKE_SYSTEMD_FAIL" ]; then echo "systemd-run failed" >&2; exit 1; fi'
        "echo `"systemd-run `$*`" >> `"$root/sched-calls`""
        'exit 0'
    ) | Set-Content -LiteralPath (Join-Path $schedBin 'systemd-run') -Encoding ASCII
    @(
        '#!/bin/sh'
        "echo `"systemctl `$*`" >> `"$root/sched-calls`""
        'exit 0'
    ) | Set-Content -LiteralPath (Join-Path $schedBin 'systemctl') -Encoding ASCII
    & chmod 755 (Join-Path $schedBin 'schtasks')
    & chmod 755 (Join-Path $schedBin 'systemd-run')
    & chmod 755 (Join-Path $schedBin 'systemctl')
}

$sessionFile = Join-Path (Join-Path (Join-Path $profile 'accounts') 'bitwarden') 'session.key'
$ttlFile = [System.IO.Path]::ChangeExtension($sessionFile, '.ttl')
$expiryFile = Join-Path (Join-Path (Join-Path $profile 'accounts') 'bitwarden') 'expiry.json'
$callsFile = Join-Path $root 'calls'
$schedCallsFile = Join-Path $root 'sched-calls'
$stateFile = Join-Path $root 'state-unauth'
$script:sleeperPids = @()

function Reset-FakeBw {
    if (Test-Path -LiteralPath $callsFile) { Remove-Item -LiteralPath $callsFile -Force }
    Remove-Item -LiteralPath $stateFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $sessionFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $ttlFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $expiryFile -Force -ErrorAction SilentlyContinue
    Remove-Item -Path 'Env:\BW_SESSION' -ErrorAction SilentlyContinue
    Remove-Item -Path 'Env:\MAINFRAME_VAULT_SESSION_STARTED_UNIX' -ErrorAction SilentlyContinue
    Remove-Item -Path 'Env:\MAINFRAME_VAULT_APPROVED_TTL' -ErrorAction SilentlyContinue
    Remove-Item -Path 'Env:\MAINFRAME_VAULT_TTL_MINUTES' -ErrorAction SilentlyContinue
}
function Reset-SchedLog {
    if (Test-Path -LiteralPath $schedCallsFile) { Remove-Item -LiteralPath $schedCallsFile -Force }
}
function Get-Calls {
    if (Test-Path -LiteralPath $callsFile) { return (Get-Content -LiteralPath $callsFile -Raw) } else { return '' }
}
function Get-SchedCalls {
    if (Test-Path -LiteralPath $schedCallsFile) { return (Get-Content -LiteralPath $schedCallsFile -Raw) } else { return '' }
}
function Get-ExpiryState {
    if (Test-Path -LiteralPath $expiryFile) { return (Get-Content -LiteralPath $expiryFile -Raw | ConvertFrom-Json) } else { return $null }
}
function Test-ProcessAlive([int]$ProcessId) {
    try { $null = Get-Process -Id $ProcessId -ErrorAction Stop; return $true } catch { return $false }
}
function Wait-ForCondition {
    param([scriptblock]$Test, [int]$TimeoutSeconds = 110, [int]$IntervalSeconds = 2)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (& $Test) { return $true }
        Start-Sleep -Seconds $IntervalSeconds
    }
    return $false
}
function Invoke-Wrapper {
    $out = @(& $pwshExe -NoProfile -NonInteractive -File $wrapperScript -ProfileRoot $profile -BwPath $bw 2>&1)
    return @{ ExitCode = $LASTEXITCODE; Output = ($out -join "`n") }
}

$savedPath = $env:PATH
$savedProfile = $env:MAINFRAME_PROFILE_ROOT
$basePath = "$bin$([IO.Path]::PathSeparator)$savedPath"
$schedPath = "$schedBin$([IO.Path]::PathSeparator)$basePath"
try {
    $env:PATH = $basePath
    $env:MAINFRAME_PROFILE_ROOT = $profile

    Import-Module $secretModule -Force -DisableNameChecking

    # 1. -AllowExpired is gone: no callers, no parameter, no source trace.
    Assert-True ((Get-Command Get-VaultSession).Parameters.Keys -notcontains 'AllowExpired') 'Get-VaultSession has no -AllowExpired parameter'
    $secretSource = Get-Content -LiteralPath (Join-Path $repo 'windows\vault-secret.psm1') -Raw
    Assert-NotContains $secretSource 'AllowExpired' 'vault-secret.psm1 has no AllowExpired trace left'

    # 2. env-only sessions are age-gated by the start marker.
    # 2a. no file + BW_SESSION + no marker -> refused, env cleared.
    Reset-FakeBw
    $env:BW_SESSION = 'fakesessionkey0123456789abcdef'
    $refused = Get-VaultSession
    Assert-True ([string]::IsNullOrWhiteSpace($refused)) 'an unmarked env session is refused when the file is gone'
    Assert-True (-not $env:BW_SESSION) 'the refused env session is cleared in-process'
    # 2b. no file + BW_SESSION + fresh marker -> trusted.
    Reset-FakeBw
    $env:BW_SESSION = 'fakesessionkey0123456789abcdef'
    $env:MAINFRAME_VAULT_SESSION_STARTED_UNIX = [string][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $trusted = Get-VaultSession
    Assert-Equal 'fakesessionkey0123456789abcdef' $trusted 'a fresh marked env session is trusted'
    # 2c. no file + BW_SESSION + stale marker (70m old, 60m default TTL)
    # -> expired for real: lock runs, env cleared, null returned.
    Reset-FakeBw
    $env:BW_SESSION = 'fakesessionkey0123456789abcdef'
    $env:MAINFRAME_VAULT_SESSION_STARTED_UNIX = [string][DateTimeOffset]::UtcNow.AddMinutes(-70).ToUnixTimeSeconds()
    $stale = Get-VaultSession
    Assert-True ([string]::IsNullOrWhiteSpace($stale)) 'a stale marked env session returns null'
    Assert-Contains (Get-Calls) 'lock' 'a stale env session triggers bw lock'
    Assert-NotContains (Get-Calls) 'logout' 'a stale env session never logs the CLI out'
    Assert-True (-not $env:BW_SESSION) 'BW_SESSION is cleared after the env expiry'
    Assert-True (-not $env:MAINFRAME_VAULT_SESSION_STARTED_UNIX) 'the start marker is cleared after the env expiry'
    # 2d. fresh file + unmarked BW_SESSION -> the file branch wins and
    # stamps the marker from the file mtime.
    Reset-FakeBw
    Set-Content -LiteralPath $sessionFile -Value 'fakesessionkey0123456789abcdef' -NoNewline
    $env:BW_SESSION = 'someothervalue'
    $fromFile = Get-VaultSession
    Assert-Equal 'fakesessionkey0123456789abcdef' $fromFile 'the file branch wins over an unmarked env var'
    Assert-True ($env:MAINFRAME_VAULT_SESSION_STARTED_UNIX -match '^[0-9]+$') 'the file branch stamps the start marker from the mtime'
    # 2e. Lock clears the marker too.
    Lock-VaultSession
    Assert-True (-not $env:MAINFRAME_VAULT_SESSION_STARTED_UNIX) 'Lock clears the start marker'

    # 3. registration builds the right scheduler command (fake schedulers
    # on PATH - no real task/timer is created anywhere in this section).
    $env:PATH = $schedPath
    # 3a. schtasks: fixed name, ONCE, /F, full pwsh path in /TR.
    Reset-FakeBw; Reset-SchedLog
    Set-VaultSessionKey -SessionKey 'fakesessionkey0123456789abcdef' -TtlMinutes 60 | Out-Null
    $ok = Register-VaultSessionExpiry -TtlMinutes 60 -Mechanism SchTasks
    Assert-True $ok 'schtasks registration succeeds'
    $schedLog = Get-SchedCalls
    Assert-Contains $schedLog '/Create' 'schtasks registration creates a task'
    Assert-Contains $schedLog 'MainframeVaultExpiry' 'schtasks uses the fixed task name'
    Assert-Contains $schedLog '/SC ONCE' 'schtasks creates a one-shot task'
    Assert-Contains $schedLog '/F' 'schtasks creation forces overwrite'
    Assert-Contains $schedLog $wrapperScript 'schtasks /TR invokes the expiry wrapper'
    Assert-Contains $schedLog $pwshExe 'schtasks /TR uses the full pwsh path, never bare pwsh'
    $state = Get-ExpiryState
    Assert-True ($null -ne $state) 'registration writes expiry.json'
    Assert-Equal 'schtasks' $state.mechanism 'expiry.json records the schtasks mechanism'
    Assert-Equal 60 $state.ttlMinutes 'expiry.json records the TTL'
    Assert-True ($state.sessionHash -match '^[0-9a-f]{16}$') 'expiry.json records a 16-hex session hash'
    $expiryDelta = $state.expiresAtUnix - [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    Assert-True ($expiryDelta -ge 3500 -and $expiryDelta -le 3650) 'expiry.json expires ~60 minutes out'
    if ($env:OS -ne 'Windows_NT') {
        $mode = (& stat -c %a $expiryFile)
        Assert-Equal '600' $mode 'expiry.json is mode 600'
    }
    # 3b. systemd: --on-active in seconds, fixed unit, HOME passed.
    Reset-FakeBw; Reset-SchedLog
    Set-VaultSessionKey -SessionKey 'fakesessionkey0123456789abcdef' -TtlMinutes 120 | Out-Null
    $ok = Register-VaultSessionExpiry -TtlMinutes 120 -Mechanism Systemd
    Assert-True $ok 'systemd registration succeeds'
    $schedLog = Get-SchedCalls
    Assert-Contains $schedLog '--on-active=7200s' 'systemd-run gets the TTL in seconds'
    Assert-Contains $schedLog '--unit=mainframe-vault-expiry' 'systemd-run uses the fixed unit name'
    Assert-Contains $schedLog '--setenv=HOME=' 'systemd-run passes HOME (services run with an empty HOME)'
    Assert-Contains $schedLog $wrapperScript 'systemd-run invokes the expiry wrapper'
    $state = Get-ExpiryState
    Assert-Equal 'systemd' $state.mechanism 'expiry.json records the systemd mechanism'
    # 3c. replace-on-register: the old entry is cancelled BEFORE the new
    # one is created (the previous registration was systemd, so the old
    # entry is removed with systemctl stop, not a schtasks /Delete).
    Reset-SchedLog
    $ok = Register-VaultSessionExpiry -TtlMinutes 30 -Mechanism SchTasks
    Assert-True $ok 're-registration succeeds'
    $schedLog = Get-SchedCalls
    Assert-Contains $schedLog 'systemctl stop' 're-registration stops the old systemd timer first'
    Assert-True ($schedLog.IndexOf('systemctl stop') -lt $schedLog.IndexOf('/Create')) 'the old timer is stopped BEFORE the new task is created'
    Assert-Equal 30 (Get-ExpiryState).ttlMinutes 'expiry.json carries the NEW ttl after re-registration'
    # 3d. unregister removes the entry and the state file.
    $ok = Unregister-VaultSessionExpiry
    Assert-True $ok 'unregister succeeds'
    Assert-True (-not (Test-Path -LiteralPath $expiryFile)) 'unregister deletes expiry.json'
    Assert-Contains (Get-SchedCalls) '/Delete' 'unregister deletes the schtasks entry'
    # 3e. Auto falls back when the preferred mechanism fails: a failing
    # systemd-run (linux) falls through to the sleeper.
    if ($env:OS -ne 'Windows_NT') {
        Reset-FakeBw; Reset-SchedLog
        Set-VaultSessionKey -SessionKey 'fakesessionkey0123456789abcdef' -TtlMinutes 60 | Out-Null
        $env:MF_FAKE_SYSTEMD_FAIL = '1'
        try {
            $ok = Register-VaultSessionExpiry -TtlMinutes 60 -Mechanism Auto
        } finally {
            Remove-Item -Path 'Env:\MF_FAKE_SYSTEMD_FAIL' -ErrorAction SilentlyContinue
        }
        Assert-True $ok 'Auto registration succeeds via fallback when systemd-run fails'
        $state = Get-ExpiryState
        Assert-Equal 'sleeper' $state.mechanism 'Auto falls back to the sleeper when systemd-run fails'
        Assert-True (Test-ProcessAlive ([int]$state.sleeperPid)) 'the fallback sleeper is running'
        $script:sleeperPids += [int]$state.sleeperPid
        $null = Unregister-VaultSessionExpiry
        Assert-True (-not (Test-ProcessAlive ([int]$state.sleeperPid))) 'unregister kills the sleeper'
        Assert-True (-not (Test-Path -LiteralPath $expiryFile)) 'unregister deletes expiry.json after killing the sleeper'
    }
    # 3f. Set-VaultSessionKey -ScheduleExpiry wires unlock to registration.
    Reset-FakeBw; Reset-SchedLog
    Set-VaultSessionKey -SessionKey 'fakesessionkey0123456789abcdef' -TtlMinutes 60 -ScheduleExpiry | Out-Null
    Assert-True ($null -ne (Get-ExpiryState)) 'Set-VaultSessionKey -ScheduleExpiry registers the expiry'
    if ($env:OS -eq 'Windows_NT') {
        Assert-Contains (Get-SchedCalls) '/Create' 'the unlock registration creates a schtasks task (fake schtasks)'
    } else {
        Assert-Contains (Get-SchedCalls) 'systemd-run --on-active=3600s' 'the unlock registration schedules 60 minutes out (fake systemd-run)'
    }
    $null = Unregister-VaultSessionExpiry
    $env:PATH = $basePath

    # 3g. Unregister never kills its OWN process: a state file naming the
    # current PID as the sleeper (the wrapper expiring its own session)
    # must drop the state file, not suicide. (Without the guard the
    # wrapper killed itself inside Expire before logging out - the
    # sleeper e2e caught it.)
    Reset-FakeBw
    Set-VaultSessionKey -SessionKey 'fakesessionkey0123456789abcdef' -TtlMinutes 60 | Out-Null
    $selfState = [ordered]@{
        expiresAtUnix      = [DateTimeOffset]::UtcNow.AddMinutes(60).ToUnixTimeSeconds()
        ttlMinutes         = 60
        sessionHash        = '0123456789abcdef'
        sessionMtimeUnix   = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        mechanism          = 'sleeper'
        sleeperPid         = $PID
        sleeperStartedUnix = [DateTimeOffset]::new((Get-Process -Id $PID).StartTime.ToUniversalTime()).ToUnixTimeSeconds()
    }
    Set-Content -LiteralPath $expiryFile -Value ($selfState | ConvertTo-Json -Depth 4) -NoNewline
    $null = Unregister-VaultSessionExpiry
    Assert-True (-not (Test-Path -LiteralPath $expiryFile)) 'self-unregister deletes expiry.json'
    Assert-True (Test-ProcessAlive $PID) 'Unregister does not kill its own process'

    # 4. the wrapper's guards, invoked directly (no waiting).
    # 4a. stale job + fresh session (re-unlocked after registration) ->
    # the wrapper stands down and never logs out.
    $env:PATH = $schedPath
    Reset-FakeBw; Reset-SchedLog
    Set-VaultSessionKey -SessionKey 'fakesessionkey0123456789abcdef' -TtlMinutes 1 | Out-Null
    $null = Register-VaultSessionExpiry -TtlMinutes 1 -Mechanism SchTasks
    Set-VaultSessionKey -SessionKey 'fakesessionkeyFEDCBA9876543210' -TtlMinutes 1 | Out-Null
    $state = Get-ExpiryState
    $state.expiresAtUnix = [DateTimeOffset]::UtcNow.AddMinutes(-1).ToUnixTimeSeconds()
    Set-Content -LiteralPath $expiryFile -Value ($state | ConvertTo-Json -Depth 4) -NoNewline
    $run = Invoke-Wrapper
    Assert-Equal 0 $run.ExitCode 'the wrapper exits 0 when it stands down'
    Assert-Contains $run.Output 'standing down' 'the wrapper stands down on a re-unlocked session'
    Assert-True (Test-Path -LiteralPath $sessionFile) 'the fresh session file survives a stale job'
    Assert-Equal 'fakesessionkeyFEDCBA9876543210' (Get-Content -LiteralPath $sessionFile -Raw) 'the fresh session key is untouched'
    Assert-NotContains (Get-Calls) 'logout' 'a stale job never logs out'
    Assert-NotContains (Get-Calls) 'lock' 'a stale job never locks either'
    Assert-True (-not (Test-Path -LiteralPath $expiryFile)) 'the wrapper unregisters itself even when it stands down'
    # 4b. due session (old file, consistent state) -> the wrapper expires.
    Reset-FakeBw; Reset-SchedLog
    Set-VaultSessionKey -SessionKey 'fakesessionkey0123456789abcdef' -TtlMinutes 1 | Out-Null
    (Get-Item -LiteralPath $sessionFile).LastWriteTime = (Get-Date).AddMinutes(-2)
    $null = Register-VaultSessionExpiry -TtlMinutes 1 -Mechanism SchTasks
    $run = Invoke-Wrapper
    Assert-Equal 0 $run.ExitCode 'the wrapper exits 0 when it expires'
    Assert-Contains $run.Output 'expiring it' 'the wrapper expires a due session'
    Assert-True (-not (Test-Path -LiteralPath $sessionFile)) 'the due session file is gone after the wrapper fires'
    Assert-Contains (Get-Calls) 'lock' 'the wrapper expiry calls bw lock'
    Assert-NotContains (Get-Calls) 'logout' 'the wrapper expiry never logs the CLI out'
    Assert-True (-not (Test-Path -LiteralPath $expiryFile)) 'the wrapper unregisters itself after expiring'
    # 4c. no state file at all + old session -> the wrapper falls back to
    # the lazy rule (file age vs TTL) and still expires.
    Reset-FakeBw; Reset-SchedLog
    Set-VaultSessionKey -SessionKey 'fakesessionkey0123456789abcdef' | Out-Null
    (Get-Item -LiteralPath $sessionFile).LastWriteTime = (Get-Date).AddMinutes(-70)
    $run = Invoke-Wrapper
    Assert-Equal 0 $run.ExitCode 'the wrapper exits 0 on the no-state path'
    Assert-Contains $run.Output 'expiring it' 'the wrapper expires a due session even with no state file'
    Assert-True (-not (Test-Path -LiteralPath $sessionFile)) 'the due session file is gone on the no-state path'
    Assert-Contains (Get-Calls) 'lock' 'the no-state expiry calls bw lock'
    $env:PATH = $basePath

    # 5. replace-on-register kills the old SLEEPER (real processes, long
    # TTLs - no waiting, the kill is asserted directly).
    Reset-FakeBw
    Set-VaultSessionKey -SessionKey 'fakesessionkey0123456789abcdef' -TtlMinutes 60 | Out-Null
    $null = Register-VaultSessionExpiry -TtlMinutes 60 -Mechanism Sleeper
    $firstPid = [int](Get-ExpiryState).sleeperPid
    $script:sleeperPids += $firstPid
    Assert-True (Test-ProcessAlive $firstPid) 'the first sleeper is running'
    $null = Register-VaultSessionExpiry -TtlMinutes 60 -Mechanism Sleeper
    $secondPid = [int](Get-ExpiryState).sleeperPid
    $script:sleeperPids += $secondPid
    Assert-True ($secondPid -ne $firstPid) 're-registration starts a NEW sleeper'
    Assert-True (-not (Test-ProcessAlive $firstPid)) 're-registration kills the OLD sleeper first'
    Assert-True (Test-ProcessAlive $secondPid) 'the new sleeper is running'
    Assert-Equal $secondPid ([int](Get-ExpiryState).sleeperPid) 'expiry.json records the NEW sleeper pid'
    $null = Unregister-VaultSessionExpiry

    # 6. a manual lock cancels the pending job.
    Reset-FakeBw
    Set-VaultSessionKey -SessionKey 'fakesessionkey0123456789abcdef' -TtlMinutes 60 | Out-Null
    $null = Register-VaultSessionExpiry -TtlMinutes 60 -Mechanism Sleeper
    $lockPid = [int](Get-ExpiryState).sleeperPid
    $script:sleeperPids += $lockPid
    Lock-VaultSession
    Assert-True (-not (Test-ProcessAlive $lockPid)) 'a manual lock kills the pending sleeper'
    Assert-True (-not (Test-Path -LiteralPath $expiryFile)) 'a manual lock deletes expiry.json'
    Assert-True (-not (Test-Path -LiteralPath $sessionFile)) 'a manual lock still purges the session file'

    # 7. END TO END (sleeper): a 1-minute TTL expires with ZERO vault use
    # in between - the polling loop below calls no vault function at all
    # (only Test-Path + the fake bw's own log + a direct fake-bw call),
    # so the lazy check cannot be what expires the session.
    Reset-FakeBw
    Set-VaultSessionKey -SessionKey 'fakesessionkey0123456789abcdef' -TtlMinutes 1 | Out-Null
    $ok = Register-VaultSessionExpiry -TtlMinutes 1 -Mechanism Sleeper
    Assert-True $ok 'sleeper e2e: registration succeeds'
    $e2ePid = [int](Get-ExpiryState).sleeperPid
    $script:sleeperPids += $e2ePid
    Assert-True (Test-Path -LiteralPath $sessionFile) 'sleeper e2e: the session file exists right after registration'
    Assert-True (Test-ProcessAlive $e2ePid) 'sleeper e2e: the sleeper is running'
    $gone = Wait-ForCondition -Test { -not (Test-Path -LiteralPath $sessionFile) } -TimeoutSeconds 110
    Assert-True $gone 'sleeper e2e: the session file is gone after the TTL mark (no vault use in between)'
    Assert-True (-not (Test-Path -LiteralPath $ttlFile)) 'sleeper e2e: session.ttl is gone too'
    Assert-Contains (Get-Calls) 'lock' 'sleeper e2e: the expiry ran bw lock'
    $statusOut = (& $bw status | Out-String | ConvertFrom-Json)
    Assert-Equal 'locked' $statusOut.status 'sleeper e2e: bw status reports locked (the cli stays signed in) after the TTL mark'
    Assert-True (-not (Test-Path -LiteralPath $expiryFile)) 'sleeper e2e: expiry.json is cleaned up after firing'
    Assert-True (-not (Test-ProcessAlive $e2ePid)) 'sleeper e2e: no sleeper process is left behind'

    # 8. END TO END (real systemd timer, linux only): the preferred linux
    # mechanism fires the real wrapper through the real system bus. if the
    # bus is unavailable here, Register returns $false and the section
    # asserts the Auto fallback instead of pretending the timer ran.
    if ($env:OS -eq 'Windows_NT') {
        Write-Host 'NOTE: the real-systemd e2e section is linux-only; on windows the schtasks command is covered by the fake-scheduler section above and a live schtasks firing is unproven in this session.' -ForegroundColor Yellow
    } else {
        $env:PATH = $basePath
        Reset-FakeBw
        Set-VaultSessionKey -SessionKey 'fakesessionkey0123456789abcdef' -TtlMinutes 1 | Out-Null
        $ok = Register-VaultSessionExpiry -TtlMinutes 1 -Mechanism Systemd
        if (-not $ok) {
            Write-Host 'NOTE: systemd-run could not create the timer on this machine - asserting the Auto fallback to the sleeper instead.' -ForegroundColor Yellow
            $okAuto = Register-VaultSessionExpiry -TtlMinutes 60 -Mechanism Auto
            Assert-True $okAuto 'systemd unavailable: Auto registration still succeeds via fallback'
            Assert-Equal 'sleeper' (Get-ExpiryState).mechanism 'systemd unavailable: Auto falls back to the sleeper'
            $null = Unregister-VaultSessionExpiry
        } else {
            $timerState = (& systemctl show mainframe-vault-expiry.timer -p ActiveState 2>$null | Out-String)
            Assert-Contains $timerState 'ActiveState=active' 'systemd e2e: the transient timer is active after registration'
            Assert-True (Test-Path -LiteralPath $sessionFile) 'systemd e2e: the session file exists right after registration'
            $gone = Wait-ForCondition -Test { -not (Test-Path -LiteralPath $sessionFile) } -TimeoutSeconds 110
            Assert-True $gone 'systemd e2e: the session file is gone after the TTL mark (no vault use in between)'
            Assert-Contains (Get-Calls) 'lock' 'systemd e2e: the expiry ran bw lock'
            $statusOut = (& $bw status | Out-String | ConvertFrom-Json)
            Assert-Equal 'locked' $statusOut.status 'systemd e2e: bw status reports locked (the cli stays signed in) after the TTL mark'
            Assert-True (-not (Test-Path -LiteralPath $expiryFile)) 'systemd e2e: expiry.json is cleaned up after firing'
            $timersLeft = (& systemctl list-timers mainframe-vault-expiry.timer --no-pager 2>$null | Out-String)
            Assert-NotContains $timersLeft 'mainframe-vault-expiry.timer' 'systemd e2e: no timer is left behind after firing'
        }
    }
} finally {
    try { Unregister-VaultSessionExpiry | Out-Null } catch {}
    foreach ($spid in $script:sleeperPids) {
        try { if (Test-ProcessAlive $spid) { Stop-Process -Id $spid -Force -ErrorAction SilentlyContinue } } catch {}
    }
    $env:PATH = $savedPath
    $env:MAINFRAME_PROFILE_ROOT = $savedProfile
    Remove-Item -Path 'Env:\BW_SESSION' -ErrorAction SilentlyContinue
    Remove-Item -Path 'Env:\MAINFRAME_VAULT_SESSION_STARTED_UNIX' -ErrorAction SilentlyContinue
    Remove-Item -Path 'Env:\MF_FAKE_SYSTEMD_FAIL' -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "vault-session-scheduled-expiry checks: $script:checks passed" -ForegroundColor Green
