$ErrorActionPreference = 'Stop'

$accountRoot = Join-Path $env:APPDATA 'mainframe\accounts\uptimerobot'
$currentFile = Join-Path $accountRoot 'current.json'
$apiEndpoint = 'https://api.uptimerobot.com'

function Show-Usage {
    @(
        'UptimeRobot API account profile helper',
        '',
        'Profiles are keyed by account email only and stored in:',
        '  %APPDATA%\mainframe\accounts\uptimerobot\<email>',
        '',
        'UptimeRobot v3 REST API (JSON, Bearer auth with the account API key).',
        'All v3 fields are camelCase (friendlyName, interval, timeout ...).',
        'The v2 form-API is NOT used: newMonitor on v2 returns access_denied on',
        'current accounts - v3 is the supported path.',
        '',
        'Usage:',
        '  .\uptimerobot-account.ps1 login <email>',
        '  .\uptimerobot-account.ps1 token-add <email>',
        '  .\uptimerobot-account.ps1 token-clear [email]',
        '  .\uptimerobot-account.ps1 use <email>',
        '  .\uptimerobot-account.ps1 run [email] <GET|POST|PATCH|DELETE> <api path> [json body]',
        '  .\uptimerobot-account.ps1 monitors [email]',
        '  .\uptimerobot-account.ps1 monitor [email] <monitor-id>',
        '  .\uptimerobot-account.ps1 add-monitor [email] <url> <name> [interval-seconds]',
        '  .\uptimerobot-account.ps1 delete-monitor [email] <monitor-id>',
        '  .\uptimerobot-account.ps1 pause [email] <monitor-id>',
        '  .\uptimerobot-account.ps1 resume [email] <monitor-id>',
        '  .\uptimerobot-account.ps1 psp [email]',
        '  .\uptimerobot-account.ps1 new-psp [email] <name> <monitor-id,...>',
        '  .\uptimerobot-account.ps1 psp-monitors [email] <psp-id> <monitor-id,...>',
        '  .\uptimerobot-account.ps1 status [email]',
        '  .\uptimerobot-account.ps1 status-all',
        '  .\uptimerobot-account.ps1 list',
        '  .\uptimerobot-account.ps1 current',
        '  .\uptimerobot-account.ps1 path [email]',
        '  .\uptimerobot-account.ps1 env [email]',
        '  .\uptimerobot-account.ps1 logout [email]',
        '',
        'Examples:',
        '  .\uptimerobot-account.ps1 login user@example.com',
        '  .\uptimerobot-account.ps1 monitors user@example.com',
        '  .\uptimerobot-account.ps1 add-monitor user@example.com https://example.com "Example site" 300',
        '  .\uptimerobot-account.ps1 run user@example.com GET monitors',
        '  .\uptimerobot-account.ps1 run PATCH monitors/12345 ''{"status":"PAUSED"}'''
    ) -join [Environment]::NewLine | Write-Host
}

function Normalize-ProfileName {
    param([string]$Profile)

    if ([string]::IsNullOrWhiteSpace($Profile)) {
        throw 'Email profile is required.'
    }

    $normalized = $Profile.Trim().ToLowerInvariant()
    if ($normalized -notmatch '^[^\s@]+@[^\s@]+\.[^\s@]+$') {
        throw "UptimeRobot profile must be an account email, not a label or username: $Profile"
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

function Get-ProfileKeyPath {
    param([string]$ProfilePath)

    return Join-Path $ProfilePath 'api-key.txt'
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
        tool = 'uptimerobot'
        service = 'UptimeRobot'
        profile = $Profile
        apiEndpoint = $apiEndpoint
        apiVersion = 3
        keyPath = (Get-ProfileKeyPath -ProfilePath $ProfilePath)
        updatedAt = (Get-Date).ToString('o')
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $ProfilePath 'profile.json') -Encoding UTF8
}

function Write-ProfileKey {
    param(
        [string]$Profile,
        [Security.SecureString]$Token
    )

    $normalized = Normalize-ProfileName -Profile $Profile
    $profilePath = Get-ProfilePath -Profile $normalized
    Write-ProfileMetadata -Profile $normalized -ProfilePath $profilePath
    Convert-SecureStringToPlainText -SecureString $Token | Set-Content -LiteralPath (Get-ProfileKeyPath -ProfilePath $profilePath) -NoNewline -Encoding UTF8
    Set-ActiveProfile -Profile $normalized
}

function Read-ProfileKey {
    param([string]$Profile)

    $normalized = Normalize-ProfileName -Profile $Profile
    $profilePath = Get-ProfilePath -Profile $normalized
    $keyPath = Get-ProfileKeyPath -ProfilePath $profilePath
    if (-not (Test-Path -LiteralPath $keyPath)) {
        throw "UptimeRobot API key profile does not exist yet: $normalized. Run .\uptimerobot-account.ps1 token-add $normalized first."
    }

    $token = (Get-Content -LiteralPath $keyPath -Raw).Trim()
    if ([string]::IsNullOrWhiteSpace($token)) {
        throw "UptimeRobot API key profile is empty: $normalized"
    }

    return $token
}

function Remove-ProfileKey {
    param([string]$Profile)

    $normalized = Normalize-ProfileName -Profile $Profile
    $profilePath = Get-ProfilePath -Profile $normalized
    $keyPath = Get-ProfileKeyPath -ProfilePath $profilePath
    if (Test-Path -LiteralPath $keyPath) {
        Remove-Item -LiteralPath $keyPath -Force
        Write-Host "Removed saved UptimeRobot API key profile for: $normalized"
    } else {
        Write-Host "No saved UptimeRobot API key profile found for: $normalized"
    }
}

function Set-ActiveProfile {
    param([string]$Profile)

    $normalized = Normalize-ProfileName -Profile $Profile
    New-Item -ItemType Directory -Force -Path $accountRoot | Out-Null
    [ordered]@{
        tool = 'uptimerobot'
        service = 'UptimeRobot'
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
        throw 'No email was provided and no active UptimeRobot email profile is set. Run .\uptimerobot-account.ps1 use <email>.'
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
    $keyPath = Get-ProfileKeyPath -ProfilePath $profilePath
    $exists = Test-Path -LiteralPath $profilePath
    $hasApiKey = Test-Path -LiteralPath $keyPath
    $token = if ($hasApiKey) { (Get-Content -LiteralPath $keyPath -Raw).Trim() } else { $null }
    $active = Get-ActiveProfile

    [pscustomobject]@{
        Profile = $normalized
        Exists = $exists
        IsActive = ($active -eq $normalized)
        HasApiKey = $hasApiKey
        ApiKeyFingerprint = Get-TokenFingerprint -Token $token
        ApiEndpoint = $apiEndpoint
        KeyPath = $keyPath
        State = if (-not $exists) { 'missing-profile' } elseif (-not $hasApiKey) { 'missing-api-key' } elseif ($active -eq $normalized) { 'active' } else { 'configured' }
    }
}

function Get-ApiPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw 'API path is required.'
    }

    if ($Path -match '^https?://') {
        $uri = [uri]$Path
        if ($uri.Host -ne 'api.uptimerobot.com') {
            throw 'Only https://api.uptimerobot.com URLs are allowed.'
        }

        return $uri.PathAndQuery
    }

    if ($Path.StartsWith('/')) {
        return $Path
    }

    return "/$Path"
}

function Invoke-UptimeRobotApi {
    param(
        [string]$Profile,
        [string]$Method,
        [string]$Path,
        [AllowNull()][string]$JsonBody
    )

    $normalized = Normalize-ProfileName -Profile $Profile
    $key = Read-ProfileKey -Profile $normalized
    $apiPath = Get-ApiPath -Path $Path
    if ($apiPath -notmatch '^/v\d+/') {
        $apiPath = "/v3$apiPath"
    }

    $uri = "$apiEndpoint$apiPath"
    $headers = @{
        Authorization = "Bearer $key"
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
            throw "UptimeRobot API $methodUpper $apiPath failed: HTTP $statusCode $statusDescription ($($_.ErrorDetails.Message))"
        }

        throw "UptimeRobot API $methodUpper $apiPath failed: $($_.Exception.Message)"
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
        Write-Host "UptimeRobot profile does not exist: $normalized"
        return
    }

    $backupPath = "$profilePath.logged-out-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Move-Item -LiteralPath $profilePath -Destination $backupPath
    Write-Host "UptimeRobot profile moved to: $backupPath"

    $active = Get-ActiveProfile
    if ($active -eq $normalized -and (Test-Path -LiteralPath $currentFile)) {
        Remove-Item -LiteralPath $currentFile
        Write-Host 'Active UptimeRobot profile cleared.'
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
            throw 'Usage: .\uptimerobot-account.ps1 login <email>'
        }

        $profile = Normalize-ProfileName -Profile $remaining[0]
        Write-Host "Paste an UptimeRobot API key for $profile. Input is hidden; it will be saved as api-key.txt for symmetric mainframe backup/restore."
        $token = Read-Host 'UptimeRobot API key' -AsSecureString
        Write-ProfileKey -Profile $profile -Token $token
        Write-Host "UptimeRobot API key profile is ready and active: $profile"
    }

    'token-clear' {
        $profile = Get-ProfileOrActive -Profile $(if ($remaining.Count -ge 1) { $remaining[0] } else { $null })
        Remove-ProfileKey -Profile $profile
    }

    'use' {
        if ($remaining.Count -ne 1) {
            throw 'Usage: .\uptimerobot-account.ps1 use <email>'
        }

        $profile = Normalize-ProfileName -Profile $remaining[0]
        $profilePath = Get-ProfilePath -Profile $profile
        if (-not (Test-Path -LiteralPath (Get-ProfileKeyPath -ProfilePath $profilePath))) {
            throw "UptimeRobot profile does not exist yet: $profile"
        }

        Set-ActiveProfile -Profile $profile
        Write-Host "Active UptimeRobot profile: $profile"
    }

    'run' {
        if ($remaining.Count -lt 2) {
            throw 'Usage: .\uptimerobot-account.ps1 run [email] <GET|POST|PATCH|DELETE> <api path> [json body]'
        }

        $argOffset = 0
        if (Test-LooksLikeEmail -Value $remaining[0]) {
            $argOffset = 1
        }

        $profile = Get-ProfileOrActive -Profile $(if ($argOffset -eq 1) { $remaining[0] } else { $null })
        $method = $remaining[$argOffset]
        $path = $remaining[$argOffset + 1]
        $body = if ($remaining.Count -gt ($argOffset + 2)) { ($remaining[($argOffset + 2)..($remaining.Count - 1)] -join ' ') } else { $null }
        ConvertTo-JsonOutput -Value (Invoke-UptimeRobotApi -Profile $profile -Method $method -Path $path -JsonBody $body)
    }

    'monitors' {
        $profile = Get-ProfileOrActive -Profile $(if ($remaining.Count -ge 1) { $remaining[0] } else { $null })
        $response = Invoke-UptimeRobotApi -Profile $profile -Method GET -Path '/monitors?limit=50'
        $response | ForEach-Object { $_ } | ConvertTo-Json -Depth 10
    }

    'monitor' {
        if ($remaining.Count -lt 1) {
            throw 'Usage: .\uptimerobot-account.ps1 monitor [email] <monitor-id>'
        }

        $argOffset = 0
        if (Test-LooksLikeEmail -Value $remaining[0]) {
            $argOffset = 1
        }

        $profile = Get-ProfileOrActive -Profile $(if ($argOffset -eq 1) { $remaining[0] } else { $null })
        $monitorId = $remaining[$argOffset]
        ConvertTo-JsonOutput -Value (Invoke-UptimeRobotApi -Profile $profile -Method GET -Path "/monitors/$monitorId")
    }

    'add-monitor' {
        if ($remaining.Count -lt 2) {
            throw 'Usage: .\uptimerobot-account.ps1 add-monitor [email] <url> <name> [interval-seconds]'
        }

        $argOffset = 0
        if (Test-LooksLikeEmail -Value $remaining[0]) {
            $argOffset = 1
        }

        $profile = Get-ProfileOrActive -Profile $(if ($argOffset -eq 1) { $remaining[0] } else { $null })
        $url = $remaining[$argOffset]
        $name = $remaining[$argOffset + 1]
        if (-not $url.StartsWith('http://', [StringComparison]::OrdinalIgnoreCase) -and -not $url.StartsWith('https://', [StringComparison]::OrdinalIgnoreCase)) {
            throw "Monitor URL must start with http:// or https://: $url"
        }

        $interval = if ($remaining.Count -gt ($argOffset + 2)) { [int]$remaining[$argOffset + 2] } else { 300 }
        $body = @{ friendlyName = $name; url = $url; type = 'http'; interval = $interval; timeout = 30 } | ConvertTo-Json -Compress
        ConvertTo-JsonOutput -Value (Invoke-UptimeRobotApi -Profile $profile -Method POST -Path '/monitors' -JsonBody $body)
    }

    'delete-monitor' {
        if ($remaining.Count -lt 1) {
            throw 'Usage: .\uptimerobot-account.ps1 delete-monitor [email] <monitor-id>'
        }

        $argOffset = 0
        if (Test-LooksLikeEmail -Value $remaining[0]) {
            $argOffset = 1
        }

        $profile = Get-ProfileOrActive -Profile $(if ($argOffset -eq 1) { $remaining[0] } else { $null })
        $monitorId = $remaining[$argOffset]
        ConvertTo-JsonOutput -Value (Invoke-UptimeRobotApi -Profile $profile -Method DELETE -Path "/monitors/$monitorId")
    }

    'pause' {
        if ($remaining.Count -lt 1) {
            throw 'Usage: .\uptimerobot-account.ps1 pause [email] <monitor-id>'
        }

        $argOffset = 0
        if (Test-LooksLikeEmail -Value $remaining[0]) {
            $argOffset = 1
        }

        $profile = Get-ProfileOrActive -Profile $(if ($argOffset -eq 1) { $remaining[0] } else { $null })
        $monitorId = $remaining[$argOffset]
        ConvertTo-JsonOutput -Value (Invoke-UptimeRobotApi -Profile $profile -Method POST -Path "/monitors/$monitorId/pause")
    }

    'resume' {
        if ($remaining.Count -lt 1) {
            throw 'Usage: .\uptimerobot-account.ps1 resume [email] <monitor-id>'
        }

        $argOffset = 0
        if (Test-LooksLikeEmail -Value $remaining[0]) {
            $argOffset = 1
        }

        $profile = Get-ProfileOrActive -Profile $(if ($argOffset -eq 1) { $remaining[0] } else { $null })
        $monitorId = $remaining[$argOffset]
        ConvertTo-JsonOutput -Value (Invoke-UptimeRobotApi -Profile $profile -Method POST -Path "/monitors/$monitorId/start")
    }

    'psp' {
        $profile = Get-ProfileOrActive -Profile $(if ($remaining.Count -ge 1) { $remaining[0] } else { $null })
        ConvertTo-JsonOutput -Value (Invoke-UptimeRobotApi -Profile $profile -Method GET -Path '/psps')
    }

    'new-psp' {
        if ($remaining.Count -lt 2) {
            throw 'Usage: .\uptimerobot-account.ps1 new-psp [email] <name> <monitor-id,...>'
        }

        $argOffset = 0
        if (Test-LooksLikeEmail -Value $remaining[0]) {
            $argOffset = 1
        }

        $profile = Get-ProfileOrActive -Profile $(if ($argOffset -eq 1) { $remaining[0] } else { $null })
        $name = $remaining[$argOffset]
        $monitorIds = @($remaining[$argOffset + 1] -split ',' | ForEach-Object { [int]$_.Trim() })
        $body = @{ friendlyName = $name; monitorIds = $monitorIds } | ConvertTo-Json -Compress
        ConvertTo-JsonOutput -Value (Invoke-UptimeRobotApi -Profile $profile -Method POST -Path '/psps' -JsonBody $body)
    }

    'psp-monitors' {
        if ($remaining.Count -lt 2) {
            throw 'Usage: .\uptimerobot-account.ps1 psp-monitors [email] <psp-id> <monitor-id,...>'
        }

        $argOffset = 0
        if (Test-LooksLikeEmail -Value $remaining[0]) {
            $argOffset = 1
        }

        $profile = Get-ProfileOrActive -Profile $(if ($argOffset -eq 1) { $remaining[0] } else { $null })
        $pspId = $remaining[$argOffset]
        $monitorIds = @($remaining[$argOffset + 1] -split ',' | ForEach-Object { [int]$_.Trim() })
        $body = @{ monitorIds = $monitorIds } | ConvertTo-Json -Compress
        ConvertTo-JsonOutput -Value (Invoke-UptimeRobotApi -Profile $profile -Method PATCH -Path "/psps/$pspId" -JsonBody $body)
    }

    'status' {
        $profile = Get-ProfileOrActive -Profile $(if ($remaining.Count -ge 1) { $remaining[0] } else { $null })
        Get-ProfileStatus -Profile $profile | Format-List
    }

    'status-all' {
        if (-not (Test-Path -LiteralPath $accountRoot)) {
            Write-Host 'No UptimeRobot profiles found.'
            return
        }

        $profiles = @(Get-ChildItem -LiteralPath $accountRoot -Directory -Force | Where-Object { $_.Name -match '^[^\s@]+@[^\s@]+\.[^\s@]+$' } | Sort-Object Name)
        if ($profiles.Count -eq 0) {
            Write-Host 'No UptimeRobot profiles found.'
            return
        }

        $profiles |
            ForEach-Object { Get-ProfileStatus -Profile (Get-ProfileName -Directory $_) } |
            Format-Table -AutoSize
    }

    'list' {
        if (-not (Test-Path -LiteralPath $accountRoot)) {
            Write-Host 'No UptimeRobot profiles found.'
            return
        }

        $active = Get-ActiveProfile
        $profiles = @(Get-ChildItem -LiteralPath $accountRoot -Directory -Force | Where-Object { $_.Name -match '^[^\s@]+@[^\s@]+\.[^\s@]+$' } | Sort-Object Name)
        if ($profiles.Count -eq 0) {
            Write-Host 'No UptimeRobot profiles found.'
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
            Write-Host 'No active UptimeRobot email profile set.'
        }
    }

    'path' {
        $profile = Get-ProfileOrActive -Profile $(if ($remaining.Count -ge 1) { $remaining[0] } else { $null })
        Write-Host (Get-ProfilePath -Profile $profile)
    }

    'env' {
        $profile = Get-ProfileOrActive -Profile $(if ($remaining.Count -ge 1) { $remaining[0] } else { $null })
        $profilePath = Get-ProfilePath -Profile $profile
        $keyPath = Get-ProfileKeyPath -ProfilePath $profilePath
        $keyState = if (Test-Path -LiteralPath $keyPath) { '<profile api key>' } else { '<missing api key>' }
        Write-Host "`$env:UPTIMEROBOT_API_KEY = $keyState"
        Write-Host "`$env:UPTIMEROBOT_API_ENDPOINT = '$apiEndpoint'"
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