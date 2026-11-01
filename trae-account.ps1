$ErrorActionPreference = 'Stop'

# Trae account profile helper.
#
# Trae is a VS Code fork. The whole signed-in session is ONE file --
# %USERPROFILE%\.trae\trae-jwt-token, a 933-byte RS256 JWT with a 7 day life --
# and the app owns it: TokenManager rewrites it on every sign-in and on every
# scheduled refresh. Nothing else on the machine holds the session: the auth
# object the renderer keeps in memory (refreshToken / refreshExpiredAt /
# tokenReleaseAt / loginScope) is never written to disk (it only reaches
# %APPDATA%\Trae\logs\...\main.log as a log line), and Trae's Local Storage
# leveldb holds no credential. So a Trae "account" is exactly one access token,
# and switching means: close Trae, write that account's token into the live
# file, relaunch. The restart IS the switch -- Trae reads the token once per
# launch.
#
# The token renews itself with no login. The auth service mints a new one from
# a live one, for the same account, and the new one can renew itself again:
#
#   POST https://growsg-normal.trae.ai/cloudide/api/v3/trae/GenerateTempToken
#   headers: x-cloudide-token: <the current token>
#   body:    {"IDEVersion": "<the installed Trae's file version>"}
#   -> Result.Token, Result.ExpiredAt
#
# GetUserInfo on the same host is how an account names itself; it is a pure
# read (it hands back no token) and it is the ONLY source of the email:
#
#   POST .../GetUserInfo   headers: same, body: same
#   -> Result.NonPlainTextEmail (the plain address, despite the name),
#      Result.UserID, Result.ScreenName, Result.LastLoginType, Result.TenantID
#
# The uid alone is not an address, and this pool is keyed by the account's own
# email only -- the same anchor rule the MiniMax (realUserID), ADCode and
# Firebase helpers use. A sign-in GetUserInfo cannot name is refused, never
# filed under a uid or a screen name.
#
# The uid is also in the token itself (data.user_id), which is what lets
# status/list work offline and what `use` verifies before it touches anything.
#
# WHY THIS IS NOT A CHAT-ACCOUNT SWITCHER: the hub authenticates requests by
# the signed-in credential, not by the uid a request claims -- a foreign live
# token answers 1001 and a mismatched pair answers 4015. Moving the live token
# is what makes the IDE *be* the other account (its own history, its own
# bucket, its own token file); it does not make one account's existing chat
# sessions drivable from the other. That is the fork route's job, and it is
# documented in trae.ai/AGENTS.md.
#
# Profiles are keyed by email only and stored in:
#   %APPDATA%\mainframe\accounts\trae\<email>
# Each profile holds two files, the same shape the live data uses:
#   token        the access token, one line, no trailing newline
#   profile.json uid / email / screen name / provider / expiry, for offline rows
#
# Usage:
#   .\trae-account.ps1 harvest [email]              bank the live sign-in (email verified)
#   .\trae-account.ps1 login [email]                same, for the contract: verify + bank
#   .\trae-account.ps1 use <email>                  close Trae, install the profile, reopen it
#   .\trae-account.ps1 refresh [email]              mint a fresh token for a stored profile
#   .\trae-account.ps1 open                         start Trae (for signing a profile in)
#   .\trae-account.ps1 run [email] [app args...]    switch, then launch Trae (optionally with args)
#   .\trae-account.ps1 list / current / status / status-all / path / env
#   .\trae-account.ps1 logout [email]               clear the LIVE token (Trae must be closed)
#   .\trae-account.ps1 forget <email>               move a stored profile aside
#   .\trae-account.ps1 status-all -Json             one json object, for the monitor api
#
# The live token file can be pointed elsewhere with TRAE_JWT_TOKEN_FILE, the
# profile store with TRAE_ACCOUNT_ROOT, the auth service with TRAE_AUTH_BASE and
# the reported build with TRAE_IDE_VERSION. TRAE_EXE overrides the executable.

$tool = 'trae'
$serviceName = 'Trae'

$authBaseDefault = 'https://growsg-normal.trae.ai/cloudide/api/v3/trae'
$httpTimeoutSec = 25
$closeWaitSec = 45
$launchWaitSec = 45

$accountRoot = if ([string]::IsNullOrWhiteSpace($env:TRAE_ACCOUNT_ROOT)) {
    Join-Path $env:APPDATA 'mainframe\accounts\trae'
} else {
    [IO.Path]::GetFullPath($env:TRAE_ACCOUNT_ROOT.Trim())
}
$currentFile = Join-Path $accountRoot 'current.json'
$liveCacheFile = Join-Path $accountRoot 'live-cache.json'

# the account's own state. token first: it is the thing that decides identity.
$tokenRelative = 'token'
$metadataRelative = 'profile.json'
$accountFiles = @($tokenRelative, $metadataRelative)

$authBase = if ([string]::IsNullOrWhiteSpace($env:TRAE_AUTH_BASE)) {
    $authBaseDefault
} else {
    $env:TRAE_AUTH_BASE.Trim().TrimEnd('/')
}

function Show-Usage {
    @(
        'Trae account profile helper',
        '',
        'Profiles are keyed by account email only and stored in:',
        '  %APPDATA%\mainframe\accounts\trae\<email>',
        '',
        'Usage:',
        '  .\trae-account.ps1 harvest [email]              bank the live sign-in (email verified)',
        '  .\trae-account.ps1 login [email]                verify + bank the live sign-in',
        '  .\trae-account.ps1 use <email>                  close Trae, install the profile, reopen it',
        '  .\trae-account.ps1 refresh [email]              mint a fresh token for a stored profile',
        '  .\trae-account.ps1 open                         start Trae',
        '  .\trae-account.ps1 run [email] [app args...]    switch, then launch Trae',
        '  .\trae-account.ps1 list',
        '  .\trae-account.ps1 current',
        '  .\trae-account.ps1 status [email]',
        '  .\trae-account.ps1 status-all',
        '  .\trae-account.ps1 path [email]',
        '  .\trae-account.ps1 env [email]',
        '  .\trae-account.ps1 logout [email]               clear the LIVE token (Trae must be closed)',
        '  .\trae-account.ps1 forget <email>               move a stored profile aside',
        '',
        'Add -Json to any command for a single machine-readable json object.',
        '',
        'Trae reads its session ONCE per launch, so "use" closes it, swaps the',
        'signed-in token and reopens it: the restart is the switch. A sign-in that',
        'GetUserInfo cannot name (no address) is never banked.',
        '',
        'Examples:',
        '  .\trae-account.ps1 harvest',
        '  .\trae-account.ps1 use someone@example.com',
        '  .\trae-account.ps1 status-all -Json'
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
        throw "Trae profile must be an account email, not a label or display name: $Profile"
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

# One Trae uid can only be one account. A second email for a uid the pool
# already holds is a mislabel, not a new account -- the same anchor rule the
# MiniMax helper uses with realUserID.
function Test-IdentityAnchorTaken {
    param(
        [AllowNull()][string]$Uid,
        [string]$Email
    )

    if ([string]::IsNullOrWhiteSpace($Uid)) {
        return $null
    }

    foreach ($directory in @(Get-ChildItem -LiteralPath $accountRoot -Directory -ErrorAction SilentlyContinue)) {
        $metadata = Get-ProfileMetadata -Profile $directory.Name
        if (-not $metadata) {
            continue
        }

        if (([string]$metadata['uid'] -eq $Uid) -and ([string]$metadata['email'] -ne $Email)) {
            return [string]$metadata['email']
        }
    }

    return $null
}

# ---- json + fingerprints ---------------------------------------------------

function Read-JsonFile {
    param(
        [string]$Path,
        [string]$Label
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    $raw = [IO.File]::ReadAllText($Path)
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $null
    }

    try {
        return $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "$Label at $Path is not valid json: $($_.Exception.Message)"
    }
}

function Write-JsonFile {
    param(
        [string]$Path,
        $Value,
        [string]$Label
    )

    $directory = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($directory)) {
        [void][IO.Directory]::CreateDirectory($directory)
    }

    $json = ConvertTo-Json -InputObject $Value -Depth 12
    $temporary = "$Path.tmp-$PID"
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($temporary, $json, $utf8)

    for ($attempt = 0; ; $attempt++) {
        try {
            Move-Item -LiteralPath $temporary -Destination $Path -Force
            return
        } catch {
            if ($attempt -ge 5) {
                Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
                throw "could not write $Label at $Path after 6 attempts: $($_.Exception.Message)"
            }
            Start-Sleep -Milliseconds (50 * [Math]::Pow(2, $attempt))
        }
    }
}

function Get-Sha256Hex {
    param([string]$Text)

    $bytes = [Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))
    return ([BitConverter]::ToString($bytes) -replace '-', '').ToLowerInvariant()
}

function Get-Fingerprint {
    param([AllowNull()][string]$Token)

    if ([string]::IsNullOrWhiteSpace($Token)) {
        return $null
    }

    return (Get-Sha256Hex -Text $Token).Substring(0, 12)
}

function Get-UidFingerprint {
    param([AllowNull()][string]$Uid)

    if ([string]::IsNullOrWhiteSpace($Uid)) {
        return $null
    }

    return (Get-Sha256Hex -Text $Uid).Substring(0, 10)
}

function Get-NowIso {
    return [DateTimeOffset]::UtcNow.ToString('o')
}

function Format-Iso {
    param([AllowNull()]$Value)

    if ([string]::IsNullOrWhiteSpace([string]$Value)) {
        return $null
    }

    try {
        return [DateTimeOffset]::Parse([string]$Value).ToUniversalTime().ToString('o').Replace('+00:00', 'Z')
    } catch {
        return $null
    }
}

# ---- the token itself ------------------------------------------------------

# the whole session: an RS256 JWT whose payload is
# {data{id,tenant_id,type,user_id},exp,iat,iss:"trae"}. uid and expiry are read
# straight off it, offline, which is what keeps list/status network-free.
function Get-TokenClaims {
    param([AllowNull()][string]$Token)

    if ([string]::IsNullOrWhiteSpace($Token)) {
        return $null
    }

    $parts = $Token.Split('.')
    if ($parts.Length -ne 3) {
        return $null
    }

    try {
        $payload = $parts[1].Replace('-', '+').Replace('_', '/')
        while ($payload.Length % 4 -ne 0) {
            $payload += '='
        }
        $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload))
        $claims = $json | ConvertFrom-Json -ErrorAction Stop
    } catch {
        return $null
    }

    $data = $claims.data
    $uid = if ($data) { [string]$data.user_id } else { '' }
    if ([string]::IsNullOrWhiteSpace($uid) -and $data) {
        $uid = [string]$data.id
    }

    $exp = 0
    if ($claims.exp) {
        $exp = [int64]$claims.exp
    }

    $parsed = @{}
    $parsed['Uid'] = if ([string]::IsNullOrWhiteSpace($uid)) { $null } else { $uid }
    $parsed['TenantId'] = if ($data) { [string]$data.tenant_id } else { $null }
    $parsed['ExpiresUnix'] = $exp
    $parsed['ExpiresAt'] = if ($exp -gt 0) { [DateTimeOffset]::FromUnixTimeSeconds($exp).ToUniversalTime().ToString('o').Replace('+00:00', 'Z') } else { $null }
    $parsed['Expired'] = [bool]($exp -gt 0 -and ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() -ge $exp))
    return $parsed
}

function Get-LiveTokenFile {
    if (-not [string]::IsNullOrWhiteSpace($env:TRAE_JWT_TOKEN_FILE)) {
        return [IO.Path]::GetFullPath($env:TRAE_JWT_TOKEN_FILE.Trim())
    }

    return Join-Path $env:USERPROFILE '.trae\trae-jwt-token'
}

# Trae rewrites this file in place while it runs, so a read is retried until it
# settles rather than parsed on the first shot.
function Get-LiveToken {
    $file = Get-LiveTokenFile
    if (-not (Test-Path -LiteralPath $file)) {
        return $null
    }

    $previous = $null
    for ($attempt = 0; $attempt -lt 6; $attempt++) {
        $raw = [IO.File]::ReadAllText($file)
        if (-not [string]::IsNullOrWhiteSpace($raw)) {
            $token = $raw.Trim()
            if ($null -ne $previous -and $token -eq $previous) {
                $claims = Get-TokenClaims -Token $token
                if ($claims -and $claims['Uid']) {
                    $identity = @{}
                    $identity['Uid'] = [string]$claims['Uid']
                    $identity['TenantId'] = $claims['TenantId']
                    $identity['Token'] = $token
                    $identity['File'] = $file
                    $identity['TokenFingerprint'] = Get-Fingerprint -Token $token
                    $identity['ExpiresAt'] = $claims['ExpiresAt']
                    $identity['Expired'] = $claims['Expired']
                    return $identity
                }
            }
            $previous = $token
        }
        Start-Sleep -Milliseconds 120
    }

    throw "the live Trae token at $file never settled into a readable JWT -- Trae is writing it right now; try again."
}

function Write-TokenFile {
    param(
        [string]$Path,
        [string]$Token
    )

    $directory = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($directory)) {
        [void][IO.Directory]::CreateDirectory($directory)
    }

    # byte-for-byte how Trae writes it: one line, no trailing newline, no BOM.
    $temporary = "$Path.tmp-$PID"
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($temporary, $Token, $utf8)

    for ($attempt = 0; ; $attempt++) {
        try {
            Move-Item -LiteralPath $temporary -Destination $Path -Force
            return
        } catch {
            if ($attempt -ge 5) {
                Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
                throw "could not write the token at $Path after 6 attempts: $($_.Exception.Message)"
            }
            Start-Sleep -Milliseconds (50 * [Math]::Pow(2, $attempt))
        }
    }
}

# ---- profile store ---------------------------------------------------------

function Get-ProfileToken {
    param([string]$Profile)

    $path = Join-Path (Get-ProfilePath -Profile $Profile) $tokenRelative
    if (-not (Test-Path -LiteralPath $path)) {
        return $null
    }

    $token = ([IO.File]::ReadAllText($path)).Trim()
    if ([string]::IsNullOrWhiteSpace($token)) {
        throw "the stored token for $Profile at $path is empty."
    }

    $claims = Get-TokenClaims -Token $token
    if (-not $claims -or -not $claims['Uid']) {
        throw "the stored token for $Profile at $path is not a readable Trae JWT."
    }

    $identity = @{}
    $identity['Uid'] = [string]$claims['Uid']
    $identity['TenantId'] = $claims['TenantId']
    $identity['Token'] = $token
    $identity['File'] = $path
    $identity['TokenFingerprint'] = Get-Fingerprint -Token $token
    $identity['ExpiresAt'] = $claims['ExpiresAt']
    $identity['Expired'] = $claims['Expired']
    return $identity
}

function Get-ProfileMetadata {
    param([string]$Profile)

    $path = Join-Path (Get-ProfilePath -Profile $Profile) $metadataRelative
    $parsed = Read-JsonFile -Path $path -Label "$Profile profile.json"
    if (-not $parsed) {
        return $null
    }

    $metadata = @{}
    $metadata['email'] = [string]$parsed.email
    $metadata['uid'] = [string]$parsed.uid
    $metadata['emailSource'] = [string]$parsed.emailSource
    $metadata['displayName'] = [string]$parsed.displayName
    $metadata['provider'] = [string]$parsed.provider
    $metadata['avatarUrl'] = [string]$parsed.avatarUrl
    $metadata['tenantId'] = [string]$parsed.tenantId
    $metadata['region'] = [string]$parsed.region
    $metadata['storeCountry'] = [string]$parsed.storeCountry
    $metadata['registerTime'] = [string]$parsed.registerTime
    $metadata['lastLoginTime'] = [string]$parsed.lastLoginTime
    $metadata['savedAt'] = [string]$parsed.savedAt
    $metadata['updatedAt'] = [string]$parsed.updatedAt
    $metadata['switchedAt'] = [string]$parsed.switchedAt
    $metadata['refreshedAt'] = [string]$parsed.refreshedAt
    $metadata['tokenDead'] = [bool]$parsed.tokenDead
    $metadata['tokenDeadReason'] = [string]$parsed.tokenDeadReason
    $metadata['tokenCheckedAt'] = [string]$parsed.tokenCheckedAt
    $metadata['tokenFingerprint'] = [string]$parsed.tokenFingerprint
    return $metadata
}

function Write-ProfileMetadata {
    param([string]$Profile, $Metadata)

    $path = Join-Path (Get-ProfilePath -Profile $Profile) $metadataRelative
    $optional = @(
        'displayName', 'avatarUrl', 'tenantId', 'region', 'storeCountry',
        'registerTime', 'lastLoginTime', 'switchedAt', 'refreshedAt',
        'tokenDeadReason', 'tokenCheckedAt'
    )
    $value = @{}
    $value['email'] = [string]$Metadata['email']
    $value['uid'] = [string]$Metadata['uid']
    $value['emailSource'] = [string]$Metadata['emailSource']
    foreach ($key in $optional) {
        $value[$key] = if ([string]::IsNullOrWhiteSpace([string]$Metadata[$key])) { $null } else { [string]$Metadata[$key] }
    }
    $value['provider'] = [string]$Metadata['provider']
    $value['savedAt'] = [string]$Metadata['savedAt']
    $value['updatedAt'] = [string]$Metadata['updatedAt']
    $value['tokenDead'] = [bool]$Metadata['tokenDead']
    $value['tokenFingerprint'] = [string]$Metadata['tokenFingerprint']
    Write-JsonFile -Path $path -Value $value -Label "$Profile profile.json"
}

function Set-ProfileTokenDead {
    param(
        [string]$Profile,
        [string]$Reason
    )

    $metadata = Get-ProfileMetadata -Profile $Profile
    if (-not $metadata) {
        return
    }
    $metadata['tokenDead'] = $true
    $metadata['tokenDeadReason'] = $Reason
    $metadata['tokenCheckedAt'] = Get-NowIso
    Write-ProfileMetadata -Profile $Profile -Metadata $metadata
}

function Clear-ProfileTokenDead {
    param([string]$Profile)

    $metadata = Get-ProfileMetadata -Profile $Profile
    if (-not $metadata) {
        return $null
    }
    $metadata['tokenDead'] = $false
    $metadata['tokenDeadReason'] = $null
    $metadata['tokenCheckedAt'] = Get-NowIso
    Write-ProfileMetadata -Profile $Profile -Metadata $metadata
    return $metadata
}

function Get-ProfileDirectories {
    if (-not (Test-Path -LiteralPath $accountRoot)) {
        return @()
    }

    return @(Get-ChildItem -LiteralPath $accountRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { -not $_.Name.StartsWith('_') } |
            Sort-Object Name)
}

function Get-ActiveProfile {
    $parsed = Read-JsonFile -Path $currentFile -Label 'current.json'
    if (-not $parsed -or [string]::IsNullOrWhiteSpace([string]$parsed.profile)) {
        return $null
    }

    $profile = [string]$parsed.profile
    if (-not (Test-Path -LiteralPath (Get-ProfilePath -Profile $profile))) {
        return $null
    }
    return $profile
}

# When the ACTIVE profile became active. current.json is written at every switch
# and is the authoritative record for exactly that one profile, so the monitor
# can tint the live row the same way it tints any other switched-today row even
# when that account was switched in before this feature existed.
function Get-ActiveSwitchedAt {
    $parsed = Read-JsonFile -Path $currentFile -Label 'current.json'
    if (-not $parsed -or [string]::IsNullOrWhiteSpace([string]$parsed.switchedAt)) {
        return $null
    }
    return Format-Iso -Value ([string]$parsed.switchedAt)
}

function Set-ActiveProfile {
    param([string]$Profile)

    $identity = Get-ProfileToken -Profile $Profile
    $metadata = Get-ProfileMetadata -Profile $Profile
    $now = Get-NowIso
    $value = @{}
    $value['profile'] = $Profile
    $value['uid'] = if ($identity) { $identity['Uid'] } else { $null }
    $value['email'] = $Profile
    $value['displayName'] = if ($metadata) { $metadata['displayName'] } else { $null }
    $value['switchedAt'] = $now
    Write-JsonFile -Path $currentFile -Value $value -Label 'current.json'

    # this profile just became the active one: stamp WHEN on the profile itself
    # too, so the monitor can mark a row that was switched to today. Get/Write-
    # ProfileMetadata both carry switchedAt, so every later rewrite keeps it.
    if ($metadata) {
        $metadata['switchedAt'] = $now
        Write-ProfileMetadata -Profile $Profile -Metadata $metadata
    }
}

function Get-ProfileOrActive {
    param([AllowNull()][string]$Profile)

    if (-not [string]::IsNullOrWhiteSpace($Profile)) {
        return Normalize-ProfileName -Profile $Profile
    }

    $active = Get-ActiveProfile
    if ($active) {
        return $active
    }

    throw "no active Trae profile is set and none was given. run .\trae-account.ps1 use <email> first."
}

function Find-ProfileForUid {
    param([AllowNull()][string]$Uid)

    if ([string]::IsNullOrWhiteSpace($Uid)) {
        return $null
    }

    foreach ($directory in Get-ProfileDirectories) {
        $metadata = Get-ProfileMetadata -Profile $directory.Name
        if ($metadata -and ([string]$metadata['uid'] -eq $Uid)) {
            return $directory.Name
        }
        $identity = $null
        try {
            $identity = Get-ProfileToken -Profile $directory.Name
        } catch {
            continue
        }
        if ($identity -and ([string]$identity['Uid'] -eq $Uid)) {
            return $directory.Name
        }
    }

    return $null
}

# ---- the Trae install ------------------------------------------------------

function Get-IdeVersion {
    if (-not [string]::IsNullOrWhiteSpace($env:TRAE_IDE_VERSION)) {
        return $env:TRAE_IDE_VERSION.Trim()
    }

    $exe = Get-TraeExecutable -Processes @()
    $version = (Get-Item -LiteralPath $exe).VersionInfo.FileVersion
    if ([string]::IsNullOrWhiteSpace($version)) {
        throw "Trae's build version is not readable from $exe. set TRAE_IDE_VERSION to the installed version (the auth service is told it, and there is no guess here on purpose)."
    }
    return $version.Trim()
}

function Get-TraeExecutable {
    param([AllowNull()]$Processes)

    $candidates = @()
    if ($Processes) {
        foreach ($process in @($Processes)) {
            if ($process.ExecutablePath) {
                $candidates += [string]$process.ExecutablePath
            }
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($env:TRAE_EXE)) {
        $candidates += $env:TRAE_EXE.Trim()
    }
    if ($env:USERPROFILE) {
        $candidates += Join-Path $env:USERPROFILE 'scoop\apps\trae\current\Trae.exe'
    }
    if ($env:LOCALAPPDATA) {
        $candidates += Join-Path $env:LOCALAPPDATA 'Programs\Trae\Trae.exe'
    }

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    throw "Trae's executable was not found. checked TRAE_EXE, $env:USERPROFILE\scoop\apps\trae\current\Trae.exe and $env:LOCALAPPDATA\Programs\Trae\Trae.exe -- set TRAE_EXE to the installed Trae.exe."
}

# Trae spawns one Electron main process (the window) plus a tree of helpers --
# renderers, extension hosts, and language servers that are ALSO named
# Trae.exe and carry no --type= argument. So "main" here is not a command-line
# guess: it is the process that actually owns a window. Closing only those is
# what keeps a switch from killing a half-written extension host.
function Get-TraeProcesses {
    $rows = @()
    foreach ($process in @(Get-CimInstance Win32_Process -Filter "Name = 'Trae.exe'" -ErrorAction SilentlyContinue)) {
        $handle = [IntPtr]::Zero
        try {
            $handle = (Get-Process -Id $process.ProcessId -ErrorAction Stop).MainWindowHandle
        } catch {
            continue
        }

        $row = @{}
        $row['ProcessId'] = [int]$process.ProcessId
        $row['Window'] = [bool]($handle -ne [IntPtr]::Zero)
        $row['Main'] = [bool]($handle -ne [IntPtr]::Zero)
        $row['ExecutablePath'] = if ($process.ExecutablePath) { [string]$process.ExecutablePath } else { $null }
        $rows += $row
    }

    return $rows
}

function Get-AppReport {
    $processes = @(Get-TraeProcesses)
    $report = @{}
    $report['running'] = ($processes.Count -gt 0)
    $report['windows'] = @($processes | Where-Object { $_['Window'] }).Count
    $report['processes'] = $processes.Count
    $report['tokenFile'] = Get-LiveTokenFile
    $report['exe'] = $null
    try {
        $report['exe'] = Get-TraeExecutable -Processes $processes
    } catch {
        $report['exe'] = $null
        $report['exeError'] = $_.Exception.Message
    }
    return $report
}

function Close-App {
    $processes = @(Get-TraeProcesses)
    if ($processes.Count -eq 0) {
        return $false
    }

    # WM_CLOSE, not TerminateProcess: Trae is an editor and can be holding
    # unsaved buffers or a running agent turn. taskkill without /F posts
    # WM_CLOSE; /F would throw that away.
    $mains = @($processes | Where-Object { $_['Main'] } | ForEach-Object { $_['ProcessId'] })
    if ($mains.Count -eq 0) {
        $mains = @($processes | ForEach-Object { $_['ProcessId'] })
    }
    foreach ($id in $mains) {
        & taskkill.exe /PID $id 2>&1 | Out-Null
    }

    $deadline = [DateTime]::UtcNow.AddSeconds($closeWaitSec)
    while ([DateTime]::UtcNow -lt $deadline) {
        if (@(Get-TraeProcesses).Count -eq 0) {
            return $true
        }
        Start-Sleep -Milliseconds 400
    }

    $left = @(Get-TraeProcesses).Count
    throw "Trae did not close within ${closeWaitSec}s ($left process(es) still running). it may be showing a save/quit prompt -- handle it, then press switch again. the token file was NOT touched."
}

function Start-App {
    param([string[]]$Arguments = @())

    $exe = Get-TraeExecutable -Processes @(Get-TraeProcesses)
    $started = if ($Arguments.Count -gt 0) {
        Start-Process -FilePath $exe -ArgumentList @($Arguments) -PassThru
    } else {
        Start-Process -FilePath $exe -PassThru
    }

    $deadline = [DateTime]::UtcNow.AddSeconds($launchWaitSec)
    while ([DateTime]::UtcNow -lt $deadline) {
        $mains = @(Get-TraeProcesses | Where-Object { $_['Main'] })
        if ($mains.Count -gt 0) {
            $report = @{}
            $report['pid'] = [int]$mains[0]['ProcessId']
            $report['exe'] = $exe
            return $report
        }
        Start-Sleep -Milliseconds 400
    }

    throw "Trae was launched ($exe) but no window appeared within ${launchWaitSec}s."
}

# ---- the auth service ------------------------------------------------------

function Get-HttpErrorDetail {
    param($ErrorRecord)

    $body = $null
    if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
        $body = $ErrorRecord.ErrorDetails.Message
    } elseif ($ErrorRecord.Exception -and $ErrorRecord.Exception.Response) {
        try {
            $stream = $ErrorRecord.Exception.Response.GetResponseStream()
            if ($stream) {
                $body = (New-Object IO.StreamReader($stream)).ReadToEnd()
            }
        } catch {
            $body = $null
        }
    }

    $status = $null
    if ($ErrorRecord.Exception -and $ErrorRecord.Exception.Response -and $ErrorRecord.Exception.Response.StatusCode) {
        $status = [int]$ErrorRecord.Exception.Response.StatusCode
    }

    if ([string]::IsNullOrWhiteSpace($body)) {
        $body = $ErrorRecord.Exception.Message
    }

    $body = ($body -replace '\s+', ' ').Trim()
    if ($body.Length -gt 300) {
        $body = $body.Substring(0, 300)
    }

    if ($status) {
        return "HTTP $status $body"
    }
    return $body
}

function Invoke-TraeAuth {
    param(
        [string]$Path,
        [string]$Token,
        [string]$Label
    )

    $body = @{ IDEVersion = (Get-IdeVersion) } | ConvertTo-Json -Compress
    try {
        return Invoke-RestMethod -Method Post -Uri "$authBase/$Path" `
            -Headers @{ 'x-cloudide-token' = $Token } -ContentType 'application/json' `
            -Body $body -TimeoutSec $httpTimeoutSec
    } catch {
        throw "$Label ($Path) was refused: $(Get-HttpErrorDetail -ErrorRecord $_)"
    }
}

# who the token belongs to, per the server. a pure read: it hands back no token,
# so calling it never rotates anything.
function Resolve-TraeIdentity {
    param([string]$Token)

    $response = Invoke-TraeAuth -Path 'GetUserInfo' -Token $Token -Label 'the Trae auth service'
    $result = if ($response.Result) { $response.Result } else { $response }
    if (-not $result -or [string]::IsNullOrWhiteSpace([string]$result.UserID)) {
        throw "GetUserInfo returned no UserID for this token -- the Trae auth service answered something unexpected."
    }

    $identity = @{}
    $identity['Uid'] = [string]$result.UserID
    $identity['Email'] = [string]$result.NonPlainTextEmail
    $identity['DisplayName'] = [string]$result.ScreenName
    $identity['Provider'] = [string]$result.LastLoginType
    $identity['AvatarUrl'] = [string]$result.AvatarUrl
    $identity['TenantId'] = [string]$result.TenantID
    $identity['Region'] = [string]$result.Region
    $identity['StoreCountry'] = [string]$result.StoreCountry
    $identity['RegisterTime'] = [string]$result.RegisterTime
    $identity['LastLoginTime'] = [string]$result.LastLoginTime
    return $identity
}

# mint a fresh token for the same account. this is a renewal, not a sign-in:
# no login, no refresh token, and the new token renews itself again.
function Invoke-TraeRenew {
    param([string]$Token)

    $response = Invoke-TraeAuth -Path 'GenerateTempToken' -Token $Token -Label 'GenerateTempToken'
    $result = if ($response.Result) { $response.Result } else { $response }
    $newToken = [string]$result.Token
    if ([string]::IsNullOrWhiteSpace($newToken)) {
        throw "GenerateTempToken returned no Result.Token -- the Trae auth service answered something unexpected."
    }

    $claims = Get-TokenClaims -Token $newToken
    if (-not $claims -or -not $claims['Uid']) {
        throw 'GenerateTempToken returned a token that is not a readable Trae JWT.'
    }

    $renewed = @{}
    $renewed['Token'] = $newToken
    $renewed['Uid'] = [string]$claims['Uid']
    $renewed['ExpiresAt'] = $claims['ExpiresAt']
    $renewed['Expired'] = $claims['Expired']
    $renewed['TokenFingerprint'] = Get-Fingerprint -Token $newToken
    return $renewed
}

# a token the auth service still accepts is a live credential; anything else is
# a dead chain and gets stamped on the profile so `use` refuses early.
function Test-TokenRefused {
    param([string]$Detail)

    return [bool]($Detail -match '(?i)\b(401|403|1001|4015)\b|unauthenticated|not able to authenticate|token (is )?(invalid|expired)')
}

# ---- status ----------------------------------------------------------------

function Get-ProfileRow {
    param(
        [string]$Profile,
        [AllowNull()][string]$LiveUid,
        [AllowNull()][string]$Active,
        [AllowNull()][string]$ActiveSwitchedAt
    )

    $normalized = Normalize-ProfileName -Profile $Profile
    $metadata = Get-ProfileMetadata -Profile $normalized
    $identity = $null
    $identityError = $null
    try {
        $identity = Get-ProfileToken -Profile $normalized
    } catch {
        $identityError = $_.Exception.Message
    }

    $uid = if ($metadata -and $metadata['uid']) { [string]$metadata['uid'] } elseif ($identity) { [string]$identity['Uid'] } else { $null }
    $isLive = [bool]($uid -and $LiveUid -and ($uid -eq $LiveUid))
    $expired = [bool]($identity -and [bool]$identity['Expired'])
    $tokenDead = [bool]($metadata -and [bool]$metadata['tokenDead'])
    $state = if (-not $identity) { 'missing-token' } elseif ($isLive) { 'live' } elseif ($expired) { 'expired' } elseif ($tokenDead) { 'token-dead' } elseif ($normalized -eq $Active) { 'active' } else { 'stored' }

    $row = @{}
    $row['email'] = $normalized
    $row['uid'] = $uid
    $row['uidFingerprint'] = Get-UidFingerprint -Uid $uid
    $row['displayName'] = if ($metadata) { $metadata['displayName'] } else { $null }
    $row['provider'] = if ($metadata) { $metadata['provider'] } else { $null }
    $row['avatarUrl'] = if ($metadata) { $metadata['avatarUrl'] } else { $null }
    $row['emailSource'] = if ($metadata) { $metadata['emailSource'] } else { $null }
    $row['folder'] = Get-ProfilePath -Profile $normalized
    $row['tokenFile'] = Join-Path $row['folder'] $tokenRelative
    $row['tokenFingerprint'] = if ($identity) { $identity['TokenFingerprint'] } else { $null }
    $row['expiresAt'] = if ($identity) { $identity['ExpiresAt'] } else { $null }
    $row['expired'] = $expired
    $row['savedAt'] = if ($metadata -and $metadata['savedAt']) { $metadata['savedAt'] } else { $null }
    $row['updatedAt'] = if ($metadata -and $metadata['updatedAt']) { $metadata['updatedAt'] } else { $null }
    # when this profile was last switched to (see Set-ActiveProfile). the monitor
    # tints a row that was switched to today, so it reads this straight off the
    # row. the ACTIVE profile's source is current.json -- the authoritative
    # record of when the active account became active -- so it is tinted even
    # when that switch predates this feature.
    $switchedSource = if (($normalized -eq $Active) -and $ActiveSwitchedAt) { $ActiveSwitchedAt } elseif ($metadata -and $metadata['switchedAt']) { [string]$metadata['switchedAt'] } else { $null }
    $row['switchedAt'] = Format-Iso -Value $switchedSource
    $row['refreshedAt'] = if ($metadata) { $metadata['refreshedAt'] } else { $null }
    $row['tokenCheckedAt'] = if ($metadata) { $metadata['tokenCheckedAt'] } else { $null }
    $row['isLive'] = $isLive
    $row['isActive'] = [bool]($normalized -eq $Active)
    $row['tokenDead'] = $tokenDead
    $row['tokenDeadReason'] = if ($tokenDead -and $metadata) { $metadata['tokenDeadReason'] } else { $null }
    $row['identityError'] = $identityError
    $row['state'] = $state
    return $row
}

# who an UNBANKED live uid belongs to. unlike a named account this needs a
# GetUserInfo round trip, so the answer is cached: the panel polls status every
# 10s and must not spend a request per poll.
function Resolve-UnbankedLive {
    param($Live)

    $cache = Read-JsonFile -Path $liveCacheFile -Label 'live-cache.json'
    if ($cache -and
        ([string]$cache.uid -eq [string]$Live['Uid']) -and
        ([string]$cache.tokenFingerprint -eq [string]$Live['TokenFingerprint'])) {
        $checkedAt = if ($cache.checkedAt) { [DateTimeOffset]::Parse([string]$cache.checkedAt) } else { [DateTimeOffset]::MinValue }
        $ttlSeconds = if ($cache.error) { 120 } else { 900 }
        if (([DateTimeOffset]::UtcNow - $checkedAt).TotalSeconds -lt $ttlSeconds) {
            $cached = @{}
            $cached['email'] = if ($cache.email) { [string]$cache.email } else { $null }
            $cached['displayName'] = if ($cache.displayName) { [string]$cache.displayName } else { $null }
            $cached['provider'] = if ($cache.provider) { [string]$cache.provider } else { $null }
            $cached['error'] = if ($cache.error) { [string]$cache.error } else { $null }
            return $cached
        }
    }

    $resolved = @{}
    $resolved['email'] = $null
    $resolved['displayName'] = $null
    $resolved['provider'] = $null
    $resolved['error'] = $null
    try {
        $identity = Resolve-TraeIdentity -Token ([string]$Live['Token'])
        if ([string]$identity['Uid'] -ne [string]$Live['Uid']) {
            throw "the token belongs to uid $($identity['Uid']), not $($Live['Uid']) -- the token file changed under the read."
        }
        $resolved['email'] = $identity['Email']
        $resolved['displayName'] = $identity['DisplayName']
        $resolved['provider'] = $identity['Provider']
    } catch {
        $resolved['error'] = $_.Exception.Message
    }

    $value = @{}
    $value['uid'] = [string]$Live['Uid']
    $value['tokenFingerprint'] = [string]$Live['TokenFingerprint']
    $value['email'] = $resolved['email']
    $value['displayName'] = $resolved['displayName']
    $value['provider'] = $resolved['provider']
    $value['error'] = $resolved['error']
    $value['checkedAt'] = Get-NowIso
    try {
        Write-JsonFile -Path $liveCacheFile -Value $value -Label 'live-cache.json'
    } catch {
        # a cache that cannot be written must not hide the identity it resolved.
    }

    return $resolved
}

function Get-StatusReport {
    $live = Get-LiveToken
    $active = Get-ActiveProfile
    $activeSwitchedAt = Get-ActiveSwitchedAt
    $app = Get-AppReport
    $liveProfile = if ($live) { Find-ProfileForUid -Uid ([string]$live['Uid']) } else { $null }
    $liveEmail = $null
    $liveDisplay = $null
    $liveProvider = $null
    $identityError = $null
    $emailSource = $null

    if ($live -and $liveProfile) {
        $metadata = Get-ProfileMetadata -Profile $liveProfile
        $liveEmail = if ($metadata) { $metadata['email'] } else { $liveProfile }
        $liveDisplay = if ($metadata) { $metadata['displayName'] } else { $null }
        $liveProvider = if ($metadata) { $metadata['provider'] } else { $null }
        $emailSource = 'profile'
    } elseif ($live) {
        $resolved = Resolve-UnbankedLive -Live $live
        $liveEmail = $resolved['email']
        $liveDisplay = $resolved['displayName']
        $liveProvider = $resolved['provider']
        $identityError = $resolved['error']
        $emailSource = if ($resolved['email']) { 'auth' } else { $null }
    }

    # Trae's TokenManager rewrites the live token on its own schedule. copy that
    # newest head into the profile that owns it, so `use` never installs a token
    # the server has already moved past. local file work only, no network.
    $rebanked = $null
    $rebankError = $null
    if ($live -and $liveProfile) {
        try {
            $stored = Get-ProfileToken -Profile $liveProfile
            if ($stored -and ([string]$stored['Token'] -ne [string]$live['Token'])) {
                $metadata = Get-ProfileMetadata -Profile $liveProfile
                if (-not $metadata) {
                    throw "profile $liveProfile has no profile.json to update."
                }
                Write-TokenFile -Path (Join-Path (Get-ProfilePath -Profile $liveProfile) $tokenRelative) -Token ([string]$live['Token'])
                $metadata['tokenFingerprint'] = [string]$live['TokenFingerprint']
                $metadata['updatedAt'] = Get-NowIso
                Write-ProfileMetadata -Profile $liveProfile -Metadata $metadata
                $rebanked = $liveProfile
            }
        } catch {
            $rebankError = $_.Exception.Message
        }
    }

    $profiles = @(foreach ($directory in Get-ProfileDirectories) {
            Get-ProfileRow -Profile $directory.Name -LiveUid $(if ($live) { [string]$live['Uid'] } else { $null }) -Active $active -ActiveSwitchedAt $activeSwitchedAt
        })

    $detail = if ($live) {
        if ($liveProfile) {
            "signed in as $liveProfile"
        } elseif ($liveEmail) {
            "signed in as $liveEmail, which no stored profile owns yet -- harvest it"
        } elseif ($identityError) {
            "signed in with an account no profile owns, and the auth service could not name it -- $identityError"
        } else {
            'signed in with a token the auth service cannot name (no address on the account) -- it cannot join the pool'
        }
    } else {
        "no token at $(Get-LiveTokenFile) -- Trae has never signed in on this machine"
    }

    $livePart = @{}
    $livePart['signedIn'] = [bool]$live
    $livePart['uid'] = if ($live) { [string]$live['Uid'] } else { $null }
    $livePart['uidFingerprint'] = if ($live) { Get-UidFingerprint -Uid ([string]$live['Uid']) } else { $null }
    $livePart['email'] = $liveEmail
    $livePart['displayName'] = $liveDisplay
    $livePart['provider'] = $liveProvider
    $livePart['emailSource'] = $emailSource
    $livePart['profile'] = $liveProfile
    $livePart['anonymous'] = [bool]($live -and -not $liveProfile -and -not $liveEmail)
    $livePart['tokenFingerprint'] = if ($live) { [string]$live['TokenFingerprint'] } else { $null }
    $livePart['expiresAt'] = if ($live) { $live['ExpiresAt'] } else { $null }
    $livePart['expired'] = if ($live) { [bool]$live['Expired'] } else { $false }
    $livePart['tokenFile'] = Get-LiveTokenFile
    $livePart['identityError'] = $identityError
    $livePart['detail'] = $detail

    $counts = @{}
    $counts['profiles'] = $profiles.Count
    $counts['signedIn'] = [bool]$live
    $counts['appRunning'] = [bool]$app['running']
    $counts['expired'] = @($profiles | Where-Object { $_['expired'] }).Count
    $counts['tokenDead'] = @($profiles | Where-Object { $_['tokenDead'] }).Count

    $report = @{}
    $report['ok'] = $true
    $report['tool'] = $tool
    $report['service'] = $serviceName
    $report['helper'] = (Join-Path $PSScriptRoot 'trae-account.ps1')
    $report['accountRoot'] = $accountRoot
    $report['authBase'] = $authBase
    $report['tokenFile'] = Get-LiveTokenFile
    $report['accountFiles'] = @($accountFiles)
    $ideVersion = $null
    $ideVersionError = $null
    try {
        $ideVersion = Get-IdeVersion
    } catch {
        $ideVersionError = $_.Exception.Message
    }
    $report['ideVersion'] = $ideVersion
    $report['ideVersionError'] = $ideVersionError
    $report['app'] = $app
    $report['active'] = $active
    $report['live'] = $livePart
    $report['profiles'] = $profiles
    $report['rebankedProfile'] = $rebanked
    $report['rebankError'] = $rebankError
    $report['counts'] = $counts
    $report['checkedAt'] = Get-NowIso
    return $report
}

# ---- verbs -----------------------------------------------------------------

function Invoke-Harvest {
    param([AllowNull()][string]$Profile, [switch]$Quiet)

    $live = Get-LiveToken
    if (-not $live) {
        throw "nothing is signed in to $(Get-LiveTokenFile), so there is no token to harvest. open Trae and sign in, then run .\trae-account.ps1 harvest."
    }

    # a banked profile needs no network to be re-banked; an unnamed live
    # sign-in does, because GetUserInfo is the only thing that can name it.
    $owner = Find-ProfileForUid -Uid ([string]$live['Uid'])
    $auth = $null
    $authError = $null
    try {
        $auth = Resolve-TraeIdentity -Token ([string]$live['Token'])
        if ([string]$auth['Uid'] -ne [string]$live['Uid']) {
            throw "the token belongs to uid $($auth['Uid']), not $($live['Uid']) -- the live token changed under the read."
        }
    } catch {
        $authError = $_.Exception.Message
    }

    $identityEmail = if ($auth) { [string]$auth['Email'] } else { $null }
    $email = $null
    $emailSource = $null
    if ($Profile) {
        $email = Normalize-ProfileName -Profile $Profile
        if ($identityEmail -and ($email -ne $identityEmail.ToLowerInvariant())) {
            throw "the live Trae sign-in is $identityEmail, not $email. profiles are keyed by the account's own email -- sign in as that account inside Trae (or pass $identityEmail)."
        }
        if (-not $identityEmail) {
            $why = if ($authError) { "the auth service could not be asked: $authError" } else { 'the account has no address on it' }
            throw "cannot bank this sign-in as $email -- $why. this helper never saves an unverified address."
        }
        $emailSource = 'auth'
    } else {
        $email = if ($identityEmail) { $identityEmail.ToLowerInvariant() } else { $null }
        $emailSource = if ($identityEmail) { 'auth' } else { $null }
        if (-not $email -and $owner) {
            $email = $owner
            $emailSource = 'profile'
        }
    }

    if (-not $email) {
        $why = if ($authError) {
            "and the auth service could not name it either -- $authError"
        } elseif ($auth) {
            'and GetUserInfo reports no address for it, so there is nothing to key a profile by'
        } else {
            'and the auth service returned no identity for it'
        }
        throw "this sign-in matches no stored profile $why. sign in inside Trae as an account with an email address, then harvest again. profiles are keyed by email only."
    }

    if ($authError -and -not $Profile -and -not $owner) {
        throw "this sign-in matches no stored profile and the auth service could not name it -- $authError"
    }

    $clash = Test-IdentityAnchorTaken -Uid ([string]$live['Uid']) -Email $email
    if ($clash) {
        throw "'$email' and '$clash' are the same Trae account (uid $(Get-UidFingerprint -Uid ([string]$live['Uid']))). bank it once, under one address: .\trae-account.ps1 forget $clash"
    }

    $now = Get-NowIso
    $metadata = Get-ProfileMetadata -Profile $email
    $savedAt = if ($metadata -and $metadata['savedAt']) { $metadata['savedAt'] } else { $now }

    # the token is banked and verified in the same act: a live file that
    # disappeared between the read and the write is caught here, not at switch.
    Write-TokenFile -Path (Join-Path (Get-ProfilePath -Profile $email) $tokenRelative) -Token ([string]$live['Token'])
    $stored = Get-ProfileToken -Profile $email
    if (-not $stored -or ([string]$stored['Uid'] -ne [string]$live['Uid'])) {
        throw "the live token at $(Get-LiveTokenFile) disappeared while banking $email. sign in again inside Trae."
    }

    $value = @{}
    $value['email'] = $email
    $value['uid'] = [string]$live['Uid']
    $value['emailSource'] = $emailSource
    $value['displayName'] = if ($auth) { $auth['DisplayName'] } else { $null }
    $value['provider'] = if ($auth) { $auth['Provider'] } elseif ($metadata) { $metadata['provider'] } else { $null }
    $value['avatarUrl'] = if ($auth) { $auth['AvatarUrl'] } else { $null }
    $value['tenantId'] = if ($auth) { $auth['TenantId'] } else { $live['TenantId'] }
    $value['region'] = if ($auth) { $auth['Region'] } else { $null }
    $value['storeCountry'] = if ($auth) { $auth['StoreCountry'] } else { $null }
    $value['registerTime'] = if ($auth) { $auth['RegisterTime'] } else { $null }
    $value['lastLoginTime'] = if ($auth) { $auth['LastLoginTime'] } else { $null }
    $value['savedAt'] = $savedAt
    $value['updatedAt'] = $now
    $value['switchedAt'] = $now
    $value['refreshedAt'] = if ($metadata) { $metadata['refreshedAt'] } else { $null }
    $value['tokenDead'] = $false
    $value['tokenDeadReason'] = $null
    $value['tokenCheckedAt'] = $now
    $value['tokenFingerprint'] = [string]$live['TokenFingerprint']
    Write-ProfileMetadata -Profile $email -Metadata $value
    Set-ActiveProfile -Profile $email

    $result = @{}
    $result['ok'] = $true
    $result['action'] = 'harvested'
    $result['profile'] = $email
    $result['uid'] = [string]$live['Uid']
    $result['displayName'] = if ($auth) { $auth['DisplayName'] } else { $null }
    $result['provider'] = $value['provider']
    $result['emailSource'] = $emailSource
    $result['tokenFingerprint'] = [string]$live['TokenFingerprint']
    $result['expiresAt'] = $live['ExpiresAt']
    $result['authError'] = $authError
    $result['message'] = if ($authError) {
        "saved the live sign-in as $email without re-verifying it against the auth service: $authError"
    } else {
        "saved the live sign-in as $email (the auth service named it)"
    }
    if (-not $Quiet) {
        Write-Host $result['message']
    }

    return $result
}

function Invoke-Login {
    param([AllowNull()][string]$Profile)

    $banked = Invoke-Harvest -Profile $Profile -Quiet
    $result = @{}
    $result['ok'] = $true
    $result['action'] = 'logged-in'
    $result['profile'] = $banked['profile']
    $result['uid'] = $banked['uid']
    $result['displayName'] = $banked['displayName']
    $result['provider'] = $banked['provider']
    $result['emailSource'] = $banked['emailSource']
    $result['tokenFingerprint'] = $banked['tokenFingerprint']
    $result['expiresAt'] = $banked['expiresAt']
    $result['authError'] = $banked['authError']
    $result['message'] = "Trae is signed in as $($banked['profile']) and the profile is banked."
    return $result
}

function Invoke-Use {
    param([string]$Profile)

    $normalized = Normalize-ProfileName -Profile $Profile
    $stored = Get-ProfileToken -Profile $normalized
    if (-not $stored) {
        throw "profile '$normalized' has no $tokenRelative. sign in with that account inside Trae, then run .\trae-account.ps1 harvest."
    }
    $metadata = Get-ProfileMetadata -Profile $normalized
    if (-not $metadata) {
        throw "profile '$normalized' has no profile.json -- bank it again with harvest so its uid anchor is known."
    }
    if ([string]$metadata['uid'] -ne [string]$stored['Uid']) {
        throw "profile '$normalized' is inconsistent: profile.json says uid $(Get-UidFingerprint -Uid ([string]$metadata['uid'])) but $tokenRelative is $(Get-UidFingerprint -Uid ([string]$stored['Uid'])). re-bank it with harvest."
    }

    $before = Get-LiveToken
    if ($before -and ([string]$before['Uid'] -eq [string]$stored['Uid'])) {
        Set-ActiveProfile -Profile $normalized
        $report = Get-AppReport
        $same = @{}
        $same['ok'] = $true
        $same['action'] = 'already-live'
        $same['profile'] = $normalized
        $same['uid'] = [string]$stored['Uid']
        $same['appRunning'] = [bool]$report['running']
        $same['expiresAt'] = $stored['ExpiresAt']
        $same['message'] = "$normalized is already the live Trae sign-in; nothing was closed or swapped."
        return $same
    }

    $liveOwner = if ($before) { Find-ProfileForUid -Uid ([string]$before['Uid']) } else { $null }
    if ($before -and -not $liveOwner) {
        throw "switch refused: the sign-in Trae is holding ($(Get-UidFingerprint -Uid ([string]$before['Uid']))) is not banked under any profile, and swapping it out loses it for good. name it first: .\trae-account.ps1 harvest -- or clear it with logout."
    }

    # verify AND renew the target token BEFORE closing the IDE: a refusal must
    # leave Trae open, and a fresh token means the new session starts with a
    # full 7 days rather than whatever was left on the banked one.
    $renewed = $null
    try {
        $renewed = Invoke-TraeRenew -Token ([string]$stored['Token'])
        if ([string]$renewed['Uid'] -ne [string]$stored['Uid']) {
            throw "the minted token belongs to uid $(Get-UidFingerprint -Uid ([string]$renewed['Uid'])), not $(Get-UidFingerprint -Uid ([string]$stored['Uid'])) -- re-bank this profile."
        }
    } catch {
        $detail = $_.Exception.Message
        if (Test-TokenRefused -Detail $detail) {
            Set-ProfileTokenDead -Profile $normalized -Reason $detail
        }
        throw $detail
    }

    $stored['Token'] = [string]$renewed['Token']
    $stored['TokenFingerprint'] = [string]$renewed['TokenFingerprint']
    $stored['ExpiresAt'] = $renewed['ExpiresAt']
    $storeRoot = Get-ProfilePath -Profile $normalized
    Write-TokenFile -Path (Join-Path $storeRoot $tokenRelative) -Token ([string]$stored['Token'])
    $metadata = Clear-ProfileTokenDead -Profile $normalized
    if ($metadata) {
        $metadata['refreshedAt'] = Get-NowIso
        $metadata['tokenFingerprint'] = [string]$stored['TokenFingerprint']
        $metadata['updatedAt'] = Get-NowIso
        Write-ProfileMetadata -Profile $normalized -Metadata $metadata
    }

    $app = Get-AppReport
    $wasRunning = [bool]$app['running']
    if ($wasRunning) {
        [void](Close-App)
    }

    # Trae is gone; re-read what it left behind and bank the outgoing account
    # before anything is overwritten. if it rotated to an unnamed account on the
    # way out, refuse rather than discard it.
    $after = Get-LiveToken
    if ($after) {
        $owner = Find-ProfileForUid -Uid ([string]$after['Uid'])
        if (-not $owner) {
            throw "Trae closed holding a sign-in no profile owns ($(Get-UidFingerprint -Uid ([string]$after['Uid']))) -- the token file was NOT replaced. bank it with harvest, then press switch again."
        }
        if ($owner -ne $normalized) {
            Write-TokenFile -Path (Join-Path (Get-ProfilePath -Profile $owner) $tokenRelative) -Token ([string]$after['Token'])
            $ownerMetadata = Get-ProfileMetadata -Profile $owner
            if ($ownerMetadata) {
                $ownerMetadata['tokenFingerprint'] = [string]$after['TokenFingerprint']
                $ownerMetadata['updatedAt'] = Get-NowIso
                Write-ProfileMetadata -Profile $owner -Metadata $ownerMetadata
            }
        }
    }

    Write-TokenFile -Path (Get-LiveTokenFile) -Token ([string]$stored['Token'])
    Set-ActiveProfile -Profile $normalized

    $installed = Get-LiveToken
    if (-not $installed -or ([string]$installed['Uid'] -ne [string]$stored['Uid'])) {
        throw "the switch wrote $normalized into $(Get-LiveTokenFile) but the file does not hold its uid afterwards. read status before trusting Trae."
    }

    $launchError = $null
    $launched = $null
    if ($wasRunning) {
        try {
            $launched = Start-App
        } catch {
            $launchError = $_.Exception.Message
        }
    }

    $reportAfter = Get-AppReport
    $result = @{}
    $result['ok'] = $true
    $result['action'] = 'switched'
    $result['profile'] = $normalized
    $result['uid'] = [string]$stored['Uid']
    $result['tokenFingerprint'] = [string]$stored['TokenFingerprint']
    $result['expiresAt'] = $stored['ExpiresAt']
    $result['appWasRunning'] = $wasRunning
    $result['appRunning'] = [bool]$reportAfter['running']
    $result['appLaunched'] = [bool]($launched -ne $null)
    $result['appPid'] = if ($launched) { $launched['pid'] } else { $null }
    $result['launchError'] = $launchError
    $result['message'] = if ($launchError) {
        "switched Trae to ${normalized}, but reopening it failed: $launchError. open Trae by hand -- it will start on this account."
    } elseif ($wasRunning) {
        "switched to ${normalized}: Trae was closed, the signed-in token swapped, and it was reopened (pid $($launched['pid'])). the restart is the switch -- Trae reads its token once per launch."
    } else {
        "switched to ${normalized}; Trae is not running, so its next launch starts on that account."
    }
    return $result
}

function Invoke-Refresh {
    param([AllowNull()][string]$Profile)

    $normalized = Get-ProfileOrActive -Profile $Profile
    $stored = Get-ProfileToken -Profile $normalized
    if (-not $stored) {
        throw "profile '$normalized' has no $tokenRelative to renew."
    }

    $live = Get-LiveToken
    $isLive = [bool]($live -and ([string]$live['Uid'] -eq [string]$stored['Uid']))
    $app = Get-AppReport
    if ($isLive -and $app['running']) {
        throw "$normalized is the live sign-in and Trae is running: Trae owns that token and rewrites it on its own schedule. close Trae first (or just leave it -- it renews itself)."
    }

    try {
        $renewed = Invoke-TraeRenew -Token ([string]$stored['Token'])
    } catch {
        $detail = $_.Exception.Message
        if (Test-TokenRefused -Detail $detail) {
            Set-ProfileTokenDead -Profile $normalized -Reason $detail
        }
        throw $detail
    }
    if ([string]$renewed['Uid'] -ne [string]$stored['Uid']) {
        throw "the auth service says this token belongs to uid $(Get-UidFingerprint -Uid ([string]$renewed['Uid'])), not $(Get-UidFingerprint -Uid ([string]$stored['Uid'])) -- re-bank '$normalized'."
    }

    Write-TokenFile -Path (Join-Path (Get-ProfilePath -Profile $normalized) $tokenRelative) -Token ([string]$renewed['Token'])

    $metadata = Get-ProfileMetadata -Profile $normalized
    if ($metadata) {
        $metadata['tokenDead'] = $false
        $metadata['tokenDeadReason'] = $null
        $metadata['tokenCheckedAt'] = Get-NowIso
        $metadata['refreshedAt'] = Get-NowIso
        $metadata['updatedAt'] = Get-NowIso
        $metadata['tokenFingerprint'] = [string]$renewed['TokenFingerprint']
        Write-ProfileMetadata -Profile $normalized -Metadata $metadata
    }

    $liveUpdated = $false
    if ($isLive) {
        # Trae is closed, so writing the renewed head into the live file is this
        # profile's next launch as well as its next switch head.
        $current = Get-LiveToken
        if ($current -and ([string]$current['Token'] -eq [string]$stored['Token'])) {
            Write-TokenFile -Path (Get-LiveTokenFile) -Token ([string]$renewed['Token'])
            $liveUpdated = $true
        }
    }

    $result = @{}
    $result['ok'] = $true
    $result['action'] = 'refreshed'
    $result['profile'] = $normalized
    $result['uid'] = [string]$stored['Uid']
    $result['tokenFingerprint'] = [string]$renewed['TokenFingerprint']
    $result['expiresAt'] = $renewed['ExpiresAt']
    $result['liveUpdated'] = $liveUpdated
    $result['message'] = if ($liveUpdated) {
        "minted a fresh token for $normalized and wrote it to the live token file."
    } else {
        "minted a fresh token for $normalized in the profile store."
    }
    return $result
}

function Invoke-Open {
    $report = Get-AppReport
    if ($report['running']) {
        $already = @{}
        $already['ok'] = $true
        $already['action'] = 'already-open'
        $already['message'] = "Trae is already running ($($report['windows']) window(s))."
        return $already
    }

    $started = Start-App
    $result = @{}
    $result['ok'] = $true
    $result['action'] = 'opened'
    $result['pid'] = $started['pid']
    $result['message'] = "started Trae ($($started['exe']), pid $($started['pid']))."
    return $result
}

function Invoke-Logout {
    param([AllowNull()][string]$Profile)

    $app = Get-AppReport
    if ($app['running']) {
        throw 'close Trae first: it holds the session and rewrites the token file when it refreshes, so deleting the file under it would not sign it out and would lose the newest token.'
    }

    $live = Get-LiveToken
    if (-not $live) {
        $idle = @{}
        $idle['ok'] = $true
        $idle['action'] = 'already-signed-out'
        $idle['profile'] = $Profile
        $idle['message'] = "nothing is signed in to $(Get-LiveTokenFile)."
        return $idle
    }

    $owner = Find-ProfileForUid -Uid ([string]$live['Uid'])
    if ($Profile) {
        $normalized = Normalize-ProfileName -Profile $Profile
        if ($owner -ne $normalized) {
            throw "the live sign-in is not $normalized (it is $(if ($owner) { $owner } else { 'unbanked' })). logout clears the LIVE sign-in, not a stored profile."
        }
    }
    if (-not $owner) {
        throw "refusing to clear an unbanked sign-in ($(Get-UidFingerprint -Uid ([string]$live['Uid']))): it would be lost. bank it first with harvest, or sign out inside Trae by hand."
    }

    Write-TokenFile -Path (Join-Path (Get-ProfilePath -Profile $owner) $tokenRelative) -Token ([string]$live['Token'])
    Remove-Item -LiteralPath (Get-LiveTokenFile) -Force
    if (Test-Path -LiteralPath $currentFile) {
        Remove-Item -LiteralPath $currentFile -Force
    }

    $result = @{}
    $result['ok'] = $true
    $result['action'] = 'logged-out'
    $result['profile'] = $owner
    $result['message'] = "cleared the live token at $(Get-LiveTokenFile). the stored profile $owner keeps its own token, so use can sign back in."
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

    $live = Get-LiveToken
    if ($live) {
        $owner = Find-ProfileForUid -Uid ([string]$live['Uid'])
        if ($owner -eq $normalized) {
            throw "$normalized is the live Trae sign-in. switch to another account (or log out) before forgetting it."
        }
    }

    $backup = "$path.forgotten-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
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

    if ($Profile) {
        $normalized = Normalize-ProfileName -Profile $Profile
        $live = Get-LiveToken
        $stored = Get-ProfileToken -Profile $normalized
        if (-not $stored) {
            throw "profile '$normalized' has no $tokenRelative."
        }
        if (-not $live -or ([string]$live['Uid'] -ne [string]$stored['Uid'])) {
            Write-Host "making $normalized the live Trae account first (this closes and reopens Trae)" -ForegroundColor DarkGray
            [void](Invoke-Use -Profile $normalized)
        }
    } else {
        $live = Get-LiveToken
        if (-not $live) {
            throw 'no live Trae sign-in and no profile given. run .\trae-account.ps1 use <email> first.'
        }
    }

    $report = Get-AppReport
    if ($report['running'] -and $Arguments.Count -eq 0) {
        $already = @{}
        $already['ok'] = $true
        $already['action'] = 'already-running'
        $already['message'] = 'Trae is already running.'
        return $already
    }

    $started = Start-App -Arguments $Arguments
    $result = @{}
    $result['ok'] = $true
    $result['action'] = 'ran'
    $result['pid'] = $started['pid']
    $result['message'] = "started Trae (pid $($started['pid']))$(if ($Arguments.Count -gt 0) { " with $($Arguments.Count) argument(s)" })."
    return $result
}

function Show-Env {
    param([AllowNull()][string]$Profile)

    $normalized = Get-ProfileOrActive -Profile $Profile
    Write-Host "`$env:TRAE_JWT_TOKEN_FILE = '$(Get-LiveTokenFile)'"
    Write-Host "auth service = '$authBase'"
    Write-Host "profile store = '$accountRoot'"
    Write-Host "profile = '$normalized'"
    Write-Host "profile token = '$(Join-Path (Get-ProfilePath -Profile $normalized) $tokenRelative)'"
    try {
        Write-Host "ide version = '$(Get-IdeVersion)'"
    } catch {
        Write-Host "ide version = NOT READABLE -- $($_.Exception.Message)"
    }
    try {
        Write-Host "app = '$(Get-TraeExecutable -Processes @(Get-TraeProcesses))'"
    } catch {
        Write-Host "app = NOT FOUND -- $($_.Exception.Message)"
    }
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
        $profile = if ($remaining.Count -ge 1) { $remaining[0] } else { $null }
        $result = Invoke-Login -Profile $profile
        Emit -Payload $result -Human {
            Write-Host $result.message
            Write-Host "  display name: $($result.displayName)"
            Write-Host "  provider: $($result.provider)"
        }
    }

    'harvest' {
        $profile = if ($remaining.Count -ge 1) { $remaining[0] } else { $null }
        $result = Invoke-Harvest -Profile $profile
        Emit -Payload $result -Human {
            Write-Host "Saved the live sign-in as: $($result.profile)"
            Write-Host "  display name: $($result.displayName)"
            Write-Host "  named by: $($result.emailSource)"
            Write-Host "  key: $($result.tokenFingerprint)"
            Write-Host "  token expires: $($result.expiresAt)"
        }
    }

    'use' {
        if ($remaining.Count -ne 1) {
            throw 'Usage: .\trae-account.ps1 use <email>'
        }

        $result = Invoke-Use -Profile $remaining[0]
        Emit -Payload $result -Human {
            Write-Host $result.message
            if ($result.launchError) {
                Write-Host "  relaunch failed: $($result.launchError)" -ForegroundColor Yellow
            }
        }
    }

    'refresh' {
        $profile = if ($remaining.Count -ge 1) { $remaining[0] } else { $null }
        $result = Invoke-Refresh -Profile $profile
        Emit -Payload $result -Human { Write-Host $result.message }
    }

    'open' {
        $result = Invoke-Open
        Emit -Payload $result -Human { Write-Host $result.message }
    }

    'run' {
        $profile = $null
        $arguments = @($remaining)
        if ($remaining.Count -ge 1 -and (Test-LooksLikeEmail -Value $remaining[0])) {
            $profile = Normalize-ProfileName -Profile $remaining[0]
            $arguments = @($remaining | Select-Object -Skip 1)
        }

        $result = Invoke-Run -Profile $profile -Arguments $arguments
        Emit -Payload $result -Human { Write-Host $result.message }
    }

    'status' {
        $profile = Get-ProfileOrActive -Profile $(if ($remaining.Count -ge 1) { $remaining[0] } else { $null })
        $report = Get-StatusReport
        $row = @($report['profiles'] | Where-Object { $_['email'] -eq $profile }) | Select-Object -First 1
        if (-not $row) {
            $row = Get-ProfileRow -Profile $profile -LiveUid $(if ($report['live']['signedIn']) { [string]$report['live']['uid'] } else { $null }) -Active $report['active']
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
            Write-Host "token file: $($report['live']['tokenFile'])"
            Write-Host "app: $(if ($report['app']['running']) { "running ($($report['app']['windows']) windows)" } else { 'not running' })"
        }
    }

    'status-all' {
        $report = Get-StatusReport
        Emit -Payload $report -Human {
            if (@($report['profiles']).Count -eq 0) {
                Write-Host 'No Trae profiles found. open Trae, sign in, then run .\trae-account.ps1 harvest.'
                Write-Host "live: $($report['live']['detail'])"
                return
            }

            $report['profiles'] |
                Select-Object email, state, isActive, isLive, expired, tokenFingerprint, expiresAt |
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
                Write-Host 'No Trae profiles found.'
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
        $liveProfile = $report['live']['profile']
        $payload = @{}
        $payload['ok'] = $true
        $payload['action'] = 'current'
        $payload['profile'] = $active
        $payload['active'] = $active
        $payload['liveSignedIn'] = $report['live']['signedIn']
        $payload['liveProfile'] = $liveProfile
        $payload['liveEmail'] = $report['live']['email']
        $payload['liveDetail'] = $report['live']['detail']
        $payload['matchesLive'] = [bool]($active -and $liveProfile -and ($active -eq $liveProfile))
        Emit -Payload $payload -Human {
            if ($active) {
                Write-Host $active
            } else {
                Write-Host 'No active Trae email profile set.'
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
        $payload['tokenFile'] = Join-Path $folder $tokenRelative
        Emit -Payload $payload -Human { Write-Host $folder }
    }

    'env' {
        $profile = if ($remaining.Count -ge 1) { $remaining[0] } else { $null }
        if ($useJson) {
            $normalized = Get-ProfileOrActive -Profile $profile
            $folder = Get-ProfilePath -Profile $normalized
            $ideVersion = $null
            try {
                $ideVersion = Get-IdeVersion
            } catch {
                $ideVersion = $null
            }
            $payload = @{}
            $payload['ok'] = $true
            $payload['action'] = 'env'
            $payload['profile'] = $normalized
            $payload['tokenFile'] = Get-LiveTokenFile
            $payload['authBase'] = $authBase
            $payload['accountRoot'] = $accountRoot
            $payload['folder'] = $folder
            $payload['profileTokenFile'] = (Join-Path $folder $tokenRelative)
            $payload['ideVersion'] = $ideVersion
            $payload['app'] = Get-AppReport
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
            throw 'Usage: .\trae-account.ps1 forget <email>'
        }

        $result = Invoke-Forget -Profile $remaining[0]
        Emit -Payload $result -Human { Write-Host $result.message }
    }

    default {
        Show-Usage
        throw "Unknown command: $command"
    }
}
