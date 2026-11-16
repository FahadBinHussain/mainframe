# No Pester dependency. This file has to pass under windows powershell 5.1 AND
# pwsh 7 - the whole point is that the approval flow works in both.
#
# No network at all and no real bw: Invoke-VaultServerBwCommand is mocked
# inside the module's own scope (the same technique
# tests/vault-approval-topic-converge.Tests.ps1 uses for
# Invoke-BwApprovalCommand), so the test drives the vault answers through
# env vars. The config files live in temp dirs (MAINFRAME_PROFILE_ROOT +
# explicit -CheckoutConfigPath), so the test never touches the real
# profile - the runner also isolates it, but this test does not rely on
# that.
#
# What it pins: the vault holds the canonical ntfy relay server, and a
# machine converges its local config to it on a vault flow with a live
# session - so a relay move reaches every machine without a human relaying
# a command. A dead session, a missing item, or a malformed vault value
# all leave the local config exactly as it is (existing behavior). The
# server url is not a secret (the topic is the credential), so the
# convergence log names the new relay in full.
$ErrorActionPreference = 'Stop'
$module = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\windows\vault-ntfy-server.psm1'))

$script:checks = 0
function Assert-True($Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:checks++
}
function Assert-Equal($Expected, $Actual, [string]$Message) {
    if ($Expected -ne $Actual) { throw "FAIL: $Message`n  expected: $Expected`n  actual:   $Actual" }
}

# test values: obviously fake (.example.test never resolves), never a real relay.
$script:staleServer = 'https://relay-old.example.test/ntfy'
$script:vaultServer = 'https://relay-new.example.test/ntfy'
$script:vaultItemName = 'github.com/FahadBinHussain/mainframe / mainframe.ntfy-server'

# 1. the module parses
$parseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($module, [ref]$null, [ref]$parseErrors)
Assert-True ($parseErrors.Count -eq 0) 'vault-ntfy-server.psm1 parses'

$source = Get-Content -LiteralPath $module -Raw

# 2. the convergence machinery exists, and the vault item name matches the
#    topic item's shape (same repo prefix, value in notes).
Assert-True ($source -match 'function Sync-VaultNtfyServerFromVault') 'Sync-VaultNtfyServerFromVault exists'
Assert-True ($source -match 'function Get-VaultNtfyServerFromVault') 'Get-VaultNtfyServerFromVault exists'
Assert-True ($source -match [regex]::Escape($script:vaultItemName)) 'the vault item name is the symmetric secure-note name'
Assert-True ($source -match 'Sync-VaultNtfyServerFromVault') 'the sync function is exported'

Import-Module $module -Force -DisableNameChecking

# 3. mock Invoke-VaultServerBwCommand inside the module's own scope. env
#    vars carry the scenario in because the mock runs in the module's
#    session state, not this script's. MF_BW_SCENARIO: live | locked |
#    noitem. MF_BW_VAULT_SERVER is the notes value for the live case -
#    including the malformed values, which are just live answers that
#    fail validation.
$env:MF_BW_SCENARIO = 'live'
$env:MF_BW_VAULT_SERVER = $script:vaultServer
& (Get-Module vault-ntfy-server) {
    function script:Invoke-VaultServerBwCommand {
        param([string[]]$Arguments, [int]$TimeoutSeconds = 10)
        if ($Arguments -contains 'status') {
            if ($env:MF_BW_SCENARIO -eq 'locked') { return '{"status":"locked"}' }
            return '{"status":"unlocked"}'
        }
        if ($Arguments -contains 'list') {
            if ($env:MF_BW_SCENARIO -eq 'noitem') { return '[]' }
            $item = [pscustomobject]@{ name = 'github.com/FahadBinHussain/mainframe / mainframe.ntfy-server'; notes = $env:MF_BW_VAULT_SERVER }
            return (@($item) | ConvertTo-Json -Compress)
        }
        return $null
    }
}

function New-TestConfig {
    param([string]$Dir, [string]$Server)
    $null = New-Item -ItemType Directory -Force -Path $Dir
    $path = Join-Path $Dir 'mainframe.config.json'
    $json = [pscustomobject]@{
        bitwardenEmail = 'test@example.invalid'
        ntfyTopic      = 'c' * 32
        ntfyServer     = $Server
    } | ConvertTo-Json
    Set-Content -LiteralPath $path -Value $json -Encoding UTF8
    return $path
}

function Read-ConfigServer {
    param([string]$Path)
    return ([string](Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json).ntfyServer)
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
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('mf-server-converge-' + [Guid]::NewGuid().ToString('N'))
try {
    $null = New-Item -ItemType Directory -Force -Path $tempRoot
    $profileDir = Join-Path $tempRoot 'profile'
    $checkoutDir = Join-Path $tempRoot 'checkout'
    $env:MAINFRAME_PROFILE_ROOT = $profileDir

    # 4. vault server wins: both configs converge, loudly, naming the relay.
    $profileConfig = New-TestConfig -Dir $profileDir -Server $script:staleServer
    $checkoutConfig = New-TestConfig -Dir $checkoutDir -Server $script:staleServer
    $env:MF_BW_SCENARIO = 'live'
    $env:MF_BW_VAULT_SERVER = $script:vaultServer
    $run = Invoke-WithStderr { Sync-VaultNtfyServerFromVault -CheckoutConfigPath $checkoutConfig }
    Assert-True ($run.Result -eq $true) 'live session + vault item returns true'
    Assert-Equal $script:vaultServer (Read-ConfigServer -Path $profileConfig) 'the profile config converged to the vault server'
    Assert-Equal $script:vaultServer (Read-ConfigServer -Path $checkoutConfig) 'the checkout config converged to the vault server'
    Assert-True ($run.Stderr -match 'converged from the vault') 'the convergence is logged loudly'
    Assert-True ($run.Stderr -match [regex]::Escape($script:vaultServer)) 'the log names the new relay in full'

    # 5. already converged: silent, no rewrite.
    $before = Get-Content -LiteralPath $profileConfig -Raw
    $run = Invoke-WithStderr { Sync-VaultNtfyServerFromVault -CheckoutConfigPath $checkoutConfig }
    Assert-True ($run.Result -eq $true) 'already-converged still returns true'
    Assert-True ($run.Stderr -notmatch 'converged') 'an already-converged machine stays silent'
    Assert-Equal $before (Get-Content -LiteralPath $profileConfig -Raw) 'an already-converged config is not rewritten'

    # 6. dead session: local config untouched, false.
    $profileConfig = New-TestConfig -Dir $profileDir -Server $script:staleServer
    $checkoutConfig = New-TestConfig -Dir $checkoutDir -Server $script:staleServer
    $env:MF_BW_SCENARIO = 'locked'
    $run = Invoke-WithStderr { Sync-VaultNtfyServerFromVault -CheckoutConfigPath $checkoutConfig }
    Assert-True ($run.Result -eq $false) 'dead session returns false'
    Assert-Equal $script:staleServer (Read-ConfigServer -Path $profileConfig) 'dead session leaves the profile config alone'
    Assert-Equal $script:staleServer (Read-ConfigServer -Path $checkoutConfig) 'dead session leaves the checkout config alone'

    # 7. no vault item: local config untouched, false.
    $env:MF_BW_SCENARIO = 'noitem'
    $run = Invoke-WithStderr { Sync-VaultNtfyServerFromVault -CheckoutConfigPath $checkoutConfig }
    Assert-True ($run.Result -eq $false) 'missing vault item returns false'
    Assert-Equal $script:staleServer (Read-ConfigServer -Path $profileConfig) 'missing vault item leaves the profile config alone'

    # 8. malformed vault values: each ignored loudly, local config untouched.
    $env:MF_BW_SCENARIO = 'live'
    foreach ($bad in @(
        'http://relay-new.example.test/ntfy',   # http, not https
        'https://relay-new.example.test/',        # no /ntfy path
        'https://relay-new.example.test',         # no path at all
        'https://relay-new.example.test/ntfy/x',  # wrong path
        'not-a-url'
    )) {
        $env:MF_BW_VAULT_SERVER = $bad
        $run = Invoke-WithStderr { Sync-VaultNtfyServerFromVault -CheckoutConfigPath $checkoutConfig }
        Assert-True ($run.Result -eq $false) "malformed vault value '$bad' returns false"
        Assert-Equal $script:staleServer (Read-ConfigServer -Path $profileConfig) "malformed vault value '$bad' leaves the profile config alone"
        Assert-True ($run.Stderr -match 'malformed') "a malformed vault value '$bad' warns loudly"
    }

    # 9. a trailing slash is tolerated and trimmed, then it converges.
    $env:MF_BW_VAULT_SERVER = "$script:vaultServer/"
    $run = Invoke-WithStderr { Sync-VaultNtfyServerFromVault -CheckoutConfigPath $checkoutConfig }
    Assert-True ($run.Result -eq $true) 'trailing-slash vault value returns true'
    Assert-Equal $script:vaultServer (Read-ConfigServer -Path $profileConfig) 'the trailing slash is trimmed on converge'

    # 10. missing profile config: the checkout still converges, no file is
    #     invented for the profile.
    $profileConfig = New-TestConfig -Dir $profileDir -Server $script:staleServer
    $checkoutConfig = New-TestConfig -Dir $checkoutDir -Server $script:staleServer
    Remove-Item -LiteralPath $profileConfig -Force
    $env:MF_BW_VAULT_SERVER = $script:vaultServer
    $run = Invoke-WithStderr { Sync-VaultNtfyServerFromVault -CheckoutConfigPath $checkoutConfig }
    Assert-True ($run.Result -eq $true) 'missing profile config still returns true'
    Assert-True (-not (Test-Path -LiteralPath $profileConfig)) 'a missing profile config is not invented'
    Assert-Equal $script:vaultServer (Read-ConfigServer -Path $checkoutConfig) 'the checkout still converges without a profile config'

    # 11. unparseable config: warned about loudly, left alone byte-for-byte.
    Set-Content -LiteralPath $profileConfig -Value '{not json' -Encoding UTF8
    $checkoutConfig = New-TestConfig -Dir $checkoutDir -Server $script:staleServer
    $run = Invoke-WithStderr { Sync-VaultNtfyServerFromVault -CheckoutConfigPath $checkoutConfig }
    Assert-True ($run.Result -eq $true) 'unparseable profile config still returns true'
    Assert-Equal '{not json' (Get-Content -LiteralPath $profileConfig -Raw).Trim() 'an unparseable config is left alone byte-for-byte'
    Assert-True ($run.Stderr -match 'not parseable json') 'an unparseable config warns loudly'
    Assert-Equal $script:vaultServer (Read-ConfigServer -Path $checkoutConfig) 'the checkout still converges past an unparseable profile config'

    # 12. a config with no ntfyServer at all is left alone (the ntfy.sh
    #     default keeps working); only the config that carries one moves.
    $profileConfig = New-TestConfig -Dir $profileDir -Server $script:staleServer
    $checkoutConfig = New-TestConfig -Dir $checkoutDir -Server $script:staleServer
    $noServer = [pscustomobject]@{ bitwardenEmail = 'test@example.invalid'; ntfyTopic = 'c' * 32 } | ConvertTo-Json
    Set-Content -LiteralPath $profileConfig -Value $noServer -Encoding UTF8
    $env:MF_BW_VAULT_SERVER = $script:vaultServer
    $run = Invoke-WithStderr { Sync-VaultNtfyServerFromVault -CheckoutConfigPath $checkoutConfig }
    Assert-True ($run.Result -eq $true) 'a server-less profile config still returns true'
    Assert-True (-not ((Get-Content -LiteralPath $profileConfig -Raw | ConvertFrom-Json).ntfyServer)) 'a config with no ntfyServer stays server-less'
    Assert-Equal $script:vaultServer (Read-ConfigServer -Path $checkoutConfig) 'the checkout still converges past a server-less profile config'

    # 13. Get-VaultNtfyServerFromVault reads the item directly (same mock).
    $env:MF_BW_SCENARIO = 'live'
    $env:MF_BW_VAULT_SERVER = $script:vaultServer
    Assert-Equal $script:vaultServer (Get-VaultNtfyServerFromVault) 'the vault server reads back directly'
    $env:MF_BW_SCENARIO = 'locked'
    Assert-Equal $null (Get-VaultNtfyServerFromVault) 'a dead session reads nothing directly'
} finally {
    Remove-Item Env:\MF_BW_SCENARIO -ErrorAction SilentlyContinue
    Remove-Item Env:\MF_BW_VAULT_SERVER -ErrorAction SilentlyContinue
    if ($null -ne $oldProfileRoot) { $env:MAINFRAME_PROFILE_ROOT = $oldProfileRoot } else { Remove-Item Env:\MAINFRAME_PROFILE_ROOT -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host "vault-approval server convergence checks: $script:checks passed"
