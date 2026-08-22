$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'vault-secret.psm1') -Force

$accountRoot = Join-Path $env:APPDATA 'mainframe\accounts\notion'
$currentFile = Join-Path $accountRoot 'current.json'
$apiEndpoint = 'https://api.notion.com'
$apiVersion = '2026-03-11'

function Show-Usage {
    @(
        'Notion account profile helper',
        '',
        'Profiles are keyed by account email only and stored in:',
        '  %APPDATA%\mainframe\accounts\notion\<email>',
        '',
        'Notion API profiles use a personal access token or integration token.',
        'The token is passed as NOTION_API_TOKEN for ntn and as a Bearer token',
        'for direct API calls. Notion CLI config is isolated with NOTION_HOME.',
        '',
        'Usage:',
        '  .\notion-account.ps1 login <email> [ntn login args...]',
        '  .\notion-account.ps1 token-add [email] [workspace-id]',
        '  .\notion-account.ps1 import-current [email] [workspace-id]',
        '  .\notion-account.ps1 token-clear [email]',
        '  .\notion-account.ps1 use <email>',
        '  .\notion-account.ps1 run [email] <ntn args...>',
        '  .\notion-account.ps1 api <email> <GET|POST|PATCH|DELETE> <api path> [json body]',
        '  .\notion-account.ps1 me [email]',
        '  .\notion-account.ps1 users [email]',
        '  .\notion-account.ps1 search [email] [json body]',
        '  .\notion-account.ps1 page <email> <page-id>',
        '  .\notion-account.ps1 blocks <email> <block-id>',
        '  .\notion-account.ps1 status [email]',
        '  .\notion-account.ps1 status-all',
        '  .\notion-account.ps1 list',
        '  .\notion-account.ps1 current',
        '  .\notion-account.ps1 path [email]',
        '  .\notion-account.ps1 env [email]',
        '  .\notion-account.ps1 logout [email]',
        '',
        'Examples:',
        '  .\notion-account.ps1 import-current',
        '  .\notion-account.ps1 token-add',
        '  .\notion-account.ps1 me user@example.com',
        '  .\notion-account.ps1 users user@example.com',
        '  .\notion-account.ps1 search user@example.com ''{"page_size":10}''',
        '  .\notion-account.ps1 run user@example.com api v1/users/me',
        '  .\notion-account.ps1 run api v1/users/me',
        '  .\notion-account.ps1 api user@example.com GET /users/me'
    ) -join [Environment]::NewLine | Write-Host
}

function Normalize-ProfileName {
    param([string]$Profile)

    if ([string]::IsNullOrWhiteSpace($Profile)) {
        throw 'Email profile is required.'
    }

    $normalized = $Profile.Trim().ToLowerInvariant()
    if ($normalized -notmatch '^[^\s@]+@[^\s@]+\.[^\s@]+$') {
        throw "Notion profile must be an account email, not a label, workspace name, or username: $Profile"
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

function Get-WorkspaceIdPath {
    param([string]$ProfilePath)

    return Join-Path $ProfilePath 'workspace-id.txt'
}

function Get-NtnCommand {
    $cmd = Get-Command ntn -ErrorAction SilentlyContinue
    if (-not $cmd) {
        throw 'Notion CLI was not found. Install it with Node.js 22+ using: npm install --global ntn'
    }

    $output = @(& $cmd.Source --version 2>&1)
    if ($LASTEXITCODE -eq 0) {
        return $cmd.Source
    }

    $message = ($output -join ' ').Trim()
    throw "Notion CLI is installed but is not usable here: $message"
}

function Get-NtnStatus {
    $cmd = Get-Command ntn -ErrorAction SilentlyContinue
    if (-not $cmd) {
        return 'missing'
    }

    $output = @(& $cmd.Source --version 2>&1)
    if ($LASTEXITCODE -eq 0) {
        return 'available'
    }

    return 'unsupported'
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

function ConvertTo-JsonOutput {
    param([AllowNull()]$Value)

    if ($null -eq $Value) {
        Write-Host '{}'
        return
    }

    $Value | ConvertTo-Json -Depth 64
}

function Write-ProfileMetadata {
    param(
        [string]$Profile,
        [string]$ProfilePath,
        [AllowNull()][string]$WorkspaceId,
        [AllowNull()]$Identity
    )

    $actorName = $null
    $actorType = $null
    $workspaceName = $null
    $resolvedWorkspaceId = $WorkspaceId
    if ($Identity) {
        if ($Identity.name) {
            $actorName = [string]$Identity.name
        } elseif ($Identity.bot -and $Identity.bot.owner -and $Identity.bot.owner.user -and $Identity.bot.owner.user.name) {
            $actorName = [string]$Identity.bot.owner.user.name
        }

        if ($Identity.type) {
            $actorType = [string]$Identity.type
        } elseif ($Identity.object) {
            $actorType = [string]$Identity.object
        }

        if ($Identity.bot -and $Identity.bot.workspace_name) {
            $workspaceName = [string]$Identity.bot.workspace_name
        }

        if ([string]::IsNullOrWhiteSpace($resolvedWorkspaceId) -and $Identity.bot -and $Identity.bot.workspace_id) {
            $resolvedWorkspaceId = [string]$Identity.bot.workspace_id
        }
    }

    New-Item -ItemType Directory -Force -Path $ProfilePath | Out-Null
    [ordered]@{
        tool = 'notion'
        service = 'notion.so'
        profile = $Profile
        workspaceId = $resolvedWorkspaceId
        workspaceName = $workspaceName
        actorName = $actorName
        actorType = $actorType
        notionHome = $ProfilePath
        apiEndpoint = $apiEndpoint
        apiVersion = $apiVersion
        tokenPath = (Get-TokenPath -ProfilePath $ProfilePath)
        updatedAt = (Get-Date).ToString('o')
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $ProfilePath 'profile.json') -Encoding UTF8
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
        tool = 'notion'
        service = 'notion.so'
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
        throw 'No email was provided and no active Notion email profile is set. Run .\notion-account.ps1 use <email>.'
    }

    return Normalize-ProfileName -Profile $active
}

function Read-ProfileWorkspaceId {
    param([string]$Profile)

    $normalized = Normalize-ProfileName -Profile $Profile
    $profilePath = Get-ProfilePath -Profile $normalized
    $workspaceIdPath = Get-WorkspaceIdPath -ProfilePath $profilePath
    if (Test-Path -LiteralPath $workspaceIdPath) {
        $workspaceId = (Get-Content -LiteralPath $workspaceIdPath -Raw).Trim()
        if (-not [string]::IsNullOrWhiteSpace($workspaceId)) {
            return $workspaceId
        }
    }

    $metadata = Read-ProfileMetadata -ProfilePath $profilePath
    if ($metadata -and $metadata.workspaceId) {
        return [string]$metadata.workspaceId
    }

    return $null
}

function Write-ProfileTokenValue {
    param(
        [string]$Profile,
        [string]$Token,
        [AllowNull()][string]$WorkspaceId,
        [AllowNull()]$Identity
    )

    if ([string]::IsNullOrWhiteSpace($Token)) {
        throw 'Notion API token is empty.'
    }

    $normalized = Normalize-ProfileName -Profile $Profile
    $profilePath = Get-ProfilePath -Profile $normalized
    New-Item -ItemType Directory -Force -Path $profilePath | Out-Null
    Write-VaultSecretToExisting -Email $normalized -NamePattern 'www.notion.so' -Header '[token]' -Value $Token.Trim() -ItemName 'www.notion.so' -Username $normalized -Uri 'https://www.notion.so/my-integrations'
    if (-not [string]::IsNullOrWhiteSpace($WorkspaceId)) {
        $WorkspaceId.Trim() | Set-Content -LiteralPath (Get-WorkspaceIdPath -ProfilePath $profilePath) -NoNewline -Encoding UTF8
    }

    Write-ProfileMetadata -Profile $normalized -ProfilePath $profilePath -WorkspaceId $WorkspaceId -Identity $Identity
    Set-ActiveProfile -Profile $normalized
}

function Read-ProfileToken {
    param([string]$Profile)

    $normalized = Normalize-ProfileName -Profile $Profile
    return Read-VaultSecret -Email $normalized -NamePattern 'www.notion.so' -ValueRegex '(ntn_|secret_)[A-Za-z0-9]+'
}

function Invoke-WithNotionProfile {
    param(
        [string]$Profile,
        [scriptblock]$Script
    )

    $normalized = Normalize-ProfileName -Profile $Profile
    $profilePath = Get-ProfilePath -Profile $normalized
    New-Item -ItemType Directory -Force -Path $profilePath | Out-Null
    $token = Read-ProfileToken -Profile $normalized
    $workspaceId = Read-ProfileWorkspaceId -Profile $normalized

    $oldNotionHome = $env:NOTION_HOME
    $oldApiToken = $env:NOTION_API_TOKEN
    $oldNotionToken = $env:NOTION_TOKEN
    $oldAccessToken = $env:NOTION_ACCESS_TOKEN
    $oldApiVersion = $env:NOTION_API_VERSION
    $oldWorkspaceId = $env:NOTION_WORKSPACE_ID

    try {
        $env:NOTION_HOME = $profilePath
        $env:NOTION_API_VERSION = $apiVersion
        if ([string]::IsNullOrWhiteSpace($workspaceId)) {
            Remove-Item Env:\NOTION_WORKSPACE_ID -ErrorAction SilentlyContinue
        } else {
            $env:NOTION_WORKSPACE_ID = $workspaceId
        }

        if ([string]::IsNullOrWhiteSpace($token)) {
            Remove-Item Env:\NOTION_API_TOKEN -ErrorAction SilentlyContinue
            Remove-Item Env:\NOTION_TOKEN -ErrorAction SilentlyContinue
            Remove-Item Env:\NOTION_ACCESS_TOKEN -ErrorAction SilentlyContinue
        } else {
            $env:NOTION_API_TOKEN = $token
            $env:NOTION_TOKEN = $token
            $env:NOTION_ACCESS_TOKEN = $token
        }

        & $Script
    } finally {
        if ([string]::IsNullOrWhiteSpace($oldNotionHome)) {
            Remove-Item Env:\NOTION_HOME -ErrorAction SilentlyContinue
        } else {
            $env:NOTION_HOME = $oldNotionHome
        }

        if ([string]::IsNullOrWhiteSpace($oldApiToken)) {
            Remove-Item Env:\NOTION_API_TOKEN -ErrorAction SilentlyContinue
        } else {
            $env:NOTION_API_TOKEN = $oldApiToken
        }

        if ([string]::IsNullOrWhiteSpace($oldNotionToken)) {
            Remove-Item Env:\NOTION_TOKEN -ErrorAction SilentlyContinue
        } else {
            $env:NOTION_TOKEN = $oldNotionToken
        }

        if ([string]::IsNullOrWhiteSpace($oldAccessToken)) {
            Remove-Item Env:\NOTION_ACCESS_TOKEN -ErrorAction SilentlyContinue
        } else {
            $env:NOTION_ACCESS_TOKEN = $oldAccessToken
        }

        if ([string]::IsNullOrWhiteSpace($oldApiVersion)) {
            Remove-Item Env:\NOTION_API_VERSION -ErrorAction SilentlyContinue
        } else {
            $env:NOTION_API_VERSION = $oldApiVersion
        }

        if ([string]::IsNullOrWhiteSpace($oldWorkspaceId)) {
            Remove-Item Env:\NOTION_WORKSPACE_ID -ErrorAction SilentlyContinue
        } else {
            $env:NOTION_WORKSPACE_ID = $oldWorkspaceId
        }
    }
}

function Invoke-NtnProfile {
    param(
        [string]$Profile,
        [string[]]$NtnArgs
    )

    $normalized = Normalize-ProfileName -Profile $Profile
    $profilePath = Get-ProfilePath -Profile $normalized
    if (-not (Test-Path -LiteralPath $profilePath)) {
        throw "Notion profile does not exist yet: $normalized. Run .\notion-account.ps1 import-current $normalized or .\notion-account.ps1 token-add $normalized first."
    }

    $ntn = Get-NtnCommand
    Invoke-WithNotionProfile -Profile $normalized -Script {
        & $ntn @NtnArgs
        if ($LASTEXITCODE -ne 0) {
            throw "ntn $($NtnArgs -join ' ') failed with exit code $LASTEXITCODE"
        }
    }
}

function Get-ApiPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw 'API path is required.'
    }

    $trimmed = $Path.Trim()
    if ($trimmed -match '^https?://') {
        $uri = [uri]$trimmed
        if ($uri.Host -ne 'api.notion.com') {
            throw 'Only https://api.notion.com URLs are allowed.'
        }

        return $uri.PathAndQuery
    }

    if ($trimmed -match '^/?v1/') {
        return "/$($trimmed.TrimStart('/'))"
    }

    if ($trimmed.StartsWith('/')) {
        return "/v1$trimmed"
    }

    return "/v1/$trimmed"
}

function Invoke-NotionApi {
    param(
        [string]$Profile,
        [string]$Method,
        [string]$Path,
        [AllowNull()][string]$JsonBody
    )

    $normalized = Normalize-ProfileName -Profile $Profile
    $token = Read-ProfileToken -Profile $normalized
    if ([string]::IsNullOrWhiteSpace($token)) {
        throw "Notion token profile is missing for $normalized. Use import-current or token-add first."
    }

    $apiPath = Get-ApiPath -Path $Path
    $uri = "$apiEndpoint$apiPath"
    $headers = @{
        Authorization = "Bearer $token"
        'Notion-Version' = $apiVersion
        Accept = 'application/json'
        'User-Agent' = 'mainframe-notion-account'
    }

    $methodUpper = $Method.ToUpperInvariant()
    if ($methodUpper -notin @('GET', 'POST', 'PATCH', 'DELETE')) {
        throw 'Method must be one of: GET, POST, PATCH, DELETE.'
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
            throw "Notion API $methodUpper $apiPath failed: HTTP $statusCode $statusDescription"
        }

        throw "Notion API $methodUpper $apiPath failed: $($_.Exception.Message)"
    }
}

function Invoke-NotionListUsers {
    param([string]$Profile)

    $items = New-Object System.Collections.Generic.List[object]
    $cursor = $null
    do {
        $path = '/users?page_size=100'
        if (-not [string]::IsNullOrWhiteSpace($cursor)) {
            $path = "$path&start_cursor=$([uri]::EscapeDataString($cursor))"
        }

        $page = Invoke-NotionApi -Profile $Profile -Method GET -Path $path -JsonBody $null
        foreach ($item in @($page.results)) {
            $items.Add($item)
        }

        $cursor = if ($page.has_more) { [string]$page.next_cursor } else { $null }
    } while (-not [string]::IsNullOrWhiteSpace($cursor))

    return $items.ToArray()
}

function Invoke-NotionSearchAll {
    param(
        [string]$Profile,
        [AllowNull()][string]$JsonBody
    )

    $body = if ([string]::IsNullOrWhiteSpace($JsonBody)) {
        [pscustomobject]@{}
    } else {
        $JsonBody | ConvertFrom-Json
    }

    if ($body -is [array]) {
        throw 'Search body must be a JSON object.'
    }

    if (-not ($body.PSObject.Properties.Name -contains 'page_size')) {
        $body | Add-Member -NotePropertyName page_size -NotePropertyValue 100 -Force
    }

    $items = New-Object System.Collections.Generic.List[object]
    $cursor = $null
    do {
        if ([string]::IsNullOrWhiteSpace($cursor)) {
            if ($body.PSObject.Properties.Name -contains 'start_cursor') {
                $body.PSObject.Properties.Remove('start_cursor')
            }
        } else {
            $body | Add-Member -NotePropertyName start_cursor -NotePropertyValue $cursor -Force
        }

        $page = Invoke-NotionApi -Profile $Profile -Method POST -Path '/search' -JsonBody ($body | ConvertTo-Json -Depth 32)
        foreach ($item in @($page.results)) {
            $items.Add($item)
        }

        $cursor = if ($page.has_more) { [string]$page.next_cursor } else { $null }
    } while (-not [string]::IsNullOrWhiteSpace($cursor))

    return $items.ToArray()
}

function Get-NotionObjectTitle {
    param([AllowNull()]$Object)

    if (-not $Object) {
        return $null
    }

    if ($Object.title) {
        $parts = @($Object.title | ForEach-Object {
            if ($_.plain_text) { [string]$_.plain_text }
        })
        $title = ($parts -join '').Trim()
        if ($title) {
            return $title
        }
    }

    if ($Object.properties) {
        foreach ($prop in @($Object.properties.PSObject.Properties)) {
            $value = $prop.Value
            if ($value -and $value.type -eq 'title' -and $value.title) {
                $parts = @($value.title | ForEach-Object {
                    if ($_.plain_text) { [string]$_.plain_text }
                })
                $title = ($parts -join '').Trim()
                if ($title) {
                    return $title
                }
            }
        }
    }

    return $null
}

function Resolve-NotionIdentity {
    param([string]$Profile)

    try {
        return Invoke-NotionApi -Profile $Profile -Method GET -Path '/users/me' -JsonBody $null
    } catch {
        return $null
    }
}

function Resolve-NotionIdentityFromToken {
    param([string]$Token)

    if ([string]::IsNullOrWhiteSpace($Token)) {
        return $null
    }

    try {
        return Invoke-RestMethod -Method GET -Uri "$apiEndpoint/v1/users/me" -Headers @{
            Authorization = "Bearer $($Token.Trim())"
            'Notion-Version' = $apiVersion
            Accept = 'application/json'
            'User-Agent' = 'mainframe-notion-account'
        } -ContentType 'application/json'
    } catch {
        return $null
    }
}

function Resolve-NotionEmailFromIdentity {
    param([AllowNull()]$Identity)

    if (-not $Identity) {
        return $null
    }

    $candidates = @(
        $Identity.email,
        $Identity.person.email,
        $Identity.bot.owner.user.email,
        $Identity.bot.owner.user.person.email,
        $Identity.bot.owner.user.name
    )

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

function Resolve-OptionalProfileArgs {
    param(
        [object[]]$Arguments,
        [string]$Usage
    )

    $profile = $null
    $workspaceId = $null

    if ($Arguments.Count -gt 2) {
        throw $Usage
    }

    if ($Arguments.Count -ge 1) {
        $first = [string]$Arguments[0]
        if ($first -match '^[^\s@]+@[^\s@]+\.[^\s@]+$') {
            $profile = Normalize-ProfileName -Profile $first
            if ($Arguments.Count -eq 2) {
                $workspaceId = [string]$Arguments[1]
            }
        } else {
            if ($Arguments.Count -eq 2) {
                throw $Usage
            }
            $workspaceId = $first
        }
    }

    return [pscustomobject]@{
        Profile = $profile
        WorkspaceId = $workspaceId
    }
}

function Resolve-ProfileFromIdentity {
    param(
        [AllowNull()][string]$Profile,
        [AllowNull()]$Identity,
        [string]$FallbackCommand
    )

    if (-not [string]::IsNullOrWhiteSpace($Profile)) {
        return Normalize-ProfileName -Profile $Profile
    }

    $detected = Resolve-NotionEmailFromIdentity -Identity $Identity
    if (-not [string]::IsNullOrWhiteSpace($detected)) {
        return $detected
    }

    throw "Could not detect an account email from Notion /users/me. No token was saved. Run $FallbackCommand with the email explicitly."
}

function Import-CurrentToken {
    param(
        [AllowNull()][string]$Profile,
        [AllowNull()][string]$WorkspaceId
    )

    $token = $null
    $source = $null
    if (-not [string]::IsNullOrWhiteSpace($env:NOTION_API_TOKEN)) {
        $token = $env:NOTION_API_TOKEN.Trim()
        $source = 'NOTION_API_TOKEN environment variable'
    } elseif (-not [string]::IsNullOrWhiteSpace($env:NOTION_ACCESS_TOKEN)) {
        $token = $env:NOTION_ACCESS_TOKEN.Trim()
        $source = 'NOTION_ACCESS_TOKEN environment variable'
    } elseif (-not [string]::IsNullOrWhiteSpace($env:NOTION_TOKEN)) {
        $token = $env:NOTION_TOKEN.Trim()
        $source = 'NOTION_TOKEN environment variable'
    }

    if ([string]::IsNullOrWhiteSpace($token)) {
        throw 'No current Notion token was found in NOTION_API_TOKEN, NOTION_ACCESS_TOKEN, or NOTION_TOKEN.'
    }

    $identity = Resolve-NotionIdentityFromToken -Token $token
    $normalized = Resolve-ProfileFromIdentity -Profile $Profile -Identity $identity -FallbackCommand '.\notion-account.ps1 import-current <email>'

    Write-ProfileTokenValue -Profile $normalized -Token $token -WorkspaceId $WorkspaceId -Identity $identity
    if (-not $identity) {
        $identity = Resolve-NotionIdentity -Profile $normalized
    }
    Write-ProfileMetadata -Profile $normalized -ProfilePath (Get-ProfilePath -Profile $normalized) -WorkspaceId $WorkspaceId -Identity $identity
    Write-Host "Imported current Notion token into profile: $normalized"
    Write-Host "Source: $source"
}

function Get-ProfileStatus {
    param([string]$Profile)

    $normalized = Normalize-ProfileName -Profile $Profile
    $profilePath = Get-ProfilePath -Profile $normalized
    $metadata = Read-ProfileMetadata -ProfilePath $profilePath
    $hasToken = -not [string]::IsNullOrWhiteSpace((Read-ProfileToken -Profile $normalized))
    $exists = Test-Path -LiteralPath $profilePath
    $active = Get-ActiveProfile

    [pscustomobject]@{
        Profile = $normalized
        WorkspaceId = if ($metadata -and $metadata.workspaceId) { [string]$metadata.workspaceId } else { $null }
        WorkspaceName = if ($metadata -and $metadata.workspaceName) { [string]$metadata.workspaceName } else { $null }
        ActorName = if ($metadata -and $metadata.actorName) { [string]$metadata.actorName } else { $null }
        ActorType = if ($metadata -and $metadata.actorType) { [string]$metadata.actorType } else { $null }
        Exists = $exists
        IsActive = ($active -eq $normalized)
        HasToken = $hasToken
        TokenStatus = if ($hasToken) { 'present' } else { 'missing' }
        NotionHome = $profilePath
        ApiVersion = $apiVersion
        NtnStatus = Get-NtnStatus
        State = if (-not $exists) { 'missing-profile' } elseif (-not $hasToken) { 'missing-token' } elseif ($active -eq $normalized) { 'active' } else { 'configured' }
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
    $tokenPath = Get-TokenPath -ProfilePath $profilePath
    if (Test-Path -LiteralPath $tokenPath) {
        Remove-Item -LiteralPath $tokenPath -Force
        Write-Host "Removed saved Notion token profile for: $normalized"
    } else {
        Write-Host "No saved Notion token profile found for: $normalized"
    }
}

function Remove-Profile {
    param([string]$Profile)

    $normalized = Normalize-ProfileName -Profile $Profile
    $profilePath = Get-ProfilePath -Profile $normalized
    if (-not (Test-Path -LiteralPath $profilePath)) {
        Write-Host "Notion profile does not exist: $normalized"
        return
    }

    $backupPath = "$profilePath.logged-out-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Move-Item -LiteralPath $profilePath -Destination $backupPath
    Write-Host "Notion profile moved to: $backupPath"

    $active = Get-ActiveProfile
    if ($active -eq $normalized -and (Test-Path -LiteralPath $currentFile)) {
        Remove-Item -LiteralPath $currentFile
        Write-Host 'Active Notion profile cleared.'
    }

    Write-Warning 'If this profile was created with ntn login and OS keychain auth, run ntn logout separately when you want to clear the keychain session.'
}

$command = if ($args.Count -gt 0) { $args[0].ToLowerInvariant() } else { 'help' }
$remaining = @($args | Select-Object -Skip 1)

switch ($command) {
    'help' {
        Show-Usage
    }

    'login' {
        $profile = $null
        $loginArgs = @()
        if ($remaining.Count -gt 0 -and $remaining[0] -notlike '-*') {
            $profile = Normalize-ProfileName -Profile $remaining[0]
            $loginArgs = @($remaining | Select-Object -Skip 1)
        } else {
            throw 'Usage: .\notion-account.ps1 login <email> [ntn login args...]'
        }

        $ntn = Get-NtnCommand
        $profilePath = Get-ProfilePath -Profile $profile
        New-Item -ItemType Directory -Force -Path $profilePath | Out-Null
        $displayProfile = $profile
        Write-Host "Starting Notion CLI login for profile: $displayProfile"

        $oldNotionHome = $env:NOTION_HOME
        $oldApiToken = $env:NOTION_API_TOKEN
        $oldNotionToken = $env:NOTION_TOKEN
        $oldAccessToken = $env:NOTION_ACCESS_TOKEN
        try {
            $env:NOTION_HOME = $profilePath
            Remove-Item Env:\NOTION_API_TOKEN -ErrorAction SilentlyContinue
            Remove-Item Env:\NOTION_TOKEN -ErrorAction SilentlyContinue
            Remove-Item Env:\NOTION_ACCESS_TOKEN -ErrorAction SilentlyContinue
            & $ntn login @loginArgs
            if ($LASTEXITCODE -ne 0) {
                throw "ntn login failed with exit code $LASTEXITCODE"
            }
        } finally {
            if ([string]::IsNullOrWhiteSpace($oldNotionHome)) { Remove-Item Env:\NOTION_HOME -ErrorAction SilentlyContinue } else { $env:NOTION_HOME = $oldNotionHome }
            if ([string]::IsNullOrWhiteSpace($oldApiToken)) { Remove-Item Env:\NOTION_API_TOKEN -ErrorAction SilentlyContinue } else { $env:NOTION_API_TOKEN = $oldApiToken }
            if ([string]::IsNullOrWhiteSpace($oldNotionToken)) { Remove-Item Env:\NOTION_TOKEN -ErrorAction SilentlyContinue } else { $env:NOTION_TOKEN = $oldNotionToken }
            if ([string]::IsNullOrWhiteSpace($oldAccessToken)) { Remove-Item Env:\NOTION_ACCESS_TOKEN -ErrorAction SilentlyContinue } else { $env:NOTION_ACCESS_TOKEN = $oldAccessToken }
        }

        Write-ProfileMetadata -Profile $profile -ProfilePath $profilePath -WorkspaceId $null -Identity $null
        Set-ActiveProfile -Profile $profile
        Write-Host "Notion CLI profile config is ready and active: $profile"
        Write-Warning 'For portable backup/restore, use import-current or token-add so token.txt is included in encrypted mainframe secrets.'
    }

    { $_ -in @('token-add', 'add', 'token-add-auto', 'add-auto') } {
        $parsedArgs = Resolve-OptionalProfileArgs -Arguments $remaining -Usage 'Usage: .\notion-account.ps1 token-add [email] [workspace-id]'
        $target = if ($parsedArgs.Profile) { $parsedArgs.Profile } else { 'auto-detected account email' }
        Write-Host "Paste a Notion API token for $target. Input is hidden; it will be saved as token.txt for symmetric mainframe backup/restore."

        $token = Read-Host 'Notion token' -AsSecureString
        $plainToken = Convert-SecureStringToPlainText -SecureString $token
        $identity = Resolve-NotionIdentityFromToken -Token $plainToken
        $profile = Resolve-ProfileFromIdentity -Profile $parsedArgs.Profile -Identity $identity -FallbackCommand '.\notion-account.ps1 token-add <email>'

        Write-ProfileTokenValue -Profile $profile -Token $plainToken -WorkspaceId $parsedArgs.WorkspaceId -Identity $identity
        if (-not $identity) {
            $identity = Resolve-NotionIdentity -Profile $profile
        }

        Write-ProfileMetadata -Profile $profile -ProfilePath (Get-ProfilePath -Profile $profile) -WorkspaceId $parsedArgs.WorkspaceId -Identity $identity
        Write-Host "Notion token profile is ready and active: $profile"
    }

    'import-current' {
        $parsedArgs = Resolve-OptionalProfileArgs -Arguments $remaining -Usage 'Usage: .\notion-account.ps1 import-current [email] [workspace-id]'
        Import-CurrentToken -Profile $parsedArgs.Profile -WorkspaceId $parsedArgs.WorkspaceId
    }

    'token-clear' {
        $profile = Get-ProfileOrActive -Profile $(if ($remaining.Count -ge 1) { $remaining[0] } else { $null })
        Remove-ProfileToken -Profile $profile
    }

    'use' {
        if ($remaining.Count -ne 1) {
            throw 'Usage: .\notion-account.ps1 use <email>'
        }

        $profile = Normalize-ProfileName -Profile $remaining[0]
        $profilePath = Get-ProfilePath -Profile $profile
        if (-not (Test-Path -LiteralPath $profilePath)) {
            throw "Notion profile does not exist yet: $profile"
        }

        Set-ActiveProfile -Profile $profile
        Write-Host "Active Notion profile: $profile"
    }

    'run' {
        if ($remaining.Count -lt 1) {
            throw 'Usage: .\notion-account.ps1 run [email] <ntn args...>'
        }

        if (Test-LooksLikeEmail -Value $remaining[0]) {
            if ($remaining.Count -lt 2) {
                throw 'Usage: .\notion-account.ps1 run [email] <ntn args...>'
            }

            $profile = Normalize-ProfileName -Profile $remaining[0]
            $ntnArgs = @($remaining | Select-Object -Skip 1)
        } else {
            $profile = Get-ProfileOrActive -Profile $null
            $ntnArgs = @($remaining)
        }

        Invoke-NtnProfile -Profile $profile -NtnArgs $ntnArgs
    }

    'api' {
        if ($remaining.Count -lt 3) {
            throw 'Usage: .\notion-account.ps1 api <email> <GET|POST|PATCH|DELETE> <api path> [json body]'
        }

        $profile = Normalize-ProfileName -Profile $remaining[0]
        $method = $remaining[1]
        $path = $remaining[2]
        $body = if ($remaining.Count -gt 3) { ($remaining[3..($remaining.Count - 1)] -join ' ') } else { $null }
        ConvertTo-JsonOutput -Value (Invoke-NotionApi -Profile $profile -Method $method -Path $path -JsonBody $body)
    }

    'me' {
        $profile = Get-ProfileOrActive -Profile $(if ($remaining.Count -ge 1) { $remaining[0] } else { $null })
        ConvertTo-JsonOutput -Value (Invoke-NotionApi -Profile $profile -Method GET -Path '/users/me' -JsonBody $null)
    }

    'users' {
        $profile = Get-ProfileOrActive -Profile $(if ($remaining.Count -ge 1) { $remaining[0] } else { $null })
        ConvertTo-JsonOutput -Value (Invoke-NotionListUsers -Profile $profile)
    }

    'search' {
        $profile = Get-ProfileOrActive -Profile $(if ($remaining.Count -ge 1) { $remaining[0] } else { $null })
        $body = if ($remaining.Count -gt 1) { ($remaining[1..($remaining.Count - 1)] -join ' ') } else { $null }
        ConvertTo-JsonOutput -Value (Invoke-NotionSearchAll -Profile $profile -JsonBody $body)
    }

    'page' {
        if ($remaining.Count -ne 2) {
            throw 'Usage: .\notion-account.ps1 page <email> <page-id>'
        }

        $profile = Normalize-ProfileName -Profile $remaining[0]
        $pageId = $remaining[1]
        ConvertTo-JsonOutput -Value (Invoke-NotionApi -Profile $profile -Method GET -Path "/pages/$pageId" -JsonBody $null)
    }

    'blocks' {
        if ($remaining.Count -ne 2) {
            throw 'Usage: .\notion-account.ps1 blocks <email> <block-id>'
        }

        $profile = Normalize-ProfileName -Profile $remaining[0]
        $blockId = $remaining[1]
        ConvertTo-JsonOutput -Value (Invoke-NotionApi -Profile $profile -Method GET -Path "/blocks/$blockId/children?page_size=100" -JsonBody $null)
    }

    'status' {
        $profile = Get-ProfileOrActive -Profile $(if ($remaining.Count -ge 1) { $remaining[0] } else { $null })
        Get-ProfileStatus -Profile $profile | Format-List
    }

    'status-all' {
        if (-not (Test-Path -LiteralPath $accountRoot)) {
            Write-Host 'No Notion profiles found.'
            return
        }

        $profiles = @(Get-ChildItem -LiteralPath $accountRoot -Directory -Force | Where-Object { $_.Name -match '^[^\s@]+@[^\s@]+\.[^\s@]+$' } | Sort-Object Name)
        if ($profiles.Count -eq 0) {
            Write-Host 'No Notion profiles found.'
            return
        }

        $profiles |
            ForEach-Object { Get-ProfileStatus -Profile (Get-ProfileName -Directory $_) } |
            Format-Table -AutoSize
    }

    'list' {
        if (-not (Test-Path -LiteralPath $accountRoot)) {
            Write-Host 'No Notion profiles found.'
            return
        }

        $active = Get-ActiveProfile
        $profiles = @(Get-ChildItem -LiteralPath $accountRoot -Directory -Force | Where-Object { $_.Name -match '^[^\s@]+@[^\s@]+\.[^\s@]+$' } | Sort-Object Name)
        if ($profiles.Count -eq 0) {
            Write-Host 'No Notion profiles found.'
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
            Write-Host 'No active Notion email profile set.'
        }
    }

    'path' {
        $profile = Get-ProfileOrActive -Profile $(if ($remaining.Count -ge 1) { $remaining[0] } else { $null })
        Write-Host (Get-ProfilePath -Profile $profile)
    }

    'env' {
        $profile = Get-ProfileOrActive -Profile $(if ($remaining.Count -ge 1) { $remaining[0] } else { $null })
        $profilePath = Get-ProfilePath -Profile $profile
        $workspaceId = Read-ProfileWorkspaceId -Profile $profile
        Write-Host "`$env:NOTION_HOME = '$profilePath'"
        Write-Host "`$env:NOTION_API_VERSION = '$apiVersion'"
        if (-not [string]::IsNullOrWhiteSpace($workspaceId)) {
            Write-Host "`$env:NOTION_WORKSPACE_ID = '$workspaceId'"
        }
        Write-Host '$env:NOTION_API_TOKEN = <profile token if token.txt exists>'
        Write-Host '$env:NOTION_TOKEN = <profile token if token.txt exists>'
        Write-Host '$env:NOTION_ACCESS_TOKEN = <profile token if token.txt exists>'
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
