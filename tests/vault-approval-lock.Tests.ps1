# No Pester dependency. Runs under windows powershell 5.1 AND pwsh 7.
#
# The approval flow must ask the phone ONCE, no matter how many agents ask at
# the same moment. This checks the single-flight lock that guarantees it:
#
#   1. two requesters that start together produce exactly ONE push, and the
#      second one only asks the phone after the first one went stale
#   2. a waiter that sees a session key appear while it waits returns
#      __SESSION_ALREADY_UNLOCKED__ and never pushes
#   3. a locks left behind by a dead requester is taken over once its deadline
#      lapses, so a queue can never wedge
#
# Nothing here touches the network, the real vault or the phone: the push, the
# relay and the adb popup are replaced inside the module, and the profile root
# is a temp directory.
$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$module = Join-Path $repo 'vault-approval.psm1'

$script:checks = 0
function Assert-True($Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:checks++
}
function Assert-Equal($Expected, $Actual, [string]$Message) {
    if ($Expected -ne $Actual) { throw "FAIL: $Message`n  expected: $Expected`n  actual:   $Actual" }
    $script:checks++
}

$root = Join-Path ([IO.Path]::GetTempPath()) ("vault-lock-test-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$profile = Join-Path $root 'profile'
$log = Join-Path $root 'pushes.log'
New-Item -ItemType Directory -Force -Path (Join-Path (Join-Path $profile 'accounts') 'bitwarden') | Out-Null
$lockPath = Join-Path (Join-Path (Join-Path $profile 'accounts') 'bitwarden') 'approval.lock'
$sessionFile = Join-Path (Join-Path (Join-Path $profile 'accounts') 'bitwarden') 'session.key'

# the child that plays a real requester: same module, fake push / relay / adb
$driver = Join-Path $root 'driver.ps1'
@'
param(
    [string]$ModulePath,
    [string]$ProfileRoot,
    [int]$TimeoutSeconds,
    [string]$Tag
)
$ErrorActionPreference = 'Stop'
$env:MAINFRAME_PROFILE_ROOT = $ProfileRoot
Import-Module $ModulePath -Force -DisableNameChecking

# replace the three side effects inside the module's own scope, so
# Get-VaultMasterPassword uses them exactly as the real ones would be used.
& (Get-Module vault-approval) {
    function script:Send-VaultApprovalNotification {
        param([string]$Topic, [string]$Url, [string]$HostName, [string]$Code, [string]$PromptContext, [string]$Agent, [string]$Model, [string]$Server)
        $line = 'push|{0}|{1}|{2}' -f $env:MF_TAG, $Code, [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        for ($i = 0; $i -lt 50; $i++) {
            try { [IO.File]::AppendAllText($env:MF_LOG, $line + "`n"); break } catch { Start-Sleep -Milliseconds 50 }
        }
        return $true
    }
    function script:Send-VaultRequestExpired {
        param([string]$Sid, [string]$HostName, [string]$Code, [string]$Server)
        return $true
    }
    function script:Open-VaultApprovalOnPhone {
        param([string]$Url)
        return $false
    }
}

$pw = Get-VaultMasterPassword -NtfyTopic 'lock-test-topic' -Server 'http://127.0.0.1:1' `
    -TimeoutSeconds $TimeoutSeconds -PromptContext "lock test" -Agent 'lock-test' -Model 'none'
if ($pw -eq '__SESSION_ALREADY_UNLOCKED__') { Write-Output 'RESULT:already-unlocked' }
elseif ($pw) { Write-Output 'RESULT:password' }
else { Write-Output 'RESULT:none' }
'@ | Set-Content -LiteralPath $driver -Encoding ASCII

function Get-Pushes {
    if (-not (Test-Path -LiteralPath $log)) { return @() }
    return @(Get-Content -LiteralPath $log | Where-Object { $_ -match '^push\|' })
}

$hostExe = if ($PSVersionTable.PSEdition -eq 'Core') { Join-Path $PSHOME 'pwsh.exe' } else { Join-Path $PSHOME 'powershell.exe' }

$savedRoot = $env:MAINFRAME_PROFILE_ROOT
$savedLog = $env:MF_LOG
$savedTag = $env:MF_TAG
$children = @()
try {
    $env:MAINFRAME_PROFILE_ROOT = $profile
    $env:MF_LOG = $log
    $env:MF_TAG = 'first'
    Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue

    # --- 1. two requesters at the same moment: exactly one push, then the
    #        next one only after the first went stale -----------------------
    $out1 = Join-Path $root 'first.out'
    $out2 = Join-Path $root 'second.out'
    $first = Start-Process -FilePath $hostExe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$driver`" -ModulePath `"$module`" -ProfileRoot `"$profile`" -TimeoutSeconds 6 -Tag first" -RedirectStandardOutput $out1 -RedirectStandardError (Join-Path $root 'first.err') -WindowStyle Hidden -PassThru
    $env:MF_TAG = 'second'
    $second = Start-Process -FilePath $hostExe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$driver`" -ModulePath `"$module`" -ProfileRoot `"$profile`" -TimeoutSeconds 6 -Tag second" -RedirectStandardOutput $out2 -RedirectStandardError (Join-Path $root 'second.err') -WindowStyle Hidden -PassThru
    $children = @($first, $second)

    $pushDeadline = (Get-Date).AddSeconds(5)
    while ((Get-Pushes).Count -eq 0 -and (Get-Date) -lt $pushDeadline) { Start-Sleep -Milliseconds 200 }
    Assert-Equal 1 (Get-Pushes).Count 'two simultaneous requesters put exactly ONE prompt on the phone'

    $null = $first.WaitForExit(60000)
    $null = $second.WaitForExit(60000)
    Assert-True $first.HasExited 'the first requester finished'
    Assert-True $second.HasExited 'the second requester finished'

    $pushes = Get-Pushes
    Assert-Equal 2 $pushes.Count 'the second requester asked the phone only after the first went stale'
    $firstAt = [long](($pushes[0] -split '\|')[3])
    $secondAt = [long](($pushes[1] -split '\|')[3])
    Assert-True (($secondAt - $firstAt) -ge 5000) "the second prompt waited for the first to go stale (gap $($secondAt - $firstAt)ms)"
    Assert-True (-not (Test-Path -LiteralPath $lockPath)) 'the turn is released when both requests are done'

    $firstText = (Get-Content -LiteralPath $out1 -Raw) -join "`n"
    $secondText = (Get-Content -LiteralPath $out2 -Raw) -join "`n"
    Assert-True ($firstText -match 'RESULT:none') 'the first requester timed out as expected'
    Assert-True ($secondText -match 'RESULT:none') 'the second requester timed out as expected'
    $children = @()

    # --- 2. a waiter never pushes when a session key appears -----------------
    Import-Module $module -Force -DisableNameChecking
    Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $sessionFile -Force -ErrorAction SilentlyContinue

    $since = [DateTime]::UtcNow
    $turn = Enter-VaultApprovalRequest -PromptContext 'holder' -TimeoutSeconds 30 -Agent 'holder' -HostName 'test-host' -SinceUtc $since
    Assert-True $turn.Acquired 'the holder took the turn'

    $env:MF_TAG = 'waiter'
    $waiter = Start-Process -FilePath $hostExe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$driver`" -ModulePath `"$module`" -ProfileRoot `"$profile`" -TimeoutSeconds 20 -Tag waiter" -RedirectStandardOutput (Join-Path $root 'waiter.out') -RedirectStandardError (Join-Path $root 'waiter.err') -WindowStyle Hidden -PassThru
    $children = @($waiter)

    Start-Sleep -Seconds 2
    Set-Content -LiteralPath $sessionFile -Value 'session-key-written-by-the-holder' -NoNewline
    $null = $waiter.WaitForExit(60000)
    Assert-True $waiter.HasExited 'the waiter finished'
    $waiterText = Get-Content -LiteralPath (Join-Path $root 'waiter.out') -Raw
    Assert-True ($waiterText -match 'RESULT:already-unlocked') 'the waiter reported the unlock instead of asking the phone'
    Assert-Equal 0 (Get-Pushes).Count 'the waiter pushed NOTHING while another request was in flight'
    Close-VaultApprovalRequest -Path $turn.Path -Token $turn.Token
    $children = @()

    # --- 3. a dead requester's turn is taken over after its deadline --------
    Remove-Item -LiteralPath $sessionFile -Force -ErrorAction SilentlyContinue
    $stale = [ordered]@{
        token = 'stale-token'; pid = 999999; host = 'dead-host'; context = 'crashed'
        agent = 'crashed-agent'; model = ''; state = 'pending'; code = '77'; sid = 'mf-vault-dead'
        startedAt = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 300
        expiresAt = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 10
    }
    Set-Content -LiteralPath $lockPath -Value (ConvertTo-Json -InputObject $stale -Compress) -NoNewline
    $taken = Enter-VaultApprovalRequest -PromptContext 'takeover' -TimeoutSeconds 5 -Agent 'takeover' -SinceUtc ([DateTime]::UtcNow)
    Assert-True $taken.Acquired 'the expired turn is taken over instead of blocking the queue forever'
    Assert-True ($taken.Token -ne 'stale-token') 'the takeover replaced the dead request record'
    Close-VaultApprovalRequest -Path $taken.Path -Token $taken.Token
    Assert-True (-not (Test-Path -LiteralPath $lockPath)) 'the takeover record is released normally'

    # --- 4. an approved request that nobody followed up on is reused at once,
    #        without the crash grace (its state is terminal, not mysterious) --
    $resolved = [ordered]@{
        token = 'resolved-token'; pid = 999998; host = 'old-host'; context = 'done'
        agent = 'old-agent'; model = ''; state = 'approved'; code = '12'; sid = 'mf-vault-done'
        startedAt = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 60
        expiresAt = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 5
    }
    Set-Content -LiteralPath $lockPath -Value (ConvertTo-Json -InputObject $resolved -Compress) -NoNewline
    $startedAt = Get-Date
    $reused = Enter-VaultApprovalRequest -PromptContext 'reuse' -TimeoutSeconds 5 -Agent 'reuse' -SinceUtc ([DateTime]::UtcNow)
    $elapsed = ((Get-Date) - $startedAt).TotalSeconds
    Assert-True $reused.Acquired 'a resolved request is handed over instead of blocking the queue'
    Assert-True ($elapsed -lt 3) "the handover does not wait for the crash grace ($([math]::Round($elapsed, 1))s)"
    Close-VaultApprovalRequest -Path $reused.Path -Token $reused.Token
} finally {
    foreach ($child in $children) {
        if ($child -and -not $child.HasExited) { Stop-Process -Id $child.Id -Force -ErrorAction SilentlyContinue }
    }
    $env:MAINFRAME_PROFILE_ROOT = $savedRoot
    $env:MF_LOG = $savedLog
    $env:MF_TAG = $savedTag
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "vault-approval lock checks: $script:checks passed"
