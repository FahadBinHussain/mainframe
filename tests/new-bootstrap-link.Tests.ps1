#Requires -Version 7
# No Pester dependency. No network, no real vault, no real relay: every
# `bw` call goes to a fake bw (tests/mock-bw.py) in a temp bin dir on
# PATH, and every Invoke-RestMethod goes to the mock in
# tests/mock-rest-harness.ps1, which dot-sources the target script in a
# child pwsh (so the script's own `exit` codes are observable).
# The VM's egress proxy blocks even localhost TCP, so no local HTTP
# listener is used anywhere here.
#
# What it pins: the ONE permanent link - the vault item is written
# FIRST (a dead session fails loudly and changes nothing), the token is
# generated locally, the bundle is PUT under it, the old token's bundle
# is deleted, and the local config is written last. -PushOnly re-pushes
# under the existing token without a new token, a vault write, or a
# printed link. Nothing secret but the link itself is ever printed.
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
$target = Join-Path $repoRoot 'windows/new-bootstrap-link.ps1'
$harness = Join-Path $PSScriptRoot 'mock-rest-harness.ps1'
$mockBwSource = Join-Path $PSScriptRoot 'mock-bw.py'
$linkItemName = 'github.com/FahadBinHussain/mainframe / mainframe.bootstrap-link'
$script:fakeTopic = 't' * 32
$script:fakeOldToken = 'AaAaAaAaAaAaAaAaAaAaAa'
$script:fakeVaultToken = 'BbBbBbBbBbBbBbBbBbBbBb'
$script:relayServer = 'https://relay.example.invalid/ntfy'
$script:relayBase = 'https://relay.example.invalid'

# the target + the harness parse (a bare [ref]$null parse check gives a
# FALSE clean - $tokens/$errs are initialized first).
$tokens = $null; $errs = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($target, [ref]$tokens, [ref]$errs)
Assert-True ($errs.Count -eq 0) 'new-bootstrap-link.ps1 parses'
$tokens = $null; $errs = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($harness, [ref]$tokens, [ref]$errs)
Assert-True ($errs.Count -eq 0) 'mock-rest-harness.ps1 parses'

$python = Get-Command python3 -ErrorAction SilentlyContinue
if (-not $python) { $python = Get-Command python -ErrorAction SilentlyContinue }
if (-not $python) { throw 'FAIL: no python3/python on PATH - the mock bw needs it' }
$pwshExe = [System.Environment]::ProcessPath
if (-not $pwshExe -or -not (Test-Path -LiteralPath $pwshExe)) {
    $pwshExe = Join-Path $PSHOME (if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })
}

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('mf-new-link-test-' + [Guid]::NewGuid().ToString('N'))
$bin = Join-Path $tempRoot 'bin'
$profile = Join-Path $tempRoot 'profile'
$bwState = Join-Path $tempRoot 'bw-state'
$restState = Join-Path $tempRoot 'rest-state'
$callLog = Join-Path $tempRoot 'calls.log'
$restCapture = Join-Path $tempRoot 'rest.jsonl'
$configPath = Join-Path $profile 'mainframe.config.json'

function Reset-CaseState {
    param([string]$RestMode = 'ok', [switch]$Locked)
    $env:MF_REST_MODE = $RestMode
    if ($Locked) { $env:MF_MOCK_BW_LOCKED = '1' } else { Remove-Item Env:MF_MOCK_BW_LOCKED -ErrorAction SilentlyContinue }
    Set-Content -LiteralPath $callLog -Value '' -NoNewline
    Set-Content -LiteralPath $restCapture -Value '' -NoNewline
    Remove-Item -LiteralPath (Join-Path $restState 'delete-count.txt') -ErrorAction SilentlyContinue
    Set-Content -LiteralPath (Join-Path $bwState 'items.json') -Value '[]' -NoNewline
}
function Set-TestConfig {
    # $Token is deliberately UNTYPED: a [string]$Token = $null default
    # coerces $null to '' and the fixture would always carry an (empty)
    # bootstrapToken property - which masked the real failure where a
    # pre-bootstrap config has NO such property at all (assigning a new
    # property to a ConvertFrom-Json object throws; the script must use
    # Add-Member). with $Token untyped, omitting -Token writes a config
    # with no bootstrapToken property, like a real first-run config.
    param([string]$Topic = $script:fakeTopic, [string]$Server = $script:relayServer, $Token = $null)
    $obj = [ordered]@{ bitwardenEmail = 'test@example.invalid'; ntfyTopic = $Topic; ntfyServer = $Server; pagesBase = 'https://example.invalid'; vaultTtlMinutes = 60 }
    if ($null -ne $Token) { $obj.bootstrapToken = $Token }
    ($obj | ConvertTo-Json) | Set-Content -LiteralPath $configPath -NoNewline
}
function Get-TestConfig { return (Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json) }
function Get-VaultItems {
    $itemsFile = Join-Path $bwState 'items.json'
    if (-not (Test-Path -LiteralPath $itemsFile)) { return @() }
    $raw = Get-Content -LiteralPath $itemsFile -Raw
    if (-not $raw -or $raw.Trim() -eq '' -or $raw.Trim() -eq '[]') { return @() }
    return @($raw | ConvertFrom-Json)
}
function Get-LinkItem { return @(Get-VaultItems | Where-Object { $_.name -eq $linkItemName }) | Select-Object -First 1 }
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
$savedLocked = $env:MF_MOCK_BW_LOCKED
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

    # 1. -DryRun validates and creates nothing: no bw, no relay, no write.
    Reset-CaseState
    Set-TestConfig
    $before = Get-Content -LiteralPath $configPath -Raw
    $run = Invoke-Target -TargetArgs @{ DryRun = $true }
    Assert-Equal 0 $run.Code 'dry run exits 0'
    Assert-Contains $run.Output $script:relayBase 'dry run prints the relay base'
    Assert-Contains $run.Output 'tttt' 'dry run prints the topic fingerprint'
    Assert-Contains $run.Output 'no link created' 'dry run says no link is created'
    Assert-True ((Get-CallLog).Count -eq 0) 'dry run touches neither bw nor the relay'
    Assert-Equal $before (Get-Content -LiteralPath $configPath -Raw) 'dry run leaves the config alone'
    Assert-True ((Get-VaultItems).Count -eq 0) 'dry run writes no vault item'

    # 2. plain run, first link: vault FIRST, then PUT, then local config.
    #    no old token, so no DELETE. the link is printed exactly once.
    Reset-CaseState
    Set-TestConfig
    $run = Invoke-Target
    Assert-Equal 0 $run.Code 'plain run exits 0'
    $linkMatches = [regex]::Matches($run.Output, 'https://relay\.example\.invalid/bootstrap/[A-Za-z0-9_-]{22}')
    Assert-Equal 1 $linkMatches.Count 'the link is printed exactly once'
    $link = $linkMatches[0].Value
    $token = $link.Substring($link.LastIndexOf('/') + 1)
    Assert-True ($token -cmatch '^[A-Za-z0-9_-]{22}$') 'the token is 22 base64url chars'
    Assert-NotContains $run.Output $script:fakeTopic 'the topic is never printed'
    Assert-Contains $run.Output 'permanent' 'the link is framed as permanent'
    Assert-NotContains $run.Output 'single-use' 'no single-use language survives'
    $item = Get-LinkItem
    Assert-True ($null -ne $item) 'the vault link item was created'
    Assert-Equal $link $item.notes 'the vault item holds the full link'
    $cfg = Get-TestConfig
    Assert-Equal $token $cfg.bootstrapToken 'the local config holds the new token'
    Assert-Equal $script:fakeTopic $cfg.ntfyTopic 'the local config keeps its topic'
    Assert-Equal $script:relayServer $cfg.ntfyServer 'the local config keeps its server'
    Assert-Equal 'test@example.invalid' $cfg.bitwardenEmail 'the local config keeps its email'
    if (-not $IsWindows) {
        Assert-Equal '600' (& stat -c %a $configPath) 'the local config stays mode 0600'
    }
    $rest = Get-RestCalls
    Assert-Equal 1 $rest.Count 'exactly one relay call (the PUT)'
    Assert-Equal 'Put' $rest[0].method 'the relay call is a PUT'
    Assert-Equal "$script:relayBase/bootstrap/$token" $rest[0].uri 'the PUT goes to the new token'
    $putBody = $rest[0].body | ConvertFrom-Json
    Assert-Equal $script:fakeTopic $putBody.ntfyTopic 'the PUT bundle carries the topic'
    Assert-Equal $token $putBody.bootstrapToken 'the PUT bundle carries its own token'
    $calls = Get-CallLog
    $vaultWriteAt = -1; $putAt = -1
    for ($i = 0; $i -lt $calls.Count; $i++) {
        if ($calls[$i] -like 'BW create item*') { $vaultWriteAt = $i }
        if ($calls[$i] -like 'REST Put*') { $putAt = $i }
    }
    Assert-True ($vaultWriteAt -ge 0 -and $putAt -gt $vaultWriteAt) 'the vault item is written BEFORE the relay PUT'

    # 3. plain run with an existing token: rotate - new token, vault edit,
    #    old bundle DELETE, local config updated.
    Reset-CaseState
    Set-TestConfig -Token $script:fakeOldToken
    $oldLink = "$script:relayBase/bootstrap/$script:fakeOldToken"
    Set-Content -LiteralPath (Join-Path $bwState 'items.json') -Value (ConvertTo-Json -InputObject @([pscustomobject]@{ id = 'mock-id-1'; name = $linkItemName; notes = $oldLink }) -Compress) -NoNewline
    $run = Invoke-Target
    Assert-Equal 0 $run.Code 'rotation run exits 0'
    $linkMatches = [regex]::Matches($run.Output, 'https://relay\.example\.invalid/bootstrap/[A-Za-z0-9_-]{22}')
    Assert-Equal 1 $linkMatches.Count 'rotation prints exactly one link'
    $newLink = $linkMatches[0].Value
    $newToken = $newLink.Substring($newLink.LastIndexOf('/') + 1)
    Assert-True ($newToken -ne $script:fakeOldToken) 'rotation generates a fresh token'
    Assert-Contains $run.Output 'previous link was retired' 'rotation says the old link was retired'
    Assert-Equal $newLink (Get-LinkItem).notes 'the vault item is edited to the new link'
    Assert-Equal $newToken (Get-TestConfig).bootstrapToken 'the local config holds the new token'
    $rest = Get-RestCalls
    $puts = @($rest | Where-Object { $_.method -eq 'Put' })
    $deletes = @($rest | Where-Object { $_.method -eq 'Delete' })
    Assert-Equal 1 $puts.Count 'rotation PUTs once'
    Assert-Equal "$script:relayBase/bootstrap/$newToken" $puts[0].uri 'rotation PUTs under the new token'
    Assert-Equal 1 $deletes.Count 'rotation DELETEs once'
    Assert-Equal "$script:relayBase/bootstrap/$script:fakeOldToken" $deletes[0].uri 'rotation DELETEs the old token'
    Assert-True ((Get-CallLog) -contains 'BW edit item') 'rotation edits (not re-creates) the vault item'

    # 4. dead vault session: LOUD failure, nothing touched anywhere.
    Reset-CaseState -Locked
    Set-TestConfig
    $before = Get-Content -LiteralPath $configPath -Raw
    $run = Invoke-Target
    Assert-True ($run.Code -ne 0) 'dead session exits non-zero'
    Assert-Contains $run.Output 'no live bw session' 'dead session names itself'
    Assert-True ((Get-RestCalls).Count -eq 0) 'dead session never reaches the relay'
    Assert-Equal $before (Get-Content -LiteralPath $configPath -Raw) 'dead session leaves the config alone'
    Assert-True ((Get-VaultItems).Count -eq 0) 'dead session writes no vault item'

    # 5. -PushOnly with a local token: PUT under it, no bw at all, no
    #    link printed, config untouched.
    Reset-CaseState
    Set-TestConfig -Token $script:fakeOldToken
    $before = Get-Content -LiteralPath $configPath -Raw
    $run = Invoke-Target -TargetArgs @{ PushOnly = $true }
    Assert-Equal 0 $run.Code 'push-only exits 0'
    Assert-Contains $run.Output 're-pushed' 'push-only confirms the re-push'
    Assert-Contains $run.Output 'tttt' 'push-only prints the topic fingerprint'
    Assert-NotContains $run.Output 'https://' 'push-only prints no link'
    Assert-NotContains $run.Output $script:fakeOldToken 'push-only prints no token'
    Assert-Equal $before (Get-Content -LiteralPath $configPath -Raw) 'push-only does not rewrite the config'
    Assert-True ((Get-VaultItems).Count -eq 0) 'push-only writes no vault item'
    $bwCalls = @(Get-CallLog | Where-Object { $_ -like 'BW *' })
    Assert-Equal 0 $bwCalls.Count 'push-only with a local token never calls bw'
    $rest = Get-RestCalls
    Assert-Equal 1 $rest.Count 'push-only makes exactly one relay call'
    Assert-Equal 'Put' $rest[0].method 'push-only PUTs'
    Assert-Equal "$script:relayBase/bootstrap/$script:fakeOldToken" $rest[0].uri 'push-only PUTs under the existing token'
    Assert-Equal $script:fakeTopic (($rest[0].body | ConvertFrom-Json).ntfyTopic) 'push-only PUTs the current config'

    # 6. -PushOnly with no local token: falls back to the vault link.
    Reset-CaseState
    Set-TestConfig
    $vaultLink = "$script:relayBase/bootstrap/$script:fakeVaultToken"
    Set-Content -LiteralPath (Join-Path $bwState 'items.json') -Value (ConvertTo-Json -InputObject @([pscustomobject]@{ id = 'mock-id-1'; name = $linkItemName; notes = $vaultLink }) -Compress) -NoNewline
    $run = Invoke-Target -TargetArgs @{ PushOnly = $true }
    Assert-Equal 0 $run.Code 'push-only from the vault exits 0'
    Assert-NotContains $run.Output 'https://' 'push-only from the vault prints no link'
    $rest = Get-RestCalls
    Assert-Equal 1 $rest.Count 'push-only from the vault makes exactly one relay call'
    Assert-Equal "$script:relayBase/bootstrap/$script:fakeVaultToken" $rest[0].uri 'push-only from the vault PUTs under the vault token'
    $bwWrites = @(Get-CallLog | Where-Object { $_ -like 'BW create item*' -or $_ -like 'BW edit item*' })
    Assert-Equal 0 $bwWrites.Count 'push-only never writes the vault'

    # 7. -PushOnly with no token anywhere: LOUD failure, no relay call.
    Reset-CaseState
    Set-TestConfig
    $run = Invoke-Target -TargetArgs @{ PushOnly = $true }
    Assert-True ($run.Code -ne 0) 'push-only without a token exits non-zero'
    Assert-Contains $run.Output 'no bootstrap token found anywhere' 'push-only without a token names itself'
    Assert-Contains $run.Output 'run this script plain once' 'push-only without a token gives the fix'
    Assert-True ((Get-RestCalls).Count -eq 0) 'push-only without a token never reaches the relay'

    # 8. the relay refuses the PUT: the vault already holds the new link,
    #    the local config is untouched, the recovery is a plain re-run.
    Reset-CaseState -RestMode 'put-fail'
    Set-TestConfig -Token $script:fakeOldToken
    $run = Invoke-Target
    Assert-True ($run.Code -ne 0) 'a refused PUT exits non-zero'
    Assert-Contains $run.Output 'refused the bootstrap bundle' 'a refused PUT names itself'
    Assert-Contains $run.Output 're-run this script plain' 'a refused PUT gives the recovery'
    Assert-True ($null -ne (Get-LinkItem)) 'a refused PUT still wrote the vault item first'
    Assert-Equal $script:fakeOldToken (Get-TestConfig).bootstrapToken 'a refused PUT leaves the local config alone'
    Assert-Equal 0 (@(Get-RestCalls | Where-Object { $_.method -eq 'Delete' }).Count) 'a refused PUT deletes nothing'

    # 9. the DELETE fails twice: exit 1, LOUD warning, the old token is
    #    NEVER printed, the local config keeps the old token.
    Reset-CaseState -RestMode 'delete-fail'
    Set-TestConfig -Token $script:fakeOldToken
    Set-Content -LiteralPath (Join-Path $bwState 'items.json') -Value (ConvertTo-Json -InputObject @([pscustomobject]@{ id = 'mock-id-1'; name = $linkItemName; notes = "$script:relayBase/bootstrap/$script:fakeOldToken" }) -Compress) -NoNewline
    $run = Invoke-Target
    Assert-Equal 1 $run.Code 'a failed DELETE exits 1'
    Assert-Contains $run.Output 'could not be deleted' 'a failed DELETE warns loudly'
    Assert-Contains $run.Output 'unguessable' 'a failed DELETE names the orphan inert'
    Assert-NotContains $run.Output $script:fakeOldToken 'a failed DELETE never prints the old token'
    Assert-Contains $run.Output 're-run this script plain' 'a failed DELETE gives the recovery'
    Assert-Equal $script:fakeOldToken (Get-TestConfig).bootstrapToken 'a failed DELETE leaves the local config on the old token'
    Assert-Equal 2 (@(Get-RestCalls | Where-Object { $_.method -eq 'Delete' }).Count) 'the DELETE is retried once'
    Assert-True ($null -ne (Get-LinkItem)) 'a failed DELETE still wrote the new vault link'

    # 10. the DELETE fails once, then succeeds: the retry saves the run.
    Reset-CaseState -RestMode 'delete-fail-once'
    Set-TestConfig -Token $script:fakeOldToken
    Set-Content -LiteralPath (Join-Path $bwState 'items.json') -Value (ConvertTo-Json -InputObject @([pscustomobject]@{ id = 'mock-id-1'; name = $linkItemName; notes = "$script:relayBase/bootstrap/$script:fakeOldToken" }) -Compress) -NoNewline
    $run = Invoke-Target
    Assert-Equal 0 $run.Code 'a retried DELETE exits 0'
    Assert-Equal 2 (@(Get-RestCalls | Where-Object { $_.method -eq 'Delete' }).Count) 'the DELETE ran twice (fail, then success)'
    Assert-True ((Get-TestConfig).bootstrapToken -ne $script:fakeOldToken) 'a retried DELETE still rotates the local config'

    # 11. a broken config refuses before bw or the relay is ever touched.
    Reset-CaseState
    Set-TestConfig -Topic 'NOT-A-VALID-TOPIC'
    $run = Invoke-Target
    Assert-True ($run.Code -ne 0) 'a bad topic exits non-zero'
    Assert-Contains $run.Output 'no valid ntfyTopic' 'a bad topic names itself'
    Assert-True ((Get-CallLog).Count -eq 0) 'a bad topic touches neither bw nor the relay'

    # 12. the relay guards hold: ntfyServer must end in /ntfy, over https.
    Reset-CaseState
    Set-TestConfig -Server 'https://ntfy.sh'
    $run = Invoke-Target
    Assert-True ($run.Code -ne 0) 'a bare ntfy.sh server exits non-zero'
    Assert-Contains $run.Output 'does not end in /ntfy' 'a bare ntfy.sh server names itself'
    Assert-True ((Get-CallLog).Count -eq 0) 'a bare ntfy.sh server touches neither bw nor the relay'
    Reset-CaseState
    Set-TestConfig -Server 'http://relay.example.invalid/ntfy'
    $run = Invoke-Target
    Assert-True ($run.Code -ne 0) 'a plain-http relay exits non-zero'
    Assert-Contains $run.Output 'is not https' 'a plain-http relay names itself'

    # 13. duplicate vault link items: refuse loudly, touch nothing.
    #    duplicates happen when a bw create/edit "fails" client-side
    #    after the server applied it (measured 2026-11-15: four
    #    same-name items after one flaky run).
    Reset-CaseState
    Set-TestConfig
    Set-Content -LiteralPath (Join-Path $bwState 'items.json') -Value (ConvertTo-Json -InputObject @([pscustomobject]@{ id = 'mock-id-1'; name = $linkItemName; notes = "$script:relayBase/bootstrap/$script:fakeOldToken" }, [pscustomobject]@{ id = 'mock-id-2'; name = $linkItemName; notes = "$script:relayBase/bootstrap/$script:fakeVaultToken" }) -Compress) -NoNewline
    $before = Get-Content -LiteralPath $configPath -Raw
    $run = Invoke-Target
    Assert-True ($run.Code -ne 0) 'duplicate vault items exit non-zero'
    Assert-Contains $run.Output 'found 2 vault items' 'duplicate vault items are named'
    Assert-Contains $run.Output 'mock-id-1' 'duplicate vault items list the first id'
    Assert-Contains $run.Output 'mock-id-2' 'duplicate vault items list the second id'
    Assert-Equal $before (Get-Content -LiteralPath $configPath -Raw) 'duplicate vault items leave the config alone'
    Assert-Equal 0 (Get-RestCalls).Count 'duplicate vault items make no relay call'
} finally {
    if ($null -eq $savedProfile) { Remove-Item Env:MAINFRAME_PROFILE_ROOT -ErrorAction SilentlyContinue } else { $env:MAINFRAME_PROFILE_ROOT = $savedProfile }
    if ($null -eq $savedBwState) { Remove-Item Env:MF_MOCK_BW_STATE -ErrorAction SilentlyContinue } else { $env:MF_MOCK_BW_STATE = $savedBwState }
    if ($null -eq $savedCallLog) { Remove-Item Env:MF_CALL_LOG -ErrorAction SilentlyContinue } else { $env:MF_CALL_LOG = $savedCallLog }
    if ($null -eq $savedRestCapture) { Remove-Item Env:MF_REST_CAPTURE -ErrorAction SilentlyContinue } else { $env:MF_REST_CAPTURE = $savedRestCapture }
    if ($null -eq $savedRestState) { Remove-Item Env:MF_REST_STATE -ErrorAction SilentlyContinue } else { $env:MF_REST_STATE = $savedRestState }
    if ($null -eq $savedRestMode) { Remove-Item Env:MF_REST_MODE -ErrorAction SilentlyContinue } else { $env:MF_REST_MODE = $savedRestMode }
    if ($null -eq $savedLocked) { Remove-Item Env:MF_MOCK_BW_LOCKED -ErrorAction SilentlyContinue } else { $env:MF_MOCK_BW_LOCKED = $savedLocked }
    if ($null -eq $savedHarnessArgs) { Remove-Item Env:MF_HARNESS_ARGS -ErrorAction SilentlyContinue } else { $env:MF_HARNESS_ARGS = $savedHarnessArgs }
    $env:PATH = $savedPath
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host "new-bootstrap-link checks: $script:checks passed"
