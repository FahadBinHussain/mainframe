$ErrorActionPreference = 'Stop'

$accountRoot = Join-Path $env:APPDATA 'mainframe\accounts\firebase'
$currentFile = Join-Path $accountRoot 'current.json'
$defaultConfigRoot = Join-Path $env:USERPROFILE '.config'
$defaultConfigPath = Join-Path $defaultConfigRoot 'configstore\firebase-tools.json'

function Show-Usage {
    @'
Firebase CLI account profile helper

Profiles are keyed by email and stored in:
  %APPDATA%\mainframe\accounts\firebase\<email>

Each profile is a Firebase CLI configstore selected with XDG_CONFIG_HOME.

Usage:
  .\firebase-account.ps1 login [email] [firebase login args...]
  .\firebase-account.ps1 reauth [email] [firebase login args...]
  .\firebase-account.ps1 import-current [email]
  .\firebase-account.ps1 use <email>
  .\firebase-account.ps1 run [email] <firebase args...>
  .\firebase-account.ps1 mcp [email] [firebase mcp args...]
  .\firebase-account.ps1 whoami [email]
  .\firebase-account.ps1 projects [email]
  .\firebase-account.ps1 projects-json [email]
  .\firebase-account.ps1 apps [email] <project-id> [WEB|ANDROID|IOS]
  .\firebase-account.ps1 sdkconfig [email] <project-id> <platform> <app-id>
  .\firebase-account.ps1 web-config [email] <project-id> <web-app-id>
  .\firebase-account.ps1 capabilities [email]
  .\firebase-account.ps1 capabilities-json [email]
  .\firebase-account.ps1 status [email]
  .\firebase-account.ps1 status-all
  .\firebase-account.ps1 list
  .\firebase-account.ps1 current
  .\firebase-account.ps1 path [email]
  .\firebase-account.ps1 env [email]
  .\firebase-account.ps1 logout [email]

Examples:
  .\firebase-account.ps1 import-current
  .\firebase-account.ps1 use user@example.com
  .\firebase-account.ps1 run user@example.com projects:list
  .\firebase-account.ps1 run projects:list
  .\firebase-account.ps1 run user@example.com init auth
  .\firebase-account.ps1 run user@example.com deploy --only auth
  .\firebase-account.ps1 apps user@example.com my-project WEB
  .\firebase-account.ps1 web-config user@example.com my-project 1:123:web:abc
  .\firebase-account.ps1 mcp user@example.com --only core,firestore
'@ | Write-Host
}

function Normalize-Email {
    param([string]$Email)

    if ([string]::IsNullOrWhiteSpace($Email)) {
        throw 'Email is required.'
    }

    $normalized = $Email.Trim().ToLowerInvariant()
    if ($normalized -notmatch '^[^\s@]+@[^\s@]+\.[^\s@]+$') {
        throw "Firebase profile must be an account email, not a username, project, or label: $Email"
    }

    foreach ($char in [IO.Path]::GetInvalidFileNameChars()) {
        $invalidChar = [string]$char
        if ([string]::IsNullOrEmpty($invalidChar)) {
            continue
        }

        if ($normalized.IndexOf($invalidChar, [StringComparison]::Ordinal) -ge 0) {
            throw "Email contains a character that cannot be used in a Windows folder name: $Email"
        }
    }

    return $normalized
}

function Test-LooksLikeEmail {
    param([AllowNull()][string]$Value)

    return (-not [string]::IsNullOrWhiteSpace($Value)) -and ($Value -match '^[^\s@]+@[^\s@]+\.[^\s@]+$')
}

function Get-ProfilePath {
    param([string]$Email)

    $normalized = Normalize-Email -Email $Email
    return Join-Path $accountRoot $normalized
}

function Get-ProfileConfigPath {
    param([string]$ProfilePath)

    return Join-Path $ProfilePath 'configstore\firebase-tools.json'
}

function Get-FirebaseCommand {
    $cmd = Get-Command firebase -ErrorAction SilentlyContinue
    if ($cmd) {
        return $cmd.Source
    }

    throw 'Firebase CLI was not found. Install it with: pnpm add -g firebase-tools'
}

function Set-ActiveEmail {
    param([string]$Email)

    $normalized = Normalize-Email -Email $Email
    New-Item -ItemType Directory -Force -Path $accountRoot | Out-Null
    [ordered]@{
        tool = 'firebase'
        email = $normalized
        updatedAt = (Get-Date).ToString('o')
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $currentFile -Encoding UTF8
}

function Get-ActiveEmail {
    if (-not (Test-Path -LiteralPath $currentFile)) {
        return $null
    }

    try {
        $current = Get-Content -LiteralPath $currentFile -Raw | ConvertFrom-Json
        return Normalize-Email -Email ([string]$current.email)
    } catch {
        return $null
    }
}

function Get-EmailOrActive {
    param([AllowNull()][string]$Email)

    if (-not [string]::IsNullOrWhiteSpace($Email)) {
        return Normalize-Email -Email $Email
    }

    $active = Get-ActiveEmail
    if (-not $active) {
        throw 'No email was provided and no active Firebase profile is set. Run .\firebase-account.ps1 use <email>.'
    }

    return $active
}

function Get-ProfileEmail {
    param([IO.DirectoryInfo]$Directory)

    return Normalize-Email -Email $Directory.Name
}

function Write-ProfileMetadata {
    param(
        [string]$Email,
        [string]$ProfilePath
    )

    New-Item -ItemType Directory -Force -Path $ProfilePath | Out-Null
    [ordered]@{
        tool = 'firebase'
        email = $Email
        xdgConfigHome = $ProfilePath
        configPath = (Get-ProfileConfigPath -ProfilePath $ProfilePath)
        updatedAt = (Get-Date).ToString('o')
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $ProfilePath 'profile.json') -Encoding UTF8
}

function Invoke-WithFirebaseConfig {
    param(
        [string]$ConfigRoot,
        [scriptblock]$Script
    )

    $oldXdg = $env:XDG_CONFIG_HOME
    $oldDisableUpdate = $env:FIREBASE_CLI_DISABLE_UPDATE_NOTIFIER
    $oldNoUpdateNotifier = $env:NO_UPDATE_NOTIFIER

    try {
        New-Item -ItemType Directory -Force -Path $ConfigRoot | Out-Null
        $env:XDG_CONFIG_HOME = $ConfigRoot
        $env:FIREBASE_CLI_DISABLE_UPDATE_NOTIFIER = '1'
        $env:NO_UPDATE_NOTIFIER = '1'
        & $Script
    } finally {
        if ($null -eq $oldXdg) {
            Remove-Item Env:\XDG_CONFIG_HOME -ErrorAction SilentlyContinue
        } else {
            $env:XDG_CONFIG_HOME = $oldXdg
        }

        if ($null -eq $oldDisableUpdate) {
            Remove-Item Env:\FIREBASE_CLI_DISABLE_UPDATE_NOTIFIER -ErrorAction SilentlyContinue
        } else {
            $env:FIREBASE_CLI_DISABLE_UPDATE_NOTIFIER = $oldDisableUpdate
        }

        if ($null -eq $oldNoUpdateNotifier) {
            Remove-Item Env:\NO_UPDATE_NOTIFIER -ErrorAction SilentlyContinue
        } else {
            $env:NO_UPDATE_NOTIFIER = $oldNoUpdateNotifier
        }
    }
}

function Invoke-WithFirebaseProfile {
    param(
        [string]$Email,
        [scriptblock]$Script
    )

    $normalized = Normalize-Email -Email $Email
    $profilePath = Get-ProfilePath -Email $normalized
    Invoke-WithFirebaseConfig -ConfigRoot $profilePath -Script $Script
}

function Invoke-FirebaseProfile {
    param(
        [string]$Email,
        [string[]]$FirebaseArgs
    )

    $firebase = Get-FirebaseCommand
    Invoke-WithFirebaseProfile -Email $Email -Script {
        & $firebase @FirebaseArgs
        if ($LASTEXITCODE -ne 0) {
            throw "firebase failed with exit code $LASTEXITCODE"
        }
    }
}

function Split-OptionalEmail {
    param([string[]]$Values)

    if ($Values.Count -gt 0 -and (Test-LooksLikeEmail -Value $Values[0])) {
        return [pscustomobject]@{
            Email = Normalize-Email -Email $Values[0]
            Rest = @($Values | Select-Object -Skip 1)
        }
    }

    return [pscustomobject]@{
        Email = Get-EmailOrActive -Email $null
        Rest = @($Values)
    }
}

function Invoke-FirebaseJsonCommand {
    param(
        [string]$Email,
        [string[]]$FirebaseArgs
    )

    Invoke-FirebaseProfile -Email $Email -FirebaseArgs @($FirebaseArgs + @('--json'))
}

function Get-FirebaseCliVersion {
    $firebase = Get-FirebaseCommand
    $output = @(& $firebase --version 2>$null)
    if ($output.Count -gt 0) {
        return (($output | Select-Object -First 1) -as [string]).Trim()
    }

    return $null
}

function Get-FirebaseCapabilities {
    param([string]$Email)

    $status = Get-ProfileStatus -Email $Email
    [pscustomobject]@{
        Email = $status.Email
        State = $status.State
        HasConfig = $status.HasConfig
        Accounts = $status.Accounts
        FirebaseCliVersion = Get-FirebaseCliVersion
        OfficialSurfaces = @(
            'Firebase CLI with isolated XDG_CONFIG_HOME profile',
            'Firebase CLI MCP server through the same saved profile',
            'Firebase project/app management commands',
            'Firebase deploy/emulator/auth/firestore/hosting/apphosting/dataconnect commands through run'
        )
        ShortcutCommands = @(
            'projects-json',
            'apps',
            'sdkconfig',
            'web-config',
            'mcp',
            'reauth'
        )
        DefaultCredentialRule = 'Use Firebase CLI OAuth profiles keyed by detected email; refresh stale saved credentials with firebase login --reauth inside the same profile.'
        ScopeRule = 'Firebase CLI does not expose a manual scope-selection flag; it requests the official scopes needed by each command.'
    }
}

function Write-FirebaseCapabilities {
    param([string]$Email)

    $capabilities = Get-FirebaseCapabilities -Email $Email
    Write-Host "Firebase capabilities for $Email"
    $capabilities | Select-Object Email, State, HasConfig, Accounts, FirebaseCliVersion | Format-List

    Write-Host 'Official surfaces:'
    foreach ($surface in $capabilities.OfficialSurfaces) {
        Write-Host "  - $surface"
    }

    Write-Host 'Shortcut commands:'
    foreach ($command in $capabilities.ShortcutCommands) {
        Write-Host "  - $command"
    }

    Write-Host "Default credential rule: $($capabilities.DefaultCredentialRule)"
    Write-Host "Scope rule: $($capabilities.ScopeRule)"
}

function Find-EmailsInObject {
    param([AllowNull()]$Value)

    $emails = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Value) {
        return @()
    }

    if ($Value -is [string]) {
        foreach ($match in [regex]::Matches($Value, '[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}', [Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
            try {
                $emails.Add((Normalize-Email -Email $match.Value))
            } catch {
            }
        }

        return @($emails | Select-Object -Unique)
    }

    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        foreach ($item in $Value) {
            foreach ($email in (Find-EmailsInObject -Value $item)) {
                $emails.Add($email)
            }
        }

        return @($emails | Select-Object -Unique)
    }

    if ($Value.PSObject -and $Value.PSObject.Properties) {
        foreach ($property in $Value.PSObject.Properties) {
            foreach ($email in (Find-EmailsInObject -Value $property.Value)) {
                $emails.Add($email)
            }
        }
    }

    return @($emails | Select-Object -Unique)
}

function Get-FirebaseEmailsFromConfigPath {
    param([string]$ConfigPath)

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        return @()
    }

    try {
        $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    } catch {
        return @()
    }

    $emails = New-Object System.Collections.Generic.List[string]
    if ($config.PSObject.Properties['user'] -and $config.user.PSObject.Properties['email']) {
        $email = [string]$config.user.email
        if (Test-LooksLikeEmail -Value $email) {
            $emails.Add((Normalize-Email -Email $email))
        }
    }

    foreach ($email in (Find-EmailsInObject -Value $config)) {
        if ($emails -notcontains $email) {
            $emails.Add($email)
        }
    }

    return @($emails | Select-Object -Unique)
}

function Get-FirebaseEmailsFromProfile {
    param([string]$ProfilePath)

    $configPath = Get-ProfileConfigPath -ProfilePath $ProfilePath
    return @(Get-FirebaseEmailsFromConfigPath -ConfigPath $configPath)
}

function Copy-DefaultConfigToProfile {
    param(
        [string]$SourcePath,
        [string]$DestinationProfilePath
    )

    if (-not (Test-Path -LiteralPath $SourcePath)) {
        throw "Firebase CLI config was not found: $SourcePath"
    }

    if (Test-Path -LiteralPath $DestinationProfilePath) {
        $backupPath = "$DestinationProfilePath.backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Move-Item -LiteralPath $DestinationProfilePath -Destination $backupPath
        Write-Host "Existing Firebase profile moved to: $backupPath"
    }

    $destinationConfigPath = Get-ProfileConfigPath -ProfilePath $DestinationProfilePath
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destinationConfigPath) | Out-Null
    Copy-Item -LiteralPath $SourcePath -Destination $destinationConfigPath -Force
}

function Move-ProfileDirectory {
    param(
        [string]$Source,
        [string]$Destination
    )

    if (Test-Path -LiteralPath $Destination) {
        $backupPath = "$Destination.backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Move-Item -LiteralPath $Destination -Destination $backupPath
        Write-Host "Existing Firebase profile moved to: $backupPath"
    }

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Destination) | Out-Null
    Move-Item -LiteralPath $Source -Destination $Destination
}

function Import-CurrentProfile {
    param([AllowNull()][string]$Email)

    $emails = @(Get-FirebaseEmailsFromConfigPath -ConfigPath $defaultConfigPath)
    $targetEmail = if ([string]::IsNullOrWhiteSpace($Email)) {
        if ($emails.Count -eq 1) {
            $emails[0]
        } elseif ($emails.Count -gt 1) {
            throw "Default Firebase config has multiple emails. Pass one explicitly: $($emails -join ', ')"
        } else {
            $null
        }
    } else {
        Normalize-Email -Email $Email
    }

    if (-not $targetEmail) {
        throw 'Could not detect a Firebase account email. Pass it explicitly: .\firebase-account.ps1 import-current <email>'
    }

    if ($emails.Count -gt 0 -and $emails -notcontains $targetEmail) {
        throw "Default Firebase config does not contain $targetEmail. Detected: $($emails -join ', ')"
    }

    $profilePath = Get-ProfilePath -Email $targetEmail
    Copy-DefaultConfigToProfile -SourcePath $defaultConfigPath -DestinationProfilePath $profilePath
    Write-ProfileMetadata -Email $targetEmail -ProfilePath $profilePath
    Set-ActiveEmail -Email $targetEmail
    Write-Host "Firebase profile imported and active: $targetEmail"
}

function Login-Profile {
    param(
        [AllowNull()][string]$Email,
        [string[]]$LoginArgs
    )

    $firebase = Get-FirebaseCommand
    $targetEmail = if ([string]::IsNullOrWhiteSpace($Email)) { $null } else { Normalize-Email -Email $Email }
    $profilePath = if ($targetEmail) {
        Get-ProfilePath -Email $targetEmail
    } else {
        Join-Path $env:TEMP "mainframe-firebase-login-$([Guid]::NewGuid().ToString('N'))"
    }

    New-Item -ItemType Directory -Force -Path $profilePath | Out-Null
    Write-Host 'Starting Firebase CLI login inside an isolated mainframe profile.'
    Invoke-WithFirebaseConfig -ConfigRoot $profilePath -Script {
        & $firebase login @LoginArgs
        if ($LASTEXITCODE -ne 0) {
            throw "firebase login failed with exit code $LASTEXITCODE"
        }
    }

    $emails = @(Get-FirebaseEmailsFromProfile -ProfilePath $profilePath)
    if ($emails.Count -eq 0) {
        throw 'Login succeeded, but Firebase account email could not be detected. Refusing to save a project name or label fallback.'
    }

    if ($targetEmail) {
        if ($emails -notcontains $targetEmail) {
            throw "Login did not produce the requested Firebase email profile: $targetEmail. Detected: $($emails -join ', ')"
        }

        $finalEmail = $targetEmail
    } elseif ($emails.Count -eq 1) {
        $finalEmail = $emails[0]
    } else {
        throw "Login produced multiple Firebase accounts. Re-run with the email explicitly: $($emails -join ', ')"
    }

    $finalPath = Get-ProfilePath -Email $finalEmail
    if ($profilePath -ne $finalPath) {
        Move-ProfileDirectory -Source $profilePath -Destination $finalPath
    }

    Write-ProfileMetadata -Email $finalEmail -ProfilePath $finalPath
    Set-ActiveEmail -Email $finalEmail
    Write-Host "Firebase profile ready and active: $finalEmail"
}

function Get-ProfileStatus {
    param([string]$Email)

    $normalized = Normalize-Email -Email $Email
    $profilePath = Get-ProfilePath -Email $normalized
    $exists = Test-Path -LiteralPath $profilePath
    $active = Get-ActiveEmail
    $configPath = Get-ProfileConfigPath -ProfilePath $profilePath
    $emails = if ($exists) { @(Get-FirebaseEmailsFromProfile -ProfilePath $profilePath) } else { @() }

    [pscustomobject]@{
        Email = $normalized
        Exists = $exists
        IsActive = ($active -eq $normalized)
        XdgConfigHome = $profilePath
        ConfigPath = $configPath
        HasConfig = ($exists -and (Test-Path -LiteralPath $configPath))
        Accounts = ($emails -join ', ')
        State = if (-not $exists) { 'missing-profile' } elseif ($emails -contains $normalized) { 'ready' } elseif ($emails.Count -gt 0) { 'email-mismatch' } else { 'missing-account' }
    }
}

function Remove-Profile {
    param([string]$Email)

    $normalized = Normalize-Email -Email $Email
    $profilePath = Get-ProfilePath -Email $normalized
    if (-not (Test-Path -LiteralPath $profilePath)) {
        Write-Host "Firebase profile does not exist: $normalized"
        return
    }

    $backupPath = "$profilePath.logged-out-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Move-Item -LiteralPath $profilePath -Destination $backupPath
    Write-Host "Firebase profile moved to: $backupPath"

    $active = Get-ActiveEmail
    if ($active -eq $normalized -and (Test-Path -LiteralPath $currentFile)) {
        Remove-Item -LiteralPath $currentFile
        Write-Host 'Active Firebase profile cleared.'
    }
}

$action = if ($args.Count -gt 0) { [string]$args[0] } else { 'help' }
$remaining = @()
if ($args.Count -gt 1) {
    $remaining = @($args[1..($args.Count - 1)])
}

switch ($action.ToLowerInvariant()) {
    'help' {
        Show-Usage
    }

    'login' {
        $email = $null
        $loginArgs = @($remaining)
        if ($remaining.Count -gt 0 -and (Test-LooksLikeEmail -Value $remaining[0])) {
            $email = Normalize-Email -Email $remaining[0]
            $loginArgs = @($remaining | Select-Object -Skip 1)
        }

        Login-Profile -Email $email -LoginArgs $loginArgs
    }

    'reauth' {
        $email = $null
        $loginArgs = @('--reauth')
        if ($remaining.Count -gt 0 -and (Test-LooksLikeEmail -Value $remaining[0])) {
            $email = Normalize-Email -Email $remaining[0]
            $loginArgs += @($remaining | Select-Object -Skip 1)
        } else {
            $email = Get-EmailOrActive -Email $null
            $loginArgs += @($remaining)
        }

        Login-Profile -Email $email -LoginArgs $loginArgs
    }

    'import-current' {
        if ($remaining.Count -gt 1) {
            throw 'Usage: .\firebase-account.ps1 import-current [email]'
        }

        Import-CurrentProfile -Email $(if ($remaining.Count -eq 1) { $remaining[0] } else { $null })
    }

    'use' {
        if ($remaining.Count -ne 1) {
            throw 'Usage: .\firebase-account.ps1 use <email>'
        }

        $email = Normalize-Email -Email $remaining[0]
        $profilePath = Get-ProfilePath -Email $email
        if (-not (Test-Path -LiteralPath $profilePath)) {
            throw "Firebase profile does not exist yet: $email"
        }

        Set-ActiveEmail -Email $email
        Write-Host "Active Firebase profile: $email"
    }

    'run' {
        if ($remaining.Count -lt 1) {
            throw 'Usage: .\firebase-account.ps1 run [email] <firebase args...>'
        }

        if (Test-LooksLikeEmail -Value $remaining[0]) {
            if ($remaining.Count -lt 2) {
                throw 'Usage: .\firebase-account.ps1 run [email] <firebase args...>'
            }

            $email = Normalize-Email -Email $remaining[0]
            $firebaseArgs = @($remaining | Select-Object -Skip 1)
        } else {
            $email = Get-EmailOrActive -Email $null
            $firebaseArgs = @($remaining)
        }

        Invoke-FirebaseProfile -Email $email -FirebaseArgs $firebaseArgs
    }

    'mcp' {
        $parts = Split-OptionalEmail -Values $remaining
        Invoke-FirebaseProfile -Email $parts.Email -FirebaseArgs (@('mcp') + @($parts.Rest))
    }

    'whoami' {
        $email = Get-EmailOrActive -Email $(if ($remaining.Count -ge 1) { $remaining[0] } else { $null })
        Get-ProfileStatus -Email $email | Select-Object Email, Accounts, State | Format-List
    }

    'projects' {
        $email = Get-EmailOrActive -Email $(if ($remaining.Count -ge 1) { $remaining[0] } else { $null })
        Invoke-FirebaseProfile -Email $email -FirebaseArgs @('projects:list')
    }

    'projects-json' {
        if ($remaining.Count -gt 1) {
            throw 'Usage: .\firebase-account.ps1 projects-json [email]'
        }

        $email = Get-EmailOrActive -Email $(if ($remaining.Count -ge 1) { $remaining[0] } else { $null })
        Invoke-FirebaseJsonCommand -Email $email -FirebaseArgs @('projects:list')
    }

    'apps' {
        $parts = Split-OptionalEmail -Values $remaining
        if ($parts.Rest.Count -lt 1 -or $parts.Rest.Count -gt 2) {
            throw 'Usage: .\firebase-account.ps1 apps [email] <project-id> [WEB|ANDROID|IOS]'
        }

        $projectId = $parts.Rest[0]
        $firebaseArgs = @('apps:list')
        if ($parts.Rest.Count -eq 2) {
            $firebaseArgs += $parts.Rest[1]
        }

        $firebaseArgs += @('--project', $projectId)
        Invoke-FirebaseJsonCommand -Email $parts.Email -FirebaseArgs $firebaseArgs
    }

    'sdkconfig' {
        $parts = Split-OptionalEmail -Values $remaining
        if ($parts.Rest.Count -ne 3) {
            throw 'Usage: .\firebase-account.ps1 sdkconfig [email] <project-id> <platform> <app-id>'
        }

        Invoke-FirebaseJsonCommand -Email $parts.Email -FirebaseArgs @('apps:sdkconfig', $parts.Rest[1], $parts.Rest[2], '--project', $parts.Rest[0])
    }

    'web-config' {
        $parts = Split-OptionalEmail -Values $remaining
        if ($parts.Rest.Count -ne 2) {
            throw 'Usage: .\firebase-account.ps1 web-config [email] <project-id> <web-app-id>'
        }

        Invoke-FirebaseJsonCommand -Email $parts.Email -FirebaseArgs @('apps:sdkconfig', 'WEB', $parts.Rest[1], '--project', $parts.Rest[0])
    }

    'capabilities' {
        if ($remaining.Count -gt 1) {
            throw 'Usage: .\firebase-account.ps1 capabilities [email]'
        }

        $email = Get-EmailOrActive -Email $(if ($remaining.Count -ge 1) { $remaining[0] } else { $null })
        Write-FirebaseCapabilities -Email $email
    }

    'capabilities-json' {
        if ($remaining.Count -gt 1) {
            throw 'Usage: .\firebase-account.ps1 capabilities-json [email]'
        }

        $email = Get-EmailOrActive -Email $(if ($remaining.Count -ge 1) { $remaining[0] } else { $null })
        Get-FirebaseCapabilities -Email $email | ConvertTo-Json -Depth 12
    }

    'status' {
        $email = Get-EmailOrActive -Email $(if ($remaining.Count -ge 1) { $remaining[0] } else { $null })
        Get-ProfileStatus -Email $email | Format-List
    }

    'status-all' {
        if (-not (Test-Path -LiteralPath $accountRoot)) {
            Write-Host 'No Firebase profiles found.'
            return
        }

        $profiles = @(Get-ChildItem -LiteralPath $accountRoot -Directory -Force | Where-Object { $_.Name -match '^[^\s@]+@[^\s@]+\.[^\s@]+$' } | Sort-Object Name)
        if ($profiles.Count -eq 0) {
            Write-Host 'No Firebase profiles found.'
            return
        }

        $profiles |
            ForEach-Object { Get-ProfileStatus -Email (Get-ProfileEmail -Directory $_) } |
            Format-Table -AutoSize
    }

    'list' {
        if (-not (Test-Path -LiteralPath $accountRoot)) {
            Write-Host 'No Firebase profiles found.'
            return
        }

        $active = Get-ActiveEmail
        $profiles = @(Get-ChildItem -LiteralPath $accountRoot -Directory -Force | Where-Object { $_.Name -match '^[^\s@]+@[^\s@]+\.[^\s@]+$' } | Sort-Object Name)
        if ($profiles.Count -eq 0) {
            Write-Host 'No Firebase profiles found.'
            return
        }

        foreach ($profile in $profiles) {
            $email = Get-ProfileEmail -Directory $profile
            $marker = if ($email -eq $active) { '*' } else { ' ' }
            Write-Host "$marker $email"
        }
    }

    'current' {
        $active = Get-ActiveEmail
        if ($active) {
            Write-Host $active
        } else {
            Write-Host 'No active Firebase profile set.'
        }
    }

    'path' {
        $email = Get-EmailOrActive -Email $(if ($remaining.Count -ge 1) { $remaining[0] } else { $null })
        Write-Host (Get-ProfilePath -Email $email)
    }

    'env' {
        $email = Get-EmailOrActive -Email $(if ($remaining.Count -ge 1) { $remaining[0] } else { $null })
        Write-Host "`$env:XDG_CONFIG_HOME = '$(Get-ProfilePath -Email $email)'"
        Write-Host '$env:FIREBASE_CLI_DISABLE_UPDATE_NOTIFIER = ''1'''
    }

    'logout' {
        $email = Get-EmailOrActive -Email $(if ($remaining.Count -ge 1) { $remaining[0] } else { $null })
        Remove-Profile -Email $email
    }

    default {
        Show-Usage
        throw "Unknown action: $action"
    }
}
