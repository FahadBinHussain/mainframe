$ErrorActionPreference = 'Stop'

$accountRoot = Join-Path $env:APPDATA 'mainframe\accounts\microsoft'
$currentFile = Join-Path $accountRoot 'current.json'
$graphEndpoint = 'https://graph.microsoft.com'
$defaultTenant = 'consumers'
$defaultRedirectUri = 'http://127.0.0.1:8595/callback/'
$defaultScopes = @('openid', 'profile', 'offline_access', 'User.Read', 'Mail.ReadWrite', 'Mail.Send', 'MailboxSettings.ReadWrite', 'Calendars.ReadWrite', 'Contacts.ReadWrite', 'Files.ReadWrite.All', 'Tasks.ReadWrite', 'Notes.ReadWrite', 'ShortNotes.ReadWrite')
$userAgent = 'mainframe-microsoft-account'

function Show-Usage {
    @'
mainframe Microsoft Graph account helper

Profiles are stored under:
  %APPDATA%\mainframe\accounts\microsoft\<email>

Commands:
  login [email] -ClientId <client_id> [-Tenant consumers|common|organizations|<tenant-id>] [-RedirectUri <uri>] [-Scopes openid,profile,offline_access,User.Read,Mail.Read] [-Port 8595]
  use <email>
  current
  list
  status [email]
  status-all
  path [email]
  env [email]
  me [email]
  run [email] <GET|POST|PATCH|PUT|DELETE> <graph path-or-url> [json body]
  api [email] <GET|POST|PATCH|PUT|DELETE> <graph path-or-url> [json body]
  messages [email] [-Folder inbox] [-Unread] [-Since <iso datetime>] [-Top <1-100>]
  unread [email] [-Folder inbox] [-Since <iso datetime>] [-Top <1-100>]
  message [email] <message-id>
  token-clear [email]
  logout [email]

Examples:
  .\microsoft-account.ps1 login user@outlook.com -ClientId YOUR_PUBLIC_CLIENT_ID
  .\microsoft-account.ps1 use user@outlook.com
  .\microsoft-account.ps1 me user@outlook.com
  .\microsoft-account.ps1 unread user@outlook.com -Since 2026-05-30T12:00:00Z
  .\microsoft-account.ps1 messages user@outlook.com -Folder inbox -Unread -Top 20
  .\microsoft-account.ps1 run user@outlook.com GET /me/mailFolders/inbox/messages?$top=5

Notes:
  - Default tenant is consumers for personal Microsoft accounts.
  - Default scopes cover mail, calendar, contacts, OneDrive, To Do, OneNote, and Sticky Notes delegated access.
  - Generic Graph calls support GET, POST, PATCH, PUT, and DELETE; only run write/delete calls you intend.
  - Tokens are stored as refresh-token.txt and access-token.txt; env/status never print token values.
'@
}

function Test-LooksLikeEmail {
    param([AllowNull()][string]$Value)
    return -not [string]::IsNullOrWhiteSpace($Value) -and $Value -match '^[^\s@]+@[^\s@]+\.[^\s@]+$'
}

function Normalize-ProfileName {
    param([string]$Profile)

    if ([string]::IsNullOrWhiteSpace($Profile)) {
        throw 'Profile email is required.'
    }

    $normalized = $Profile.Trim().ToLowerInvariant()
    if (-not (Test-LooksLikeEmail -Value $normalized)) {
        throw "Microsoft profiles must be keyed by account email only, not labels or usernames: $Profile"
    }

    foreach ($char in [IO.Path]::GetInvalidFileNameChars()) {
        if ($normalized.Contains($char)) {
            throw "Profile email contains an invalid path character: $Profile"
        }
    }

    return $normalized
}

function Get-ProfilePath {
    param([string]$Profile)
    Join-Path $accountRoot (Normalize-ProfileName -Profile $Profile)
}

function Get-ProfileConfigPath {
    param([string]$ProfilePath)
    Join-Path $ProfilePath 'profile.json'
}

function Get-RefreshTokenPath {
    param([string]$ProfilePath)
    Join-Path $ProfilePath 'refresh-token.txt'
}

function Get-AccessTokenPath {
    param([string]$ProfilePath)
    Join-Path $ProfilePath 'access-token.txt'
}

function ConvertTo-SafeJson {
    param([AllowNull()]$Value, [int]$Depth = 16)
    $Value | ConvertTo-Json -Depth $Depth
}

function Read-JsonFile {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    $raw = Get-Content -LiteralPath $Path -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $null
    }

    return $raw | ConvertFrom-Json
}

function Write-JsonFile {
    param([string]$Path, [AllowNull()]$Value)

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
    ConvertTo-SafeJson -Value $Value -Depth 24 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Read-SecretValue {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    $value = (Get-Content -LiteralPath $Path -Raw).Trim()
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $null
    }

    return $value
}

function Write-SecretValue {
    param([string]$Path, [string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw 'Secret value is empty.'
    }

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
    $Value.Trim() | Set-Content -LiteralPath $Path -NoNewline -Encoding UTF8
}

function Set-ActiveProfile {
    param([string]$Profile)

    $normalized = Normalize-ProfileName -Profile $Profile
    New-Item -ItemType Directory -Force -Path $accountRoot | Out-Null
    Write-JsonFile -Path $currentFile -Value ([pscustomobject]@{
        service = 'microsoft'
        profile = $normalized
        updatedAt = [DateTimeOffset]::UtcNow.ToString('o')
    })
}

function Get-ActiveProfile {
    if (-not (Test-Path -LiteralPath $currentFile)) {
        return $null
    }

    try {
        $current = Read-JsonFile -Path $currentFile
        if ($current -and $current.profile) {
            return Normalize-ProfileName -Profile ([string]$current.profile)
        }
    } catch {
        return $null
    }

    return $null
}

function Get-ProfileOrActive {
    param([AllowNull()][string]$Profile)

    if (-not [string]::IsNullOrWhiteSpace($Profile)) {
        return Normalize-ProfileName -Profile $Profile
    }

    $active = Get-ActiveProfile
    if (-not $active) {
        throw 'No email was provided and no active Microsoft email profile is set. Run .\microsoft-account.ps1 use <email>.'
    }

    return $active
}

function Get-ProfileMetadata {
    param([string]$Profile)

    $normalized = Normalize-ProfileName -Profile $Profile
    $profilePath = Get-ProfilePath -Profile $normalized
    return Read-JsonFile -Path (Get-ProfileConfigPath -ProfilePath $profilePath)
}

function ConvertTo-QueryString {
    param([object]$Parameters)

    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($entry in $Parameters.GetEnumerator()) {
        if ($null -eq $entry.Value) {
            continue
        }

        $key = [uri]::EscapeDataString([string]$entry.Key)
        $value = [uri]::EscapeDataString([string]$entry.Value)
        $parts.Add("$key=$value")
    }

    return ($parts -join '&')
}

function Get-OptionValue {
    param(
        [object[]]$Items,
        [string[]]$Names,
        [AllowNull()][string]$Default
    )

    for ($i = 0; $i -lt $Items.Count; $i++) {
        if ($Names -contains [string]$Items[$i]) {
            if ($i + 1 -ge $Items.Count) {
                throw "Missing value for option $($Items[$i])"
            }
            return [string]$Items[$i + 1]
        }
    }

    return $Default
}

function Test-OptionPresent {
    param(
        [object[]]$Items,
        [string[]]$Names
    )

    foreach ($item in $Items) {
        if ($Names -contains [string]$item) {
            return $true
        }
    }

    return $false
}

function Get-RemainingArgsWithoutOptions {
    param(
        [object[]]$Items,
        [string[]]$OptionNames
    )

    $result = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $Items.Count; $i++) {
        if ($OptionNames -contains [string]$Items[$i]) {
            $i++
            continue
        }
        $result.Add([string]$Items[$i])
    }

    return @($result)
}

function Resolve-ProfileAndArgs {
    param(
        [object[]]$Arguments,
        [string]$Usage
    )

    if ($Arguments.Count -gt 0 -and (Test-LooksLikeEmail -Value ([string]$Arguments[0]))) {
        if ($Arguments.Count -lt 2) {
            throw $Usage
        }

        return [pscustomobject]@{
            Profile = Normalize-ProfileName -Profile ([string]$Arguments[0])
            Args = @($Arguments | Select-Object -Skip 1)
        }
    }

    return [pscustomobject]@{
        Profile = Get-ProfileOrActive -Profile $null
        Args = @($Arguments)
    }
}

function Get-RedirectPort {
    param([string]$RedirectUri)

    $uri = [uri]$RedirectUri
    if ($uri.Scheme -ne 'http' -or $uri.Host -notin @('127.0.0.1', 'localhost')) {
        throw 'Redirect URI must be a loopback http://127.0.0.1 or http://localhost URI for this helper.'
    }

    if ($uri.Port -le 0) {
        throw 'Redirect URI must include a port.'
    }

    return $uri.Port
}

function Wait-ForOAuthCallback {
    param(
        [string]$RedirectUri,
        [string]$ExpectedState
    )

    $listener = [Net.HttpListener]::new()
    $listener.Prefixes.Add($RedirectUri)
    try {
        $listener.Start()
        Write-Host "Waiting for Microsoft OAuth callback at $RedirectUri"
        $context = $listener.GetContext()
        $request = $context.Request
        $code = $request.QueryString['code']
        $state = $request.QueryString['state']
        $errorValue = $request.QueryString['error']
        $errorDescription = $request.QueryString['error_description']

        $responseText = if ($errorValue) {
            "Microsoft OAuth failed: $errorValue. You can close this tab."
        } else {
            'Microsoft OAuth completed. You can close this tab and return to PowerShell.'
        }
        $buffer = [Text.Encoding]::UTF8.GetBytes($responseText)
        $context.Response.ContentType = 'text/plain'
        $context.Response.ContentLength64 = $buffer.Length
        $context.Response.OutputStream.Write($buffer, 0, $buffer.Length)
        $context.Response.OutputStream.Close()

        if ($errorValue) {
            if ([string]::IsNullOrWhiteSpace($errorDescription)) {
                throw "Microsoft OAuth returned error: $errorValue"
            }
            throw "Microsoft OAuth returned error: $errorValue - $errorDescription"
        }

        if ($state -ne $ExpectedState) {
            throw 'Microsoft OAuth state mismatch. Refusing to save credentials.'
        }

        if ([string]::IsNullOrWhiteSpace($code)) {
            throw 'Microsoft OAuth callback did not include a code.'
        }

        return $code
    } finally {
        if ($listener.IsListening) {
            $listener.Stop()
        }
        $listener.Close()
    }
}

function Invoke-MicrosoftTokenRequest {
    param(
        [string]$Tenant,
        [hashtable]$Body
    )

    $tokenEndpoint = "https://login.microsoftonline.com/$Tenant/oauth2/v2.0/token"
    try {
        return Invoke-RestMethod -Method POST -Uri $tokenEndpoint -ContentType 'application/x-www-form-urlencoded' -Body $Body -Headers @{
            Accept = 'application/json'
            'User-Agent' = $userAgent
        }
    } catch {
        $response = $_.Exception.Response
        if ($response -and $response.StatusCode) {
            throw "Microsoft token request failed: HTTP $([int]$response.StatusCode) $($response.StatusDescription)"
        }

        throw "Microsoft token request failed: $($_.Exception.Message)"
    }
}

function Resolve-GraphUri {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw 'Graph path is required.'
    }

    $trimmed = $Path.Trim()
    if ($trimmed -match '^https?://') {
        $uri = [uri]$trimmed
        if ($uri.Host -ne 'graph.microsoft.com') {
            throw 'Only https://graph.microsoft.com URLs are allowed.'
        }

        return $trimmed
    }

    if ($trimmed.StartsWith('/v1.0/') -or $trimmed.StartsWith('/beta/')) {
        return "$graphEndpoint$trimmed"
    }

    if ($trimmed.StartsWith('v1.0/') -or $trimmed.StartsWith('beta/')) {
        return "$graphEndpoint/$trimmed"
    }

    if ($trimmed.StartsWith('/')) {
        return "$graphEndpoint/v1.0$trimmed"
    }

    return "$graphEndpoint/v1.0/$trimmed"
}

function Invoke-GraphRawRequest {
    param(
        [string]$AccessToken,
        [string]$Method,
        [string]$Path,
        [AllowNull()][string]$JsonBody
    )

    $methodUpper = $Method.ToUpperInvariant()
    if ($methodUpper -notin @('GET', 'POST', 'PATCH', 'PUT', 'DELETE')) {
        throw 'Method must be one of: GET, POST, PATCH, PUT, DELETE.'
    }

    $uri = Resolve-GraphUri -Path $Path
    $headers = @{
        Authorization = "Bearer $AccessToken"
        Accept = 'application/json'
        'User-Agent' = $userAgent
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
            throw "Microsoft Graph $methodUpper failed: HTTP $([int]$response.StatusCode) $($response.StatusDescription)"
        }

        throw "Microsoft Graph $methodUpper failed: $($_.Exception.Message)"
    }
}

function Invoke-GraphRawGet {
    param(
        [string]$AccessToken,
        [string]$Path
    )

    return Invoke-GraphRawRequest -AccessToken $AccessToken -Method GET -Path $Path -JsonBody $null
}

function Resolve-GraphEmailFromMe {
    param([AllowNull()]$Me)

    if (-not $Me) {
        return $null
    }

    $candidates = @($Me.mail, $Me.userPrincipalName)
    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace([string]$candidate)) {
            continue
        }

        try {
            return Normalize-ProfileName -Profile ([string]$candidate)
        } catch {
            continue
        }
    }

    return $null
}

function Write-ProfileTokens {
    param(
        [string]$Profile,
        [string]$ClientId,
        [string]$Tenant,
        [string]$RedirectUri,
        [string[]]$Scopes,
        [object]$TokenResponse,
        [object]$Me
    )

    if (-not $TokenResponse -or [string]::IsNullOrWhiteSpace([string]$TokenResponse.access_token)) {
        throw 'Microsoft token response did not include an access token.'
    }

    $normalized = Normalize-ProfileName -Profile $Profile
    $profilePath = Get-ProfilePath -Profile $normalized
    New-Item -ItemType Directory -Force -Path $profilePath | Out-Null

    if (-not [string]::IsNullOrWhiteSpace([string]$TokenResponse.refresh_token)) {
        Write-SecretValue -Path (Get-RefreshTokenPath -ProfilePath $profilePath) -Value ([string]$TokenResponse.refresh_token)
    }

    Write-SecretValue -Path (Get-AccessTokenPath -ProfilePath $profilePath) -Value ([string]$TokenResponse.access_token)

    $expiresIn = if ($TokenResponse.expires_in) { [int]$TokenResponse.expires_in } else { 3600 }
    $expiresAt = [DateTimeOffset]::UtcNow.AddSeconds([Math]::Max(0, $expiresIn - 60)).ToString('o')
    $accountEmail = Resolve-GraphEmailFromMe -Me $Me
    if ([string]::IsNullOrWhiteSpace($accountEmail)) {
        $accountEmail = $normalized
    }

    $metadata = [pscustomobject]@{
        tool = 'mainframe-microsoft-account'
        service = 'microsoft'
        profile = $normalized
        accountEmail = $accountEmail
        displayName = if ($Me -and $Me.displayName) { [string]$Me.displayName } else { $null }
        userId = if ($Me -and $Me.id) { [string]$Me.id } else { $null }
        clientId = $ClientId
        tenant = $Tenant
        redirectUri = $RedirectUri
        scopes = @($Scopes)
        graphEndpoint = $graphEndpoint
        refreshTokenPath = (Get-RefreshTokenPath -ProfilePath $profilePath)
        accessTokenPath = (Get-AccessTokenPath -ProfilePath $profilePath)
        accessTokenExpiresAt = $expiresAt
        updatedAt = [DateTimeOffset]::UtcNow.ToString('o')
    }

    Write-JsonFile -Path (Get-ProfileConfigPath -ProfilePath $profilePath) -Value $metadata
}

function Get-AccessToken {
    param([string]$Profile)

    $normalized = Normalize-ProfileName -Profile $Profile
    $profilePath = Get-ProfilePath -Profile $normalized
    $metadata = Get-ProfileMetadata -Profile $normalized
    if (-not $metadata) {
        throw "Microsoft profile is missing: $normalized. Run .\microsoft-account.ps1 login $normalized -ClientId <client_id>."
    }

    $accessTokenPath = Get-AccessTokenPath -ProfilePath $profilePath
    $accessToken = Read-SecretValue -Path $accessTokenPath
    $expiresAt = $null
    if ($metadata.accessTokenExpiresAt) {
        try {
            $expiresAt = [DateTimeOffset]::Parse([string]$metadata.accessTokenExpiresAt)
        } catch {
            $expiresAt = $null
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($accessToken) -and $expiresAt -and $expiresAt -gt [DateTimeOffset]::UtcNow.AddMinutes(2)) {
        return $accessToken
    }

    $refreshToken = Read-SecretValue -Path (Get-RefreshTokenPath -ProfilePath $profilePath)
    if ([string]::IsNullOrWhiteSpace($refreshToken)) {
        throw "Microsoft profile has no refresh token: $normalized. Run login again."
    }

    $scopes = @($metadata.scopes | ForEach-Object { [string]$_ })
    if ($scopes.Count -eq 0) {
        $scopes = $defaultScopes
    }

    $token = Invoke-MicrosoftTokenRequest -Tenant ([string]$metadata.tenant) -Body @{
        client_id = [string]$metadata.clientId
        grant_type = 'refresh_token'
        refresh_token = $refreshToken
        scope = ($scopes -join ' ')
    }

    $me = $null
    try {
        $me = Invoke-GraphRawGet -AccessToken ([string]$token.access_token) -Path '/me?$select=id,displayName,mail,userPrincipalName'
    } catch {
        $me = $null
    }

    Write-ProfileTokens -Profile $normalized -ClientId ([string]$metadata.clientId) -Tenant ([string]$metadata.tenant) -RedirectUri ([string]$metadata.redirectUri) -Scopes $scopes -TokenResponse $token -Me $me
    return [string]$token.access_token
}

function Invoke-GraphApi {
    param(
        [string]$Profile,
        [string]$Method,
        [string]$Path,
        [AllowNull()][string]$JsonBody
    )

    $accessToken = Get-AccessToken -Profile $Profile
    return Invoke-GraphRawRequest -AccessToken $accessToken -Method $Method -Path $Path -JsonBody $JsonBody
}

function Start-MicrosoftLogin {
    param(
        [AllowNull()][string]$ExpectedEmail,
        [string]$ClientId,
        [string]$Tenant,
        [string]$RedirectUri,
        [string[]]$Scopes,
        [bool]$AutoConfirm = $false
    )

    if ([string]::IsNullOrWhiteSpace($ClientId)) {
        throw 'Client ID is required. Create/use a Microsoft public client app, then run: .\microsoft-account.ps1 login <email> -ClientId <client_id>'
    }

    $expected = if ([string]::IsNullOrWhiteSpace($ExpectedEmail)) { $null } else { Normalize-ProfileName -Profile $ExpectedEmail }
    $null = Get-RedirectPort -RedirectUri $RedirectUri
    $scopeText = $Scopes -join ' '

    Write-Host 'About to open Microsoft OAuth in your browser.'
    Write-Host 'Service: Microsoft Graph'
    Write-Host ("Expected account: " + $(if ($expected) { $expected } else { 'auto-detect from Microsoft Graph /me' }))
    Write-Host "Tenant: $Tenant"
    Write-Host "Redirect URI: $RedirectUri"
    Write-Host "Scopes: $($Scopes -join ',')"
    Write-Host 'This helper saves the detected email profile only after Graph /me confirms an email.'
    if (-not $AutoConfirm) {
        $confirmation = Read-Host 'Type YES to open Microsoft OAuth'
        if ($confirmation -ne 'YES') {
            throw 'Microsoft OAuth cancelled before opening browser.'
        }
    }

    $state = [Guid]::NewGuid().ToString('N')
    $authorizeUrl = "https://login.microsoftonline.com/$Tenant/oauth2/v2.0/authorize?" + (ConvertTo-QueryString ([ordered]@{
        client_id = $ClientId
        response_type = 'code'
        redirect_uri = $RedirectUri
        response_mode = 'query'
        scope = $scopeText
        state = $state
        prompt = 'select_account'
    }))

    Start-Process $authorizeUrl
    $code = Wait-ForOAuthCallback -RedirectUri $RedirectUri -ExpectedState $state
    $token = Invoke-MicrosoftTokenRequest -Tenant $Tenant -Body @{
        client_id = $ClientId
        grant_type = 'authorization_code'
        code = $code
        redirect_uri = $RedirectUri
        scope = $scopeText
    }

    if ([string]::IsNullOrWhiteSpace([string]$token.refresh_token)) {
        throw 'Microsoft OAuth did not return a refresh token. Make sure offline_access was included and consented.'
    }

    $me = Invoke-GraphRawGet -AccessToken ([string]$token.access_token) -Path '/me?$select=id,displayName,mail,userPrincipalName'
    $detected = Resolve-GraphEmailFromMe -Me $me
    if ([string]::IsNullOrWhiteSpace($detected)) {
        throw 'Could not detect an account email from Microsoft Graph /me. No token was saved.'
    }

    if ($expected -and $detected -ne $expected) {
        throw "Microsoft account mismatch. Expected $expected, but Graph /me returned $detected. No token was saved."
    }

    Write-ProfileTokens -Profile $detected -ClientId $ClientId -Tenant $Tenant -RedirectUri $RedirectUri -Scopes $Scopes -TokenResponse $token -Me $me
    Set-ActiveProfile -Profile $detected
    Write-Host "Microsoft profile is ready and active: $detected"
}

function Get-ProfileStatus {
    param([string]$Profile)

    $normalized = Normalize-ProfileName -Profile $Profile
    $profilePath = Get-ProfilePath -Profile $normalized
    $metadata = Get-ProfileMetadata -Profile $normalized
    $exists = Test-Path -LiteralPath $profilePath
    $refreshToken = Read-SecretValue -Path (Get-RefreshTokenPath -ProfilePath $profilePath)
    $accessToken = Read-SecretValue -Path (Get-AccessTokenPath -ProfilePath $profilePath)
    $active = Get-ActiveProfile

    [pscustomobject]@{
        Profile = $normalized
        AccountEmail = if ($metadata -and $metadata.accountEmail) { [string]$metadata.accountEmail } else { $null }
        DisplayName = if ($metadata -and $metadata.displayName) { [string]$metadata.displayName } else { $null }
        Exists = $exists
        IsActive = ($active -eq $normalized)
        HasRefreshToken = -not [string]::IsNullOrWhiteSpace($refreshToken)
        HasAccessToken = -not [string]::IsNullOrWhiteSpace($accessToken)
        AccessTokenExpiresAt = if ($metadata -and $metadata.accessTokenExpiresAt) { [string]$metadata.accessTokenExpiresAt } else { $null }
        Tenant = if ($metadata -and $metadata.tenant) { [string]$metadata.tenant } else { $null }
        ClientId = if ($metadata -and $metadata.clientId) { [string]$metadata.clientId } else { $null }
        Scopes = if ($metadata -and $metadata.scopes) { (@($metadata.scopes) -join ',') } else { $null }
        ProfilePath = $profilePath
        State = if (-not $exists) { 'missing-profile' } elseif ([string]::IsNullOrWhiteSpace($refreshToken)) { 'missing-refresh-token' } elseif ($active -eq $normalized) { 'active' } else { 'configured' }
    }
}

function Get-ProfileName {
    param([IO.DirectoryInfo]$Directory)

    $metadataPath = Join-Path $Directory.FullName 'profile.json'
    if (Test-Path -LiteralPath $metadataPath) {
        try {
            $metadata = Read-JsonFile -Path $metadataPath
            if ($metadata -and $metadata.profile) {
                return [string]$metadata.profile
            }
        } catch {
            Write-Warning "Could not read profile metadata: $metadataPath"
        }
    }

    return $Directory.Name
}

function Remove-ProfileToken {
    param([string]$Profile)

    $normalized = Normalize-ProfileName -Profile $Profile
    $profilePath = Get-ProfilePath -Profile $normalized
    $removed = $false
    foreach ($path in @((Get-RefreshTokenPath -ProfilePath $profilePath), (Get-AccessTokenPath -ProfilePath $profilePath))) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Force
            $removed = $true
        }
    }

    if ($removed) {
        Write-Host "Removed saved Microsoft token files for: $normalized"
    } else {
        Write-Host "No saved Microsoft token files found for: $normalized"
    }
}

function Remove-Profile {
    param([string]$Profile)

    $normalized = Normalize-ProfileName -Profile $Profile
    $profilePath = Get-ProfilePath -Profile $normalized
    if (-not (Test-Path -LiteralPath $profilePath)) {
        Write-Host "Microsoft profile does not exist: $normalized"
        return
    }

    $backupPath = "$profilePath.logged-out-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Move-Item -LiteralPath $profilePath -Destination $backupPath
    Write-Host "Microsoft profile moved to: $backupPath"

    $active = Get-ActiveProfile
    if ($active -eq $normalized -and (Test-Path -LiteralPath $currentFile)) {
        Remove-Item -LiteralPath $currentFile
        Write-Host 'Active Microsoft profile cleared.'
    }
}

function Convert-GraphMessageSummary {
    param([AllowNull()]$Message)

    if (-not $Message) {
        return $null
    }

    [pscustomobject]@{
        id = $Message.id
        subject = $Message.subject
        receivedDateTime = $Message.receivedDateTime
        from = if ($Message.from -and $Message.from.emailAddress) { $Message.from.emailAddress.address } else { $null }
        fromName = if ($Message.from -and $Message.from.emailAddress) { $Message.from.emailAddress.name } else { $null }
        isRead = $Message.isRead
        importance = $Message.importance
        webLink = $Message.webLink
        bodyPreview = $Message.bodyPreview
    }
}

function Get-OutlookMessages {
    param(
        [string]$Profile,
        [string]$Folder,
        [bool]$Unread,
        [AllowNull()][string]$Since,
        [int]$Top
    )

    if ($Top -lt 1 -or $Top -gt 100) {
        throw 'Top must be between 1 and 100.'
    }

    if ([string]::IsNullOrWhiteSpace($Folder)) {
        $Folder = 'inbox'
    }

    $safeFolder = [uri]::EscapeDataString($Folder.Trim())
    $query = [ordered]@{
        '$top' = $Top
        '$select' = 'id,subject,receivedDateTime,from,isRead,importance,webLink,bodyPreview'
        '$orderby' = 'receivedDateTime desc'
    }

    $filters = New-Object System.Collections.Generic.List[string]
    if ($Unread) {
        $filters.Add('isRead eq false')
    }

    if (-not [string]::IsNullOrWhiteSpace($Since)) {
        $sinceDate = [DateTimeOffset]::Parse($Since).UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)
        $filters.Add("receivedDateTime ge $sinceDate")
    }

    if ($filters.Count -gt 0) {
        $query['$filter'] = ($filters -join ' and ')
    }

    $path = "/me/mailFolders/$safeFolder/messages?$(ConvertTo-QueryString $query)"
    $result = Invoke-GraphApi -Profile $Profile -Method GET -Path $path
    @($result.value | ForEach-Object { Convert-GraphMessageSummary -Message $_ })
}

function Get-OutlookMessage {
    param(
        [string]$Profile,
        [string]$MessageId
    )

    if ([string]::IsNullOrWhiteSpace($MessageId)) {
        throw 'Message ID is required.'
    }

    $safeId = [uri]::EscapeDataString($MessageId.Trim())
    $query = ConvertTo-QueryString ([ordered]@{
        '$select' = 'id,subject,receivedDateTime,from,toRecipients,ccRecipients,isRead,importance,webLink,bodyPreview,body'
    })
    Invoke-GraphApi -Profile $Profile -Method GET -Path "/me/messages/$safeId?$query"
}

$command = if ($args.Count -gt 0) { [string]$args[0].ToLowerInvariant() } else { 'help' }
$remaining = @($args | Select-Object -Skip 1)

switch ($command) {
    'help' {
        Show-Usage
    }

    'login' {
        $flagNames = @('-Yes', '--yes', '-ConfirmAuth', '--confirm-auth')
        $autoConfirm = Test-OptionPresent -Items $remaining -Names $flagNames
        $remainingForOptions = @($remaining | Where-Object { $flagNames -notcontains [string]$_ })
        $optionNames = @('-ClientId', '--client-id', '-Tenant', '--tenant', '-RedirectUri', '--redirect-uri', '-Scopes', '--scopes', '-Port', '--port')
        $freeArgs = @(Get-RemainingArgsWithoutOptions -Items $remainingForOptions -OptionNames $optionNames)
        $expectedEmail = $null
        if ($freeArgs.Count -gt 0) {
            $expectedEmail = Normalize-ProfileName -Profile $freeArgs[0]
        }

        $clientId = Get-OptionValue -Items $remainingForOptions -Names @('-ClientId', '--client-id') -Default $null
        $tenant = Get-OptionValue -Items $remainingForOptions -Names @('-Tenant', '--tenant') -Default $defaultTenant
        $redirectUri = Get-OptionValue -Items $remainingForOptions -Names @('-RedirectUri', '--redirect-uri') -Default $defaultRedirectUri
        $scopeText = Get-OptionValue -Items $remainingForOptions -Names @('-Scopes', '--scopes') -Default ($defaultScopes -join ',')
        $scopes = @($scopeText -split '[,\s]+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($scopes.Count -eq 0) {
            throw 'At least one Microsoft Graph scope is required.'
        }

        $portText = Get-OptionValue -Items $remainingForOptions -Names @('-Port', '--port') -Default $null
        if (-not [string]::IsNullOrWhiteSpace($portText)) {
            $port = [int]$portText
            $redirectPort = Get-RedirectPort -RedirectUri $redirectUri
            if ($port -ne $redirectPort) {
                throw "-Port $port does not match RedirectUri port $redirectPort."
            }
        }

        Start-MicrosoftLogin -ExpectedEmail $expectedEmail -ClientId $clientId -Tenant $tenant -RedirectUri $redirectUri -Scopes $scopes -AutoConfirm $autoConfirm
    }

    'use' {
        if ($remaining.Count -ne 1) {
            throw 'Usage: .\microsoft-account.ps1 use <email>'
        }

        $profile = Normalize-ProfileName -Profile ([string]$remaining[0])
        $profilePath = Get-ProfilePath -Profile $profile
        if (-not (Test-Path -LiteralPath (Get-ProfileConfigPath -ProfilePath $profilePath))) {
            throw "Microsoft profile does not exist yet: $profile"
        }

        Set-ActiveProfile -Profile $profile
        Write-Host "Active Microsoft profile: $profile"
    }

    { $_ -in @('run', 'api') } {
        if ($remaining.Count -lt 2) {
            throw 'Usage: .\microsoft-account.ps1 run [email] <GET|POST|PATCH|PUT|DELETE> <graph path-or-url> [json body]'
        }

        $resolved = Resolve-ProfileAndArgs -Arguments $remaining -Usage 'Usage: .\microsoft-account.ps1 run [email] <GET|POST|PATCH|PUT|DELETE> <graph path-or-url> [json body]'
        $apiArgs = @($resolved.Args)
        if ($apiArgs.Count -lt 2) {
            throw 'Usage: .\microsoft-account.ps1 run [email] <GET|POST|PATCH|PUT|DELETE> <graph path-or-url> [json body]'
        }

        $jsonBody = if ($apiArgs.Count -gt 2) { [string]$apiArgs[2] } else { $null }
        Invoke-GraphApi -Profile $resolved.Profile -Method ([string]$apiArgs[0]) -Path ([string]$apiArgs[1]) -JsonBody $jsonBody | ConvertTo-Json -Depth 24
    }

    'me' {
        $profile = Get-ProfileOrActive -Profile $(if ($remaining.Count -ge 1) { [string]$remaining[0] } else { $null })
        Invoke-GraphApi -Profile $profile -Method GET -Path '/me?$select=id,displayName,mail,userPrincipalName' | ConvertTo-Json -Depth 12
    }

    { $_ -in @('messages', 'unread') } {
        $profile = $null
        $argsForOptions = @($remaining)
        if ($argsForOptions.Count -gt 0 -and (Test-LooksLikeEmail -Value ([string]$argsForOptions[0]))) {
            $profile = Normalize-ProfileName -Profile ([string]$argsForOptions[0])
            $argsForOptions = @($argsForOptions | Select-Object -Skip 1)
        } else {
            $profile = Get-ProfileOrActive -Profile $null
        }

        $folder = Get-OptionValue -Items $argsForOptions -Names @('-Folder', '--folder') -Default 'inbox'
        $since = Get-OptionValue -Items $argsForOptions -Names @('-Since', '--since') -Default $null
        $topText = Get-OptionValue -Items $argsForOptions -Names @('-Top', '--top') -Default '25'
        $top = [int]$topText
        $unreadFlag = ($command -eq 'unread') -or (Test-OptionPresent -Items $argsForOptions -Names @('-Unread', '--unread'))

        Get-OutlookMessages -Profile $profile -Folder $folder -Unread $unreadFlag -Since $since -Top $top | ConvertTo-Json -Depth 16
    }

    'message' {
        $usage = 'Usage: .\microsoft-account.ps1 message [email] <message-id>'
        if ($remaining.Count -lt 1) {
            throw $usage
        }

        if (Test-LooksLikeEmail -Value ([string]$remaining[0])) {
            if ($remaining.Count -lt 2) {
                throw $usage
            }
            $profile = Normalize-ProfileName -Profile ([string]$remaining[0])
            $messageId = [string]$remaining[1]
        } else {
            $profile = Get-ProfileOrActive -Profile $null
            $messageId = [string]$remaining[0]
        }

        Get-OutlookMessage -Profile $profile -MessageId $messageId | ConvertTo-Json -Depth 32
    }

    'status' {
        $profile = Get-ProfileOrActive -Profile $(if ($remaining.Count -ge 1) { [string]$remaining[0] } else { $null })
        Get-ProfileStatus -Profile $profile | Format-List
    }

    'status-all' {
        if (-not (Test-Path -LiteralPath $accountRoot)) {
            Write-Host 'No Microsoft profiles found.'
            return
        }

        $profiles = @(Get-ChildItem -LiteralPath $accountRoot -Directory -Force | Where-Object { $_.Name -match '^[^\s@]+@[^\s@]+\.[^\s@]+$' } | Sort-Object Name)
        if ($profiles.Count -eq 0) {
            Write-Host 'No Microsoft profiles found.'
            return
        }

        $profiles |
            ForEach-Object { Get-ProfileStatus -Profile (Get-ProfileName -Directory $_) } |
            Format-Table -AutoSize
    }

    'list' {
        if (-not (Test-Path -LiteralPath $accountRoot)) {
            Write-Host 'No Microsoft profiles found.'
            return
        }

        $active = Get-ActiveProfile
        $profiles = @(Get-ChildItem -LiteralPath $accountRoot -Directory -Force | Where-Object { $_.Name -match '^[^\s@]+@[^\s@]+\.[^\s@]+$' } | Sort-Object Name)
        if ($profiles.Count -eq 0) {
            Write-Host 'No Microsoft profiles found.'
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
            Write-Host 'No active Microsoft email profile set.'
        }
    }

    'path' {
        $profile = Get-ProfileOrActive -Profile $(if ($remaining.Count -ge 1) { [string]$remaining[0] } else { $null })
        Write-Host (Get-ProfilePath -Profile $profile)
    }

    'env' {
        $profile = Get-ProfileOrActive -Profile $(if ($remaining.Count -ge 1) { [string]$remaining[0] } else { $null })
        $profilePath = Get-ProfilePath -Profile $profile
        $metadata = Get-ProfileMetadata -Profile $profile
        Write-Host "`$env:MICROSOFT_PROFILE = '$profile'"
        Write-Host "`$env:MICROSOFT_PROFILE_PATH = '$profilePath'"
        Write-Host "`$env:MICROSOFT_GRAPH_ENDPOINT = '$graphEndpoint'"
        if ($metadata -and $metadata.clientId) {
            Write-Host '$env:MICROSOFT_CLIENT_ID = <profile client id>'
        }
        Write-Host '$env:MICROSOFT_REFRESH_TOKEN = <profile refresh token>'
        Write-Host '$env:MICROSOFT_ACCESS_TOKEN = <profile access token>'
    }

    'token-clear' {
        $profile = Get-ProfileOrActive -Profile $(if ($remaining.Count -ge 1) { [string]$remaining[0] } else { $null })
        Remove-ProfileToken -Profile $profile
    }

    'logout' {
        $profile = Get-ProfileOrActive -Profile $(if ($remaining.Count -ge 1) { [string]$remaining[0] } else { $null })
        Remove-Profile -Profile $profile
    }

    default {
        Show-Usage
        throw "Unknown command: $command"
    }
}