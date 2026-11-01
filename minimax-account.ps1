$ErrorActionPreference = 'Stop'

# MiniMax Code account profile helper.
#
# MiniMax Code has exactly one signed-in account per data dir, and it keeps that
# account in two plaintext json files it re-reads every 250ms. That is the whole
# opening: swap the pair and the running app follows, no restart, no keychain.
#
# Profiles are keyed by account email only and stored in:
#   %APPDATA%\mainframe\accounts\minimax\<email>
# that folder sits inside the encrypted mainframe secret backup, which is why the
# refresh token lives here rather than in a vault item: MiniMax rotates the
# refresh token on every renewal, so a vault copy goes stale within minutes and a
# stale one can sign the account out. This folder is rewritten after each refresh.
#
# MiniMax will not tell us whose account a credential is: /v1/api/user/info leaves
# email BLANK for accounts bound to Google, the name it returns is a nickname the
# user typed, and there is no oidc discovery on the authorization server, so a
# device grant carries no id_token. So the address comes from a human, either as
# the argument to login/harvest or (login with no argument) a moment later, when
# the unnamed sign-in is harvested under the address it belongs to. Either way it
# is stated, never guessed: what is stored is emailSource (minimax / stated) plus
# the numeric realUserID as the anchor, so one account can never land under two
# emails.
#
# Usage:
#   .\minimax-account.ps1 harvest <email>              save the live sign-in as a profile
#   .\minimax-account.ps1 login <email>                device-code sign-in, then save + activate it
#   .\minimax-account.ps1 use <email>                  switch the live sign-in to a profile
#   .\minimax-account.ps1 refresh [email]              renew a stored access token (rotates the refresh token)
#   .\minimax-account.ps1 keepalive                    rotate every idle profile's chain so none lapses
#   .\minimax-account.ps1 run [email] <mcode args...>  make that profile live, then run the mcode-tools CLI
#   .\minimax-account.ps1 list / current / status / status-all / path / env
#   .\minimax-account.ps1 logout [email]               revoke + clear the LIVE sign-in
#   .\minimax-account.ps1 forget <email>               move a stored profile aside
#   .\minimax-account.ps1 status-all -Json             one json object, for the monitor api
#
# Every write to the live auth files goes through the same lock dir the app uses,
# and is re-read afterwards to prove the switch landed -- so a switch either
# happened or fails with the reason.

$tool = 'minimax'
$serviceName = 'MiniMax Code'

$accountRoot = Join-Path $env:APPDATA 'mainframe\accounts\minimax'
$currentFile = Join-Path $accountRoot 'current.json'

# ---- the oauth contract, read out of the shipped runtime -------------------
# @mavis/oauth-core/dist/contracts.js + endpoint-config.js. these are the values
# the app asserts on, so a hand-written credential has to carry them exactly.
$clientId = 'mcode-public'
$audience = 'agent-backend'
$defaultScope = 'agent.default'
$tokenType = 'Bearer'
$authStateSchemaVersion = 2
$credentialSchemaVersion = 1

$accountOrigins = @{
    en = @{ dev = 'https://account-overseas-test.xaminim.com'; test = 'https://account-overseas-test.xaminim.com'; staging = 'https://account-overseas-pre.xaminim.com'; prod = 'https://account.minimax.io' }
    cn = @{ dev = 'https://account-test.xaminim.com'; test = 'https://account-test.xaminim.com'; staging = 'https://account-pre.xaminim.com'; prod = 'https://account.minimax.cn' }
}
$identityOrigins = @{ en = 'https://agent.minimax.io'; cn = 'https://agent.minimax.cn' }

# the app renews on its own once a token is gone; renew a little earlier so a
# switch never installs something the app immediately has to re-grant.
$refreshMarginSec = 5 * 60
$deviceTimeoutSec = 6 * 60
$httpTimeoutSec = 20
$staleLockMs = 30 * 1000

function Show-Usage {
    @(
        'MiniMax Code account profile helper',
        '',
        'Profiles are keyed by account email only and stored in:',
        '  %APPDATA%\mainframe\accounts\minimax\<email>',
        '',
        'Usage:',
        '  .\minimax-account.ps1 harvest <email>              save the live sign-in as a profile',
        '  .\minimax-account.ps1 login [email]                device-code sign-in, then save + activate it',
        '                                               (MiniMax reports no email for google-bound',
        '                                                accounts, so you name the one you approve; run',
        '                                                it with no email and you name it after, with',
        '                                                harvest <email>)',
        '  .\minimax-account.ps1 use <email>                  switch the live sign-in to a profile',
        '  .\minimax-account.ps1 refresh [email]              renew a stored access token',
        '  .\minimax-account.ps1 keepalive                    rotate every idle profile so no chain lapses',
        '  .\minimax-account.ps1 run [email] <mcode args...>  switch, then run the mcode-tools CLI',
        '  .\minimax-account.ps1 list',
        '  .\minimax-account.ps1 current',
        '  .\minimax-account.ps1 status [email]',
        '  .\minimax-account.ps1 status-all',
        '  .\minimax-account.ps1 path [email]',
        '  .\minimax-account.ps1 env [email]',
        '  .\minimax-account.ps1 logout [email]               revoke + clear the LIVE sign-in',
        '  .\minimax-account.ps1 forget <email>               move a stored profile aside',
        '',
        'Add -Json to any command for a single machine-readable json object.',
        '',
        'Examples:',
        '  .\minimax-account.ps1 login someone@example.com',
        '  .\minimax-account.ps1 login            # sign in unnamed, then name it:',
        '  .\minimax-account.ps1 harvest someone@example.com',
        '  .\minimax-account.ps1 use someone@example.com',
        '  .\minimax-account.ps1 status-all -Json',
        '  .\minimax-account.ps1 run someone@example.com --help'
    ) -join [Environment]::NewLine | Write-Host
}

# ---- profile identity ------------------------------------------------------

function Normalize-ProfileName {
    param([string]$Profile)

    if ([string]::IsNullOrWhiteSpace($Profile)) {
        throw 'Email profile is required.'
    }

    $normalized = $Profile.Trim().ToLowerInvariant()
    if ($normalized -notmatch '^[^\s@]+@[^\s@]+\.[^\s@]+$') {
        throw "MiniMax profile must be an account email, not a label or display name: $Profile"
    }

    foreach ($char in [IO.Path]::GetInvalidFileNameChars()) {
        $invalidChar = [string]$char
        if ([string]::IsNullOrEmpty($invalidChar)) {
            continue
        }

        if ($normalized.IndexOf($invalidChar, [StringComparison]::Ordinal) -ge 0) {
            throw "Profile contains a character that cannot be used in a Windows folder name: $Profile"
        }
    }

    return $normalized
}

function Test-LooksLikeEmail {
    param([AllowNull()][string]$Value)

    return (-not [string]::IsNullOrWhiteSpace($Value)) -and ($Value -match '^[^\s@]+@[^\s@]+\.[^\s@]+$')
}

function Get-ProfilePath {
    param([string]$Profile)

    return Join-Path $accountRoot (Normalize-ProfileName -Profile $Profile)
}

# MiniMax leaves userInfo.email BLANK for accounts that signed in through Google
# (verified against /v1/api/user/info and /matrix/api/v1/user/profile), and the
# device grant asks for agent.default only, so there is no id_token to read an
# address out of either. The address is therefore either MiniMax's own answer or
# something a human who knows which account they approved has to state.
#
# A display name is NEVER consulted: it is a nickname the user types, and keying
# a pool on one merges two accounts the first time someone names them alike.
function Resolve-AccountEmail {
    param(
        [AllowNull()][string]$IdentityEmail,
        [AllowNull()][string]$StatedEmail
    )

    $out = @{}
    $out['Email'] = $null
    $out['Source'] = $null

    $candidates = @(
        @{ Value = $IdentityEmail; From = 'minimax' },
        @{ Value = $StatedEmail; From = 'stated' }
    )
    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate.Value)) {
            continue
        }

        $match = [regex]::Match($candidate.Value, '[^\s@]+@[^\s@]+\.[^\s@]+')
        if (-not $match.Success) {
            continue
        }

        $out['Email'] = $match.Value.ToLowerInvariant()
        $out['Source'] = $candidate.From
        return $out
    }

    return $out
}

# Two folders claiming the same MiniMax account is how a pool quietly spends one
# quota twice. realUserID is MiniMax's own stable id, so it is the anchor: a
# second email for an id that is already banked is a mislabel, not a new account.
function Test-IdentityAnchorTaken {
    param(
        [AllowNull()][string]$RealUserID,
        [string]$Email
    )

    if ([string]::IsNullOrWhiteSpace($RealUserID)) {
        return $null
    }

    foreach ($directory in @(Get-ChildItem -LiteralPath $accountRoot -Directory -ErrorAction SilentlyContinue)) {
        $metadata = Read-ProfileMetadata -Profile $directory.Name
        if (-not $metadata) {
            continue
        }

        if (([string]$metadata['realUserID'] -eq $RealUserID) -and ([string]$metadata['email'] -ne $Email)) {
            return [string]$metadata['email']
        }
    }

    return $null
}

# ---- the live auth namespace ----------------------------------------------

function Get-DataDir {
    foreach ($name in @('MINIMAX_DATA_DIR', 'MAVIS_DATA_DIR')) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return $value.Trim().TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
        }
    }

    return Join-Path $env:USERPROFILE '.minimax'
}

function Get-Base64UrlSha256 {
    param([string]$Text)

    # node's digest('base64url') over the utf8 bytes of the same string.
    $bytes = [Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))
    return [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function Get-Md5 {
    param([string]$Text)

    $bytes = [Security.Cryptography.MD5]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))
    return (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Get-Fingerprint {
    param([AllowNull()][string]$Token)

    if ([string]::IsNullOrWhiteSpace($Token)) {
        return $null
    }

    $bytes = [Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($Token))
    return (($bytes | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0, 12)
}

function Get-EnvText {
    param([string]$Name, [AllowNull()][string]$Default)

    $raw = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return [string]$Default
    }

    return $raw.Trim()
}

function Get-MiniMaxNamespace {
    $dataDir = Get-DataDir
    $buildEnv = (Get-EnvText 'MCODE_BUILD_ENV' 'prod').ToLowerInvariant()
    $regionRaw = (Get-EnvText 'MCODE_REGION' 'en').ToLowerInvariant()
    # the desktop launcher uses "global" for the overseas region.
    $region = if ($regionRaw -in @('global', 'overseas')) { 'en' } else { $regionRaw }
    if ($region -notin @('en', 'cn')) {
        throw "MCODE_REGION must be en, global or cn, got: $regionRaw"
    }
    if ($buildEnv -notin @('dev', 'test', 'staging', 'prod')) {
        throw "MCODE_BUILD_ENV must be dev, test, staging or prod, got: $buildEnv"
    }

    $authHome = Join-Path $dataDir 'auth'
    $namespaceHome = Join-Path (Join-Path (Join-Path $authHome $buildEnv) $region) $clientId
    $service = "com.minimax.mcode.oauth.$buildEnv.$region"
    # the account half of the record key is a sha256 over "<authHome><NUL>mcode-public".
    $account = Get-Base64UrlSha256 -Text ($authHome + [char]0 + $clientId)

    $accountOrigin = $accountOrigins[$region][$buildEnv]

    return [pscustomobject]@{
        DataDir = $dataDir
        AuthHome = $authHome
        NamespaceHome = $namespaceHome
        CredentialFile = Join-Path $namespaceHome 'auth.json'
        StateFile = Join-Path $namespaceHome 'auth-state.json'
        LockFile = Join-Path $namespaceHome 'auth.lock'
        RefreshStagingFile = Join-Path (Join-Path $namespaceHome 'refresh') 'auth.json'
        Service = $service
        Account = $account
        RecordKey = ($service + [char]0 + $account)
        BuildEnv = $buildEnv
        Region = $region
        ClientId = $clientId
        AccountOrigin = $accountOrigin
        DeviceEndpoint = (Get-EnvText 'MCODE_OAUTH_DEVICE_AUTHORIZATION_ENDPOINT' "$accountOrigin/oauth2/device/code")
        TokenEndpoint = (Get-EnvText 'MCODE_OAUTH_TOKEN_ENDPOINT' "$accountOrigin/oauth2/token")
        RevokeEndpoint = (Get-EnvText 'MCODE_OAUTH_REVOCATION_ENDPOINT' "$accountOrigin/oauth2/revoke")
        IdentityOrigin = (Get-EnvText 'MINIMAX_IDENTITY_ORIGIN' $identityOrigins[$region])
    }
}

# ---- json + file plumbing --------------------------------------------------

function Read-JsonFile {
    param([string]$Path, [string]$Label)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    $text = $null
    $lastIoError = $null
    for ($attempt = 0; $attempt -lt 6; $attempt += 1) {
        try {
            $text = [IO.File]::ReadAllText($Path)
            break
        } catch {
            $lastIoError = $_.Exception
            Start-Sleep -Milliseconds 120
        }
    }

    if ($null -eq $text) {
        throw "$Label at $Path could not be read -- $($lastIoError.Message). MiniMax Code may be mid-write; retry, and nothing here overwrites it until it can be read."
    }
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    try {
        return $text | ConvertFrom-Json -AsHashtable
    } catch {
        throw "$Label at $Path is not readable json -- $($_.Exception.Message). repair or remove it; this helper will not overwrite an unparseable auth file."
    }
}

function Write-JsonFile {
    param([string]$Path, $Value, [string]$Label)

    $dir = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $leaf = Split-Path -Leaf $Path
    $tmp = Join-Path $dir ('.{0}.{1}.tmp' -f $leaf, [Guid]::NewGuid().ToString('N'))
    # same shape the app writes: 2-space indent, utf8, no bom.
    $json = ConvertTo-Json -InputObject $Value -Depth 12
    [IO.File]::WriteAllText($tmp, $json, [Text.UTF8Encoding]::new($false))

    $lastError = $null
    for ($attempt = 0; $attempt -lt 4; $attempt += 1) {
        try {
            Move-Item -LiteralPath $tmp -Destination $Path -Force
            $lastError = $null
            break
        } catch {
            $lastError = $_.Exception
            Start-Sleep -Milliseconds ([int](40 * [Math]::Pow(2, $attempt)))
        }
    }
    if ($lastError) {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        throw "could not replace $Label at $Path -- $($lastError.Message)"
    }
}

function Enter-AuthLock {
    param([string]$LockFile, [int]$TimeoutSec = 25)

    # proper-lockfile semantics (cross-process-lock.js locks "auth.lock" with
    # stale 30s + 120 retries, factor 1.15, 5-250ms): the mutex is a DIRECTORY
    # named "<file>.lock" created atomically, and the holder keeps an "update"
    # file inside it fresh. a guard dir with NO update file reads as a crashed
    # holder, so the app would delete it mid-write -- we therefore write the
    # marker too and judge staleness by its mtime, exactly like the app does.
    $dir = "$LockFile.lock"
    $marker = Join-Path $dir 'update'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $LockFile) | Out-Null
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $delay = 5
    for (;;) {
        try {
            [void](New-Item -ItemType Directory -Path $dir -ErrorAction Stop)
            [void](New-Item -ItemType File -Path $marker -Force -ErrorAction SilentlyContinue)
            return $dir
        } catch {
            if (-not (Test-Path -LiteralPath $dir)) {
                continue
            }

            $stamp = if (Test-Path -LiteralPath $marker) {
                (Get-Item -LiteralPath $marker -Force).LastWriteTime
            } else {
                (Get-Item -LiteralPath $dir -Force).LastWriteTime
            }

            if ($stamp -and ((Get-Date) - $stamp).TotalMilliseconds -gt $staleLockMs) {
                Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
                continue
            }

            if ((Get-Date) -gt $deadline) {
                throw "the MiniMax auth lock at $dir stayed held for over ${TimeoutSec}s -- MiniMax Code is mid-login or mid-refresh. finish that in the app, or quit it and retry."
            }

            Start-Sleep -Milliseconds ([Math]::Min(250, $delay))
            $delay = [Math]::Min(250, [int]($delay * 1.15))
        }
    }
}

function Exit-AuthLock {
    param([AllowNull()][string]$Dir)

    if ($Dir -and (Test-Path -LiteralPath $Dir)) {
        Remove-Item -LiteralPath $Dir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ---- live state ------------------------------------------------------------

function Assert-CredentialContract {
    param([AllowNull()]$Credential, [string]$Where)

    if ($Credential -isnot [hashtable]) {
        throw "${Where}: no credential record to check."
    }

    foreach ($field in @('accessToken', 'refreshToken', 'tokenType', 'clientId', 'audience', 'expiresAtMs', 'generation', 'loginEpoch')) {
        if (-not $Credential.ContainsKey($field)) {
            throw "${Where}: credential record is missing '$field'; this helper writes only the shape MiniMax Code itself asserts on."
        }
    }
    if ($Credential['clientId'] -ne $clientId -or $Credential['audience'] -ne $audience -or $Credential['tokenType'] -ne $tokenType) {
        throw "${Where}: credential contract drifted (clientId=$($Credential['clientId']) audience=$($Credential['audience']) tokenType=$($Credential['tokenType'])). expected $clientId / $audience / $tokenType."
    }

    $scopes = @($Credential['scopes'])
    if ($scopes.Count -eq 0 -or ($scopes -notcontains $defaultScope)) {
        throw "${Where}: credential scopes are $(($scopes) -join ','), which does not include '$defaultScope'; MiniMax Code would refuse it."
    }
}

function New-Credential {
    param(
        [AllowNull()][string]$AccessToken,
        [AllowNull()][string]$RefreshToken,
        [long]$ExpiresAtMs,
        [long]$Generation,
        [AllowNull()][string]$LoginEpoch
    )

    if ([string]::IsNullOrWhiteSpace($AccessToken)) {
        throw 'no access token came back from the token endpoint.'
    }
    if ([string]::IsNullOrWhiteSpace($RefreshToken)) {
        throw 'no refresh token came back from the token endpoint.'
    }

    $credential = @{}
    $credential['schemaVersion'] = $credentialSchemaVersion
    $credential['accessToken'] = $AccessToken.Trim()
    $credential['refreshToken'] = $RefreshToken.Trim()
    $credential['tokenType'] = $tokenType
    $credential['clientId'] = $clientId
    $credential['scopes'] = @($defaultScope)
    $credential['audience'] = $audience
    $credential['expiresAtMs'] = $ExpiresAtMs
    $credential['generation'] = $Generation
    $credential['loginEpoch'] = if ([string]::IsNullOrWhiteSpace($LoginEpoch)) { [Guid]::NewGuid().ToString() } else { $LoginEpoch.Trim() }

    Assert-CredentialContract -Credential $credential -Where 'new credential'
    return $credential
}

function Get-LiveAuth {
    $ns = Get-MiniMaxNamespace
    $state = Read-JsonFile -Path $ns.StateFile -Label 'auth-state.json'
    $payload = Read-JsonFile -Path $ns.CredentialFile -Label 'auth.json'

    $credential = $null
    $records = if ($payload -and $payload.ContainsKey('records') -and $payload['records'] -is [hashtable]) { $payload['records'] } else { $null }
    if ($records -and $records.ContainsKey($ns.RecordKey)) {
        $credential = $records[$ns.RecordKey]
        if ($credential -is [hashtable]) {
            Assert-CredentialContract -Credential $credential -Where "the live record in $($ns.CredentialFile)"
        } else {
            $credential = $null
        }
    }

    $status = if ($state -and $state.ContainsKey('status')) { [string]$state['status'] } else { $null }
    $generation = if ($state -and $state.ContainsKey('generation')) { [long]$state['generation'] } else { 0 }
    $expiresAtMs = if ($state -and $state.ContainsKey('expiresAtMs')) { [long]$state['expiresAtMs'] } else { 0 }

    # the app only reports signed-in when the state and the record agree on
    # generation; the same join decides whether what we found is usable.
    $signedIn = [bool](($status -eq 'authenticated') -and $credential -and ([long]$credential['generation'] -eq $generation))

    return [pscustomobject]@{
        Namespace = $ns
        Status = $status
        Generation = $generation
        ExpiresAtMs = $expiresAtMs
        Credential = $credential
        SignedIn = $signedIn
        StateFile = $ns.StateFile
        CredentialFile = $ns.CredentialFile
        RecordCount = if ($records) { @($records.Keys).Count } else { 0 }
    }
}

function Get-AuthenticatedState {
    param([hashtable]$Credential, $Namespace)

    $state = @{}
    $state['schemaVersion'] = $authStateSchemaVersion
    $state['status'] = 'authenticated'
    $state['storeKind'] = 'file'
    $state['clientId'] = [string]$Credential['clientId']
    $state['scopes'] = @($Credential['scopes'])
    $state['audience'] = [string]$Credential['audience']
    $state['buildEnv'] = $Namespace.BuildEnv
    $state['region'] = $Namespace.Region
    $state['generation'] = [long]$Credential['generation']
    $state['expiresAtMs'] = [long]$Credential['expiresAtMs']
    return $state
}

function Install-LiveCredential {
    param(
        [hashtable]$Credential,
        [long]$ExistingGeneration = 0
    )

    $ns = Get-MiniMaxNamespace
    # commitLogin's own rule: one above the highest generation either file holds.
    $generation = [Math]::Max($ExistingGeneration, [long]$Credential['generation']) + 1
    $installed = $Credential.Clone()
    $installed['generation'] = $generation

    $records = @{}
    $records[$ns.RecordKey] = $installed
    $payload = @{}
    $payload['schemaVersion'] = 1
    $payload['records'] = $records

    # credential first, then state -- the order commitLogin uses, so a reader that
    # sees 'authenticated' always finds the matching record already there.
    Write-JsonFile -Path $ns.CredentialFile -Value $payload -Label 'auth.json'
    Write-JsonFile -Path $ns.StateFile -Value (Get-AuthenticatedState -Credential $installed -Namespace $ns) -Label 'auth-state.json'

    # a half-finished refresh of the account being replaced must not commit over
    # this install, and a cached CLI projection must stop naming the previous one.
    Remove-Item -LiteralPath $ns.RefreshStagingFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $ns.DataDir 'local-runtime.auth.json') -Force -ErrorAction SilentlyContinue

    # prove it landed: re-read and re-apply the join the app performs.
    $after = Get-LiveAuth
    if (-not $after.SignedIn) {
        throw "the switch was written to $($ns.StateFile) but reading it back does not report a signed-in account (state generation $($after.Generation), record generation $($installed['generation'])). MiniMax Code rewrote these files in the same moment -- quit it and retry."
    }
    # the loginEpoch is what identifies THIS sign-in: a refresh rotates the
    # tokens but keeps it. so a different accessToken with the same loginEpoch is
    # the app consuming the switch, not an intruder; a different loginEpoch is.
    if ([string]$after.Credential['loginEpoch'] -ne [string]$installed['loginEpoch']) {
        throw "the credential read back from $($ns.CredentialFile) belongs to a different sign-in (loginEpoch $([string]$after.Credential['loginEpoch']) instead of $([string]$installed['loginEpoch'])); something else wrote this data dir in the same moment."
    }

    $appRewrote = [bool]([string]$after.Credential['accessToken'] -ne [string]$installed['accessToken'])

    return [pscustomobject]@{
        Generation = $generation
        ExpiresAtMs = [long]$installed['expiresAtMs']
        AccessToken = [string]$installed['accessToken']
        LoginEpoch = [string]$installed['loginEpoch']
        AppRewroteIt = $appRewrote
        Namespace = $ns
        Report = $after
    }
}

# ---- profiles --------------------------------------------------------------

function Write-ProfileRecord {
    param(
        [string]$Profile,
        [hashtable]$Credential,
        [AllowNull()][hashtable]$Identity,
        [AllowNull()][string]$EmailSource
    )

    $normalized = Normalize-ProfileName -Profile $Profile
    $path = Get-ProfilePath -Profile $normalized
    New-Item -ItemType Directory -Force -Path $path | Out-Null
    $ns = Get-MiniMaxNamespace

    # when MiniMax does name an account, that name is the law: a folder claiming
    # somebody else's credential is a pool that will switch to the wrong person.
    $identityEmail = $null
    if ($Identity) {
        $identityEmail = (Resolve-AccountEmail -IdentityEmail $Identity['userEmail']).Email
    }
    if ($identityEmail -and $identityEmail -ne $normalized) {
        throw "profile '$normalized' does not match the account this credential belongs to ($identityEmail). fix the email or harvest it under its own address."
    }

    # a refresh has no identity response to re-read, so carry the stored one over.
    $existing = Read-ProfileMetadata -Profile $normalized

    # a grant MiniMax refused once stays flagged until the chain actually changes:
    # the same refresh token is the same dead grant, a different one is a new
    # sign-in and the flag is dropped with it.
    $previous = Read-JsonFile -Path (Join-Path $path 'credential.json') -Label "credential.json for $normalized"
    $sameChain = [bool](
        $previous -and
        ([string]$previous['refreshToken'] -eq [string]$Credential['refreshToken']) -and
        ([string]$previous['loginEpoch'] -eq [string]$Credential['loginEpoch'])
    )

    ConvertTo-Json -InputObject $Credential -Depth 8 |
        Set-Content -LiteralPath (Join-Path $path 'credential.json') -Encoding UTF8 -NoNewline

    $metadata = @{}
    $metadata['tool'] = $tool
    $metadata['service'] = $serviceName
    $metadata['profile'] = $normalized
    $metadata['email'] = $normalized
    # how this address became known: MiniMax named it, or a human stated it at
    # sign-in. the second one is normal for google-bound accounts, and the panel
    # says so rather than implying the service verified it. the origin never
    # downgrades: a re-bank that matched the live credential to this folder is not
    # a new naming event, and 'you named it' stays true after fifty re-banks.
    $metadata['emailSource'] = if ($identityEmail) {
        'minimax'
    } elseif ($EmailSource -eq 'stated') {
        'stated'
    } elseif ($existing -and $existing['emailSource']) {
        [string]$existing['emailSource']
    } elseif ($EmailSource) {
        $EmailSource
    } else {
        $null
    }
    $metadata['displayName'] = if ($Identity) { $Identity['userName'] } elseif ($existing) { $existing['displayName'] } else { $null }
    $metadata['userID'] = if ($Identity) { $Identity['userID'] } elseif ($existing) { $existing['userID'] } else { $null }
    $metadata['realUserID'] = if ($Identity) { $Identity['realUserID'] } elseif ($existing) { $existing['realUserID'] } else { $null }
    $metadata['buildEnv'] = $ns.BuildEnv
    $metadata['region'] = $ns.Region
    $metadata['clientId'] = $clientId
    $metadata['audience'] = $audience
    $metadata['scope'] = $defaultScope
    $metadata['dataDir'] = $ns.DataDir
    $metadata['namespaceHome'] = $ns.NamespaceHome
    $metadata['credentialPath'] = (Join-Path $path 'credential.json')
    $metadata['tokenFingerprint'] = Get-Fingerprint -Token ([string]$Credential['accessToken'])
    $metadata['expiresAtMs'] = [long]$Credential['expiresAtMs']
    $metadata['generation'] = [long]$Credential['generation']
    $metadata['loginEpoch'] = [string]$Credential['loginEpoch']
    $metadata['updatedAt'] = [DateTimeOffset]::UtcNow.ToString('o')
    $metadata['grantDead'] = [bool]($sameChain -and $existing -and [bool]$existing['grantDead'])
    if ($metadata['grantDead']) {
        $metadata['grantDeadReason'] = [string]$existing['grantDeadReason']
        $metadata['grantDeadAt'] = [string]$existing['grantDeadAt']
    }

    ConvertTo-Json -InputObject $metadata -Depth 8 |
        Set-Content -LiteralPath (Join-Path $path 'profile.json') -Encoding UTF8 -NoNewline
}

# MiniMax's answer to a spent refresh token is final for that chain: "this
# refresh token can no longer be used". Marking the profile makes the panel offer
# a new sign-in instead of a switch that would wipe the app's live session.
function Set-ProfileGrantDead {
    param(
        [string]$Profile,
        [string]$Reason
    )

    $normalized = Normalize-ProfileName -Profile $Profile
    $metadata = Read-ProfileMetadata -Profile $normalized
    if (-not $metadata) {
        return
    }

    $metadata['grantDead'] = $true
    $metadata['grantDeadReason'] = $Reason
    $metadata['grantDeadAt'] = [DateTimeOffset]::UtcNow.ToString('o')
    ConvertTo-Json -InputObject $metadata -Depth 8 |
        Set-Content -LiteralPath (Join-Path (Get-ProfilePath -Profile $normalized) 'profile.json') -Encoding UTF8 -NoNewline
}

function Read-ProfileCredential {
    param([string]$Profile)

    $normalized = Normalize-ProfileName -Profile $Profile
    $path = Join-Path (Get-ProfilePath -Profile $normalized) 'credential.json'
    $credential = Read-JsonFile -Path $path -Label "credential.json for $normalized"
    if (-not $credential) {
        return $null
    }

    Assert-CredentialContract -Credential $credential -Where "profile $normalized"
    return $credential
}

function Read-ProfileMetadata {
    param([string]$Profile)

    $normalized = Normalize-ProfileName -Profile $Profile
    $path = Join-Path (Get-ProfilePath -Profile $normalized) 'profile.json'
    return Read-JsonFile -Path $path -Label "profile.json for $normalized"
}

function Set-ActiveProfile {
    param([string]$Profile)

    $normalized = Normalize-ProfileName -Profile $Profile
    New-Item -ItemType Directory -Force -Path $accountRoot | Out-Null
    $current = @{}
    $current['tool'] = $tool
    $current['service'] = $serviceName
    $current['profile'] = $normalized
    $current['updatedAt'] = [DateTimeOffset]::UtcNow.ToString('o')
    ConvertTo-Json -InputObject $current -Depth 4 |
        Set-Content -LiteralPath $currentFile -Encoding UTF8 -NoNewline
}

function Get-ActiveProfile {
    if (-not (Test-Path -LiteralPath $currentFile)) {
        return $null
    }

    $current = Read-JsonFile -Path $currentFile -Label 'current.json'
    if (-not $current -or -not $current.ContainsKey('profile')) {
        return $null
    }

    try {
        return Normalize-ProfileName -Profile ([string]$current['profile'])
    } catch {
        return $null
    }
}

function Get-ProfileDirectories {
    if (-not (Test-Path -LiteralPath $accountRoot)) {
        return @()
    }

    return @(Get-ChildItem -LiteralPath $accountRoot -Directory -Force |
        Where-Object { $_.Name -match '^[^\s@]+@[^\s@]+\.[^\s@]+$' } |
        Sort-Object Name)
}

# Which stored profile owns this live credential? loginEpoch is minted per
# sign-in and survives every refresh, so it identifies the account without a
# network round-trip and without trusting a label.
function Find-ProfileForCredential {
    param([AllowNull()][hashtable]$Credential)

    if (-not $Credential) {
        return $null
    }

    $epoch = [string]$Credential['loginEpoch']
    $refresh = [string]$Credential['refreshToken']
    foreach ($dir in Get-ProfileDirectories) {
        $stored = Read-ProfileCredential -Profile $dir.Name
        if (-not $stored) {
            continue
        }
        if ($epoch -and [string]$stored['loginEpoch'] -eq $epoch) {
            return $dir.Name
        }
        if ($refresh -and [string]$stored['refreshToken'] -eq $refresh) {
            return $dir.Name
        }
    }

    return $null
}

function Get-ProfileOrActive {
    param([AllowNull()][string]$Profile)

    if (-not [string]::IsNullOrWhiteSpace($Profile)) {
        return Normalize-ProfileName -Profile $Profile
    }

    $active = Get-ActiveProfile
    if ($active -and (Test-Path -LiteralPath (Get-ProfilePath -Profile $active))) {
        return $active
    }

    $live = Get-LiveAuth
    if ($live.SignedIn) {
        $fromLive = Find-ProfileForCredential -Credential $live.Credential
        if ($fromLive) {
            return $fromLive
        }
    }

    throw 'No email was given, no stored profile is active, and the live sign-in matches no profile. Run .\minimax-account.ps1 harvest <email> first.'
}

# ---- http ------------------------------------------------------------------

function Invoke-MiniMaxForm {
    param(
        [string]$Endpoint,
        [hashtable]$Fields,
        [hashtable]$ExtraHeaders = @{},
        [int]$TimeoutSec = $httpTimeoutSec
    )

    $headers = @{}
    $headers['accept'] = 'application/json'
    foreach ($key in $ExtraHeaders.Keys) {
        $headers[$key] = $ExtraHeaders[$key]
    }

    try {
        $response = Invoke-WebRequest -Method Post -Uri $Endpoint -ContentType 'application/x-www-form-urlencoded' `
            -Body $Fields -Headers $headers -TimeoutSec $TimeoutSec -SkipHttpErrorCheck
    } catch {
        # a transport failure is a RESULT, not a throw: the device poll has to
        # tolerate one slow round trip without losing a live device code. every
        # caller still names this error verbatim when it decides to fail.
        $failed = @{}
        $failed['Status'] = 0
        $failed['Body'] = $null
        $failed['Raw'] = ''
        $failed['Error'] = 'transport_failure'
        $failed['ErrorDescription'] = "the MiniMax endpoint $Endpoint could not be reached -- $($_.Exception.Message)"
        return $failed
    }

    $text = if ($null -ne $response.Content) { [string]$response.Content } else { '' }
    $parsed = $null
    if ($text.Trim()) {
        try {
            $parsed = $text | ConvertFrom-Json -AsHashtable
        } catch {
            throw "the MiniMax endpoint $Endpoint answered HTTP $([int]$response.StatusCode) with something that is not json: $($text.Substring(0, [Math]::Min(200, $text.Length)))"
        }
    }

    $result = @{}
    $result['Status'] = [int]$response.StatusCode
    $result['Body'] = $parsed
    $result['Raw'] = $text
    $result['Error'] = if ($parsed -and $parsed.ContainsKey('error')) { [string]$parsed['error'] } else { $null }
    $result['ErrorDescription'] = if ($parsed -and $parsed.ContainsKey('error_description')) { [string]$parsed['error_description'] } else { $null }
    return $result
}

function Start-DeviceAuthorization {
    $ns = Get-MiniMaxNamespace
    $random = [byte[]]::new(32)
    [Security.Cryptography.RandomNumberGenerator]::Fill($random)
    $verifier = [Convert]::ToBase64String($random).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    $challenge = Get-Base64UrlSha256 -Text $verifier

    $extraHeaders = @{}
    if ($ns.BuildEnv -eq 'staging') {
        $extraHeaders['X-User-Pre'] = '1'
    }

    $response = Invoke-MiniMaxForm -Endpoint $ns.DeviceEndpoint -ExtraHeaders $extraHeaders -Fields @{
        client_id = $clientId
        scope = $defaultScope
        audience = $audience
        code_challenge = $challenge
        code_challenge_method = 'S256'
    }
    if ($response.Status -ne 200 -or -not $response.Body) {
        $reason = if ($response.Error) { "$($response.Error) $($response.ErrorDescription)" } else { $response.Raw }
        throw "the device-code request to $($ns.DeviceEndpoint) failed with HTTP $($response.Status): $reason"
    }

    $body = $response.Body
    foreach ($field in @('device_code', 'user_code', 'verification_uri', 'expires_in')) {
        if (-not $body.ContainsKey($field)) {
            throw "the device-code response from $($ns.DeviceEndpoint) has no '$field' field: $($response.Raw)"
        }
    }

    $authorization = @{}
    $authorization['DeviceCode'] = [string]$body['device_code']
    $authorization['UserCode'] = [string]$body['user_code']
    $authorization['VerificationUri'] = [string]$body['verification_uri']
    $authorization['VerificationUriComplete'] = if ($body.ContainsKey('verification_uri_complete')) { [string]$body['verification_uri_complete'] } else { $null }
    $authorization['ExpiresInSec'] = [int]$body['expires_in']
    $authorization['IntervalSec'] = if ($body.ContainsKey('interval')) { [int]$body['interval'] } else { 5 }
    $authorization['CodeVerifier'] = $verifier
    $authorization['Namespace'] = $ns
    return $authorization
}

function Get-TokenGrant {
    param(
        [hashtable]$Fields,
        [string]$Endpoint,
        [string]$Context
    )

    $response = Invoke-MiniMaxForm -Endpoint $Endpoint -Fields $Fields
    $grant = @{}
    $grant['Status'] = $response.Status
    $grant['Error'] = $response.Error
    $grant['ErrorDescription'] = $response.ErrorDescription
    $grant['Raw'] = $response.Raw
    $grant['Ok'] = [bool]($response.Status -eq 200 -and $response.Body -and -not $response.Error)
    if (-not $grant['Ok']) {
        return $grant
    }

    $body = $response.Body
    if (-not $body.ContainsKey('access_token') -or -not $body.ContainsKey('expires_in')) {
        throw "the token endpoint answered the $Context grant without access_token/expires_in: $($response.Raw)"
    }

    $grant['AccessToken'] = [string]$body['access_token']
    $grant['RefreshToken'] = if ($body.ContainsKey('refresh_token')) { [string]$body['refresh_token'] } else { $null }
    $grant['ExpiresInSec'] = [int]$body['expires_in']
    $grant['TokenType'] = if ($body.ContainsKey('token_type')) { [string]$body['token_type'] } else { $tokenType }
    return $grant
}

function Wait-DeviceToken {
    param([hashtable]$Authorization)

    $ns = $Authorization['Namespace']
    $deadline = (Get-Date).AddSeconds([Math]::Min([int]$Authorization['ExpiresInSec'], $deviceTimeoutSec))
    $interval = [Math]::Max(1, [int]$Authorization['IntervalSec'])
    $lastError = $null

    while ((Get-Date) -lt $deadline) {
        $grant = Get-TokenGrant -Endpoint $ns.TokenEndpoint -Context 'device' -Fields @{
            grant_type = 'urn:ietf:params:oauth:grant-type:device_code'
            device_code = [string]$Authorization['DeviceCode']
            client_id = $clientId
            code_verifier = [string]$Authorization['CodeVerifier']
        }
        if ($grant.Ok) {
            if (-not $grant.RefreshToken) {
                throw 'the device grant returned no refresh_token, so this account could never be switched back to. run login again.'
            }
            return $grant
        }

        $lastError = $grant
        switch ($grant.Error) {
            'authorization_pending' { Start-Sleep -Seconds $interval }
            'slow_down' { $interval += 5; Start-Sleep -Seconds $interval }
            'access_denied' { throw 'the sign-in was declined in the browser. approve the device code and run login again.' }
            'expired_token' { throw 'the device code expired before it was approved. run login again.' }
            'transport_failure' {
                # one slow round trip must not throw away a device code the user
                # is about to approve: keep polling until the real deadline.
                Write-Warning "the device poll could not get through; retrying. $($grant.ErrorDescription)"
                Start-Sleep -Seconds $interval
            }
            default {
                throw "the token endpoint rejected the device grant (HTTP $($grant.Status) $($grant.Error) $($grant.ErrorDescription))."
            }
        }
    }

    $waited = [Math]::Min([int]$Authorization['ExpiresInSec'], $deviceTimeoutSec)
    $last = if ($lastError) { " (last answer: $($lastError.Error) $($lastError.ErrorDescription))" } else { '' }
    throw "nobody approved the device code within $waited seconds$last"
}

function Invoke-RefreshGrant {
    param([hashtable]$Credential, [AllowNull()][string]$Label)

    $ns = Get-MiniMaxNamespace
    $grant = Get-TokenGrant -Endpoint $ns.TokenEndpoint -Context 'refresh' -Fields @{
        grant_type = 'refresh_token'
        refresh_token = [string]$Credential['refreshToken']
        client_id = $clientId
        scope = $defaultScope
        audience = $audience
    }
    if (-not $grant.Ok) {
        if ($grant.Error -eq 'transport_failure') {
            # the request never got through, so the saved refresh_token is still
            # valid. saying "sign in again" here would throw away a good grant.
            throw "could not reach the MiniMax token endpoint to refresh $(if ($Label) { $Label } else { 'the stored account' }) -- $($grant.ErrorDescription) the saved refresh_token was not used and is still valid; retry once the network is back."
        }
        $failure = "refreshing the stored MiniMax token failed (HTTP $($grant.Status) $($grant.Error) $($grant.ErrorDescription))."
        $again = if ($Label) { "login $Label" } else { 'login <email>' }
        throw ($failure + " the token endpoint refused the saved refresh_token, so that account has to sign in again: .\minimax-account.ps1 $again")
    }

    $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    return New-Credential -AccessToken $grant.AccessToken `
        -RefreshToken $(if ($grant.RefreshToken) { $grant.RefreshToken } else { [string]$Credential['refreshToken'] }) `
        -ExpiresAtMs ($now + ([int]$grant.ExpiresInSec * 1000)) `
        -Generation ([long]$Credential['generation']) `
        -LoginEpoch ([string]$Credential['loginEpoch'])
}

function Invoke-RevokeGrant {
    param([string]$RefreshToken)

    $ns = Get-MiniMaxNamespace
    $response = Invoke-MiniMaxForm -Endpoint $ns.RevokeEndpoint -Fields @{
        token = $RefreshToken
        token_type_hint = 'refresh_token'
        client_id = $clientId
    }
    if ($response.Status -notin @(200, 204)) {
        throw "the revoke request failed with HTTP $($response.Status): $($response.Raw)"
    }
}

# ---- identity --------------------------------------------------------------

# GET /v1/api/user/info, signed exactly as the desktop app signs it: yy is an md5
# over the encoded path+query, an md5 of the millisecond clock and a literal, and
# x-signature is an md5 over the second and a fixed secret.
function Resolve-MiniMaxIdentity {
    param([AllowNull()][string]$AccessToken)

    if ([string]::IsNullOrWhiteSpace($AccessToken)) {
        throw 'no access token was given, so the MiniMax account email cannot be looked up.'
    }

    $ns = Get-MiniMaxNamespace
    $nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $offsetSeconds = [int][Math]::Round((Get-TimeZone).BaseUtcOffset.TotalSeconds)
    $pairs = @(
        @('device_platform', 'mcode'),
        @('biz_id', '3'),
        @('app_id', '3001'),
        @('version_code', '22201'),
        @('unix', "$nowMs"),
        @('timezone_offset', "$offsetSeconds"),
        @('sys_language', 'en'),
        @('lang', 'en'),
        @('device_id', '0'),
        @('os_name', 'win32'),
        @('browser_name', 'mcode'),
        @('user_id', '0'),
        @('client', 'mcode')
    )
    $search = (($pairs | ForEach-Object { '{0}={1}' -f [Uri]::EscapeDataString($_[0]), [Uri]::EscapeDataString($_[1]) }) -join '&')
    $path = '/v1/api/user/info'
    $encodedPath = [Uri]::EscapeDataString("$path`?$search")
    $yy = Get-Md5 -Text ($encodedPath + '_{}' + (Get-Md5 -Text "$nowMs") + 'ooui')
    $second = [long][Math]::Floor($nowMs / 1000)

    $headers = @{}
    $headers['Accept'] = 'application/json'
    $headers['Content-Type'] = 'application/json'
    $headers['User-Agent'] = 'MiniMaxCode'
    $headers['Authorization'] = "Bearer $AccessToken"
    $headers['yy'] = $yy
    $headers['x-timestamp'] = "$second"
    $headers['x-signature'] = Get-Md5 -Text "${second}I*7Cf%WZ#S&%1RlZJ&C2"

    try {
        $response = Invoke-WebRequest -Method Get -Uri "$($ns.IdentityOrigin)$path`?$search" -Headers $headers -TimeoutSec 10 -SkipHttpErrorCheck
    } catch {
        throw "the MiniMax profile lookup at $($ns.IdentityOrigin)$path could not be reached -- $($_.Exception.Message)"
    }

    $status = [int]$response.StatusCode
    $text = if ($null -ne $response.Content) { [string]$response.Content } else { '' }
    if ($status -eq 401) {
        throw 'MiniMax rejected this access token for the profile lookup (HTTP 401) -- it is expired, or the account was signed out server-side.'
    }
    if ($status -ne 200) {
        throw "the profile lookup at $($ns.IdentityOrigin)$path answered HTTP ${status}: $($text.Substring(0, [Math]::Min(200, $text.Length)))"
    }

    try {
        $body = $text | ConvertFrom-Json -AsHashtable
    } catch {
        throw "the profile lookup answered HTTP 200 with something that is not json: $($text.Substring(0, [Math]::Min(200, $text.Length)))"
    }

    $statusInfo = if ($body.ContainsKey('statusInfo')) { $body['statusInfo'] } else { $null }
    if ($statusInfo -and $statusInfo.ContainsKey('code') -and [int]$statusInfo['code'] -ne 0) {
        $code = [int]$statusInfo['code']
        if ($code -eq 1000048) {
            throw 'MiniMax rejected this access token for the profile lookup (statusInfo.code 1000048, unauthorized). that account has to run login again.'
        }
        throw "the profile lookup was rejected (statusInfo.code $code): $($statusInfo['message'])"
    }

    $data = if ($body.ContainsKey('data')) { $body['data'] } else { $null }
    $user = $null
    if ($data) {
        foreach ($key in @('userInfo', 'user_info')) {
            if ($data.ContainsKey($key)) {
                $user = $data[$key]
                break
            }
        }
    }
    if (-not $user) {
        throw "the profile lookup answered without data.userInfo -- $($text.Substring(0, [Math]::Min(300, $text.Length)))"
    }

    $identity = @{}
    foreach ($key in @('userID', 'realUserID', 'email', 'name', 'subUserName')) {
        $identity[$key] = if ($user.ContainsKey($key)) { [string]$user[$key] } else { $null }
    }

    $out = @{}
    $out['userID'] = $identity['userID']
    $out['realUserID'] = $identity['realUserID']
    $out['userEmail'] = $identity['email']
    $out['userName'] = $identity['name']
    $out['subUserName'] = $identity['subUserName']
    return $out
}

# ---- status ----------------------------------------------------------------

function Get-AppProcessReport {
    $processes = @(Get-Process -Name 'MiniMax Code' -ErrorAction SilentlyContinue)
    $report = @{}
    $report['running'] = ($processes.Count -gt 0)
    $report['windows'] = $processes.Count
    return $report
}

function Get-ExpiryFields {
    param([long]$ExpiresAtMs)

    $expiry = @{}
    if ($ExpiresAtMs -le 0) {
        $expiry['ExpiresAt'] = $null
        $expiry['ExpiresInSeconds'] = $null
        $expiry['Expired'] = $true
        return $expiry
    }

    $remaining = [long][Math]::Floor(([DateTimeOffset]::FromUnixTimeMilliseconds($ExpiresAtMs).ToUnixTimeSeconds() - [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()))
    $expiry['ExpiresAt'] = [DateTimeOffset]::FromUnixTimeMilliseconds($ExpiresAtMs).ToUniversalTime().ToString('o')
    $expiry['ExpiresInSeconds'] = $remaining
    $expiry['Expired'] = [bool]($remaining -le 0)
    return $expiry
}

function Get-ProfileRow {
    param(
        [string]$Profile,
        [AllowNull()][string]$LiveEpoch,
        [AllowNull()][string]$LiveRefresh,
        [AllowNull()][string]$Active
    )

    $normalized = Normalize-ProfileName -Profile $Profile
    $path = Get-ProfilePath -Profile $normalized
    $metadata = Read-ProfileMetadata -Profile $normalized
    $credential = Read-ProfileCredential -Profile $normalized
    $epoch = if ($credential) { [string]$credential['loginEpoch'] } else { $null }
    $refresh = if ($credential) { [string]$credential['refreshToken'] } else { $null }
    $expiry = Get-ExpiryFields -ExpiresAtMs $(if ($credential) { [long]$credential['expiresAtMs'] } else { 0 })
    $isLive = [bool](($epoch -and $epoch -eq $LiveEpoch) -or ($refresh -and $refresh -eq $LiveRefresh))
    $grantDead = [bool]($metadata -and [bool]$metadata['grantDead'])

    $state = if (-not $credential) { 'missing-credential' } elseif ($isLive) { 'live' } elseif ($grantDead) { 'grant-dead' } elseif ($expiry.Expired) { 'expired-token' } elseif ($normalized -eq $Active) { 'active' } else { 'stored' }

    $row = @{}
    $row['email'] = $normalized
    $row['displayName'] = if ($metadata) { $metadata['displayName'] } else { $null }
    $row['userID'] = if ($metadata) { $metadata['userID'] } else { $null }
    $row['realUserID'] = if ($metadata) { $metadata['realUserID'] } else { $null }
    # 'minimax' = the service named this address; 'stated' = a human did at login,
    # because MiniMax leaves email blank for google-bound accounts.
    $row['emailSource'] = if ($metadata) { $metadata['emailSource'] } else { $null }
    $row['folder'] = $path
    $row['credentialFile'] = Join-Path $path 'credential.json'
    $row['tokenFingerprint'] = if ($metadata) { $metadata['tokenFingerprint'] } else { $null }
    $row['generation'] = if ($credential) { [long]$credential['generation'] } else { $null }
    $row['expiresAt'] = $expiry['ExpiresAt']
    $row['expiresInSeconds'] = $expiry['ExpiresInSeconds']
    $row['expired'] = $expiry['Expired']
    $row['savedAt'] = if ($metadata -and $metadata['updatedAt']) { [DateTimeOffset]::Parse([string]$metadata['updatedAt']).ToUniversalTime().ToString('o').Replace('+00:00','Z') } else { $null }
    $row['isLive'] = $isLive
    $row['isActive'] = [bool]($normalized -eq $Active)
    $row['grantDead'] = $grantDead
    $row['grantDeadReason'] = if ($grantDead) { [string]$metadata['grantDeadReason'] } else { $null }
    $row['state'] = $state
    return $row
}

function Get-StatusReport {
    $ns = Get-MiniMaxNamespace
    $live = Get-LiveAuth
    $active = Get-ActiveProfile
    $liveEpoch = if ($live.Credential) { [string]$live.Credential['loginEpoch'] } else { $null }
    $liveRefresh = if ($live.Credential) { [string]$live.Credential['refreshToken'] } else { $null }
    $liveProfile = if ($live.SignedIn) { Find-ProfileForCredential -Credential $live.Credential } else { $null }

    # MiniMax rotates this grant's refresh token on the app's own hourly refresh,
    # and a stored profile that fell behind that rotation is a dead grant: the
    # next switch installs a token MiniMax answers "this refresh token can no
    # longer be used" for, and the app then wipes its own sign-in. so the live
    # head is copied into the profile that owns it on every read -- local file
    # work only, no network, and it is what keeps a switchable account switchable.
    $rebanked = $null
    if ($live.SignedIn -and $liveProfile) {
        $storedLive = Read-ProfileCredential -Profile $liveProfile
        if ($storedLive -and
            (([string]$storedLive['refreshToken'] -ne [string]$live.Credential['refreshToken']) -or
             ([string]$storedLive['accessToken'] -ne [string]$live.Credential['accessToken']))) {
            Write-ProfileRecord -Profile $liveProfile -Credential $live.Credential -Identity $null
            $rebanked = $liveProfile
        }
    }

    $expiry = Get-ExpiryFields -ExpiresAtMs $live.ExpiresAtMs
    $app = Get-AppProcessReport

    $profiles = @(foreach ($dir in Get-ProfileDirectories) {
            Get-ProfileRow -Profile $dir.Name -LiveEpoch $liveEpoch -LiveRefresh $liveRefresh -Active $active
        })

    $detail = if ($live.SignedIn) {
        if ($liveProfile) { "signed in as $liveProfile" } else { 'signed in with an account no profile knows yet -- run harvest' }
    } elseif ($live.Status) {
        "auth-state.json says '$($live.Status)', which is not a signed-in state"
    } else {
        "no auth-state.json at $($ns.StateFile) -- MiniMax Code has never signed in to this data dir"
    }

    $livePart = @{}
    $livePart['signedIn'] = $live.SignedIn
    $livePart['status'] = if ($live.Status) { $live.Status } else { 'missing' }
    $livePart['generation'] = $live.Generation
    $livePart['email'] = $liveProfile
    $livePart['tokenFingerprint'] = if ($live.Credential) { Get-Fingerprint -Token ([string]$live.Credential['accessToken']) } else { $null }
    $livePart['expiresAt'] = $expiry['ExpiresAt']
    $livePart['expiresInSeconds'] = $expiry['ExpiresInSeconds']
    $livePart['expired'] = $expiry['Expired']
    $livePart['stateFile'] = $live.StateFile
    $livePart['credentialFile'] = $live.CredentialFile
    $livePart['records'] = $live.RecordCount
    $livePart['detail'] = $detail
    # who the unnamed sign-in belongs to. this is the one case where a status read
    # has to ask the api: the nickname is all MiniMax gives, and it is the same
    # string the app shows in its own corner, so it is enough to tell "which of my
    # accounts am I on right now" while the human types the address that names it.
    # a named live account never pays for this call.
    $livePart['displayName'] = $null
    $livePart['realUserID'] = $null
    $livePart['identityError'] = $null
    if ($live.SignedIn -and -not $liveProfile -and -not $expiry.Expired) {
        try {
            $liveIdentity = Resolve-MiniMaxIdentity -AccessToken ([string]$live.Credential['accessToken'])
            $livePart['displayName'] = $liveIdentity['userName']
            $livePart['realUserID'] = $liveIdentity['realUserID']
        } catch {
            $livePart['identityError'] = $_.Exception.Message
        }
    }

    $counts = @{}
    $counts['profiles'] = $profiles.Count
    $counts['signedIn'] = $live.SignedIn
    $counts['appRunning'] = $app['running']

    $report = @{}
    $report['ok'] = $true
    $report['tool'] = $tool
    $report['service'] = $serviceName
    $report['helper'] = (Join-Path $PSScriptRoot 'minimax-account.ps1')
    $report['accountRoot'] = $accountRoot
    $report['dataDir'] = $ns.DataDir
    $report['namespaceHome'] = $ns.NamespaceHome
    $report['buildEnv'] = $ns.BuildEnv
    $report['region'] = $ns.Region
    $report['clientId'] = $ns.ClientId
    $report['audience'] = $audience
    $report['scope'] = $defaultScope
    $report['deviceEndpoint'] = $ns.DeviceEndpoint
    $report['tokenEndpoint'] = $ns.TokenEndpoint
    $report['identityOrigin'] = $ns.IdentityOrigin
    $report['app'] = $app
    $report['active'] = $active
    $report['live'] = $livePart
    $report['profiles'] = $profiles
    $report['rebankedProfile'] = $rebanked
    $report['counts'] = $counts
    $report['checkedAt'] = [DateTimeOffset]::UtcNow.ToString('o')
    return $report
}

# ---- verbs -----------------------------------------------------------------

function Invoke-Harvest {
    param([AllowNull()][string]$Profile, [switch]$Quiet)

    $live = Get-LiveAuth
    if (-not $live.SignedIn) {
        throw "nothing is signed in to $($live.StateFile), so there is no credential to harvest. open MiniMax Code and sign in, or run .\minimax-account.ps1 login <email>."
    }

    # an expired access token gets a 401 from the profile lookup -- the account
    # is not signed out, its refresh token is still the thing we need to bank.
    # so the identity is opportunistic here and its absence is reported, never
    # hidden: the credential is saved either way.
    $identity = $null
    $identityError = $null
    try {
        $identity = Resolve-MiniMaxIdentity -AccessToken ([string]$live.Credential['accessToken'])
    } catch {
        $identityError = $_.Exception.Message
    }

    $email = if ($Profile) { Normalize-ProfileName -Profile $Profile } else { Find-ProfileForCredential -Credential $live.Credential }
    $emailSource = if ($Profile) { 'stated' } elseif ($email) { 'matched-credential' } else { $null }
    if (-not $email) {
        $resolved = Resolve-AccountEmail -IdentityEmail $identity['userEmail']
        $email = $resolved.Email
        $emailSource = $resolved.Source
    }
    if (-not $email) {
        $why = if ($identityError) { "and the profile lookup could not name it either -- $identityError" } else { "and MiniMax reports no account email for it (its display name is just a nickname: '$($identity['userName'])')" }
        throw "this sign-in matches no stored profile $why. profiles are keyed by email, so pass the address you signed in as: .\minimax-account.ps1 harvest you@example.com -- in the monitor that is accounts pool > minimax code: the email field + 'name this sign-in'."
    }

    $clash = Test-IdentityAnchorTaken -RealUserID $(if ($identity) { $identity['realUserID'] } else { $null }) -Email $email
    if ($clash) {
        $anchorId = if ($identity) { [string]$identity['realUserID'] } else { 'unknown' }
        throw "'$email' and '$clash' are the same MiniMax account (realUserID $anchorId). bank it once, under one address: .\minimax-account.ps1 forget $clash"
    }

    Write-ProfileRecord -Profile $email -Credential $live.Credential -Identity $identity -EmailSource $emailSource
    Set-ActiveProfile -Profile $email

    $expiry = Get-ExpiryFields -ExpiresAtMs ([long]$live.Credential['expiresAtMs'])
    $result = @{}
    $result['ok'] = $true
    $result['action'] = 'harvested'
    $result['profile'] = $email
    $result['displayName'] = if ($identity) { $identity['userName'] } else { $null }
    $result['realUserID'] = if ($identity) { $identity['realUserID'] } else { $null }
    $result['generation'] = [long]$live.Credential['generation']
    $result['expiresAt'] = $expiry['ExpiresAt']
    $result['identityError'] = $identityError
    $result['emailSource'] = $emailSource
    $result['message'] = if ($identityError) {
        "saved the live sign-in as $email without its identity: $identityError"
    } elseif ($emailSource -eq 'stated') {
        "saved the live sign-in as $email (named by you -- MiniMax reports no email for it)"
    } else {
        "saved the live sign-in as $email"
    }
    if (-not $Quiet) {
        Write-Host $result['message']
    }

    return $result
}

function Save-LiveCredentialOffline {
    param([AllowNull()][string]$Profile)

    # in-lock re-bank: no network, no identity lookup. it exists because the app
    # may refresh between the pre-lock harvest and the install, and that rotated
    # token would be discarded with the rest of the live record.
    $live = Get-LiveAuth
    if (-not $live.SignedIn) {
        return $null
    }

    $email = if ($Profile) { Normalize-ProfileName -Profile $Profile } else { Find-ProfileForCredential -Credential $live.Credential }
    if (-not $email) {
        return $null
    }

    Write-ProfileRecord -Profile $email -Credential $live.Credential -Identity $null
    return $email
}

function Invoke-Use {
    param([string]$Profile)

    $normalized = Normalize-ProfileName -Profile $Profile
    $stored = Read-ProfileCredential -Profile $normalized
    if (-not $stored) {
        throw "profile '$normalized' has no credential.json. run .\minimax-account.ps1 login $normalized (or harvest while that account is the one signed in)."
    }

    # bank the live sign-in BEFORE anything can rotate it (network here, so it
    # stays outside the lock); then renew the target; then take the lock only for
    # the two atomic writes, re-banking offline if the app moved in between.
    $banked = $true
    $bankNote = $null
    $before = Get-LiveAuth
    $liveOwner = if ($before.SignedIn) { Find-ProfileForCredential -Credential $before.Credential } else { $null }
    if ($before.SignedIn -and $liveOwner -ne $normalized) {
        try {
            [void](Invoke-Harvest -Profile $liveOwner -Quiet)
        } catch {
            if (-not $liveOwner) {
                # nobody owns the live sign-in, so this is the ONLY copy of that
                # chain: switching away spends its refresh token and the account
                # comes back only through a new browser sign-in. naming it is one
                # argument, so refuse instead of trading it for this switch.
                throw "$($_.Exception.Message) -- switch refused: the sign-in MiniMax Code is holding is not banked under any profile, and switching away spends its refresh chain for good. give it the address you signed in as (.\minimax-account.ps1 harvest <email>, or the monitor's 'name this sign-in' button under accounts pool > minimax code), or discard it with .\minimax-account.ps1 logout -- then switch."
            }
            $banked = $false
            $bankNote = $_.Exception.Message
            Write-Host "could not bank the live sign-in before switching: $bankNote" -ForegroundColor Yellow
        }
    }

    # same account, already live: the live record owns this grant's current
    # refresh token, so it is used as-is instead of the stored copy. rotating the
    # stored sibling burns the whole chain -- MiniMax answers "this refresh token
    # can no longer be used" for BOTH of them.
    $sameAccountLive = [bool]($before.SignedIn -and $liveOwner -eq $normalized)
    $target = if ($sameAccountLive) { $before.Credential } else { $stored }
    $refreshed = $false
    $expiry = Get-ExpiryFields -ExpiresAtMs ([long]$target['expiresAtMs'])
    $needsRenewal = [bool]($null -eq $expiry['ExpiresInSeconds'] -or $expiry['ExpiresInSeconds'] -lt $refreshMarginSec)
    if ($needsRenewal -and -not $sameAccountLive) {
        Write-Host "the stored token for $normalized has no usable time left, refreshing it through the token endpoint first" -ForegroundColor DarkGray
        try {
            $target = Invoke-RefreshGrant -Credential $stored -Label $normalized
        } catch {
            $dead = $_.Exception.Message -match 'invalid_grant'
            if ($dead) {
                Set-ProfileGrantDead -Profile $normalized -Reason $_.Exception.Message
            }
            $hint = if ($dead) {
                " that stored chain is spent and cannot be revived: .\minimax-account.ps1 login $normalized"
            } elseif ($liveOwner -eq $normalized) {
                " if the app renewed this account while it was live, that token is the newest one: .\minimax-account.ps1 harvest $normalized, then retry."
            } else {
                ''
            }
            throw "$($_.Exception.Message)$hint"
        }
        $refreshed = $true
        Write-ProfileRecord -Profile $normalized -Credential $target -Identity $null
    } elseif ($needsRenewal) {
        # the live copy is expired and we are about to install it anyway: the app
        # re-reads auth-state.json every 250ms and refreshes on its own, so this
        # helper must not race it for the grant.
        Write-Host "$normalized is already the live sign-in and its access token is expired: installing it as it is. MiniMax Code re-reads auth-state.json every 250ms and renews the token itself." -ForegroundColor Yellow
    }

    $lock = $null
    try {
        $lock = Enter-AuthLock -LockFile (Get-MiniMaxNamespace).LockFile
        $live = Get-LiveAuth
        if ($live.SignedIn) {
            $currentOwner = Find-ProfileForCredential -Credential $live.Credential
            if ($currentOwner -ne $normalized) {
                [void](Save-LiveCredentialOffline -Profile $currentOwner)
            }
        }

        $installed = Install-LiveCredential -Credential $target -ExistingGeneration ([long]$live.Generation)
        Set-ActiveProfile -Profile $normalized
    } finally {
        Exit-AuthLock -Dir $lock
    }

    # the app re-reads auth-state.json every 250ms, so the switch is live for it
    # as soon as both files land. the only observable proof that a RUNNING app
    # consumed it is the app's own refresh: same loginEpoch, newer generation.
    $app = Get-AppProcessReport
    $settled = if ($app['running']) { Start-Sleep -Milliseconds 1500; Get-LiveAuth } else { $null }
    $consumed = [bool]($installed.AppRewroteIt -or
        ($null -ne $settled -and $settled.SignedIn -and [long]$settled.Generation -gt [long]$installed.Generation))
    $holds = [bool]($null -eq $settled -or
        ($settled.SignedIn -and [string]$settled.Credential['loginEpoch'] -eq [string]$installed.LoginEpoch))

    $message = if (-not $app['running']) {
        "signed in as $normalized; MiniMax Code is not running, so its next launch starts on that account."
    } elseif ($consumed) {
        "switched to ${normalized}: the running app took it and renewed the token itself (generation $([long]$settled.Generation))."
    } elseif ($holds) {
        "switched to ${normalized}: the live files hold that account and MiniMax Code re-reads them every 250ms."
    } else {
        "switched to $normalized, but the live files now report a different sign-in -- read status before trusting the app."
    }

    $result = @{}
    $result['ok'] = $true
    $result['action'] = 'switched'
    $result['profile'] = $normalized
    $result['refreshedBeforeSwitch'] = $refreshed
    $result['alreadyLive'] = $sameAccountLive
    $result['generation'] = $installed.Generation
    $result['expiresAt'] = (Get-ExpiryFields -ExpiresAtMs $installed.ExpiresAtMs)['ExpiresAt']
    $result['stateFile'] = $installed.Namespace.StateFile
    $result['credentialFile'] = $installed.Namespace.CredentialFile
    $result['appRunning'] = $app['running']
    $result['appPickedUp'] = $consumed
    $result['liveMatchesInstall'] = $holds
    $result['liveGeneration'] = if ($null -ne $settled) { [long]$settled.Generation } else { $null }
    $result['bankedPreviousAccount'] = $banked
    $result['bankError'] = $bankNote
    $result['message'] = $message
    return $result
}

function Write-LoginPhase {
    param(
        [string]$Phase,
        [string]$Message,
        [AllowNull()][string]$Code = $null,
        [AllowNull()][string]$Url = $null,
        [AllowNull()][string]$Email = $null
    )

    # the monitor's opt-in progress channel (MINIMAX_ACCOUNT_STATE, set by the api
    # when it launches this helper). a plain terminal run has no state dir and
    # needs none -- the console already shows the same thing.
    $dir = Get-EnvText 'MINIMAX_ACCOUNT_STATE' ''
    if ([string]::IsNullOrWhiteSpace($dir)) {
        return
    }

    if (-not (Test-Path -LiteralPath $dir)) {
        [void](New-Item -ItemType Directory -Path $dir -Force)
    }

    # NOTE: powershell variables are case-insensitive, so the entry is not named
    # "$phase" -- that name already belongs to the -Phase parameter.
    $entry = @{}
    $entry['phase'] = $Phase
    $entry['message'] = $Message
    $entry['code'] = $Code
    $entry['url'] = $Url
    $entry['email'] = $Email
    $entry['updatedAt'] = [DateTimeOffset]::UtcNow.ToString('o')
    Write-JsonFile -Path (Join-Path $dir 'minimax-login-request.json') -Value $entry -Label 'login phase'
}

function Invoke-Login {
    param([AllowNull()][string]$Profile)

    # the email may be stated up front, which is the best case (the profile is
    # named before any grant exists), or left out entirely: then the sign-in goes
    # live UNNAMED and `harvest <email>` names it a moment later. MiniMax reports
    # no email of its own for social sign-ins, so somebody has to say it either
    # way -- leaving it out only moves when the asking happens.
    $stated = if ([string]::IsNullOrWhiteSpace($Profile)) { $null } else { Normalize-ProfileName -Profile $Profile }

    # bank the current sign-in before the app replaces it, so nothing is lost.
    $live = Get-LiveAuth
    $bankNote = $null
    if ($live.SignedIn) {
        try {
            [void](Invoke-Harvest -Quiet)
        } catch {
            $bankNote = $_.Exception.Message
            Write-Host "could not bank the live sign-in before logging in: $bankNote" -ForegroundColor Yellow
        }
    }

    $authorization = Start-DeviceAuthorization
    $url = if ($authorization['VerificationUriComplete']) { $authorization['VerificationUriComplete'] } else { $authorization['VerificationUri'] }
    Write-Host ''
    Write-Host 'Sign in to MiniMax in your browser:' -ForegroundColor Cyan
    Write-Host "  $url"
    Write-Host "  user code: $($authorization['UserCode'])"
    Write-Host "waiting up to $($authorization['ExpiresInSec'])s for the approval..."
    # if the previous sign-in could not be banked, the user has to see that
    # BEFORE approving: approving destroys that account's refresh chain and the
    # only way back in is a fresh sign-in.
    $waitingMessage = if ($stated) { "waiting for the browser approval, to be saved as $stated" } else { 'waiting for the browser approval with no email given: the sign-in will go live unnamed and must be saved with harvest <email>' }
    if ($bankNote) {
        $waitingMessage = "$waitingMessage -- WARNING: the account signed in right now was NOT banked ($bankNote). approving this code replaces its refresh chain, so that account will need a new sign-in before it can be switched to again."
    }
    Write-LoginPhase -Phase 'waiting' -Message $waitingMessage -Code ([string]$authorization['UserCode']) -Url $url -Email $stated
    try {
        Start-Process $url | Out-Null
    } catch {
        Write-Warning "could not open the browser automatically ($($_.Exception.Message)); open the url above by hand."
    }

    try {
        $grant = Wait-DeviceToken -Authorization $authorization
    } catch {
        Write-LoginPhase -Phase 'failed' -Message $_.Exception.Message -Code ([string]$authorization['UserCode']) -Url $url
        throw
    }
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $credential = New-Credential -AccessToken $grant.AccessToken -RefreshToken $grant.RefreshToken `
        -ExpiresAtMs ($now + ([int]$grant.ExpiresInSec * 1000)) -Generation 0 -LoginEpoch $null

    $identity = Resolve-MiniMaxIdentity -AccessToken $grant.AccessToken
    $resolved = Resolve-AccountEmail -IdentityEmail $identity['userEmail'] -StatedEmail $stated
    $email = $resolved.Email
    if ($stated -and $identity['userEmail'] -and ($email -ne $stated)) {
        # MiniMax named a different account than the one that was stated: the
        # approval went to the wrong person, and banking it under the asked-for
        # name would put one account's quota behind another's label.
        $mismatch = "you approved this as '$stated' but MiniMax says the sign-in belongs to '$email'. nothing was saved; run login again with the address you actually approved."
        Write-LoginPhase -Phase 'failed' -Message $mismatch -Code ([string]$authorization['UserCode']) -Url $url -Email $email
        throw $mismatch
    }

    if (-not $email) {
        # no stated address and MiniMax named none: the sign-in is real but a
        # profile needs an email, so nothing is banked. the chain head sits in the
        # app's own files, which is exactly what harvest reads -- naming it is one
        # command, and until then the caller (the monitor panel) keeps asking.
        $installed = Install-LiveCredential -Credential $credential -ExistingGeneration ([long]$live.Generation)
        $unnamed = "signed in as '$($identity['userName'])' (realUserID $($identity['realUserID'])) but NOTHING was banked: this account has no email yet, so its refresh chain lives only in MiniMax Code. name it now: .\minimax-account.ps1 harvest <the address you approved>, which in the monitor is accounts pool > minimax code: the field + 'name this sign-in' button. until it is named, switching away from it spends this chain for good."
        Write-LoginPhase -Phase 'needs-name' -Message $unnamed -Code ([string]$authorization['UserCode']) -Url $url
        $result = @{}
        $result['ok'] = $true
        $result['action'] = 'logged-in-unnamed'
        $result['profile'] = $null
        $result['needsName'] = $true
        $result['displayName'] = $identity['userName']
        $result['realUserID'] = $identity['realUserID']
        $result['userCode'] = $authorization['UserCode']
        $result['generation'] = $installed.Generation
        $result['expiresAt'] = (Get-ExpiryFields -ExpiresAtMs $installed.ExpiresAtMs)['ExpiresAt']
        $result['bankError'] = $bankNote
        $result['message'] = $unnamed
        $result['emailSource'] = $null
        return $result
    }

    $clash = Test-IdentityAnchorTaken -RealUserID $identity['realUserID'] -Email $email
    if ($clash) {
        $conflict = "'$email' and '$clash' are the same MiniMax account (realUserID $($identity['realUserID'])). nothing was saved; bank it once under one address."
        Write-LoginPhase -Phase 'failed' -Message $conflict -Code ([string]$authorization['UserCode']) -Url $url -Email $email
        throw $conflict
    }

    $sourceNote = if ($resolved.Source -eq 'minimax') { 'MiniMax named this account' } else { 'named by you at login -- MiniMax reports no email for it' }
    Write-ProfileRecord -Profile $email -Credential $credential -Identity $identity -EmailSource $resolved.Source
    $installed = Install-LiveCredential -Credential $credential -ExistingGeneration ([long]$live.Generation)
    Set-ActiveProfile -Profile $email
    Write-LoginPhase -Phase 'authorized' -Message "signed in and saved as $email ($sourceNote)" -Code ([string]$authorization['UserCode']) -Url $url -Email $email

    $result = @{}
    $result['ok'] = $true
    $result['action'] = 'logged-in'
    $result['profile'] = $email
    $result['displayName'] = $identity['userName']
    $result['realUserID'] = $identity['realUserID']
    $result['userCode'] = $authorization['UserCode']
    $result['generation'] = $installed.Generation
    $result['expiresAt'] = (Get-ExpiryFields -ExpiresAtMs $installed.ExpiresAtMs)['ExpiresAt']
    $result['bankError'] = $bankNote
    $result['message'] = "signed in and saved as $email ($sourceNote)"
    $result['emailSource'] = $resolved.Source
    return $result
}

function Invoke-Refresh {
    param([AllowNull()][string]$Profile)

    $normalized = Get-ProfileOrActive -Profile $Profile
    $stored = Read-ProfileCredential -Profile $normalized
    if (-not $stored) {
        throw "profile '$normalized' has no credential.json to refresh."
    }

    # one grant, one holder at a time: while the app runs that account it owns
    # the current refresh token, and a second rotation from the stored sibling
    # makes MiniMax revoke the whole chain.
    $app = Get-AppProcessReport
    $live = Get-LiveAuth
    $liveOwner = if ($live.SignedIn) { Find-ProfileForCredential -Credential $live.Credential } else { $null }
    if ($liveOwner -eq $normalized -and $app['running']) {
        throw "refresh: $normalized is the sign-in MiniMax Code is running right now, and the app renews that grant itself. rotating the stored copy here would race it and revoke both tokens -- bank the live one instead: .\minimax-account.ps1 harvest $normalized"
    }

    try {
        $fresh = Invoke-RefreshGrant -Credential $stored -Label $normalized
    } catch {
        # invalid_grant is MiniMax's "this refresh token can no longer be used":
        # the chain is spent, so the profile is only good for a fresh sign-in.
        if ($_.Exception.Message -match 'invalid_grant') {
            Set-ProfileGrantDead -Profile $normalized -Reason $_.Exception.Message
        }
        throw
    }
    Write-ProfileRecord -Profile $normalized -Credential $fresh -Identity $null

    $installedLive = [bool]($live.SignedIn -and [string]$live.Credential['loginEpoch'] -eq [string]$stored['loginEpoch'])
    if ($installedLive) {
        $lock = $null
        try {
            $lock = Enter-AuthLock -LockFile (Get-MiniMaxNamespace).LockFile
            [void](Install-LiveCredential -Credential $fresh -ExistingGeneration ([long]$live.Credential['generation']))
        } finally {
            Exit-AuthLock -Dir $lock
        }
    }

    $result = @{}
    $result['ok'] = $true
    $result['action'] = 'refreshed'
    $result['profile'] = $normalized
    $result['installedLive'] = $installedLive
    $result['expiresAt'] = (Get-ExpiryFields -ExpiresAtMs ([long]$fresh['expiresAtMs']))['ExpiresAt']
    $result['message'] = if ($installedLive) { "renewed $normalized and put the new token live." } else { "renewed $normalized in the profile store." }
    return $result
}

# MiniMax rotates the refresh token on every renewal, and the RUNNING app rotates
# the live account's chain hourly. That leaves every OTHER profile frozen at the
# token it held when it was last banked, and an idle chain that is never rotated
# eventually answers invalid_grant -- the profile goes grant-dead, and only a
# fresh browser sign-in brings it back. keepalive is the missing half of "keep the
# pool forever": it walks every profile and rotates the ones the running app is
# NOT holding, so each chain keeps rolling whether or not it is the active one.
#
# The live account is skipped on purpose while the app runs -- the app owns that
# grant and a second rotation from here would revoke the pair (the same guard
# Invoke-Refresh already enforces). A grant-dead or credential-less profile is not
# retried: it needs a sign-in, so it is reported loudly and the verb exits nonzero.
function Invoke-Keepalive {
    $report = Get-StatusReport
    $appRunning = [bool]$report['app']['running']
    $liveEmail = [string]$report['live']['email']

    $rows = @()
    $rotated = 0
    $skipped = 0
    $failed = 0

    foreach ($profile in @($report['profiles'])) {
        $email = [string]$profile['email']
        $entry = @{}
        $entry['email'] = $email

        if ($profile['grantDead']) {
            $entry['action'] = 'needs-sign-in'
            $entry['detail'] = if ($profile['grantDeadReason']) { [string]$profile['grantDeadReason'] } else { 'MiniMax refused the stored chain' }
            $failed += 1
            $rows += $entry
            continue
        }

        if (($profile['state'] -eq 'missing-credential') -or -not (Read-ProfileCredential -Profile $email)) {
            $entry['action'] = 'needs-sign-in'
            $entry['detail'] = 'no credential.json for this address -- run login for it'
            $failed += 1
            $rows += $entry
            continue
        }

        if ($appRunning -and $profile['isLive']) {
            $entry['action'] = 'skipped'
            $entry['detail'] = 'this is the sign-in MiniMax Code is running; the app rotates that chain itself'
            $skipped += 1
            $rows += $entry
            continue
        }

        try {
            $result = Invoke-Refresh -Profile $email
            $entry['action'] = 'rotated'
            $entry['expiresAt'] = $result['expiresAt']
            $entry['installedLive'] = $result['installedLive']
            $rotated += 1
        } catch {
            # one spent chain must not stop the rotation of the others: record it,
            # keep going, and let the count decide the verb's exit code.
            $entry['action'] = if ($_.Exception.Message -match 'invalid_grant') { 'needs-sign-in' } else { 'failed' }
            $entry['detail'] = $_.Exception.Message
            $failed += 1
        }
        $rows += $entry
    }

    $needsSignIn = @($rows | Where-Object { $_['action'] -eq 'needs-sign-in' } | ForEach-Object { [string]$_['email'] })
    $lines = @("rotated $rotated, skipped $skipped, failed $failed (of $($rows.Count) profile(s))")
    if ($needsSignIn.Count -gt 0) {
        $lines += "needs a fresh browser sign-in: $($needsSignIn -join ', ')"
    }

    $payload = @{}
    $payload['ok'] = [bool]($failed -eq 0)
    $payload['action'] = 'keepalive'
    $payload['rotated'] = $rotated
    $payload['skipped'] = $skipped
    $payload['failed'] = $failed
    $payload['needsSignIn'] = $needsSignIn
    $payload['live'] = $liveEmail
    $payload['appRunning'] = $appRunning
    $payload['profiles'] = $rows
    $payload['rebankedProfile'] = $report['rebankedProfile']
    $payload['checkedAt'] = [DateTimeOffset]::UtcNow.ToString('o')
    $payload['message'] = ($lines -join '; ')
    return $payload
}

function Invoke-Logout {
    param([AllowNull()][string]$Profile)

    $live = Get-LiveAuth
    if (-not $live.SignedIn) {
        $idle = @{}
        $idle['ok'] = $true
        $idle['action'] = 'already-signed-out'
        $idle['profile'] = $Profile
        $idle['message'] = "nothing is signed in to $($live.StateFile)."
        return $idle
    }

    $owner = Find-ProfileForCredential -Credential $live.Credential
    $lock = $null
    $ns = Get-MiniMaxNamespace
    try {
        $lock = Enter-AuthLock -LockFile $ns.LockFile
        [void](Invoke-Harvest -Quiet)
        Invoke-RevokeGrant -RefreshToken ([string]$live.Credential['refreshToken'])

        # drop only this namespace's record: an unknown second record means the
        # data dir holds more than one account, which this helper does not model.
        $records = @{}
        $payload = Read-JsonFile -Path $ns.CredentialFile -Label 'auth.json'
        if ($payload -and $payload['records'] -is [hashtable]) {
            foreach ($key in @($payload['records'].Keys)) {
                if ($key -ne $ns.RecordKey) {
                    $records[$key] = $payload['records'][$key]
                }
            }
        }
        $newPayload = @{}
        $newPayload['schemaVersion'] = 1
        $newPayload['records'] = $records
        Write-JsonFile -Path $ns.CredentialFile -Value $newPayload -Label 'auth.json'

        $signedOut = @{}
        $signedOut['schemaVersion'] = $authStateSchemaVersion
        $signedOut['status'] = 'anonymous'
        $signedOut['storeKind'] = 'file'
        $signedOut['clientId'] = $clientId
        $signedOut['scopes'] = @($defaultScope)
        $signedOut['audience'] = $audience
        $signedOut['buildEnv'] = $ns.BuildEnv
        $signedOut['region'] = $ns.Region
        $signedOut['generation'] = [Math]::Max($live.Generation, [long]$live.Credential['generation']) + 1
        Write-JsonFile -Path $ns.StateFile -Value $signedOut -Label 'auth-state.json'
        Remove-Item -LiteralPath $ns.RefreshStagingFile -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Join-Path $ns.DataDir 'local-runtime.auth.json') -Force -ErrorAction SilentlyContinue
    } finally {
        Exit-AuthLock -Dir $lock
    }

    if (Test-Path -LiteralPath $currentFile) {
        Remove-Item -LiteralPath $currentFile -Force
    }

    $kept = if ($owner) { " the stored profile $owner keeps its own token, so use can sign back in." } else { '' }
    $result = @{}
    $result['ok'] = $true
    $result['action'] = 'logged-out'
    $result['profile'] = $owner
    $result['message'] = "revoked the live refresh token and cleared the sign-in from $ns.StateFile.$kept"
    return $result
}

function Invoke-Forget {
    param([string]$Profile)

    $normalized = Normalize-ProfileName -Profile $Profile
    $path = Get-ProfilePath -Profile $normalized
    $result = @{}
    $result['ok'] = $true
    $result['profile'] = $normalized

    if (-not (Test-Path -LiteralPath $path)) {
        $result['action'] = 'nothing-to-forget'
        $result['message'] = "no stored profile for $normalized."
        return $result
    }

    $backup = "$path.logged-out-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Move-Item -LiteralPath $path -Destination $backup
    if ((Get-ActiveProfile) -eq $normalized -and (Test-Path -LiteralPath $currentFile)) {
        Remove-Item -LiteralPath $currentFile -Force
    }

    $result['action'] = 'forgot'
    $result['movedTo'] = $backup
    $result['message'] = "moved the stored profile aside to $backup (the live sign-in was not touched)."
    return $result
}

function Invoke-Run {
    param([AllowNull()][string]$Profile, [string[]]$Arguments)

    $launcher = [Environment]::GetEnvironmentVariable('MCODE_TOOLS_LAUNCHER')
    if ([string]::IsNullOrWhiteSpace($launcher)) {
        $candidate = Join-Path (Get-DataDir) 'bin\mcode-tools.cmd'
        if (Test-Path -LiteralPath $candidate) {
            $launcher = $candidate
        }
    }
    if ([string]::IsNullOrWhiteSpace($launcher) -or -not (Test-Path -LiteralPath $launcher)) {
        throw "the mcode-tools launcher was not found. checked MCODE_TOOLS_LAUNCHER and $(Join-Path (Get-DataDir) 'bin\mcode-tools.cmd') -- MiniMax Code writes it into its data dir on first run."
    }

    $live = Get-LiveAuth
    $owner = if ($live.SignedIn) { Find-ProfileForCredential -Credential $live.Credential } else { $null }
    if ($Profile -and $Profile -ne $owner) {
        Write-Host "making $Profile the live MiniMax sign-in first" -ForegroundColor DarkGray
        [void](Invoke-Use -Profile $Profile)
    }
    if (-not $Profile -and -not $owner) {
        throw 'no profile matches the live sign-in and none was given. run .\minimax-account.ps1 use <email> first.'
    }

    & $launcher @Arguments
    $code = $LASTEXITCODE

    $result = @{}
    $result['ok'] = ($code -eq 0)
    $result['action'] = 'ran'
    $result['launcher'] = $launcher
    $result['profile'] = if ($Profile) { $Profile } else { $owner }
    $result['exitCode'] = $code
    $result['message'] = "ran $(Split-Path -Leaf $launcher) as $($result['profile']) with exit code $code"
    return $result
}

function Show-Env {
    param([AllowNull()][string]$Profile)

    $normalized = Get-ProfileOrActive -Profile $Profile
    $ns = Get-MiniMaxNamespace
    Write-Host "`$env:MINIMAX_DATA_DIR = '$($ns.DataDir)'"
    Write-Host "`$env:MCODE_REGION = '$($ns.Region)'"
    Write-Host "`$env:MCODE_BUILD_ENV = '$($ns.BuildEnv)'"
    Write-Host "`$env:MCODE_CONFIG_DIR = '$(Join-Path $ns.DataDir "integrations\mcode-tools\$($ns.Region)")'"
    Write-Host "`$env:MCODE_AUTH_PROVIDER = 'shared-broker' (MiniMax Code has to be running: the CLI reads its auth lease)"
    Write-Host "`$env:MCODE_CLIENT_ID = '$clientId'"
    Write-Host "`$env:MCODE_SCOPE = '$defaultScope'"
    Write-Host "profile = '$normalized'"
    Write-Host "credential = $(Join-Path (Get-ProfilePath -Profile $normalized) 'credential.json')"
    Write-Host 'tokens stay in that profile folder -- never in the environment.'
}

# ---- entry -----------------------------------------------------------------

$argv = @()
$useJson = $false
foreach ($item in @($args)) {
    $text = [string]$item
    if ($text -eq '-Json' -or $text -eq '--json') {
        $useJson = $true
        continue
    }
    $argv += $text
}

$command = if ($argv.Count -gt 0) { $argv[0].ToLowerInvariant() } else { 'help' }
$remaining = @($argv | Select-Object -Skip 1)

function Emit {
    param(
        $Payload,
        [scriptblock]$Human
    )

    if ($script:useJson) {
        ConvertTo-Json -InputObject $Payload -Depth 14 | Write-Output
        return
    }

    & $Human
}

switch ($command) {
    'help' {
        Show-Usage
    }

    'login' {
        # no email is the "sign in unnamed, name it with harvest later" path; a
        # NON-email is a typo and has to fail, not quietly become an unnamed
        # sign-in that burns a device code.
        $profile = if ($remaining.Count -ge 1) { $remaining[0] } else { $null }
        $result = Invoke-Login -Profile $profile
        Emit -Payload $result -Human {
            if ($result.needsName) {
                Write-Host "Signed in to MiniMax Code with no name on it." -ForegroundColor Yellow
                Write-Host "  display name: $($result.displayName) (realUserID $($result.realUserID))"
                Write-Host "  token expires: $($result.expiresAt)"
                Write-Host "  nothing was banked -- name it now:" -ForegroundColor Yellow
                Write-Host "    .\minimax-account.ps1 harvest you@example.com"
            } else {
                Write-Host "Signed in to MiniMax Code as: $($result.profile)"
                Write-Host "  display name: $($result.displayName)"
                Write-Host "  token expires: $($result.expiresAt)"
                Write-Host "  named by: $($result.emailSource)"
            }
        }
    }

    'harvest' {
        $profile = if ($remaining.Count -ge 1) { $remaining[0] } else { $null }
        $result = Invoke-Harvest -Profile $profile
        Emit -Payload $result -Human {
            Write-Host "Saved the live sign-in as: $($result.profile)"
            Write-Host "  token expires: $($result.expiresAt)"
            Write-Host "  named by: $($result.emailSource)"
        }
    }

    'use' {
        if ($remaining.Count -ne 1) {
            throw 'Usage: .\minimax-account.ps1 use <email>'
        }

        $result = Invoke-Use -Profile $remaining[0]
        Emit -Payload $result -Human {
            Write-Host $result.message
            Write-Host "  generation: $($result.generation) - token expires: $($result.expiresAt)"
        }
    }

    'refresh' {
        $profile = if ($remaining.Count -ge 1) { $remaining[0] } else { $null }
        $result = Invoke-Refresh -Profile $profile
        Emit -Payload $result -Human { Write-Host $result.message }
    }

    'keepalive' {
        $result = Invoke-Keepalive
        Emit -Payload $result -Human {
            Write-Host $result['message']
            foreach ($row in $result['profiles']) {
                $tone = switch ($row['action']) { 'rotated' { 'Green' } 'skipped' { 'DarkGray' } default { 'Red' } }
                $suffix = if ($row['detail']) { " -- $($row['detail'])" } else { '' }
                Write-Host ("  {0,-14} {1}{2}" -f $row['action'], $row['email'], $suffix) -ForegroundColor $tone
            }
        }
        if (-not $result['ok']) { exit 1 }
    }

    'run' {
        if ($remaining.Count -eq 0) {
            throw 'Usage: .\minimax-account.ps1 run [email] <mcode args...>'
        }

        $profile = $null
        $arguments = @($remaining)
        if (Test-LooksLikeEmail -Value $remaining[0]) {
            $profile = Normalize-ProfileName -Profile $remaining[0]
            $arguments = @($remaining | Select-Object -Skip 1)
        }

        $result = Invoke-Run -Profile $profile -Arguments $arguments
        Emit -Payload $result -Human { Write-Host $result.message }
        if (-not $result.ok) {
            exit $result.exitCode
        }
    }

    'status' {
        $profile = Get-ProfileOrActive -Profile $(if ($remaining.Count -ge 1) { $remaining[0] } else { $null })
        $report = Get-StatusReport
        $row = @($report['profiles'] | Where-Object { $_['email'] -eq $profile }) | Select-Object -First 1
        if (-not $row) {
            $row = Get-ProfileRow -Profile $profile -LiveEpoch $null -LiveRefresh $null -Active $report['active']
        }

        $payload = @{}
        $payload['ok'] = $true
        $payload['action'] = 'status'
        $payload['report'] = $report
        $payload['profile'] = $row
        Emit -Payload $payload -Human {
            foreach ($key in (@($row.Keys) | Sort-Object)) {
                Write-Host ('  {0,-18} {1}' -f $key, $row[$key])
            }
            Write-Host ''
            Write-Host "live: $($report['live']['detail'])"
            Write-Host "state file: $($report['live']['stateFile'])"
            Write-Host "app: $(if ($report['app']['running']) { "running ($($report['app']['windows']) windows)" } else { 'not running' })"
        }
    }

    'status-all' {
        $report = Get-StatusReport
        Emit -Payload $report -Human {
            if (@($report['profiles']).Count -eq 0) {
                Write-Host 'No MiniMax profiles found. Run .\minimax-account.ps1 harvest or login.'
                Write-Host "live: $($report['live']['detail'])"
                return
            }

            $report['profiles'] |
                Select-Object email, state, isActive, isLive, expiresInSeconds, tokenFingerprint, savedAt |
                Format-Table -AutoSize | Out-String | Write-Host
            Write-Host "live: $($report['live']['detail'])"
        }
    }

    'list' {
        $report = Get-StatusReport
        $payload = @{}
        $payload['ok'] = $true
        $payload['action'] = 'list'
        $payload['profiles'] = $report['profiles']
        $payload['active'] = $report['active']
        $payload['live'] = $report['live']
        Emit -Payload $payload -Human {
            if (@($report['profiles']).Count -eq 0) {
                Write-Host 'No MiniMax profiles found.'
                return
            }

            foreach ($row in $report['profiles']) {
                $marker = if ($row['isLive']) { '*' } elseif ($row['isActive']) { '+' } else { ' ' }
                Write-Host "$marker $($row['email'])  [$($row['state'])]"
            }
        }
    }

    'current' {
        $report = Get-StatusReport
        $active = $report['active']
        $liveEmail = $report['live']['email']
        $payload = @{}
        $payload['ok'] = $true
        $payload['action'] = 'current'
        $payload['profile'] = $active
        $payload['active'] = $active
        $payload['liveSignedIn'] = $report['live']['signedIn']
        $payload['liveEmail'] = $liveEmail
        $payload['liveDetail'] = $report['live']['detail']
        $payload['matchesLive'] = [bool]($active -and $liveEmail -and ($active -eq $liveEmail))
        Emit -Payload $payload -Human {
            if ($active) {
                Write-Host $active
            } else {
                Write-Host 'No active MiniMax email profile set.'
            }
            if (-not $payload['matchesLive']) {
                Write-Host "live: $($report['live']['detail'])" -ForegroundColor DarkGray
            }
        }
    }

    'path' {
        $profile = Get-ProfileOrActive -Profile $(if ($remaining.Count -ge 1) { $remaining[0] } else { $null })
        $folder = Get-ProfilePath -Profile $profile
        $payload = @{}
        $payload['ok'] = $true
        $payload['action'] = 'path'
        $payload['profile'] = $profile
        $payload['folder'] = $folder
        $payload['credentialFile'] = Join-Path $folder 'credential.json'
        Emit -Payload $payload -Human { Write-Host $folder }
    }

    'env' {
        $profile = if ($remaining.Count -ge 1) { $remaining[0] } else { $null }
        if ($useJson) {
            $normalized = Get-ProfileOrActive -Profile $profile
            $ns = Get-MiniMaxNamespace
            $folder = Get-ProfilePath -Profile $normalized
            $payload = @{}
            $payload['ok'] = $true
            $payload['action'] = 'env'
            $payload['profile'] = $normalized
            $payload['dataDir'] = $ns.DataDir
            $payload['region'] = $ns.Region
            $payload['buildEnv'] = $ns.BuildEnv
            $payload['clientId'] = $clientId
            $payload['scope'] = $defaultScope
            $payload['launcher'] = (Join-Path $ns.DataDir 'bin\mcode-tools.cmd')
            $payload['folder'] = $folder
            $payload['credentialFile'] = (Join-Path $folder 'credential.json')
            Emit -Payload $payload -Human { }
        } else {
            Show-Env -Profile $profile
        }
    }

    'logout' {
        $profile = if ($remaining.Count -ge 1) { $remaining[0] } else { $null }
        $result = Invoke-Logout -Profile $profile
        Emit -Payload $result -Human { Write-Host $result.message }
    }

    'forget' {
        if ($remaining.Count -ne 1) {
            throw 'Usage: .\minimax-account.ps1 forget <email>'
        }

        $result = Invoke-Forget -Profile $remaining[0]
        Emit -Payload $result -Human { Write-Host $result.message }
    }

    default {
        Show-Usage
        throw "Unknown command: $command"
    }
}
