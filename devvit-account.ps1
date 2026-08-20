$ErrorActionPreference = 'Stop'

$accountRoot = Join-Path $env:APPDATA 'mainframe\accounts\devvit'
$currentFile = Join-Path $accountRoot 'current.json'
$officialDevvitDir = Join-Path $env:USERPROFILE '.devvit'
$officialTokenPath = Join-Path $officialDevvitDir 'token'

function Show-Usage {
    @(
        'Devvit account profile helper',
        '',
        'Profiles are keyed by account email only and stored in:',
        '  %APPDATA%\mainframe\accounts\devvit\<email>',
        '',
        'Devvit stores its CLI auth token at:',
        '  %USERPROFILE%\.devvit\token',
        '',
        'Devvit does not currently document a per-profile config directory setting.',
        'This helper swaps the official token file safely and stores profile copies',
        'under mainframe account profiles.',
        '',
        'Usage:',
        '  .\devvit-account.ps1 login <email> [devvit login args...]',
        '  .\devvit-account.ps1 import-current <email>',
        '  .\devvit-account.ps1 use <email>',
        '  .\devvit-account.ps1 run [email] <devvit args...>',
        '  .\devvit-account.ps1 whoami [email]',
        '  .\devvit-account.ps1 apps [email]',
        '  .\devvit-account.ps1 installs [email] [subreddit]',
        '  .\devvit-account.ps1 status [email]',
        '  .\devvit-account.ps1 status-all',
        '  .\devvit-account.ps1 list',
        '  .\devvit-account.ps1 current',
        '  .\devvit-account.ps1 path [email]',
        '  .\devvit-account.ps1 token-path [email]',
        '  .\devvit-account.ps1 env [email]',
        '  .\devvit-account.ps1 logout <email>',
        '',
        'Examples:',
        '  .\devvit-account.ps1 login user@example.com --copy-paste',
        '  .\devvit-account.ps1 import-current user@example.com',
        '  .\devvit-account.ps1 use user@example.com',
        '  .\devvit-account.ps1 run user@example.com whoami',
        '  .\devvit-account.ps1 run whoami',
        '  .\devvit-account.ps1 apps user@example.com',
        '  .\devvit-account.ps1 installs user@example.com mySubreddit'
    ) -join [Environment]::NewLine | Write-Host
}

function Normalize-ProfileName {
    param([string]$Profile)

    if ([string]::IsNullOrWhiteSpace($Profile)) {
        throw 'Email profile is required.'
    }

    $normalized = $Profile.Trim().ToLowerInvariant()
    if ($normalized.StartsWith('u/')) {
        throw "Devvit profile must be an account email, not a Reddit username: $Profile"
    }

    if ($normalized -notmatch '^[^\s@]+@[^\s@]+\.[^\s@]+$') {
        throw "Devvit profile must be an account email, not a label or username: $Profile"
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

    $normalized = Normalize-ProfileName -Profile $Profile
    return Join-Path $accountRoot $normalized
}

function Get-ProfileTokenPath {
    param([string]$ProfilePath)

    return Join-Path $ProfilePath 'token'
}

function Get-DevvitInvocation {
    $devvit = Get-Command devvit -ErrorAction SilentlyContinue
    if ($devvit) {
        return [pscustomobject]@{
            Command = $devvit.Source
            Prefix = @()
        }
    }

    $npx = Get-Command npx -ErrorAction SilentlyContinue
    if ($npx) {
        return [pscustomobject]@{
            Command = $npx.Source
            Prefix = @('devvit')
        }
    }

    throw 'Devvit CLI was not found. Install Node.js/npm, then use the official path: npx devvit <command>.'
}

function Invoke-DevvitCommand {
    param([string[]]$DevvitArgs)

    $invocation = Get-DevvitInvocation
    $allArgs = @($invocation.Prefix) + @($DevvitArgs)
    & $invocation.Command @allArgs
    if ($LASTEXITCODE -ne 0) {
        throw "devvit $($DevvitArgs -join ' ') failed with exit code $LASTEXITCODE"
    }
}

function Invoke-DevvitCommandCapture {
    param([string[]]$DevvitArgs)

    $invocation = Get-DevvitInvocation
    $allArgs = @($invocation.Prefix) + @($DevvitArgs)
    $output = @(& $invocation.Command @allArgs 2>&1)
    if ($LASTEXITCODE -ne 0) {
        $output | ForEach-Object { Write-Host $_ }
        throw "devvit $($DevvitArgs -join ' ') failed with exit code $LASTEXITCODE"
    }

    return ($output -join [Environment]::NewLine)
}

function Find-DevvitProfileInText {
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }

    $userMatch = [regex]::Match($Text, '\bu\/([A-Za-z0-9_-]{3,20})\b')
    if ($userMatch.Success) {
        return Normalize-ProfileName -Profile $userMatch.Groups[1].Value
    }

    $loggedInMatch = [regex]::Match($Text, 'logged\s+in\s+as\s+([A-Za-z0-9_-]{3,20})', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($loggedInMatch.Success) {
        return Normalize-ProfileName -Profile $loggedInMatch.Groups[1].Value
    }

    return $null
}

function Resolve-LoggedInDevvitProfile {
    $whoamiOutput = Invoke-DevvitCommandCapture -DevvitArgs @('whoami')
    $profile = Find-DevvitProfileInText -Text $whoamiOutput
    if ($profile) {
        return $profile
    }

    return $null
}

function Write-ProfileMetadata {
    param(
        [string]$Profile,
        [string]$ProfilePath
    )

    New-Item -ItemType Directory -Force -Path $ProfilePath | Out-Null
    [ordered]@{
        tool = 'devvit'
        profile = $Profile
        tokenPath = (Get-ProfileTokenPath -ProfilePath $ProfilePath)
        officialTokenPath = $officialTokenPath
        updatedAt = (Get-Date).ToString('o')
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $ProfilePath 'profile.json') -Encoding UTF8
}

function Set-ActiveProfile {
    param([string]$Profile)

    $normalized = Normalize-ProfileName -Profile $Profile
    New-Item -ItemType Directory -Force -Path $accountRoot | Out-Null
    [ordered]@{
        tool = 'devvit'
        profile = $normalized
        updatedAt = (Get-Date).ToString('o')
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $currentFile -Encoding UTF8
}

function Get-ActiveProfile {
    if (-not (Test-Path -LiteralPath $currentFile)) {
        return $null
    }

    $current = Get-Content -LiteralPath $currentFile -Raw | ConvertFrom-Json
    try {
        return Normalize-ProfileName -Profile ([string]$current.profile)
    } catch {
        return $null
    }
}

function Get-ProfileOrActive {
    param([AllowNull()][string]$Profile)

    if (-not [string]::IsNullOrWhiteSpace($Profile)) {
        return Normalize-ProfileName -Profile $Profile
    }

    $active = Get-ActiveProfile
    if (-not $active) {
        throw 'No email was provided and no active Devvit email profile is set. Run .\devvit-account.ps1 use <email>.'
    }

    return Normalize-ProfileName -Profile $active
}

function Test-TokenFilesMatch {
    param(
        [string]$LeftPath,
        [string]$RightPath
    )

    if (-not (Test-Path -LiteralPath $LeftPath) -or -not (Test-Path -LiteralPath $RightPath)) {
        return $false
    }

    $leftHash = (Get-FileHash -LiteralPath $LeftPath -Algorithm SHA256).Hash
    $rightHash = (Get-FileHash -LiteralPath $RightPath -Algorithm SHA256).Hash
    return $leftHash -eq $rightHash
}

function Save-OfficialTokenSnapshot {
    param([string]$Reason)

    if (-not (Test-Path -LiteralPath $officialTokenPath)) {
        return
    }

    $backupRoot = Join-Path $accountRoot '_token-backups'
    New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null
    $backupPath = Join-Path $backupRoot "token-$Reason-$(Get-Date -Format 'yyyyMMdd-HHmmss').bak"
    Copy-Item -LiteralPath $officialTokenPath -Destination $backupPath -Force
    Write-Host "Existing Devvit token snapshot saved under: $backupRoot"
}

function Save-OfficialTokenToActiveProfile {
    $active = Get-ActiveProfile
    if (-not $active) {
        return
    }

    if (-not (Test-Path -LiteralPath $officialTokenPath)) {
        return
    }

    $activeProfilePath = Get-ProfilePath -Profile $active
    if (-not (Test-Path -LiteralPath $activeProfilePath)) {
        return
    }

    $activeTokenPath = Get-ProfileTokenPath -ProfilePath $activeProfilePath
    Copy-Item -LiteralPath $officialTokenPath -Destination $activeTokenPath -Force
    Write-ProfileMetadata -Profile $active -ProfilePath $activeProfilePath
}

function Install-ProfileToken {
    param([string]$Profile)

    $normalized = Normalize-ProfileName -Profile $Profile
    $profilePath = Get-ProfilePath -Profile $normalized
    $profileTokenPath = Get-ProfileTokenPath -ProfilePath $profilePath

    if (-not (Test-Path -LiteralPath $profileTokenPath)) {
        throw "Devvit profile token does not exist yet: $normalized. Run .\devvit-account.ps1 login $normalized first."
    }

    $active = Get-ActiveProfile
    if ($active -and $active -ne $normalized) {
        Save-OfficialTokenToActiveProfile
    } elseif (-not $active -and (Test-Path -LiteralPath $officialTokenPath) -and -not (Test-TokenFilesMatch -LeftPath $officialTokenPath -RightPath $profileTokenPath)) {
        Save-OfficialTokenSnapshot -Reason 'unmanaged'
    }

    New-Item -ItemType Directory -Force -Path $officialDevvitDir | Out-Null
    Copy-Item -LiteralPath $profileTokenPath -Destination $officialTokenPath -Force
    Write-ProfileMetadata -Profile $normalized -ProfilePath $profilePath
    Set-ActiveProfile -Profile $normalized
}

function Invoke-DevvitProfile {
    param(
        [string]$Profile,
        [string[]]$DevvitArgs
    )

    $normalized = Normalize-ProfileName -Profile $Profile
    Install-ProfileToken -Profile $normalized
    try {
        Invoke-DevvitCommand -DevvitArgs $DevvitArgs
    } finally {
        if (Test-Path -LiteralPath $officialTokenPath) {
            $profilePath = Get-ProfilePath -Profile $normalized
            $profileTokenPath = Get-ProfileTokenPath -ProfilePath $profilePath
            Copy-Item -LiteralPath $officialTokenPath -Destination $profileTokenPath -Force
            Write-ProfileMetadata -Profile $normalized -ProfilePath $profilePath
        }
    }
}

function Get-ProfileStatus {
    param([string]$Profile)

    $normalized = Normalize-ProfileName -Profile $Profile
    $profilePath = Get-ProfilePath -Profile $normalized
    $profileTokenPath = Get-ProfileTokenPath -ProfilePath $profilePath
    $exists = Test-Path -LiteralPath $profilePath
    $hasToken = Test-Path -LiteralPath $profileTokenPath
    $hasOfficialToken = Test-Path -LiteralPath $officialTokenPath
    $active = Get-ActiveProfile

    [pscustomobject]@{
        Profile = $normalized
        Exists = $exists
        IsActive = ($active -eq $normalized)
        HasToken = $hasToken
        OfficialTokenInstalled = (Test-TokenFilesMatch -LeftPath $officialTokenPath -RightPath $profileTokenPath)
        ProfilePath = $profilePath
        TokenPath = $profileTokenPath
        OfficialTokenPath = $officialTokenPath
        State = if (-not $exists) { 'missing-profile' } elseif (-not $hasToken) { 'missing-token' } elseif (-not $hasOfficialToken) { 'profile-saved' } elseif ($active -eq $normalized) { 'active' } else { 'saved' }
    }
}

function Get-ProfileName {
    param([IO.DirectoryInfo]$Directory)

    $metadataPath = Join-Path $Directory.FullName 'profile.json'
    if (Test-Path -LiteralPath $metadataPath) {
        try {
            $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
            if ($metadata.profile) {
                return [string]$metadata.profile
            }
        } catch {
            Write-Warning "Could not read profile metadata: $metadataPath"
        }
    }

    return $Directory.Name
}

function Remove-Profile {
    param([string]$Profile)

    $normalized = Normalize-ProfileName -Profile $Profile
    $profilePath = Get-ProfilePath -Profile $normalized
    if (-not (Test-Path -LiteralPath $profilePath)) {
        Write-Host "Devvit profile does not exist: $normalized"
        return
    }

    $profileTokenPath = Get-ProfileTokenPath -ProfilePath $profilePath
    $officialMatches = Test-TokenFilesMatch -LeftPath $officialTokenPath -RightPath $profileTokenPath
    $backupPath = "$profilePath.logged-out-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Move-Item -LiteralPath $profilePath -Destination $backupPath
    Write-Host "Devvit profile moved to: $backupPath"

    $active = Get-ActiveProfile
    if ($active -eq $normalized -and (Test-Path -LiteralPath $currentFile)) {
        Remove-Item -LiteralPath $currentFile
        Write-Host 'Active Devvit profile cleared.'
    }

    if ($officialMatches -and (Test-Path -LiteralPath $officialTokenPath)) {
        $officialBackup = Join-Path $officialDevvitDir "token.logged-out-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Move-Item -LiteralPath $officialTokenPath -Destination $officialBackup
        Write-Host 'Official Devvit token was moved aside because it matched the logged-out profile.'
    }
}

$command = if ($args.Count -gt 0) { $args[0].ToLowerInvariant() } else { 'help' }
$remaining = @($args | Select-Object -Skip 1)

switch ($command) {
    'help' {
        Show-Usage
    }

    { $_ -in @('login', 'add') } {
        $profile = $null
        $loginArgs = @()
        if ($remaining.Count -gt 0 -and $remaining[0] -notlike '-*') {
            $profile = Normalize-ProfileName -Profile $remaining[0]
            $loginArgs = @($remaining | Select-Object -Skip 1)
        } else {
            throw 'Usage: .\devvit-account.ps1 login <email> [devvit login args...]'
        }

        $displayProfile = $profile
        Save-OfficialTokenToActiveProfile
        if (Test-Path -LiteralPath $officialTokenPath) {
            Save-OfficialTokenSnapshot -Reason 'before-login'
        }

        Write-Host "Opening Reddit Devvit browser login for profile: $displayProfile"
        Invoke-DevvitCommand -DevvitArgs (@('login') + $loginArgs)

        if (-not (Test-Path -LiteralPath $officialTokenPath)) {
            throw "Devvit login completed, but the official token file was not found at $officialTokenPath"
        }

        $profilePath = Get-ProfilePath -Profile $profile
        New-Item -ItemType Directory -Force -Path $profilePath | Out-Null
        Copy-Item -LiteralPath $officialTokenPath -Destination (Get-ProfileTokenPath -ProfilePath $profilePath) -Force
        Write-ProfileMetadata -Profile $profile -ProfilePath $profilePath
        Set-ActiveProfile -Profile $profile
        Write-Host "Devvit profile is ready and active: $profile"
    }

    'import-current' {
        if ($remaining.Count -ne 1) {
            throw 'Usage: .\devvit-account.ps1 import-current <email>'
        }

        if (-not (Test-Path -LiteralPath $officialTokenPath)) {
            throw "No current Devvit token found at $officialTokenPath. Run npx devvit login first, or use .\devvit-account.ps1 login <email>."
        }

        $profile = Normalize-ProfileName -Profile $remaining[0]
        $profilePath = Get-ProfilePath -Profile $profile
        New-Item -ItemType Directory -Force -Path $profilePath | Out-Null
        Copy-Item -LiteralPath $officialTokenPath -Destination (Get-ProfileTokenPath -ProfilePath $profilePath) -Force
        Write-ProfileMetadata -Profile $profile -ProfilePath $profilePath
        Set-ActiveProfile -Profile $profile
        Write-Host "Current Devvit token imported as active profile: $profile"
    }

    'use' {
        if ($remaining.Count -ne 1) {
            throw 'Usage: .\devvit-account.ps1 use <email>'
        }

        $profile = Normalize-ProfileName -Profile $remaining[0]
        Install-ProfileToken -Profile $profile
        Write-Host "Active Devvit profile: $profile"
    }

    'run' {
        if ($remaining.Count -lt 1) {
            throw 'Usage: .\devvit-account.ps1 run [email] <devvit args...>'
        }

        if (Test-LooksLikeEmail -Value $remaining[0]) {
            if ($remaining.Count -lt 2) {
                throw 'Usage: .\devvit-account.ps1 run [email] <devvit args...>'
            }

            $profile = Normalize-ProfileName -Profile $remaining[0]
            $devvitArgs = @($remaining | Select-Object -Skip 1)
        } else {
            $profile = Get-ProfileOrActive -Profile $null
            $devvitArgs = @($remaining)
        }

        Invoke-DevvitProfile -Profile $profile -DevvitArgs $devvitArgs
    }

    'whoami' {
        $profile = Get-ProfileOrActive -Profile $(if ($remaining.Count -ge 1) { $remaining[0] } else { $null })
        Invoke-DevvitProfile -Profile $profile -DevvitArgs @('whoami')
    }

    'apps' {
        $profile = Get-ProfileOrActive -Profile $(if ($remaining.Count -ge 1) { $remaining[0] } else { $null })
        Invoke-DevvitProfile -Profile $profile -DevvitArgs @('list', 'apps')
    }

    'installs' {
        $profile = Get-ProfileOrActive -Profile $(if ($remaining.Count -ge 1) { $remaining[0] } else { $null })
        $installArgs = @('list', 'installs')
        if ($remaining.Count -ge 2) {
            $installArgs += $remaining[1]
        }

        Invoke-DevvitProfile -Profile $profile -DevvitArgs $installArgs
    }

    'status' {
        $profile = Get-ProfileOrActive -Profile $(if ($remaining.Count -ge 1) { $remaining[0] } else { $null })
        Get-ProfileStatus -Profile $profile | Format-List
    }

    'status-all' {
        if (-not (Test-Path -LiteralPath $accountRoot)) {
            Write-Host 'No Devvit profiles found.'
            return
        }

        $profiles = @(Get-ChildItem -LiteralPath $accountRoot -Directory -Force | Where-Object { $_.Name -match '^[^\s@]+@[^\s@]+\.[^\s@]+$' } | Sort-Object Name)
        if ($profiles.Count -eq 0) {
            Write-Host 'No Devvit profiles found.'
            return
        }

        $profiles |
            ForEach-Object { Get-ProfileStatus -Profile (Get-ProfileName -Directory $_) } |
            Format-Table -AutoSize
    }

    'list' {
        if (-not (Test-Path -LiteralPath $accountRoot)) {
            Write-Host 'No Devvit profiles found.'
            return
        }

        $active = Get-ActiveProfile
        $profiles = @(Get-ChildItem -LiteralPath $accountRoot -Directory -Force | Where-Object { -not $_.Name.StartsWith('_') -and $_.Name -match '^[^\s@]+@[^\s@]+\.[^\s@]+$' } | Sort-Object Name)
        if ($profiles.Count -eq 0) {
            Write-Host 'No Devvit profiles found.'
            return
        }

        foreach ($profileDir in $profiles) {
            $profile = Get-ProfileName -Directory $profileDir
            $marker = if ($profile -eq $active) { '*' } else { ' ' }
            Write-Host "$marker $profile"
        }
    }

    'current' {
        $active = Get-ActiveProfile
        if ($active) {
            Write-Host $active
        } else {
            Write-Host 'No active Devvit email profile set.'
        }
    }

    'path' {
        $profile = Get-ProfileOrActive -Profile $(if ($remaining.Count -ge 1) { $remaining[0] } else { $null })
        Write-Host (Get-ProfilePath -Profile $profile)
    }

    'token-path' {
        $profile = Get-ProfileOrActive -Profile $(if ($remaining.Count -ge 1) { $remaining[0] } else { $null })
        $profilePath = Get-ProfilePath -Profile $profile
        Write-Host (Get-ProfileTokenPath -ProfilePath $profilePath)
    }

    'env' {
        $profile = Get-ProfileOrActive -Profile $(if ($remaining.Count -ge 1) { $remaining[0] } else { $null })
        $profilePath = Get-ProfilePath -Profile $profile
        $tokenPath = Get-ProfileTokenPath -ProfilePath $profilePath
        $tokenState = if (Test-Path -LiteralPath $tokenPath) { '<profile token>' } else { '<missing token>' }
        Write-Host "Devvit has no documented per-profile env var; use .\devvit-account.ps1 run [email] <devvit args...>."
        Write-Host "`$env:DEVVIT_MAINFRAME_PROFILE = '$profile'"
        Write-Host "`$env:DEVVIT_MAINFRAME_TOKEN_PATH = '$tokenPath'"
        Write-Host "`$env:DEVVIT_OFFICIAL_TOKEN_PATH = '$officialTokenPath'"
        Write-Host "DEVVIT_TOKEN = $tokenState"
    }

    'logout' {
        if ($remaining.Count -ne 1) {
            throw 'Usage: .\devvit-account.ps1 logout <email>'
        }

        Remove-Profile -Profile $remaining[0]
    }

    default {
        Show-Usage
        throw "Unknown command: $command"
    }
}
