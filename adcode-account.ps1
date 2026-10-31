$ErrorActionPreference = 'Stop'

# ADCode account profile helper.
#
# ADCode is an Electron IDE whose "Included AI" runs on a Firebase identity.
# The identity is ONE file -- %APPDATA%\@adcode\desktop\ads\ads\identity.json,
# { uid, refreshToken } -- and the app reads it ONCE per launch: the id token is
# minted from the refresh token in memory and the file is only rewritten when
# that refresh happens. There is no re-read loop, so unlike MiniMax Code a swap
# under a running app does nothing. Switching accounts therefore means:
# close ADCode, swap the account files, relaunch it. That restart is part of
# the verb, not a caveat after it.
#
# The email is not in identity.json. It comes from Firebase's own lookup
# (accounts:lookup) using an id token minted from the refresh token. An
# ANONYMOUS identity (created by the app on first run, no Google/GitHub/email
# linked) has no email at all -- such a sign-in is refused here, because a pool
# keyed by anything but the account's own email is how two accounts merge.
# Link a sign-in inside ADCode first (account menu -> sign in), then harvest.
#
# Profiles are keyed by email only and stored in:
#   %APPDATA%\mainframe\accounts\adcode\<email>
# Each profile keeps the same relative files the live data dir uses:
#   ads\ads\identity.json, ads\ads\receipts.json, referrals.json,
#   milestones.json, activity-queue.json, ai-usage.json
# Everything except identity is account-scoped earnings/usage state, so it
# travels with the account: install leaves nothing of the previous account
# behind, and a switch banks the outgoing account first.
#
# Usage:
#   .\adcode-account.ps1 harvest [email]             bank the live sign-in (email verified)
#   .\adcode-account.ps1 login [email]               same, for the contract: verify + bank
#   .\adcode-account.ps1 use <email>                 close ADCode, install the profile, reopen it
#   .\adcode-account.ps1 refresh [email]             renew a stored refresh chain through Firebase
#   .\adcode-account.ps1 open                        start ADCode (for signing a profile in)
#   .\adcode-account.ps1 run [email] [app args...]   switch, then launch ADCode (optionally with args)
#   .\adcode-account.ps1 list / current / status / status-all / path / env
#   .\adcode-account.ps1 logout [email]              clear the LIVE identity (app must be closed)
#   .\adcode-account.ps1 forget <email>              move a stored profile aside
#   .\adcode-account.ps1 status-all -Json            one json object, for the monitor api
#
# The live data dir can be pointed elsewhere with ADCODE_USER_DATA_DIR (the app
# itself honours the same variable, or --user-data-dir); the profile store with
# ADCODE_ACCOUNT_ROOT. A profile-specific data dir is only ever closed/relaunched
# when its own processes carry that --user-data-dir, never the default install.

$tool = 'adcode'
$serviceName = 'ADCode'

# ---- the Firebase contract, read out of the shipped runtime ----------------
# out/main/index.js: STORE_KEY = "ads/identity.json", DEFAULT_FIREBASE_API_KEY,
# identitytoolkit signUp/signInWithIdp/signInWithPassword/update/lookup, and
# securetoken refresh. The refresh response is snake_case; lookup is camelCase.
$defaultFirebaseApiKey = 'AIzaSyATZzX5Fw2HjR34VxB3UQWTmljprA5uXqE'
$secureTokenUrl = 'https://securetoken.googleapis.com/v1/token'
$lookupUrl = 'https://identitytoolkit.googleapis.com/v1/accounts:lookup'

$httpTimeoutSec = 20
$closeWaitSec = 30
$launchWaitSec = 15

# ADCode recomputes the id token itself; refreshing from here is safe while the
# app is closed. With the app running only `use`/`harvest`/`refresh` touch the
# chain, and the app rewrites identity.json when it refreshes, which status
# re-banks.
$accountRoot = if ([string]::IsNullOrWhiteSpace($env:ADCODE_ACCOUNT_ROOT)) {
    Join-Path $env:APPDATA 'mainframe\accounts\adcode'
} else {
    [IO.Path]::GetFullPath($env:ADCODE_ACCOUNT_ROOT.Trim())
}
$currentFile = Join-Path $accountRoot 'current.json'
$liveCacheFile = Join-Path $accountRoot 'live-cache.json'

# the account's own state, in the order it is banked/installed. identity first.
$accountFiles = @(
    'ads\ads\identity.json',
    'ads\ads\receipts.json',
    'referrals.json',
    'milestones.json',
    'activity-queue.json',
    'ai-usage.json'
)
$identityRelative = 'ads\ads\identity.json'

$firebaseApiKey = if ([string]::IsNullOrWhiteSpace($env:ADCODE_FIREBASE_API_KEY)) {
    $defaultFirebaseApiKey
} else {
    $env:ADCODE_FIREBASE_API_KEY.Trim()
}

function Show-Usage {
    @(
        'ADCode account profile helper',
        '',
        'Profiles are keyed by account email only and stored in:',
        '  %APPDATA%\mainframe\accounts\adcode\<email>',
        '',
        'Usage:',
        '  .\adcode-account.ps1 harvest [email]             bank the live sign-in (email verified)',
        '  .\adcode-account.ps1 login [email]               verify + bank the live sign-in',
        '  .\adcode-account.ps1 use <email>                 close ADCode, install the profile, reopen it',
        '  .\adcode-account.ps1 refresh [email]             renew a stored refresh chain',
        '  .\adcode-account.ps1 open                        start ADCode',
        '  .\adcode-account.ps1 run [email] [app args...]   switch, then launch ADCode',
        '  .\adcode-account.ps1 list',
        '  .\adcode-account.ps1 current',
        '  .\adcode-account.ps1 status [email]',
        '  .\adcode-account.ps1 status-all',
        '  .\adcode-account.ps1 path [email]',
        '  .\adcode-account.ps1 env [email]',
        '  .\adcode-account.ps1 logout [email]              clear the LIVE identity (app must be closed)',
        '  .\adcode-account.ps1 forget <email>              move a stored profile aside',
        '',
        'Add -Json to any command for a single machine-readable json object.',
        '',
        'ADCode reads its identity ONCE per launch, so "use" closes it, swaps the',
        'account files and reopens it. An anonymous sign-in (no email linked) is',
        'never banked: link Google/GitHub/email inside ADCode first.',
        '',
        'Examples:',
        '  .\adcode-account.ps1 harvest',
        '  .\adcode-account.ps1 use someone@example.com',
        '  .\adcode-account.ps1 status-all -Json'
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
        throw "ADCode profile must be an account email, not a label or display name: $Profile"
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

# One Firebase uid can only be one account. A second email for a uid the pool
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

# ---- the live data dir and its files --------------------------------------

function Get-DefaultUserData {
    return Join-Path $env:APPDATA '@adcode\desktop'
}

function Get-UserData {
    if (-not [string]::IsNullOrWhiteSpace($env:ADCODE_USER_DATA_DIR)) {
        return [IO.Path]::GetFullPath($env:ADCODE_USER_DATA_DIR.Trim())
    }

    return Get-DefaultUserData
}

function Test-DefaultUserData {
    $live = (Get-UserData).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $default = (Get-DefaultUserData).TrimEnd([IO.Path]::DirectorySeparatorChar)
    return [bool]($live -eq $default)
}

function Get-LiveFile {
    param([string]$Relative)

    return Join-Path (Get-UserData) $Relative
}

function Get-LiveIdentityFile {
    return Get-LiveFile -Relative $identityRelative
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

# ---- app processes ---------------------------------------------------------

function Get-AppExecutable {
    param([AllowNull()]$Processes)

    $candidates = @()
    if ($Processes) {
        foreach ($process in @($Processes)) {
            if ($process.ExecutablePath) {
                $candidates += [string]$process.ExecutablePath
            }
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($env:ADCODE_EXE)) {
        $candidates += $env:ADCODE_EXE.Trim()
    }
    if ($env:LOCALAPPDATA) {
        $candidates += Join-Path $env:LOCALAPPDATA 'Programs\ADCode\ADCode.exe'
    }

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    throw "ADCode's executable was not found. checked ADCODE_EXE and $(Join-Path $env:LOCALAPPDATA 'Programs\ADCode\ADCode.exe') -- set ADCODE_EXE to the installed ADCode.exe."
}

# Which ADCode processes belong to THIS data dir. Electron's main process has
# no --type= argument; renderers/utilities do. A default install carries no
# --user-data-dir; a profile-specific launch carries the absolute path. Matching
# command lines (not process names alone) is what keeps a test/prod profile from
# closing the other instance.
function Get-AppProcesses {
    $userData = (Get-UserData).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $isDefault = Test-DefaultUserData
    $rows = @()

    foreach ($process in @(Get-CimInstance Win32_Process -Filter "Name = 'ADCode.exe'" -ErrorAction SilentlyContinue)) {
        $commandLine = [string]$process.CommandLine
        $hasArg = $commandLine -match '--user-data-dir'
        if ($isDefault) {
            $mine = (-not $hasArg) -or ($commandLine.IndexOf($userData, [StringComparison]::OrdinalIgnoreCase) -ge 0)
        } else {
            $mine = $commandLine.IndexOf("--user-data-dir=$userData", [StringComparison]::OrdinalIgnoreCase) -ge 0
        }
        if (-not $mine) {
            continue
        }

        $main = ($commandLine -notmatch '--type=')
        $handle = [IntPtr]::Zero
        try {
            $handle = (Get-Process -Id $process.ProcessId -ErrorAction Stop).MainWindowHandle
        } catch {
            continue
        }

        $row = @{}
        $row['ProcessId'] = [int]$process.ProcessId
        $row['Main'] = $main
        $row['Window'] = [bool]($handle -ne [IntPtr]::Zero)
        $row['ExecutablePath'] = if ($process.ExecutablePath) { [string]$process.ExecutablePath } else { $null }
        $rows += $row
    }

    return $rows
}

function Get-AppReport {
    $processes = @(Get-AppProcesses)
    $report = @{}
    $report['running'] = ($processes.Count -gt 0)
    $report['windows'] = @($processes | Where-Object { $_['Window'] }).Count
    $report['processes'] = $processes.Count
    $report['userData'] = (Get-UserData)
    $report['exe'] = $null
    try {
        $report['exe'] = Get-AppExecutable -Processes $processes
    } catch {
        $report['exe'] = $null
        $report['exeError'] = $_.Exception.Message
    }
    return $report
}

function Close-App {
    $processes = @(Get-AppProcesses)
    if ($processes.Count -eq 0) {
        return $false
    }

    # WM_CLOSE, not TerminateProcess: Electron saves drafts and can ask a human
    # to save a file. taskkill without /F posts WM_CLOSE; /F would throw away
    # whatever the editor is holding.
    $mains = @($processes | Where-Object { $_['Main'] } | ForEach-Object { $_['ProcessId'] })
    if ($mains.Count -eq 0) {
        $mains = @($processes | ForEach-Object { $_['ProcessId'] })
    }
    foreach ($id in $mains) {
        & taskkill.exe /PID $id 2>&1 | Out-Null
    }

    $deadline = [DateTime]::UtcNow.AddSeconds($closeWaitSec)
    while ([DateTime]::UtcNow -lt $deadline) {
        if (@(Get-AppProcesses).Count -eq 0) {
            return $true
        }
        Start-Sleep -Milliseconds 400
    }

    $left = @(Get-AppProcesses).Count
    throw "ADCode did not close within ${closeWaitSec}s ($left process(es) still running). it may be showing a save/quit prompt -- handle it, then press switch again. the account files were NOT touched."
}

function Start-App {
    param([string[]]$Arguments = @())

    $exe = Get-AppExecutable -Processes @(Get-AppProcesses)
    $launchArgs = @()
    if (-not (Test-DefaultUserData)) {
        $launchArgs += "--user-data-dir=`"$(Get-UserData)`""
    }
    $launchArgs += @($Arguments)

    $started = if ($launchArgs.Count -gt 0) {
        Start-Process -FilePath $exe -ArgumentList $launchArgs -PassThru
    } else {
        Start-Process -FilePath $exe -PassThru
    }

    $deadline = [DateTime]::UtcNow.AddSeconds($launchWaitSec)
    while ([DateTime]::UtcNow -lt $deadline) {
        $mains = @(Get-AppProcesses | Where-Object { $_['Main'] })
        if ($mains.Count -gt 0) {
            $report = @{}
            $report['pid'] = [int]$mains[0]['ProcessId']
            $report['exe'] = $exe
            return $report
        }
        Start-Sleep -Milliseconds 300
    }

    throw "ADCode was launched ($exe) but no main process appeared within ${launchWaitSec}s."
}

# ---- firebase --------------------------------------------------------------

function Get-FirebaseErrorDetail {
    param($ErrorRecord)

    $body = $null
    if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
        $body = $ErrorRecord.ErrorDetails.Message
    } elseif ($ErrorRecord.Exception -and $ErrorRecord.Exception.Response) {
        try {
            $reader = New-Object IO.StreamReader($ErrorRecord.Exception.Response.GetResponseStream())
            $body = $reader.ReadToEnd()
        } catch {
            $body = $null
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($body)) {
        try {
            $parsed = $body | ConvertFrom-Json
            if ($parsed.error -and $parsed.error.message) {
                return [string]$parsed.error.message
            }
            if ($parsed.error -is [string]) {
                return [string]$parsed.error
            }
        } catch {
            return $body.Trim()
        }
        return $body.Trim()
    }

    return $ErrorRecord.Exception.Message
}

function Test-DeadRefreshDetail {
    param([string]$Detail)

    return [bool]($Detail -match 'TOKEN_EXPIRED|INVALID_REFRESH_TOKEN|USER_NOT_FOUND|INVALID_GRANT|refresh token is invalid|refresh token has expired')
}

function Invoke-FirebaseRefresh {
    param([string]$RefreshToken)

    $uri = "$secureTokenUrl`?key=$([uri]::EscapeDataString($firebaseApiKey))"
    try {
        $response = Invoke-RestMethod -Method Post -Uri $uri -ContentType 'application/x-www-form-urlencoded' -Body @{
            grant_type    = 'refresh_token'
            refresh_token = $RefreshToken
        } -TimeoutSec $httpTimeoutSec
    } catch {
        $detail = Get-FirebaseErrorDetail -ErrorRecord $_
        $suffix = if (Test-DeadRefreshDetail -Detail $detail) {
            ' that refresh chain is spent and cannot be revived: sign out and sign in again inside ADCode.'
        } else {
            ''
        }
        throw "Firebase refused this refresh token: $detail.$suffix"
    }

    if ([string]::IsNullOrWhiteSpace([string]$response.id_token) -or [string]::IsNullOrWhiteSpace([string]$response.refresh_token)) {
        throw 'Firebase answered the refresh without id_token/refresh_token -- the response shape changed; check the helper.'
    }

    $result = @{}
    $result['IdToken'] = [string]$response.id_token
    $result['RefreshToken'] = [string]$response.refresh_token
    $result['Uid'] = if ($response.user_id) { [string]$response.user_id } else { $null }
    $result['ExpiresIn'] = if ($response.expires_in) { [long]$response.expires_in } else { $null }
    return $result
}

function Resolve-FirebaseIdentity {
    param([string]$IdToken)

    $uri = "$lookupUrl`?key=$([uri]::EscapeDataString($firebaseApiKey))"
    try {
        $response = Invoke-RestMethod -Method Post -Uri $uri -ContentType 'application/json' -Body (@{ idToken = $IdToken } | ConvertTo-Json) -TimeoutSec $httpTimeoutSec
    } catch {
        $detail = Get-FirebaseErrorDetail -ErrorRecord $_
        throw "Firebase lookup failed: $detail"
    }

    $user = @($response.users) | Select-Object -First 1
    $result = @{}
    $result['Email'] = $null
    $result['DisplayName'] = $null
    $result['Providers'] = @()
    if ($null -eq $user) {
        return $result
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$user.email)) {
        $result['Email'] = ([string]$user.email).Trim().ToLowerInvariant()
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$user.displayName)) {
        $result['DisplayName'] = [string]$user.displayName
    }
    if ($user.providerUserInfo) {
        $result['Providers'] = @(@($user.providerUserInfo) | ForEach-Object { [string]$_.providerId } | Where-Object { $_ })
    }
    return $result
}

# ---- live identity ---------------------------------------------------------

# the app rewrites identity.json after every refresh. reading it while that
# happens can catch a half-written file; two identical reads 120ms apart is the
# proof that this is a settled file, not a snapshot mid-write.
function Get-LiveIdentity {
    $file = Get-LiveIdentityFile
    if (-not (Test-Path -LiteralPath $file)) {
        return $null
    }

    $previous = $null
    for ($attempt = 0; $attempt -lt 6; $attempt++) {
        $raw = [IO.File]::ReadAllText($file)
        if (-not [string]::IsNullOrWhiteSpace($raw)) {
            if ($null -ne $previous -and $raw -eq $previous) {
                try {
                    $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
                    $uid = [string]$parsed.uid
                    $refreshToken = [string]$parsed.refreshToken
                    if (-not [string]::IsNullOrWhiteSpace($uid) -and -not [string]::IsNullOrWhiteSpace($refreshToken)) {
                        $identity = @{}
                        $identity['Uid'] = $uid
                        $identity['RefreshToken'] = $refreshToken
                        $identity['File'] = $file
                        $identity['TokenFingerprint'] = Get-Fingerprint -Token $refreshToken
                        return $identity
                    }
                } catch {
                }
            }
            $previous = $raw
        }
        Start-Sleep -Milliseconds 120
    }

    throw "the live ADCode identity at $file never settled into a readable { uid, refreshToken } -- ADCode is writing it right now; try again."
}

function Write-LiveIdentity {
    param(
        [string]$Uid,
        [string]$RefreshToken
    )

    $value = @{}
    $value['uid'] = $Uid
    $value['refreshToken'] = $RefreshToken
    Write-JsonFile -Path (Get-LiveIdentityFile) -Value $value -Label 'identity.json'
}

# ---- profile store ---------------------------------------------------------

function Get-ProfileIdentity {
    param([string]$Profile)

    $path = Join-Path (Get-ProfilePath -Profile $Profile) $identityRelative
    $parsed = Read-JsonFile -Path $path -Label "$Profile identity.json"
    if (-not $parsed) {
        return $null
    }

    $uid = [string]$parsed.uid
    $refreshToken = [string]$parsed.refreshToken
    if ([string]::IsNullOrWhiteSpace($uid) -or [string]::IsNullOrWhiteSpace($refreshToken)) {
        throw "the stored identity for $Profile at $path is missing uid/refreshToken."
    }

    $identity = @{}
    $identity['Uid'] = $uid
    $identity['RefreshToken'] = $refreshToken
    $identity['File'] = $path
    $identity['TokenFingerprint'] = Get-Fingerprint -Token $refreshToken
    return $identity
}

function Get-ProfileMetadata {
    param([string]$Profile)

    $path = Join-Path (Get-ProfilePath -Profile $Profile) 'profile.json'
    $parsed = Read-JsonFile -Path $path -Label "$Profile profile.json"
    if (-not $parsed) {
        return $null
    }

    $metadata = @{}
    $metadata['email'] = [string]$parsed.email
    $metadata['uid'] = [string]$parsed.uid
    $metadata['emailSource'] = [string]$parsed.emailSource
    $metadata['displayName'] = [string]$parsed.displayName
    $metadata['providers'] = @($parsed.providers | Where-Object { $_ })
    $metadata['savedAt'] = [string]$parsed.savedAt
    $metadata['updatedAt'] = [string]$parsed.updatedAt
    $metadata['grantDead'] = [bool]$parsed.grantDead
    $metadata['grantDeadReason'] = [string]$parsed.grantDeadReason
    $metadata['grantCheckedAt'] = [string]$parsed.grantCheckedAt
    $metadata['tokenFingerprint'] = [string]$parsed.tokenFingerprint
    $metadata['switchedAt'] = [string]$parsed.switchedAt
    return $metadata
}

function Write-ProfileMetadata {
    param([string]$Profile, $Metadata)

    $path = Join-Path (Get-ProfilePath -Profile $Profile) 'profile.json'
    $value = @{}
    $value['email'] = [string]$Metadata['email']
    $value['uid'] = [string]$Metadata['uid']
    $value['emailSource'] = [string]$Metadata['emailSource']
    $value['displayName'] = if ([string]::IsNullOrWhiteSpace([string]$Metadata['displayName'])) { $null } else { [string]$Metadata['displayName'] }
    $value['providers'] = @($Metadata['providers'])
    $value['savedAt'] = [string]$Metadata['savedAt']
    $value['updatedAt'] = [string]$Metadata['updatedAt']
    $value['grantDead'] = [bool]$Metadata['grantDead']
    $value['grantDeadReason'] = if ([string]::IsNullOrWhiteSpace([string]$Metadata['grantDeadReason'])) { $null } else { [string]$Metadata['grantDeadReason'] }
    $value['grantCheckedAt'] = if ([string]::IsNullOrWhiteSpace([string]$Metadata['grantCheckedAt'])) { $null } else { [string]$Metadata['grantCheckedAt'] }
    $value['tokenFingerprint'] = [string]$Metadata['tokenFingerprint']
    $value['switchedAt'] = if ([string]::IsNullOrWhiteSpace([string]$Metadata['switchedAt'])) { $null } else { [string]$Metadata['switchedAt'] }
    Write-JsonFile -Path $path -Value $value -Label "$Profile profile.json"
}

function Set-ProfileGrantDead {
    param(
        [string]$Profile,
        [string]$Reason
    )

    $metadata = Get-ProfileMetadata -Profile $Profile
    if (-not $metadata) {
        return
    }
    $metadata['grantDead'] = $true
    $metadata['grantDeadReason'] = $Reason
    $metadata['grantCheckedAt'] = Get-NowIso
    Write-ProfileMetadata -Profile $Profile -Metadata $metadata
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

function Set-ActiveProfile {
    param([string]$Profile)

    $identity = Get-ProfileIdentity -Profile $Profile
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
    # ProfileMetadata both carry switchedAt, so every later rewrite (renew,
    # grant-dead check, re-bank) keeps the mark.
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

    throw "no active ADCode profile is set and none was given. run .\adcode-account.ps1 use <email> first."
}

function Find-ProfileForUid {
    param([AllowNull()][string]$Uid)

    if ([string]::IsNullOrWhiteSpace($Uid)) {
        return $null
    }

    foreach ($directory in Get-ProfileDirectories) {
        $identity = $null
        try {
            $identity = Get-ProfileIdentity -Profile $directory.Name
        } catch {
            continue
        }
        if ($identity -and ([string]$identity['Uid'] -eq $Uid)) {
            return $directory.Name
        }
    }

    return $null
}

function Copy-LiveFilesToProfile {
    param([string]$Profile)

    $target = Get-ProfilePath -Profile $Profile
    [void][IO.Directory]::CreateDirectory($target)
    $copied = @()
    foreach ($relative in $accountFiles) {
        $source = Get-LiveFile -Relative $relative
        if (-not (Test-Path -LiteralPath $source)) {
            continue
        }
        $destination = Join-Path $target $relative
        $directory = Split-Path -Parent $destination
        [void][IO.Directory]::CreateDirectory($directory)
        Copy-Item -LiteralPath $source -Destination $destination -Force
        $copied += $relative
    }
    return $copied
}

function Install-ProfileToLive {
    param([string]$Profile)

    $sourceRoot = Get-ProfilePath -Profile $Profile
    $identityPath = Join-Path $sourceRoot $identityRelative
    if (-not (Test-Path -LiteralPath $identityPath)) {
        throw "profile $Profile has no $identityRelative. bank it again with harvest while that account is signed in."
    }

    # identity is installed last: a half-installed switch must never look like
    # a signed-in account with the wrong account's earnings files.
    foreach ($relative in $accountFiles) {
        if ($relative -eq $identityRelative) {
            continue
        }
        $live = Get-LiveFile -Relative $relative
        $source = Join-Path $sourceRoot $relative
        if (Test-Path -LiteralPath $source) {
            $directory = Split-Path -Parent $live
            [void][IO.Directory]::CreateDirectory($directory)
            Copy-Item -LiteralPath $source -Destination $live -Force
        } elseif (Test-Path -LiteralPath $live) {
            # the previous account's state must not leak into this one.
            Remove-Item -LiteralPath $live -Force
        }
    }

    $liveIdentity = Get-LiveIdentityFile
    $directory = Split-Path -Parent $liveIdentity
    [void][IO.Directory]::CreateDirectory($directory)
    Copy-Item -LiteralPath $identityPath -Destination $liveIdentity -Force
}

# ---- status ----------------------------------------------------------------

function Get-ProfileRow {
    param(
        [string]$Profile,
        [AllowNull()][string]$LiveUid,
        [AllowNull()][string]$Active
    )

    $normalized = Normalize-ProfileName -Profile $Profile
    $metadata = Get-ProfileMetadata -Profile $normalized
    $identity = $null
    $identityError = $null
    try {
        $identity = Get-ProfileIdentity -Profile $normalized
    } catch {
        $identityError = $_.Exception.Message
    }

    $uid = if ($metadata -and $metadata['uid']) { [string]$metadata['uid'] } elseif ($identity) { [string]$identity['Uid'] } else { $null }
    $isLive = [bool]($uid -and $LiveUid -and ($uid -eq $LiveUid))
    $grantDead = [bool]($metadata -and [bool]$metadata['grantDead'])
    $state = if (-not $identity) { 'missing-identity' } elseif ($isLive) { 'live' } elseif ($grantDead) { 'grant-dead' } elseif ($normalized -eq $Active) { 'active' } else { 'stored' }

    $row = @{}
    $row['email'] = $normalized
    $row['uid'] = $uid
    $row['uidFingerprint'] = Get-UidFingerprint -Uid $uid
    $row['displayName'] = if ($metadata) { $metadata['displayName'] } else { $null }
    # never assign an array through an `if` EXPRESSION: powershell unrolls a
    # one-element array on output, so a google-only account would serialize as
    # "providers": "google.com" and break every consumer that expects a list.
    $row['providers'] = @()
    if ($metadata) {
        $row['providers'] = @($metadata['providers'] | Where-Object { $_ })
    }
    $row['emailSource'] = if ($metadata) { $metadata['emailSource'] } else { $null }
    $row['folder'] = Get-ProfilePath -Profile $normalized
    $row['identityFile'] = Join-Path $row['folder'] $identityRelative
    $row['tokenFingerprint'] = if ($identity) { $identity['TokenFingerprint'] } else { $null }
    $row['savedAt'] = if ($metadata -and $metadata['savedAt']) { $metadata['savedAt'] } else { $null }
    $row['updatedAt'] = if ($metadata -and $metadata['updatedAt']) { $metadata['updatedAt'] } else { $null }
    # when this profile was last switched to (see Set-ActiveProfile). the monitor
    # tints a row that was switched to today, so it reads this straight off the row.
    $row['switchedAt'] = if ($metadata -and $metadata['switchedAt']) { $metadata['switchedAt'] } else { $null }
    $row['chainCheckedAt'] = if ($metadata) { $metadata['grantCheckedAt'] } else { $null }
    $row['isLive'] = $isLive
    $row['isActive'] = [bool]($normalized -eq $Active)
    $row['grantDead'] = $grantDead
    $row['grantDeadReason'] = if ($grantDead -and $metadata) { $metadata['grantDeadReason'] } else { $null }
    $row['identityError'] = $identityError
    $row['state'] = $state
    return $row
}

# who an UNBANKED live uid belongs to. unlike a named account this needs a
# Firebase refresh + lookup, so the answer is cached: the panel polls status
# every 10s and must not spend a token refresh per poll.
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
            $cached['providers'] = @($cache.providers | Where-Object { $_ })
            $cached['error'] = if ($cache.error) { [string]$cache.error } else { $null }
            return $cached
        }
    }

    $resolved = @{}
    $resolved['email'] = $null
    $resolved['displayName'] = $null
    $resolved['providers'] = @()
    $resolved['error'] = $null
    try {
        $refreshed = Invoke-FirebaseRefresh -RefreshToken ([string]$Live['RefreshToken'])
        if ($refreshed['Uid'] -and ([string]$refreshed['Uid'] -ne [string]$Live['Uid'])) {
            throw "the refresh token belongs to uid $($refreshed['Uid']), not $($Live['Uid']) -- the identity file changed under the read."
        }
        $identity = Resolve-FirebaseIdentity -IdToken $refreshed['IdToken']
        $resolved['email'] = $identity['Email']
        $resolved['displayName'] = $identity['DisplayName']
        $resolved['providers'] = @($identity['Providers'])
    } catch {
        $resolved['error'] = $_.Exception.Message
    }

    $value = @{}
    $value['uid'] = [string]$Live['Uid']
    $value['tokenFingerprint'] = [string]$Live['TokenFingerprint']
    $value['email'] = $resolved['email']
    $value['displayName'] = $resolved['displayName']
    $value['providers'] = @($resolved['providers'])
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
    $live = Get-LiveIdentity
    $active = Get-ActiveProfile
    $app = Get-AppReport
    $liveProfile = if ($live) { Find-ProfileForUid -Uid ([string]$live['Uid']) } else { $null }
    $liveEmail = $null
    $liveDisplay = $null
    $liveProviders = @()
    $identityError = $null
    $emailSource = $null

    if ($live -and $liveProfile) {
        $metadata = Get-ProfileMetadata -Profile $liveProfile
        $liveEmail = if ($metadata) { $metadata['email'] } else { $liveProfile }
        $liveDisplay = if ($metadata) { $metadata['displayName'] } else { $null }
        $liveProviders = @()
        if ($metadata) {
            $liveProviders = @($metadata['providers'] | Where-Object { $_ })
        }
        $emailSource = 'profile'
    } elseif ($live) {
        $resolved = Resolve-UnbankedLive -Live $live
        $liveEmail = $resolved['email']
        $liveDisplay = $resolved['displayName']
        $liveProviders = @($resolved['providers'])
        $identityError = $resolved['error']
        $emailSource = if ($resolved['email']) { 'firebase' } else { $null }
    }

    # the app rewrites identity.json on its own refresh. copy that newest head
    # into the profile that owns it, so `use` never installs a token the server
    # has already moved past. local file work only, no network.
    $rebanked = $null
    $rebankError = $null
    if ($live -and $liveProfile) {
        try {
            $stored = Get-ProfileIdentity -Profile $liveProfile
            if ($stored -and ([string]$stored['RefreshToken'] -ne [string]$live['RefreshToken'])) {
                $metadata = Get-ProfileMetadata -Profile $liveProfile
                if (-not $metadata) {
                    throw "profile $liveProfile has no profile.json to update."
                }
                Copy-LiveFilesToProfile -Profile $liveProfile | Out-Null
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
            Get-ProfileRow -Profile $directory.Name -LiveUid $(if ($live) { [string]$live['Uid'] } else { $null }) -Active $active
        })

    $detail = if ($live) {
        if ($liveProfile) {
            "signed in as $liveProfile"
        } elseif ($liveEmail) {
            "signed in as $liveEmail, which no stored profile owns yet -- harvest it"
        } elseif ($identityError) {
            "signed in with an account no profile owns, and Firebase could not name it -- $identityError"
        } else {
            'signed in with an ANONYMOUS Firebase account (no email linked) -- link Google/GitHub/email inside ADCode before it can join the pool'
        }
    } else {
        "no identity.json at $(Get-LiveIdentityFile) -- ADCode has never signed in to this data dir"
    }

    $livePart = @{}
    $livePart['signedIn'] = [bool]$live
    $livePart['uid'] = if ($live) { [string]$live['Uid'] } else { $null }
    $livePart['uidFingerprint'] = if ($live) { Get-UidFingerprint -Uid ([string]$live['Uid']) } else { $null }
    $livePart['email'] = $liveEmail
    $livePart['displayName'] = $liveDisplay
    $livePart['providers'] = @($liveProviders)
    $livePart['emailSource'] = $emailSource
    $livePart['profile'] = $liveProfile
    $livePart['anonymous'] = [bool]($live -and -not $liveProfile -and -not $liveEmail)
    $livePart['tokenFingerprint'] = if ($live) { [string]$live['TokenFingerprint'] } else { $null }
    $livePart['identityFile'] = Get-LiveIdentityFile
    $livePart['identityError'] = $identityError
    $livePart['detail'] = $detail

    $counts = @{}
    $counts['profiles'] = $profiles.Count
    $counts['signedIn'] = [bool]$live
    $counts['appRunning'] = [bool]$app['running']
    $counts['grantDead'] = @($profiles | Where-Object { $_['grantDead'] }).Count

    $report = @{}
    $report['ok'] = $true
    $report['tool'] = $tool
    $report['service'] = $serviceName
    $report['helper'] = (Join-Path $PSScriptRoot 'adcode-account.ps1')
    $report['accountRoot'] = $accountRoot
    $report['userData'] = Get-UserData
    $report['identityFile'] = Get-LiveIdentityFile
    $report['accountFiles'] = @($accountFiles)
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

    $live = Get-LiveIdentity
    if (-not $live) {
        throw "nothing is signed in to $(Get-LiveIdentityFile), so there is no identity to harvest. open ADCode and sign in, then run .\adcode-account.ps1 harvest."
    }

    # a banked profile needs no network to be re-banked; an unnamed live
    # sign-in does, because Firebase is the only thing that can name it.
    $owner = Find-ProfileForUid -Uid ([string]$live['Uid'])
    $firebase = $null
    $firebaseError = $null
    try {
        $refreshed = Invoke-FirebaseRefresh -RefreshToken ([string]$live['RefreshToken'])
        if ($refreshed['Uid'] -and ([string]$refreshed['Uid'] -ne [string]$live['Uid'])) {
            throw "the refresh token belongs to uid $($refreshed['Uid']), not $($live['Uid']) -- the live identity changed under the read."
        }
        $firebase = Resolve-FirebaseIdentity -IdToken $refreshed['IdToken']
        if ([string]$refreshed['RefreshToken'] -ne [string]$live['RefreshToken']) {
            # Firebase answered with a newer refresh token: persist it, but only
            # while the file still holds the one we just spent (the app may have
            # refreshed it again in the meantime).
            $current = Get-LiveIdentity
            if ($current -and ([string]$current['RefreshToken'] -eq [string]$live['RefreshToken'])) {
                Write-LiveIdentity -Uid ([string]$live['Uid']) -RefreshToken ([string]$refreshed['RefreshToken'])
                $live['RefreshToken'] = [string]$refreshed['RefreshToken']
                $live['TokenFingerprint'] = Get-Fingerprint -Token ([string]$live['RefreshToken'])
            }
        }
    } catch {
        $firebaseError = $_.Exception.Message
    }

    $identityEmail = if ($firebase) { $firebase['Email'] } else { $null }
    $email = $null
    $emailSource = $null
    if ($Profile) {
        $email = Normalize-ProfileName -Profile $Profile
        if ($identityEmail -and ($email -ne $identityEmail)) {
            throw "the live ADCode sign-in is $identityEmail, not $email. profiles are keyed by the account's own verified email -- switch to that account inside ADCode (or pass $identityEmail)."
        }
        if (-not $identityEmail) {
            $why = if ($firebaseError) { "Firebase could not be asked: $firebaseError" } else { 'the account is anonymous (no email linked)' }
            throw "cannot bank this sign-in as $email -- $why. ADCode must link a Google/GitHub/email sign-in first (open ADCode, use its account menu), and this helper never saves an unverified address."
        }
        $emailSource = 'firebase'
    } else {
        $email = $identityEmail
        $emailSource = if ($identityEmail) { 'firebase' } else { $null }
        if (-not $email -and $owner) {
            $email = $owner
            $emailSource = 'profile'
        }
    }

    if (-not $email) {
        $why = if ($firebaseError) {
            "and Firebase could not name it either -- $firebaseError"
        } elseif ($firebase) {
            'and the account is anonymous (Firebase reports no email), so there is no address to key a profile by'
        } else {
            'and Firebase returned no identity for it'
        }
        throw "this sign-in matches no stored profile $why. open ADCode and link a Google/GitHub/email sign-in, then harvest again. profiles are keyed by email only."
    }

    if ($firebaseError -and -not $Profile) {
        # a re-harvest of a known profile is allowed offline; naming a NEW one is not.
        if (-not $owner) {
            throw "this sign-in matches no stored profile and Firebase could not name it -- $firebaseError"
        }
    }

    $clash = Test-IdentityAnchorTaken -Uid ([string]$live['Uid']) -Email $email
    if ($clash) {
        throw "'$email' and '$clash' are the same ADCode account (uid $(Get-UidFingerprint -Uid ([string]$live['Uid']))). bank it once, under one address: .\adcode-account.ps1 forget $clash"
    }

    $now = Get-NowIso
    $metadata = Get-ProfileMetadata -Profile $email
    $savedAt = if ($metadata -and $metadata['savedAt']) { $metadata['savedAt'] } else { $now }
    $copied = Copy-LiveFilesToProfile -Profile $email
    if (-not ($copied -contains $identityRelative)) {
        throw "the live identity at $(Get-LiveIdentityFile) disappeared while banking $email. sign in again inside ADCode."
    }

    $providers = @()
    if ($firebase) {
        $providers = @($firebase['Providers'] | Where-Object { $_ })
    }

    $value = @{}
    $value['email'] = $email
    $value['uid'] = [string]$live['Uid']
    $value['emailSource'] = $emailSource
    $value['displayName'] = if ($firebase) { $firebase['DisplayName'] } else { $null }
    $value['providers'] = $providers
    $value['savedAt'] = $savedAt
    $value['updatedAt'] = $now
    $value['grantDead'] = $false
    $value['grantDeadReason'] = $null
    $value['grantCheckedAt'] = $now
    $value['tokenFingerprint'] = [string]$live['TokenFingerprint']
    Write-ProfileMetadata -Profile $email -Metadata $value
    Set-ActiveProfile -Profile $email

    $result = @{}
    $result['ok'] = $true
    $result['action'] = 'harvested'
    $result['profile'] = $email
    $result['uid'] = [string]$live['Uid']
    $result['displayName'] = if ($firebase) { $firebase['DisplayName'] } else { $null }
    $result['providers'] = $providers
    $result['emailSource'] = $emailSource
    $result['tokenFingerprint'] = [string]$live['TokenFingerprint']
    $result['firebaseError'] = $firebaseError
    $result['message'] = if ($firebaseError) {
        "saved the live sign-in as $email without re-verifying it against Firebase: $firebaseError"
    } else {
        "saved the live sign-in as $email (Firebase named it)"
    }
    if (-not $Quiet) {
        Write-Host $result['message']
    }

    return $result
}

function Invoke-Login {
    param([AllowNull()][string]$Profile)

    $banked = Invoke-Harvest -Profile $Profile
    $result = @{}
    $result['ok'] = $true
    $result['action'] = 'logged-in'
    $result['profile'] = $banked['profile']
    $result['uid'] = $banked['uid']
    $result['displayName'] = $banked['displayName']
    $result['providers'] = $banked['providers']
    $result['emailSource'] = $banked['emailSource']
    $result['tokenFingerprint'] = $banked['tokenFingerprint']
    $result['firebaseError'] = $banked['firebaseError']
    $result['message'] = "ADCode is signed in as $($banked['profile']) and the profile is banked."
    return $result
}

function Invoke-Use {
    param([string]$Profile)

    $normalized = Normalize-ProfileName -Profile $Profile
    $stored = Get-ProfileIdentity -Profile $normalized
    if (-not $stored) {
        throw "profile '$normalized' has no $identityRelative. sign in with that account inside ADCode, then run .\adcode-account.ps1 harvest."
    }
    $metadata = Get-ProfileMetadata -Profile $normalized
    if (-not $metadata) {
        throw "profile '$normalized' has no profile.json -- bank it again with harvest so its uid anchor is known."
    }
    if ([string]$metadata['uid'] -ne [string]$stored['Uid']) {
        throw "profile '$normalized' is inconsistent: profile.json says uid $(Get-UidFingerprint -Uid ([string]$metadata['uid'])) but identity.json is $(Get-UidFingerprint -Uid ([string]$stored['Uid'])). re-bank it with harvest."
    }
    if ([bool]$metadata['grantDead']) {
        throw "profile '$normalized' needs a new sign-in: its refresh chain was refused ($($metadata['grantDeadReason'])). open ADCode, sign out and sign in as $normalized, then harvest it again."
    }

    $before = Get-LiveIdentity
    if ($before -and ([string]$before['Uid'] -eq [string]$stored['Uid'])) {
        Set-ActiveProfile -Profile $normalized
        $report = Get-AppReport
        $same = @{}
        $same['ok'] = $true
        $same['action'] = 'already-live'
        $same['profile'] = $normalized
        $same['uid'] = [string]$stored['Uid']
        $same['appRunning'] = [bool]$report['running']
        $same['message'] = "$normalized is already the live ADCode sign-in; nothing was closed or swapped."
        return $same
    }

    $liveOwner = if ($before) { Find-ProfileForUid -Uid ([string]$before['Uid']) } else { $null }
    if ($before -and -not $liveOwner) {
        throw "switch refused: the sign-in ADCode is holding ($(Get-UidFingerprint -Uid ([string]$before['Uid']))) is not banked under any profile, and swapping it out loses it for good. name it first: link Google/GitHub/email inside ADCode, then run .\adcode-account.ps1 harvest -- or clear it with logout."
    }

    # verify the target chain BEFORE closing the IDE. a dead chain is a refusal
    # with the app still open, not a switch that strands the user.
    $refreshed = $null
    try {
        $refreshed = Invoke-FirebaseRefresh -RefreshToken ([string]$stored['RefreshToken'])
        if ($refreshed['Uid'] -and ([string]$refreshed['Uid'] -ne [string]$stored['Uid'])) {
            throw "the stored refresh token belongs to uid $(Get-UidFingerprint -Uid ([string]$refreshed['Uid'])), not $(Get-UidFingerprint -Uid ([string]$stored['Uid'])) -- re-bank this profile."
        }
        if ([string]$refreshed['RefreshToken'] -ne [string]$stored['RefreshToken']) {
            $value = @{}
            $value['uid'] = [string]$stored['Uid']
            $value['refreshToken'] = [string]$refreshed['RefreshToken']
            Write-JsonFile -Path (Join-Path (Get-ProfilePath -Profile $normalized) $identityRelative) -Value $value -Label "$normalized identity.json"
            $stored['RefreshToken'] = [string]$refreshed['RefreshToken']
            $stored['TokenFingerprint'] = Get-Fingerprint -Token ([string]$stored['RefreshToken'])
            $metadata['tokenFingerprint'] = [string]$stored['TokenFingerprint']
            $metadata['updatedAt'] = Get-NowIso
            Write-ProfileMetadata -Profile $normalized -Metadata $metadata
        }
        $metadata['grantDead'] = $false
        $metadata['grantDeadReason'] = $null
        $metadata['grantCheckedAt'] = Get-NowIso
        Write-ProfileMetadata -Profile $normalized -Metadata $metadata
    } catch {
        $detail = $_.Exception.Message
        if (Test-DeadRefreshDetail -Detail $detail) {
            Set-ProfileGrantDead -Profile $normalized -Reason $detail
        }
        throw $detail
    }

    $app = Get-AppReport
    $wasRunning = [bool]$app['running']
    if ($wasRunning) {
        [void](Close-App)
    }

    # the app is gone; re-read what it left behind and bank the outgoing account
    # before anything is overwritten. if it changed to an unnamed account on the
    # way out, refuse rather than discard it.
    $after = Get-LiveIdentity
    if ($after) {
        $owner = Find-ProfileForUid -Uid ([string]$after['Uid'])
        if (-not $owner) {
            throw "ADCode closed holding a sign-in no profile owns ($(Get-UidFingerprint -Uid ([string]$after['Uid']))) -- it was NOT replaced. link its email inside ADCode and harvest it, then press switch again."
        }
        if ($owner -ne $normalized) {
            Copy-LiveFilesToProfile -Profile $owner | Out-Null
            $ownerMetadata = Get-ProfileMetadata -Profile $owner
            if ($ownerMetadata) {
                $ownerMetadata['tokenFingerprint'] = [string]$after['TokenFingerprint']
                $ownerMetadata['updatedAt'] = Get-NowIso
                Write-ProfileMetadata -Profile $owner -Metadata $ownerMetadata
            }
        }
    }

    Install-ProfileToLive -Profile $normalized
    Set-ActiveProfile -Profile $normalized

    $installed = Get-LiveIdentity
    if (-not $installed -or ([string]$installed['Uid'] -ne [string]$stored['Uid'])) {
        throw "the switch copied $normalized into $(Get-LiveIdentityFile) but the file does not hold its uid afterwards. read status before trusting ADCode."
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
    $result['appWasRunning'] = $wasRunning
    $result['appRunning'] = [bool]$reportAfter['running']
    $result['appLaunched'] = [bool]($launched -ne $null)
    $result['appPid'] = if ($launched) { $launched['pid'] } else { $null }
    $result['launchError'] = $launchError
    $result['message'] = if ($launchError) {
        "switched ADCode to ${normalized}, but reopening it failed: $launchError. open ADCode by hand -- it will start on this account."
    } elseif ($wasRunning) {
        "switched to ${normalized}: ADCode was closed, its account files swapped, and it was reopened (pid $($launched['pid'])). the restart is the switch -- ADCode reads its identity once per launch."
    } else {
        "switched to ${normalized}; ADCode is not running, so its next launch starts on that account."
    }
    return $result
}

function Invoke-Refresh {
    param([AllowNull()][string]$Profile)

    $normalized = Get-ProfileOrActive -Profile $Profile
    $stored = Get-ProfileIdentity -Profile $normalized
    if (-not $stored) {
        throw "profile '$normalized' has no $identityRelative to renew."
    }

    $live = Get-LiveIdentity
    $isLive = [bool]($live -and ([string]$live['Uid'] -eq [string]$stored['Uid']))
    $app = Get-AppReport
    if ($isLive -and $app['running']) {
        throw "$normalized is the live sign-in and ADCode is running: the app owns that refresh chain and renews it itself. close ADCode first (or just leave it -- it renews on demand)."
    }

    try {
        $refreshed = Invoke-FirebaseRefresh -RefreshToken ([string]$stored['RefreshToken'])
    } catch {
        $detail = $_.Exception.Message
        if (Test-DeadRefreshDetail -Detail $detail) {
            Set-ProfileGrantDead -Profile $normalized -Reason $detail
        }
        throw $detail
    }
    if ($refreshed['Uid'] -and ([string]$refreshed['Uid'] -ne [string]$stored['Uid'])) {
        throw "Firebase says this refresh token belongs to uid $(Get-UidFingerprint -Uid ([string]$refreshed['Uid'])), not $(Get-UidFingerprint -Uid ([string]$stored['Uid'])) -- re-bank '$normalized'."
    }

    $value = @{}
    $value['uid'] = [string]$stored['Uid']
    $value['refreshToken'] = [string]$refreshed['RefreshToken']
    Write-JsonFile -Path (Join-Path (Get-ProfilePath -Profile $normalized) $identityRelative) -Value $value -Label "$normalized identity.json"

    $metadata = Get-ProfileMetadata -Profile $normalized
    if ($metadata) {
        $metadata['grantDead'] = $false
        $metadata['grantDeadReason'] = $null
        $metadata['grantCheckedAt'] = Get-NowIso
        $metadata['updatedAt'] = Get-NowIso
        $metadata['tokenFingerprint'] = Get-Fingerprint -Token ([string]$refreshed['RefreshToken'])
        Write-ProfileMetadata -Profile $normalized -Metadata $metadata
    }

    $liveUpdated = $false
    if ($isLive) {
        # the app is closed, so writing the rotated head into identity.json is
        # this profile's next switch head as well as its next launch.
        $current = Get-LiveIdentity
        if ($current -and ([string]$current['RefreshToken'] -eq [string]$stored['RefreshToken'])) {
            Write-LiveIdentity -Uid ([string]$stored['Uid']) -RefreshToken ([string]$refreshed['RefreshToken'])
            $liveUpdated = $true
        }
    }

    $result = @{}
    $result['ok'] = $true
    $result['action'] = 'refreshed'
    $result['profile'] = $normalized
    $result['uid'] = [string]$stored['Uid']
    $result['tokenFingerprint'] = Get-Fingerprint -Token ([string]$refreshed['RefreshToken'])
    $result['liveUpdated'] = $liveUpdated
    $result['message'] = if ($liveUpdated) {
        "renewed $normalized's refresh chain and wrote it to the live identity.json."
    } else {
        "renewed $normalized's refresh chain in the profile store."
    }
    return $result
}

function Invoke-Open {
    $report = Get-AppReport
    if ($report['running']) {
        $already = @{}
        $already['ok'] = $true
        $already['action'] = 'already-open'
        $already['message'] = "ADCode is already running ($($report['windows']) window(s))."
        return $already
    }

    $started = Start-App
    $result = @{}
    $result['ok'] = $true
    $result['action'] = 'opened'
    $result['pid'] = $started['pid']
    $result['message'] = "started ADCode ($($started['exe']), pid $($started['pid']))."
    return $result
}

function Invoke-Logout {
    param([AllowNull()][string]$Profile)

    $app = Get-AppReport
    if ($app['running']) {
        throw 'close ADCode first: it holds the live identity in memory and rewrites identity.json when it renews, so deleting the file under it would not sign it out and would lose the newest token.'
    }

    $live = Get-LiveIdentity
    if (-not $live) {
        $idle = @{}
        $idle['ok'] = $true
        $idle['action'] = 'already-signed-out'
        $idle['profile'] = $Profile
        $idle['message'] = "nothing is signed in to $(Get-LiveIdentityFile)."
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
        throw "refusing to clear an unbanked sign-in ($(Get-UidFingerprint -Uid ([string]$live['Uid']))): it would be lost. bank it first (link its email inside ADCode, then harvest), or sign out inside ADCode by hand."
    }

    Copy-LiveFilesToProfile -Profile $owner | Out-Null
    foreach ($relative in $accountFiles) {
        $path = Get-LiveFile -Relative $relative
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Force
        }
    }
    if (Test-Path -LiteralPath $currentFile) {
        Remove-Item -LiteralPath $currentFile -Force
    }

    $result = @{}
    $result['ok'] = $true
    $result['action'] = 'logged-out'
    $result['profile'] = $owner
    $result['message'] = "cleared the live identity from $(Get-LiveIdentityFile). the stored profile $owner keeps its own token, so use can sign back in."
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

    $live = Get-LiveIdentity
    if ($live) {
        $owner = Find-ProfileForUid -Uid ([string]$live['Uid'])
        if ($owner -eq $normalized) {
            throw "$normalized is the live ADCode sign-in. switch to another account (or log out) before forgetting it."
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
        $live = Get-LiveIdentity
        $stored = Get-ProfileIdentity -Profile $normalized
        if (-not $stored) {
            throw "profile '$normalized' has no $identityRelative."
        }
        if (-not $live -or ([string]$live['Uid'] -ne [string]$stored['Uid'])) {
            Write-Host "making $normalized the live ADCode account first (this closes and reopens ADCode)" -ForegroundColor DarkGray
            [void](Invoke-Use -Profile $normalized)
        }
    } else {
        $live = Get-LiveIdentity
        if (-not $live) {
            throw 'no live ADCode sign-in and no profile given. run .\adcode-account.ps1 use <email> first.'
        }
    }

    $report = Get-AppReport
    if ($report['running'] -and $Arguments.Count -eq 0) {
        $already = @{}
        $already['ok'] = $true
        $already['action'] = 'already-running'
        $already['message'] = 'ADCode is already running.'
        return $already
    }

    $started = Start-App -Arguments $Arguments
    $result = @{}
    $result['ok'] = $true
    $result['action'] = 'ran'
    $result['pid'] = $started['pid']
    $result['message'] = "started ADCode (pid $($started['pid']))$(if ($Arguments.Count -gt 0) { " with $($Arguments.Count) argument(s)" })."
    return $result
}

function Show-Env {
    param([AllowNull()][string]$Profile)

    $normalized = Get-ProfileOrActive -Profile $Profile
    Write-Host "`$env:ADCODE_USER_DATA_DIR = '$(Get-UserData)'"
    Write-Host "live identity = '$(Get-LiveIdentityFile)'"
    Write-Host "profile store = '$accountRoot'"
    Write-Host "profile = '$normalized'"
    Write-Host "profile identity = '$(Join-Path (Get-ProfilePath -Profile $normalized) $identityRelative)'"
    try {
        Write-Host "app = '$(Get-AppExecutable -Processes @(Get-AppProcesses))'"
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
            Write-Host "  providers: $((@($result.providers)) -join ', ')"
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
        }
    }

    'use' {
        if ($remaining.Count -ne 1) {
            throw 'Usage: .\adcode-account.ps1 use <email>'
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
            Write-Host "identity file: $($report['live']['identityFile'])"
            Write-Host "app: $(if ($report['app']['running']) { "running ($($report['app']['windows']) windows)" } else { 'not running' })"
        }
    }

    'status-all' {
        $report = Get-StatusReport
        Emit -Payload $report -Human {
            if (@($report['profiles']).Count -eq 0) {
                Write-Host 'No ADCode profiles found. open ADCode, sign in with a linked account, then run .\adcode-account.ps1 harvest.'
                Write-Host "live: $($report['live']['detail'])"
                return
            }

            $report['profiles'] |
                Select-Object email, state, isActive, isLive, tokenFingerprint, savedAt |
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
                Write-Host 'No ADCode profiles found.'
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
                Write-Host 'No active ADCode email profile set.'
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
        $payload['identityFile'] = Join-Path $folder $identityRelative
        Emit -Payload $payload -Human { Write-Host $folder }
    }

    'env' {
        $profile = if ($remaining.Count -ge 1) { $remaining[0] } else { $null }
        if ($useJson) {
            $normalized = Get-ProfileOrActive -Profile $profile
            $folder = Get-ProfilePath -Profile $normalized
            $payload = @{}
            $payload['ok'] = $true
            $payload['action'] = 'env'
            $payload['profile'] = $normalized
            $payload['userData'] = Get-UserData
            $payload['identityFile'] = Get-LiveIdentityFile
            $payload['accountRoot'] = $accountRoot
            $payload['folder'] = $folder
            $payload['profileIdentityFile'] = (Join-Path $folder $identityRelative)
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
            throw 'Usage: .\adcode-account.ps1 forget <email>'
        }

        $result = Invoke-Forget -Profile $remaining[0]
        Emit -Payload $result -Human { Write-Host $result.message }
    }

    default {
        Show-Usage
        throw "Unknown command: $command"
    }
}
