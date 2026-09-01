$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'vault-secret.psm1') -Force

$accountRoot = Join-Path $env:APPDATA 'mainframe\accounts\neon'
$currentFile = Join-Path $accountRoot 'current.json'
$apiBase = 'https://console.neon.tech/api/v2'

function Show-Usage {
    @'
Neon account profile helper

Profiles are keyed by email and stored in:
  %APPDATA%\mainframe\accounts\neon\<email>

Usage:
  .\neon-account.ps1 login [email]
  .\neon-account.ps1 api-key-add [email]
  .\neon-account.ps1 api-key-add-limited [email]
  .\neon-account.ps1 api-key-clear [email]
  .\neon-account.ps1 add
  .\neon-account.ps1 use <email>
  .\neon-account.ps1 run [email] <neon args...>
  .\neon-account.ps1 api [email] <GET|POST|PUT|PATCH|DELETE> <api path|url> [json body]
  .\neon-account.ps1 whoami [email]
  .\neon-account.ps1 me-json [email]
  .\neon-account.ps1 orgs-json [email]
  .\neon-account.ps1 projects-json [email] [--org-id <org-id>]
  .\neon-account.ps1 project [email] <project-id>
  .\neon-account.ps1 branches [email] <project-id>
  .\neon-account.ps1 endpoints [email] <project-id>
  .\neon-account.ps1 databases [email] <project-id> <branch-id-or-name>
  .\neon-account.ps1 roles [email] <project-id> <branch-id-or-name>
  .\neon-account.ps1 operations [email] <project-id>
  .\neon-account.ps1 ip-allow [email] <project-id>
  .\neon-account.ps1 authority [email]
  .\neon-account.ps1 authority-json [email]
  .\neon-account.ps1 authority-all-json
  .\neon-account.ps1 capabilities [email]
  .\neon-account.ps1 capabilities-json [email]
  .\neon-account.ps1 status [email]
  .\neon-account.ps1 status-all
  .\neon-account.ps1 projects-count [email]
  .\neon-account.ps1 logout [email]
  .\neon-account.ps1 list
  .\neon-account.ps1 current
  .\neon-account.ps1 path [email]
  .\neon-account.ps1 env [email]

Examples:
  .\neon-account.ps1 login
  .\neon-account.ps1 login user@example.com
  .\neon-account.ps1 api-key-add
  .\neon-account.ps1 api-key-add user@example.com
  .\neon-account.ps1 run user@example.com projects list
  .\neon-account.ps1 run projects list
  .\neon-account.ps1 run user@example.com branches list --project-id cool-project-123
  .\neon-account.ps1 projects-json user@example.com --org-id org-example-123
  .\neon-account.ps1 branches user@example.com cool-project-123
'@ | Write-Host
}

function Normalize-Email {
    param([string]$Email)

    if ([string]::IsNullOrWhiteSpace($Email)) {
        throw 'Email is required.'
    }

    $normalized = $Email.Trim().ToLowerInvariant()
    if ($normalized -notmatch '^[^\s@]+@[^\s@]+\.[^\s@]+$') {
        throw "Invalid email profile name: $Email"
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

function Get-ApiKeyPath {
    param([string]$ProfilePath)

    return Join-Path $ProfilePath 'api-key.txt'
}

function Get-NeonCommand {
    foreach ($name in @('neonctl', 'neon')) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd) {
            return $cmd.Source
        }
    }

    throw 'Neon CLI was not found. Install it with: pnpm add -g neonctl'
}

function Add-QueryParameter {
    param(
        [string]$Path,
        [string]$Name,
        [AllowNull()][string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $Path
    }

    $separator = if ($Path.Contains('?')) { '&' } else { '?' }
    return "$Path$separator$([uri]::EscapeDataString($Name))=$([uri]::EscapeDataString($Value))"
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

function Get-NeonCliVersion {
    $neon = Get-NeonCommand
    $output = @(& $neon --version 2>$null)
    if ($output.Count -gt 0) {
        return (($output | Select-Object -First 1) -as [string]).Trim()
    }

    return $null
}

function Find-EmailInText {
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }

    $matches = [regex]::Matches($Text, '[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    foreach ($match in $matches) {
        try {
            return Normalize-Email -Email $match.Value
        } catch {
            continue
        }
    }

    return $null
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
        [string]$Email,
        [string]$ProfilePath,
        [AllowNull()][string]$AuthType,
        [AllowNull()]$Authority
    )

    New-Item -ItemType Directory -Force -Path $ProfilePath | Out-Null
    $metadata = [ordered]@{
        tool = 'neon'
        email = $Email
        configDir = $ProfilePath
        authType = $AuthType
        apiKeyPath = (Get-ApiKeyPath -ProfilePath $ProfilePath)
        updatedAt = (Get-Date).ToString('o')
    }
    if ($null -ne $Authority) {
        $metadata.authority = $Authority
    }

    $metadata | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $ProfilePath 'profile.json') -Encoding UTF8
}

function Set-ActiveEmail {
    param([string]$Email)

    New-Item -ItemType Directory -Force -Path $accountRoot | Out-Null
    [ordered]@{
        tool = 'neon'
        email = $Email
        updatedAt = (Get-Date).ToString('o')
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $currentFile -Encoding UTF8
}

function Get-ActiveEmail {
    if (-not (Test-Path -LiteralPath $currentFile)) {
        return $null
    }

    $current = Get-Content -LiteralPath $currentFile -Raw | ConvertFrom-Json
    try {
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
        throw 'No email was provided and no active Neon profile is set. Run .\neon-account.ps1 use <email>.'
    }

    return Normalize-Email -Email $active
}

function Invoke-WithNeonApiKey {
    param(
        [AllowNull()][string]$ApiKey,
        [scriptblock]$Script
    )

    $oldNeonApiKey = $env:NEON_API_KEY
    try {
        if ([string]::IsNullOrWhiteSpace($ApiKey)) {
            Remove-Item Env:\NEON_API_KEY -ErrorAction SilentlyContinue
        } else {
            $env:NEON_API_KEY = $ApiKey
        }

        & $Script
    } finally {
        if ([string]::IsNullOrWhiteSpace($oldNeonApiKey)) {
            Remove-Item Env:\NEON_API_KEY -ErrorAction SilentlyContinue
        } else {
            $env:NEON_API_KEY = $oldNeonApiKey
        }
    }
}

function Invoke-NeonCliJsonWithApiKey {
    param(
        [string]$ApiKey,
        [string[]]$NeonArgs
    )

    if ([string]::IsNullOrWhiteSpace($ApiKey)) {
        throw 'Neon API key is empty.'
    }

    $neon = Get-NeonCommand
    $pendingRoot = Join-Path $env:TEMP 'mainframe-neon-api-key-check'
    New-Item -ItemType Directory -Force -Path $pendingRoot | Out-Null
    $profilePath = Join-Path $pendingRoot "check-$([Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Force -Path $profilePath | Out-Null
    try {
        $script:neonApiKeyCheckOutput = @()
        $script:neonApiKeyCheckExitCode = 0
        Invoke-WithNeonApiKey -ApiKey $ApiKey -Script {
            $script:neonApiKeyCheckOutput = @(& $neon @NeonArgs --output json --no-color --no-analytics --config-dir $profilePath 2>&1)
            $script:neonApiKeyCheckExitCode = $LASTEXITCODE
        }

        $output = @($script:neonApiKeyCheckOutput)
        $exitCode = $script:neonApiKeyCheckExitCode
        Remove-Variable -Name neonApiKeyCheckOutput -Scope Script -ErrorAction SilentlyContinue
        Remove-Variable -Name neonApiKeyCheckExitCode -Scope Script -ErrorAction SilentlyContinue
        if ($exitCode -ne 0) {
            throw "neon $($NeonArgs -join ' ') failed with exit code $exitCode."
        }

        $text = ($output -join [Environment]::NewLine).Trim()
        if ([string]::IsNullOrWhiteSpace($text)) {
            return $null
        }

        return $text | ConvertFrom-Json
    } finally {
        Remove-Item -LiteralPath $profilePath -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Resolve-NeonEmailFromApiKey {
    param([string]$ApiKey)

    if ([string]::IsNullOrWhiteSpace($ApiKey)) {
        throw 'Neon API key is empty.'
    }

    try {
        $json = Invoke-NeonCliJsonWithApiKey -ApiKey $ApiKey -NeonArgs @('me')
        if ($json.email) {
            return Normalize-Email -Email ([string]$json.email)
        }

        $email = Find-EmailInText -Text ($json | ConvertTo-Json -Depth 8)
        if ($email) {
            return $email
        }

        throw 'Neon API key verification succeeded, but the account email could not be detected.'
    } catch {
        throw "Neon API key verification failed. $($_.Exception.Message)"
    }
}

function Write-ProfileApiKeyValue {
    param(
        [AllowNull()][string]$Email,
        [string]$ApiKey,
        [switch]$AllowLimited
    )

    $detectedEmail = Resolve-NeonEmailFromApiKey -ApiKey $ApiKey
    if (-not [string]::IsNullOrWhiteSpace($Email)) {
        $requestedEmail = Normalize-Email -Email $Email
        if ($requestedEmail -ne $detectedEmail) {
            throw "Neon API key belongs to $detectedEmail, not $requestedEmail."
        }
    }

    $authority = Get-NeonApiKeyAuthority -ApiKey $ApiKey -Email $detectedEmail
    if (-not $authority.FullAuthority -and -not $AllowLimited) {
        throw "Neon API key is not full-authority for mainframe. Missing: $(@($authority.MissingRequirements) -join ', '). Use a personal API key from an org-admin account, or explicitly run api-key-add-limited if you want to save a limited key."
    }

    $profilePath = Get-ProfilePath -Email $detectedEmail
    New-Item -ItemType Directory -Force -Path $profilePath | Out-Null
    $userPrefix = ($detectedEmail -split '@')[0]
    Write-VaultSecretToExisting -Email $detectedEmail -NamePattern 'console.neon.tech*' -Header '[api keys]' -Value $ApiKey.Trim() -ItemName "console.neon.tech - $userPrefix" -Username $detectedEmail -Uri 'https://console.neon.tech/app/settings#password'
    Write-ProfileMetadata -Email $detectedEmail -ProfilePath $profilePath -AuthType 'api-key' -Authority $authority
    Set-ActiveEmail -Email $detectedEmail
    $label = if ($authority.FullAuthority) { 'full-authority' } else { 'limited' }
    Write-Host "Neon API key profile is ready and active: $detectedEmail ($label)"
}

function Write-ProfileApiKey {
    param(
        [AllowNull()][string]$Email,
        [Security.SecureString]$ApiKey,
        [switch]$AllowLimited
    )

    Write-ProfileApiKeyValue -Email $Email -ApiKey (Convert-SecureStringToPlainText -SecureString $ApiKey) -AllowLimited:$AllowLimited
}

function Read-ProfileApiKey {
    param([string]$Email)

    $normalized = Normalize-Email -Email $Email
    return Read-VaultSecret -Email $normalized -NamePattern 'console.neon.tech*' -ValueRegex 'napi_[A-Za-z0-9]+'
}

function Invoke-NeonProfile {
    param(
        [string]$Email,
        [string[]]$NeonArgs
    )

    $normalized = Normalize-Email -Email $Email
    $profilePath = Get-ProfilePath -Email $normalized
    if (-not (Test-Path -LiteralPath $profilePath)) {
        throw "Neon profile does not exist yet: $normalized. Run .\neon-account.ps1 api-key-add $normalized first."
    }

    $neon = Get-NeonCommand
    $isHelpCommand = $false
    foreach ($arg in $NeonArgs) {
        if ($arg -in @('--help', '-h', 'help')) {
            $isHelpCommand = $true
            break
        }
    }

    if ($isHelpCommand) {
        Invoke-WithNeonApiKey -ApiKey $null -Script {
            & $neon @NeonArgs --config-dir $profilePath
            if ($LASTEXITCODE -ne 0) {
                throw "neon $($NeonArgs -join ' ') failed with exit code $LASTEXITCODE"
            }
        }
        return
    }

    $apiKey = Read-ProfileApiKey -Email $normalized
    if ([string]::IsNullOrWhiteSpace($apiKey)) {
        throw "Neon API key does not exist for profile: $normalized. Run .\neon-account.ps1 api-key-add $normalized. Browser OAuth fallback is disabled for durable mainframe automation."
    }

    Invoke-WithNeonApiKey -ApiKey $apiKey -Script {
        & $neon @NeonArgs --config-dir $profilePath
        if ($LASTEXITCODE -ne 0) {
            throw "neon $($NeonArgs -join ' ') failed with exit code $LASTEXITCODE"
        }
    }
}

function Invoke-NeonJsonProfile {
    param(
        [string]$Email,
        [string[]]$NeonArgs
    )

    Invoke-NeonProfile -Email $Email -NeonArgs (@($NeonArgs) + @('--output', 'json', '--no-color', '--no-analytics'))
}

function Protect-NeonSecretFields {
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
            if ($name -match '^(authorization|accessToken|refreshToken|clientSecret|clientToken|password|secret|value|token|apiKey|api_key|keyString|privateKey|private_key|jwt|cookie|connection_uri|connectionUri|database_url|DATABASE_URL|dsn)$') {
                $result[$name] = '<redacted>'
            } else {
                $result[$name] = Protect-NeonSecretFields -Value $Value[$key]
            }
        }

        return [pscustomobject]$result
    }

    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        $items = @()
        foreach ($item in $Value) {
            $items += Protect-NeonSecretFields -Value $item
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
            if ($name -match '^(authorization|accessToken|refreshToken|clientSecret|clientToken|password|secret|value|token|apiKey|api_key|keyString|privateKey|private_key|jwt|cookie|connection_uri|connectionUri|database_url|DATABASE_URL|dsn)$') {
                $result[$name] = '<redacted>'
            } else {
                $result[$name] = Protect-NeonSecretFields -Value $property.Value
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

    Protect-NeonSecretFields -Value $Value | ConvertTo-Json -Depth $Depth
}

function Invoke-NeonRest {
    param(
        [string]$Email,
        [ValidateSet('GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'HEAD')]
        [string]$Method,
        [string]$PathOrUrl,
        [AllowNull()][string]$JsonBody
    )

    $normalized = Normalize-Email -Email $Email
    $apiKey = Read-ProfileApiKey -Email $normalized
    if ([string]::IsNullOrWhiteSpace($apiKey)) {
        throw "Neon API key does not exist for profile: $normalized. Run .\neon-account.ps1 api-key-add $normalized."
    }

    Invoke-NeonRestWithApiKey -ApiKey $apiKey -Method $Method -PathOrUrl $PathOrUrl -JsonBody $JsonBody
}

function Invoke-NeonRestWithApiKey {
    param(
        [string]$ApiKey,
        [ValidateSet('GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'HEAD')]
        [string]$Method,
        [string]$PathOrUrl,
        [AllowNull()][string]$JsonBody
    )

    if ([string]::IsNullOrWhiteSpace($ApiKey)) {
        throw 'Neon API key is empty.'
    }

    if ($PathOrUrl -match '^https?://') {
        $uri = [uri]$PathOrUrl
        if ($uri.Scheme -ne 'https' -or $uri.Host -ne 'console.neon.tech' -or -not $uri.AbsolutePath.StartsWith('/api/v2/')) {
            throw 'Only https://console.neon.tech/api/v2/... URLs are allowed for neon-account.ps1 api.'
        }

        $url = $uri.AbsoluteUri
    } else {
        $safePath = if ($PathOrUrl.StartsWith('/')) { $PathOrUrl } else { "/$PathOrUrl" }
        if (-not $safePath.StartsWith('/api/v2/')) {
            $safePath = "/api/v2$safePath"
        }

        $url = "https://console.neon.tech$safePath"
    }

    $headers = @{
        Authorization = "Bearer $ApiKey"
        Accept = 'application/json'
    }

    $parameters = @{
        Method = $Method
        Uri = $url
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
        $nativeMessage = $_.Exception.Message
        if ($nativeMessage -match 'SSL connection|secure channel|trust relationship|authentication failed') {
            return Invoke-NeonRestViaCurl -ApiKey $ApiKey -Method $Method -Url $url -JsonBody $JsonBody
        }

        $status = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { $null }
        $message = $_.Exception.Message
        if ($status) {
            throw "Neon API $Method $url failed with HTTP $status. $message"
        }

        throw "Neon API $Method $url failed. $message"
    }
}

function Invoke-NeonRestViaCurl {
    param(
        [string]$ApiKey,
        [ValidateSet('GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'HEAD')]
        [string]$Method,
        [string]$Url,
        [AllowNull()][string]$JsonBody
    )

    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if (-not $curl) {
        throw 'curl.exe was not found for Neon API SSL fallback.'
    }

    $configPath = Join-Path $env:TEMP "mainframe-neon-api-$([Guid]::NewGuid().ToString('N')).curl"
    $bodyPath = $null
    try {
        $configLines = @(
            'silent',
            'show-error',
            'fail-with-body',
            'connect-timeout = 30',
            'max-time = 30',
            "request = `"$Method`"",
            "url = `"$Url`"",
            'header = "Accept: application/json"',
            "header = `"Authorization: Bearer $ApiKey`""
        )

        if (-not [string]::IsNullOrWhiteSpace($JsonBody)) {
            $bodyPath = Join-Path $env:TEMP "mainframe-neon-api-body-$([Guid]::NewGuid().ToString('N')).json"
            Set-Content -LiteralPath $bodyPath -Value $JsonBody -Encoding UTF8
            $configLines += 'header = "Content-Type: application/json"'
            $configLines += "data-binary = @$bodyPath"
        }

        Set-Content -LiteralPath $configPath -Value $configLines -Encoding UTF8
        $output = @(& $curl.Source --config $configPath 2>&1)
        if ($LASTEXITCODE -ne 0) {
            $message = ($output -join [Environment]::NewLine).Trim()
            throw "curl fallback failed with exit code $LASTEXITCODE. $message"
        }

        $text = ($output -join [Environment]::NewLine).Trim()
        if ([string]::IsNullOrWhiteSpace($text)) {
            return $null
        }

        return $text | ConvertFrom-Json
    } finally {
        Remove-Item -LiteralPath $configPath -Force -ErrorAction SilentlyContinue
        if ($bodyPath) {
            Remove-Item -LiteralPath $bodyPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-NeonApiKeyAuthority {
    param(
        [string]$ApiKey,
        [string]$Email
    )

    $normalized = Normalize-Email -Email $Email
    $missing = [Collections.Generic.List[string]]::new()
    $orgRecords = @()
    $credentialClass = 'personal-api-key'
    $meEmail = $null

    try {
        $me = Invoke-NeonCliJsonWithApiKey -ApiKey $ApiKey -NeonArgs @('me')
        if ($me.email) {
            $meEmail = Normalize-Email -Email ([string]$me.email)
        }
    } catch {
        $credentialClass = 'limited-or-non-personal-api-key'
        $missing.Add('personal-api-key-me-check')
    }

    if ($meEmail -ne $normalized) {
        $missing.Add('personal-api-key-email-match')
    }

    try {
        $orgs = @(Invoke-NeonCliJsonWithApiKey -ApiKey $ApiKey -NeonArgs @('orgs', 'list'))
    } catch {
        $orgs = @()
        $missing.Add('organization-list')
    }

    foreach ($org in $orgs) {
        $orgId = [string]$org.id
        $role = $null
        $canReadMembers = $false
        $canListApiKeys = $false

        try {
            $membersResponse = Invoke-NeonRestWithApiKey -ApiKey $ApiKey -Method 'GET' -PathOrUrl "/organizations/$orgId/members" -JsonBody $null
            $canReadMembers = $true
            $self = @($membersResponse.members) | Where-Object {
                $_.user -and $_.user.email -and ((Normalize-Email -Email ([string]$_.user.email)) -eq $normalized)
            } | Select-Object -First 1
            if ($self -and $self.member -and $self.member.role) {
                $role = [string]$self.member.role
            }
        } catch {
            $missing.Add("organization-members:$orgId")
        }

        try {
            $null = Invoke-NeonRestWithApiKey -ApiKey $ApiKey -Method 'GET' -PathOrUrl "/organizations/$orgId/api_keys" -JsonBody $null
            $canListApiKeys = $true
        } catch {
            $missing.Add("organization-api-keys:$orgId")
        }

        if ($role -ne 'admin') {
            $missing.Add("organization-admin-role:$orgId")
        }

        $orgRecords += [pscustomobject]@{
            Id = $orgId
            Name = if ($org.name) { [string]$org.name } else { $null }
            Handle = if ($org.handle) { [string]$org.handle } else { $null }
            Role = $role
            CanReadMembers = $canReadMembers
            CanListApiKeys = $canListApiKeys
            FullAuthority = ($role -eq 'admin' -and $canReadMembers -and $canListApiKeys)
        }
    }

    $uniqueMissing = @($missing.ToArray() | Select-Object -Unique)
    [pscustomobject]@{
        Email = $normalized
        FullAuthority = ($uniqueMissing.Count -eq 0)
        CredentialClass = $credentialClass
        OfficialMaximum = 'personal API key for the account, with admin role in every visible Neon organization'
        OrganizationCount = $orgRecords.Count
        Organizations = $orgRecords
        MissingRequirements = $uniqueMissing
        CheckedAt = (Get-Date).ToString('o')
    }
}

function Get-NeonProfileAuthority {
    param([string]$Email)

    $normalized = Normalize-Email -Email $Email
    $apiKey = Read-ProfileApiKey -Email $normalized
    if ([string]::IsNullOrWhiteSpace($apiKey)) {
        return [pscustomobject]@{
            Email = $normalized
            FullAuthority = $false
            CredentialClass = 'missing-api-key'
            OfficialMaximum = 'personal API key for the account, with admin role in every visible Neon organization'
            OrganizationCount = 0
            Organizations = @()
            MissingRequirements = @('api-key')
            CheckedAt = (Get-Date).ToString('o')
        }
    }

    Get-NeonApiKeyAuthority -ApiKey $apiKey -Email $normalized
}

function Write-NeonAuthority {
    param([string]$Email)

    $authority = Get-NeonProfileAuthority -Email $Email
    Write-Host "Neon authority for $($authority.Email)"
    $authority | Select-Object Email, FullAuthority, CredentialClass, OfficialMaximum, OrganizationCount, MissingRequirements, CheckedAt | Format-List
    if ($authority.Organizations.Count -gt 0) {
        Write-Host 'Organizations:'
        foreach ($org in $authority.Organizations) {
            Write-Host "  - $($org.Id) role=$($org.Role) full=$($org.FullAuthority)"
        }
    }
}

function Get-NeonCapabilities {
    param([string]$Email)

    $status = Get-ProfileStatus -Email $Email
    [pscustomobject]@{
        Email = $status.Email
        State = $status.State
        HasApiKey = $status.HasApiKey
        NeonCliVersion = Get-NeonCliVersion
        OfficialSurfaces = @(
            'Neon CLI with email-keyed NEON_API_KEY profile',
            'Neon REST API at https://console.neon.tech/api/v2',
            'Projects, organizations, branches, endpoints, databases, roles, operations',
            'IP allow list and VPC controls through neonctl raw run',
            'Neon MCP server remains available through the Neon plugin when OAuth is desired'
        )
        ShortcutCommands = @(
            'api',
            'me-json',
            'orgs-json',
            'projects-json',
            'project',
            'branches',
            'endpoints',
            'databases',
            'roles',
            'operations',
            'ip-allow',
            'authority-json',
            'authority-all-json',
            'capabilities-json'
        )
        DefaultCredentialRule = 'Default login accepts only a full-authority personal Neon API key for the detected account; limited keys require api-key-add-limited.'
        SecretRule = 'Generic API output redacts API keys, passwords, connection URIs, DATABASE_URL values, and similar secret fields.'
    }
}

function Write-NeonCapabilities {
    param([string]$Email)

    $capabilities = Get-NeonCapabilities -Email $Email
    Write-Host "Neon capabilities for $Email"
    $capabilities | Select-Object Email, State, HasApiKey, NeonCliVersion | Format-List

    Write-Host 'Official surfaces:'
    foreach ($surface in $capabilities.OfficialSurfaces) {
        Write-Host "  - $surface"
    }

    Write-Host 'Shortcut commands:'
    foreach ($command in $capabilities.ShortcutCommands) {
        Write-Host "  - $command"
    }

    Write-Host "Default credential rule: $($capabilities.DefaultCredentialRule)"
    Write-Host "Secret rule: $($capabilities.SecretRule)"
}

function Get-ProfileEmail {
    param([IO.DirectoryInfo]$Directory)

    $metadataPath = Join-Path $Directory.FullName 'profile.json'
    if (Test-Path -LiteralPath $metadataPath) {
        try {
            $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
            if ($metadata.email) {
                return [string]$metadata.email
            }
        } catch {
            Write-Warning "Could not read profile metadata: $metadataPath"
        }
    }

    return $Directory.Name
}

function Get-ProfileStatus {
    param([string]$Email)

    $normalized = Normalize-Email -Email $Email
    $profilePath = Get-ProfilePath -Email $normalized
    $exists = Test-Path -LiteralPath $profilePath
    $active = Get-ActiveEmail
    $configItems = @()
    if ($exists) {
        $configItems = @(Get-ChildItem -LiteralPath $profilePath -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'profile.json' })
    }
    $apiKeyPath = if ($exists) { Get-ApiKeyPath -ProfilePath $profilePath } else { $null }
    $hasApiKey = -not [string]::IsNullOrWhiteSpace((Read-ProfileApiKey -Email $normalized))

    [pscustomobject]@{
        Email = $normalized
        Exists = $exists
        IsActive = ($active -eq $normalized)
        ConfigDir = $profilePath
        HasApiKey = $hasApiKey
        HasConfig = ($configItems.Count -gt 0)
        State = if (-not $exists) { 'missing-profile' } elseif ($hasApiKey) { 'api-key' } else { 'missing-api-key' }
    }
}

# Count projects for an account via the REST API (no neonctl dependency).
# v2 requires org_id for org-scoped keys; a personal-only key works without it.
# Returns a ps custom object with Count, Projects (list), and Note (error/plan context).
function Get-ProfileProjectCount {
    param([string]$Email)

    $normalized = Normalize-Email -Email $Email
    $apiKey = Read-ProfileApiKey -Email $normalized
    if ([string]::IsNullOrWhiteSpace($apiKey)) {
        return [pscustomobject]@{ Email = $normalized; Count = -1; Projects = @(); Note = 'no api key' }
    }

    $headers = @{
        Authorization = "Bearer $apiKey"
        Accept = 'application/json'
    }

    $projects = @()
    try {
        # personal projects first (no org_id)
        $resp = Invoke-RestMethod -Uri "$apiBase/projects?limit=100" -Headers $headers -TimeoutSec 20 -ErrorAction Stop
        $projects = @($resp.projects)
    } catch {
        # org-scoped key: 400 "org_id is required" -> enumerate orgs then projects per org
        try {
            $orgsResp = Invoke-RestMethod -Uri "$apiBase/users/me/organizations" -Headers $headers -TimeoutSec 20 -ErrorAction Stop
            foreach ($org in @($orgsResp.organizations)) {
                $rp = Invoke-RestMethod -Uri "$apiBase/projects?org_id=$($org.id)&limit=100" -Headers $headers -TimeoutSec 20 -ErrorAction Stop
                foreach ($p in @($rp.projects)) {
                    $projects += [pscustomobject]@{ id = $p.id; name = $p.name; org = $org.name; org_id = $org.id }
                }
            }
        } catch {
            return [pscustomobject]@{ Email = $normalized; Count = -1; Projects = @(); Note = "api error: $($_.Exception.Message)" }
        }
    }

    # if personal response had no projects and no org enumeration ran, try orgs as fallback
    if ($projects.Count -eq 0) {
        try {
            $orgsResp = Invoke-RestMethod -Uri "$apiBase/users/me/organizations" -Headers $headers -TimeoutSec 20 -ErrorAction Stop
            foreach ($org in @($orgsResp.organizations)) {
                $rp = Invoke-RestMethod -Uri "$apiBase/projects?org_id=$($org.id)&limit=100" -Headers $headers -TimeoutSec 20 -ErrorAction Stop
                foreach ($p in @($rp.projects)) {
                    $projects += [pscustomobject]@{ id = $p.id; name = $p.name; org = $org.name; org_id = $org.id }
                }
            }
        } catch {}
    }

    $note = if ($projects.Count -eq 0) { 'no projects' } else { 'ok' }
    return [pscustomobject]@{ Email = $normalized; Count = $projects.Count; Projects = $projects; Note = $note }
}

function Clear-ProfileApiKey {
    param([string]$Email)

    $normalized = Normalize-Email -Email $Email
    $profilePath = Get-ProfilePath -Email $normalized
    $apiKeyPath = Get-ApiKeyPath -ProfilePath $profilePath
    if (Test-Path -LiteralPath $apiKeyPath) {
        Remove-Item -LiteralPath $apiKeyPath -Force
        Write-Host "Neon API key cleared for profile: $normalized"
    } else {
        Write-Host "No Neon API key saved for profile: $normalized"
    }

    if (Test-Path -LiteralPath $profilePath) {
        Write-ProfileMetadata -Email $normalized -ProfilePath $profilePath -AuthType $null
    }
}

function Remove-Profile {
    param([string]$Email)

    $normalized = Normalize-Email -Email $Email
    $profilePath = Get-ProfilePath -Email $normalized
    if (-not (Test-Path -LiteralPath $profilePath)) {
        Write-Host "Neon profile does not exist: $normalized"
        return
    }

    $backupPath = "$profilePath.logged-out-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Move-Item -LiteralPath $profilePath -Destination $backupPath
    Write-Host "Neon profile moved to: $backupPath"

    $active = Get-ActiveEmail
    if ($active -eq $normalized -and (Test-Path -LiteralPath $currentFile)) {
        Remove-Item -LiteralPath $currentFile
        Write-Host 'Active Neon profile cleared.'
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

    'auth' {
        throw 'Neon browser OAuth is disabled in mainframe. Create a Neon API key in the Neon console, then run .\neon-account.ps1 login [email].'
    }

    { $_ -in @('login', 'api-key-add', 'token-add', 'add', 'login-limited', 'api-key-add-limited', 'token-add-limited', 'add-limited') } {
        if ($remaining.Count -gt 1) {
            throw 'Usage: .\neon-account.ps1 api-key-add [email]'
        }

        $allowLimited = $action.ToLowerInvariant() -in @('login-limited', 'api-key-add-limited', 'token-add-limited', 'add-limited')
        $email = if ($remaining.Count -eq 1) { Normalize-Email -Email $remaining[0] } else { $null }
        if ($allowLimited) {
            Write-Warning 'Saving a limited Neon key by explicit request. Default mainframe Neon profiles should use full-authority personal admin keys.'
        }

        Write-Host 'Paste a Neon API key. The value will not be printed.'
        $apiKey = Read-Host -AsSecureString 'Neon API key'
        Write-ProfileApiKey -Email $email -ApiKey $apiKey -AllowLimited:$allowLimited
    }

    { $_ -in @('api-key-clear', 'token-clear') } {
        $email = Get-EmailOrActive -Email $(if ($remaining.Count -gt 0) { $remaining[0] } else { $null })
        Clear-ProfileApiKey -Email $email
    }

    'use' {
        if ($remaining.Count -lt 1) {
            throw 'Usage: .\neon-account.ps1 use <email>'
        }

        $email = Normalize-Email -Email $remaining[0]
        $profilePath = Get-ProfilePath -Email $email
        if (-not (Test-Path -LiteralPath $profilePath)) {
            throw "Neon profile does not exist yet: $email"
        }

        Set-ActiveEmail -Email $email
        Write-Host "Active Neon profile: $email"
    }

    'run' {
        if ($remaining.Count -lt 1) {
            throw 'Usage: .\neon-account.ps1 run [email] <neon args...>'
        }

        if (Test-LooksLikeEmail -Value $remaining[0]) {
            if ($remaining.Count -lt 2) {
                throw 'Usage: .\neon-account.ps1 run [email] <neon args...>'
            }

            $email = Normalize-Email -Email $remaining[0]
            $neonArgs = @($remaining | Select-Object -Skip 1)
        } else {
            $email = Get-EmailOrActive -Email $null
            $neonArgs = @($remaining)
        }

        Invoke-NeonProfile -Email $email -NeonArgs $neonArgs
    }

    'api' {
        if ($remaining.Count -lt 2) {
            throw 'Usage: .\neon-account.ps1 api [email] <GET|POST|PUT|PATCH|DELETE> <api path|url> [json body]'
        }

        if (Test-LooksLikeEmail -Value $remaining[0]) {
            if ($remaining.Count -lt 3) {
                throw 'Usage: .\neon-account.ps1 api [email] <GET|POST|PUT|PATCH|DELETE> <api path|url> [json body]'
            }

            $email = Normalize-Email -Email $remaining[0]
            $method = $remaining[1].ToUpperInvariant()
            $pathOrUrl = $remaining[2]
            $body = if ($remaining.Count -gt 3) { ($remaining[3..($remaining.Count - 1)] -join ' ') } else { $null }
        } else {
            $email = Get-EmailOrActive -Email $null
            $method = $remaining[0].ToUpperInvariant()
            $pathOrUrl = $remaining[1]
            $body = if ($remaining.Count -gt 2) { ($remaining[2..($remaining.Count - 1)] -join ' ') } else { $null }
        }

        ConvertTo-SafeJsonOutput -Value (Invoke-NeonRest -Email $email -Method $method -PathOrUrl $pathOrUrl -JsonBody $body)
    }

    'whoami' {
        $email = Get-EmailOrActive -Email $(if ($remaining.Count -gt 0) { $remaining[0] } else { $null })
        Invoke-NeonProfile -Email $email -NeonArgs @('me')
    }

    'me-json' {
        if ($remaining.Count -gt 1) {
            throw 'Usage: .\neon-account.ps1 me-json [email]'
        }

        $email = Get-EmailOrActive -Email $(if ($remaining.Count -gt 0) { $remaining[0] } else { $null })
        Invoke-NeonJsonProfile -Email $email -NeonArgs @('me')
    }

    'orgs-json' {
        if ($remaining.Count -gt 1) {
            throw 'Usage: .\neon-account.ps1 orgs-json [email]'
        }

        $email = Get-EmailOrActive -Email $(if ($remaining.Count -gt 0) { $remaining[0] } else { $null })
        Invoke-NeonJsonProfile -Email $email -NeonArgs @('orgs', 'list')
    }

    'projects-json' {
        $parts = Split-OptionalEmail -Values $remaining
        $orgId = $null
        if ($parts.Rest.Count -eq 0) {
            $neon = Get-NeonCommand
            $profilePath = Get-ProfilePath -Email $parts.Email
            $apiKey = Read-ProfileApiKey -Email $parts.Email
            $script:neonProjectsJsonOrgOutput = @()
            $script:neonProjectsJsonOrgExitCode = 0
            Invoke-WithNeonApiKey -ApiKey $apiKey -Script {
                $script:neonProjectsJsonOrgOutput = @(& $neon orgs list --output json --no-color --no-analytics --config-dir $profilePath 2>$null)
                $script:neonProjectsJsonOrgExitCode = $LASTEXITCODE
            }

            $orgOutput = @($script:neonProjectsJsonOrgOutput)
            $orgExitCode = $script:neonProjectsJsonOrgExitCode
            Remove-Variable -Name neonProjectsJsonOrgOutput -Scope Script -ErrorAction SilentlyContinue
            Remove-Variable -Name neonProjectsJsonOrgExitCode -Scope Script -ErrorAction SilentlyContinue
            if ($orgExitCode -ne 0) {
                throw "neon orgs list failed with exit code $orgExitCode"
            }

            $orgs = @(($orgOutput -join [Environment]::NewLine) | ConvertFrom-Json)
            if ($orgs.Count -eq 1) {
                Invoke-NeonJsonProfile -Email $parts.Email -NeonArgs @('projects', 'list', '--org-id', $orgs[0].id)
            } elseif ($orgs.Count -gt 1) {
                throw "Neon account has multiple organizations. Re-run with --org-id. Orgs: $(@($orgs | ForEach-Object { $_.id }) -join ', ')"
            } else {
                Invoke-NeonJsonProfile -Email $parts.Email -NeonArgs @('projects', 'list')
            }
        } elseif ($parts.Rest.Count -eq 2 -and $parts.Rest[0] -eq '--org-id') {
            $orgId = $parts.Rest[1]
            Invoke-NeonJsonProfile -Email $parts.Email -NeonArgs @('projects', 'list', '--org-id', $orgId)
        } else {
            throw 'Usage: .\neon-account.ps1 projects-json [email] [--org-id <org-id>]'
        }
    }

    'project' {
        $parts = Split-OptionalEmail -Values $remaining
        if ($parts.Rest.Count -ne 1) {
            throw 'Usage: .\neon-account.ps1 project [email] <project-id>'
        }

        Invoke-NeonJsonProfile -Email $parts.Email -NeonArgs @('projects', 'get', $parts.Rest[0])
    }

    'branches' {
        $parts = Split-OptionalEmail -Values $remaining
        if ($parts.Rest.Count -ne 1) {
            throw 'Usage: .\neon-account.ps1 branches [email] <project-id>'
        }

        Invoke-NeonJsonProfile -Email $parts.Email -NeonArgs @('branches', 'list', '--project-id', $parts.Rest[0])
    }

    'endpoints' {
        $parts = Split-OptionalEmail -Values $remaining
        if ($parts.Rest.Count -ne 1) {
            throw 'Usage: .\neon-account.ps1 endpoints [email] <project-id>'
        }

        ConvertTo-SafeJsonOutput -Value (Invoke-NeonRest -Email $parts.Email -Method 'GET' -PathOrUrl "/projects/$($parts.Rest[0])/endpoints")
    }

    'databases' {
        $parts = Split-OptionalEmail -Values $remaining
        if ($parts.Rest.Count -ne 2) {
            throw 'Usage: .\neon-account.ps1 databases [email] <project-id> <branch-id-or-name>'
        }

        Invoke-NeonJsonProfile -Email $parts.Email -NeonArgs @('databases', 'list', '--project-id', $parts.Rest[0], '--branch', $parts.Rest[1])
    }

    'roles' {
        $parts = Split-OptionalEmail -Values $remaining
        if ($parts.Rest.Count -ne 2) {
            throw 'Usage: .\neon-account.ps1 roles [email] <project-id> <branch-id-or-name>'
        }

        Invoke-NeonJsonProfile -Email $parts.Email -NeonArgs @('roles', 'list', '--project-id', $parts.Rest[0], '--branch', $parts.Rest[1])
    }

    'operations' {
        $parts = Split-OptionalEmail -Values $remaining
        if ($parts.Rest.Count -ne 1) {
            throw 'Usage: .\neon-account.ps1 operations [email] <project-id>'
        }

        Invoke-NeonJsonProfile -Email $parts.Email -NeonArgs @('operations', 'list', '--project-id', $parts.Rest[0])
    }

    'ip-allow' {
        $parts = Split-OptionalEmail -Values $remaining
        if ($parts.Rest.Count -ne 1) {
            throw 'Usage: .\neon-account.ps1 ip-allow [email] <project-id>'
        }

        Invoke-NeonJsonProfile -Email $parts.Email -NeonArgs @('ip-allow', 'list', '--project-id', $parts.Rest[0])
    }

    'authority' {
        if ($remaining.Count -gt 1) {
            throw 'Usage: .\neon-account.ps1 authority [email]'
        }

        $email = Get-EmailOrActive -Email $(if ($remaining.Count -gt 0) { $remaining[0] } else { $null })
        Write-NeonAuthority -Email $email
    }

    'authority-json' {
        if ($remaining.Count -gt 1) {
            throw 'Usage: .\neon-account.ps1 authority-json [email]'
        }

        $email = Get-EmailOrActive -Email $(if ($remaining.Count -gt 0) { $remaining[0] } else { $null })
        ConvertTo-SafeJsonOutput -Value (Get-NeonProfileAuthority -Email $email)
    }

    'authority-all-json' {
        if ($remaining.Count -gt 0) {
            throw 'Usage: .\neon-account.ps1 authority-all-json'
        }

        $profiles = @()
        if (Test-Path -LiteralPath $accountRoot) {
            $profiles = @(Get-ChildItem -LiteralPath $accountRoot -Directory -Force | Where-Object { $_.Name -notlike '*.logged-out-*' })
        }

        $results = foreach ($profile in $profiles) {
            $email = Get-ProfileEmail -Directory $profile
            try {
                Get-NeonProfileAuthority -Email $email
            } catch {
                [pscustomobject]@{
                    Email = $email
                    FullAuthority = $false
                    CredentialClass = 'audit-failed'
                    OfficialMaximum = 'personal API key for the account, with admin role in every visible Neon organization'
                    OrganizationCount = 0
                    Organizations = @()
                    MissingRequirements = @('audit-failed')
                    Error = $_.Exception.Message
                    CheckedAt = (Get-Date).ToString('o')
                }
            }
        }

        ConvertTo-SafeJsonOutput -Value @($results)
    }

    'capabilities' {
        if ($remaining.Count -gt 1) {
            throw 'Usage: .\neon-account.ps1 capabilities [email]'
        }

        $email = Get-EmailOrActive -Email $(if ($remaining.Count -gt 0) { $remaining[0] } else { $null })
        Write-NeonCapabilities -Email $email
    }

    'capabilities-json' {
        if ($remaining.Count -gt 1) {
            throw 'Usage: .\neon-account.ps1 capabilities-json [email]'
        }

        $email = Get-EmailOrActive -Email $(if ($remaining.Count -gt 0) { $remaining[0] } else { $null })
        ConvertTo-SafeJsonOutput -Value (Get-NeonCapabilities -Email $email)
    }

    'status' {
        $email = Get-EmailOrActive -Email $(if ($remaining.Count -gt 0) { $remaining[0] } else { $null })
        Get-ProfileStatus -Email $email | Format-List
    }

    'status-all' {
        if (-not (Test-Path -LiteralPath $accountRoot)) {
            Write-Host 'No Neon profiles found.'
            return
        }

        $profiles = @(Get-ChildItem -LiteralPath $accountRoot -Directory -Force | Where-Object { $_.Name -match '^[^\s@]+@[^\s@]+\.[^\s@]+$' } | Sort-Object Name)
        if ($profiles.Count -eq 0) {
            Write-Host 'No Neon profiles found.'
            return
        }

        $profiles |
            ForEach-Object { Get-ProfileStatus -Email (Get-ProfileEmail -Directory $_) } |
            Format-Table -AutoSize
    }

    'projects-count' {
        if ($remaining.Count -gt 1) {
            throw 'Usage: .\neon-account.ps1 projects-count [email]'
        }

        $target = if ($remaining.Count -eq 1) { Normalize-Email -Email $remaining[0] } else { $null }
        if (-not (Test-Path -LiteralPath $accountRoot)) {
            Write-Host 'No Neon profiles found.'
            return
        }

        $profiles = @(Get-ChildItem -LiteralPath $accountRoot -Directory -Force | Where-Object { $_.Name -match '^[^\s@]+@[^\s@]+\.[^\s@]+$' } | Sort-Object Name)
        if ($profiles.Count -eq 0) {
            Write-Host 'No Neon profiles found.'
            return
        }

        $rows = @()
        foreach ($profile in $profiles) {
            $email = Get-ProfileEmail -Directory $profile
            if ($target -and $email -ne $target) {
                continue
            }
            $row = Get-ProfileProjectCount -Email $email
            $rows += $row
        }

        $rows | Sort-Object Count, Email | Format-Table Email, Count, Note -AutoSize
        Write-Host ''
        Write-Host 'Accounts with 0 projects:'
        $zero = @($rows | Where-Object { $_.Count -eq 0 })
        if ($zero.Count -eq 0) {
            Write-Host '  (none)'
        } else {
            $zero | ForEach-Object { Write-Host "  $($_.Email)" }
        }
    }

    'current' {
        $active = Get-ActiveEmail
        if ($active) {
            Write-Host $active
        } else {
            Write-Host 'No active Neon profile set.'
        }
    }

    'path' {
        $email = Get-EmailOrActive -Email $(if ($remaining.Count -gt 0) { $remaining[0] } else { $null })
        Write-Host (Get-ProfilePath -Email $email)
    }

    'env' {
        $email = Get-EmailOrActive -Email $(if ($remaining.Count -gt 0) { $remaining[0] } else { $null })
        $profilePath = Get-ProfilePath -Email $email
        $apiKeyPath = Get-ApiKeyPath -ProfilePath $profilePath
        $apiKeyState = if (Test-Path -LiteralPath $apiKeyPath) { '<profile api key>' } else { '<missing api key>' }
        Write-Host "`$env:NEON_API_KEY = $apiKeyState"
    }

    'logout' {
        $email = Get-EmailOrActive -Email $(if ($remaining.Count -gt 0) { $remaining[0] } else { $null })
        Remove-Profile -Email $email
    }

    'list' {
        if (-not (Test-Path -LiteralPath $accountRoot)) {
            Write-Host 'No Neon profiles found.'
            return
        }

        $active = Get-ActiveEmail
        $profiles = @(Get-ChildItem -LiteralPath $accountRoot -Directory -Force | Where-Object { $_.Name -match '^[^\s@]+@[^\s@]+\.[^\s@]+$' } | Sort-Object Name)
        if ($profiles.Count -eq 0) {
            Write-Host 'No Neon profiles found.'
            return
        }

        foreach ($profile in $profiles) {
            $email = Get-ProfileEmail -Directory $profile
            $marker = if ($email -eq $active) { '*' } else { ' ' }
            Write-Host "$marker $email"
        }
    }

    default {
        Show-Usage
        throw "Unknown action: $action"
    }
}
