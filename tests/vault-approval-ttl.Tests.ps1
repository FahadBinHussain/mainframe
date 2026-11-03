# Standalone test for 12-hour extended vault session approval and TTL tracking.
# Compatible with Windows PowerShell 5.1 and pwsh 7.

$ErrorActionPreference = 'Stop'
$scriptDir = $PSScriptRoot
$approvalModule = [IO.Path]::GetFullPath((Join-Path $scriptDir '../vault-approval.psm1'))
$secretModule = [IO.Path]::GetFullPath((Join-Path $scriptDir '../vault-secret.psm1'))

Import-Module $approvalModule -Force -DisableNameChecking
Import-Module $secretModule -Force -DisableNameChecking

$script:checks = 0
function Assert-True($Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:checks++
}
function Assert-Equal($Expected, $Actual, [string]$Message) {
    if ($Expected -ne $Actual) { throw "FAIL: $Message`n  expected: $Expected`n  actual:   $Actual" }
    $script:checks++
}

# 1. Standard plaintext master password (1-hour default)
$rsa = [System.Security.Cryptography.RSA]::Create(2048)
try {
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

    # 3. Set-VaultSessionKey persists .ttl file next to session.key
    $testSessionKey = 'test-session-key-abcdef1234567890'
    $sessionPath = Set-VaultSessionKey -SessionKey $testSessionKey
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
    Assert-Equal 60 (Get-VaultSessionTtlMinutes) 'default TTL returns to 60'
} finally {
    $rsa.Dispose()
    Remove-Item Env:MAINFRAME_VAULT_APPROVED_TTL -ErrorAction SilentlyContinue
}

Write-Host "vault-approval-ttl checks: $script:checks passed" -ForegroundColor Green
