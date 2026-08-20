$ErrorActionPreference = 'Stop'

$accountRoot = Join-Path $env:APPDATA 'mainframe\accounts\vercel'
$currentFile = Join-Path $accountRoot 'current.json'
$legacyCurrentFile = Join-Path $accountRoot 'current.txt'
$apiBase = 'https://api.vercel.com'
$env:NO_UPDATE_NOTIFIER = '1'

function Show-Usage {
    @'
Vercel token profile helper

Profiles are keyed by email and stored in:
  %APPDATA%\mainframe\accounts\vercel\<email>\token.txt

Usage:
  .\vercel-account.ps1 token-add
  .\vercel-account.ps1 token-add-limited
  .\vercel-account.ps1 token-clear [email]
  .\vercel-account.ps1 login
  .\vercel-account.ps1 login-limited
  .\vercel-account.ps1 use <email>
  .\vercel-account.ps1 run [email] <vercel args...>
  .\vercel-account.ps1 api [email] <GET|POST|PUT|PATCH|DELETE> <api path> [json body]
  .\vercel-account.ps1 whoami [email]
  .\vercel-account.ps1 teams [email]
  .\vercel-account.ps1 projects [email] [--all-teams|--team <teamId-or-slug>]
  .\vercel-account.ps1 deployments [email] [--team <teamId-or-slug>] [--project <projectId-or-name>] [--limit <n>]
  .\vercel-account.ps1 domains [email] [--team <teamId-or-slug>]
  .\vercel-account.ps1 tokens [email]
  .\vercel-account.ps1 authority [email]
  .\vercel-account.ps1 authority-json [email]
  .\vercel-account.ps1 authority-all-json
  .\vercel-account.ps1 capabilities [email]
  .\vercel-account.ps1 capabilities-json [email]
  .\vercel-account.ps1 status [email]
  .\vercel-account.ps1 status-all
  .\vercel-account.ps1 list
  .\vercel-account.ps1 current
  .\vercel-account.ps1 path [email]
  .\vercel-account.ps1 env [email]
  .\vercel-account.ps1 logout [email]

Examples:
  .\vercel-account.ps1 token-add
  .\vercel-account.ps1 use user@example.com
  .\vercel-account.ps1 run user@example.com deploy --prod
  .\vercel-account.ps1 run deploy --prod
  .\vercel-account.ps1 api user@example.com GET /v9/projects
  .\vercel-account.ps1 projects user@example.com --all-teams
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

function Get-ProfileTokenPath {
    param([string]$ProfilePath)

    return Join-Path $ProfilePath 'token.txt'
}

function Get-VercelCommand {
    $cmd = Get-Command vercel -ErrorAction SilentlyContinue
    if ($cmd) {
        return $cmd.Source
    }

    throw 'Vercel CLI was not found. Install it with: pnpm add -g vercel'
}

function Find-EmailInObject {
    param([AllowNull()]$Value)

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [string]) {
        if (Test-LooksLikeEmail -Value $Value) {
            return (Normalize-Email -Email $Value)
        }

        $match = [regex]::Match($Value, '[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($match.Success) {
            return (Normalize-Email -Email $match.Value)
        }

        return $null
    }

    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        foreach ($item in $Value) {
            $email = Find-EmailInObject -Value $item
            if ($email) {
                return $email
            }
        }

        return $null
    }

    if ($Value.PSObject -and $Value.PSObject.Properties) {
        foreach ($name in @('email', 'emailAddress', 'username')) {
            $property = $Value.PSObject.Properties[$name]
            if ($property) {
                $email = Find-EmailInObject -Value $property.Value
                if ($email) {
                    return $email
                }
            }
        }

        foreach ($property in $Value.PSObject.Properties) {
            $email = Find-EmailInObject -Value $property.Value
            if ($email) {
                return $email
            }
        }
    }

    return $null
}

function Resolve-VercelEmailFromToken {
    param([string]$Token)

    if ([string]::IsNullOrWhiteSpace($Token)) {
        return $null
    }

    $vercel = Get-VercelCommand
    $previousToken = $env:VERCEL_TOKEN
    $previousTelemetryDisabled = $env:VERCEL_TELEMETRY_DISABLED
    $runConfigPath = Join-Path $env:TEMP "mainframe-vercel-detect-$([Guid]::NewGuid().ToString('N'))"

    try {
        $env:VERCEL_TOKEN = $Token
        $env:VERCEL_TELEMETRY_DISABLED = '1'
        New-Item -ItemType Directory -Force -Path $runConfigPath | Out-Null

        $output = @(& $vercel --global-config $runConfigPath api /v2/user --raw 2>$null)
        if ($LASTEXITCODE -ne 0 -or -not $output) {
            return $null
        }

        $text = ($output -join [Environment]::NewLine)
        try {
            $json = $text | ConvertFrom-Json
            return Find-EmailInObject -Value $json
        } catch {
            return Find-EmailInObject -Value $text
        }
    } finally {
        if ($null -eq $previousToken) {
            Remove-Item Env:\VERCEL_TOKEN -ErrorAction SilentlyContinue
        } else {
            $env:VERCEL_TOKEN = $previousToken
        }

        if ($null -eq $previousTelemetryDisabled) {
            Remove-Item Env:\VERCEL_TELEMETRY_DISABLED -ErrorAction SilentlyContinue
        } else {
            $env:VERCEL_TELEMETRY_DISABLED = $previousTelemetryDisabled
        }

        Remove-Item -LiteralPath $runConfigPath -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Ensure-ProfileDirectory {
    param([string]$ProfilePath)

    New-Item -ItemType Directory -Force -Path $ProfilePath | Out-Null
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

function Read-ProfileToken {
    param([string]$ProfilePath)

    $tokenPath = Get-ProfileTokenPath -ProfilePath $ProfilePath
    if (-not (Test-Path -LiteralPath $tokenPath)) {
        return $null
    }

    $token = (Get-Content -LiteralPath $tokenPath -Raw).Trim()
    if ([string]::IsNullOrWhiteSpace($token)) {
        return $null
    }

    return $token
}

function Write-ProfileToken {
    param(
        [string]$Email,
        [Security.SecureString]$Token
    )

    $normalized = Normalize-Email -Email $Email
    $profilePath = Get-ProfilePath -Email $normalized
    Ensure-ProfileDirectory -ProfilePath $profilePath

    Convert-SecureStringToPlainText -SecureString $Token |
        Set-Content -LiteralPath (Get-ProfileTokenPath -ProfilePath $profilePath) -NoNewline -Encoding UTF8
    Set-ActiveEmail -Email $normalized
}

function Write-ProfileTokenText {
    param(
        [string]$Email,
        [string]$Token
    )

    $normalized = Normalize-Email -Email $Email
    if ([string]::IsNullOrWhiteSpace($Token)) {
        throw 'Vercel token is empty.'
    }

    $profilePath = Get-ProfilePath -Email $normalized
    Ensure-ProfileDirectory -ProfilePath $profilePath

    $Token.Trim() |
        Set-Content -LiteralPath (Get-ProfileTokenPath -ProfilePath $profilePath) -NoNewline -Encoding UTF8
    Set-ActiveEmail -Email $normalized
}

function Remove-ProfileToken {
    param([string]$Email)

    $normalized = Normalize-Email -Email $Email
    $tokenPath = Get-ProfileTokenPath -ProfilePath (Get-ProfilePath -Email $normalized)
    if (Test-Path -LiteralPath $tokenPath) {
        Remove-Item -LiteralPath $tokenPath -Force
        Write-Host "Removed saved Vercel token profile for: $normalized"
        return
    }

    Write-Host "No saved Vercel token profile found for: $normalized"
}

function Format-VercelArgsForError {
    param([string[]]$VercelArgs)

    $safeArgs = @()
    $redactNext = $false
    foreach ($arg in $VercelArgs) {
        if ($redactNext) {
            $safeArgs += '<redacted>'
            $redactNext = $false
            continue
        }

        if ($arg -eq '--value' -or $arg -eq '-v' -or $arg -eq '--token') {
            $safeArgs += $arg
            $redactNext = $true
            continue
        }

        if ($arg -match '^(--value|-v|--token)=') {
            $safeArgs += ($arg -replace '=(.*)$', '=<redacted>')
            continue
        }

        $safeArgs += $arg
    }

    return ($safeArgs -join ' ')
}

function Get-VercelProfileStatus {
    param([string]$Email)

    $normalized = Normalize-Email -Email $Email
    $profilePath = Get-ProfilePath -Email $normalized
    if (-not (Test-Path -LiteralPath $profilePath)) {
        return [pscustomobject]@{
            Email = $normalized
            Exists = $false
            HasTokenProfile = $false
            TokenStorage = $null
            State = 'missing-profile'
        }
    }

    $hasToken = -not [string]::IsNullOrWhiteSpace((Read-ProfileToken -ProfilePath $profilePath))
    return [pscustomobject]@{
        Email = $normalized
        Exists = $true
        HasTokenProfile = $hasToken
        TokenStorage = if ($hasToken) { 'plain-text-token-file' } else { $null }
        State = if ($hasToken) { 'token-profile' } else { 'missing-token' }
    }
}

function Get-VercelProfileDirectories {
    if (-not (Test-Path -LiteralPath $accountRoot)) {
        return @()
    }

    return @(
        Get-ChildItem -LiteralPath $accountRoot -Directory -Force |
            Where-Object { $_.Name -match '^[^\s@]+@[^\s@]+\.[^\s@]+$' } |
            Where-Object { $_.Name -notmatch '\.(deleted|wrong|logged-out|backup)-' } |
            Sort-Object Name
    )
}

function Set-ActiveEmail {
    param([string]$Email)

    $normalized = Normalize-Email -Email $Email
    New-Item -ItemType Directory -Force -Path $accountRoot | Out-Null
    [ordered]@{
        tool = 'vercel'
        service = 'vercel.com'
        email = $normalized
        updatedAt = (Get-Date).ToString('o')
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $currentFile -Encoding UTF8

    if (Test-Path -LiteralPath $legacyCurrentFile) {
        Remove-Item -LiteralPath $legacyCurrentFile -Force
    }
}

function Get-ActiveEmail {
    if (Test-Path -LiteralPath $currentFile) {
        try {
            $current = Get-Content -LiteralPath $currentFile -Raw | ConvertFrom-Json
            foreach ($value in @($current.email, $current.profile)) {
                if (-not [string]::IsNullOrWhiteSpace([string]$value)) {
                    return Normalize-Email -Email ([string]$value)
                }
            }
        } catch {
            $activeText = (Get-Content -LiteralPath $currentFile -Raw).Trim()
            if (-not [string]::IsNullOrWhiteSpace($activeText)) {
                try {
                    return Normalize-Email -Email $activeText
                } catch {
                    return $null
                }
            }
        }
    }

    if (Test-Path -LiteralPath $legacyCurrentFile) {
        $active = (Get-Content -LiteralPath $legacyCurrentFile -Raw).Trim()
        if ([string]::IsNullOrWhiteSpace($active)) {
            return $null
        }

        try {
            return Normalize-Email -Email $active
        } catch {
            return $null
        }
    }

    return $null
}

function Get-EmailOrActive {
    param([AllowNull()][string]$Email)

    if (-not [string]::IsNullOrWhiteSpace($Email)) {
        return Normalize-Email -Email $Email
    }

    $active = Get-ActiveEmail
    if (-not $active) {
        throw 'No email was provided and no active Vercel token profile is set. Run .\vercel-account.ps1 use <email>.'
    }

    return $active
}

function Invoke-VercelProfile {
    param(
        [string]$Email,
        [string[]]$VercelArgs
    )

    $normalized = Normalize-Email -Email $Email
    $profilePath = Get-ProfilePath -Email $normalized
    if (-not (Test-Path -LiteralPath $profilePath)) {
        throw "Vercel token profile does not exist yet: $normalized. Run .\vercel-account.ps1 token-add first; the profile email must be detected from the token."
    }

    $token = Read-ProfileToken -ProfilePath $profilePath
    if ([string]::IsNullOrWhiteSpace($token)) {
        throw "Vercel token profile has no saved token: $normalized. Run .\vercel-account.ps1 token-add; the profile email must be detected from the token."
    }

    $vercel = Get-VercelCommand
    $previousToken = $env:VERCEL_TOKEN
    $previousTelemetryDisabled = $env:VERCEL_TELEMETRY_DISABLED
    $runConfigPath = Join-Path $env:TEMP "mainframe-vercel-$($normalized)-$([Guid]::NewGuid().ToString('N'))"

    try {
        $env:VERCEL_TOKEN = $token
        $env:VERCEL_TELEMETRY_DISABLED = '1'
        New-Item -ItemType Directory -Force -Path $runConfigPath | Out-Null

        & $vercel --global-config $runConfigPath @VercelArgs
        if ($LASTEXITCODE -ne 0) {
            throw "vercel $(Format-VercelArgsForError -VercelArgs $VercelArgs) failed with exit code $LASTEXITCODE"
        }
    } finally {
        if ($null -eq $previousToken) {
            Remove-Item Env:\VERCEL_TOKEN -ErrorAction SilentlyContinue
        } else {
            $env:VERCEL_TOKEN = $previousToken
        }

        if ($null -eq $previousTelemetryDisabled) {
            Remove-Item Env:\VERCEL_TELEMETRY_DISABLED -ErrorAction SilentlyContinue
        } else {
            $env:VERCEL_TELEMETRY_DISABLED = $previousTelemetryDisabled
        }

        Remove-Item -LiteralPath $runConfigPath -Recurse -Force -ErrorAction SilentlyContinue
    }
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

function Resolve-VercelTeamId {
    param(
        [string]$Email,
        [AllowNull()][string]$Team
    )

    if ([string]::IsNullOrWhiteSpace($Team)) {
        return $null
    }

    if ($Team -like 'team_*') {
        return $Team
    }

    $teams = Invoke-VercelRest -Email $Email -Method 'GET' -Path '/v2/teams'
    foreach ($teamInfo in @($teams.teams)) {
        if ($teamInfo.id -eq $Team -or $teamInfo.slug -eq $Team -or $teamInfo.name -eq $Team) {
            return [string]$teamInfo.id
        }
    }

    throw "Vercel team was not found for ${Email}: $Team"
}

function Resolve-VercelProjectId {
    param(
        [string]$Email,
        [AllowNull()][string]$Project,
        [AllowNull()][string]$TeamId
    )

    if ([string]::IsNullOrWhiteSpace($Project)) {
        return $null
    }

    if ($Project -like 'prj_*') {
        return $Project
    }

    $projects = @(Get-VercelProjectSummaries -Email $Email -TeamId $TeamId)
    foreach ($projectInfo in $projects) {
        if ($projectInfo.id -eq $Project -or $projectInfo.name -eq $Project) {
            return [string]$projectInfo.id
        }
    }

    throw "Vercel project was not found for ${Email}: $Project"
}

function Invoke-VercelRest {
    param(
        [string]$Email,
        [ValidateSet('GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'HEAD')]
        [string]$Method,
        [string]$Path,
        [AllowNull()][string]$JsonBody,
        [AllowNull()][string]$TeamId
    )

    $normalized = Normalize-Email -Email $Email
    $profilePath = Get-ProfilePath -Email $normalized
    if (-not (Test-Path -LiteralPath $profilePath)) {
        throw "Vercel token profile does not exist yet: $normalized. Run .\vercel-account.ps1 token-add first."
    }

    $token = Read-ProfileToken -ProfilePath $profilePath
    if ([string]::IsNullOrWhiteSpace($token)) {
        throw "Vercel token profile has no saved token: $normalized. Run .\vercel-account.ps1 token-add first."
    }

    $safePath = if ($Path.StartsWith('/')) { $Path } else { "/$Path" }
    $safePath = Add-QueryParameter -Path $safePath -Name 'teamId' -Value $TeamId
    $uri = "$apiBase$safePath"
    $headers = @{
        Authorization = "Bearer $token"
        Accept = 'application/json'
    }

    try {
        $parameters = @{
            Method = $Method
            Uri = $uri
            Headers = $headers
            ErrorAction = 'Stop'
        }

        if (-not [string]::IsNullOrWhiteSpace($JsonBody)) {
            $parameters['ContentType'] = 'application/json'
            $parameters['Body'] = $JsonBody
        }

        return Invoke-RestMethod @parameters
    } catch {
        $nativeMessage = $_.Exception.Message
        if ($nativeMessage -match 'SSL connection|secure channel|trust relationship|authentication failed') {
            return Invoke-VercelRestViaCli -Email $normalized -Method $Method -Path $safePath -JsonBody $JsonBody
        }

        $status = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { $null }
        $message = $_.Exception.Message
        if ($status) {
            throw "Vercel API $Method $safePath failed with HTTP $status. $message"
        }

        throw "Vercel API $Method $safePath failed. $message"
    }
}

function Invoke-VercelRestViaCli {
    param(
        [string]$Email,
        [ValidateSet('GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'HEAD')]
        [string]$Method,
        [string]$Path,
        [AllowNull()][string]$JsonBody
    )

    $normalized = Normalize-Email -Email $Email
    $profilePath = Get-ProfilePath -Email $normalized
    $token = Read-ProfileToken -ProfilePath $profilePath
    if ([string]::IsNullOrWhiteSpace($token)) {
        throw "Vercel token profile has no saved token: $normalized. Run .\vercel-account.ps1 token-add first."
    }

    $vercel = Get-VercelCommand
    $previousToken = $env:VERCEL_TOKEN
    $previousTelemetryDisabled = $env:VERCEL_TELEMETRY_DISABLED
    $runConfigPath = Join-Path $env:TEMP "mainframe-vercel-api-$($normalized)-$([Guid]::NewGuid().ToString('N'))"
    $bodyPath = $null

    try {
        $env:VERCEL_TOKEN = $token
        $env:VERCEL_TELEMETRY_DISABLED = '1'
        New-Item -ItemType Directory -Force -Path $runConfigPath | Out-Null

        $cliArgs = @('--global-config', $runConfigPath, 'api', $Path, '--raw', '-X', $Method)
        if ($Method -eq 'DELETE') {
            $cliArgs += '--dangerously-skip-permissions'
        }

        if (-not [string]::IsNullOrWhiteSpace($JsonBody)) {
            $bodyPath = Join-Path $env:TEMP "mainframe-vercel-api-body-$([Guid]::NewGuid().ToString('N')).json"
            Set-Content -LiteralPath $bodyPath -Value $JsonBody -Encoding UTF8
            $cliArgs += @('--input', $bodyPath)
        }

        $output = @(& $vercel @cliArgs 2>$null)
        if ($LASTEXITCODE -ne 0) {
            throw "vercel api $Method $Path failed with exit code $LASTEXITCODE"
        }

        $text = ($output -join [Environment]::NewLine).Trim()
        if ([string]::IsNullOrWhiteSpace($text)) {
            return $null
        }

        return $text | ConvertFrom-Json
    } finally {
        if ($null -eq $previousToken) {
            Remove-Item Env:\VERCEL_TOKEN -ErrorAction SilentlyContinue
        } else {
            $env:VERCEL_TOKEN = $previousToken
        }

        if ($null -eq $previousTelemetryDisabled) {
            Remove-Item Env:\VERCEL_TELEMETRY_DISABLED -ErrorAction SilentlyContinue
        } else {
            $env:VERCEL_TELEMETRY_DISABLED = $previousTelemetryDisabled
        }

        Remove-Item -LiteralPath $runConfigPath -Recurse -Force -ErrorAction SilentlyContinue
        if ($bodyPath) {
            Remove-Item -LiteralPath $bodyPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-VercelRestWithToken {
    param(
        [string]$Token,
        [ValidateSet('GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'HEAD')]
        [string]$Method,
        [string]$Path,
        [AllowNull()][string]$JsonBody
    )

    if ([string]::IsNullOrWhiteSpace($Token)) {
        throw 'Vercel token is empty.'
    }

    $safePath = if ($Path.StartsWith('/')) { $Path } else { "/$Path" }
    $uri = "$apiBase$safePath"
    $headers = @{
        Authorization = "Bearer $($Token.Trim())"
        Accept = 'application/json'
    }

    try {
        $parameters = @{
            Method = $Method
            Uri = $uri
            Headers = $headers
            ErrorAction = 'Stop'
        }

        if (-not [string]::IsNullOrWhiteSpace($JsonBody)) {
            $parameters['ContentType'] = 'application/json'
            $parameters['Body'] = $JsonBody
        }

        return Invoke-RestMethod @parameters
    } catch {
        $nativeMessage = $_.Exception.Message
        if ($nativeMessage -notmatch 'SSL connection|secure channel|trust relationship|authentication failed') {
            throw
        }

        $vercel = Get-VercelCommand
        $previousToken = $env:VERCEL_TOKEN
        $previousTelemetryDisabled = $env:VERCEL_TELEMETRY_DISABLED
        $runConfigPath = Join-Path $env:TEMP "mainframe-vercel-token-api-$([Guid]::NewGuid().ToString('N'))"
        $bodyPath = $null

        try {
            $env:VERCEL_TOKEN = $Token.Trim()
            $env:VERCEL_TELEMETRY_DISABLED = '1'
            New-Item -ItemType Directory -Force -Path $runConfigPath | Out-Null

            $cliArgs = @('--global-config', $runConfigPath, 'api', $safePath, '--raw', '-X', $Method)
            if ($Method -eq 'DELETE') {
                $cliArgs += '--dangerously-skip-permissions'
            }

            if (-not [string]::IsNullOrWhiteSpace($JsonBody)) {
                $bodyPath = Join-Path $env:TEMP "mainframe-vercel-token-body-$([Guid]::NewGuid().ToString('N')).json"
                Set-Content -LiteralPath $bodyPath -Value $JsonBody -Encoding UTF8
                $cliArgs += @('--input', $bodyPath)
            }

            $output = @(& $vercel @cliArgs 2>$null)
            if ($LASTEXITCODE -ne 0) {
                throw "vercel api $Method $safePath failed with exit code $LASTEXITCODE"
            }

            $text = ($output -join [Environment]::NewLine).Trim()
            if ([string]::IsNullOrWhiteSpace($text)) {
                return $null
            }

            return $text | ConvertFrom-Json
        } finally {
            if ($null -eq $previousToken) {
                Remove-Item Env:\VERCEL_TOKEN -ErrorAction SilentlyContinue
            } else {
                $env:VERCEL_TOKEN = $previousToken
            }

            if ($null -eq $previousTelemetryDisabled) {
                Remove-Item Env:\VERCEL_TELEMETRY_DISABLED -ErrorAction SilentlyContinue
            } else {
                $env:VERCEL_TELEMETRY_DISABLED = $previousTelemetryDisabled
            }

            Remove-Item -LiteralPath $runConfigPath -Recurse -Force -ErrorAction SilentlyContinue
            if ($bodyPath) {
                Remove-Item -LiteralPath $bodyPath -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

function Get-VercelTokenAuthority {
    param(
        [string]$Token,
        [AllowNull()][string]$Email
    )

    $normalizedEmail = if ([string]::IsNullOrWhiteSpace($Email)) { $null } else { Normalize-Email -Email $Email }
    $detectedEmail = $null
    $username = $null
    $userId = $null
    $teams = @()
    $tokenMetadataVisible = $false
    $tokenScopeTypes = @()
    $apiErrors = New-Object System.Collections.Generic.List[string]
    $missing = New-Object System.Collections.Generic.List[string]

    try {
        $userResponse = Invoke-VercelRestWithToken -Token $Token -Method 'GET' -Path '/v2/user' -JsonBody $null
        $detectedEmail = Find-EmailInObject -Value $userResponse
        $username = $userResponse.user.username
        $userId = $userResponse.user.id
    } catch {
        $apiErrors.Add("user-api: $($_.Exception.Message)")
        $missing.Add('read-user')
    }

    if ($normalizedEmail -and $detectedEmail -and $detectedEmail -ne $normalizedEmail) {
        $missing.Add("email-match:$normalizedEmail")
    }

    try {
        $teamResponse = Invoke-VercelRestWithToken -Token $Token -Method 'GET' -Path '/v2/teams' -JsonBody $null
        $teams = @($teamResponse.teams)
    } catch {
        $apiErrors.Add("teams-api: $($_.Exception.Message)")
        $missing.Add('list-teams')
    }

    try {
        $tokenResponse = Invoke-VercelRestWithToken -Token $Token -Method 'GET' -Path '/v5/user/tokens' -JsonBody $null
        $tokenMetadataVisible = $true
        $tokenScopeTypes = @($tokenResponse.tokens | ForEach-Object { $_.scopes } | ForEach-Object { $_.type } | Where-Object { $_ } | Sort-Object -Unique)
    } catch {
        $apiErrors.Add("tokens-api: $($_.Exception.Message)")
        $missing.Add('list-user-auth-tokens')
    }

    if ($tokenMetadataVisible -and (@($tokenScopeTypes) -notcontains 'user')) {
        $missing.Add('account-level-user-scope')
    }

    $teamSummaries = @()
    foreach ($team in @($teams)) {
        $role = [string]$team.membership.role
        $slug = [string]$team.slug
        if ($role -and $role.ToUpperInvariant() -ne 'OWNER') {
            $missing.Add("team-owner:$slug")
        }

        $teamSummaries += [pscustomobject]@{
            id = $team.id
            slug = $slug
            name = $team.name
            role = $role
            plan = $team.billing.plan
        }
    }

    [pscustomobject]@{
        Service = 'vercel.com'
        Email = if ($normalizedEmail) { $normalizedEmail } else { $detectedEmail }
        DetectedEmail = $detectedEmail
        Username = $username
        UserId = $userId
        FullAuthority = (@($missing.ToArray()).Count -eq 0)
        CredentialClass = if ($tokenMetadataVisible -and (@($tokenScopeTypes) -contains 'user')) { 'account-scoped-access-token' } elseif ($tokenMetadataVisible) { 'limited-access-token' } else { 'unknown-or-limited-token' }
        OfficialMaximum = 'Vercel access token with account-level user scope plus owner role on visible teams'
        TokenMetadataVisible = $tokenMetadataVisible
        TokenScopeTypes = @($tokenScopeTypes)
        TeamCount = @($teams).Count
        Teams = @($teamSummaries)
        MissingRequirements = @($missing.ToArray() | Sort-Object -Unique)
        ApiErrors = @($apiErrors.ToArray())
        CheckedAt = (Get-Date).ToString('o')
    }
}

function Get-VercelProfileAuthority {
    param([string]$Email)

    $normalized = Normalize-Email -Email $Email
    $profilePath = Get-ProfilePath -Email $normalized
    $token = Read-ProfileToken -ProfilePath $profilePath
    if ([string]::IsNullOrWhiteSpace($token)) {
        return [pscustomobject]@{
            Service = 'vercel.com'
            Email = $normalized
            DetectedEmail = $null
            Username = $null
            UserId = $null
            FullAuthority = $false
            CredentialClass = 'missing-token'
            OfficialMaximum = 'Vercel access token with account-level user scope plus owner role on visible teams'
            TokenMetadataVisible = $false
            TokenScopeTypes = @()
            TeamCount = 0
            Teams = @()
            MissingRequirements = @('profile-token-missing')
            ApiErrors = @('profile token missing')
            CheckedAt = (Get-Date).ToString('o')
        }
    }

    return Get-VercelTokenAuthority -Token $token -Email $normalized
}

function Assert-VercelTokenFullAuthority {
    param(
        [string]$Token,
        [AllowNull()][string]$Email,
        [string]$Source
    )

    $authority = Get-VercelTokenAuthority -Token $Token -Email $Email
    if (-not $authority.FullAuthority) {
        $missing = if (@($authority.MissingRequirements).Count -gt 0) { @($authority.MissingRequirements) -join ', ' } else { 'unknown-authority-check' }
        if (@($authority.ApiErrors).Count -gt 0) {
            $missing = "$missing; api-check=$(@($authority.ApiErrors) -join '; ')"
        }

        throw "$Source is not full-authority for mainframe. Missing Vercel requirements: $missing. Use an account-level token from the personal Account Tokens page, or explicitly use token-add-limited/login-limited for a narrow token."
    }

    return $authority
}

function Write-VercelAuthority {
    param([string]$Email)

    $authority = Get-VercelProfileAuthority -Email $Email
    Write-Host "Vercel authority for $($authority.Email)"
    $authority |
        Select-Object Email, DetectedEmail, FullAuthority, CredentialClass, OfficialMaximum, TokenMetadataVisible, TokenScopeTypes, TeamCount, MissingRequirements, ApiErrors, CheckedAt |
        Format-List

    if (@($authority.Teams).Count -gt 0) {
        Write-Host 'Teams:'
        foreach ($team in @($authority.Teams)) {
            Write-Host "  - $($team.slug) [$($team.id)] $($team.role), $($team.plan)"
        }
    }
}

function Protect-VercelSecretFields {
    param([AllowNull()]$Value)

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [string] -or $Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal] -or $Value -is [bool]) {
        return $Value
    }

    if ($Value -is [System.Collections.IDictionary]) {
        $result = [ordered]@{}
        foreach ($key in $Value.Keys) {
            $name = [string]$key
            if ($name -match '^(bearerToken|authorization|accessToken|refreshToken|clientSecret|clientToken|password|secret|value|token|apiKey|privateKey|jwt|cookie)$') {
                $result[$name] = '<redacted>'
            } else {
                $result[$name] = Protect-VercelSecretFields -Value $Value[$key]
            }
        }

        return [pscustomobject]$result
    }

    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        $items = @()
        foreach ($item in $Value) {
            $items += Protect-VercelSecretFields -Value $item
        }

        return $items
    }

    if ($Value.PSObject -and $Value.PSObject.Properties) {
        $result = [ordered]@{}
        foreach ($property in $Value.PSObject.Properties) {
            $name = [string]$property.Name
            if ($name -match '^(bearerToken|authorization|accessToken|refreshToken|clientSecret|clientToken|password|secret|value|token|apiKey|privateKey|jwt|cookie)$') {
                $result[$name] = '<redacted>'
            } else {
                $result[$name] = Protect-VercelSecretFields -Value $property.Value
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

    Protect-VercelSecretFields -Value $Value | ConvertTo-Json -Depth $Depth
}

function Get-VercelTeams {
    param([string]$Email)

    $response = Invoke-VercelRest -Email $Email -Method 'GET' -Path '/v2/teams'
    return @($response.teams)
}

function Get-VercelProjectSummaries {
    param(
        [string]$Email,
        [AllowNull()][string]$TeamId
    )

    $path = '/v9/projects?limit=100'
    $response = Invoke-VercelRest -Email $Email -Method 'GET' -Path $path -TeamId $TeamId
    return @($response.projects)
}

function Get-VercelCapabilities {
    param([string]$Email)

    $normalized = Normalize-Email -Email $Email
    $authority = Get-VercelProfileAuthority -Email $normalized
    $userResponse = Invoke-VercelRest -Email $normalized -Method 'GET' -Path '/v2/user'
    $teams = @(Get-VercelTeams -Email $normalized)
    $tokenResponse = $null
    try {
        $tokenResponse = Invoke-VercelRest -Email $normalized -Method 'GET' -Path '/v5/user/tokens'
    } catch {
        $tokenResponse = $null
    }

    $teamSummaries = @()
    foreach ($team in $teams) {
        $projectCount = $null
        try {
            $projectCount = @(Get-VercelProjectSummaries -Email $normalized -TeamId $team.id).Count
        } catch {
            $projectCount = $null
        }

        $teamSummaries += [pscustomobject]@{
            id = $team.id
            slug = $team.slug
            name = $team.name
            role = $team.membership.role
            plan = $team.billing.plan
            projectCount = $projectCount
        }
    }

    $tokenTypes = @()
    $tokenScopeTypes = @()
    if ($tokenResponse) {
        $tokenTypes = @($tokenResponse.tokens | ForEach-Object { $_.type } | Where-Object { $_ } | Sort-Object -Unique)
        $tokenScopeTypes = @($tokenResponse.tokens | ForEach-Object { $_.scopes } | ForEach-Object { $_.type } | Where-Object { $_ } | Sort-Object -Unique)
    }

    return [pscustomobject]@{
        Email = $normalized
        Username = $userResponse.user.username
        UserId = $userResponse.user.id
        DefaultTeamId = $userResponse.user.defaultTeamId
        Plan = $userResponse.user.billing.plan
        TeamCount = $teams.Count
        Teams = $teamSummaries
        TokenMetadataVisible = [bool]$tokenResponse
        TokenTypes = $tokenTypes
        TokenScopeTypes = $tokenScopeTypes
        Authority = $authority
        OfficialSurfaces = @(
            'Vercel CLI with profile token',
            'Vercel REST API through api command',
            'Vercel SDK with VERCEL_TOKEN from env command',
            'Vercel MCP/plugin for read-oriented dashboard inspection'
        )
        DefaultCredentialRule = 'Default token-add/login accepts only account-level Vercel tokens that can list user auth tokens; limited team/project tokens require token-add-limited/login-limited.'
    }
}

function Write-VercelCapabilities {
    param([string]$Email)

    $capabilities = Get-VercelCapabilities -Email $Email
    Write-Host "Vercel capabilities for $Email"
    $capabilities | Select-Object Email, Username, UserId, DefaultTeamId, Plan, TeamCount, TokenMetadataVisible, TokenTypes, TokenScopeTypes, @{ Name = 'FullAuthority'; Expression = { $_.Authority.FullAuthority } }, @{ Name = 'MissingRequirements'; Expression = { @($_.Authority.MissingRequirements) -join ', ' } } | Format-List
    if (@($capabilities.Teams).Count -gt 0) {
        Write-Host 'Teams:'
        foreach ($team in $capabilities.Teams) {
            $projectText = if ($null -eq $team.projectCount) { 'unknown projects' } else { "$($team.projectCount) projects" }
            Write-Host "  - $($team.slug) [$($team.id)] $($team.role), $($team.plan), $projectText"
        }
    }

    Write-Host 'Official surfaces:'
    foreach ($surface in $capabilities.OfficialSurfaces) {
        Write-Host "  - $surface"
    }
    Write-Host "Default credential rule: $($capabilities.DefaultCredentialRule)"
}

function Parse-VercelReadOptions {
    param([string[]]$Values)

    $options = [ordered]@{
        Email = $null
        Team = $null
        Project = $null
        Limit = $null
        AllTeams = $false
    }

    $index = 0
    if ($Values.Count -gt 0 -and (Test-LooksLikeEmail -Value $Values[0])) {
        $options.Email = Normalize-Email -Email $Values[0]
        $index = 1
    }

    while ($index -lt $Values.Count) {
        $arg = $Values[$index]
        switch ($arg) {
            '--all-teams' {
                $options.AllTeams = $true
                $index++
            }
            '--team' {
                if ($index + 1 -ge $Values.Count) { throw '--team needs a team id or slug.' }
                $options.Team = $Values[$index + 1]
                $index += 2
            }
            '--project' {
                if ($index + 1 -ge $Values.Count) { throw '--project needs a project id or name.' }
                $options.Project = $Values[$index + 1]
                $index += 2
            }
            '--limit' {
                if ($index + 1 -ge $Values.Count) { throw '--limit needs a number.' }
                $options.Limit = [int]$Values[$index + 1]
                $index += 2
            }
            default {
                throw "Unknown option: $arg"
            }
        }
    }

    if (-not $options.Email) {
        $options.Email = Get-EmailOrActive -Email $null
    }

    return [pscustomobject]$options
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

    { $_ -in @('token-add', 'login', 'token-add-limited', 'login-limited') } {
        if ($remaining.Count -gt 0) {
            throw "Usage: .\vercel-account.ps1 $($action.ToLowerInvariant())"
        }

        $allowLimited = $action.ToLowerInvariant() -in @('token-add-limited', 'login-limited')
        Write-Host 'Paste a Vercel token. Input is hidden; mainframe will detect the account email and save it as token.txt.'
        $secureToken = Read-Host 'Vercel token' -AsSecureString
        $plainToken = Convert-SecureStringToPlainText -SecureString $secureToken
        $email = Resolve-VercelEmailFromToken -Token $plainToken
        if (-not $email) {
            throw 'Could not auto-detect the Vercel email from that token. Refusing to save a manually named fallback profile.'
        }

        Write-Host "Detected Vercel email: $email"
        if (-not $allowLimited) {
            Assert-VercelTokenFullAuthority -Token $plainToken -Email $email -Source 'Vercel token' | Out-Null
        } else {
            Write-Warning 'Saving a limited Vercel token by explicit request. Default mainframe Vercel profiles should use account-level tokens.'
        }

        Write-ProfileTokenText -Email $email -Token $plainToken
        Write-Host "Vercel token profile is ready and active: $email"
    }

    'token-clear' {
        $email = Get-EmailOrActive -Email $(if ($remaining.Count -gt 0) { $remaining[0] } else { $null })
        Remove-ProfileToken -Email $email
    }

    'logout' {
        $email = Get-EmailOrActive -Email $(if ($remaining.Count -gt 0) { $remaining[0] } else { $null })
        Remove-ProfileToken -Email $email
    }

    'use' {
        if ($remaining.Count -lt 1) {
            throw 'Usage: .\vercel-account.ps1 use <email>'
        }

        $email = Normalize-Email -Email $remaining[0]
        $profilePath = Get-ProfilePath -Email $email
        if (-not (Test-Path -LiteralPath $profilePath)) {
            throw "Vercel token profile does not exist yet: $email"
        }

        Set-ActiveEmail -Email $email
        Write-Host "Active Vercel token profile: $email"
    }

    'run' {
        if ($remaining.Count -lt 1) {
            throw 'Usage: .\vercel-account.ps1 run [email] <vercel args...>'
        }

        if (Test-LooksLikeEmail -Value $remaining[0]) {
            if ($remaining.Count -lt 2) {
                throw 'Usage: .\vercel-account.ps1 run [email] <vercel args...>'
            }

            $email = Normalize-Email -Email $remaining[0]
            $vercelArgs = @($remaining[1..($remaining.Count - 1)])
        } else {
            $email = Get-EmailOrActive -Email $null
            $vercelArgs = $remaining
        }

        Invoke-VercelProfile -Email $email -VercelArgs $vercelArgs
    }

    'api' {
        if ($remaining.Count -lt 2) {
            throw 'Usage: .\vercel-account.ps1 api [email] <GET|POST|PUT|PATCH|DELETE> <api path> [json body]'
        }

        if (Test-LooksLikeEmail -Value $remaining[0]) {
            if ($remaining.Count -lt 3) {
                throw 'Usage: .\vercel-account.ps1 api [email] <GET|POST|PUT|PATCH|DELETE> <api path> [json body]'
            }

            $email = Normalize-Email -Email $remaining[0]
            $method = $remaining[1].ToUpperInvariant()
            $path = $remaining[2]
            $body = if ($remaining.Count -gt 3) { ($remaining[3..($remaining.Count - 1)] -join ' ') } else { $null }
        } else {
            $email = Get-EmailOrActive -Email $null
            $method = $remaining[0].ToUpperInvariant()
            $path = $remaining[1]
            $body = if ($remaining.Count -gt 2) { ($remaining[2..($remaining.Count - 1)] -join ' ') } else { $null }
        }

        ConvertTo-SafeJsonOutput -Value (Invoke-VercelRest -Email $email -Method $method -Path $path -JsonBody $body)
    }

    'whoami' {
        if ($remaining.Count -gt 1) {
            throw 'Usage: .\vercel-account.ps1 whoami [email]'
        }

        $email = Get-EmailOrActive -Email $(if ($remaining.Count -gt 0) { $remaining[0] } else { $null })
        Invoke-VercelProfile -Email $email -VercelArgs @('whoami')
    }

    'teams' {
        if ($remaining.Count -gt 1) {
            throw 'Usage: .\vercel-account.ps1 teams [email]'
        }

        $email = Get-EmailOrActive -Email $(if ($remaining.Count -gt 0) { $remaining[0] } else { $null })
        Get-VercelTeams -Email $email |
            Select-Object id, slug, name, @{ Name = 'role'; Expression = { $_.membership.role } }, @{ Name = 'plan'; Expression = { $_.billing.plan } } |
            ConvertTo-Json -Depth 8
    }

    'projects' {
        $options = Parse-VercelReadOptions -Values $remaining
        if ($options.AllTeams) {
            $results = @()
            foreach ($team in @(Get-VercelTeams -Email $options.Email)) {
                $projects = @(Get-VercelProjectSummaries -Email $options.Email -TeamId $team.id)
                foreach ($project in $projects) {
                    $results += [pscustomobject]@{
                        teamId = $team.id
                        teamSlug = $team.slug
                        id = $project.id
                        name = $project.name
                        framework = $project.framework
                        updatedAt = $project.updatedAt
                        live = $project.live
                    }
                }
            }

            $results | ConvertTo-Json -Depth 8
        } else {
            $teamId = Resolve-VercelTeamId -Email $options.Email -Team $options.Team
            Get-VercelProjectSummaries -Email $options.Email -TeamId $teamId |
                Select-Object id, name, accountId, framework, updatedAt, live |
                ConvertTo-Json -Depth 8
        }
    }

    'deployments' {
        $options = Parse-VercelReadOptions -Values $remaining
        $limit = if ($null -ne $options.Limit) { [int]$options.Limit } else { 20 }
        $teamId = Resolve-VercelTeamId -Email $options.Email -Team $options.Team
        $projectId = Resolve-VercelProjectId -Email $options.Email -Project $options.Project -TeamId $teamId
        $path = "/v6/deployments?limit=$limit"
        $path = Add-QueryParameter -Path $path -Name 'projectId' -Value $projectId
        $response = Invoke-VercelRest -Email $options.Email -Method 'GET' -Path $path -TeamId $teamId
        $deployments = @($response.deployments) |
            Select-Object -First $limit |
            Select-Object uid, name, url, state, target, created, creator, meta |
            ForEach-Object { $_ }
        ConvertTo-SafeJsonOutput -Value $deployments
    }

    'domains' {
        $options = Parse-VercelReadOptions -Values $remaining
        $teamId = Resolve-VercelTeamId -Email $options.Email -Team $options.Team
        $response = Invoke-VercelRest -Email $options.Email -Method 'GET' -Path '/v6/domains' -TeamId $teamId
        @($response.domains) |
            Select-Object name, apexName, projectId, verified, createdAt, expiresAt |
            ConvertTo-Json -Depth 8
    }

    'tokens' {
        if ($remaining.Count -gt 1) {
            throw 'Usage: .\vercel-account.ps1 tokens [email]'
        }

        $email = Get-EmailOrActive -Email $(if ($remaining.Count -gt 0) { $remaining[0] } else { $null })
        $response = Invoke-VercelRest -Email $email -Method 'GET' -Path '/v5/user/tokens'
        @($response.tokens) |
            Select-Object id, name, type, origin, activeAt, createdAt, expiresAt, @{ Name = 'scopeTypes'; Expression = { @($_.scopes | ForEach-Object { $_.type }) } } |
            ConvertTo-Json -Depth 8
    }

    'authority' {
        if ($remaining.Count -gt 1) {
            throw 'Usage: .\vercel-account.ps1 authority [email]'
        }

        $email = Get-EmailOrActive -Email $(if ($remaining.Count -gt 0) { $remaining[0] } else { $null })
        Write-VercelAuthority -Email $email
    }

    'authority-json' {
        if ($remaining.Count -gt 1) {
            throw 'Usage: .\vercel-account.ps1 authority-json [email]'
        }

        $email = Get-EmailOrActive -Email $(if ($remaining.Count -gt 0) { $remaining[0] } else { $null })
        ConvertTo-SafeJsonOutput -Value (Get-VercelProfileAuthority -Email $email)
    }

    'authority-all-json' {
        if ($remaining.Count -ne 0) {
            throw 'Usage: .\vercel-account.ps1 authority-all-json'
        }

        ConvertTo-SafeJsonOutput -Value @(Get-VercelProfileDirectories | ForEach-Object { Get-VercelProfileAuthority -Email $_.Name })
    }

    'capabilities' {
        if ($remaining.Count -gt 1) {
            throw 'Usage: .\vercel-account.ps1 capabilities [email]'
        }

        $email = Get-EmailOrActive -Email $(if ($remaining.Count -gt 0) { $remaining[0] } else { $null })
        Write-VercelCapabilities -Email $email
    }

    'capabilities-json' {
        if ($remaining.Count -gt 1) {
            throw 'Usage: .\vercel-account.ps1 capabilities-json [email]'
        }

        $email = Get-EmailOrActive -Email $(if ($remaining.Count -gt 0) { $remaining[0] } else { $null })
        ConvertTo-SafeJsonOutput -Value (Get-VercelCapabilities -Email $email)
    }

    'status' {
        if ($remaining.Count -gt 1) {
            throw 'Usage: .\vercel-account.ps1 status [email]'
        }

        $email = Get-EmailOrActive -Email $(if ($remaining.Count -gt 0) { $remaining[0] } else { $null })
        Get-VercelProfileStatus -Email $email | Format-List
    }

    'status-all' {
        $profiles = @(Get-VercelProfileDirectories)
        if ($profiles.Count -eq 0) {
            Write-Host 'No Vercel token profiles found.'
            return
        }

        $profiles |
            ForEach-Object { Get-VercelProfileStatus -Email $_.Name } |
            Format-Table -AutoSize
    }

    'current' {
        $active = Get-ActiveEmail
        if ($active) {
            Write-Host $active
        } else {
            Write-Host 'No active Vercel token profile set.'
        }
    }

    'path' {
        $email = Get-EmailOrActive -Email $(if ($remaining.Count -gt 0) { $remaining[0] } else { $null })
        Write-Host (Get-ProfilePath -Email $email)
    }

    'env' {
        $email = Get-EmailOrActive -Email $(if ($remaining.Count -gt 0) { $remaining[0] } else { $null })
        $profilePath = Get-ProfilePath -Email $email
        $tokenPath = Get-ProfileTokenPath -ProfilePath $profilePath
        $tokenState = if (Test-Path -LiteralPath $tokenPath) { '<profile token>' } else { '<missing token>' }
        Write-Host "`$env:VERCEL_TOKEN = $tokenState"
        Write-Host '$env:VERCEL_TELEMETRY_DISABLED = ''1'''
    }

    'list' {
        $profiles = @(Get-VercelProfileDirectories)
        if ($profiles.Count -eq 0) {
            Write-Host 'No Vercel token profiles found.'
            return
        }

        $active = Get-ActiveEmail
        foreach ($profile in $profiles) {
            $email = $profile.Name
            $marker = if ($email -eq $active) { '*' } else { ' ' }
            Write-Host "$marker $email"
        }
    }

    default {
        Show-Usage
        throw "Unknown action: $action"
    }
}
