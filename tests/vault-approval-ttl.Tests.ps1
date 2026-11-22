# Standalone test for 12-hour extended vault session approval and TTL tracking.
# Compatible with Windows PowerShell 5.1 and pwsh 7.
#
# ISOLATED: every session write goes to a temp profile root and every `bw`
# call goes to a fake bw in a temp bin dir (same pattern as
# vault-session-expire.Tests.ps1). this test used to run against the REAL
# profile - on 2026-11-15 it overwrote the live 12-hour session.key with a
# fake test key and then deleted it, killing the vault session every agent
# on the box was using. never run these assertions against the real profile
# again: the tripwire below fails the test if the session path ever escapes
# the temp root.

$ErrorActionPreference = 'Stop'
$scriptDir = $PSScriptRoot
$godScript = [IO.Path]::GetFullPath((Join-Path $scriptDir '..\windows\mainframe.ps1'))

. $godScript

$script:checks = 0
function Assert-True($Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:checks++
}
function Assert-Equal($Expected, $Actual, [string]$Message) {
    if ($Expected -ne $Actual) { throw "FAIL: $Message`n  expected: $Expected`n  actual:   $Actual" }
    $script:checks++
}

# --- isolation: temp profile root + fake bw ---
$rootLeaf = "vault-ttl-test-" + [guid]::NewGuid().ToString('N').Substring(0, 8)
$root = Join-Path ([IO.Path]::GetTempPath()) $rootLeaf
$bin = Join-Path $root 'bin'
$profile = Join-Path $root 'profile'
New-Item -ItemType Directory -Force -Path $bin, (Join-Path (Join-Path $profile 'accounts') 'bitwarden') | Out-Null

if ($env:OS -eq 'Windows_NT') {
    $bw = Join-Path $bin 'bw.cmd'
    @(
        '@echo off'
        'if "%1"=="lock" ('
        '  echo Your vault is locked.'
        ') else ('
        '  echo fake bw: unknown command %1 1>&2'
        '  exit /b 1'
        ')'
    ) | Set-Content -LiteralPath $bw -Encoding ASCII
    # fake schedulers: log the call, exit 0 - Set-VaultSessionKey
    # registers the expiry unconditionally now (enforced), so section 3's
    # unlock must hit the fakes, never a real schtasks task.
    @('@echo off', "echo schtasks %*>>`"$root\sched-calls`"", 'exit /b 0') | Set-Content -LiteralPath (Join-Path $bin 'schtasks.cmd') -Encoding ASCII
    @('@echo off', "echo systemd-run %*>>`"$root\sched-calls`"", 'exit /b 0') | Set-Content -LiteralPath (Join-Path $bin 'systemd-run.cmd') -Encoding ASCII
    @('@echo off', "echo systemctl %*>>`"$root\sched-calls`"", 'exit /b 0') | Set-Content -LiteralPath (Join-Path $bin 'systemctl.cmd') -Encoding ASCII
} else {
    $bw = Join-Path $bin 'bw'
    @(
        '#!/bin/sh'
        'case "$1" in'
        '  lock) echo "Your vault is locked.";;'
        '  *) echo "fake bw: unknown command $1" >&2; exit 1;;'
        'esac'
    ) | Set-Content -LiteralPath $bw -Encoding ASCII
    & chmod 755 $bw
    # fake schedulers: log the call, exit 0 - Set-VaultSessionKey
    # registers the expiry unconditionally now (enforced), so section 3's
    # unlock must hit the fakes, never a real systemd timer (or a real
    # 12-hour sleeper when systemd-run fails on a container).
    @('#!/bin/sh', "echo `"schtasks `$*`" >> `"$root/sched-calls`"", 'exit 0') | Set-Content -LiteralPath (Join-Path $bin 'schtasks') -Encoding ASCII
    @('#!/bin/sh', "echo `"systemd-run `$*`" >> `"$root/sched-calls`"", 'exit 0') | Set-Content -LiteralPath (Join-Path $bin 'systemd-run') -Encoding ASCII
    @('#!/bin/sh', "echo `"systemctl `$*`" >> `"$root/sched-calls`"", 'exit 0') | Set-Content -LiteralPath (Join-Path $bin 'systemctl') -Encoding ASCII
    & chmod 755 (Join-Path $bin 'schtasks')
    & chmod 755 (Join-Path $bin 'systemd-run')
    & chmod 755 (Join-Path $bin 'systemctl')
}

$savedPath = $env:PATH
$savedProfile = $env:MAINFRAME_PROFILE_ROOT

# 1. Standard plaintext master password (no approved TTL - the 12-hour default applies)
$rsa = [System.Security.Cryptography.RSA]::Create(2048)
try {
    $env:PATH = "$bin$([IO.Path]::PathSeparator)$savedPath"
    $env:MAINFRAME_PROFILE_ROOT = $profile

    $plainPw = 'StandardPassword123!'
    $plainBytes = [System.Text.Encoding]::UTF8.GetBytes($plainPw)
    $cipherBytes = $rsa.Encrypt($plainBytes, [System.Security.Cryptography.RSAEncryptionPadding]::OaepSHA256)
    $b64Cipher = [Convert]::ToBase64String($cipherBytes)

    $decrypted = Decrypt-VaultApprovalCiphertext -Rsa $rsa -Ciphertext $b64Cipher
    Assert-Equal $plainPw $decrypted 'standard password decrypts accurately'
    Assert-Equal 0 (Get-VaultApprovedTtlMinutes) 'standard approval has 0 custom ttl'
    Assert-True (-not $env:MAINFRAME_VAULT_APPROVED_TTL) 'no env approved ttl for standard'

    # 2. 12-hour structured JSON payload from mobile checkbox
    $jsonPayload = '{"pw":"ExtendedPassword999!","ttl":720,"ttlMinutes":720}'
    $jsonBytes = [System.Text.Encoding]::UTF8.GetBytes($jsonPayload)
    $jsonCipher = [Convert]::ToBase64String($rsa.Encrypt($jsonBytes, [System.Security.Cryptography.RSAEncryptionPadding]::OaepSHA256))

    $decryptedJsonPw = Decrypt-VaultApprovalCiphertext -Rsa $rsa -Ciphertext $jsonCipher
    Assert-Equal 'ExtendedPassword999!' $decryptedJsonPw 'structured payload extracts master password cleanly'
    Assert-Equal 720 (Get-VaultApprovedTtlMinutes) 'approved TTL is 720 minutes'
    Assert-Equal '720' $env:MAINFRAME_VAULT_APPROVED_TTL 'env MAINFRAME_VAULT_APPROVED_TTL is 720'

    # 2b. a TTL over 12 hours is clamped to 720 (L15) - the value comes from
    # the phone side, so a wild number must never mint a longer session
    $wildPayload = '{"pw":"WildPassword999!","ttl":9999}'
    $wildBytes = [System.Text.Encoding]::UTF8.GetBytes($wildPayload)
    $wildCipher = [Convert]::ToBase64String($rsa.Encrypt($wildBytes, [System.Security.Cryptography.RSAEncryptionPadding]::OaepSHA256))
    $decryptedWildPw = Decrypt-VaultApprovalCiphertext -Rsa $rsa -Ciphertext $wildCipher
    Assert-Equal 'WildPassword999!' $decryptedWildPw 'a clamped payload still extracts the master password'
    Assert-Equal 720 (Get-VaultApprovedTtlMinutes) 'a 9999-minute TTL is clamped to 720'
    $wildPayload2 = '{"pw":"WildPassword999!","ttlMinutes":100000}'
    $wildBytes2 = [System.Text.Encoding]::UTF8.GetBytes($wildPayload2)
    $wildCipher2 = [Convert]::ToBase64String($rsa.Encrypt($wildBytes2, [System.Security.Cryptography.RSAEncryptionPadding]::OaepSHA256))
    $null = Decrypt-VaultApprovalCiphertext -Rsa $rsa -Ciphertext $wildCipher2
    Assert-Equal 720 (Get-VaultApprovedTtlMinutes) 'a 100000-minute ttlMinutes is clamped to 720'

    # 3. Set-VaultSessionKey persists .ttl file next to session.key
    $testSessionKey = 'test-session-key-abcdef1234567890'
    $sessionPath = Set-VaultSessionKey -SessionKey $testSessionKey
    Assert-True ($sessionPath -like "*$rootLeaf*") 'session.key must live in the temp profile, never the real one'
    Assert-True (Test-Path -LiteralPath $sessionPath) 'session.key exists'

    $ttlPath = [System.IO.Path]::ChangeExtension($sessionPath, '.ttl')
    Assert-True (Test-Path -LiteralPath $ttlPath) 'session.ttl exists for 12-hour session'
    Assert-Equal '720' ((Get-Content -LiteralPath $ttlPath -Raw).Trim()) 'session.ttl contains 720'

    # 4. Get-VaultSessionTtlMinutes returns 720
    $activeTtl = Get-VaultSessionTtlMinutes
    Assert-Equal 720 $activeTtl 'Get-VaultSessionTtlMinutes returns 720'

    # 5. Lock-VaultSession removes both session.key and session.ttl
    Lock-VaultSession
    Assert-True (-not (Test-Path -LiteralPath $sessionPath)) 'session.key removed after lock'
    Assert-True (-not (Test-Path -LiteralPath $ttlPath)) 'session.ttl removed after lock'
    Assert-True (-not $env:MAINFRAME_VAULT_APPROVED_TTL) 'env variable cleared after lock'
    Assert-Equal 720 (Get-VaultSessionTtlMinutes) 'default TTL returns to 720 (12 hours)'
} finally {
    $rsa.Dispose()
    Remove-Item Env:MAINFRAME_VAULT_APPROVED_TTL -ErrorAction SilentlyContinue
    $env:PATH = $savedPath
    if ($null -eq $savedProfile) { Remove-Item Env:MAINFRAME_PROFILE_ROOT -ErrorAction SilentlyContinue } else { $env:MAINFRAME_PROFILE_ROOT = $savedProfile }
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "vault-approval-ttl checks: $script:checks passed" -ForegroundColor Green
