$ErrorActionPreference = 'Stop'

$accountRoot = Join-Path $env:APPDATA 'mainframe\accounts\gcloud'
$currentFile = Join-Path $accountRoot 'current.json'
$defaultConfigDir = Join-Path $env:APPDATA 'gcloud'

function Show-Usage {
    @'
Google Cloud CLI account profile helper

Profiles are keyed by email and stored in:
  %APPDATA%\mainframe\accounts\gcloud\<email>

Each profile is a normal gcloud config directory selected with CLOUDSDK_CONFIG.

Usage:
  .\gcloud-account.ps1 login [email] [gcloud auth login args...]
  .\gcloud-account.ps1 reauth [email] [gcloud auth login args...]
  .\gcloud-account.ps1 import-current [email]
  .\gcloud-account.ps1 use <email>
  .\gcloud-account.ps1 run [email] <gcloud args...>
  .\gcloud-account.ps1 api [email] <GET|POST|PUT|PATCH|DELETE> <googleapis-url> [json body]
  .\gcloud-account.ps1 whoami [email]
  .\gcloud-account.ps1 projects [email]
  .\gcloud-account.ps1 projects-json [email]
  .\gcloud-account.ps1 project [email] <project-id>
  .\gcloud-account.ps1 services [email] <project-id>
  .\gcloud-account.ps1 services-json [email] <project-id> [--available]
  .\gcloud-account.ps1 services-enable [email] <project-id> <service...>
  .\gcloud-account.ps1 iam-policy [email] <project-id>
  .\gcloud-account.ps1 service-accounts [email] <project-id>
  .\gcloud-account.ps1 api-keys [email] <project-id>
  .\gcloud-account.ps1 billing-accounts [email]
  .\gcloud-account.ps1 organizations [email]
  .\gcloud-account.ps1 folders [email] <org:ID|organization/ID|folder:ID|folders/ID>
  .\gcloud-account.ps1 config-json [email]
  .\gcloud-account.ps1 capabilities [email]
  .\gcloud-account.ps1 capabilities-json [email]
  .\gcloud-account.ps1 status [email]
  .\gcloud-account.ps1 status-all
  .\gcloud-account.ps1 list
  .\gcloud-account.ps1 current
  .\gcloud-account.ps1 path [email]
  .\gcloud-account.ps1 env [email]
  .\gcloud-account.ps1 logout [email]

Examples:
  .\gcloud-account.ps1 import-current
  .\gcloud-account.ps1 use user@example.com
  .\gcloud-account.ps1 run user@example.com config list
  .\gcloud-account.ps1 run config list
  .\gcloud-account.ps1 run user@example.com services enable firebase.googleapis.com --project my-project
  .\gcloud-account.ps1 services-enable user@example.com my-project firebase.googleapis.com identitytoolkit.googleapis.com
  .\gcloud-account.ps1 service-accounts user@example.com my-project
'@ | Write-Host
}

function Normalize-Email {
    param([string]$Email)

    if ([string]::IsNullOrWhiteSpace($Email)) {
        throw 'Email is required.'
    }

    $normalized = $Email.Trim().ToLowerInvariant()
    if ($normalized -notmatch '^[^\s@]+@[^\s@]+\.[^\s@]+$') {
        throw "Google Cloud profile must be an account email, not a username, project, or label: $Email"
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

function Get-GcloudCommand {
    $cmd = Get-Command gcloud -ErrorAction SilentlyContinue
    if ($cmd) {
        return $cmd.Source
    }

    throw 'Google Cloud CLI was not found. Install it with Scoop: scoop install gcloud'
}

function Set-ActiveEmail {
    param([string]$Email)

    $normalized = Normalize-Email -Email $Email
    New-Item -ItemType Directory -Force -Path $accountRoot | Out-Null
    [ordered]@{
        tool = 'gcloud'
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
        throw 'No email was provided and no active Google Cloud profile is set. Run .\gcloud-account.ps1 use <email>.'
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
        [string]$ProfilePath,
        [AllowNull()][string]$Account,
        [AllowNull()][string]$Project
    )

    New-Item -ItemType Directory -Force -Path $ProfilePath | Out-Null
    [ordered]@{
        tool = 'gcloud'
        email = $Email
        account = $Account
        project = $Project
        configDir = $ProfilePath
        updatedAt = (Get-Date).ToString('o')
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $ProfilePath 'mainframe-profile.json') -Encoding UTF8
}

function Invoke-WithGcloudConfig {
    param(
        [string]$ConfigDir,
        [scriptblock]$Script
    )

    $oldConfig = $env:CLOUDSDK_CONFIG
    $oldUpdateCheck = $env:CLOUDSDK_COMPONENT_MANAGER_DISABLE_UPDATE_CHECK
    $oldUsage = $env:CLOUDSDK_CORE_DISABLE_USAGE_REPORTING
    $oldFileLogging = $env:CLOUDSDK_CORE_DISABLE_FILE_LOGGING

    try {
        New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
        $env:CLOUDSDK_CONFIG = $ConfigDir
        $env:CLOUDSDK_COMPONENT_MANAGER_DISABLE_UPDATE_CHECK = '1'
        $env:CLOUDSDK_CORE_DISABLE_USAGE_REPORTING = '1'
        $env:CLOUDSDK_CORE_DISABLE_FILE_LOGGING = '1'
        & $Script
    } finally {
        if ($null -eq $oldConfig) {
            Remove-Item Env:\CLOUDSDK_CONFIG -ErrorAction SilentlyContinue
        } else {
            $env:CLOUDSDK_CONFIG = $oldConfig
        }

        if ($null -eq $oldUpdateCheck) {
            Remove-Item Env:\CLOUDSDK_COMPONENT_MANAGER_DISABLE_UPDATE_CHECK -ErrorAction SilentlyContinue
        } else {
            $env:CLOUDSDK_COMPONENT_MANAGER_DISABLE_UPDATE_CHECK = $oldUpdateCheck
        }

        if ($null -eq $oldUsage) {
            Remove-Item Env:\CLOUDSDK_CORE_DISABLE_USAGE_REPORTING -ErrorAction SilentlyContinue
        } else {
            $env:CLOUDSDK_CORE_DISABLE_USAGE_REPORTING = $oldUsage
        }

        if ($null -eq $oldFileLogging) {
            Remove-Item Env:\CLOUDSDK_CORE_DISABLE_FILE_LOGGING -ErrorAction SilentlyContinue
        } else {
            $env:CLOUDSDK_CORE_DISABLE_FILE_LOGGING = $oldFileLogging
        }
    }
}

function Invoke-WithGcloudProfile {
    param(
        [string]$Email,
        [scriptblock]$Script
    )

    $normalized = Normalize-Email -Email $Email
    $profilePath = Get-ProfilePath -Email $normalized
    Invoke-WithGcloudConfig -ConfigDir $profilePath -Script $Script
}

function Invoke-GcloudProfile {
    param(
        [string]$Email,
        [string[]]$GcloudArgs
    )

    $gcloud = Get-GcloudCommand
    Invoke-WithGcloudProfile -Email $Email -Script {
        & $gcloud @GcloudArgs
        if ($LASTEXITCODE -ne 0) {
            throw "gcloud failed with exit code $LASTEXITCODE"
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

function Invoke-GcloudJsonProfile {
    param(
        [string]$Email,
        [string[]]$GcloudArgs
    )

    Invoke-GcloudProfile -Email $Email -GcloudArgs @($GcloudArgs + @('--format=json'))
}

function Get-GcloudCliVersion {
    $gcloud = Get-GcloudCommand
    $output = @(& $gcloud version 2>$null)
    foreach ($line in $output) {
        if ($line -match '^Google Cloud SDK\s+(.+)$') {
            return $matches[1].Trim()
        }
    }

    return $null
}

function Get-GcloudAccessToken {
    param([string]$Email)

    $normalized = Normalize-Email -Email $Email
    $profilePath = Get-ProfilePath -Email $normalized
    $token = Get-GcloudValue -ConfigDir $profilePath -CommandArgs @('auth', 'print-access-token', '--account', $normalized)
    if ([string]::IsNullOrWhiteSpace($token)) {
        throw "Could not obtain a Google Cloud access token for $normalized"
    }

    return $token
}

function Protect-GcloudSecretFields {
    param([AllowNull()]$Value)

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [string] -or $Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal] -or $Value -is [bool] -or $Value -is [datetime] -or $Value -is [datetimeoffset] -or $Value -is [guid]) {
        return $Value
    }

    if ($Value -is [System.Collections.IDictionary]) {
        $result = [ordered]@{}
        foreach ($key in $Value.Keys) {
            $name = [string]$key
            if ($name -match '^(authorization|accessToken|refreshToken|clientSecret|clientToken|password|secret|value|token|apiKey|keyString|privateKey|private_key|jwt|cookie)$') {
                $result[$name] = '<redacted>'
            } else {
                $result[$name] = Protect-GcloudSecretFields -Value $Value[$key]
            }
        }

        return [pscustomobject]$result
    }

    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        $items = @()
        foreach ($item in $Value) {
            $items += Protect-GcloudSecretFields -Value $item
        }

        return $items
    }

    if ($Value -isnot [pscustomobject]) {
        return $Value
    }

    if ($Value.PSObject -and $Value.PSObject.Properties) {
        $result = [ordered]@{}
        foreach ($property in $Value.PSObject.Properties) {
            $name = [string]$property.Name
            if ($name -match '^(authorization|accessToken|refreshToken|clientSecret|clientToken|password|secret|value|token|apiKey|keyString|privateKey|private_key|jwt|cookie)$') {
                $result[$name] = '<redacted>'
            } else {
                $result[$name] = Protect-GcloudSecretFields -Value $property.Value
            }
        }

        return [pscustomobject]$result
    }

    return $Value
}

function ConvertTo-SafeJsonOutput {
    param(
        [AllowNull()]$Value,
        [int]$Depth = 32
    )

    Protect-GcloudSecretFields -Value $Value | ConvertTo-Json -Depth $Depth
}

function Invoke-GcloudRest {
    param(
        [string]$Email,
        [ValidateSet('GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'HEAD')]
        [string]$Method,
        [string]$Url,
        [AllowNull()][string]$JsonBody
    )

    $uri = [uri]$Url
    if ($uri.Scheme -ne 'https' -or $uri.Host -notmatch '(^|\.)googleapis\.com$') {
        throw 'Only https://*.googleapis.com URLs are allowed for gcloud-account.ps1 api.'
    }

    $token = Get-GcloudAccessToken -Email $Email
    $headers = @{
        Authorization = "Bearer $token"
        Accept = 'application/json'
    }

    $parameters = @{
        Method = $Method
        Uri = $uri.AbsoluteUri
        Headers = $headers
        TimeoutSec = 30
        ErrorAction = 'Stop'
    }

    if (-not [string]::IsNullOrWhiteSpace($JsonBody)) {
        $parameters['ContentType'] = 'application/json'
        $parameters['Body'] = $JsonBody
    }

    try {
        return Invoke-RestMethod @parameters
    } catch {
        $status = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { $null }
        $message = $_.Exception.Message
        if ($status) {
            throw "Google API $Method $($uri.AbsoluteUri) failed with HTTP $status. $message"
        }

        throw "Google API $Method $($uri.AbsoluteUri) failed. $message"
    }
}

function Get-GcloudCapabilities {
    param([string]$Email)

    $status = Get-ProfileStatus -Email $Email
    [pscustomobject]@{
        Email = $status.Email
        State = $status.State
        Account = $status.Account
        Project = $status.Project
        HasCredentialsDb = $status.HasCredentialsDb
        GcloudVersion = Get-GcloudCliVersion
        OfficialSurfaces = @(
            'Google Cloud CLI with isolated CLOUDSDK_CONFIG profile',
            'Google Cloud Resource Manager projects and IAM commands',
            'Service Usage API enable/list commands through gcloud services',
            'IAM service accounts and key metadata through gcloud iam',
            'Google API REST calls through OAuth token captured internally',
            'bq and gsutil available from the installed Google Cloud SDK'
        )
        ShortcutCommands = @(
            'projects-json',
            'project',
            'services-json',
            'services-enable',
            'iam-policy',
            'service-accounts',
            'api-keys',
            'billing-accounts',
            'organizations',
            'folders',
            'api',
            'reauth'
        )
        DefaultCredentialRule = 'Use gcloud OAuth profiles keyed by detected email; refresh with gcloud auth login --force inside the same profile.'
        ScopeRule = 'gcloud auth login does not expose a manual --scopes flag; full automation power comes from the signed-in principal IAM/project/org permissions. ADC login has separate --scopes support and is not this profile store.'
    }
}

function Write-GcloudCapabilities {
    param([string]$Email)

    $capabilities = Get-GcloudCapabilities -Email $Email
    Write-Host "Google Cloud capabilities for $Email"
    $capabilities | Select-Object Email, State, Account, Project, HasCredentialsDb, GcloudVersion | Format-List

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

function Get-GcloudValue {
    param(
        [string]$ConfigDir,
        [string[]]$CommandArgs
    )

    $gcloud = Get-GcloudCommand
    $output = @(Invoke-WithGcloudConfig -ConfigDir $ConfigDir -Script {
        $output = @(& $gcloud @CommandArgs 2>$null)
        $output
    })

    if ($LASTEXITCODE -ne 0 -or -not $output) {
        return $null
    }

    $value = (($output -join [Environment]::NewLine).Trim())
    if ([string]::IsNullOrWhiteSpace($value) -or $value -eq '(unset)') {
        return $null
    }

    return $value
}

function Get-GcloudPropertyFromConfigFile {
    param(
        [string]$ConfigDir,
        [string]$Section,
        [string]$Key
    )

    $activeConfigPath = Join-Path $ConfigDir 'active_config'
    $activeConfig = 'default'
    if (Test-Path -LiteralPath $activeConfigPath) {
        $candidate = (Get-Content -LiteralPath $activeConfigPath -Raw).Trim()
        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
            $activeConfig = $candidate
        }
    }

    $configPath = Join-Path $ConfigDir ("configurations\config_$activeConfig")
    if (-not (Test-Path -LiteralPath $configPath)) {
        $configPath = Join-Path $ConfigDir 'configurations\config_default'
    }

    if (-not (Test-Path -LiteralPath $configPath)) {
        return $null
    }

    $inSection = $false
    foreach ($line in (Get-Content -LiteralPath $configPath)) {
        $trimmed = $line.Trim()
        if ($trimmed -match '^\[(.+)\]$') {
            $inSection = ($matches[1] -eq $Section)
            continue
        }

        if ($inSection -and $trimmed -match ('^{0}\s*=\s*(.+)$' -f [regex]::Escape($Key))) {
            $value = $matches[1].Trim()
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                return $value
            }
        }
    }

    return $null
}

function Get-GcloudAccountFromConfig {
    param([string]$ConfigDir)

    $account = Get-GcloudValue -ConfigDir $ConfigDir -CommandArgs @('config', 'get-value', 'account', '--quiet')
    if (Test-LooksLikeEmail -Value $account) {
        return Normalize-Email -Email $account
    }

    $account = Get-GcloudPropertyFromConfigFile -ConfigDir $ConfigDir -Section 'core' -Key 'account'
    if (Test-LooksLikeEmail -Value $account) {
        return Normalize-Email -Email $account
    }

    $account = Get-GcloudValue -ConfigDir $ConfigDir -CommandArgs @('auth', 'list', '--filter=status:ACTIVE', '--format=value(account)')
    if (Test-LooksLikeEmail -Value $account) {
        return Normalize-Email -Email $account
    }

    return $null
}

function Get-GcloudProjectFromConfig {
    param([string]$ConfigDir)

    $project = Get-GcloudValue -ConfigDir $ConfigDir -CommandArgs @('config', 'get-value', 'project', '--quiet')
    if (-not [string]::IsNullOrWhiteSpace($project)) {
        return $project
    }

    return Get-GcloudPropertyFromConfigFile -ConfigDir $ConfigDir -Section 'core' -Key 'project'
}

function Copy-ConfigDirectory {
    param(
        [string]$Source,
        [string]$Destination
    )

    if (-not (Test-Path -LiteralPath $Source)) {
        throw "Source gcloud config directory not found: $Source"
    }

    if (Test-Path -LiteralPath $Destination) {
        $backupPath = "$Destination.backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Move-Item -LiteralPath $Destination -Destination $backupPath
        Write-Host "Existing Google Cloud profile moved to: $backupPath"
    }

    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    Get-ChildItem -LiteralPath $Source -Force |
        Where-Object { $_.Name -ne 'logs' } |
        ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination $Destination -Recurse -Force
        }
}

function Move-ConfigDirectory {
    param(
        [string]$Source,
        [string]$Destination
    )

    if (Test-Path -LiteralPath $Destination) {
        $backupPath = "$Destination.backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Move-Item -LiteralPath $Destination -Destination $backupPath
        Write-Host "Existing Google Cloud profile moved to: $backupPath"
    }

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Destination) | Out-Null
    Move-Item -LiteralPath $Source -Destination $Destination
}

function Import-CurrentProfile {
    param([AllowNull()][string]$Email)

    if (-not (Test-Path -LiteralPath $defaultConfigDir)) {
        throw "Default gcloud config directory was not found: $defaultConfigDir"
    }

    $detected = Get-GcloudAccountFromConfig -ConfigDir $defaultConfigDir
    $targetEmail = if ([string]::IsNullOrWhiteSpace($Email)) { $detected } else { Normalize-Email -Email $Email }
    if (-not $targetEmail) {
        throw 'Could not detect the active Google Cloud account email. Pass it explicitly: .\gcloud-account.ps1 import-current <email>'
    }

    if ($detected -and $detected -ne $targetEmail) {
        throw "Default gcloud account is $detected, not $targetEmail. Refusing to save under the wrong email profile."
    }

    $profilePath = Get-ProfilePath -Email $targetEmail
    Copy-ConfigDirectory -Source $defaultConfigDir -Destination $profilePath
    $account = Get-GcloudAccountFromConfig -ConfigDir $profilePath
    $project = Get-GcloudProjectFromConfig -ConfigDir $profilePath
    Write-ProfileMetadata -Email $targetEmail -ProfilePath $profilePath -Account $account -Project $project
    Set-ActiveEmail -Email $targetEmail
    Write-Host "Google Cloud profile imported and active: $targetEmail"
}

function Login-Profile {
    param(
        [AllowNull()][string]$Email,
        [string[]]$LoginArgs
    )

    $gcloud = Get-GcloudCommand
    $targetEmail = if ([string]::IsNullOrWhiteSpace($Email)) { $null } else { Normalize-Email -Email $Email }
    $profilePath = if ($targetEmail) {
        Get-ProfilePath -Email $targetEmail
    } else {
        Join-Path $env:TEMP "mainframe-gcloud-login-$([Guid]::NewGuid().ToString('N'))"
    }

    New-Item -ItemType Directory -Force -Path $profilePath | Out-Null
    Write-Host 'Starting Google Cloud CLI login inside an isolated mainframe profile.'
    Invoke-WithGcloudConfig -ConfigDir $profilePath -Script {
        & $gcloud auth login @LoginArgs
        if ($LASTEXITCODE -ne 0) {
            throw "gcloud auth login failed with exit code $LASTEXITCODE"
        }
    }

    $detected = Get-GcloudAccountFromConfig -ConfigDir $profilePath
    if (-not $detected) {
        throw 'Login succeeded, but Google Cloud account email could not be detected. Refusing to save a project name or label fallback.'
    }

    if ($targetEmail -and $detected -ne $targetEmail) {
        throw "Login detected $detected, not $targetEmail. Refusing to save under the wrong email profile."
    }

    $finalPath = Get-ProfilePath -Email $detected
    if ($profilePath -ne $finalPath) {
        Move-ConfigDirectory -Source $profilePath -Destination $finalPath
    }

    $project = Get-GcloudProjectFromConfig -ConfigDir $finalPath
    Write-ProfileMetadata -Email $detected -ProfilePath $finalPath -Account $detected -Project $project
    Set-ActiveEmail -Email $detected
    Write-Host "Google Cloud profile ready and active: $detected"
}

function Get-ProfileStatus {
    param([string]$Email)

    $normalized = Normalize-Email -Email $Email
    $profilePath = Get-ProfilePath -Email $normalized
    $exists = Test-Path -LiteralPath $profilePath
    $active = Get-ActiveEmail
    $account = if ($exists) { Get-GcloudAccountFromConfig -ConfigDir $profilePath } else { $null }
    $project = if ($exists) { Get-GcloudProjectFromConfig -ConfigDir $profilePath } else { $null }
    $credentialsDb = Join-Path $profilePath 'credentials.db'

    [pscustomobject]@{
        Email = $normalized
        Exists = $exists
        IsActive = ($active -eq $normalized)
        ConfigDir = $profilePath
        Account = $account
        Project = $project
        HasCredentialsDb = ($exists -and (Test-Path -LiteralPath $credentialsDb))
        State = if (-not $exists) { 'missing-profile' } elseif ($account -eq $normalized) { 'ready' } elseif ($account) { 'email-mismatch' } else { 'missing-account' }
    }
}

function Remove-Profile {
    param([string]$Email)

    $normalized = Normalize-Email -Email $Email
    $profilePath = Get-ProfilePath -Email $normalized
    if (-not (Test-Path -LiteralPath $profilePath)) {
        Write-Host "Google Cloud profile does not exist: $normalized"
        return
    }

    $backupPath = "$profilePath.logged-out-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Move-Item -LiteralPath $profilePath -Destination $backupPath
    Write-Host "Google Cloud profile moved to: $backupPath"

    $active = Get-ActiveEmail
    if ($active -eq $normalized -and (Test-Path -LiteralPath $currentFile)) {
        Remove-Item -LiteralPath $currentFile
        Write-Host 'Active Google Cloud profile cleared.'
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
        $loginArgs = @('--force')
        if ($remaining.Count -gt 0 -and (Test-LooksLikeEmail -Value $remaining[0])) {
            $email = Normalize-Email -Email $remaining[0]
            $loginArgs = @($remaining[0], '--force') + @($remaining | Select-Object -Skip 1)
        } else {
            $email = Get-EmailOrActive -Email $null
            $loginArgs = @($email, '--force') + @($remaining)
        }

        Login-Profile -Email $email -LoginArgs $loginArgs
    }

    'import-current' {
        if ($remaining.Count -gt 1) {
            throw 'Usage: .\gcloud-account.ps1 import-current [email]'
        }

        Import-CurrentProfile -Email $(if ($remaining.Count -eq 1) { $remaining[0] } else { $null })
    }

    'use' {
        if ($remaining.Count -ne 1) {
            throw 'Usage: .\gcloud-account.ps1 use <email>'
        }

        $email = Normalize-Email -Email $remaining[0]
        $profilePath = Get-ProfilePath -Email $email
        if (-not (Test-Path -LiteralPath $profilePath)) {
            throw "Google Cloud profile does not exist yet: $email"
        }

        Set-ActiveEmail -Email $email
        Write-Host "Active Google Cloud profile: $email"
    }

    'run' {
        if ($remaining.Count -lt 1) {
            throw 'Usage: .\gcloud-account.ps1 run [email] <gcloud args...>'
        }

        if (Test-LooksLikeEmail -Value $remaining[0]) {
            if ($remaining.Count -lt 2) {
                throw 'Usage: .\gcloud-account.ps1 run [email] <gcloud args...>'
            }

            $email = Normalize-Email -Email $remaining[0]
            $gcloudArgs = @($remaining | Select-Object -Skip 1)
        } else {
            $email = Get-EmailOrActive -Email $null
            $gcloudArgs = @($remaining)
        }

        Invoke-GcloudProfile -Email $email -GcloudArgs $gcloudArgs
    }

    'api' {
        if ($remaining.Count -lt 2) {
            throw 'Usage: .\gcloud-account.ps1 api [email] <GET|POST|PUT|PATCH|DELETE> <googleapis-url> [json body]'
        }

        if (Test-LooksLikeEmail -Value $remaining[0]) {
            if ($remaining.Count -lt 3) {
                throw 'Usage: .\gcloud-account.ps1 api [email] <GET|POST|PUT|PATCH|DELETE> <googleapis-url> [json body]'
            }

            $email = Normalize-Email -Email $remaining[0]
            $method = $remaining[1].ToUpperInvariant()
            $url = $remaining[2]
            $body = if ($remaining.Count -gt 3) { ($remaining[3..($remaining.Count - 1)] -join ' ') } else { $null }
        } else {
            $email = Get-EmailOrActive -Email $null
            $method = $remaining[0].ToUpperInvariant()
            $url = $remaining[1]
            $body = if ($remaining.Count -gt 2) { ($remaining[2..($remaining.Count - 1)] -join ' ') } else { $null }
        }

        ConvertTo-SafeJsonOutput -Value (Invoke-GcloudRest -Email $email -Method $method -Url $url -JsonBody $body)
    }

    'whoami' {
        $email = Get-EmailOrActive -Email $(if ($remaining.Count -ge 1) { $remaining[0] } else { $null })
        Get-ProfileStatus -Email $email | Select-Object Email, Account, Project, State | Format-List
    }

    'projects' {
        $email = Get-EmailOrActive -Email $(if ($remaining.Count -ge 1) { $remaining[0] } else { $null })
        Invoke-GcloudProfile -Email $email -GcloudArgs @('projects', 'list')
    }

    'projects-json' {
        if ($remaining.Count -gt 1) {
            throw 'Usage: .\gcloud-account.ps1 projects-json [email]'
        }

        $email = Get-EmailOrActive -Email $(if ($remaining.Count -ge 1) { $remaining[0] } else { $null })
        Invoke-GcloudJsonProfile -Email $email -GcloudArgs @('projects', 'list')
    }

    'project' {
        $parts = Split-OptionalEmail -Values $remaining
        if ($parts.Rest.Count -ne 1) {
            throw 'Usage: .\gcloud-account.ps1 project [email] <project-id>'
        }

        Invoke-GcloudJsonProfile -Email $parts.Email -GcloudArgs @('projects', 'describe', $parts.Rest[0])
    }

    'services' {
        $parts = Split-OptionalEmail -Values $remaining
        if ($parts.Rest.Count -ne 1) {
            throw 'Usage: .\gcloud-account.ps1 services [email] <project-id>'
        }

        Invoke-GcloudProfile -Email $parts.Email -GcloudArgs @('services', 'list', '--enabled', '--project', $parts.Rest[0])
    }

    'services-json' {
        $parts = Split-OptionalEmail -Values $remaining
        if ($parts.Rest.Count -lt 1 -or $parts.Rest.Count -gt 2) {
            throw 'Usage: .\gcloud-account.ps1 services-json [email] <project-id> [--available]'
        }

        $argsForGcloud = @('services', 'list', '--enabled', '--project', $parts.Rest[0])
        if ($parts.Rest.Count -eq 2) {
            if ($parts.Rest[1] -ne '--available') {
                throw 'Usage: .\gcloud-account.ps1 services-json [email] <project-id> [--available]'
            }

            $argsForGcloud = @('services', 'list', '--available', '--project', $parts.Rest[0])
        }

        Invoke-GcloudJsonProfile -Email $parts.Email -GcloudArgs $argsForGcloud
    }

    'services-enable' {
        $parts = Split-OptionalEmail -Values $remaining
        if ($parts.Rest.Count -lt 2) {
            throw 'Usage: .\gcloud-account.ps1 services-enable [email] <project-id> <service...>'
        }

        $project = $parts.Rest[0]
        $services = @($parts.Rest | Select-Object -Skip 1)
        Invoke-GcloudProfile -Email $parts.Email -GcloudArgs (@('services', 'enable') + $services + @('--project', $project))
    }

    'iam-policy' {
        $parts = Split-OptionalEmail -Values $remaining
        if ($parts.Rest.Count -ne 1) {
            throw 'Usage: .\gcloud-account.ps1 iam-policy [email] <project-id>'
        }

        Invoke-GcloudJsonProfile -Email $parts.Email -GcloudArgs @('projects', 'get-iam-policy', $parts.Rest[0])
    }

    'service-accounts' {
        $parts = Split-OptionalEmail -Values $remaining
        if ($parts.Rest.Count -ne 1) {
            throw 'Usage: .\gcloud-account.ps1 service-accounts [email] <project-id>'
        }

        Invoke-GcloudJsonProfile -Email $parts.Email -GcloudArgs @('iam', 'service-accounts', 'list', '--project', $parts.Rest[0])
    }

    'api-keys' {
        $parts = Split-OptionalEmail -Values $remaining
        if ($parts.Rest.Count -ne 1) {
            throw 'Usage: .\gcloud-account.ps1 api-keys [email] <project-id>'
        }

        Invoke-GcloudJsonProfile -Email $parts.Email -GcloudArgs @('services', 'api-keys', 'list', '--project', $parts.Rest[0])
    }

    'billing-accounts' {
        if ($remaining.Count -gt 1) {
            throw 'Usage: .\gcloud-account.ps1 billing-accounts [email]'
        }

        $email = Get-EmailOrActive -Email $(if ($remaining.Count -ge 1) { $remaining[0] } else { $null })
        Invoke-GcloudJsonProfile -Email $email -GcloudArgs @('billing', 'accounts', 'list')
    }

    'organizations' {
        if ($remaining.Count -gt 1) {
            throw 'Usage: .\gcloud-account.ps1 organizations [email]'
        }

        $email = Get-EmailOrActive -Email $(if ($remaining.Count -ge 1) { $remaining[0] } else { $null })
        Invoke-GcloudJsonProfile -Email $email -GcloudArgs @('organizations', 'list')
    }

    'folders' {
        $parts = Split-OptionalEmail -Values $remaining
        if ($parts.Rest.Count -ne 1) {
            throw 'Usage: .\gcloud-account.ps1 folders [email] <org:ID|organization/ID|folder:ID|folders/ID>'
        }

        $parent = $parts.Rest[0]
        if ($parent -match '^(org|organization|organizations)[:/](.+)$') {
            Invoke-GcloudJsonProfile -Email $parts.Email -GcloudArgs @('resource-manager', 'folders', 'list', "--organization=$($matches[2])")
        } elseif ($parent -match '^(folder|folders)[:/](.+)$') {
            Invoke-GcloudJsonProfile -Email $parts.Email -GcloudArgs @('resource-manager', 'folders', 'list', "--folder=$($matches[2])")
        } else {
            Invoke-GcloudJsonProfile -Email $parts.Email -GcloudArgs @('resource-manager', 'folders', 'list', "--folder=$parent")
        }
    }

    'config-json' {
        if ($remaining.Count -gt 1) {
            throw 'Usage: .\gcloud-account.ps1 config-json [email]'
        }

        $email = Get-EmailOrActive -Email $(if ($remaining.Count -ge 1) { $remaining[0] } else { $null })
        Invoke-GcloudJsonProfile -Email $email -GcloudArgs @('config', 'list')
    }

    'capabilities' {
        if ($remaining.Count -gt 1) {
            throw 'Usage: .\gcloud-account.ps1 capabilities [email]'
        }

        $email = Get-EmailOrActive -Email $(if ($remaining.Count -ge 1) { $remaining[0] } else { $null })
        Write-GcloudCapabilities -Email $email
    }

    'capabilities-json' {
        if ($remaining.Count -gt 1) {
            throw 'Usage: .\gcloud-account.ps1 capabilities-json [email]'
        }

        $email = Get-EmailOrActive -Email $(if ($remaining.Count -ge 1) { $remaining[0] } else { $null })
        ConvertTo-SafeJsonOutput -Value (Get-GcloudCapabilities -Email $email)
    }

    'status' {
        $email = Get-EmailOrActive -Email $(if ($remaining.Count -ge 1) { $remaining[0] } else { $null })
        Get-ProfileStatus -Email $email | Format-List
    }

    'status-all' {
        if (-not (Test-Path -LiteralPath $accountRoot)) {
            Write-Host 'No Google Cloud profiles found.'
            return
        }

        $profiles = @(Get-ChildItem -LiteralPath $accountRoot -Directory -Force | Where-Object { $_.Name -match '^[^\s@]+@[^\s@]+\.[^\s@]+$' } | Sort-Object Name)
        if ($profiles.Count -eq 0) {
            Write-Host 'No Google Cloud profiles found.'
            return
        }

        $profiles |
            ForEach-Object { Get-ProfileStatus -Email (Get-ProfileEmail -Directory $_) } |
            Format-Table -AutoSize
    }

    'list' {
        if (-not (Test-Path -LiteralPath $accountRoot)) {
            Write-Host 'No Google Cloud profiles found.'
            return
        }

        $active = Get-ActiveEmail
        $profiles = @(Get-ChildItem -LiteralPath $accountRoot -Directory -Force | Where-Object { $_.Name -match '^[^\s@]+@[^\s@]+\.[^\s@]+$' } | Sort-Object Name)
        if ($profiles.Count -eq 0) {
            Write-Host 'No Google Cloud profiles found.'
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
            Write-Host 'No active Google Cloud profile set.'
        }
    }

    'path' {
        $email = Get-EmailOrActive -Email $(if ($remaining.Count -ge 1) { $remaining[0] } else { $null })
        Write-Host (Get-ProfilePath -Email $email)
    }

    'env' {
        $email = Get-EmailOrActive -Email $(if ($remaining.Count -ge 1) { $remaining[0] } else { $null })
        Write-Host "`$env:CLOUDSDK_CONFIG = '$(Get-ProfilePath -Email $email)'"
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
