# seal-bw-email.ps1 - one-time sealer for fresh-machine restores.
# Seals the bitwarden account email with a key derived from the master
# password into bw-email.enc.json (ciphertext only) and pushes it to this
# repo. boot.ps1 unseals it with the master password setup asks for anyway,
# so a fresh machine never has to type the email. Run once on a machine
# where the bw CLI is logged in; publish-backup.ps1 also seals automatically
# on publish when the blob is missing. Delete the blob and re-run to
# re-seal (e.g. after an email change).
function Get-BwEmailKeyMaterial {
    param([securestring]$Password, [byte[]]$Salt, [int]$Iterations)
    $plain = [System.Net.NetworkCredential]::new('', $Password).Password
    $pwBytes = [System.Text.Encoding]::UTF8.GetBytes($plain)
    $kdf = [System.Security.Cryptography.Rfc2898DeriveBytes]::new($pwBytes, $Salt, $Iterations, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
    try { return ,$kdf.GetBytes(64) } finally { $kdf.Dispose() }
}

function Seal-BwEmail {
    param([string]$Email, [securestring]$Password)
    $salt = New-Object byte[] 16
    $iv = New-Object byte[] 16
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($salt); $rng.GetBytes($iv); $rng.Dispose()
    $iterations = 600000
    $km = Get-BwEmailKeyMaterial -Password $Password -Salt $salt -Iterations $iterations
    $encKey = New-Object byte[] 32; [Array]::Copy($km, 0, $encKey, 0, 32)
    $macKey = New-Object byte[] 32; [Array]::Copy($km, 32, $macKey, 0, 32)
    $aes = [System.Security.Cryptography.Aes]::Create()
    $aes.Key = $encKey; $aes.IV = $iv
    $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
    $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
    $plainBytes = [System.Text.Encoding]::UTF8.GetBytes($Email)
    $ct = $aes.CreateEncryptor().TransformFinalBlock($plainBytes, 0, $plainBytes.Length)
    $aes.Dispose()
    $macInput = New-Object byte[] ($salt.Length + $iv.Length + $ct.Length)
    [Array]::Copy($salt, 0, $macInput, 0, $salt.Length)
    [Array]::Copy($iv, 0, $macInput, $salt.Length, $iv.Length)
    [Array]::Copy($ct, 0, $macInput, $salt.Length + $iv.Length, $ct.Length)
    $hmac = [System.Security.Cryptography.HMACSHA256]::new($macKey)
    $mac = $hmac.ComputeHash($macInput)
    $hmac.Dispose()
    return [ordered]@{
        v    = 1
        kdf  = 'PBKDF2-HMAC-SHA256'
        iter = $iterations
        salt = [Convert]::ToBase64String($salt)
        iv   = [Convert]::ToBase64String($iv)
        ct   = [Convert]::ToBase64String($ct)
        mac  = [Convert]::ToBase64String($mac)
    }
}

$bwStatus = & bw status --raw 2>$null | ConvertFrom-Json
if (-not $bwStatus -or $bwStatus.status -eq 'unauthenticated') {
    Write-Host 'bw CLI is not logged in here - logging in (interactive):'
    & bw login
    if ($LASTEXITCODE -ne 0) { throw 'bw login failed' }
    $bwStatus = & bw status --raw 2>$null | ConvertFrom-Json
}
$bwEmail = [string]$bwStatus.userEmail
if ([string]::IsNullOrWhiteSpace($bwEmail)) { $bwEmail = Read-Host 'bitwarden EMAIL' }
$sealPw = Read-Host "master password (seals $bwEmail into bw-email.enc.json)" -AsSecureString
$sealedBlob = Seal-BwEmail -Email $bwEmail -Password $sealPw
$blobPath = Join-Path $PSScriptRoot 'bw-email.enc.json'
Set-Content -LiteralPath $blobPath -Value ($sealedBlob | ConvertTo-Json) -Encoding UTF8
& git -C $PSScriptRoot add -- bw-email.enc.json 2>$null | Out-Null
& git -C $PSScriptRoot commit -m 'chore: seal bw email blob' -- bw-email.enc.json 2>$null | Out-Null
& git -C $PSScriptRoot push 2>$null | Out-Null
if ($LASTEXITCODE -eq 0) { Write-Host 'done: bw-email.enc.json pushed (ciphertext only) - fresh-machine setups now ask only for the master password' }
else { Write-Warning 'git push failed - bw-email.enc.json is written locally; commit and push it manually' }
