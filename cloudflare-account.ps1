$ErrorActionPreference = 'Stop'

$accountRoot = Join-Path $env:APPDATA 'mainframe\accounts\cloudflare'
$currentFile = Join-Path $accountRoot 'current.json'
$apiEndpoint = 'https://api.cloudflare.com/client/v4'

function Show-Usage {
    @(
        'Cloudflare account profile helper',
        '',
        'Profiles are keyed by account email only and stored in:',
        '  %APPDATA%\mainframe\accounts\cloudflare\<email>',
        '',
        'Cloudflare automation can use API tokens or isolated Wrangler browser auth.',
        'This helper stores one token or Wrangler OAuth state per mainframe email',
        'profile, then injects only the selected profile while a command runs.',
        '',
        'Usage:',
        '  .\cloudflare-account.ps1 login',
        '  .\cloudflare-account.ps1 token-add [account-id]',
        '  .\cloudflare-account.ps1 import-current [account-id]',
        '  .\cloudflare-account.ps1 token-clear [email]',
        '  .\cloudflare-account.ps1 use <email>',
        '  .\cloudflare-account.ps1 run [email] <wrangler args...>',
        '  .\cloudflare-account.ps1 whoami [email]',
        '  .\cloudflare-account.ps1 api <email> <GET|POST|PUT|PATCH|DELETE> <api path> [json body]',
        '  .\cloudflare-account.ps1 verify [email]',
        '  .\cloudflare-account.ps1 accounts [email]',
        '  .\cloudflare-account.ps1 zones [email]',
        '  .\cloudflare-account.ps1 dns <email> <zone-id>',
        '  .\cloudflare-account.ps1 export <email> [output-path]',
        '  .\cloudflare-account.ps1 status [email]',
        '  .\cloudflare-account.ps1 status-all',
        '  .\cloudflare-account.ps1 list',
        '  .\cloudflare-account.ps1 current',
        '  .\cloudflare-account.ps1 path [email]',
        '  .\cloudflare-account.ps1 env [email]',
        '  .\cloudflare-account.ps1 logout [email]',
        '',
        'Examples:',
        '  .\cloudflare-account.ps1 login',
        '  .\cloudflare-account.ps1 token-add',
        '  .\cloudflare-account.ps1 whoami user@example.com',
        '  .\cloudflare-account.ps1 verify user@example.com',
        '  .\cloudflare-account.ps1 zones user@example.com',
        '  .\cloudflare-account.ps1 dns user@example.com ZONE_ID',
        '  .\cloudflare-account.ps1 export user@example.com',
        '  .\cloudflare-account.ps1 run user@example.com --version',
        '  .\cloudflare-account.ps1 run --version'
    ) -join [Environment]::NewLine | Write-Host
}

function Normalize-ProfileName {
    param([string]$Profile)

    if ([string]::IsNullOrWhiteSpace($Profile)) {
        throw 'Email profile is required.'
    }

    $normalized = $Profile.Trim().ToLowerInvariant()
    if ($normalized -notmatch '^[^\s@]+@[^\s@]+\.[^\s@]+$') {
        throw "Cloudflare profile must be an account email, not a label or username: $Profile"
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

function Get-TokenPath {
    param([string]$ProfilePath)

    return Join-Path $ProfilePath 'token.txt'
}

function Get-AccountIdPath {
    param([string]$ProfilePath)

    return Join-Path $ProfilePath 'account-id.txt'
}

function Get-WranglerStatePath {
    param([string]$ProfilePath)

    return Join-Path $ProfilePath 'wrangler-oauth'
}

function Get-DefaultExportPath {
    param([string]$ProfilePath)

    return Join-Path $ProfilePath 'cloudflare-export.json'
}

function Assert-PathUnderRoot {
    param(
        [string]$Path,
        [string]$Root
    )

    $resolvedRoot = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $resolvedPath = [IO.Path]::GetFullPath($Path).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    if (-not ($resolvedPath.Equals($resolvedRoot, [StringComparison]::OrdinalIgnoreCase) -or $resolvedPath.StartsWith("$resolvedRoot$([IO.Path]::DirectorySeparatorChar)", [StringComparison]::OrdinalIgnoreCase))) {
        throw "Refusing to operate outside mainframe Cloudflare account storage: $Path"
    }
}

function Set-ProcessEnvironmentValue {
    param(
        [string]$Name,
        [AllowNull()][string]$Value
    )

    if ($null -eq $Value) {
        Remove-Item -Path "Env:$Name" -ErrorAction SilentlyContinue
    } else {
        Set-Item -Path "Env:$Name" -Value $Value
    }
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

function Write-ProfileMetadata {
    param(
        [string]$Profile,
        [string]$ProfilePath,
        [AllowNull()][string]$AccountId,
        [AllowNull()][string]$AuthType
    )

    New-Item -ItemType Directory -Force -Path $ProfilePath | Out-Null
    [ordered]@{
        tool = 'cloudflare'
        service = 'cloudflare.com'
        profile = $Profile
        authType = $AuthType
        apiEndpoint = $apiEndpoint
        accountId = $AccountId
        tokenPath = (Get-TokenPath -ProfilePath $ProfilePath)
        wranglerStatePath = (Get-WranglerStatePath -ProfilePath $ProfilePath)
        updatedAt = (Get-Date).ToString('o')
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $ProfilePath 'profile.json') -Encoding UTF8
}

function Read-ProfileMetadata {
    param([string]$ProfilePath)

    $metadataPath = Join-Path $ProfilePath 'profile.json'
    if (-not (Test-Path -LiteralPath $metadataPath)) {
        return $null
    }

    try {
        return Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
    } catch {
        Write-Warning "Could not read profile metadata: $metadataPath"
        return $null
    }
}

function Set-ActiveProfile {
    param([string]$Profile)

    $normalized = Normalize-ProfileName -Profile $Profile
    New-Item -ItemType Directory -Force -Path $accountRoot | Out-Null
    [ordered]@{
        tool = 'cloudflare'
        service = 'cloudflare.com'
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
        throw 'No email was provided and no active Cloudflare email profile is set. Run .\cloudflare-account.ps1 use <email>.'
    }

    return Normalize-ProfileName -Profile $active
}

function Write-ProfileTokenValue {
    param(
        [string]$Profile,
        [string]$Token,
        [AllowNull()][string]$AccountId
    )

    if ([string]::IsNullOrWhiteSpace($Token)) {
        throw 'Cloudflare API token is empty.'
    }

    $normalized = Normalize-ProfileName -Profile $Profile
    $profilePath = Get-ProfilePath -Profile $normalized
    New-Item -ItemType Directory -Force -Path $profilePath | Out-Null
    $Token.Trim() | Set-Content -LiteralPath (Get-TokenPath -ProfilePath $profilePath) -NoNewline -Encoding UTF8
    if (-not [string]::IsNullOrWhiteSpace($AccountId)) {
        $AccountId.Trim() | Set-Content -LiteralPath (Get-AccountIdPath -ProfilePath $profilePath) -NoNewline -Encoding UTF8
    }

    Write-ProfileMetadata -Profile $normalized -ProfilePath $profilePath -AccountId $AccountId -AuthType 'api-token'
    Set-ActiveProfile -Profile $normalized
}

function Write-ProfileWranglerState {
    param(
        [string]$Profile,
        [string]$StateRoot,
        [AllowNull()][string]$AccountId
    )

    $normalized = Normalize-ProfileName -Profile $Profile
    $profilePath = Get-ProfilePath -Profile $normalized
    $destination = Get-WranglerStatePath -ProfilePath $profilePath
    Assert-PathUnderRoot -Path $profilePath -Root $accountRoot
    Assert-PathUnderRoot -Path $destination -Root $accountRoot
    Assert-PathUnderRoot -Path $StateRoot -Root $accountRoot

    if (-not (Test-Path -LiteralPath $StateRoot)) {
        throw "Wrangler OAuth state was not found: $StateRoot"
    }

    New-Item -ItemType Directory -Force -Path $profilePath | Out-Null
    if (Test-Path -LiteralPath $destination) {
        Remove-Item -LiteralPath $destination -Recurse -Force
    }

    Move-Item -LiteralPath $StateRoot -Destination $destination
    if (-not [string]::IsNullOrWhiteSpace($AccountId)) {
        $AccountId.Trim() | Set-Content -LiteralPath (Get-AccountIdPath -ProfilePath $profilePath) -NoNewline -Encoding UTF8
    }

    Write-ProfileMetadata -Profile $normalized -ProfilePath $profilePath -AccountId $AccountId -AuthType 'wrangler-oauth'
    Set-ActiveProfile -Profile $normalized
}

function Read-ProfileToken {
    param([string]$Profile)

    $normalized = Normalize-ProfileName -Profile $Profile
    $profilePath = Get-ProfilePath -Profile $normalized
    $tokenPath = Get-TokenPath -ProfilePath $profilePath
    if (-not (Test-Path -LiteralPath $tokenPath)) {
        throw "Cloudflare API token does not exist for profile: $normalized. Run .\cloudflare-account.ps1 token-add for API calls, or use .\cloudflare-account.ps1 run/whoami if this is a browser-login profile."
    }

    $token = (Get-Content -LiteralPath $tokenPath -Raw).Trim()
    if ([string]::IsNullOrWhiteSpace($token)) {
        throw "Cloudflare token profile is empty: $normalized"
    }

    return $token
}

function Read-ProfileAccountId {
    param([string]$Profile)

    $normalized = Normalize-ProfileName -Profile $Profile
    $profilePath = Get-ProfilePath -Profile $normalized
    $accountIdPath = Get-AccountIdPath -ProfilePath $profilePath
    if (Test-Path -LiteralPath $accountIdPath) {
        $accountId = (Get-Content -LiteralPath $accountIdPath -Raw).Trim()
        if (-not [string]::IsNullOrWhiteSpace($accountId)) {
            return $accountId
        }
    }

    $metadata = Read-ProfileMetadata -ProfilePath $profilePath
    if ($metadata -and $metadata.accountId) {
        return [string]$metadata.accountId
    }

    return $null
}

function Get-WranglerCommand {
    $cmd = Get-Command wrangler -ErrorAction SilentlyContinue
    if ($cmd) {
        return $cmd.Source
    }

    throw 'Wrangler CLI was not found. Install it with: pnpm add -g wrangler'
}

function Invoke-WithWranglerState {
    param(
        [string]$StateRoot,
        [scriptblock]$Script,
        [AllowNull()][string]$AccountId
    )

    Assert-PathUnderRoot -Path $StateRoot -Root $accountRoot
    $paths = [ordered]@{
        XDG_CONFIG_HOME = (Join-Path $StateRoot 'xdg-config')
        XDG_CACHE_HOME = (Join-Path $StateRoot 'xdg-cache')
        XDG_DATA_HOME = (Join-Path $StateRoot 'xdg-data')
        XDG_STATE_HOME = (Join-Path $StateRoot 'xdg-state')
    }

    foreach ($path in $paths.Values) {
        New-Item -ItemType Directory -Force -Path $path | Out-Null
    }

    $environmentKeys = @(
        'XDG_CONFIG_HOME',
        'XDG_CACHE_HOME',
        'XDG_DATA_HOME',
        'XDG_STATE_HOME',
        'CLOUDFLARE_API_TOKEN',
        'CF_API_TOKEN',
        'CLOUDFLARE_API_KEY',
        'CLOUDFLARE_EMAIL',
        'CLOUDFLARE_ACCOUNT_ID'
    )
    $oldValues = @{}
    foreach ($key in $environmentKeys) {
        $oldValues[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
    }

    try {
        foreach ($entry in $paths.GetEnumerator()) {
            Set-ProcessEnvironmentValue -Name $entry.Key -Value $entry.Value
        }

        foreach ($key in @('CLOUDFLARE_API_TOKEN', 'CF_API_TOKEN', 'CLOUDFLARE_API_KEY', 'CLOUDFLARE_EMAIL')) {
            Set-ProcessEnvironmentValue -Name $key -Value $null
        }

        if ([string]::IsNullOrWhiteSpace($AccountId)) {
            Set-ProcessEnvironmentValue -Name 'CLOUDFLARE_ACCOUNT_ID' -Value $null
        } else {
            Set-ProcessEnvironmentValue -Name 'CLOUDFLARE_ACCOUNT_ID' -Value $AccountId
        }

        & $Script
    } finally {
        foreach ($key in $environmentKeys) {
            Set-ProcessEnvironmentValue -Name $key -Value $oldValues[$key]
        }
    }
}

function Invoke-WranglerForOutput {
    param(
        [string]$Wrangler,
        [string[]]$WranglerArgs
    )

    $output = & $Wrangler @WranglerArgs 2>&1
    $exitCode = $LASTEXITCODE
    $text = ($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
    if ($exitCode -ne 0) {
        throw "wrangler $($WranglerArgs -join ' ') failed with exit code $exitCode. $text"
    }

    return $text
}

function ConvertFrom-WranglerJsonOutput {
    param([string]$Output)

    if ([string]::IsNullOrWhiteSpace($Output)) {
        throw 'Wrangler returned empty JSON output.'
    }

    $start = $Output.IndexOf('{')
    $end = $Output.LastIndexOf('}')
    if ($start -lt 0 -or $end -lt $start) {
        throw "Wrangler output did not contain JSON: $Output"
    }

    return $Output.Substring($start, $end - $start + 1) | ConvertFrom-Json
}

function Get-AccountIdFromWranglerWhoami {
    param($Whoami)

    $accounts = @($Whoami.accounts)
    if ($accounts.Count -ne 1) {
        return $null
    }

    foreach ($key in @('id', 'accountId', 'account_id')) {
        if ($accounts[0].PSObject.Properties.Name -contains $key -and -not [string]::IsNullOrWhiteSpace([string]$accounts[0].$key)) {
            return [string]$accounts[0].$key
        }
    }

    return $null
}

function Invoke-WithCloudflareProfile {
    param(
        [string]$Profile,
        [scriptblock]$Script
    )

    $normalized = Normalize-ProfileName -Profile $Profile
    $profilePath = Get-ProfilePath -Profile $normalized
    $tokenPath = Get-TokenPath -ProfilePath $profilePath
    $wranglerStatePath = Get-WranglerStatePath -ProfilePath $profilePath
    $accountId = Read-ProfileAccountId -Profile $normalized

    if (-not (Test-Path -LiteralPath $tokenPath)) {
        if (Test-Path -LiteralPath $wranglerStatePath) {
            return Invoke-WithWranglerState -StateRoot $wranglerStatePath -AccountId $accountId -Script $Script
        }

        throw "Cloudflare profile does not have saved auth yet: $normalized. Run .\cloudflare-account.ps1 login or .\cloudflare-account.ps1 token-add first."
    }

    $token = Read-ProfileToken -Profile $normalized
    $oldToken = $env:CLOUDFLARE_API_TOKEN
    $oldCfToken = $env:CF_API_TOKEN
    $oldAccountId = $env:CLOUDFLARE_ACCOUNT_ID
    try {
        $env:CLOUDFLARE_API_TOKEN = $token
        $env:CF_API_TOKEN = $token
        if ([string]::IsNullOrWhiteSpace($accountId)) {
            Remove-Item Env:\CLOUDFLARE_ACCOUNT_ID -ErrorAction SilentlyContinue
        } else {
            $env:CLOUDFLARE_ACCOUNT_ID = $accountId
        }

        & $Script
    } finally {
        if ([string]::IsNullOrWhiteSpace($oldToken)) {
            Remove-Item Env:\CLOUDFLARE_API_TOKEN -ErrorAction SilentlyContinue
        } else {
            $env:CLOUDFLARE_API_TOKEN = $oldToken
        }

        if ([string]::IsNullOrWhiteSpace($oldCfToken)) {
            Remove-Item Env:\CF_API_TOKEN -ErrorAction SilentlyContinue
        } else {
            $env:CF_API_TOKEN = $oldCfToken
        }

        if ([string]::IsNullOrWhiteSpace($oldAccountId)) {
            Remove-Item Env:\CLOUDFLARE_ACCOUNT_ID -ErrorAction SilentlyContinue
        } else {
            $env:CLOUDFLARE_ACCOUNT_ID = $oldAccountId
        }
    }
}

function Get-ApiPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw 'API path is required.'
    }

    if ($Path -match '^https?://') {
        $uri = [uri]$Path
        if ($uri.Host -ne 'api.cloudflare.com') {
            throw 'Only https://api.cloudflare.com URLs are allowed.'
        }

        if ($uri.AbsolutePath -like '/client/v4/*') {
            return $uri.PathAndQuery.Substring('/client/v4'.Length)
        }

        return $uri.PathAndQuery
    }

    if ($Path.StartsWith('/client/v4/')) {
        return $Path.Substring('/client/v4'.Length)
    }

    if ($Path.StartsWith('/')) {
        return $Path
    }

    return "/$Path"
}

function Invoke-CloudflareApi {
    param(
        [string]$Profile,
        [string]$Method,
        [string]$Path,
        [AllowNull()][string]$JsonBody
    )

    $normalized = Normalize-ProfileName -Profile $Profile
    $token = Read-ProfileToken -Profile $normalized
    $apiPath = Get-ApiPath -Path $Path
    $uri = "$apiEndpoint$apiPath"
    $headers = @{
        Authorization = "Bearer $token"
        Accept = 'application/json'
    }

    $methodUpper = $Method.ToUpperInvariant()
    if ($methodUpper -notin @('GET', 'POST', 'PUT', 'PATCH', 'DELETE')) {
        throw 'Method must be one of: GET, POST, PUT, PATCH, DELETE.'
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
            throw "Cloudflare API $methodUpper $apiPath failed: HTTP $statusCode $statusDescription"
        }

        throw "Cloudflare API $methodUpper $apiPath failed: $($_.Exception.Message)"
    }
}

function ConvertTo-JsonOutput {
    param([AllowNull()]$Value)

    if ($null -eq $Value) {
        Write-Host '{}'
        return
    }

    $Value | ConvertTo-Json -Depth 32
}

function Invoke-CloudflareApiWithToken {
    param(
        [string]$Token,
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Token)) {
        return $null
    }

    try {
        return Invoke-RestMethod -Method GET -Uri "$apiEndpoint$Path" -Headers @{
            Authorization = "Bearer $($Token.Trim())"
            Accept = 'application/json'
        } -ContentType 'application/json'
    } catch {
        return $null
    }
}

function Resolve-CloudflareProfileFromToken {
    param([string]$Token)

    $user = Invoke-CloudflareApiWithToken -Token $Token -Path '/user'
    $email = [string]$user.result.email
    if (-not [string]::IsNullOrWhiteSpace($email)) {
        return Normalize-ProfileName -Profile $email
    }

    return $null
}

function Export-CloudflareState {
    param(
        [string]$Profile,
        [AllowNull()][string]$OutputPath
    )

    $normalized = Normalize-ProfileName -Profile $Profile
    $profilePath = Get-ProfilePath -Profile $normalized
    if ([string]::IsNullOrWhiteSpace($OutputPath)) {
        $OutputPath = Get-DefaultExportPath -ProfilePath $profilePath
    }
    if (-not [IO.Path]::IsPathRooted($OutputPath)) {
        $OutputPath = Join-Path (Get-Location) $OutputPath
    }

    $verify = Invoke-CloudflareApi -Profile $normalized -Method GET -Path '/user/tokens/verify' -JsonBody $null
    $accounts = Invoke-CloudflareApi -Profile $normalized -Method GET -Path '/accounts' -JsonBody $null
    $zones = Invoke-CloudflareApi -Profile $normalized -Method GET -Path '/zones?per_page=100' -JsonBody $null
    $zoneExports = @()
    foreach ($zone in @($zones.result)) {
        if (-not $zone.id) {
            continue
        }

        $dnsRecords = Invoke-CloudflareApi -Profile $normalized -Method GET -Path "/zones/$($zone.id)/dns_records?per_page=500" -JsonBody $null
        $zoneExports += [ordered]@{
            id = $zone.id
            name = $zone.name
            status = $zone.status
            account = $zone.account
            dnsRecords = @($dnsRecords.result)
        }
    }

    $export = [ordered]@{
        tool = 'cloudflare'
        service = 'cloudflare.com'
        schemaVersion = 1
        profile = $normalized
        apiEndpoint = $apiEndpoint
        exportedAt = (Get-Date).ToString('o')
        note = 'Private Cloudflare export. DNS records, comments, routes, hostnames, and account metadata may be sensitive.'
        token = [ordered]@{
            status = if ($verify.result -and $verify.result.status) { $verify.result.status } else { $null }
            id = if ($verify.result -and $verify.result.id) { $verify.result.id } else { $null }
        }
        accounts = @($accounts.result)
        zones = @($zoneExports)
    }

    $outputParent = Split-Path -Parent $OutputPath
    if (-not [string]::IsNullOrWhiteSpace($outputParent)) {
        New-Item -ItemType Directory -Force -Path $outputParent | Out-Null
    }
    $export | ConvertTo-Json -Depth 64 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
    Write-Host "Exported Cloudflare state for $normalized to: $OutputPath"
}

function Get-ProfileStatus {
    param([string]$Profile)

    $normalized = Normalize-ProfileName -Profile $Profile
    $profilePath = Get-ProfilePath -Profile $normalized
    $tokenPath = Get-TokenPath -ProfilePath $profilePath
    $wranglerStatePath = Get-WranglerStatePath -ProfilePath $profilePath
    $accountId = Read-ProfileAccountId -Profile $normalized
    $exists = Test-Path -LiteralPath $profilePath
    $hasToken = Test-Path -LiteralPath $tokenPath
    $hasWranglerState = Test-Path -LiteralPath $wranglerStatePath
    $active = Get-ActiveProfile

    [pscustomobject]@{
        Profile = $normalized
        Exists = $exists
        IsActive = ($active -eq $normalized)
        HasToken = $hasToken
        HasWranglerOAuth = $hasWranglerState
        AuthType = if ($hasToken) { 'api-token' } elseif ($hasWranglerState) { 'wrangler-oauth' } else { $null }
        TokenStatus = if ($hasToken) { 'present' } else { 'missing' }
        AccountId = if ($accountId) { $accountId } else { $null }
        WranglerInstalled = [bool](Get-Command wrangler -ErrorAction SilentlyContinue)
        ApiEndpoint = $apiEndpoint
        ProfilePath = $profilePath
        State = if (-not $exists) { 'missing-profile' } elseif (-not ($hasToken -or $hasWranglerState)) { 'missing-auth' } elseif ($active -eq $normalized) { 'active' } else { 'configured' }
    }
}

function Get-ProfileName {
    param([IO.DirectoryInfo]$Directory)

    $metadata = Read-ProfileMetadata -ProfilePath $Directory.FullName
    if ($metadata -and $metadata.profile) {
        return [string]$metadata.profile
    }

    return $Directory.Name
}

function Remove-ProfileToken {
    param([string]$Profile)

    $normalized = Normalize-ProfileName -Profile $Profile
    $profilePath = Get-ProfilePath -Profile $normalized
    $removed = $false
    foreach ($path in @(
        (Get-TokenPath -ProfilePath $profilePath),
        (Get-AccountIdPath -ProfilePath $profilePath)
    )) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Force
            $removed = $true
        }
    }

    if ($removed) {
        Write-Host "Removed saved Cloudflare token profile for: $normalized"
    } else {
        Write-Host "No saved Cloudflare token profile found for: $normalized"
    }
}

function Remove-Profile {
    param([string]$Profile)

    $normalized = Normalize-ProfileName -Profile $Profile
    $profilePath = Get-ProfilePath -Profile $normalized
    if (-not (Test-Path -LiteralPath $profilePath)) {
        Write-Host "Cloudflare profile does not exist: $normalized"
        return
    }

    $backupPath = "$profilePath.logged-out-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Move-Item -LiteralPath $profilePath -Destination $backupPath
    Write-Host "Cloudflare profile moved to: $backupPath"

    $active = Get-ActiveProfile
    if ($active -eq $normalized -and (Test-Path -LiteralPath $currentFile)) {
        Remove-Item -LiteralPath $currentFile
        Write-Host 'Active Cloudflare profile cleared.'
    }
}

$command = if ($args.Count -gt 0) { $args[0].ToLowerInvariant() } else { 'help' }
$remaining = @($args | Select-Object -Skip 1)

switch ($command) {
    'help' {
        Show-Usage
    }

    'login' {
        if ($remaining.Count -ne 0) {
            throw 'Usage: .\cloudflare-account.ps1 login'
        }

        $wrangler = Get-WranglerCommand
        $stagingRoot = Join-Path $accountRoot ".wrangler-login-$([guid]::NewGuid().ToString('N'))"
        Assert-PathUnderRoot -Path $stagingRoot -Root $accountRoot
        New-Item -ItemType Directory -Force -Path $stagingRoot | Out-Null

        try {
            $whoamiRaw = Invoke-WithWranglerState -StateRoot $stagingRoot -Script {
                Write-Host 'Opening Cloudflare auth through Wrangler in the default browser profile.'
                Write-Host 'Mainframe isolates Wrangler auth state without changing browser profile environment.'
                & $wrangler login --browser true
                if ($LASTEXITCODE -ne 0) {
                    throw "wrangler login failed with exit code $LASTEXITCODE"
                }

                Invoke-WranglerForOutput -Wrangler $wrangler -WranglerArgs @('whoami', '--json')
            }

            $whoami = ConvertFrom-WranglerJsonOutput -Output ($whoamiRaw -join [Environment]::NewLine)
            if ($whoami.loggedIn -eq $false) {
                throw 'Wrangler reports that no Cloudflare account is logged in.'
            }

            $profile = Normalize-ProfileName -Profile ([string]$whoami.email)
            $accountId = Get-AccountIdFromWranglerWhoami -Whoami $whoami
            Write-ProfileWranglerState -Profile $profile -StateRoot $stagingRoot -AccountId $accountId
            $stagingRoot = $null
            Write-Host "Cloudflare Wrangler browser profile is ready and active: $profile"
        } finally {
            if (-not [string]::IsNullOrWhiteSpace($stagingRoot) -and (Test-Path -LiteralPath $stagingRoot)) {
                Assert-PathUnderRoot -Path $stagingRoot -Root $accountRoot
                Remove-Item -LiteralPath $stagingRoot -Recurse -Force
            }
        }
    }

    { $_ -in @('token-add', 'add') } {
        if ($remaining.Count -gt 1) {
            throw 'Usage: .\cloudflare-account.ps1 token-add [account-id]'
        }

        if ($remaining.Count -eq 1 -and $remaining[0] -match '^[^\s@]+@[^\s@]+\.[^\s@]+$') {
            throw 'Do not pass a Cloudflare profile argument to token-add. The email must be detected from the token.'
        }

        $accountId = if ($remaining.Count -eq 1) { [string]$remaining[0] } else { $null }
        Write-Host 'Paste a Cloudflare API token. Input is hidden; mainframe will detect the account email and save it as token.txt.'
        $token = Read-Host 'Cloudflare API token' -AsSecureString
        $plainToken = Convert-SecureStringToPlainText -SecureString $token
        $profile = Resolve-CloudflareProfileFromToken -Token $plainToken
        if (-not $profile) {
            throw 'Could not auto-detect the Cloudflare account email from that token. Refusing to save a label, username, account name, or account ID fallback.'
        }

        Write-Host "Detected Cloudflare email: $profile"
        Write-ProfileTokenValue -Profile $profile -Token $plainToken -AccountId $accountId
        Write-Host "Cloudflare token profile is ready and active: $profile"
    }

    'import-current' {
        if ($remaining.Count -gt 1) {
            throw 'Usage: .\cloudflare-account.ps1 import-current [account-id]'
        }

        if ([string]::IsNullOrWhiteSpace($env:CLOUDFLARE_API_TOKEN)) {
            throw 'No current CLOUDFLARE_API_TOKEN environment variable was found.'
        }

        if ($remaining.Count -eq 1 -and $remaining[0] -match '^[^\s@]+@[^\s@]+\.[^\s@]+$') {
            throw 'Do not pass a Cloudflare profile argument to import-current. The email must be detected from CLOUDFLARE_API_TOKEN.'
        }

        $profile = Resolve-CloudflareProfileFromToken -Token $env:CLOUDFLARE_API_TOKEN
        if (-not $profile) {
            throw 'Could not auto-detect the Cloudflare account email from CLOUDFLARE_API_TOKEN. Refusing to save a label, username, account name, or account ID fallback.'
        }

        $accountId = if ($remaining.Count -eq 1) { [string]$remaining[0] } elseif (-not [string]::IsNullOrWhiteSpace($env:CLOUDFLARE_ACCOUNT_ID)) { $env:CLOUDFLARE_ACCOUNT_ID } else { $null }
        Write-ProfileTokenValue -Profile $profile -Token $env:CLOUDFLARE_API_TOKEN -AccountId $accountId
        Write-Host "Imported current Cloudflare token into profile: $profile"
    }

    'token-clear' {
        $profile = Get-ProfileOrActive -Profile $(if ($remaining.Count -ge 1) { $remaining[0] } else { $null })
        Remove-ProfileToken -Profile $profile
    }

    'use' {
        if ($remaining.Count -ne 1) {
            throw 'Usage: .\cloudflare-account.ps1 use <email>'
        }

        $profile = Normalize-ProfileName -Profile $remaining[0]
        $profilePath = Get-ProfilePath -Profile $profile
        $hasToken = Test-Path -LiteralPath (Get-TokenPath -ProfilePath $profilePath)
        $hasWranglerState = Test-Path -LiteralPath (Get-WranglerStatePath -ProfilePath $profilePath)
        if (-not ($hasToken -or $hasWranglerState)) {
            throw "Cloudflare profile does not exist yet: $profile"
        }

        Set-ActiveProfile -Profile $profile
        Write-Host "Active Cloudflare profile: $profile"
    }

    'run' {
        if ($remaining.Count -lt 1) {
            throw 'Usage: .\cloudflare-account.ps1 run [email] <wrangler args...>'
        }

        if (Test-LooksLikeEmail -Value $remaining[0]) {
            if ($remaining.Count -lt 2) {
                throw 'Usage: .\cloudflare-account.ps1 run [email] <wrangler args...>'
            }

            $profile = Normalize-ProfileName -Profile $remaining[0]
            $wranglerArgs = @($remaining | Select-Object -Skip 1)
        } else {
            $profile = Get-ProfileOrActive -Profile $null
            $wranglerArgs = @($remaining)
        }

        $wrangler = Get-WranglerCommand
        Invoke-WithCloudflareProfile -Profile $profile -Script {
            & $wrangler @wranglerArgs
            if ($LASTEXITCODE -ne 0) {
                throw "wrangler $($wranglerArgs -join ' ') failed with exit code $LASTEXITCODE"
            }
        }
    }

    'whoami' {
        if ($remaining.Count -gt 1) {
            throw 'Usage: .\cloudflare-account.ps1 whoami [email]'
        }

        $profile = Get-ProfileOrActive -Profile $(if ($remaining.Count -ge 1) { $remaining[0] } else { $null })
        $wrangler = Get-WranglerCommand
        Invoke-WithCloudflareProfile -Profile $profile -Script {
            & $wrangler whoami --json
            if ($LASTEXITCODE -ne 0) {
                throw "wrangler whoami --json failed with exit code $LASTEXITCODE"
            }
        }
    }

    'api' {
        if ($remaining.Count -lt 3) {
            throw 'Usage: .\cloudflare-account.ps1 api <email> <GET|POST|PUT|PATCH|DELETE> <api path> [json body]'
        }

        $profile = Normalize-ProfileName -Profile $remaining[0]
        $method = $remaining[1]
        $path = $remaining[2]
        $body = if ($remaining.Count -gt 3) { ($remaining[3..($remaining.Count - 1)] -join ' ') } else { $null }
        ConvertTo-JsonOutput -Value (Invoke-CloudflareApi -Profile $profile -Method $method -Path $path -JsonBody $body)
    }

    'verify' {
        $profile = Get-ProfileOrActive -Profile $(if ($remaining.Count -ge 1) { $remaining[0] } else { $null })
        ConvertTo-JsonOutput -Value (Invoke-CloudflareApi -Profile $profile -Method GET -Path '/user/tokens/verify' -JsonBody $null)
    }

    'accounts' {
        $profile = Get-ProfileOrActive -Profile $(if ($remaining.Count -ge 1) { $remaining[0] } else { $null })
        ConvertTo-JsonOutput -Value (Invoke-CloudflareApi -Profile $profile -Method GET -Path '/accounts' -JsonBody $null)
    }

    'zones' {
        $profile = Get-ProfileOrActive -Profile $(if ($remaining.Count -ge 1) { $remaining[0] } else { $null })
        ConvertTo-JsonOutput -Value (Invoke-CloudflareApi -Profile $profile -Method GET -Path '/zones?per_page=100' -JsonBody $null)
    }

    'dns' {
        if ($remaining.Count -lt 2) {
            throw 'Usage: .\cloudflare-account.ps1 dns <email> <zone-id>'
        }

        $profile = Normalize-ProfileName -Profile $remaining[0]
        $zoneId = [string]$remaining[1]
        ConvertTo-JsonOutput -Value (Invoke-CloudflareApi -Profile $profile -Method GET -Path "/zones/$zoneId/dns_records?per_page=500" -JsonBody $null)
    }

    'export' {
        if ($remaining.Count -lt 1) {
            throw 'Usage: .\cloudflare-account.ps1 export <email> [output-path]'
        }

        $profile = Normalize-ProfileName -Profile $remaining[0]
        $outputPath = if ($remaining.Count -gt 1) { $remaining[1] } else { $null }
        Export-CloudflareState -Profile $profile -OutputPath $outputPath
    }

    'status' {
        $profile = Get-ProfileOrActive -Profile $(if ($remaining.Count -ge 1) { $remaining[0] } else { $null })
        Get-ProfileStatus -Profile $profile | Format-List
    }

    'status-all' {
        if (-not (Test-Path -LiteralPath $accountRoot)) {
            Write-Host 'No Cloudflare profiles found.'
            return
        }

        $profiles = @(Get-ChildItem -LiteralPath $accountRoot -Directory -Force | Where-Object { $_.Name -match '^[^\s@]+@[^\s@]+\.[^\s@]+$' } | Sort-Object Name)
        if ($profiles.Count -eq 0) {
            Write-Host 'No Cloudflare profiles found.'
            return
        }

        $profiles |
            ForEach-Object { Get-ProfileStatus -Profile (Get-ProfileName -Directory $_) } |
            Format-Table -AutoSize
    }

    'list' {
        if (-not (Test-Path -LiteralPath $accountRoot)) {
            Write-Host 'No Cloudflare profiles found.'
            return
        }

        $active = Get-ActiveProfile
        $profiles = @(Get-ChildItem -LiteralPath $accountRoot -Directory -Force | Where-Object { $_.Name -match '^[^\s@]+@[^\s@]+\.[^\s@]+$' } | Sort-Object Name)
        if ($profiles.Count -eq 0) {
            Write-Host 'No Cloudflare profiles found.'
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
            Write-Host 'No active Cloudflare email profile set.'
        }
    }

    'path' {
        $profile = Get-ProfileOrActive -Profile $(if ($remaining.Count -ge 1) { $remaining[0] } else { $null })
        Write-Host (Get-ProfilePath -Profile $profile)
    }

    'env' {
        $profile = Get-ProfileOrActive -Profile $(if ($remaining.Count -ge 1) { $remaining[0] } else { $null })
        $accountId = Read-ProfileAccountId -Profile $profile
        Write-Host '$env:CLOUDFLARE_API_TOKEN = <profile token>'
        Write-Host '$env:CF_API_TOKEN = <profile token>'
        if ($accountId) {
            Write-Host "`$env:CLOUDFLARE_ACCOUNT_ID = '$accountId'"
        } else {
            Write-Host '$env:CLOUDFLARE_ACCOUNT_ID is not set for this profile.'
        }
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
