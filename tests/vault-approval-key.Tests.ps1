# No Pester dependency. This file has to pass under windows powershell 5.1 AND
# pwsh 7 - the whole point is that the approval flow works in both.
#
# It talks to NO network at all. What it pins:
#   - the machine's RSA key loads, and its public half is a real SPKI
#   - the approval page carries NO signing-key trust list any more (the
#     registration design was removed 2026-11-15; the topic is the
#     credential now - see docs/approval-signing-bootstrap.md)
#   - the key round-trips an OAEP encryption: the page encrypts the master
#     password to the public half, the runner decrypts it with the private
#     half - that is the only job the key still has
#   - the link carries the approval facts (k, sid, code, host, ctx, agent,
#     model, exp, srv) and NO signature
#   - a configured-but-missing key fails LOUDLY instead of shipping a link
#     the page cannot encrypt for, and a machine with no key at all mints
#     its own pair and proceeds - no registration step, no stop
#   - the credential resolver picks the right shape
$ErrorActionPreference = 'Stop'
$module = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../vault-approval.psm1'))
$page = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../docs/vault-tab.html'))

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
    if (-not $Haystack.Contains($Needle)) { throw "FAIL: $Message`n  missing: $Needle" }
    $script:checks++
}
function Assert-NotContains($Haystack, [string]$Needle, [string]$Message) {
    if ($Haystack.Contains($Needle)) { throw "FAIL: $Message`n  found: $Needle" }
    $script:checks++
}

# 1. the module parses
$parseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($module, [ref]$null, [ref]$parseErrors)
Assert-True ($parseErrors.Count -eq 0) 'vault-approval.psm1 parses'

Import-Module $module -Force -DisableNameChecking

# 2. the key loads and its public half is a real SPKI
$publicKey = Get-VaultApprovalPublicKey
Assert-True ($publicKey.Length -gt 300) 'the approval public key is a real SPKI'
Assert-True ($publicKey -notmatch '[+/=]') 'the public key is base64url'

# 3. the page carries no signing-key trust list any more
$pageSource = Get-Content -LiteralPath $page -Raw
Assert-NotContains $pageSource 'APPROVAL_PUBLIC_KEYS_B64URL' 'the page must not carry a trusted signing key list'
Assert-NotContains $pageSource 'verifyDescriptor' 'the page must not verify signatures'
Assert-NotContains $pageSource 'APPROVAL_DESCRIPTOR_VERSION' 'the page must not build a descriptor'
Assert-NotContains $pageSource 'X-MF-Sig' 'the page must not send a signature header'
Assert-Contains $pageSource 'encryptForRunner' 'the page still encrypts the password to the runner key'

# 4. the key round-trips an OAEP encryption (the page's encryptForRunner
# encrypts with the public half; the runner decrypts with the private half)
$signer = Get-VaultApprovalSigningKey
try {
    $plain = 'test-master-password-123'
    $plainBytes = [System.Text.Encoding]::UTF8.GetBytes($plain)
    $cipherBytes = $signer.Encrypt($plainBytes, [System.Security.Cryptography.RSAEncryptionPadding]::OaepSHA256)
    Assert-Equal 256 $cipherBytes.Length 'an RSA-2048 OAEP block is 256 bytes'
    $cipherB64 = [Convert]::ToBase64String($cipherBytes)
    Assert-True (Test-VaultApprovalCiphertext -Value $cipherB64 -Rsa $signer) 'a well-formed block from this key is accepted'
    Assert-True (-not (Test-VaultApprovalCiphertext -Value 'garbage')) 'garbage is not a ciphertext'
    $decrypted = Decrypt-VaultApprovalCiphertext -Rsa $signer -Ciphertext $cipherB64
    Assert-Equal $plain $decrypted 'the runner decrypts what the page encrypted'
} finally {
    $signer.Dispose()
}

# 5. the link carries the approval facts and no signature
$rsa = [System.Security.Cryptography.RSA]::Create(2048)
try {
    $session = Get-VaultApprovalUrl -Rsa $rsa -PromptContext 'vault access' -HostName 'LAPTOP-MAIN' `
        -Agent 'minimax-code' -Model 'MiniMax-M3.1-Flash' -ExpiresInSeconds 300 `
        -Server 'https://relay.example.test/ntfy'
    $fragment = $session.Url.Split('#')[1]
    $params = [System.Web.HttpUtility]::ParseQueryString($fragment)
    Assert-True ($params['k'].Length -gt 300) 'the link carries the runner public key'
    Assert-True ($params['sid'] -like 'mf-vault-*') 'the link carries the single-use topic'
    Assert-True ($params['code'] -match '^[0-9]{2}$') 'the link carries the 2-digit code'
    Assert-Equal 'LAPTOP-MAIN' $params['host'] 'the link carries the host'
    Assert-Equal 'vault access' $params['ctx'] 'the link carries the context'
    Assert-Equal 'minimax-code' $params['agent'] 'the link carries the agent'
    Assert-Equal 'MiniMax-M3.1-Flash' $params['model'] 'the link carries the model'
    Assert-True ($params['exp'] -match '^[0-9]+$') 'the link carries the expiry'
    Assert-Equal 'https://relay.example.test/ntfy' $params['srv'] 'the link carries the relay hint'
    Assert-NotContains $session.Url '&sig=' 'the link carries no signature'
    Assert-True ($session.PSObject.Properties.Name -notcontains 'Descriptor') 'the session carries no descriptor'
    Assert-True ($session.PSObject.Properties.Name -notcontains 'Signature') 'the session carries no signature'
} finally {
    $rsa.Dispose()
}

# 6. a configured-but-missing key fails loudly - the page would have no
# public key to encrypt for, so shipping a link is worse than stopping
$savedKeyEnv = $env:MAINFRAME_APPROVAL_SIGNING_KEY
try {
    $env:MAINFRAME_APPROVAL_SIGNING_KEY = [IO.Path]::Combine([IO.Path]::GetTempPath(), 'mainframe-no-such-signing.key')
    $threw = $false
    $message = ''
    try {
        $null = Get-VaultApprovalSigningKey
    } catch {
        $threw = $true
        $message = $_.Exception.Message
    }
    Assert-True $threw 'a missing signing key must throw'
    Assert-Contains $message 'signing key' 'the error names the signing key'
    Assert-Contains $message 'bitwarden' 'the error says where to restore it'
} finally {
    if ($null -eq $savedKeyEnv) { Remove-Item Env:\MAINFRAME_APPROVAL_SIGNING_KEY -ErrorAction SilentlyContinue }
    else { $env:MAINFRAME_APPROVAL_SIGNING_KEY = $savedKeyEnv }
}

# 7. there is no credential resolver any more - topic-only auth means no
#    header or token is ever resolved, sent, or read from the config
$source = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../vault-approval.psm1') -Raw
Assert-True ($source -notmatch 'function Get-VaultNtfyCredential') 'there is no credential resolver'
Assert-True ($source -notmatch 'MAINFRAME_NTFY_AUTH') 'there is no ntfy auth environment variable'
Assert-True ($source -notmatch "'ntfyAuth'") 'the config carries no ntfy auth key'

# 8. a machine with no key provisioned mints its own pair and proceeds -
# no registration step, no stop. the second call loads the same key.
$savedHome2 = $env:MAINFRAME_HOME
$savedKeyEnv2 = $env:MAINFRAME_APPROVAL_SIGNING_KEY
$tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ('mf-signing-test-' + [Guid]::NewGuid().ToString('n'))
try {
    Remove-Item Env:\MAINFRAME_APPROVAL_SIGNING_KEY -ErrorAction SilentlyContinue
    $env:MAINFRAME_HOME = $tmpRoot
    $genKeyPath = Join-Path $tmpRoot 'mainframe.approval-signing.key'
    Assert-True (-not (Test-Path -LiteralPath $genKeyPath)) 'the test starts with no key file'
    $genSigner = Get-VaultApprovalSigningKey
    try {
        Assert-True ($null -ne $genSigner) 'a keyless machine mints a key and proceeds (no throw)'
        Assert-True (Test-Path -LiteralPath $genKeyPath) 'the generated key was written at the resolved key path'
        $firstPublic = Get-VaultApprovalPublicKey
        Assert-True ($firstPublic.Length -gt 300) 'the minted key has a real public half'
    } finally {
        $genSigner.Dispose()
    }
    $genSigner2 = Get-VaultApprovalSigningKey
    try {
        Assert-Equal $firstPublic (Get-VaultApprovalPublicKey) 'the second call loads the same key'
    } finally {
        $genSigner2.Dispose()
    }
} finally {
    if ($null -eq $savedHome2) { Remove-Item Env:\MAINFRAME_HOME -ErrorAction SilentlyContinue }
    else { $env:MAINFRAME_HOME = $savedHome2 }
    if ($null -eq $savedKeyEnv2) { Remove-Item Env:\MAINFRAME_APPROVAL_SIGNING_KEY -ErrorAction SilentlyContinue }
    else { $env:MAINFRAME_APPROVAL_SIGNING_KEY = $savedKeyEnv2 }
    Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "approval key checks: $script:checks passed"
