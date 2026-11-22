# No Pester dependency. Runs under windows powershell 5.1 AND pwsh 7.
#
# What it pins (vault approval flow red-team audit, 2026-11-15):
#   C1  the approval link is signed with ONE shared EC P-256 key
#       (approval-signing.key in the profile root): the signature is a
#       64-byte raw R||S over the byte-exact payload k LF sid LF code LF
#       exp LF srv, base64url, carried as fragment param `sig`. a missing
#       key + no live session yields an UNSIGNED link with NO error, and
#       the key self-heals from the vault when a live session exists.
#   M5  the ciphertext picker takes the FIRST valid block, caps trial
#       decryptions per poll, and remembers tested lines across polls.
#   H1  the topic fingerprint (first 4 chars + ellipsis) is all the
#       terminal ever prints about the topic.
#   L11 the single-flight lock file is created 0600.
#   L16 the verification code is 4 digits.
#   L19 the full approval URL only prints with -Verbose.
#
# ISOLATED: every profile write goes to a temp profile root and every `bw`
# call goes to a fake bw in a temp bin dir (same pattern as
# vault-approval-ttl.Tests.ps1). the tripwire fails the test if the signing
# key path ever escapes the temp root.
#
# No network at all - not even a local listener: the Muse VM's egress proxy
# intercepts even localhost TCP, so a listener-based test cannot run there.
# The ciphertext picker is tested directly (it is pure), never through the
# polling loop.
$ErrorActionPreference = 'Stop'
$godScript = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\windows\mainframe.ps1'))

$script:checks = 0
function Assert-True($Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:checks++
}
function Assert-Equal($Expected, $Actual, [string]$Message) {
    if ($Expected -ne $Actual) { throw "FAIL: $Message`n  expected: $Expected`n  actual:   $Actual" }
    $script:checks++
}
function Assert-Null($Actual, [string]$Message) {
    if ($null -ne $Actual) { throw "FAIL: $Message`n  expected: null`n  actual:   $Actual" }
    $script:checks++
}

function ConvertFrom-Base64Url {
    param([string]$Value)
    $padded = $Value.Replace('-', '+').Replace('_', '/')
    switch ($padded.Length % 4) {
        2 { $padded += '==' }
        3 { $padded += '=' }
    }
    return [Convert]::FromBase64String($padded)
}

function Get-FileModeOctal {
    param([string]$Path)
    if ($env:OS -eq 'Windows_NT') { return $null }
    if (-not (Get-Command stat -ErrorAction SilentlyContinue)) { return $null }
    return ((& stat -c %a $Path 2>$null) -join '').Trim()
}

# 1. the module parses
$parseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($godScript, [ref]$null, [ref]$parseErrors)
Assert-True ($parseErrors.Count -eq 0) 'mainframe.ps1 parses'

$source = Get-Content -LiteralPath $godScript -Raw

# L19 + H1, structural: the URL and the topic must never reach the terminal
# through Write-Host, whatever the runtime does.
Assert-True ($source -match 'Write-Verbose "approval url:') 'the approval URL prints only with -Verbose'
Assert-True ($source -notmatch 'Write-Host "approval url:') 'the approval URL never prints on the default path'
Assert-True ($source -match 'function Get-VaultMasterPassword \{\s*\[CmdletBinding\(\)\]') 'Get-VaultMasterPassword takes -Verbose'
Assert-True ($source -notmatch 'push notification sent to ntfy topic: \$NtfyTopic') 'the push line never prints the full topic'
Assert-True ($source -notmatch "to topic '\$Topic'") 'the push warnings never print the full topic'

. $godScript

# --- isolation: temp profile root + fake bw ---
$rootLeaf = "vault-signing-test-" + [guid]::NewGuid().ToString('N').Substring(0, 8)
$root = Join-Path ([IO.Path]::GetTempPath()) $rootLeaf
$bin = Join-Path $root 'bin'
$profile = Join-Path $root 'profile'
$itemsFile = Join-Path $root 'bw-items.json'
$callsFile = Join-Path $root 'bw-calls.log'
New-Item -ItemType Directory -Force -Path $bin, (Join-Path (Join-Path $profile 'accounts') 'bitwarden') | Out-Null

# the fake bw: MF_BW_STATE=locked|unlocked decides `status`; `list` cats the
# items file the test writes (and refuses while locked). every invocation
# logs its first word so the test can prove `list` was never called.
if ($env:OS -eq 'Windows_NT') {
    $bw = Join-Path $bin 'bw.cmd'
    @(
        '@echo off'
        'echo %1>>"%MF_BW_CALLS%"'
        'if "%1"=="status" ('
        '  if "%MF_BW_STATE%"=="unlocked" (echo {"status":"unlocked","serverUrl":"https://example.invalid","userEmail":"t@example.invalid"}) else (echo {"status":"locked","serverUrl":"https://example.invalid","userEmail":"t@example.invalid"})'
        ') else if "%1"=="list" ('
        '  if not "%MF_BW_STATE%"=="unlocked" (echo vault is locked 1>&2 & exit /b 1)'
        '  type "%MF_BW_ITEMS%"'
        ') else ('
        '  echo fake bw: unknown command %1 1>&2'
        '  exit /b 1'
        ')'
    ) | Set-Content -LiteralPath $bw -Encoding ASCII
} else {
    $bw = Join-Path $bin 'bw'
    @(
        '#!/bin/sh'
        'echo "$1" >> "$MF_BW_CALLS"'
        'case "$1" in'
        '  status)'
        '    if [ "$MF_BW_STATE" = "unlocked" ]; then echo ''{"status":"unlocked","serverUrl":"https://example.invalid","userEmail":"t@example.invalid"}'';'
        '    else echo ''{"status":"locked","serverUrl":"https://example.invalid","userEmail":"t@example.invalid"}''; fi;;'
        '  list)'
        '    if [ "$MF_BW_STATE" != "unlocked" ]; then echo "vault is locked" >&2; exit 1; fi'
        '    cat "$MF_BW_ITEMS";;'
        '  *) echo "fake bw: unknown command $1" >&2; exit 1;;'
        'esac'
    ) | Set-Content -LiteralPath $bw -Encoding ASCII
    & chmod 755 $bw
}

function Reset-BwCalls { Remove-Item -LiteralPath $callsFile -Force -ErrorAction SilentlyContinue }
function Get-BwCalls {
    if (Test-Path -LiteralPath $callsFile) { return (Get-Content -LiteralPath $callsFile -Raw) } else { return '' }
}

# PEM import/export is .NET Core only: windows powershell 5.1 cannot load
# the key file at all, so the PEM-file cases only run where the runtime has
# the methods. the unsigned-link behaviour IS the 5.1 behaviour, and it is
# asserted unconditionally below. (ImportFromPem is checked by NAME: its
# only overload takes a ReadOnlySpan, so a GetMethod call naming [string]
# finds nothing even where the method exists.)
$canImportPem = (@([System.Security.Cryptography.ECDsa].GetMethods() | Where-Object { $_.Name -eq 'ImportFromPem' }).Count -gt 0)
$canExportPem = $null -ne [System.Security.Cryptography.ECDsa].GetMethod('ExportECPrivateKeyPem')
if (-not ($canImportPem -and $canExportPem)) {
    Write-Host 'NOTE: this runtime has no ECDsa PEM methods (windows powershell 5.1) - the PEM-file signing cases are skipped, unsigned-link behaviour is asserted instead' -ForegroundColor Yellow
}

$savedPath = $env:PATH
$savedProfile = $env:MAINFRAME_PROFILE_ROOT
$savedState = $env:MF_BW_STATE
$savedItems = $env:MF_BW_ITEMS
$savedCalls = $env:MF_BW_CALLS
$savedServer = $env:MAINFRAME_NTFY_SERVER
$savedPages = $env:MAINFRAME_PAGES_BASE
$savedTopic = $env:MAINFRAME_NTFY_TOPIC
$rsa = $null
$ec = $null
try {
    $env:PATH = "$bin$([IO.Path]::PathSeparator)$savedPath"
    $env:MAINFRAME_PROFILE_ROOT = $profile
    # ambient relay overrides would make the default-relay assertions lie
    Remove-Item Env:MAINFRAME_NTFY_SERVER -ErrorAction SilentlyContinue
    Remove-Item Env:MAINFRAME_PAGES_BASE -ErrorAction SilentlyContinue
    Remove-Item Env:MAINFRAME_NTFY_TOPIC -ErrorAction SilentlyContinue
    $env:MF_BW_STATE = 'locked'
    $env:MF_BW_ITEMS = $itemsFile
    $env:MF_BW_CALLS = $callsFile

    # 2. the key path resolves under the temp profile root, never the real one
    $keyPath = Get-VaultApprovalLinkSigningKeyPath
    Assert-True ($keyPath -like "*$rootLeaf*") 'the signing key path must live in the temp profile, never the real one'
    Assert-True ($keyPath -like '*approval-signing.key') 'the signing key file is approval-signing.key'

    # 3. the payload format is exactly k LF sid LF code LF exp LF srv
    $payload = Get-VaultApprovalLinkPayload -Key 'k1' -Sid 's1' -Code '1234' -Exp '1799999999' -Server 'https://relay.example.test'
    Assert-Equal "k1`ns1`n1234`n1799999999`nhttps://relay.example.test" $payload 'the payload is k LF sid LF code LF exp LF srv'
    $payloadBytes = [Text.Encoding]::UTF8.GetBytes($payload)
    Assert-Equal 4 (@($payloadBytes | Where-Object { $_ -eq 10 }).Count) 'the payload has exactly 4 LFs and no trailing LF'
    $emptyPayload = Get-VaultApprovalLinkPayload -Key 'k1' -Sid 's1' -Code '1234' -Exp '' -Server ''
    Assert-Equal "k1`ns1`n1234`n`n" $emptyPayload 'absent exp/srv serialize as empty fields, not missing ones'

    # 4. the signature is 64 bytes + base64url-shaped, and verifies
    $ec = [System.Security.Cryptography.ECDsa]::Create([System.Security.Cryptography.ECCurve+NamedCurves]::nistP256)
    $sig = Get-VaultApprovalLinkSignature -Key $ec -Payload $payload
    Assert-True ($sig -match '^[A-Za-z0-9_-]{86}$') 'the signature is 86 base64url chars (64 bytes, no padding)'
    $sigBytes = ConvertFrom-Base64Url -Value $sig
    Assert-Equal 64 $sigBytes.Length 'the signature decodes to 64 bytes (raw R||S)'
    $verified = $ec.VerifyData($payloadBytes, $sigBytes, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
    Assert-True $verified 'the signature verifies against the signing key'
    $tampered = [Text.Encoding]::UTF8.GetBytes("k1`ns1`n1234`n1799999999`nhttps://evil.example")
    $verifiedTampered = $ec.VerifyData($tampered, $sigBytes, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
    Assert-True (-not $verifiedTampered) 'the signature does NOT verify over a tampered payload'

    # 5. a signed link: the sig covers the exact strings in the URL
    if ($canImportPem -and $canExportPem) {
        $pem = $ec.ExportECPrivateKeyPem()
        [IO.File]::WriteAllText($keyPath, $pem, (New-Object System.Text.UTF8Encoding($false)))

        $rsa = [System.Security.Cryptography.RSA]::Create(2048)
        $session = Get-VaultApprovalUrl -Rsa $rsa -PromptContext 'vault access' -HostName 'TESTHOST' `
            -Agent 'signing-test' -ExpiresInSeconds 300 -Server 'https://relay.example.test/ntfy'
        $fragment = ($session.Url -split '#', 2)[1]
        $params = @{}
        foreach ($pair in ($fragment -split '&')) {
            $kv = $pair -split '=', 2
            $params[$kv[0]] = [Uri]::UnescapeDataString($kv[1])
        }
        Assert-True ($null -ne $session.Signature) 'a keyed machine signs the link'
        Assert-True ($session.Signature -match '^[A-Za-z0-9_-]{86}$') 'the link signature is 86 base64url chars'
        Assert-Equal $session.Signature $params['sig'] 'the sig in the URL is the returned signature'
        $expectedPayload = "$($params['k'])`n$($params['sid'])`n$($params['code'])`n$($params['exp'])`n$($params['srv'])"
        Assert-Equal $expectedPayload $session.SignedPayload 'the signed payload is built from the exact URL strings'
        $linkSigBytes = ConvertFrom-Base64Url -Value $session.Signature
        Assert-Equal 64 $linkSigBytes.Length 'the link signature decodes to 64 bytes'
        $linkVerified = $ec.VerifyData([Text.Encoding]::UTF8.GetBytes($session.SignedPayload), $linkSigBytes, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
        Assert-True $linkVerified 'the link signature verifies against the temp key'
        Assert-Equal 'https://relay.example.test/ntfy' $params['srv'] 'the relay hint is the signed srv'
        Assert-True ($params['exp'] -match '^[0-9]+$') 'the expiry is the signed exp'

        # L16: the code is 4 digits
        Assert-True ($session.Code -match '^[0-9]{4}$') 'the verification code is 4 digits'
        Assert-True (([int]$session.Code -ge 1000) -and ([int]$session.Code -le 9999)) 'the code is in 1000..9999'

        # no relay hint, no expiry: srv/exp are empty payload fields
        $plain = Get-VaultApprovalUrl -Rsa $rsa -PromptContext 'vault access' -HostName 'TESTHOST' -Agent 'signing-test'
        $plainFragment = ($plain.Url -split '#', 2)[1]
        $plainParams = @{}
        foreach ($pair in ($plainFragment -split '&')) {
            $kv = $pair -split '=', 2
            $plainParams[$kv[0]] = [Uri]::UnescapeDataString($kv[1])
        }
        Assert-True (-not $plainParams.ContainsKey('srv')) 'the default relay carries no srv param'
        Assert-True (-not $plainParams.ContainsKey('exp')) 'no expiry carries no exp param'
        $expectedPlain = "$($plainParams['k'])`n$($plainParams['sid'])`n$($plainParams['code'])`n`n"
        Assert-Equal $expectedPlain $plain.SignedPayload 'absent exp/srv sign as empty fields'
    }

    # 6. missing key + no live session: unsigned link, NO error, and the
    # vault is never asked for the key (no `list` call at all)
    Remove-Item -LiteralPath $keyPath -Force -ErrorAction SilentlyContinue
    $env:MF_BW_STATE = 'locked'
    Reset-BwCalls
    if (-not $rsa) { $rsa = [System.Security.Cryptography.RSA]::Create(2048) }
    $unsigned = $null
    $threw = $false
    try {
        $unsigned = Get-VaultApprovalUrl -Rsa $rsa -PromptContext 'vault access' -HostName 'TESTHOST' -Agent 'signing-test'
    } catch {
        $threw = $true
    }
    Assert-True (-not $threw) 'a missing key + locked vault yields a link, not an error'
    Assert-Null $unsigned.Signature 'the unsigned link carries no signature'
    Assert-Null $unsigned.SignedPayload 'the unsigned link carries no signed payload'
    Assert-True ($unsigned.Url -notmatch '&sig=') 'the unsigned URL has no sig param'
    Assert-True ((Get-BwCalls) -notmatch 'list') 'a locked vault is never asked to list items'
    Assert-True (-not (Test-Path -LiteralPath $keyPath)) 'no key file appears without a live session'

    # 7. self-heal: the key comes back from the vault on a live session
    if ($canImportPem -and $canExportPem) {
        $pem = $ec.ExportECPrivateKeyPem()
        $items = @(
            @{ name = 'github.com/FahadBinHussain/mainframe / approval-signing.key.backup'; notes = 'not a pem' }
            @{ name = 'github.com/FahadBinHussain/mainframe / approval-signing.key'; notes = $pem }
        ) | ConvertTo-Json -Compress
        Set-Content -LiteralPath $itemsFile -Value $items -Encoding UTF8 -NoNewline

        # 7a. locked: no fetch, no file
        $env:MF_BW_STATE = 'locked'
        Reset-BwCalls
        Assert-True (-not (Sync-VaultApprovalSigningKeyFromVault)) 'sync fails closed while the vault is locked'
        Assert-True (-not (Test-Path -LiteralPath $keyPath)) 'no key file while locked'
        Assert-True ((Get-BwCalls) -notmatch 'list') 'no list call while locked'

        # 7b. unlocked: exact-name match only, saved 0600
        $env:MF_BW_STATE = 'unlocked'
        Reset-BwCalls
        Assert-True (Sync-VaultApprovalSigningKeyFromVault) 'sync fetches the key on a live session'
        Assert-True (Test-Path -LiteralPath $keyPath) 'the key file appears after sync'
        $savedPem = [IO.File]::ReadAllText($keyPath)
        Assert-Equal ($pem.Trim() + "`n") $savedPem 'the saved key is the vault notes, verbatim'
        $mode = Get-FileModeOctal -Path $keyPath
        if ($null -ne $mode) { Assert-Equal '600' $mode 'the synced key file is 0600' }
        Assert-True ((Get-BwCalls) -match 'list') 'sync listed the vault to find the key'

        # 7c. a present key is never re-fetched
        Reset-BwCalls
        Assert-True (Sync-VaultApprovalSigningKeyFromVault) 'sync is a no-op when the key already exists'
        Assert-Equal '' (Get-BwCalls) 'no bw call at all when the key already exists'

        # 7d. a search hit with the WRONG name is not the key
        Remove-Item -LiteralPath $keyPath -Force
        $decoyOnly = @(
            @{ name = 'github.com/FahadBinHussain/mainframe / approval-signing.key.backup'; notes = $pem }
        ) | ConvertTo-Json -Compress
        Set-Content -LiteralPath $itemsFile -Value $decoyOnly -Encoding UTF8 -NoNewline
        Assert-True (-not (Sync-VaultApprovalSigningKeyFromVault)) 'a non-exact name match is not the key'
        Assert-True (-not (Test-Path -LiteralPath $keyPath)) 'no key file from a decoy item'

        # 7e. notes without a PEM are not the key
        $notPem = @(
            @{ name = 'github.com/FahadBinHussain/mainframe / approval-signing.key'; notes = 'just a note' }
        ) | ConvertTo-Json -Compress
        Set-Content -LiteralPath $itemsFile -Value $notPem -Encoding UTF8 -NoNewline
        Assert-True (-not (Sync-VaultApprovalSigningKeyFromVault)) 'non-PEM notes are not the key'
        Assert-True (-not (Test-Path -LiteralPath $keyPath)) 'no key file from non-PEM notes'
    }

    # 8. M5: the FIRST valid ciphertext wins, fakes are skipped, trials are
    # capped per poll and remembered across polls
    $otherRsa = [System.Security.Cryptography.RSA]::Create(2048)
    try {
        function New-TestCipher {
            param([System.Security.Cryptography.RSA]$Key, [string]$Plain)
            $bytes = [Text.Encoding]::UTF8.GetBytes($Plain)
            return [Convert]::ToBase64String($Key.Encrypt($bytes, [System.Security.Cryptography.RSAEncryptionPadding]::OaepSHA256))
        }
        $real1 = New-TestCipher -Key $rsa -Plain 'real-password-one'
        $real2 = New-TestCipher -Key $rsa -Plain 'real-password-two'
        $fake1 = New-TestCipher -Key $otherRsa -Plain 'attacker-password'
        $fake2 = New-TestCipher -Key $otherRsa -Plain 'attacker-password-2'
        Assert-Equal 344 $real1.Length 'a real ciphertext is 344 base64 chars'
        Assert-Equal 344 $fake1.Length 'a fake ciphertext is 344 base64 chars too'

        # a fake BEFORE the real one is skipped, not returned
        Assert-Equal $real1 (Select-VaultApprovalCiphertext -Body "$fake1`n$real1" -Rsa $rsa) 'a fake before the real one is skipped'
        # a fake AFTER the real one must never displace it (was: last wins)
        Assert-Equal $real1 (Select-VaultApprovalCiphertext -Body "$real1`n$fake1" -Rsa $rsa) 'a fake after the real one never wins'
        # two valid blocks: the first wins
        Assert-Equal $real1 (Select-VaultApprovalCiphertext -Body "$real1`n$real2" -Rsa $rsa) 'the first valid block wins over a later valid one'
        # junk + expired markers are ignored, never returned
        $junkBody = "garbage`n{`"mf`":`"expired`",`"at`":1}`n$real1"
        Assert-Equal $real1 (Select-VaultApprovalCiphertext -Body $junkBody -Rsa $rsa) 'junk and expired markers are ignored'
        Assert-Null (Select-VaultApprovalCiphertext -Body '' -Rsa $rsa) 'an empty poll yields nothing'
        Assert-Null (Select-VaultApprovalCiphertext -Body "$fake1`n$fake2" -Rsa $rsa) 'fakes alone yield nothing'
        # no RSA key: shape alone decides, first well-formed line wins
        Assert-Equal $fake1 (Select-VaultApprovalCiphertext -Body "$fake1`n$real1") 'without a key the first well-formed line wins'

        # the trial cap + tested-set cursor: 12 fakes hide the real one, 10
        # trials per poll. poll 1 tests 10 fakes and finds nothing; poll 2
        # skips the tested 10 and reaches the real one.
        $fakes = @()
        for ($i = 0; $i -lt 12; $i++) { $fakes += (New-TestCipher -Key $otherRsa -Plain "fake-$i") }
        $floodBody = (($fakes + $real1) -join "`n")
        $tested = New-Object System.Collections.Generic.HashSet[string]
        $poll1 = Select-VaultApprovalCiphertext -Body $floodBody -Rsa $rsa -Tested $tested -MaxTrialsPerPoll 10
        Assert-Null $poll1 'poll 1 stops at the trial cap without reaching the real block'
        Assert-Equal 10 $tested.Count 'poll 1 remembered exactly 10 tested lines'
        $poll2 = Select-VaultApprovalCiphertext -Body $floodBody -Rsa $rsa -Tested $tested -MaxTrialsPerPoll 10
        Assert-Equal $real1 $poll2 'poll 2 skips the tested fakes and reaches the real block'
    } finally {
        $otherRsa.Dispose()
    }

    # 9. H1: the fingerprint is 4 chars + an ellipsis, nothing more
    $ellipsis = [char]0x2026
    Assert-Equal ("abcd$ellipsis") (Get-NtfyTopicFingerprint -Topic 'abcdefghij0123456789') 'the fingerprint is the first 4 chars + ellipsis'
    Assert-Equal ("ab$ellipsis") (Get-NtfyTopicFingerprint -Topic 'ab') 'a short topic fingerprints whole'
    Assert-Equal '?' (Get-NtfyTopicFingerprint -Topic '') 'an empty topic fingerprints as ?'

    # 10. L11: the single-flight lock file is created 0600
    $turn = Enter-VaultApprovalRequest -PromptContext 'signing test' -TimeoutSeconds 30 -Agent 'signing-test' -HostName 'TESTHOST' -SinceUtc ([DateTime]::UtcNow)
    try {
        Assert-True $turn.Acquired 'the test turn is acquired'
        Assert-True (Test-Path -LiteralPath $turn.Path) 'the lock file exists while held'
        $lockMode = Get-FileModeOctal -Path $turn.Path
        if ($null -ne $lockMode) { Assert-Equal '600' $lockMode 'the lock file is created 0600' }
    } finally {
        Close-VaultApprovalRequest -Path $turn.Path -Token $turn.Token
    }
    Assert-True (-not (Test-Path -LiteralPath $turn.Path)) 'the lock file is released'
} finally {
    if ($rsa) { $rsa.Dispose() }
    if ($ec) { $ec.Dispose() }
    $env:PATH = $savedPath
    if ($null -eq $savedProfile) { Remove-Item Env:MAINFRAME_PROFILE_ROOT -ErrorAction SilentlyContinue } else { $env:MAINFRAME_PROFILE_ROOT = $savedProfile }
    if ($null -eq $savedState) { Remove-Item Env:MF_BW_STATE -ErrorAction SilentlyContinue } else { $env:MF_BW_STATE = $savedState }
    if ($null -eq $savedItems) { Remove-Item Env:MF_BW_ITEMS -ErrorAction SilentlyContinue } else { $env:MF_BW_ITEMS = $savedItems }
    if ($null -eq $savedCalls) { Remove-Item Env:MF_BW_CALLS -ErrorAction SilentlyContinue } else { $env:MF_BW_CALLS = $savedCalls }
    if ($null -eq $savedServer) { Remove-Item Env:MAINFRAME_NTFY_SERVER -ErrorAction SilentlyContinue } else { $env:MAINFRAME_NTFY_SERVER = $savedServer }
    if ($null -eq $savedPages) { Remove-Item Env:MAINFRAME_PAGES_BASE -ErrorAction SilentlyContinue } else { $env:MAINFRAME_PAGES_BASE = $savedPages }
    if ($null -eq $savedTopic) { Remove-Item Env:MAINFRAME_NTFY_TOPIC -ErrorAction SilentlyContinue } else { $env:MAINFRAME_NTFY_TOPIC = $savedTopic }
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "vault-approval signing checks: $script:checks passed" -ForegroundColor Green
