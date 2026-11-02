# No Pester dependency. Runs under windows powershell 5.1 AND pwsh 7.
#
# vault-flow.ps1 is the ONE vault implementation. this checks its contract:
# a fresh cached session means NO phone approval and NO master password, and
# the JSON it prints is machine-readable and never carries the password.
#
# nothing here touches the network, the real vault or the phone: the bw CLI
# is faked and the profile root is a temp directory.
$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$flow = Join-Path $repo 'vault-flow.ps1'

$script:checks = 0
function Assert-True($Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:checks++
}
function Assert-Equal($Expected, $Actual, [string]$Message) {
    if ($Expected -ne $Actual) { throw "FAIL: $Message`n  expected: $Expected`n  actual:   $Actual" }
}

# 1. the cli parses
$parseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($flow, [ref]$null, [ref]$parseErrors)
Assert-True ($parseErrors.Count -eq 0) 'vault-flow.ps1 parses'

# 2. the fake bw cli
$items = @(
    @{ name = 'github.com/FahadBinHussain'; notes = 'token = ghp_0123456789012345678901' },
    @{ name = 'mainframe-production'; notes = 'the secrets password' }
) | ConvertTo-Json -Compress

$root = Join-Path ([IO.Path]::GetTempPath()) ("vault-flow-test-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$bin = Join-Path $root 'bin'
$profile = Join-Path $root 'profile'
New-Item -ItemType Directory -Force -Path $bin, (Join-Path (Join-Path $profile 'accounts') 'bitwarden') | Out-Null

if ($env:OS -eq 'Windows_NT') {
    $bw = Join-Path $bin 'bw.cmd'
    @(
        '@echo off'
        'if "%1"=="status" (echo {"status":"locked","serverUrl":"https://example.invalid","userEmail":"t@example.invalid"}) else (echo ' + $items + ')'
    ) | Set-Content -LiteralPath $bw -Encoding ASCII
} else {
    $bw = Join-Path $bin 'bw'
    @(
        '#!/bin/sh'
        'if [ "$1" = "status" ]; then echo ''{"status":"locked","serverUrl":"https://example.invalid","userEmail":"t@example.invalid"}'';'
        'else echo ''' + $items + "''';"
        'fi'
    ) | Set-Content -LiteralPath $bw -Encoding ASCII
    & chmod 755 $bw
}

# 3. a fresh cached session in the temp profile
$sessionFile = Join-Path (Join-Path (Join-Path $profile 'accounts') 'bitwarden') 'session.key'
Set-Content -LiteralPath $sessionFile -Value 'fake-session-key-0123456789' -NoNewline

$savedPath = $env:PATH
$savedProfile = $env:MAINFRAME_PROFILE_ROOT
try {
    $env:PATH = "$bin$([IO.Path]::PathSeparator)$savedPath"
    $env:MAINFRAME_PROFILE_ROOT = $profile

    # the flow runs in-process: the same script under pwsh 7 and under windows
    # powershell 5.1. its log lines go straight to stderr (not the error
    # stream), so stdout stays a clean JSON document.
    try {
        $output = & $flow -Json
    } catch {
        throw "FAIL: the flow did not complete: $_"
    }

    $parsed = ($output -join "`n") | ConvertFrom-Json
    Assert-Equal 'ghp_0123456789012345678901' $parsed.githubToken 'the github token is extracted'
    Assert-Equal 'the secrets password' $parsed.secretsPassword 'the secrets password is extracted'
    Assert-Equal $false $parsed.approvalRequested 'a cached session asks the phone for NOTHING'
    Assert-Equal $true $parsed.sessionCached 'the session is reported as cached'
    Assert-Equal $sessionFile $parsed.sessionPath 'the session path is the profile root one'
    Assert-True ([int]$parsed.ttlMinutes -gt 0) 'the TTL is reported'
    Assert-True (-not (($output -join "`n") -match 'fake-session-key')) 'the session key is not in the output'
} finally {
    $env:PATH = $savedPath
    $env:MAINFRAME_PROFILE_ROOT = $savedProfile
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "vault-flow checks: $script:checks passed"
