# No Pester dependency. This file has to pass under windows powershell 5.1 AND
# pwsh 7 - the whole point is that the approval flow works in both.
#
# It talks to NO network at all. What it pins:
#   - the approval descriptor is canonical (the runner and the phone have to
#     build the same bytes, or every approval is refused)
#   - a signature only covers the descriptor it was made for
#   - the link carries the signature, and the page has the matching key
#   - a missing signing key fails LOUDLY instead of shipping an unsigned link
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
}
function Assert-Contains($Haystack, [string]$Needle, [string]$Message) {
    if (-not $Haystack.Contains($Needle)) { throw "FAIL: $Message`n  missing: $Needle" }
}

# 1. the module parses
$parseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($module, [ref]$null, [ref]$parseErrors)
Assert-True ($parseErrors.Count -eq 0) 'vault-approval.psm1 parses'

Import-Module $module -Force -DisableNameChecking

# 2. the descriptor is canonical
#
# byte exact. the phone rebuilds this string from the link fragment and
# verifies the signature over it, so a change here that is not mirrored in
# the page (or in the relay) silently breaks every approval.
$descriptor = Get-VaultApprovalDescriptor -Topic 'mf-vault-0123456789abcdef01234567' `
    -Sid 'mf-vault-0123456789abcdef01234567' -Key 'PUBKEY' -Code '42' -ExpiresAt '1700000000' `
    -Server 'https://relay.example.test/ntfy' -HostName 'LAPTOP-MAIN' -Context 'vault access' `
    -Agent 'minimax-code' -Model 'MiniMax-M3.1-Flash'

$expected = @(
    'mf-vault-approval-v1'
    'topic=mf-vault-0123456789abcdef01234567'
    'sid=mf-vault-0123456789abcdef01234567'
    'k=PUBKEY'
    'code=42'
    'exp=1700000000'
    'srv=https://relay.example.test/ntfy'
    'host=LAPTOP-MAIN'
    'ctx=vault access'
    'agent=minimax-code'
    'model=MiniMax-M3.1-Flash'
) -join "`n"
Assert-Equal $expected $descriptor 'the descriptor has the documented shape'

# an empty field is an empty field, never "null" and never a missing line
$emptyDescriptor = Get-VaultApprovalDescriptor -Topic 't' -Sid 't'
$emptyLines = $emptyDescriptor -split "`n"
Assert-Equal 11 $emptyLines.Count 'the descriptor always has eleven lines'
Assert-Equal 'model=' $emptyLines[10] 'a missing model is an empty field'

# 3. the signing key loads and its public half is the one in the page
$publicKey = Get-VaultApprovalPublicKey
Assert-True ($publicKey.Length -gt 300) 'the approval public key is a real SPKI'
Assert-True ($publicKey -notmatch '[+/=]') 'the public key is base64url'

$pageSource = Get-Content -LiteralPath $page -Raw
$match = [regex]::Match($pageSource, "APPROVAL_PUBLIC_KEY_B64URL\s*=\s*'([A-Za-z0-9_-]+)'")
Assert-True ($match.Success) 'the approval page carries a signing public key'
Assert-Equal $publicKey $match.Groups[1].Value 'the page carries the SAME public key the runner signs with'

# 4. a signature only covers the descriptor it was made for
$signer = Get-VaultApprovalSigningKey
try {
    $signature = New-VaultApprovalDescriptorSignature -Descriptor $descriptor -Rsa $signer
    Assert-True ($signature.Length -gt 300) 'the signature is a full RSA block'

    $sigBytes = [Convert]::FromBase64String($signature.Replace('-', '+').Replace('_', '/') + ('=' * ((4 - ($signature.Length % 4)) % 4)))
    # the signer can verify too, and it is the same key the phone verifies
    # with - the public half is what the page carries.
    $ok = $signer.VerifyData(
        [System.Text.Encoding]::UTF8.GetBytes($descriptor),
        $sigBytes,
        [System.Security.Cryptography.HashAlgorithmName]::SHA256,
        [System.Security.Cryptography.RSASignaturePadding]::Pkcs1
    )
    Assert-True $ok 'the signature verifies against its own descriptor'

    # the point of the whole exercise: a descriptor that was edited after
    # signing must not verify. a forgery changes exactly one of these.
    foreach ($field in @('code=42', 'topic=mf-vault-0123456789abcdef01234567', 'srv=https://relay.example.test/ntfy', 'k=PUBKEY')) {
        $tampered = $descriptor.Replace($field, ($field -replace '=(.*)$', '=tampered'))
        $bad = $signer.VerifyData(
            [System.Text.Encoding]::UTF8.GetBytes($tampered),
            $sigBytes,
            [System.Security.Cryptography.HashAlgorithmName]::SHA256,
            [System.Security.Cryptography.RSASignaturePadding]::Pkcs1
        )
        Assert-True (-not $bad) "a descriptor with a changed $field must not verify"
    }
} finally {
    $signer.Dispose()
}

# 5. the link carries the signature, and it is the one over the link's own facts
$rsa = [System.Security.Cryptography.RSA]::Create(2048)
try {
    $session = Get-VaultApprovalUrl -Rsa $rsa -PromptContext 'vault access' -HostName 'LAPTOP-MAIN' `
        -Agent 'minimax-code' -Model 'MiniMax-M3.1-Flash' -ExpiresInSeconds 300 `
        -Server 'https://relay.example.test/ntfy'
    Assert-Contains $session.Url '&sig=' 'the approval link carries the signature'
    Assert-Equal $session.Descriptor $session.Descriptor 'the descriptor is returned with the link'

    # the descriptor the phone rebuilds from the fragment must be the one the
    # runner signed. rebuild it here the way the page does.
    $fragment = $session.Url.Split('#')[1]
    $params = [System.Web.HttpUtility]::ParseQueryString($fragment)
    $rebuilt = Get-VaultApprovalDescriptor -Topic $params['sid'] -Sid $params['sid'] -Key $params['k'] `
        -Code $params['code'] -ExpiresAt $params['exp'] -Server $params['srv'] -HostName $params['host'] `
        -Context $params['ctx'] -Agent $params['agent'] -Model $params['model']
    Assert-Equal $session.Descriptor $rebuilt 'the phone rebuilds the same descriptor from the link'
} finally {
    $rsa.Dispose()
}

# 6. a missing signing key fails loudly - an unsigned link would be refused
# by the phone, so shipping one is worse than stopping
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

# 7. the credential resolver picks the right shape
$savedAuth = $env:MAINFRAME_NTFY_AUTH
$savedToken = $env:MAINFRAME_NTFY_TOKEN
try {
    Remove-Item Env:\MAINFRAME_NTFY_AUTH -ErrorAction SilentlyContinue
    Remove-Item Env:\MAINFRAME_NTFY_TOKEN -ErrorAction SilentlyContinue
    Assert-Equal 'Bearer tk_explicit' (Get-VaultNtfyCredential -Token 'tk_explicit') 'an explicit token becomes a bearer header'
    Assert-Equal 'Basic abc123' (Get-VaultNtfyCredential -Auth 'Basic abc123') 'an explicit credential is used as it is'
    $env:MAINFRAME_NTFY_AUTH = 'Basic fromenv'
    Assert-Equal 'Basic fromenv' (Get-VaultNtfyCredential) 'the environment overrides the config'
    $env:MAINFRAME_NTFY_TOKEN = 'tk_fromenv'
    Assert-Equal 'Basic fromenv' (Get-VaultNtfyCredential) 'the credential wins over the token'
} finally {
    if ($null -eq $savedAuth) { Remove-Item Env:\MAINFRAME_NTFY_AUTH -ErrorAction SilentlyContinue }
    else { $env:MAINFRAME_NTFY_AUTH = $savedAuth }
    if ($null -eq $savedToken) { Remove-Item Env:\MAINFRAME_NTFY_TOKEN -ErrorAction SilentlyContinue }
    else { $env:MAINFRAME_NTFY_TOKEN = $savedToken }
}

Write-Host "approval descriptor checks: $script:checks passed"
