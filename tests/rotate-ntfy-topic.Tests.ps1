#Requires -Version 7
# No Pester dependency. No network, no real vault, no real relay: every
# `bw` call goes to a fake bw (tests/mock-bw.py) in a temp bin dir on
# PATH, and every Invoke-RestMethod goes to the mock in
# tests/mock-rest-harness.ps1, which dot-sources the target script in a
# child pwsh (so the script's own `exit` codes are observable).
# The VM's egress proxy blocks even localhost TCP, so no local HTTP
# listener is used anywhere here.
#
# What it pins: a rotation writes the vault topic item first, then the
# local config, then PUTs the updated profile config as the bootstrap
# bundle under the permanent link's token. A failed push fails LOUDLY
# at the end (exit 1) with the -PushOnly recovery - and the rotation
# itself is NEVER rolled back. -ShowCurrent stays read-only.
#
# TRIPWIRE: the script also writes the checkout-root
# mainframe.config.json when one exists and carries a topic. This test
# refuses to run when that file exists, so it can never rewrite a real
# checkout config.
$ErrorActionPreference = 'Stop'

$script:checks = 0
function Assert-True($Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:checks++
}
function Assert-Equal($Expected, $Actual, [string]$Message) {
    if ($Expected -ne $Actual) { throw "FAIL: $Message`n  expected: $Expected`n  actual:   $Actual" }
    $script:checks++
}
function Assert-Contains($Haystack, [string]$Needle, [string]$Message) {
    if ($Haystack -notmatch [regex]::Escape($Needle)) { throw "FAIL: $Message (missing: $Needle)" }
    $script:checks++
}
function Assert-NotContains($Haystack, [string]$Needle, [string]$Message) {
    if ($Haystack -match [regex]::Escape($Needle)) { throw "FAIL: $Message (must not contain: $Needle)" }
    $script:checks++
}

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$target = Join-Path $repoRoot 'windows/rotate-ntfy-topic.ps1'
$harness = Join-Path $PSScriptRoot 'mock-rest-harness.ps1'
$mockBwSource = Join-Path $PSScriptRoot 'mock-bw.py'
$topicItemName = 'github.com/FahadBinHussain/mainframe / mainframe.ntfy-topic'
$linkItemName = 'github.com/FahadBinHussain/mainframe / mainframe.bootstrap-link'
$script:fakeOldTopic = 'o' * 32
$script:fakeNewTopic = 'n' * 32
$script:fakeToken = 'CcCcCcCcCcCcCcCcCcCcCc'
$script:fakeVaultToken = 'DdDdDdDdDdDdDdDdDdDdDd'
$script:relayServer = 'https://relay.example.invalid/ntfy'
$script:relayBase = 'https://relay.example.invalid'

$checkoutConfig = Join-Path $repoRoot 'mainframe.config.json'
if (Test-Path -LiteralPath $checkoutConfig) {
    throw "FAIL: checkout config exists at $checkoutConfig - this test refuses to run, because the script under test would rewrite it. move it aside first."
}

# the target parses (a bare [ref]$null parse check gives a FALSE clean -
# $tokens/$errs are initialized first).
$tokens = $null; $errs = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($target, [ref]$tokens, [ref]$errs)
Assert-True ($errs.Count -eq 0) 'rotate-ntfy-topic.ps1 parses'

$python = Get-Command python3 -ErrorAction SilentlyContinue
if (-not $python) { $python = Get-Command python -ErrorAction SilentlyContinue }
if (-not $python) { throw 'FAIL: no python3/python on PATH - the mock bw needs it' }
$pwshExe = [System.Environment]::ProcessPath
if (-not $pwshExe -or -not (Test-Path -LiteralPath $pwshExe)) {
    $pwshExe = Join-Path $PSHOME (if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })
}

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('mf-rotate-test-' + [Guid]::NewGuid().ToString('N'))
$bin = Join-Path $tempRoot 'bin'
$profile = Join-Path $tempRoot 'profile'
$bwState = Join-Path $tempRoot 'bw-state'
$restState = Join-Path $tempRoot 'rest-state'
$callLog = Join-Path $tempRoot 'calls.log'
$restCapture = Join-Path $tempRoot 'rest.jsonl'
$configPath = Join-Path $profile 'mainframe.config.json'

function Reset-CaseState {
    param([string]$RestMode = 'ok')
    $env:MF_REST_MODE = $RestMode
    Set-Content -LiteralPath $callLog -Value '' -NoNewline
    Set-Content -LiteralPath $restCapture -Value '' -NoNewline
    Set-Content -LiteralPath (Join-Path $bwState 'items.json') -Value '[]' -NoNewline
}
function Set-TestConfig {
    # $Token is deliberately UNTYPED: a [string]$Token = $null default
    # coerces $null to '' and the fixture would always carry an (empty)
    # bootstrapToken property, so no test ever exercised a config with
    # NO such property at all (the real first-run shape - see the same
    # note in tests/new-bootstrap-link.Tests.ps1).
    param([string]$Topic = $script:fakeOldTopic, [string]$Server = $script:relayServer, $Token = $null)
    $obj = [ordered]@{ bitwardenEmail = 'test@example.invalid'; ntfyTopic = $Topic; ntfyServer = $Server; pagesBase = 'https://example.invalid'; vaultTtlMinutes = 60 }
    if ($null -ne $Token) { $obj.bootstrapToken = $Token }
    ($obj | ConvertTo-Json) | Set-Content -LiteralPath $configPath -NoNewline
}
function Set-VaultItems {
    param([array]$Items)
    Set-Content -LiteralPath (Join-Path $bwState 'items.json') -Value (ConvertTo-Json -InputObject $Items -Compress) -NoNewline
}
function Get-TestConfig { return (Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json) }
function Get-VaultItems {
    $itemsFile = Join-Path $bwState 'items.json'
    if (-not (Test-Path -LiteralPath $itemsFile)) { return @() }
    $raw = Get-Content -LiteralPath $itemsFile -Raw
    if (-not $raw -or $raw.Trim() -eq '' -or $raw.Trim() -eq '[]') { return @() }
    return @($raw | ConvertFrom-Json)
}
function Get-VaultItemByName {
    param([string]$Name)
    return @(Get-VaultItems | Where-Object { $_.name -eq $Name }) | Select-Object -First 1
}
function Get-CallLog {
    if (-not (Test-Path -LiteralPath $callLog)) { return @() }
    return @(Get-Content -LiteralPath $callLog | Where-Object { $_.Trim() })
}
function Get-RestCalls {
    if (-not (Test-Path -LiteralPath $restCapture)) { return @() }
    $lines = @(Get-Content -LiteralPath $restCapture | Where-Object { $_.Trim() })
    return @($lines | ForEach-Object { $_ | ConvertFrom-Json })
}
function Invoke-Target {
    param([hashtable]$TargetArgs = @{})
    $env:MF_HARNESS_ARGS = (ConvertTo-Json -InputObject $TargetArgs -Compress)
    $outLines = & $pwshExe -NoProfile -File $harness -Target $target 2>&1 6>&1
    $code = $LASTEXITCODE
    return [pscustomobject]@{ Code = $code; Output = ($outLines | Out-String) }
}

$savedPath = $env:PATH
$savedProfile = $env:MAINFRAME_PROFILE_ROOT
$savedBwState = $env:MF_MOCK_BW_STATE
$savedCallLog = $env:MF_CALL_LOG
$savedRestCapture = $env:MF_REST_CAPTURE
$savedRestState = $env:MF_REST_STATE
$savedRestMode = $env:MF_REST_MODE
$savedHarnessArgs = $env:MF_HARNESS_ARGS
try {
    New-Item -ItemType Directory -Force -Path $bin, $profile, $bwState, $restState | Out-Null
    New-Item -ItemType File -Force -Path $callLog, $restCapture | Out-Null
    Set-Content -LiteralPath (Join-Path $bwState 'items.json') -Value '[]' -NoNewline
    if ($env:OS -eq 'Windows_NT') {
        Copy-Item -LiteralPath $mockBwSource -Destination (Join-Path $bin 'mock-bw.py') -Force
        $bwCmd = Join-Path $bin 'bw.cmd'
        "@echo off`r`n`"$($python.Source)`" `"%~dp0mock-bw.py`" %*`r`n" | Set-Content -LiteralPath $bwCmd -Encoding ASCII
    } else {
        $bw = Join-Path $bin 'bw'
        Copy-Item -LiteralPath $mockBwSource -Destination $bw -Force
        & chmod 755 $bw
    }
    $env:PATH = "$bin$([IO.Path]::PathSeparator)$savedPath"
    $env:MAINFRAME_PROFILE_ROOT = $profile
    $env:MF_MOCK_BW_STATE = $bwState
    $env:MF_CALL_LOG = $callLog
    $env:MF_REST_CAPTURE = $restCapture
    $env:MF_REST_STATE = $restState

    # 1. -Topic rotation pushes the bundle under the local token.
    Reset-CaseState
    Set-TestConfig -Token $script:fakeToken
    Set-VaultItems @([pscustomobject]@{ id = 'mock-id-1'; name = $topicItemName; notes = $script:fakeOldTopic })
    $run = Invoke-Target -TargetArgs @{ Topic = $script:fakeNewTopic }
    Assert-Equal 0 $run.Code 'rotation exits 0'
    Assert-Contains $run.Output 'bootstrap bundle: pushed' 'rotation reports the bundle push'
    Assert-Contains $run.Output 'nnnn' 'rotation reports the new fingerprint'
    Assert-NotContains $run.Output $script:fakeNewTopic 'the new topic is never printed by default'
    Assert-Equal $script:fakeNewTopic (Get-VaultItemByName $topicItemName).notes 'the vault topic item holds the new topic'
    Assert-Equal $script:fakeNewTopic (Get-TestConfig).ntfyTopic 'the local config holds the new topic'
    Assert-Equal $script:fakeToken (Get-TestConfig).bootstrapToken 'the rotation keeps the bootstrap token'
    $rest = Get-RestCalls
    Assert-Equal 1 $rest.Count 'rotation makes exactly one relay call'
    Assert-Equal 'Put' $rest[0].method 'rotation PUTs the bundle'
    Assert-Equal "$script:relayBase/bootstrap/$script:fakeToken" $rest[0].uri 'rotation PUTs under the local token'
    Assert-Equal $script:fakeNewTopic (($rest[0].body | ConvertFrom-Json).ntfyTopic) 'the pushed bundle carries the NEW topic'
    $calls = Get-CallLog
    $vaultWriteAt = -1; $putAt = -1
    for ($i = 0; $i -lt $calls.Count; $i++) {
        if ($calls[$i] -like 'BW edit item*') { $vaultWriteAt = $i }
        if ($calls[$i] -like 'REST Put*') { $putAt = $i }
    }
    Assert-True ($vaultWriteAt -ge 0 -and $putAt -gt $vaultWriteAt) 'the vault write happens BEFORE the bundle push'

    # 2. plain run (generated topic) pushes too, and the pushed bundle
    #    matches what landed in the local config. empty vault: the topic
    #    item is created, not edited.
    Reset-CaseState
    Set-TestConfig -Token $script:fakeToken
    $run = Invoke-Target
    Assert-Equal 0 $run.Code 'plain rotation exits 0'
    Assert-Contains $run.Output 'bootstrap bundle: pushed' 'plain rotation reports the bundle push'
    $cfg = Get-TestConfig
    Assert-True ($cfg.ntfyTopic -cmatch '^[a-z0-9]{32}$' -and $cfg.ntfyTopic -ne $script:fakeOldTopic) 'plain rotation generates a fresh topic'
    Assert-Equal $cfg.ntfyTopic (Get-VaultItemByName $topicItemName).notes 'plain rotation writes the generated topic to the vault'
    $rest = Get-RestCalls
    Assert-Equal 1 $rest.Count 'plain rotation makes exactly one relay call'
    Assert-Equal $cfg.ntfyTopic (($rest[0].body | ConvertFrom-Json).ntfyTopic) 'the pushed bundle matches the local config'
    Assert-True ((Get-CallLog) -contains 'BW create item') 'an empty vault gets the topic item created'

    # 3. no local token: the token comes from the vault link item.
    Reset-CaseState
    Set-TestConfig
    Set-VaultItems @(
        [pscustomobject]@{ id = 'mock-id-1'; name = $topicItemName; notes = $script:fakeOldTopic },
        [pscustomobject]@{ id = 'mock-id-2'; name = $linkItemName; notes = "$script:relayBase/bootstrap/$script:fakeVaultToken" }
    )
    $run = Invoke-Target -TargetArgs @{ Topic = $script:fakeNewTopic }
    Assert-Equal 0 $run.Code 'rotation with a vault token exits 0'
    Assert-Contains $run.Output 'bootstrap bundle: pushed' 'rotation with a vault token reports the push'
    $rest = Get-RestCalls
    Assert-Equal 1 $rest.Count 'rotation with a vault token makes exactly one relay call'
    Assert-Equal "$script:relayBase/bootstrap/$script:fakeVaultToken" $rest[0].uri 'rotation with a vault token PUTs under the vault token'

    # 4. no token anywhere: exit 1, but the rotation itself happened -
    #    vault + local are new, only the bundle is stale.
    Reset-CaseState
    Set-TestConfig
    Set-VaultItems @([pscustomobject]@{ id = 'mock-id-1'; name = $topicItemName; notes = $script:fakeOldTopic })
    $run = Invoke-Target -TargetArgs @{ Topic = $script:fakeNewTopic }
    Assert-Equal 1 $run.Code 'rotation without a link exits 1'
    Assert-Contains $run.Output 'bootstrap bundle: NOT pushed' 'rotation without a link reports the failed push'
    Assert-Contains $run.Output 'was ever created' 'rotation without a link names the cause'
    Assert-Contains $run.Output 'BOOTSTRAP BUNDLE PUSH FAILED' 'rotation without a link fails loudly at the end'
    Assert-Contains $run.Output 'new-bootstrap-link.ps1' 'rotation without a link gives the recovery'
    Assert-Equal $script:fakeNewTopic (Get-VaultItemByName $topicItemName).notes 'the vault rotation still happened'
    Assert-Equal $script:fakeNewTopic (Get-TestConfig).ntfyTopic 'the local rotation still happened'
    Assert-Equal 0 (Get-RestCalls).Count 'rotation without a link makes no relay call'

    # 5. the relay refuses the PUT: exit 1, rotation kept, -PushOnly is
    #    the recovery.
    Reset-CaseState -RestMode 'put-fail'
    Set-TestConfig -Token $script:fakeToken
    Set-VaultItems @([pscustomobject]@{ id = 'mock-id-1'; name = $topicItemName; notes = $script:fakeOldTopic })
    $run = Invoke-Target -TargetArgs @{ Topic = $script:fakeNewTopic }
    Assert-Equal 1 $run.Code 'rotation with a refused PUT exits 1'
    Assert-Contains $run.Output 'BOOTSTRAP BUNDLE PUSH FAILED' 'a refused PUT fails loudly at the end'
    Assert-Contains $run.Output 'new-bootstrap-link.ps1 -PushOnly' 'a refused PUT gives the exact recovery'
    Assert-Contains $run.Output 'NOT rolled back' 'a refused PUT says the rotation stands'
    Assert-Equal $script:fakeNewTopic (Get-VaultItemByName $topicItemName).notes 'the vault rotation still happened'
    Assert-Equal $script:fakeNewTopic (Get-TestConfig).ntfyTopic 'the local rotation still happened'
    Assert-Equal 1 (Get-RestCalls).Count 'the PUT was attempted once'

    # 6. the relay guard fails (bare ntfy.sh): exit 1, rotation kept,
    #    fix ntfyServer + -PushOnly is the recovery, no relay call.
    Reset-CaseState
    Set-TestConfig -Server 'https://ntfy.sh' -Token $script:fakeToken
    Set-VaultItems @([pscustomobject]@{ id = 'mock-id-1'; name = $topicItemName; notes = $script:fakeOldTopic })
    $run = Invoke-Target -TargetArgs @{ Topic = $script:fakeNewTopic }
    Assert-Equal 1 $run.Code 'rotation with a bad relay base exits 1'
    Assert-Contains $run.Output 'does not end in /ntfy' 'a bad relay base names itself'
    Assert-Contains $run.Output 'fix ntfyServer' 'a bad relay base gives the fix'
    Assert-Contains $run.Output 'new-bootstrap-link.ps1 -PushOnly' 'a bad relay base gives the re-push recovery'
    Assert-Equal $script:fakeNewTopic (Get-TestConfig).ntfyTopic 'the local rotation still happened'
    Assert-Equal 0 (Get-RestCalls).Count 'a bad relay base makes no relay call'

    # 7. -ShowCurrent stays read-only: no push, no bw, no write.
    Reset-CaseState
    Set-TestConfig -Token $script:fakeToken
    $before = Get-Content -LiteralPath $configPath -Raw
    $run = Invoke-Target -TargetArgs @{ ShowCurrent = $true }
    Assert-Equal 0 $run.Code 'show-current exits 0'
    Assert-Contains $run.Output 'nothing changed' 'show-current says nothing changed'
    Assert-True ((Get-CallLog).Count -eq 0) 'show-current touches neither bw nor the relay'
    Assert-Equal $before (Get-Content -LiteralPath $configPath -Raw) 'show-current leaves the config alone'
    Assert-True ((Get-VaultItems).Count -eq 0) 'show-current writes no vault item'

    # 8. duplicate vault topic items: refuse loudly before rotating.
    #    same shape as the link-item duplicates (a "failed" bw write
    #    that landed server-side, then a retry that made another item).
    Reset-CaseState
    Set-TestConfig -Token $script:fakeToken
    Set-VaultItems @([pscustomobject]@{ id = 'mock-id-1'; name = $topicItemName; notes = $script:fakeOldTopic }, [pscustomobject]@{ id = 'mock-id-2'; name = $topicItemName; notes = $script:fakeOldTopic })
    $before = Get-Content -LiteralPath $configPath -Raw
    $run = Invoke-Target -TargetArgs @{ Topic = $script:fakeNewTopic }
    Assert-True ($run.Code -ne 0) 'duplicate topic items exit non-zero'
    Assert-Contains $run.Output 'found 2 vault items' 'duplicate topic items are named'
    Assert-Contains $run.Output 'mock-id-1' 'duplicate topic items list the first id'
    Assert-Contains $run.Output 'mock-id-2' 'duplicate topic items list the second id'
    Assert-Equal $before (Get-Content -LiteralPath $configPath -Raw) 'duplicate topic items leave the config alone'
    Assert-Equal 0 (Get-RestCalls).Count 'duplicate topic items make no relay call'
} finally {
    if ($null -eq $savedProfile) { Remove-Item Env:MAINFRAME_PROFILE_ROOT -ErrorAction SilentlyContinue } else { $env:MAINFRAME_PROFILE_ROOT = $savedProfile }
    if ($null -eq $savedBwState) { Remove-Item Env:MF_MOCK_BW_STATE -ErrorAction SilentlyContinue } else { $env:MF_MOCK_BW_STATE = $savedBwState }
    if ($null -eq $savedCallLog) { Remove-Item Env:MF_CALL_LOG -ErrorAction SilentlyContinue } else { $env:MF_CALL_LOG = $savedCallLog }
    if ($null -eq $savedRestCapture) { Remove-Item Env:MF_REST_CAPTURE -ErrorAction SilentlyContinue } else { $env:MF_REST_CAPTURE = $savedRestCapture }
    if ($null -eq $savedRestState) { Remove-Item Env:MF_REST_STATE -ErrorAction SilentlyContinue } else { $env:MF_REST_STATE = $savedRestState }
    if ($null -eq $savedRestMode) { Remove-Item Env:MF_REST_MODE -ErrorAction SilentlyContinue } else { $env:MF_REST_MODE = $savedRestMode }
    if ($null -eq $savedHarnessArgs) { Remove-Item Env:MF_HARNESS_ARGS -ErrorAction SilentlyContinue } else { $env:MF_HARNESS_ARGS = $savedHarnessArgs }
    $env:PATH = $savedPath
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host "rotate-ntfy-topic checks: $script:checks passed"
