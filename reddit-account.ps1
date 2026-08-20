$ErrorActionPreference = 'Stop'

$accountRoot = Join-Path $env:APPDATA 'mainframe\accounts\reddit'
$currentFile = Join-Path $accountRoot 'current.json'
$defaultRedirectUri = 'http://127.0.0.1:8585/callback/'
$defaultScopes = @('identity', 'read', 'submit')

function Show-Usage {
    @(
        'Reddit API account profile helper',
        '',
        'Profiles are keyed by account email only and stored in:',
        '  %APPDATA%\mainframe\accounts\reddit\<email>',
        '',
        'This helper uses official Reddit OAuth. It is for posting as your own',
        'Reddit account through the Data API, not Devvit subreddit app installs.',
        '',
        'Recommended Reddit app type: installed app',
        "Recommended redirect URI: $defaultRedirectUri",
        '',
        'Usage:',
        '  .\reddit-account.ps1 login <email> -ClientId <client_id> [-RedirectUri <uri>] [-Scopes identity,read,submit] [-Port 8585]',
        '  .\reddit-account.ps1 use <email>',
        '  .\reddit-account.ps1 run [email] <GET|POST> <oauth path> [json body]',
        '  .\reddit-account.ps1 whoami [email]',
        '  .\reddit-account.ps1 status [email]',
        '  .\reddit-account.ps1 status-all',
        '  .\reddit-account.ps1 list',
        '  .\reddit-account.ps1 current',
        '  .\reddit-account.ps1 path [email]',
        '  .\reddit-account.ps1 env [email]',
        '  .\reddit-account.ps1 logout <email>',
        '',
        'Examples:',
        '  .\reddit-account.ps1 login user@example.com -ClientId abc123',
        '  .\reddit-account.ps1 use user@example.com',
        '  .\reddit-account.ps1 whoami user@example.com',
        '  .\reddit-account.ps1 run user@example.com GET /api/v1/me',
        '  .\reddit-account.ps1 run GET /api/v1/me'
    ) -join [Environment]::NewLine | Write-Host
}

function Normalize-ProfileName {
    param([string]$Profile)

    if ([string]::IsNullOrWhiteSpace($Profile)) {
        throw 'Email profile is required.'
    }

    $normalized = $Profile.Trim().ToLowerInvariant()
    if ($normalized.StartsWith('u/')) {
        throw "Reddit profile must be an account email, not a Reddit username: $Profile"
    }

    if ($normalized -notmatch '^[^\s@]+@[^\s@]+\.[^\s@]+$') {
        throw "Reddit profile must be an account email, not a label or username: $Profile"
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

function Get-ProfileConfigPath {
    param([string]$ProfilePath)

    return Join-Path $ProfilePath 'profile.json'
}

function Get-ProfileOrActive {
    param([AllowNull()][string]$Profile)

    if (-not [string]::IsNullOrWhiteSpace($Profile)) {
        return Normalize-ProfileName -Profile $Profile
    }

    $active = Get-ActiveProfile
    if (-not $active) {
        throw 'No email was provided and no active Reddit email profile is set. Run .\reddit-account.ps1 use <email>.'
    }

    return Normalize-ProfileName -Profile $active
}

function Set-ActiveProfile {
    param([string]$Profile)

    $normalized = Normalize-ProfileName -Profile $Profile
    New-Item -ItemType Directory -Force -Path $accountRoot | Out-Null
    [ordered]@{
        tool = 'reddit'
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

function ConvertTo-QueryString {
    param([hashtable]$Values)

    $parts = foreach ($key in $Values.Keys) {
        '{0}={1}' -f [uri]::EscapeDataString([string]$key), [uri]::EscapeDataString([string]$Values[$key])
    }

    return ($parts -join '&')
}

function Get-UserAgent {
    param([AllowNull()][string]$Profile)

    $suffix = if ([string]::IsNullOrWhiteSpace($Profile)) { 'unknown' } else { $Profile }
    return "windows:mainframe-reddit:0.1 (by u/$suffix)"
}

function Get-BasicAuthHeader {
    param(
        [string]$ClientId,
        [AllowNull()][string]$ClientSecret
    )

    $pair = '{0}:{1}' -f $ClientId, $(if ($ClientSecret) { $ClientSecret } else { '' })
    $encoded = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair))
    return "Basic $encoded"
}

function Invoke-RedditTokenRequest {
    param(
        [hashtable]$Body,
        [string]$ClientId,
        [AllowNull()][string]$ClientSecret,
        [string]$UserAgent
    )

    $headers = @{
        Authorization = Get-BasicAuthHeader -ClientId $ClientId -ClientSecret $ClientSecret
        'User-Agent' = $UserAgent
    }

    Invoke-RestMethod -Method Post -Uri 'https://www.reddit.com/api/v1/access_token' -Headers $headers -Body $Body -ContentType 'application/x-www-form-urlencoded'
}

function Write-ProfileConfig {
    param(
        [string]$Profile,
        [string]$ProfilePath,
        [string]$ClientId,
        [AllowNull()][string]$ClientSecret,
        [string]$RedirectUri,
        [string[]]$Scopes,
        [string]$RefreshToken,
        [AllowNull()][string]$AccessToken,
        [AllowNull()][int]$ExpiresIn,
        [AllowNull()][object]$Me
    )

    New-Item -ItemType Directory -Force -Path $ProfilePath | Out-Null
    $expiresAt = if ($AccessToken -and $ExpiresIn) { (Get-Date).AddSeconds([Math]::Max(0, $ExpiresIn - 60)).ToString('o') } else { $null }
    [ordered]@{
        tool = 'reddit'
        profile = $Profile
        redditUsername = if ($Me -and $Me.name) { [string]$Me.name } else { $null }
        clientId = $ClientId
        clientSecret = $ClientSecret
        redirectUri = $RedirectUri
        scopes = @($Scopes)
        refreshToken = $RefreshToken
        accessToken = $AccessToken
        accessTokenExpiresAt = $expiresAt
        userAgent = Get-UserAgent -Profile $(if ($Me -and $Me.name) { [string]$Me.name } else { $Profile })
        updatedAt = (Get-Date).ToString('o')
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Get-ProfileConfigPath -ProfilePath $ProfilePath) -Encoding UTF8
}

function Read-ProfileConfig {
    param([string]$Profile)

    $normalized = Normalize-ProfileName -Profile $Profile
    $profilePath = Get-ProfilePath -Profile $normalized
    $configPath = Get-ProfileConfigPath -ProfilePath $profilePath
    if (-not (Test-Path -LiteralPath $configPath)) {
        throw "Reddit profile does not exist yet: $normalized. Run .\reddit-account.ps1 login $normalized -ClientId <client_id> first."
    }

    Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
}

function Save-AccessToken {
    param(
        [string]$Profile,
        [object]$Config,
        [object]$Token
    )

    $profilePath = Get-ProfilePath -Profile $Profile
    $me = $null
    if ($Config.redditUsername) {
        $me = [pscustomobject]@{ name = [string]$Config.redditUsername }
    }

    Write-ProfileConfig -Profile $Profile -ProfilePath $profilePath -ClientId ([string]$Config.clientId) -ClientSecret ([string]$Config.clientSecret) -RedirectUri ([string]$Config.redirectUri) -Scopes @($Config.scopes) -RefreshToken ([string]$Config.refreshToken) -AccessToken ([string]$Token.access_token) -ExpiresIn ([int]$Token.expires_in) -Me $me
}

function Get-AccessToken {
    param([string]$Profile)

    $normalized = Normalize-ProfileName -Profile $Profile
    $config = Read-ProfileConfig -Profile $normalized
    if ($config.accessToken -and $config.accessTokenExpiresAt) {
        $expiresAt = [datetime]::Parse([string]$config.accessTokenExpiresAt, $null, [Globalization.DateTimeStyles]::RoundtripKind)
        if ($expiresAt -gt (Get-Date)) {
            return [string]$config.accessToken
        }
    }

    if (-not $config.refreshToken) {
        throw "Reddit profile has no refresh token: $normalized"
    }

    $token = Invoke-RedditTokenRequest -Body @{
        grant_type = 'refresh_token'
        refresh_token = [string]$config.refreshToken
    } -ClientId ([string]$config.clientId) -ClientSecret ([string]$config.clientSecret) -UserAgent ([string]$config.userAgent)
    Save-AccessToken -Profile $normalized -Config $config -Token $token
    return [string]$token.access_token
}

function Invoke-RedditApi {
    param(
        [string]$Profile,
        [string]$Method,
        [string]$Path,
        [AllowNull()]$Body
    )

    $normalized = Normalize-ProfileName -Profile $Profile
    $config = Read-ProfileConfig -Profile $normalized
    $accessToken = Get-AccessToken -Profile $normalized
    $headers = @{
        Authorization = "Bearer $accessToken"
        'User-Agent' = [string]$config.userAgent
    }

    $uri = if ($Path -match '^https?://') { $Path } else { 'https://oauth.reddit.com' + $(if ($Path.StartsWith('/')) { $Path } else { "/$Path" }) }
    if ($null -eq $Body) {
        Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers
    } else {
        Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers -Body $Body -ContentType 'application/x-www-form-urlencoded'
    }
}

function Get-CurrentRedditUser {
    param([string]$Profile)

    Invoke-RedditApi -Profile $Profile -Method Get -Path '/api/v1/me' -Body $null
}

function Get-CurrentRedditUserFromAccessToken {
    param(
        [string]$AccessToken,
        [string]$UserAgent
    )

    Invoke-RestMethod -Method Get -Uri 'https://oauth.reddit.com/api/v1/me' -Headers @{
        Authorization = "Bearer $AccessToken"
        'User-Agent' = $UserAgent
    }
}

function Wait-ForOAuthCallback {
    param(
        [int]$Port,
        [string]$ExpectedState
    )

    $listener = [Net.HttpListener]::new()
    $prefix = "http://127.0.0.1:$Port/callback/"
    $listener.Prefixes.Add($prefix)
    try {
        $listener.Start()
        Write-Host "Waiting for Reddit OAuth callback at $prefix"
        $context = $listener.GetContext()
        $request = $context.Request
        $code = $request.QueryString['code']
        $state = $request.QueryString['state']
        $errorValue = $request.QueryString['error']

        $responseText = if ($errorValue) {
            "Reddit OAuth failed: $errorValue. You can close this tab."
        } else {
            'Reddit OAuth completed. You can close this tab and return to PowerShell.'
        }
        $buffer = [Text.Encoding]::UTF8.GetBytes($responseText)
        $context.Response.ContentType = 'text/plain'
        $context.Response.ContentLength64 = $buffer.Length
        $context.Response.OutputStream.Write($buffer, 0, $buffer.Length)
        $context.Response.OutputStream.Close()

        if ($errorValue) {
            throw "Reddit OAuth returned error: $errorValue"
        }

        if ($state -ne $ExpectedState) {
            throw 'Reddit OAuth state mismatch. Refusing to save credentials.'
        }

        if ([string]::IsNullOrWhiteSpace($code)) {
            throw 'Reddit OAuth callback did not include a code.'
        }

        return $code
    } finally {
        if ($listener.IsListening) {
            $listener.Stop()
        }
        $listener.Close()
    }
}

function Get-OptionValue {
    param(
        [string[]]$Items,
        [string[]]$Names,
        [AllowNull()][string]$Default
    )

    for ($i = 0; $i -lt $Items.Count; $i++) {
        if ($Names -contains $Items[$i]) {
            if ($i + 1 -ge $Items.Count) {
                throw "Missing value for option $($Items[$i])"
            }
            return [string]$Items[$i + 1]
        }
    }

    return $Default
}

function Get-RemainingArgsWithoutOptions {
    param(
        [string[]]$Items,
        [string[]]$OptionNames
    )

    $result = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $Items.Count; $i++) {
        if ($OptionNames -contains $Items[$i]) {
            $i++
            continue
        }
        $result.Add($Items[$i])
    }

    return @($result)
}

function Move-ProfileDirectory {
    param(
        [string]$SourcePath,
        [string]$Profile
    )

    $targetPath = Get-ProfilePath -Profile $Profile
    if ((Test-Path -LiteralPath $targetPath) -and ((Resolve-Path -LiteralPath $targetPath).Path -ne (Resolve-Path -LiteralPath $SourcePath).Path)) {
        $backupPath = "$targetPath.backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Move-Item -LiteralPath $targetPath -Destination $backupPath
        Write-Warning "Existing Reddit profile was moved to: $backupPath"
    }

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $targetPath) | Out-Null
    if (-not (Test-Path -LiteralPath $targetPath)) {
        Move-Item -LiteralPath $SourcePath -Destination $targetPath
    }

    return $targetPath
}

function Get-ProfileStatus {
    param([string]$Profile)

    $normalized = Normalize-ProfileName -Profile $Profile
    $profilePath = Get-ProfilePath -Profile $normalized
    $configPath = Get-ProfileConfigPath -ProfilePath $profilePath
    $exists = Test-Path -LiteralPath $profilePath
    $hasConfig = Test-Path -LiteralPath $configPath
    $active = Get-ActiveProfile
    $config = $null
    if ($hasConfig) {
        $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    }

    [pscustomobject]@{
        Profile = $normalized
        RedditUsername = if ($config -and $config.redditUsername) { [string]$config.redditUsername } else { $null }
        Exists = $exists
        IsActive = ($active -eq $normalized)
        HasRefreshToken = [bool]($config -and $config.refreshToken)
        AccessTokenExpiresAt = if ($config -and $config.accessTokenExpiresAt) { [string]$config.accessTokenExpiresAt } else { $null }
        Scopes = if ($config -and $config.scopes) { (@($config.scopes) -join ',') } else { $null }
        ConfigPath = $configPath
        State = if (-not $exists) { 'missing-profile' } elseif (-not $hasConfig) { 'missing-config' } elseif (-not $config.refreshToken) { 'missing-refresh-token' } elseif ($active -eq $normalized) { 'active' } else { 'configured' }
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
        Write-Host "Reddit profile does not exist: $normalized"
        return
    }

    $backupPath = "$profilePath.logged-out-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Move-Item -LiteralPath $profilePath -Destination $backupPath
    Write-Host "Reddit profile moved to: $backupPath"

    $active = Get-ActiveProfile
    if ($active -eq $normalized -and (Test-Path -LiteralPath $currentFile)) {
        Remove-Item -LiteralPath $currentFile
        Write-Host 'Active Reddit profile cleared.'
    }
}

$command = if ($args.Count -gt 0) { $args[0].ToLowerInvariant() } else { 'help' }
$remaining = @($args | Select-Object -Skip 1)

switch ($command) {
    'help' {
        Show-Usage
    }

    'login' {
        $optionNames = @('-ClientId', '--client-id', '-ClientSecret', '--client-secret', '-RedirectUri', '--redirect-uri', '-Scopes', '--scopes', '-Port', '--port')
        $freeArgs = @(Get-RemainingArgsWithoutOptions -Items $remaining -OptionNames $optionNames)
        $profile = $null
        if ($freeArgs.Count -gt 0) {
            $profile = Normalize-ProfileName -Profile $freeArgs[0]
        } else {
            throw 'Usage: .\reddit-account.ps1 login <email> -ClientId <client_id> [-RedirectUri <uri>] [-Scopes identity,read,submit] [-Port 8585]'
        }

        $clientId = Get-OptionValue -Items $remaining -Names @('-ClientId', '--client-id') -Default $null
        if ([string]::IsNullOrWhiteSpace($clientId)) {
            throw 'Client ID is required. Create a Reddit installed app, then run: .\reddit-account.ps1 login -ClientId <client_id>'
        }

        $clientSecret = Get-OptionValue -Items $remaining -Names @('-ClientSecret', '--client-secret') -Default $null
        $redirectUri = Get-OptionValue -Items $remaining -Names @('-RedirectUri', '--redirect-uri') -Default $defaultRedirectUri
        $scopeText = Get-OptionValue -Items $remaining -Names @('-Scopes', '--scopes') -Default ($defaultScopes -join ',')
        $scopes = @($scopeText -split '[,\s]+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $portText = Get-OptionValue -Items $remaining -Names @('-Port', '--port') -Default '8585'
        $port = [int]$portText

        $pendingRoot = Join-Path $env:TEMP 'mainframe-reddit-login'
        New-Item -ItemType Directory -Force -Path $pendingRoot | Out-Null
        $profilePath = Get-ProfilePath -Profile $profile
        New-Item -ItemType Directory -Force -Path $profilePath | Out-Null

        $displayProfile = $profile
        Write-Host 'About to open Reddit OAuth in your browser.'
        Write-Host "Service: Reddit API"
        Write-Host "Profile: $displayProfile"
        Write-Host "Redirect URI: $redirectUri"
        Write-Host "Scopes: $($scopes -join ',')"
        Write-Host 'Continue only if the browser is on the Reddit account you want this agent to post from.'
        $confirmation = Read-Host 'Type YES to open Reddit OAuth'
        if ($confirmation -ne 'YES') {
            throw 'Reddit OAuth cancelled before opening browser.'
        }

        $state = [Guid]::NewGuid().ToString('N')
        $authorizeUrl = 'https://www.reddit.com/api/v1/authorize?' + (ConvertTo-QueryString @{
            client_id = $clientId
            response_type = 'code'
            state = $state
            redirect_uri = $redirectUri
            duration = 'permanent'
            scope = ($scopes -join ' ')
        })

        Start-Process $authorizeUrl
        $code = Wait-ForOAuthCallback -Port $port -ExpectedState $state
        $token = Invoke-RedditTokenRequest -Body @{
            grant_type = 'authorization_code'
            code = $code
            redirect_uri = $redirectUri
        } -ClientId $clientId -ClientSecret $clientSecret -UserAgent (Get-UserAgent -Profile $displayProfile)

        if (-not $token.refresh_token) {
            throw 'Reddit OAuth did not return a refresh token. Make sure duration=permanent was accepted.'
        }

        $me = Get-CurrentRedditUserFromAccessToken -AccessToken ([string]$token.access_token) -UserAgent (Get-UserAgent -Profile $displayProfile)
        Write-ProfileConfig -Profile $profile -ProfilePath $profilePath -ClientId $clientId -ClientSecret $clientSecret -RedirectUri $redirectUri -Scopes $scopes -RefreshToken ([string]$token.refresh_token) -AccessToken ([string]$token.access_token) -ExpiresIn ([int]$token.expires_in) -Me $me
        Set-ActiveProfile -Profile $profile
        Write-Host "Reddit API profile is ready and active: $profile"
    }

    'use' {
        if ($remaining.Count -ne 1) {
            throw 'Usage: .\reddit-account.ps1 use <email>'
        }

        $profile = Normalize-ProfileName -Profile $remaining[0]
        $profilePath = Get-ProfilePath -Profile $profile
        if (-not (Test-Path -LiteralPath (Get-ProfileConfigPath -ProfilePath $profilePath))) {
            throw "Reddit profile does not exist yet: $profile"
        }

        Set-ActiveProfile -Profile $profile
        Write-Host "Active Reddit profile: $profile"
    }

    'run' {
        if ($remaining.Count -lt 2) {
            throw 'Usage: .\reddit-account.ps1 run [email] <GET|POST> <oauth path> [json body]'
        }

        if (Test-LooksLikeEmail -Value $remaining[0]) {
            if ($remaining.Count -lt 3) {
                throw 'Usage: .\reddit-account.ps1 run [email] <GET|POST> <oauth path> [json body]'
            }

            $profile = Normalize-ProfileName -Profile $remaining[0]
            $apiArgs = @($remaining | Select-Object -Skip 1)
        } else {
            $profile = Get-ProfileOrActive -Profile $null
            $apiArgs = @($remaining)
        }

        $method = $apiArgs[0].ToUpperInvariant()
        $path = $apiArgs[1]
        $body = $null
        if ($apiArgs.Count -gt 2) {
            $json = $apiArgs[2]
            $parsed = $json | ConvertFrom-Json
            $body = @{}
            foreach ($property in $parsed.PSObject.Properties) {
                $body[$property.Name] = [string]$property.Value
            }
        }

        Invoke-RedditApi -Profile $profile -Method $method -Path $path -Body $body | ConvertTo-Json -Depth 8
    }

    'whoami' {
        $profile = Get-ProfileOrActive -Profile $(if ($remaining.Count -ge 1) { $remaining[0] } else { $null })
        $me = Get-CurrentRedditUser -Profile $profile
        [pscustomobject]@{
            name = $me.name
            id = $me.id
            is_employee = $me.is_employee
            verified = $me.verified
        } | Format-List
    }

    'status' {
        $profile = Get-ProfileOrActive -Profile $(if ($remaining.Count -ge 1) { $remaining[0] } else { $null })
        Get-ProfileStatus -Profile $profile | Format-List
    }

    'status-all' {
        if (-not (Test-Path -LiteralPath $accountRoot)) {
            Write-Host 'No Reddit profiles found.'
            return
        }

        $profiles = @(Get-ChildItem -LiteralPath $accountRoot -Directory -Force | Where-Object { $_.Name -match '^[^\s@]+@[^\s@]+\.[^\s@]+$' } | Sort-Object Name)
        if ($profiles.Count -eq 0) {
            Write-Host 'No Reddit profiles found.'
            return
        }

        $profiles |
            ForEach-Object { Get-ProfileStatus -Profile (Get-ProfileName -Directory $_) } |
            Format-Table -AutoSize
    }

    'list' {
        if (-not (Test-Path -LiteralPath $accountRoot)) {
            Write-Host 'No Reddit profiles found.'
            return
        }

        $active = Get-ActiveProfile
        $profiles = @(Get-ChildItem -LiteralPath $accountRoot -Directory -Force | Where-Object { $_.Name -match '^[^\s@]+@[^\s@]+\.[^\s@]+$' } | Sort-Object Name)
        if ($profiles.Count -eq 0) {
            Write-Host 'No Reddit profiles found.'
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
            Write-Host 'No active Reddit email profile set.'
        }
    }

    'path' {
        $profile = Get-ProfileOrActive -Profile $(if ($remaining.Count -ge 1) { $remaining[0] } else { $null })
        Write-Host (Get-ProfilePath -Profile $profile)
    }

    'env' {
        $profile = Get-ProfileOrActive -Profile $(if ($remaining.Count -ge 1) { $remaining[0] } else { $null })
        $profilePath = Get-ProfilePath -Profile $profile
        $config = Read-ProfileConfig -Profile $profile
        Write-Host "`$env:REDDIT_PROFILE_PATH = '$profilePath'"
        Write-Host '$env:REDDIT_CLIENT_ID = <profile client id>'
        if (-not [string]::IsNullOrWhiteSpace([string]$config.clientSecret)) {
            Write-Host '$env:REDDIT_CLIENT_SECRET = <profile client secret>'
        }
        Write-Host '$env:REDDIT_REFRESH_TOKEN = <profile refresh token>'
        if (-not [string]::IsNullOrWhiteSpace([string]$config.redirectUri)) {
            Write-Host "`$env:REDDIT_REDIRECT_URI = '$($config.redirectUri)'"
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
