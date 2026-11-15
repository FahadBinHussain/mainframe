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
$flow = Join-Path $repo 'windows\vault-flow.ps1'

$script:checks = 0
function Assert-True($Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:checks++
}
function Assert-Equal($Expected, $Actual, [string]$Message) {
    if ($Expected -ne $Actual) { throw "FAIL: $Message`n  expected: $Expected`n  actual:   $Actual" }
    $script:checks++
}

# 1. the cli parses
$parseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($flow, [ref]$null, [ref]$parseErrors)
Assert-True ($parseErrors.Count -eq 0) 'vault-flow.ps1 parses'

# 2. the fake bw cli. status answers from $MF_BW_STATUS (locked|unlocked);
# `list` with --search serves the signing-key items file (or [] when there
# is none); any other list serves the vault items.
$items = @(
    @{ name = 'github.com/FahadBinHussain'; notes = 'token = ghp_0123456789012345678901' },
    @{ name = 'mainframe-production'; notes = 'the secrets password' }
) | ConvertTo-Json -Compress

$root = Join-Path ([IO.Path]::GetTempPath()) ("vault-flow-test-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$bin = Join-Path $root 'bin'
$profile = Join-Path $root 'profile'
$signingItemsFile = Join-Path $root 'bw-signing-items.json'
New-Item -ItemType Directory -Force -Path $bin, (Join-Path (Join-Path $profile 'accounts') 'bitwarden') | Out-Null

if ($env:OS -eq 'Windows_NT') {
    $bw = Join-Path $bin 'bw.cmd'
    @(
        '@echo off'
        'if "%1"=="status" ('
        '  if "%MF_BW_STATUS%"=="unlocked" (echo {"status":"unlocked","serverUrl":"https://example.invalid","userEmail":"t@example.invalid"}) else (echo {"status":"locked","serverUrl":"https://example.invalid","userEmail":"t@example.invalid"})'
        ') else if "%3"=="--search" ('
        '  if exist "%MF_BW_SIGNING_ITEMS%" (type "%MF_BW_SIGNING_ITEMS%") else (echo [])'
        ') else (echo ' + $items + ')'
    ) | Set-Content -LiteralPath $bw -Encoding ASCII
} else {
    $bw = Join-Path $bin 'bw'
    @(
        '#!/bin/sh'
        'if [ "$1" = "status" ]; then'
        '  if [ "$MF_BW_STATUS" = "unlocked" ]; then echo ''{"status":"unlocked","serverUrl":"https://example.invalid","userEmail":"t@example.invalid"}'';'
        '  else echo ''{"status":"locked","serverUrl":"https://example.invalid","userEmail":"t@example.invalid"}''; fi;'
        'elif [ "$1" = "list" ] && [ "$3" = "--search" ]; then'
        '  if [ -n "$MF_BW_SIGNING_ITEMS" ] && [ -f "$MF_BW_SIGNING_ITEMS" ]; then cat "$MF_BW_SIGNING_ITEMS"; else echo ''[]''; fi;'
        'else echo ''' + $items + "''';"
        'fi'
    ) | Set-Content -LiteralPath $bw -Encoding ASCII
    & chmod 755 $bw
}

# 3. a fresh cached session in the temp profile
$sessionFile = Join-Path (Join-Path (Join-Path $profile 'accounts') 'bitwarden') 'session.key'
Set-Content -LiteralPath $sessionFile -Value 'fake-session-key-0123456789' -NoNewline
$keyFile = Join-Path $profile 'approval-signing.key'

# the opportunistic heal needs a PEM to fetch: .NET Core only, so the
# heal-success case only runs where the runtime can mint one.
$canEcPem = $null -ne [System.Security.Cryptography.ECDsa].GetMethod('ExportECPrivateKeyPem')

$savedPath = $env:PATH
$savedProfile = $env:MAINFRAME_PROFILE_ROOT
$savedStatus = $env:MF_BW_STATUS
$savedSigningItems = $env:MF_BW_SIGNING_ITEMS
try {
    $env:PATH = "$bin$([IO.Path]::PathSeparator)$savedPath"
    $env:MAINFRAME_PROFILE_ROOT = $profile
    $env:MF_BW_STATUS = 'locked'
    Remove-Item Env:MF_BW_SIGNING_ITEMS -ErrorAction SilentlyContinue

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
    Assert-True (-not (Test-Path -LiteralPath $keyFile)) 'a locked vault heals no signing key at flow start'

    # 4. opportunistic heal (C1, flow-start-when-live): the session is live
    # and no approval is needed - the flow caches the signing key now.
    if (-not $canEcPem) {
        Write-Host 'NOTE: this runtime cannot mint an EC PEM (windows powershell 5.1) - the flow-start heal case is skipped' -ForegroundColor Yellow
        Assert-True $true 'the flow-start heal case is skipped on this runtime'
    } else {
        $ec = [System.Security.Cryptography.ECDsa]::Create([System.Security.Cryptography.ECCurve+NamedCurves]::nistP256)
        try {
            $pem = $ec.ExportECPrivateKeyPem()
            $signingItems = @(
                @{ name = 'github.com/FahadBinHussain/mainframe / approval-signing.key'; notes = $pem }
            ) | ConvertTo-Json -Compress
            Set-Content -LiteralPath $signingItemsFile -Value $signingItems -Encoding UTF8 -NoNewline
            $env:MF_BW_STATUS = 'unlocked'
            $env:MF_BW_SIGNING_ITEMS = $signingItemsFile
            try {
                $output2 = & $flow -Json
            } catch {
                throw "FAIL: the flow did not complete on the live session: $_"
            }
            $parsed2 = ($output2 -join "`n") | ConvertFrom-Json
            Assert-Equal 'ghp_0123456789012345678901' $parsed2.githubToken 'the live-session flow still extracts the github token'
            Assert-Equal $false $parsed2.approvalRequested 'a live session still asks the phone for NOTHING'
            Assert-True (Test-Path -LiteralPath $keyFile) 'the live-session flow heals the signing key'
            Assert-Equal ($pem.Trim() + "`n") ([IO.File]::ReadAllText($keyFile)) 'the healed key is the vault PEM, verbatim'
            if ($env:OS -ne 'Windows_NT' -and (Get-Command stat -ErrorAction SilentlyContinue)) {
                $healedMode = ((& stat -c %a $keyFile 2>$null) -join '').Trim()
                Assert-Equal '600' $healedMode 'the healed key file is 0600'
            }
        } finally {
            $ec.Dispose()
        }
    }
} finally {
    $env:PATH = $savedPath
    $env:MAINFRAME_PROFILE_ROOT = $savedProfile
    if ($null -eq $savedStatus) { Remove-Item Env:MF_BW_STATUS -ErrorAction SilentlyContinue } else { $env:MF_BW_STATUS = $savedStatus }
    if ($null -eq $savedSigningItems) { Remove-Item Env:MF_BW_SIGNING_ITEMS -ErrorAction SilentlyContinue } else { $env:MF_BW_SIGNING_ITEMS = $savedSigningItems }
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "vault-flow checks: $script:checks passed"
