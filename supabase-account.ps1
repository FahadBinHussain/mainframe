$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'vault-secret.psm1') -Force

$accountRoot = Join-Path $env:APPDATA 'mainframe\accounts\supabase'
$currentFile = Join-Path $accountRoot 'current.json'
$apiEndpoint = 'https://api.supabase.com'

function Show-Usage {
    @(
        'Supabase Management API account profile helper',
        '',
        'Profiles are keyed by account email only and stored in:',
        '  %APPDATA%\mainframe\accounts\supabase\<email>',
        '',
        'Supabase Management REST API (JSON, Bearer auth with a Personal Access Token,',
        'sbp_... from https://supabase.com/dashboard/account/tokens -> "Expires in: Never").',
        '',
        'Usage:',
        '  .\supabase-account.ps1 login <email>',
        '  .\supabase-account.ps1 token-add <email>',
        '  .\supabase-account.ps1 token-clear [email]',
        '  .\supabase-account.ps1 use <email>',
        '  .\supabase-account.ps1 run [email] <GET|POST|PATCH|DELETE> <api path> [json body]',
        '  .\supabase-account.ps1 projects [email]',
        '  .\supabase-account.ps1 project [email] <project-ref>',
        '  .\supabase-account.ps1 organizations [email]',
        '  .\supabase-account.ps1 api-keys [email] <project-ref>',
        '  .\supabase-account.ps1 status [email]',
        '  .\supabase-account.ps1 status-all',
        '  .\supabase-account.ps1 list',
        '  .\supabase-account.ps1 current',
        '  .\supabase-account.ps1 path [email]',
        '  .\supabase-account.ps1 env [email]',
        '  .\supabase-account.ps1 logout [email]',
        '',
        'Examples:',
        '  .\supabase-account.ps1 login user@example.com',
        '  .\supabase-account.ps1 projects user@example.com',
        '  .\supabase-account.ps1 organizations user@example.com',
        '  .\supabase-account.ps1 run user@example.com GET v1/projects',
        '  .\supabase-account.ps1 run user@example.com POST v1/projects ''{"name":"x"}'''
    ) -join [Environment]::NewLine | Write-Host
}

function Normalize-ProfileName {
    param([string]$Profile)

    if ([string]::IsNullOrWhiteSpace($Profile)) {
        throw 'Email profile is required.'
    }

    $normalized = $Profile.Trim().ToLowerInvariant()
    if ($normalized -notmatch '^[^\s@]+@[^\s@]+\.[^\s@]+$') {
        throw "Supabase profile must be an account email, not a label or username: $Profile"
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

    return Join-Path $ProfilePath 'token.txt'
}

function Convert-SecureStringToPlainText {
    param([Security.SecureString]$SecureString)

    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

function Get-TokenFingerprint {
    param([AllowNull()][string]$Token)

    if ([string]::IsNullOrWhiteSpace($Token)) {
        return $null
    }

    $bytes = [Text.Encoding]::UTF8.GetBytes($Token)
    $hash = [Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
    return (($hash | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0, 12)
}

function Write-ProfileMetadata {
    param(
        [string]$Profile,
        [string]$ProfilePath
    )

    New-Item -ItemType Directory -Force -Path $ProfilePath | Out-Null
    [ordered]@{
        tool = 'supabase'
        service = 'Supabase'
        profile = $Profile
        apiEndpoint = $apiEndpoint
        apiVersion = 1
        keyPath = (Get-ProfileTokenPath -ProfilePath $ProfilePath)
        updatedAt = (Get-Date).ToString('o')
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $ProfilePath 'profile.json') -Encoding UTF8
}

function Write-ProfileToken {
    param(
        [string]$Profile,
        [Security.SecureString]$Token
    )

    $normalized = Normalize-ProfileName -Profile $Profile
    $profilePath = Get-ProfilePath -Profile $normalized
    Write-ProfileMetadata -Profile $normalized -ProfilePath $profilePath
    $plainToken = Convert-SecureStringToPlainText -SecureString $Token
    $userPrefix = ($normalized -split '@')[0]
    Write-VaultSecretToExisting -Email $normalized -NamePattern 'supabase.com*' -Header 'Access Tokens' -Value $plainToken.Trim() -ItemName "supabase.com - $userPrefix" -Username $normalized -Uri 'https://supabase.com/dashboard/account/tokens'
    Set-ActiveProfile -Profile $normalized
}

function Read-ProfileToken {
    param([string]$Profile)

    $normalized = Normalize-ProfileName -Profile $Profile
    $token = Read-VaultSecret -Email $normalized -NamePattern 'supabase.com*' -ValueRegex 'sbp_v0_[A-Za-z0-9]+'
    if ([string]::IsNullOrWhiteSpace($token)) {
        throw "Supabase token profile does not exist yet: $normalized. Run .\supabase-account.ps1 login $normalized first."
    }

    return $token
}

function Remove-ProfileToken {
    param([string]$Profile)

    $normalized = Normalize-ProfileName -Profile $Profile
    $profilePath = Get-ProfilePath -Profile $normalized
    $tokenPath = Get-ProfileTokenPath -ProfilePath $profilePath
    if (Test-Path -LiteralPath $tokenPath) {
        Remove-Item -LiteralPath $tokenPath -Force
        Write-Host "Removed saved Supabase token profile for: $normalized"
    } else {
        Write-Host "No saved Supabase token profile found for: $normalized"
    }
}

function Set-ActiveProfile {
    param([string]$Profile)

    $normalized = Normalize-ProfileName -Profile $Profile
    New-Item -ItemType Directory -Force -Path $accountRoot | Out-Null
    [ordered]@{
        tool = 'supabase'
        service = 'Supabase'
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
        throw 'No email was provided and no active Supabase email profile is set. Run .\supabase-account.ps1 use <email>.'
    }

    return Normalize-ProfileName -Profile $active
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

function Get-ProfileStatus {
    param([string]$Profile)

    $normalized = Normalize-ProfileName -Profile $Profile
    $profilePath = Get-ProfilePath -Profile $normalized
    $tokenPath = Get-ProfileTokenPath -ProfilePath $profilePath
    $exists = Test-Path -LiteralPath $profilePath
    $token = Read-VaultSecret -Email $normalized -NamePattern 'supabase.com*' -ValueRegex 'sbp_v0_[A-Za-z0-9]+'
    $hasToken = -not [string]::IsNullOrWhiteSpace($token)
    $active = Get-ActiveProfile

    [pscustomobject]@{
        Profile = $normalized
        Exists = $exists
        IsActive = ($active -eq $normalized)
        HasToken = $hasToken
        TokenFingerprint = Get-TokenFingerprint -Token $token
        ApiEndpoint = $apiEndpoint
        TokenPath = $tokenPath
        State = if (-not $exists) { 'missing-profile' } elseif (-not $hasToken) { 'missing-token' } elseif ($active -eq $normalized) { 'active' } else { 'configured' }
    }
}

function Get-ApiPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw 'API path is required.'
    }

    if ($Path -match '^https?://') {
        $uri = [uri]$Path
        if ($uri.Host -ne 'api.supabase.com') {
            throw 'Only https://api.supabase.com URLs are allowed.'
        }

        return $uri.PathAndQuery
    }

    if ($Path.StartsWith('/')) {
        return $Path
    }

    return "/$Path"
}

function Invoke-SupabaseApi {
    param(
        [string]$Profile,
        [string]$Method,
        [string]$Path,
        [AllowNull()][string]$JsonBody
    )

    $normalized = Normalize-ProfileName -Profile $Profile
    $token = Read-ProfileToken -Profile $normalized
    $apiPath = Get-ApiPath -Path $Path
    if ($apiPath -notmatch '^/v\d+/') {
        $apiPath = "/v1$apiPath"
    }

    $uri = "$apiEndpoint$apiPath"
    $headers = @{
        Authorization = "Bearer $token"
        Accept = 'application/json'
    }

    $methodUpper = $Method.ToUpperInvariant()
    if ($methodUpper -notin @('GET', 'POST', 'PATCH', 'DELETE', 'PUT')) {
        throw 'Method must be one of: GET, POST, PATCH, DELETE, PUT.'
    }

    try {
        if ([string]::IsNullOrWhiteSpace($JsonBody)) {
            return Invoke-RestMethod -Method $methodUpper -Uri $uri -Headers $headers -ContentType 'application/json'
        }

        $JsonBody | ConvertFrom-Json | Out-Null
        return Invoke-RestMethod -Method $methodUpper -Uri $uri -Headers $headers -ContentType 'application/json' -Body $JsonBody
    } catch {
        $response = $_.Exception.Response
        if ($response -and $response.StatusCode) {
            $statusCode = [int]$response.StatusCode
            $statusDescription = $response.StatusDescription
            throw "Supabase API $methodUpper $apiPath failed: HTTP $statusCode $statusDescription ($($_.ErrorDetails.Message))"
        }

        throw "Supabase API $methodUpper $apiPath failed: $($_.Exception.Message)"
    }
}

function ConvertTo-JsonOutput {
    param([AllowNull()]$Value)

    if ($null -eq $Value) {
        Write-Host '{}'
        return
    }

    $Value | ConvertTo-Json -Depth 16
}

function Remove-Profile {
    param([string]$Profile)

    $normalized = Normalize-ProfileName -Profile $Profile
    $profilePath = Get-ProfilePath -Profile $normalized
    if (-not (Test-Path -LiteralPath $profilePath)) {
        Write-Host "Supabase profile does not exist: $normalized"
        return
    }

    $backupPath = "$profilePath.logged-out-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Move-Item -LiteralPath $profilePath -Destination $backupPath
    Write-Host "Supabase profile moved to: $backupPath"

    $active = Get-ActiveProfile
    if ($active -eq $normalized -and (Test-Path -LiteralPath $currentFile)) {
        Remove-Item -LiteralPath $currentFile
        Write-Host 'Active Supabase profile cleared.'
    }
}

$command = if ($args.Count -gt 0) { $args[0].ToLowerInvariant() } else { 'help' }
$remaining = @($args | Select-Object -Skip 1)

switch ($command) {
    'help' {
        Show-Usage
    }

    { $_ -in @('login', 'token-add', 'add') } {
        if ($remaining.Count -lt 1) {
            throw 'Usage: .\supabase-account.ps1 login <email>'
        }

        $profile = Normalize-ProfileName -Profile $remaining[0]
        Write-Host "Paste a Supabase Personal Access Token (sbp_...) for $profile. Input is hidden; it will be saved as token.txt for symmetric mainframe backup/restore."
        $token = Read-Host 'Supabase access token' -AsSecureString
        Write-ProfileToken -Profile $profile -Token $token
        Write-Host "Supabase token profile is ready and active: $profile"
    }

    'token-clear' {
        $profile = Get-ProfileOrActive -Profile $(if ($remaining.Count -ge 1) { $remaining[0] } else { $null })
        Remove-ProfileToken -Profile $profile
    }

    'use' {
        if ($remaining.Count -ne 1) {
            throw 'Usage: .\supabase-account.ps1 use <email>'
        }

        $profile = Normalize-ProfileName -Profile $remaining[0]
        $profilePath = Get-ProfilePath -Profile $profile
        if (-not (Test-Path -LiteralPath (Get-ProfileTokenPath -ProfilePath $profilePath))) {
            throw "Supabase profile does not exist yet: $profile"
        }

        Set-ActiveProfile -Profile $profile
        Write-Host "Active Supabase profile: $profile"
    }

    'run' {
        if ($remaining.Count -lt 2) {
            throw 'Usage: .\supabase-account.ps1 run [email] <GET|POST|PATCH|DELETE> <api path> [json body]'
        }

        $argOffset = 0
        if (Test-LooksLikeEmail -Value $remaining[0]) {
            $argOffset = 1
        }

        $profile = Get-ProfileOrActive -Profile $(if ($argOffset -eq 1) { $remaining[0] } else { $null })
        $method = $remaining[$argOffset]
        $path = $remaining[$argOffset + 1]
        $body = if ($remaining.Count -gt ($argOffset + 2)) { ($remaining[($argOffset + 2)..($remaining.Count - 1)] -join ' ') } else { $null }
        ConvertTo-JsonOutput -Value (Invoke-SupabaseApi -Profile $profile -Method $method -Path $path -JsonBody $body)
    }

    'projects' {
        $profile = Get-ProfileOrActive -Profile $(if ($remaining.Count -ge 1) { $remaining[0] } else { $null })
        ConvertTo-JsonOutput -Value (Invoke-SupabaseApi -Profile $profile -Method GET -Path '/v1/projects')
    }

    'project' {
        if ($remaining.Count -lt 1) {
            throw 'Usage: .\supabase-account.ps1 project [email] <project-ref>'
        }

        $argOffset = 0
        if (Test-LooksLikeEmail -Value $remaining[0]) {
            $argOffset = 1
        }

        $profile = Get-ProfileOrActive -Profile $(if ($argOffset -eq 1) { $remaining[0] } else { $null })
        $ref = $remaining[$argOffset]
        ConvertTo-JsonOutput -Value (Invoke-SupabaseApi -Profile $profile -Method GET -Path "/v1/projects/$ref")
    }

    'organizations' {
        $profile = Get-ProfileOrActive -Profile $(if ($remaining.Count -ge 1) { $remaining[0] } else { $null })
        ConvertTo-JsonOutput -Value (Invoke-SupabaseApi -Profile $profile -Method GET -Path '/v1/organizations')
    }

    'api-keys' {
        if ($remaining.Count -lt 1) {
            throw 'Usage: .\supabase-account.ps1 api-keys [email] <project-ref>'
        }

        $argOffset = 0
        if (Test-LooksLikeEmail -Value $remaining[0]) {
            $argOffset = 1
        }

        $profile = Get-ProfileOrActive -Profile $(if ($argOffset -eq 1) { $remaining[0] } else { $null })
        $ref = $remaining[$argOffset]
        ConvertTo-JsonOutput -Value (Invoke-SupabaseApi -Profile $profile -Method GET -Path "/v1/projects/$ref/api-keys")
    }

    'status' {
        $profile = Get-ProfileOrActive -Profile $(if ($remaining.Count -ge 1) { $remaining[0] } else { $null })
        Get-ProfileStatus -Profile $profile | Format-List
    }

    'status-all' {
        if (-not (Test-Path -LiteralPath $accountRoot)) {
            Write-Host 'No Supabase profiles found.'
            return
        }

        $profiles = @(Get-ChildItem -LiteralPath $accountRoot -Directory -Force | Where-Object { $_.Name -match '^[^\s@]+@[^\s@]+\.[^\s@]+$' } | Sort-Object Name)
        if ($profiles.Count -eq 0) {
            Write-Host 'No Supabase profiles found.'
            return
        }

        $profiles |
            ForEach-Object { Get-ProfileStatus -Profile (Get-ProfileName -Directory $_) } |
            Format-Table -AutoSize
    }

    'list' {
        if (-not (Test-Path -LiteralPath $accountRoot)) {
            Write-Host 'No Supabase profiles found.'
            return
        }

        $active = Get-ActiveProfile
        $profiles = @(Get-ChildItem -LiteralPath $accountRoot -Directory -Force | Where-Object { $_.Name -match '^[^\s@]+@[^\s@]+\.[^\s@]+$' } | Sort-Object Name)
        if ($profiles.Count -eq 0) {
            Write-Host 'No Supabase profiles found.'
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
            Write-Host 'No active Supabase email profile set.'
        }
    }

    'path' {
        $profile = Get-ProfileOrActive -Profile $(if ($remaining.Count -ge 1) { $remaining[0] } else { $null })
        Write-Host (Get-ProfilePath -Profile $profile)
    }

    'env' {
        $profile = Get-ProfileOrActive -Profile $(if ($remaining.Count -ge 1) { $remaining[0] } else { $null })
        $profilePath = Get-ProfilePath -Profile $profile
        $tokenPath = Get-ProfileTokenPath -ProfilePath $profilePath
        $tokenState = if (Test-Path -LiteralPath $tokenPath) { '<profile access token>' } else { '<missing access token>' }
        Write-Host "`$env:SUPABASE_ACCESS_TOKEN = $tokenState"
        Write-Host "`$env:SUPABASE_API_ENDPOINT = '$apiEndpoint'"
    }

    'logout' {
        $profile = Get-ProfileOrActive -Profile $(if ($remaining.Count -ge 1) { $remaining[0] } else { $null })
        Remove-Profile -Profile $profile
    }

    default {
        Show-Usage
        throw "Unknown command: $command"
    }
}