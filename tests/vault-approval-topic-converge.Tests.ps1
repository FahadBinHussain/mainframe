# No Pester dependency. This file has to pass under windows powershell 5.1 AND
# pwsh 7 - the whole point is that the approval flow works in both.
#
# No network at all and no real bw: Invoke-BwApprovalCommand is mocked
# inside the module's own scope (the same technique
# tests/vault-approval-topic.Tests.ps1 uses for Invoke-RestMethod), so the
# test drives the vault answers through env vars. The config files live in
# temp dirs (MAINFRAME_PROFILE_ROOT + explicit -CheckoutConfigPath), so the
# test never touches the real profile - the runner also isolates it, but
# this test does not rely on that.
#
# What it pins: the vault holds the canonical ntfy topic, and a machine
# converges its local config to it on a vault flow with a live session -
# so a rotation reaches every machine without a human relaying a command.
# A dead session, a missing item, or a malformed vault value all leave the
# local config exactly as it is (existing behavior). The full topic value
# never appears in output - only the 4-char fingerprint (H1).
$ErrorActionPreference = 'Stop'
$godScript = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\windows\mainframe.ps1'))

$script:checks = 0
function Assert-True($Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:checks++
}
function Assert-Equal($Expected, $Actual, [string]$Message) {
    if ($Expected -ne $Actual) { throw "FAIL: $Message`n  expected: $Expected`n  actual:   $Actual" }
}

# test values: obviously fake (all one char), never a real topic.
$script:staleTopic = 'a' * 32
$script:vaultTopic = 'b' * 32
$script:vaultItemName = 'github.com/FahadBinHussain/mainframe / mainframe.ntfy-topic'

# 1. the module parses
$parseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($godScript, [ref]$null, [ref]$parseErrors)
Assert-True ($parseErrors.Count -eq 0) 'mainframe.ps1 parses'

$source = Get-Content -LiteralPath $godScript -Raw

# 2. the convergence machinery exists, and the vault item name matches the
#    signing-key item's shape (same repo prefix, value in notes).
Assert-True ($source -match 'function Sync-VaultNtfyTopicFromVault') 'Sync-VaultNtfyTopicFromVault exists'
Assert-True ($source -match 'function Get-VaultNtfyTopicFromVault') 'Get-VaultNtfyTopicFromVault exists'
Assert-True ($source -match [regex]::Escape($script:vaultItemName)) 'the vault item name is the symmetric secure-note name'
Assert-True ($source -match '(?m)^function Sync-VaultNtfyTopicFromVault') 'the sync function is top-level (dot-sourcing exposes it)'

. $godScript

# 3. mock Invoke-BwApprovalCommand in this script's scope - the god
#    script is dot-sourced here, so its functions resolve the mock.
#    MF_BW_SCENARIO: live | locked | noitem | malformed. MF_BW_VAULT_TOPIC
#    is the notes value for the live case.
$env:MF_BW_SCENARIO = 'live'
$env:MF_BW_VAULT_TOPIC = $script:vaultTopic
function Invoke-BwApprovalCommand {
        param([string[]]$Arguments, [int]$TimeoutSeconds = 10)
        if ($Arguments -contains 'status') {
            if ($env:MF_BW_SCENARIO -eq 'locked') { return '{"status":"locked"}' }
            return '{"status":"unlocked"}'
        }
        if ($Arguments -contains 'list') {
            $scenario = $env:MF_BW_SCENARIO
            if ($scenario -eq 'noitem') { return '[]' }
            if ($scenario -eq 'malformed') {
                $item = [pscustomobject]@{ name = 'github.com/FahadBinHussain/mainframe / mainframe.ntfy-topic'; notes = 'NOT-A-TOPIC' }
                return (@($item) | ConvertTo-Json -Compress)
            }
            $item = [pscustomobject]@{ name = 'github.com/FahadBinHussain/mainframe / mainframe.ntfy-topic'; notes = $env:MF_BW_VAULT_TOPIC }
            return (@($item) | ConvertTo-Json -Compress)
        }
        return $null
    }

function New-TestConfig {
    param([string]$Dir, [string]$Topic)
    $null = New-Item -ItemType Directory -Force -Path $Dir
    $path = Join-Path $Dir 'mainframe.config.json'
    $json = [pscustomobject]@{
        bitwardenEmail = 'test@example.invalid'
        ntfyTopic      = $Topic
        ntfyServer     = 'https://relay.example.test/ntfy'
    } | ConvertTo-Json
    Set-Content -LiteralPath $path -Value $json -Encoding UTF8
    return $path
}

function Read-ConfigTopic {
    param([string]$Path)
    return ([string](Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json).ntfyTopic)
}

function Invoke-WithStderr {
    # run a scriptblock with stderr captured, return @{ Result; Stderr }.
    param([scriptblock]$Block)
    $sb = New-Object Text.StringBuilder
    $writer = [IO.StringWriter]::new($sb)
    $oldError = [Console]::Error
    [Console]::SetError($writer)
    try {
        $result = & $Block
    } finally {
        $writer.Flush()
        [Console]::SetError($oldError)
    }
    return @{ Result = $result; Stderr = $sb.ToString() }
}

$oldProfileRoot = $env:MAINFRAME_PROFILE_ROOT
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('mf-converge-' + [Guid]::NewGuid().ToString('N'))
try {
    $null = New-Item -ItemType Directory -Force -Path $tempRoot
    $profileDir = Join-Path $tempRoot 'profile'
    $checkoutDir = Join-Path $tempRoot 'checkout'
    $env:MAINFRAME_PROFILE_ROOT = $profileDir

    # 4. vault topic wins: both configs converge, loudly, fingerprint only.
    $profileConfig = New-TestConfig -Dir $profileDir -Topic $script:staleTopic
    $checkoutConfig = New-TestConfig -Dir $checkoutDir -Topic $script:staleTopic
    $env:MF_BW_SCENARIO = 'live'
    $env:MF_BW_VAULT_TOPIC = $script:vaultTopic
    $run = Invoke-WithStderr { Sync-VaultNtfyTopicFromVault -CheckoutConfigPath $checkoutConfig }
    Assert-True ($run.Result -eq $true) 'live session + vault item returns true'
    Assert-Equal $script:vaultTopic (Read-ConfigTopic -Path $profileConfig) 'the profile config converged to the vault topic'
    Assert-Equal $script:vaultTopic (Read-ConfigTopic -Path $checkoutConfig) 'the checkout config converged to the vault topic'
    Assert-True ($run.Stderr -match 'converged from the vault') 'the convergence is logged loudly'
    Assert-True ($run.Stderr -match 'bbbb') 'the log carries the 4-char fingerprint'
    Assert-True ($run.Stderr -notmatch $script:vaultTopic) 'the log never prints the full vault topic'
    Assert-True ($run.Stderr -notmatch $script:staleTopic) 'the log never prints the old topic either'

    # 5. already converged: silent, no rewrite.
    $before = Get-Content -LiteralPath $profileConfig -Raw
    $run = Invoke-WithStderr { Sync-VaultNtfyTopicFromVault -CheckoutConfigPath $checkoutConfig }
    Assert-True ($run.Result -eq $true) 'already-converged still returns true'
    Assert-True ($run.Stderr -notmatch 'converged') 'an already-converged machine stays silent'
    Assert-Equal $before (Get-Content -LiteralPath $profileConfig -Raw) 'an already-converged config is not rewritten'

    # 6. dead session: local config untouched, false.
    $profileConfig = New-TestConfig -Dir $profileDir -Topic $script:staleTopic
    $checkoutConfig = New-TestConfig -Dir $checkoutDir -Topic $script:staleTopic
    $env:MF_BW_SCENARIO = 'locked'
    $run = Invoke-WithStderr { Sync-VaultNtfyTopicFromVault -CheckoutConfigPath $checkoutConfig }
    Assert-True ($run.Result -eq $false) 'dead session returns false'
    Assert-Equal $script:staleTopic (Read-ConfigTopic -Path $profileConfig) 'dead session leaves the profile config alone'
    Assert-Equal $script:staleTopic (Read-ConfigTopic -Path $checkoutConfig) 'dead session leaves the checkout config alone'

    # 7. no vault item: local config untouched, false.
    $env:MF_BW_SCENARIO = 'noitem'
    $run = Invoke-WithStderr { Sync-VaultNtfyTopicFromVault -CheckoutConfigPath $checkoutConfig }
    Assert-True ($run.Result -eq $false) 'missing vault item returns false'
    Assert-Equal $script:staleTopic (Read-ConfigTopic -Path $profileConfig) 'missing vault item leaves the profile config alone'

    # 8. malformed vault value: ignored loudly, local config untouched.
    $env:MF_BW_SCENARIO = 'malformed'
    $run = Invoke-WithStderr { Sync-VaultNtfyTopicFromVault -CheckoutConfigPath $checkoutConfig }
    Assert-True ($run.Result -eq $false) 'malformed vault value returns false'
    Assert-Equal $script:staleTopic (Read-ConfigTopic -Path $profileConfig) 'malformed vault value leaves the profile config alone'
    Assert-True ($run.Stderr -match 'malformed') 'a malformed vault value warns loudly'

    # 9. missing profile config: the checkout still converges, no file is
    #    invented for the profile.
    Remove-Item -LiteralPath $profileConfig -Force
    $env:MF_BW_SCENARIO = 'live'
    $env:MF_BW_VAULT_TOPIC = $script:vaultTopic
    $run = Invoke-WithStderr { Sync-VaultNtfyTopicFromVault -CheckoutConfigPath $checkoutConfig }
    Assert-True ($run.Result -eq $true) 'missing profile config still returns true'
    Assert-True (-not (Test-Path -LiteralPath $profileConfig)) 'a missing profile config is not invented'
    Assert-Equal $script:vaultTopic (Read-ConfigTopic -Path $checkoutConfig) 'the checkout still converges without a profile config'

    # 10. unparseable config: warned about loudly, left alone byte-for-byte.
    Set-Content -LiteralPath $profileConfig -Value '{not json' -Encoding UTF8
    $checkoutConfig = New-TestConfig -Dir $checkoutDir -Topic $script:staleTopic
    $run = Invoke-WithStderr { Sync-VaultNtfyTopicFromVault -CheckoutConfigPath $checkoutConfig }
    Assert-True ($run.Result -eq $true) 'unparseable profile config still returns true'
    Assert-Equal '{not json' (Get-Content -LiteralPath $profileConfig -Raw).Trim() 'an unparseable config is left alone byte-for-byte'
    Assert-True ($run.Stderr -match 'not parseable json') 'an unparseable config warns loudly'
    Assert-Equal $script:vaultTopic (Read-ConfigTopic -Path $checkoutConfig) 'the checkout still converges past an unparseable profile config'

    # 11. Get-VaultNtfyTopicFromVault reads the item directly (same mock).
    $env:MF_BW_SCENARIO = 'live'
    $env:MF_BW_VAULT_TOPIC = $script:vaultTopic
    Assert-Equal $script:vaultTopic (Get-VaultNtfyTopicFromVault) 'the vault topic reads back directly'
    $env:MF_BW_SCENARIO = 'locked'
    Assert-Equal $null (Get-VaultNtfyTopicFromVault) 'a dead session reads nothing directly'
} finally {
    Remove-Item Env:\MF_BW_SCENARIO -ErrorAction SilentlyContinue
    Remove-Item Env:\MF_BW_VAULT_TOPIC -ErrorAction SilentlyContinue
    if ($null -ne $oldProfileRoot) { $env:MAINFRAME_PROFILE_ROOT = $oldProfileRoot } else { Remove-Item Env:\MAINFRAME_PROFILE_ROOT -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host "vault-approval topic convergence checks: $script:checks passed"
