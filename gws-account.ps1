$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$accountRoot = Join-Path $env:APPDATA 'mainframe\accounts\gws'
$currentFile = Join-Path $accountRoot 'current.json'
$defaultGwsConfig = Join-Path $env:USERPROFILE '.config\gws'

$DefaultGwsLoginScopes = @(
    'openid',
    'https://www.googleapis.com/auth/userinfo.email',
    'https://www.googleapis.com/auth/userinfo.profile',
    'https://www.googleapis.com/auth/drive',
    'https://www.googleapis.com/auth/spreadsheets',
    'https://www.googleapis.com/auth/gmail.modify',
    'https://www.googleapis.com/auth/calendar',
    'https://www.googleapis.com/auth/documents',
    'https://www.googleapis.com/auth/presentations',
    'https://www.googleapis.com/auth/tasks',
    'https://www.googleapis.com/auth/webmasters',
    'https://www.googleapis.com/auth/siteverification',
    'https://www.googleapis.com/auth/pubsub',
    'https://www.googleapis.com/auth/cloud-platform'
)

function Show-Usage {
    @'
Google Workspace CLI account profile helper

Profiles are keyed by email and stored in:
  %APPDATA%\mainframe\accounts\gws\<email>

Usage:
  .\gws-account.ps1 login [email] [gws auth login args...]
  .\gws-account.ps1 add [gws auth login args...]
  .\gws-account.ps1 setup <email> [gws auth setup args...]
  .\gws-account.ps1 use <email>
  .\gws-account.ps1 run [email] <gws args...>
  .\gws-account.ps1 whoami [email]
  .\gws-account.ps1 gsc [email] <sites|add-site|delete-site|sitemaps|submit-sitemap|delete-sitemap|inspect-url|analytics|verification-token|verify-site|scopes> [...]
  .\gws-account.ps1 status [email]
  .\gws-account.ps1 status-all
  .\gws-account.ps1 logout [email]
  .\gws-account.ps1 list
  .\gws-account.ps1 current
  .\gws-account.ps1 path [email]
  .\gws-account.ps1 env [email]

Examples:
  .\gws-account.ps1 add
  .\gws-account.ps1 login
  .\gws-account.ps1 login user@example.com --services gmail,drive,sheets
  .\gws-account.ps1 login user@example.com --scopes openid,profile,email,https://www.googleapis.com/auth/drive
  .\gws-account.ps1 whoami user@example.com

Note:
  login/add without --scopes, --services, or --full requests all supported scopes
  by default (drive, sheets, gmail, calendar, docs, slides, tasks, webmasters,
  siteverification, pubsub, cloud-platform, and standard openid/userinfo scopes).
  .\gws-account.ps1 run user@example.com auth status
  .\gws-account.ps1 run auth status
  .\gws-account.ps1 run user@example.com gmail users messages list --params '{"userId":"me"}'
  .\gws-account.ps1 run user@example.com drive files list --params '{"pageSize":10}'
  .\gws-account.ps1 gsc user@example.com sites
  .\gws-account.ps1 gsc user@example.com add-site https://www.example.com/
  .\gws-account.ps1 gsc user@example.com sitemaps sc-domain:example.com
  .\gws-account.ps1 gsc user@example.com submit-sitemap sc-domain:example.com https://example.com/sitemap.xml
  .\gws-account.ps1 gsc user@example.com inspect-url https://example.com/news/story sc-domain:example.com
  .\gws-account.ps1 gsc user@example.com analytics sc-domain:example.com 28 query,page
  .\gws-account.ps1 gsc user@example.com verification-token https://example.com/ META SITE
  .\gws-account.ps1 gsc user@example.com verify-site https://example.com/ META SITE
  .\gws-account.ps1 gsc user@example.com scopes

Search Console needs the webmasters OAuth scope:
  .\gws-account.ps1 login user@example.com --scopes https://www.googleapis.com/auth/webmasters,https://www.googleapis.com/auth/siteverification
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

function Get-GwsCommand {
    $cmd = Get-Command gws -ErrorAction SilentlyContinue
    if ($cmd) {
        return $cmd.Source
    }

    throw 'Google Workspace CLI was not found. Install it with: pnpm add -g @googleworkspace/cli'
}

function Write-ProfileMetadata {
    param(
        [string]$Email,
        [string]$ProfilePath
    )

    New-Item -ItemType Directory -Force -Path $ProfilePath | Out-Null
    [ordered]@{
        tool = 'gws'
        email = $Email
        configDir = $ProfilePath
        keyringBackend = 'file'
        updatedAt = (Get-Date).ToString('o')
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $ProfilePath 'profile.json') -Encoding UTF8
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

function Set-ActiveEmail {
    param([string]$Email)

    New-Item -ItemType Directory -Force -Path $accountRoot | Out-Null
    [ordered]@{
        tool = 'gws'
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
        throw 'No email was provided and no active Google Workspace CLI profile is set. Run .\gws-account.ps1 use <email>.'
    }

    return Normalize-Email -Email $active
}

function Copy-DefaultClientConfig {
    param([string]$ProfilePath)

    $targetClientConfig = Join-Path $ProfilePath 'client_secret.json'
    if (Test-Path -LiteralPath $targetClientConfig) {
        return
    }

    if (-not [string]::IsNullOrWhiteSpace($env:GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE)) {
        return
    }

    if (-not [string]::IsNullOrWhiteSpace($env:GOOGLE_WORKSPACE_CLI_CLIENT_ID) -and -not [string]::IsNullOrWhiteSpace($env:GOOGLE_WORKSPACE_CLI_CLIENT_SECRET)) {
        return
    }

    $defaultClientConfig = Join-Path $defaultGwsConfig 'client_secret.json'
    if (Test-Path -LiteralPath $defaultClientConfig) {
        Copy-Item -LiteralPath $defaultClientConfig -Destination $targetClientConfig -Force
        Write-Host "Copied OAuth client config from: $defaultClientConfig"
        return
    }

    $active = Get-ActiveEmail
    if ($active) {
        $activeClientConfig = Join-Path (Get-ProfilePath -Email $active) 'client_secret.json'
        if (Test-Path -LiteralPath $activeClientConfig) {
            Copy-Item -LiteralPath $activeClientConfig -Destination $targetClientConfig -Force
            Write-Host "Copied OAuth client config from active profile: $active"
            return
        }
    }

    if (Test-Path -LiteralPath $accountRoot) {
        $existingClientConfig = Get-ChildItem -LiteralPath $accountRoot -Directory -Force |
            ForEach-Object { Join-Path $_.FullName 'client_secret.json' } |
            Where-Object { Test-Path -LiteralPath $_ } |
            Select-Object -First 1
        if ($existingClientConfig) {
            Copy-Item -LiteralPath $existingClientConfig -Destination $targetClientConfig -Force
            Write-Host "Copied OAuth client config from existing profile: $existingClientConfig"
            return
        }
    }

    Write-Warning 'No client_secret.json was found for this profile. If login fails, run setup first or set GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE.'
}

function Get-ProfileKeyringBackend {
    param([string]$ProfilePath)

    $metadataPath = Join-Path $ProfilePath 'profile.json'
    if (Test-Path -LiteralPath $metadataPath) {
        try {
            $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
            if ($metadata.keyringBackend -in @('file', 'keyring')) {
                return [string]$metadata.keyringBackend
            }
        } catch {
            Write-Warning "Could not read profile metadata: $metadataPath"
        }
    }

    return 'file'
}

function Invoke-WithGwsProfile {
    param(
        [string]$ProfilePath,
        [ValidateSet('file', 'keyring')]
        [string]$KeyringBackend = 'file',
        [scriptblock]$Script
    )

    $oldConfigDir = $env:GOOGLE_WORKSPACE_CLI_CONFIG_DIR
    $oldKeyringBackend = $env:GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND

    try {
        $env:GOOGLE_WORKSPACE_CLI_CONFIG_DIR = $ProfilePath
        $env:GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND = $KeyringBackend
        & $Script
    } finally {
        if ($null -eq $oldConfigDir) {
            Remove-Item Env:\GOOGLE_WORKSPACE_CLI_CONFIG_DIR -ErrorAction SilentlyContinue
        } else {
            $env:GOOGLE_WORKSPACE_CLI_CONFIG_DIR = $oldConfigDir
        }

        if ($null -eq $oldKeyringBackend) {
            Remove-Item Env:\GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND -ErrorAction SilentlyContinue
        } else {
            $env:GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND = $oldKeyringBackend
        }
    }
}

function Invoke-GwsProfile {
    param(
        [string]$Email,
        [string[]]$GwsArgs
    )

    $normalized = Normalize-Email -Email $Email
    $profilePath = Get-ProfilePath -Email $normalized
    if (-not (Test-Path -LiteralPath $profilePath)) {
        throw "Google Workspace CLI profile does not exist yet: $normalized. Run .\gws-account.ps1 login $normalized first."
    }

    $gws = Get-GwsCommand
    $keyringBackend = Get-ProfileKeyringBackend -ProfilePath $profilePath
    Invoke-WithGwsProfile -ProfilePath $profilePath -KeyringBackend $keyringBackend -Script {
        & $gws @GwsArgs
        if ($LASTEXITCODE -ne 0) {
            throw "gws $($GwsArgs -join ' ') failed with exit code $LASTEXITCODE"
        }
    }
}

function Resolve-LoggedInGwsEmail {
    param([string]$ProfilePath)

    $gws = Get-GwsCommand
    $script:gwsAccountStatusOutput = @()
    $script:gwsAccountStatusExitCode = 0
    Invoke-WithGwsProfile -ProfilePath $ProfilePath -KeyringBackend 'file' -Script {
        $script:gwsAccountStatusOutput = @(& $gws auth status 2>$null)
        $script:gwsAccountStatusExitCode = $LASTEXITCODE
    }

    $statusOutput = @($script:gwsAccountStatusOutput)
    $statusExitCode = $script:gwsAccountStatusExitCode
    Remove-Variable -Name gwsAccountStatusOutput -Scope Script -ErrorAction SilentlyContinue
    Remove-Variable -Name gwsAccountStatusExitCode -Scope Script -ErrorAction SilentlyContinue

    if ($statusExitCode -eq 0 -and $statusOutput) {
        $statusText = ($statusOutput -join [Environment]::NewLine)
        try {
            $status = $statusText | ConvertFrom-Json
            foreach ($candidate in @(
                $status.user,
                $status.email,
                $status.account,
                $status.profile.email
            )) {
                $email = Find-EmailInText -Text ([string]$candidate)
                if ($email) {
                    return $email
                }
            }
        } catch {
            $email = Find-EmailInText -Text $statusText
            if ($email) {
                return $email
            }
        }
    }

    try {
        $script:gwsAccountExportOutput = @()
        $script:gwsAccountExportExitCode = 0
        Invoke-WithGwsProfile -ProfilePath $ProfilePath -KeyringBackend 'file' -Script {
            $script:gwsAccountExportOutput = @(& $gws auth export --unmasked 2>$null)
            $script:gwsAccountExportExitCode = $LASTEXITCODE
        }

        $exportOutput = @($script:gwsAccountExportOutput)
        $exportExitCode = $script:gwsAccountExportExitCode
        Remove-Variable -Name gwsAccountExportOutput -Scope Script -ErrorAction SilentlyContinue
        Remove-Variable -Name gwsAccountExportExitCode -Scope Script -ErrorAction SilentlyContinue

        if ($exportExitCode -eq 0 -and $exportOutput) {
            $credentials = ($exportOutput -join [Environment]::NewLine) | ConvertFrom-Json
            $clientConfigPath = Join-Path $ProfilePath 'client_secret.json'
            if ($credentials.refresh_token -and (Test-Path -LiteralPath $clientConfigPath)) {
                $clientConfig = Get-Content -LiteralPath $clientConfigPath -Raw | ConvertFrom-Json
                $oauthClient = if ($clientConfig.installed) {
                    $clientConfig.installed
                } elseif ($clientConfig.web) {
                    $clientConfig.web
                } else {
                    $clientConfig
                }

                $clientId = if ($credentials.client_id) { $credentials.client_id } else { $oauthClient.client_id }
                $clientSecret = if ($credentials.client_secret) { $credentials.client_secret } else { $oauthClient.client_secret }
                if ($clientId -and $clientSecret) {
                    $token = Invoke-RestMethod -Method Post -Uri 'https://oauth2.googleapis.com/token' -Body @{
                        client_id = $clientId
                        client_secret = $clientSecret
                        refresh_token = $credentials.refresh_token
                        grant_type = 'refresh_token'
                    }
                    if ($token.access_token) {
                        $tokenInfo = Invoke-RestMethod -Method Get -Uri ('https://www.googleapis.com/oauth2/v1/tokeninfo?access_token=' + [uri]::EscapeDataString($token.access_token))
                        $email = Find-EmailInText -Text ([string]$tokenInfo.email)
                        if ($email) {
                            return $email
                        }
                    }
                }
            }
        }
    } catch {
        Remove-Variable -Name gwsAccountExportOutput -Scope Script -ErrorAction SilentlyContinue
        Remove-Variable -Name gwsAccountExportExitCode -Scope Script -ErrorAction SilentlyContinue
    }

    return $null
}

function Get-RestErrorMessage {
    param([System.Management.Automation.ErrorRecord]$ErrorRecord)

    $message = $ErrorRecord.Exception.Message
    $response = $ErrorRecord.Exception.Response
    if ($response) {
        try {
            $stream = $response.GetResponseStream()
            if ($stream) {
                $reader = New-Object IO.StreamReader($stream)
                $body = $reader.ReadToEnd()
                if (-not [string]::IsNullOrWhiteSpace($body)) {
                    $message = $body
                }
            }
        } catch {
            # Keep the original exception message.
        }
    }

    return $message
}

function Get-GoogleAccessTokenFromProfile {
    param([string]$ProfilePath)

    $gws = Get-GwsCommand
    $keyringBackend = Get-ProfileKeyringBackend -ProfilePath $ProfilePath
    $script:gwsAccessTokenExportOutput = @()
    $script:gwsAccessTokenExportExitCode = 0
    Invoke-WithGwsProfile -ProfilePath $ProfilePath -KeyringBackend $keyringBackend -Script {
        $oldErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $script:gwsAccessTokenExportOutput = @(& $gws auth export --unmasked 2>&1)
            $script:gwsAccessTokenExportExitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $oldErrorActionPreference
        }
    }

    $exportOutput = @($script:gwsAccessTokenExportOutput)
    $exportExitCode = $script:gwsAccessTokenExportExitCode
    Remove-Variable -Name gwsAccessTokenExportOutput -Scope Script -ErrorAction SilentlyContinue
    Remove-Variable -Name gwsAccessTokenExportExitCode -Scope Script -ErrorAction SilentlyContinue

    if ($exportExitCode -ne 0 -or -not $exportOutput) {
        throw 'Could not export Google Workspace CLI credentials for this profile. Run .\gws-account.ps1 login <email> first.'
    }

    $exportLines = @()
    foreach ($item in $exportOutput) {
        $itemLines = ([string]$item) -split "\r?\n"
        foreach ($line in $itemLines) {
            if ($line -match 'Using keyring backend:') {
                continue
            }

            if ($line -match '^node\.exe\s*:') {
                continue
            }

            if ($line -match '^\s*At\s+.*gws\.ps1:') {
                continue
            }

            if ($line -match '^\s*(\+|~+|CategoryInfo|FullyQualifiedErrorId)\s') {
                continue
            }

            $exportLines += $line
        }
    }

    $exportText = $exportLines -join [Environment]::NewLine
    $jsonStart = $exportText.IndexOf('{')
    $jsonEnd = $exportText.LastIndexOf('}')
    if ($jsonStart -lt 0 -or $jsonEnd -lt $jsonStart) {
        throw 'Could not find JSON credentials in Google Workspace CLI export output.'
    }

    try {
        $credentials = $exportText.Substring($jsonStart, $jsonEnd - $jsonStart + 1) | ConvertFrom-Json
    } catch {
        throw 'Could not parse JSON credentials from Google Workspace CLI export output.'
    }
    if (-not $credentials.refresh_token) {
        throw 'This Google Workspace CLI profile has no refresh token. Run .\gws-account.ps1 login <email> again.'
    }

    $clientConfigPath = Join-Path $ProfilePath 'client_secret.json'
    $oauthClient = $null
    if (Test-Path -LiteralPath $clientConfigPath) {
        $clientConfig = Get-Content -LiteralPath $clientConfigPath -Raw | ConvertFrom-Json
        if ($clientConfig.installed) {
            $oauthClient = $clientConfig.installed
        } elseif ($clientConfig.web) {
            $oauthClient = $clientConfig.web
        } else {
            $oauthClient = $clientConfig
        }
    }

    $clientId = if ($credentials.client_id) { [string]$credentials.client_id } elseif ($oauthClient -and $oauthClient.client_id) { [string]$oauthClient.client_id } else { $null }
    $clientSecret = if ($credentials.client_secret) { [string]$credentials.client_secret } elseif ($oauthClient -and $oauthClient.client_secret) { [string]$oauthClient.client_secret } else { $null }
    if (-not $clientId -or -not $clientSecret) {
        throw 'Could not find OAuth client_id/client_secret for this profile.'
    }

    try {
        $token = Invoke-RestMethod -Method Post -Uri 'https://oauth2.googleapis.com/token' -Body @{
            client_id = $clientId
            client_secret = $clientSecret
            refresh_token = [string]$credentials.refresh_token
            grant_type = 'refresh_token'
        }
    } catch {
        throw "Could not refresh Google OAuth token: $(Get-RestErrorMessage -ErrorRecord $_)"
    }

    if (-not $token.access_token) {
        throw 'Google OAuth did not return an access token.'
    }

    return [string]$token.access_token
}

function ConvertTo-SearchConsoleJson {
    param([AllowNull()]$Value)

    if ($null -eq $Value -or $Value -eq '') {
        return
    }

    $Value | ConvertTo-Json -Depth 30
}

function Invoke-GoogleApi {
    param(
        [string]$Method,
        [string]$Uri,
        [string]$AccessToken,
        [AllowNull()]$Body
    )

    $headers = @{ Authorization = "Bearer $AccessToken" }
    $parameters = @{
        Method = $Method
        Uri = $Uri
        Headers = $headers
    }

    if ($null -ne $Body) {
        $parameters.Body = ($Body | ConvertTo-Json -Depth 20)
        $parameters.ContentType = 'application/json'
    }

    try {
        return Invoke-RestMethod @parameters
    } catch {
        $message = Get-RestErrorMessage -ErrorRecord $_
        if ($message -match 'does not have sufficient permission for site|permission for site') {
            throw "$message`n`nThis Search Console property is not verified for the selected account yet. Verify ownership first, then retry the command."
        }

        if ($message -match 'siteverification|Site Verification') {
            throw "$message`n`nThis profile probably needs Site Verification consent. Re-login with:`n  .\gws-account.ps1 login <email> --scopes https://www.googleapis.com/auth/webmasters,https://www.googleapis.com/auth/siteverification"
        }

        if ($message -match 'SERVICE_DISABLED|accessNotConfigured|has not been used in project|is disabled') {
            throw "$message`n`nThe OAuth scope is OK, but the Google Cloud project needs Search Console API enabled:`n  gcloud services enable searchconsole.googleapis.com --project <project-id>"
        }

        if ($message -match 'insufficient|scope|permission|forbidden|ACCESS_TOKEN_SCOPE_INSUFFICIENT') {
            throw "$message`n`nThis profile probably needs Search Console consent. Re-login with:`n  .\gws-account.ps1 login <email> --scopes https://www.googleapis.com/auth/webmasters"
        }

        throw $message
    }
}

function Show-SearchConsoleUsage {
    @'
Search Console commands

Usage:
  .\gws-account.ps1 gsc [email] sites
  .\gws-account.ps1 gsc [email] add-site <siteUrl>
  .\gws-account.ps1 gsc [email] delete-site <siteUrl>
  .\gws-account.ps1 gsc [email] sitemaps <siteUrl>
  .\gws-account.ps1 gsc [email] submit-sitemap <siteUrl> <sitemapUrl>
  .\gws-account.ps1 gsc [email] delete-sitemap <siteUrl> <sitemapUrl>
  .\gws-account.ps1 gsc [email] inspect-url <inspectionUrl> <siteUrl> [languageCode]
  .\gws-account.ps1 gsc [email] analytics <siteUrl> [days] [dimensionsCsv]
  .\gws-account.ps1 gsc [email] verification-token <identifier> [method] [type]
  .\gws-account.ps1 gsc [email] verify-site <identifier> [method] [type]
  .\gws-account.ps1 gsc [email] scopes

Examples:
  .\gws-account.ps1 gsc sites
  .\gws-account.ps1 gsc user@example.com sites
  .\gws-account.ps1 gsc user@example.com add-site https://www.example.com/
  .\gws-account.ps1 gsc user@example.com sitemaps sc-domain:example.com
  .\gws-account.ps1 gsc user@example.com submit-sitemap sc-domain:example.com https://example.com/sitemap.xml
  .\gws-account.ps1 gsc user@example.com inspect-url https://example.com/news/story sc-domain:example.com
  .\gws-account.ps1 gsc user@example.com analytics sc-domain:example.com 28 query,page
  .\gws-account.ps1 gsc user@example.com verification-token https://example.com/ META SITE
  .\gws-account.ps1 gsc user@example.com verification-token example.com DNS_TXT INET_DOMAIN
  .\gws-account.ps1 gsc user@example.com verify-site https://example.com/ META SITE
  .\gws-account.ps1 gsc user@example.com scopes

siteUrl can be a URL-prefix property like https://www.example.com/ or a Domain property like sc-domain:example.com.
'@ | Write-Host
}

function Invoke-SearchConsoleProfile {
    param(
        [AllowNull()][string]$Email,
        [string[]]$SearchArgs
    )

    if ($SearchArgs.Count -lt 1 -or $SearchArgs[0] -in @('help', '-h', '--help')) {
        Show-SearchConsoleUsage
        return
    }

    $normalized = Get-EmailOrActive -Email $Email
    $profilePath = Get-ProfilePath -Email $normalized
    if (-not (Test-Path -LiteralPath $profilePath)) {
        throw "Google Workspace CLI profile does not exist yet: $normalized. Run .\gws-account.ps1 login $normalized first."
    }

    $accessToken = Get-GoogleAccessTokenFromProfile -ProfilePath $profilePath
    $command = $SearchArgs[0].ToLowerInvariant()
    $rest = @()
    if ($SearchArgs.Count -gt 1) {
        $rest = @($SearchArgs[1..($SearchArgs.Count - 1)])
    }

    switch ($command) {
        'scopes' {
            $tokenInfoUri = 'https://www.googleapis.com/oauth2/v1/tokeninfo?access_token=' + [uri]::EscapeDataString($accessToken)
            ConvertTo-SearchConsoleJson (Invoke-RestMethod -Method Get -Uri $tokenInfoUri)
        }

        'sites' {
            ConvertTo-SearchConsoleJson (Invoke-GoogleApi -Method Get -Uri 'https://www.googleapis.com/webmasters/v3/sites' -AccessToken $accessToken -Body $null)
        }

        'add-site' {
            if ($rest.Count -lt 1) {
                throw 'Usage: .\gws-account.ps1 gsc [email] add-site <siteUrl>'
            }

            $siteUrl = [uri]::EscapeDataString($rest[0])
            Invoke-GoogleApi -Method Put -Uri "https://www.googleapis.com/webmasters/v3/sites/$siteUrl" -AccessToken $accessToken -Body $null | Out-Null
            ConvertTo-SearchConsoleJson ([ordered]@{ ok = $true; action = 'add-site'; siteUrl = $rest[0] })
        }

        'delete-site' {
            if ($rest.Count -lt 1) {
                throw 'Usage: .\gws-account.ps1 gsc [email] delete-site <siteUrl>'
            }

            $siteUrl = [uri]::EscapeDataString($rest[0])
            Invoke-GoogleApi -Method Delete -Uri "https://www.googleapis.com/webmasters/v3/sites/$siteUrl" -AccessToken $accessToken -Body $null | Out-Null
            ConvertTo-SearchConsoleJson ([ordered]@{ ok = $true; action = 'delete-site'; siteUrl = $rest[0] })
        }

        { $_ -in @('sitemaps', 'list-sitemaps') } {
            if ($rest.Count -lt 1) {
                throw 'Usage: .\gws-account.ps1 gsc [email] sitemaps <siteUrl>'
            }

            $siteUrl = [uri]::EscapeDataString($rest[0])
            ConvertTo-SearchConsoleJson (Invoke-GoogleApi -Method Get -Uri "https://www.googleapis.com/webmasters/v3/sites/$siteUrl/sitemaps" -AccessToken $accessToken -Body $null)
        }

        'submit-sitemap' {
            if ($rest.Count -lt 2) {
                throw 'Usage: .\gws-account.ps1 gsc [email] submit-sitemap <siteUrl> <sitemapUrl>'
            }

            $siteUrl = [uri]::EscapeDataString($rest[0])
            $sitemapUrl = [uri]::EscapeDataString($rest[1])
            Invoke-GoogleApi -Method Put -Uri "https://www.googleapis.com/webmasters/v3/sites/$siteUrl/sitemaps/$sitemapUrl" -AccessToken $accessToken -Body $null | Out-Null
            ConvertTo-SearchConsoleJson ([ordered]@{ ok = $true; action = 'submit-sitemap'; siteUrl = $rest[0]; sitemapUrl = $rest[1] })
        }

        'delete-sitemap' {
            if ($rest.Count -lt 2) {
                throw 'Usage: .\gws-account.ps1 gsc [email] delete-sitemap <siteUrl> <sitemapUrl>'
            }

            $siteUrl = [uri]::EscapeDataString($rest[0])
            $sitemapUrl = [uri]::EscapeDataString($rest[1])
            Invoke-GoogleApi -Method Delete -Uri "https://www.googleapis.com/webmasters/v3/sites/$siteUrl/sitemaps/$sitemapUrl" -AccessToken $accessToken -Body $null | Out-Null
            ConvertTo-SearchConsoleJson ([ordered]@{ ok = $true; action = 'delete-sitemap'; siteUrl = $rest[0]; sitemapUrl = $rest[1] })
        }

        'inspect-url' {
            if ($rest.Count -lt 2) {
                throw 'Usage: .\gws-account.ps1 gsc [email] inspect-url <inspectionUrl> <siteUrl> [languageCode]'
            }

            $body = [ordered]@{
                inspectionUrl = $rest[0]
                siteUrl = $rest[1]
            }
            if ($rest.Count -gt 2) {
                $body.languageCode = $rest[2]
            }

            ConvertTo-SearchConsoleJson (Invoke-GoogleApi -Method Post -Uri 'https://searchconsole.googleapis.com/v1/urlInspection/index:inspect' -AccessToken $accessToken -Body $body)
        }

        'analytics' {
            if ($rest.Count -lt 1) {
                throw 'Usage: .\gws-account.ps1 gsc [email] analytics <siteUrl> [days] [dimensionsCsv]'
            }

            $days = 28
            if ($rest.Count -gt 1 -and $rest[1] -match '^\d+$') {
                $days = [int]$rest[1]
            }

            $dimensions = @('query', 'page')
            if ($rest.Count -gt 2 -and -not [string]::IsNullOrWhiteSpace($rest[2])) {
                $dimensions = @($rest[2].Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            }

            $endDate = (Get-Date).AddDays(-2).ToString('yyyy-MM-dd')
            $startDate = (Get-Date).AddDays(-1 * ($days + 1)).ToString('yyyy-MM-dd')
            $siteUrl = [uri]::EscapeDataString($rest[0])
            $body = [ordered]@{
                startDate = $startDate
                endDate = $endDate
                dimensions = $dimensions
                rowLimit = 250
            }

            ConvertTo-SearchConsoleJson (Invoke-GoogleApi -Method Post -Uri "https://www.googleapis.com/webmasters/v3/sites/$siteUrl/searchAnalytics/query" -AccessToken $accessToken -Body $body)
        }

        'verification-token' {
            if ($rest.Count -lt 1) {
                throw 'Usage: .\gws-account.ps1 gsc [email] verification-token <identifier> [method] [type]'
            }

            $identifier = $rest[0]
            $method = if ($rest.Count -gt 1) { $rest[1].ToUpperInvariant() } elseif ($identifier -match '^https?://') { 'META' } else { 'DNS_TXT' }
            $siteType = if ($rest.Count -gt 2) { $rest[2].ToUpperInvariant() } elseif ($identifier -match '^https?://') { 'SITE' } else { 'INET_DOMAIN' }
            $body = [ordered]@{
                site = [ordered]@{
                    type = $siteType
                    identifier = $identifier
                }
                verificationMethod = $method
            }

            ConvertTo-SearchConsoleJson (Invoke-GoogleApi -Method Post -Uri 'https://www.googleapis.com/siteVerification/v1/token' -AccessToken $accessToken -Body $body)
        }

        'verify-site' {
            if ($rest.Count -lt 1) {
                throw 'Usage: .\gws-account.ps1 gsc [email] verify-site <identifier> [method] [type]'
            }

            $identifier = $rest[0]
            $method = if ($rest.Count -gt 1) { $rest[1].ToUpperInvariant() } elseif ($identifier -match '^https?://') { 'META' } else { 'DNS_TXT' }
            $siteType = if ($rest.Count -gt 2) { $rest[2].ToUpperInvariant() } elseif ($identifier -match '^https?://') { 'SITE' } else { 'INET_DOMAIN' }
            $body = [ordered]@{
                site = [ordered]@{
                    type = $siteType
                    identifier = $identifier
                }
            }

            $encodedMethod = [uri]::EscapeDataString($method)
            ConvertTo-SearchConsoleJson (Invoke-GoogleApi -Method Post -Uri "https://www.googleapis.com/siteVerification/v1/webResource?verificationMethod=$encodedMethod" -AccessToken $accessToken -Body $body)
        }

        default {
            Show-SearchConsoleUsage
            throw "Unknown Search Console command: $command"
        }
    }
}

function Move-ProfileDirectory {
    param(
        [string]$SourcePath,
        [string]$Email
    )

    $targetPath = Get-ProfilePath -Email $Email
    if ((Test-Path -LiteralPath $targetPath) -and ((Resolve-Path -LiteralPath $targetPath).Path -ne (Resolve-Path -LiteralPath $SourcePath).Path)) {
        $backupPath = "$targetPath.backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Move-Item -LiteralPath $targetPath -Destination $backupPath
        Write-Warning "Existing Google Workspace CLI profile was moved to: $backupPath"
    }

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $targetPath) | Out-Null
    if (-not (Test-Path -LiteralPath $targetPath)) {
        Move-Item -LiteralPath $SourcePath -Destination $targetPath
    }

    return $targetPath
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
    $metadataPath = Join-Path $profilePath 'profile.json'
    $active = Get-ActiveEmail

    [pscustomobject]@{
        Email = $normalized
        Exists = $exists
        IsActive = ($active -eq $normalized)
        HasMetadata = Test-Path -LiteralPath $metadataPath
        HasClientSecret = Test-Path -LiteralPath (Join-Path $profilePath 'client_secret.json')
        KeyringBackend = if ($exists) { Get-ProfileKeyringBackend -ProfilePath $profilePath } else { $null }
        ConfigDir = $profilePath
        State = if (-not $exists) { 'missing-profile' } elseif ($active -eq $normalized) { 'active' } else { 'configured' }
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

    { $_ -in @('login', 'add') } {
        $email = $null
        $loginArgs = @()
        if ($remaining.Count -gt 0 -and $remaining[0] -match '^[^\s@]+@[^\s@]+\.[^\s@]+$') {
            $email = Normalize-Email -Email $remaining[0]
            if ($remaining.Count -gt 1) {
                $loginArgs = @($remaining[1..($remaining.Count - 1)])
            }
        } elseif ($remaining.Count -gt 0) {
            $loginArgs = @($remaining)
        }

        # default to full scopes when no scope/service/full flag is given
        $hasScopeFlag = $loginArgs | Where-Object { $_ -match '^--(scopes|services|full)(=|$)' }
        if (-not $hasScopeFlag) {
            $loginArgs = @('--scopes', ($DefaultGwsLoginScopes -join ','))
        }

        if ($email) {
            $profilePath = Get-ProfilePath -Email $email
            Write-ProfileMetadata -Email $email -ProfilePath $profilePath
            Copy-DefaultClientConfig -ProfilePath $profilePath
            Write-Host "Opening Google Workspace CLI browser login for profile: $email"
            Write-Host 'Use that same email in the browser flow.'
        } else {
            $pendingRoot = Join-Path $env:TEMP 'mainframe-gws-login'
            New-Item -ItemType Directory -Force -Path $pendingRoot | Out-Null
            $profilePath = Join-Path $pendingRoot "pending-$([Guid]::NewGuid().ToString('N'))"
            New-Item -ItemType Directory -Force -Path $profilePath | Out-Null
            Copy-DefaultClientConfig -ProfilePath $profilePath
            Write-Host 'Opening Google Workspace CLI browser login. The email will be detected after auth.'
        }

        $gws = Get-GwsCommand
        Invoke-WithGwsProfile -ProfilePath $profilePath -KeyringBackend 'file' -Script {
            & $gws auth login @loginArgs
            if ($LASTEXITCODE -ne 0) {
                throw "gws auth login failed with exit code $LASTEXITCODE"
            }
        }

        if (-not $email) {
            $email = Resolve-LoggedInGwsEmail -ProfilePath $profilePath
            if (-not $email) {
                throw 'Login succeeded, but Google Workspace CLI email could not be detected automatically.'
            }

            $profilePath = Move-ProfileDirectory -SourcePath $profilePath -Email $email
        }

        Write-ProfileMetadata -Email $email -ProfilePath $profilePath
        Set-ActiveEmail -Email $email
        Write-Host "Google Workspace CLI profile is ready and active: $email"
    }

    'setup' {
        if ($remaining.Count -lt 1) {
            throw 'Usage: .\gws-account.ps1 setup <email> [gws auth setup args...]'
        }

        $email = Normalize-Email -Email $remaining[0]
        $setupArgs = @()
        if ($remaining.Count -gt 1) {
            $setupArgs = @($remaining[1..($remaining.Count - 1)])
        }

        $profilePath = Get-ProfilePath -Email $email
        Write-ProfileMetadata -Email $email -ProfilePath $profilePath
        $gws = Get-GwsCommand
        Invoke-WithGwsProfile -ProfilePath $profilePath -KeyringBackend 'file' -Script {
            & $gws auth setup @setupArgs
            if ($LASTEXITCODE -ne 0) {
                throw "gws auth setup failed with exit code $LASTEXITCODE"
            }
        }
        Write-ProfileMetadata -Email $email -ProfilePath $profilePath
        Set-ActiveEmail -Email $email
        Write-Host "Google Workspace CLI profile setup is ready and active: $email"
    }

    'use' {
        if ($remaining.Count -lt 1) {
            throw 'Usage: .\gws-account.ps1 use <email>'
        }

        $email = Normalize-Email -Email $remaining[0]
        $profilePath = Get-ProfilePath -Email $email
        if (-not (Test-Path -LiteralPath $profilePath)) {
            throw "Google Workspace CLI profile does not exist yet: $email"
        }

        Set-ActiveEmail -Email $email
        Write-Host "Active Google Workspace CLI profile: $email"
    }

    'run' {
        if ($remaining.Count -lt 1) {
            throw 'Usage: .\gws-account.ps1 run [email] <gws args...>'
        }

        if (Test-LooksLikeEmail -Value $remaining[0]) {
            if ($remaining.Count -lt 2) {
                throw 'Usage: .\gws-account.ps1 run [email] <gws args...>'
            }

            $email = Normalize-Email -Email $remaining[0]
            $gwsArgs = @($remaining[1..($remaining.Count - 1)])
        } else {
            $email = Get-EmailOrActive -Email $null
            $gwsArgs = @($remaining)
        }

        Invoke-GwsProfile -Email $email -GwsArgs $gwsArgs
    }

    { $_ -in @('gsc', 'search-console') } {
        $email = $null
        $searchArgs = @($remaining)
        if ($remaining.Count -gt 0 -and $remaining[0] -match '^[^\s@]+@[^\s@]+\.[^\s@]+$') {
            $email = Normalize-Email -Email $remaining[0]
            $searchArgs = @()
            if ($remaining.Count -gt 1) {
                $searchArgs = @($remaining[1..($remaining.Count - 1)])
            }
        }

        Invoke-SearchConsoleProfile -Email $email -SearchArgs $searchArgs
    }

    'status' {
        $email = Get-EmailOrActive -Email $(if ($remaining.Count -gt 0) { $remaining[0] } else { $null })
        Invoke-GwsProfile -Email $email -GwsArgs @('auth', 'status')
    }

    'status-all' {
        if (-not (Test-Path -LiteralPath $accountRoot)) {
            Write-Host 'No Google Workspace CLI profiles found.'
            return
        }

        $profiles = @(Get-ChildItem -LiteralPath $accountRoot -Directory -Force | Where-Object { $_.Name -match '^[^\s@]+@[^\s@]+\.[^\s@]+$' } | Sort-Object Name)
        if ($profiles.Count -eq 0) {
            Write-Host 'No Google Workspace CLI profiles found.'
            return
        }

        $profiles |
            ForEach-Object { Get-ProfileStatus -Email (Get-ProfileEmail -Directory $_) } |
            Format-Table -AutoSize
    }

    'whoami' {
        $email = Get-EmailOrActive -Email $(if ($remaining.Count -gt 0) { $remaining[0] } else { $null })
        Invoke-GwsProfile -Email $email -GwsArgs @('auth', 'status')
    }

    'logout' {
        $email = Get-EmailOrActive -Email $(if ($remaining.Count -gt 0) { $remaining[0] } else { $null })
        Invoke-GwsProfile -Email $email -GwsArgs @('auth', 'logout')
    }

    'current' {
        $active = Get-ActiveEmail
        if ($active) {
            Write-Host $active
        } else {
            Write-Host 'No active Google Workspace CLI profile set.'
        }
    }

    'path' {
        $email = Get-EmailOrActive -Email $(if ($remaining.Count -gt 0) { $remaining[0] } else { $null })
        Write-Host (Get-ProfilePath -Email $email)
    }

    'env' {
        $email = Get-EmailOrActive -Email $(if ($remaining.Count -gt 0) { $remaining[0] } else { $null })
        $profilePath = Get-ProfilePath -Email $email
        $keyringBackend = 'file'
        if (Test-Path -LiteralPath $profilePath) {
            $keyringBackend = Get-ProfileKeyringBackend -ProfilePath $profilePath
        }
        Write-Host "`$env:GOOGLE_WORKSPACE_CLI_CONFIG_DIR = '$profilePath'"
        Write-Host "`$env:GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND = '$keyringBackend'"
    }

    'list' {
        if (-not (Test-Path -LiteralPath $accountRoot)) {
            Write-Host 'No Google Workspace CLI profiles found.'
            return
        }

        $active = Get-ActiveEmail
        $profiles = @(Get-ChildItem -LiteralPath $accountRoot -Directory -Force | Where-Object { $_.Name -match '^[^\s@]+@[^\s@]+\.[^\s@]+$' } | Sort-Object Name)
        if ($profiles.Count -eq 0) {
            Write-Host 'No Google Workspace CLI profiles found.'
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
