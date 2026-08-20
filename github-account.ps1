$ErrorActionPreference = 'Stop'

$accountRoot = Join-Path $env:APPDATA 'mainframe\accounts\github'
$currentFile = Join-Path $accountRoot 'current.json'
$apiEndpoint = 'https://api.github.com'
$apiVersion = '2026-03-10'

function Show-Usage {
    @(
        'GitHub account profile helper',
        '',
        'Profiles are keyed by account email only and stored in:',
        '  %APPDATA%\mainframe\accounts\github\<email>',
        '',
        'GitHub CLI isolation uses GH_CONFIG_DIR plus profile-local token env.',
        'Portable token profiles use GH_TOKEN/GITHUB_TOKEN at command time so',
        'they can be restored through mainframe encrypted secrets backup.',
        '',
        'Usage:',
        '  .\github-account.ps1 login [<email>] [gh auth login args...]',
        '  .\github-account.ps1 login-limited [<email>] [gh auth login args...]',
        '  .\github-account.ps1 refresh-default-scopes [email|--all]',
        '  .\github-account.ps1 token-add [<email>]',
        '  .\github-account.ps1 token-add-limited [<email>]',
        '  .\github-account.ps1 import-current',
        '  .\github-account.ps1 import-current-limited',
        '  .\github-account.ps1 authority [email]',
        '  .\github-account.ps1 authority-json [email]',
        '  .\github-account.ps1 authority-all-json',
        '  .\github-account.ps1 token-clear [email]',
        '  .\github-account.ps1 use <email>',
        '  .\github-account.ps1 run [email] <gh args...>',
        '  .\github-account.ps1 api <email> <GET|POST|PUT|PATCH|DELETE> <api path> [json body]',
        '  .\github-account.ps1 whoami [email]',
        '  .\github-account.ps1 repos [email]',
        '  .\github-account.ps1 orgs [email]',
        '  .\github-account.ps1 capabilities [email]',
        '  .\github-account.ps1 capabilities-json [email]',
        '  .\github-account.ps1 status [email]',
        '  .\github-account.ps1 status-all',
        '  .\github-account.ps1 list',
        '  .\github-account.ps1 current',
        '  .\github-account.ps1 path [email]',
        '  .\github-account.ps1 env [email]',
        '  .\github-account.ps1 logout [email]',
        '',
        'GitHub login defaults to the full official OAuth scope set mainframe uses for automation.',
        '',
        'Passing <email> to login/token-add asserts the target identity: mainframe refuses',
        'to save the profile if the detected email does not match (rule 17: keyed by asserted email).',
        'OAuth tokens (gho_) trigger a warning recommending a durable PAT (ghp_/github_pat_).',
        '',
        'Examples:',
'  .\github-account.ps1 login user@example.com',
  '  .\github-account.ps1 token-add user@example.com',
        '  .\github-account.ps1 refresh-default-scopes --all',
        '  .\github-account.ps1 import-current',
        '  .\github-account.ps1 whoami user@example.com',
        '  .\github-account.ps1 repos user@example.com',
        '  .\github-account.ps1 capabilities user@example.com',
        '  .\github-account.ps1 run user@example.com repo list --limit 20',
        '  .\github-account.ps1 run repo list --limit 20',
        '  .\github-account.ps1 api user@example.com GET /user'
    ) -join [Environment]::NewLine | Write-Host
}

function Normalize-ProfileName {
    param([string]$Profile)

    if ([string]::IsNullOrWhiteSpace($Profile)) {
        throw 'Email profile is required.'
    }

    $normalized = $Profile.Trim().ToLowerInvariant()
    if ($normalized -notmatch '^[^\s@]+@[^\s@]+\.[^\s@]+$') {
        throw "GitHub profile must be an account email, not a username or label: $Profile"
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

function Get-GhCommand {
    $cmd = Get-Command gh -ErrorAction SilentlyContinue
    if ($cmd) {
        return $cmd.Source
    }

    throw 'GitHub CLI was not found. Install it with: scoop install gh'
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
        [AllowNull()][string]$GitHubLogin
    )

    New-Item -ItemType Directory -Force -Path $ProfilePath | Out-Null
    [ordered]@{
        tool = 'github'
        service = 'github.com'
        profile = $Profile
        githubLogin = $GitHubLogin
        ghConfigDir = $ProfilePath
        apiEndpoint = $apiEndpoint
        apiVersion = $apiVersion
        tokenPath = (Get-TokenPath -ProfilePath $ProfilePath)
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
        tool = 'github'
        service = 'github.com'
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
        throw 'No email was provided and no active GitHub email profile is set. Run .\github-account.ps1 use <email>.'
    }

    return Normalize-ProfileName -Profile $active
}

function Write-ProfileTokenValue {
    param(
        [string]$Profile,
        [string]$Token,
        [AllowNull()][string]$GitHubLogin
    )

    if ([string]::IsNullOrWhiteSpace($Token)) {
        throw 'GitHub token is empty.'
    }

    $normalized = Normalize-ProfileName -Profile $Profile
    $profilePath = Get-ProfilePath -Profile $normalized
    New-Item -ItemType Directory -Force -Path $profilePath | Out-Null
    $Token.Trim() | Set-Content -LiteralPath (Get-TokenPath -ProfilePath $profilePath) -NoNewline -Encoding UTF8
    Write-ProfileMetadata -Profile $normalized -ProfilePath $profilePath -GitHubLogin $GitHubLogin
    Set-ActiveProfile -Profile $normalized
}

function Read-ProfileToken {
    param([string]$Profile)

    $normalized = Normalize-ProfileName -Profile $Profile
    $profilePath = Get-ProfilePath -Profile $normalized
    $tokenPath = Get-TokenPath -ProfilePath $profilePath
    if (Test-Path -LiteralPath $tokenPath) {
        $token = (Get-Content -LiteralPath $tokenPath -Raw).Trim()
        if (-not [string]::IsNullOrWhiteSpace($token)) {
            return $token
        }
    }

    return $null
}

function Invoke-WithGitHubProfile {
    param(
        [string]$Profile,
        [scriptblock]$Script
    )

    $normalized = Normalize-ProfileName -Profile $Profile
    $profilePath = Get-ProfilePath -Profile $normalized
    New-Item -ItemType Directory -Force -Path $profilePath | Out-Null
    $token = Read-ProfileToken -Profile $normalized

    $oldConfigDir = $env:GH_CONFIG_DIR
    $oldGhToken = $env:GH_TOKEN
    $oldGitHubToken = $env:GITHUB_TOKEN
    $oldEnterpriseToken = $env:GH_ENTERPRISE_TOKEN
    $oldGitHubEnterpriseToken = $env:GITHUB_ENTERPRISE_TOKEN
    $oldNoNotifier = $env:GH_NO_UPDATE_NOTIFIER

    try {
        $env:GH_CONFIG_DIR = $profilePath
        $env:GH_NO_UPDATE_NOTIFIER = '1'
        Remove-Item Env:\GH_ENTERPRISE_TOKEN -ErrorAction SilentlyContinue
        Remove-Item Env:\GITHUB_ENTERPRISE_TOKEN -ErrorAction SilentlyContinue
        if ([string]::IsNullOrWhiteSpace($token)) {
            Remove-Item Env:\GH_TOKEN -ErrorAction SilentlyContinue
            Remove-Item Env:\GITHUB_TOKEN -ErrorAction SilentlyContinue
        } else {
            $env:GH_TOKEN = $token
            $env:GITHUB_TOKEN = $token
        }

        & $Script
    } finally {
        if ([string]::IsNullOrWhiteSpace($oldConfigDir)) {
            Remove-Item Env:\GH_CONFIG_DIR -ErrorAction SilentlyContinue
        } else {
            $env:GH_CONFIG_DIR = $oldConfigDir
        }

        if ([string]::IsNullOrWhiteSpace($oldGhToken)) {
            Remove-Item Env:\GH_TOKEN -ErrorAction SilentlyContinue
        } else {
            $env:GH_TOKEN = $oldGhToken
        }

        if ([string]::IsNullOrWhiteSpace($oldGitHubToken)) {
            Remove-Item Env:\GITHUB_TOKEN -ErrorAction SilentlyContinue
        } else {
            $env:GITHUB_TOKEN = $oldGitHubToken
        }

        if ([string]::IsNullOrWhiteSpace($oldEnterpriseToken)) {
            Remove-Item Env:\GH_ENTERPRISE_TOKEN -ErrorAction SilentlyContinue
        } else {
            $env:GH_ENTERPRISE_TOKEN = $oldEnterpriseToken
        }

        if ([string]::IsNullOrWhiteSpace($oldGitHubEnterpriseToken)) {
            Remove-Item Env:\GITHUB_ENTERPRISE_TOKEN -ErrorAction SilentlyContinue
        } else {
            $env:GITHUB_ENTERPRISE_TOKEN = $oldGitHubEnterpriseToken
        }

        if ([string]::IsNullOrWhiteSpace($oldNoNotifier)) {
            Remove-Item Env:\GH_NO_UPDATE_NOTIFIER -ErrorAction SilentlyContinue
        } else {
            $env:GH_NO_UPDATE_NOTIFIER = $oldNoNotifier
        }
    }
}

function Invoke-GhProfile {
    param(
        [string]$Profile,
        [string[]]$GhArgs
    )

    $normalized = Normalize-ProfileName -Profile $Profile
    $profilePath = Get-ProfilePath -Profile $normalized
    if (-not (Test-Path -LiteralPath $profilePath)) {
        throw "GitHub profile does not exist yet: $normalized. Run .\github-account.ps1 import-current or .\github-account.ps1 token-add first; the profile email must be detected from the token/session."
    }

    $gh = Get-GhCommand
    Invoke-WithGitHubProfile -Profile $normalized -Script {
        & $gh @GhArgs
        if ($LASTEXITCODE -ne 0) {
            throw "gh $($GhArgs -join ' ') failed with exit code $LASTEXITCODE"
        }
    }
}

function Invoke-GhProfileCapture {
    param(
        [string]$Profile,
        [string[]]$GhArgs
    )

    $normalized = Normalize-ProfileName -Profile $Profile
    $gh = Get-GhCommand
    $script:ghCaptureOutput = @()
    $script:ghCaptureExitCode = 0
    Invoke-WithGitHubProfile -Profile $normalized -Script {
        $script:ghCaptureOutput = @(& $gh @GhArgs 2>&1)
        $script:ghCaptureExitCode = $LASTEXITCODE
    }

    $output = @($script:ghCaptureOutput)
    $exitCode = $script:ghCaptureExitCode
    Remove-Variable -Name ghCaptureOutput -Scope Script -ErrorAction SilentlyContinue
    Remove-Variable -Name ghCaptureExitCode -Scope Script -ErrorAction SilentlyContinue

    if ($exitCode -ne 0) {
        throw "gh $($GhArgs -join ' ') failed with exit code $exitCode"
    }

    return ($output -join [Environment]::NewLine)
}

function Get-ApiPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw 'API path is required.'
    }

    if ($Path -match '^https?://') {
        $uri = [uri]$Path
        if ($uri.Host -ne 'api.github.com') {
            throw 'Only https://api.github.com URLs are allowed.'
        }

        return $uri.PathAndQuery
    }

    if ($Path.StartsWith('/')) {
        return $Path
    }

    return "/$Path"
}

function Invoke-GitHubApi {
    param(
        [string]$Profile,
        [string]$Method,
        [string]$Path,
        [AllowNull()][string]$JsonBody
    )

    $normalized = Normalize-ProfileName -Profile $Profile
    $apiPath = Get-ApiPath -Path $Path
    $methodUpper = $Method.ToUpperInvariant()
    if ($methodUpper -notin @('GET', 'POST', 'PUT', 'PATCH', 'DELETE')) {
        throw 'Method must be one of: GET, POST, PUT, PATCH, DELETE.'
    }

    $tempBodyPath = $null
    try {
        $ghArgs = @('api', '--method', $methodUpper, $apiPath)
        if ([string]::IsNullOrWhiteSpace($JsonBody)) {
            $output = Invoke-GhProfileCapture -Profile $normalized -GhArgs $ghArgs
        } else {
            $JsonBody | ConvertFrom-Json | Out-Null
            $tempBodyPath = Join-Path $env:TEMP "mainframe-github-api-body-$([Guid]::NewGuid().ToString('N')).json"
            $JsonBody | Set-Content -LiteralPath $tempBodyPath -NoNewline -Encoding UTF8
            $output = Invoke-GhProfileCapture -Profile $normalized -GhArgs ($ghArgs + @('--input', $tempBodyPath))
        }

        if ([string]::IsNullOrWhiteSpace($output)) {
            return $null
        }

        return $output | ConvertFrom-Json
    } catch {
        throw "GitHub API $methodUpper $apiPath failed: $($_.Exception.Message)"
    } finally {
        if ($tempBodyPath -and (Test-Path -LiteralPath $tempBodyPath)) {
            Remove-Item -LiteralPath $tempBodyPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-GitHubApiPaged {
    param(
        [string]$Profile,
        [string]$Path
    )

    $normalized = Normalize-ProfileName -Profile $Profile
    $items = New-Object System.Collections.Generic.List[object]
    $apiPath = Get-ApiPath -Path $Path

    $output = Invoke-GhProfileCapture -Profile $normalized -GhArgs @('api', '--paginate', '--slurp', $apiPath)
    if ([string]::IsNullOrWhiteSpace($output)) {
        return @()
    }

    $pages = $output | ConvertFrom-Json
    foreach ($page in @($pages)) {
        if ($page -is [System.Collections.IEnumerable] -and $page -isnot [string]) {
            foreach ($item in @($page)) {
                $items.Add($item)
            }
        } else {
            $items.Add($page)
        }
    }

    return $items.ToArray()
}

function ConvertTo-JsonOutput {
    param([AllowNull()]$Value)

    if ($null -eq $Value) {
        Write-Host '{}'
        return
    }

    $Value | ConvertTo-Json -Depth 32
}

function Resolve-GitHubLogin {
    param([string]$Profile)

    try {
        $user = Invoke-GitHubApi -Profile $Profile -Method GET -Path '/user' -JsonBody $null
        if ($user.login) {
            return [string]$user.login
        }
    } catch {
        return $null
    }

    return $null
}

function Resolve-GitHubEmailFromToken {
    param([string]$Token)

    if ([string]::IsNullOrWhiteSpace($Token)) {
        return $null
    }

    $headers = @{
        Authorization = "Bearer $($Token.Trim())"
        Accept = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = $apiVersion
        'User-Agent' = 'mainframe-github-account'
    }

    try {
        $emails = Invoke-RestMethod -Method Get -Uri "$apiEndpoint/user/emails" -Headers $headers -ContentType 'application/json'
        $primary = @($emails | Where-Object { $_.primary -eq $true -and $_.verified -eq $true } | Select-Object -First 1)
        if ($primary.Count -gt 0 -and $primary[0].email) {
            return Normalize-ProfileName -Profile ([string]$primary[0].email)
        }

        $verified = @($emails | Where-Object { $_.verified -eq $true } | Select-Object -First 1)
        if ($verified.Count -gt 0 -and $verified[0].email) {
            return Normalize-ProfileName -Profile ([string]$verified[0].email)
        }
    } catch {
    }

    try {
        $user = Invoke-RestMethod -Method Get -Uri "$apiEndpoint/user" -Headers $headers -ContentType 'application/json'
        if ($user.email) {
            return Normalize-ProfileName -Profile ([string]$user.email)
        }
    } catch {
    }

    return $null
}

function Invoke-WithGitHubConfigDir {
    param(
        [string]$ProfilePath,
        [scriptblock]$Script
    )

    New-Item -ItemType Directory -Force -Path $ProfilePath | Out-Null

    $oldConfigDir = $env:GH_CONFIG_DIR
    $oldGhToken = $env:GH_TOKEN
    $oldGitHubToken = $env:GITHUB_TOKEN
    $oldNoNotifier = $env:GH_NO_UPDATE_NOTIFIER

    try {
        $env:GH_CONFIG_DIR = $ProfilePath
        $env:GH_NO_UPDATE_NOTIFIER = '1'
        Remove-Item Env:\GH_TOKEN -ErrorAction SilentlyContinue
        Remove-Item Env:\GITHUB_TOKEN -ErrorAction SilentlyContinue

        & $Script
    } finally {
        if ([string]::IsNullOrWhiteSpace($oldConfigDir)) {
            Remove-Item Env:\GH_CONFIG_DIR -ErrorAction SilentlyContinue
        } else {
            $env:GH_CONFIG_DIR = $oldConfigDir
        }

        if ([string]::IsNullOrWhiteSpace($oldGhToken)) {
            Remove-Item Env:\GH_TOKEN -ErrorAction SilentlyContinue
        } else {
            $env:GH_TOKEN = $oldGhToken
        }

        if ([string]::IsNullOrWhiteSpace($oldGitHubToken)) {
            Remove-Item Env:\GITHUB_TOKEN -ErrorAction SilentlyContinue
        } else {
            $env:GITHUB_TOKEN = $oldGitHubToken
        }

        if ([string]::IsNullOrWhiteSpace($oldNoNotifier)) {
            Remove-Item Env:\GH_NO_UPDATE_NOTIFIER -ErrorAction SilentlyContinue
        } else {
            $env:GH_NO_UPDATE_NOTIFIER = $oldNoNotifier
        }
    }
}

function Resolve-GitHubEmailFromConfigDir {
    param([string]$ProfilePath)

    $gh = Get-GhCommand
    $script:ghDetectedEmail = $null
    Invoke-WithGitHubConfigDir -ProfilePath $ProfilePath -Script {
        $output = @(& $gh api user/emails --jq '.[] | select(.primary == true and .verified == true) | .email' 2>$null)
        if ($LASTEXITCODE -eq 0 -and $output) {
            $script:ghDetectedEmail = ($output | Select-Object -First 1).Trim()
            return
        }

        $output = @(& $gh api user --jq .email 2>$null)
        if ($LASTEXITCODE -eq 0 -and $output) {
            $script:ghDetectedEmail = ($output | Select-Object -First 1).Trim()
        }
    }

    $email = $script:ghDetectedEmail
    Remove-Variable -Name ghDetectedEmail -Scope Script -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($email)) {
        return $null
    }

    return Normalize-ProfileName -Profile $email
}

function Read-GitHubTokenFromConfigDir {
    param([string]$ProfilePath)

    $gh = Get-GhCommand
    $script:ghDetectedToken = $null
    Invoke-WithGitHubConfigDir -ProfilePath $ProfilePath -Script {
        $output = @(& $gh auth token 2>$null)
        if ($LASTEXITCODE -eq 0 -and $output) {
            $script:ghDetectedToken = ($output -join [Environment]::NewLine).Trim()
        }
    }

    $token = $script:ghDetectedToken
    Remove-Variable -Name ghDetectedToken -Scope Script -ErrorAction SilentlyContinue
    return $token
}

function Split-GitHubScopes {
    param([string[]]$Values)

    $scopes = New-Object System.Collections.Generic.List[string]
    foreach ($value in @($Values)) {
        if ([string]::IsNullOrWhiteSpace($value)) {
            continue
        }

        foreach ($scope in @($value -split ',')) {
            $trimmed = $scope.Trim()
            if ([string]::IsNullOrWhiteSpace($trimmed)) {
                continue
            }

            if ($trimmed -notmatch '^[a-z][a-z0-9:_-]*$') {
                throw "Invalid GitHub OAuth scope: $trimmed"
            }

            if (-not $scopes.Contains($trimmed)) {
                $scopes.Add($trimmed)
            }
        }
    }

    return [string[]]$scopes.ToArray()
}

function Get-GitHubDefaultOAuthScopes {
    return [string[]]@(
        'repo',
        'workflow',
        'admin:org',
        'admin:repo_hook',
        'admin:org_hook',
        'gist',
        'notifications',
        'user',
        'project',
        'read:packages',
        'write:packages',
        'delete:packages',
        'admin:public_key',
        'admin:gpg_key',
        'admin:ssh_signing_key',
        'codespace',
        'security_events',
        'delete_repo',
        'write:discussion',
        'read:audit_log',
        'admin:enterprise'
    )
}

function Merge-GitHubLoginScopes {
    param(
        [string[]]$Args,
        [string[]]$DefaultScopes
    )

    $keptArgs = New-Object System.Collections.Generic.List[string]
    $scopeValues = New-Object System.Collections.Generic.List[string]
    for ($index = 0; $index -lt @($Args).Count; $index++) {
        $arg = $Args[$index]
        if ($arg -eq '--scopes' -or $arg -eq '-s') {
            if ($index + 1 -ge $Args.Count) {
                throw 'GitHub scope flag needs a value.'
            }

            $scopeValues.Add($Args[$index + 1])
            $index++
            continue
        }

        if ($arg -like '--scopes=*') {
            $scopeValues.Add($arg.Substring('--scopes='.Length))
            continue
        }

        if ($arg -like '-s=*') {
            $scopeValues.Add($arg.Substring('-s='.Length))
            continue
        }

        $keptArgs.Add($arg)
    }

    $scopes = Split-GitHubScopes -Values @($scopeValues.ToArray() + $DefaultScopes)
    return [string[]]@($keptArgs.ToArray() + @('--scopes', ($scopes -join ',')))
}

function Get-GitHubTokenAuthority {
    param(
        [string]$Token,
        [AllowNull()][string]$Profile
    )

    $tokenKind = Get-GitHubTokenKind -Token $Token
    $requiredScopes = @(Get-GitHubDefaultOAuthScopes)
    $oauthScopes = @()
    $apiError = $null

    if (-not [string]::IsNullOrWhiteSpace($Token)) {
        $headers = @{
            Authorization = "Bearer $($Token.Trim())"
            Accept = 'application/vnd.github+json'
            'X-GitHub-Api-Version' = $apiVersion
            'User-Agent' = 'mainframe-github-account'
        }

        try {
            $response = Invoke-WebRequest -Method Get -Uri "$apiEndpoint/user" -Headers $headers -UseBasicParsing
            $oauthScopes = @(Convert-CommaHeaderToArray -Value (Get-HeaderValue -Headers $response.Headers -Name 'x-oauth-scopes'))
        } catch {
            $apiError = $_.Exception.Message
            try {
                $gh = Get-GhCommand
                $oldGhToken = $env:GH_TOKEN
                $oldGitHubToken = $env:GITHUB_TOKEN
                $oldEnterpriseToken = $env:GH_ENTERPRISE_TOKEN
                $oldGitHubEnterpriseToken = $env:GITHUB_ENTERPRISE_TOKEN
                $oldNoNotifier = $env:GH_NO_UPDATE_NOTIFIER
                try {
                    $env:GH_TOKEN = $Token.Trim()
                    $env:GITHUB_TOKEN = $Token.Trim()
                    $env:GH_NO_UPDATE_NOTIFIER = '1'
                    Remove-Item Env:\GH_ENTERPRISE_TOKEN -ErrorAction SilentlyContinue
                    Remove-Item Env:\GITHUB_ENTERPRISE_TOKEN -ErrorAction SilentlyContinue

                    $includeOutput = @(& $gh api --include /user 2>&1)
                    if ($LASTEXITCODE -eq 0 -and $includeOutput) {
                        $headersFromGh = Convert-GhIncludeOutputToHeaders -Output ($includeOutput -join [Environment]::NewLine)
                        $oauthScopes = @(Convert-CommaHeaderToArray -Value (Get-HeaderValue -Headers $headersFromGh -Name 'x-oauth-scopes'))
                        $apiError = $null
                    } else {
                        $apiError = "$apiError; gh api fallback failed"
                    }
                } finally {
                    if ([string]::IsNullOrWhiteSpace($oldGhToken)) { Remove-Item Env:\GH_TOKEN -ErrorAction SilentlyContinue } else { $env:GH_TOKEN = $oldGhToken }
                    if ([string]::IsNullOrWhiteSpace($oldGitHubToken)) { Remove-Item Env:\GITHUB_TOKEN -ErrorAction SilentlyContinue } else { $env:GITHUB_TOKEN = $oldGitHubToken }
                    if ([string]::IsNullOrWhiteSpace($oldEnterpriseToken)) { Remove-Item Env:\GH_ENTERPRISE_TOKEN -ErrorAction SilentlyContinue } else { $env:GH_ENTERPRISE_TOKEN = $oldEnterpriseToken }
                    if ([string]::IsNullOrWhiteSpace($oldGitHubEnterpriseToken)) { Remove-Item Env:\GITHUB_ENTERPRISE_TOKEN -ErrorAction SilentlyContinue } else { $env:GITHUB_ENTERPRISE_TOKEN = $oldGitHubEnterpriseToken }
                    if ([string]::IsNullOrWhiteSpace($oldNoNotifier)) { Remove-Item Env:\GH_NO_UPDATE_NOTIFIER -ErrorAction SilentlyContinue } else { $env:GH_NO_UPDATE_NOTIFIER = $oldNoNotifier }
                }
            } catch {
                $apiError = "$apiError; gh api fallback failed: $($_.Exception.Message)"
            }
        }
    }

    # PAT scope normalization: classic/fine-grained PATs report scopes differently than OAuth tokens.
    # - PATs return `audit_log` where OAuth returns `read:audit_log` — accept as equivalent.
    # - PATsimplicitly grant `read:packages` when `write:packages` or `delete:packages` is present;
    #   GitHub's /user response just doesn't list it separately.
    # - `security_events` scope is OAuth-Apps-only and cannot be granted to a classic PAT;
    #   do not flag PAT profiles as missing it (a PAT with admin:enterprise/admin:org covers the
    #   same audit/enterprise event surface via the GitHub API surface that PATs can reach).
    $isPat = ($tokenKind -eq 'classic-pat' -or $tokenKind -eq 'fine-grained-pat')
    $effectiveScopes = @($oauthScopes)
    if ($isPat) {
        if ($effectiveScopes -contains 'audit_log' -and $effectiveScopes -notcontains 'read:audit_log') {
            $effectiveScopes = @($effectiveScopes) + 'read:audit_log'
        }
        if (($effectiveScopes -contains 'write:packages' -or $effectiveScopes -contains 'delete:packages') -and $effectiveScopes -notcontains 'read:packages') {
            $effectiveScopes = @($effectiveScopes) + 'read:packages'
        }
        $requiredScopes = @($requiredScopes | Where-Object { $_ -ne 'security_events' })
    }

    $missingScopes = @($requiredScopes | Where-Object { $effectiveScopes -notcontains $_ })
    $fullAuthority = (-not [string]::IsNullOrWhiteSpace($Token)) -and @($missingScopes).Count -eq 0

    [pscustomobject]@{
        Service = 'github.com'
        Profile = if ([string]::IsNullOrWhiteSpace($Profile)) { $null } else { Normalize-ProfileName -Profile $Profile }
        FullAuthority = $fullAuthority
        CredentialClass = $tokenKind
        OfficialMaximum = 'GitHub OAuth token with the mainframe default broad OAuth scope set'
        RequiredScopes = @($requiredScopes)
        OAuthScopes = @($oauthScopes)
        MissingScopes = @($missingScopes)
        ApiError = $apiError
        CheckedAt = (Get-Date).ToString('o')
    }
}

function Get-GitHubProfileAuthority {
    param([string]$Profile)

    $normalized = Normalize-ProfileName -Profile $Profile
    $token = Read-ProfileToken -Profile $normalized
    if ([string]::IsNullOrWhiteSpace($token)) {
        $requiredScopes = @(Get-GitHubDefaultOAuthScopes)
        return [pscustomobject]@{
            Service = 'github.com'
            Profile = $normalized
            FullAuthority = $false
            CredentialClass = 'missing-portable-token'
            OfficialMaximum = 'GitHub OAuth token with the mainframe default broad OAuth scope set'
            RequiredScopes = @($requiredScopes)
            OAuthScopes = @()
            MissingScopes = @($requiredScopes)
            ApiError = 'profile token missing'
            CheckedAt = (Get-Date).ToString('o')
        }
    }

    return Get-GitHubTokenAuthority -Token $token -Profile $normalized
}

function Write-GitHubTokenClassWarning {
    param([string]$Token)

    $kind = Get-GitHubTokenKind -Token $Token
    if ($kind -eq 'oauth-token') {
        Write-Warning 'GitHub OAuth tokens (gho_) expire and can be revoked by session GC. For durable mainframe auth, generate a classic PAT (ghp_) or fine-grained PAT (github_pat_) with full scopes at https://github.com/settings/tokens and run: github-account.ps1 token-add <email>'
    } elseif ($kind -eq 'unknown-token-class') {
        Write-Warning "Stored GitHub token has an unrecognized class. Expected ghp_ (classic PAT), github_pat_ (fine-grained PAT), or gho_ (OAuth). Token may not work with all gh CLI operations."
    }
}

function Assert-GitHubTokenFullAuthority {
    param(
        [string]$Token,
        [AllowNull()][string]$Profile,
        [string]$Source
    )

    $authority = Get-GitHubTokenAuthority -Token $Token -Profile $Profile
    if (-not $authority.FullAuthority) {
        $missing = if (@($authority.MissingScopes).Count -gt 0) { @($authority.MissingScopes) -join ', ' } else { 'unknown-scope-check' }
        if (-not [string]::IsNullOrWhiteSpace($authority.ApiError)) {
            $missing = "$missing; api-check=$($authority.ApiError)"
        }

        throw "$Source is not full-authority for mainframe. Missing GitHub OAuth scopes: $missing. Use login/refresh-default-scopes for full OAuth, or explicitly use a limited command if you want to save a narrow token."
    }

    return $authority
}

function Write-GitHubAuthority {
    param([string]$Profile)

    $authority = Get-GitHubProfileAuthority -Profile $Profile
    Write-Host "GitHub authority for $($authority.Profile)"
    $authority |
        Select-Object Profile, FullAuthority, CredentialClass, OfficialMaximum, MissingScopes, ApiError, CheckedAt |
        Format-List

    if (@($authority.OAuthScopes).Count -gt 0) {
        Write-Host 'OAuth scopes:'
        @($authority.OAuthScopes) | ForEach-Object { Write-Host "  - $_" }
    }
}

function Resolve-GitHubProfileAndScopeArgs {
    param(
        [string[]]$Args,
        [string]$Usage
    )

    if (@($Args).Count -lt 1) {
        throw $Usage
    }

    if (Test-LooksLikeEmail -Value $Args[0]) {
        if ($Args.Count -lt 2) {
            throw $Usage
        }

        return [pscustomobject]@{
            Profile = Normalize-ProfileName -Profile $Args[0]
            Values = @($Args | Select-Object -Skip 1)
        }
    }

    return [pscustomobject]@{
        Profile = Get-ProfileOrActive -Profile $null
        Values = @($Args)
    }
}

function Invoke-GitHubScopeRefresh {
    param(
        [string]$Profile,
        [string[]]$Scopes,
        [switch]$Remove,
        [switch]$Reset
    )

    $normalized = Normalize-ProfileName -Profile $Profile
    $profilePath = Get-ProfilePath -Profile $normalized
    if (-not (Test-Path -LiteralPath $profilePath)) {
        throw "GitHub profile does not exist yet: $normalized"
    }

    if (-not $Reset -and @($Scopes).Count -eq 0) {
        throw 'At least one GitHub OAuth scope is required.'
    }

    $gh = Get-GhCommand
    $script:ghRefreshExitCode = 0
    Invoke-WithGitHubConfigDir -ProfilePath $profilePath -Script {
        if ($Reset) {
            & $gh auth refresh --hostname github.com --reset-scopes
        } elseif ($Remove) {
            & $gh auth refresh --hostname github.com --remove-scopes ($Scopes -join ',')
        } else {
            & $gh auth refresh --hostname github.com --scopes ($Scopes -join ',')
        }

        $script:ghRefreshExitCode = $LASTEXITCODE
    }

    $exitCode = $script:ghRefreshExitCode
    Remove-Variable -Name ghRefreshExitCode -Scope Script -ErrorAction SilentlyContinue
    if ($exitCode -ne 0) {
        throw "gh auth refresh failed with exit code $exitCode"
    }

    $token = Read-GitHubTokenFromConfigDir -ProfilePath $profilePath
    if (-not [string]::IsNullOrWhiteSpace($token)) {
        $detectedProfile = Resolve-GitHubEmailFromToken -Token $token
        if ($detectedProfile -and $detectedProfile -ne $normalized) {
            throw "GitHub auth refreshed for $detectedProfile, not expected profile $normalized. Refusing to overwrite profile token."
        }

        $login = Resolve-GitHubLogin -Profile $normalized
        Write-ProfileTokenValue -Profile $normalized -Token $token -GitHubLogin $login
        Write-ProfileMetadata -Profile $normalized -ProfilePath $profilePath -GitHubLogin $login
    }

    $action = if ($Reset) { 'reset' } elseif ($Remove) { 'removed' } else { 'added' }
    Write-Host "GitHub OAuth scopes $action for profile: $normalized"
    if (-not $Reset) {
        Write-Host "Scopes: $($Scopes -join ', ')"
    }
}

function Import-CurrentToken {
    param([switch]$AllowLimited)

    $token = $null
    $source = $null
    if (-not [string]::IsNullOrWhiteSpace($env:GH_TOKEN)) {
        $token = $env:GH_TOKEN.Trim()
        $source = 'GH_TOKEN environment variable'
    } elseif (-not [string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN)) {
        $token = $env:GITHUB_TOKEN.Trim()
        $source = 'GITHUB_TOKEN environment variable'
    } else {
        $gh = Get-GhCommand
        $tokenOutput = @(& $gh auth token 2>$null)
        if ($LASTEXITCODE -eq 0 -and $tokenOutput) {
            $token = ($tokenOutput -join [Environment]::NewLine).Trim()
            $source = 'current gh auth token'
        }
    }

    if ([string]::IsNullOrWhiteSpace($token)) {
        throw 'No current GitHub token was found in GH_TOKEN, GITHUB_TOKEN, or gh auth token.'
    }

    $normalized = Resolve-GitHubEmailFromToken -Token $token
    if (-not $normalized) {
        throw 'Could not auto-detect the GitHub account email from the current token. Ensure the token/session can read user email; refusing to save a username or label fallback.'
    }

    if (-not $AllowLimited) {
        Assert-GitHubTokenFullAuthority -Token $token -Profile $normalized -Source $source | Out-Null
    } else {
        Write-Warning 'Importing a limited GitHub token by explicit request. Default mainframe GitHub profiles should use the full default OAuth scope set.'
    }

    Write-ProfileTokenValue -Profile $normalized -Token $token -GitHubLogin $null
    $login = Resolve-GitHubLogin -Profile $normalized
    Write-ProfileMetadata -Profile $normalized -ProfilePath (Get-ProfilePath -Profile $normalized) -GitHubLogin $login
    Write-Host "Imported current GitHub token into profile: $normalized"
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
        GitHubLogin = if ($metadata -and $metadata.githubLogin) { [string]$metadata.githubLogin } else { $null }
        Exists = $exists
        IsActive = ($active -eq $normalized)
        HasToken = $hasToken
        TokenStatus = if ($hasToken) { 'present' } else { 'missing' }
        GhConfigDir = $profilePath
        GhInstalled = [bool](Get-Command gh -ErrorAction SilentlyContinue)
        State = if (-not $exists) { 'missing-profile' } elseif (-not $hasToken) { 'missing-token' } elseif ($active -eq $normalized) { 'active' } else { 'configured' }
    }
}

function Get-GitHubTokenKind {
    param([AllowNull()][string]$Token)

    if ([string]::IsNullOrWhiteSpace($Token)) {
        return 'gh-config-or-missing-token'
    }

    $trimmed = $Token.Trim()
    if ($trimmed.StartsWith('github_pat_', [StringComparison]::Ordinal)) {
        return 'fine-grained-pat'
    }

    if ($trimmed.StartsWith('ghp_', [StringComparison]::Ordinal)) {
        return 'classic-pat'
    }

    if ($trimmed.StartsWith('gho_', [StringComparison]::Ordinal)) {
        return 'oauth-token'
    }

    if ($trimmed.StartsWith('ghu_', [StringComparison]::Ordinal)) {
        return 'github-app-user-token'
    }

    if ($trimmed.StartsWith('ghs_', [StringComparison]::Ordinal)) {
        return 'github-app-installation-token'
    }

    if ($trimmed.StartsWith('ghr_', [StringComparison]::Ordinal)) {
        return 'github-refresh-token'
    }

    return 'unknown-token-class'
}

function Convert-HeaderValueToString {
    param([AllowNull()]$Value)

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [array]) {
        return (($Value | ForEach-Object { [string]$_ }) -join ', ')
    }

    return [string]$Value
}

function Convert-CommaHeaderToArray {
    param([AllowNull()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return @()
    }

    return @($Value.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Get-HeaderValue {
    param(
        [AllowNull()]$Headers,
        [string]$Name
    )

    if ($null -eq $Headers -or [string]::IsNullOrWhiteSpace($Name)) {
        return $null
    }

    if ($Headers -is [System.Collections.IDictionary]) {
        foreach ($key in $Headers.Keys) {
            if ([string]::Equals([string]$key, $Name, [StringComparison]::OrdinalIgnoreCase)) {
                return Convert-HeaderValueToString -Value $Headers[$key]
            }
        }

        return $null
    }

    try {
        return Convert-HeaderValueToString -Value $Headers[$Name]
    } catch {
        return $null
    }
}

function Convert-GhIncludeOutputToHeaders {
    param([AllowNull()][string]$Output)

    $headers = @{}
    if ([string]::IsNullOrWhiteSpace($Output)) {
        return $headers
    }

    $inHeaders = $false
    foreach ($line in @($Output -split "\r?\n")) {
        if ($line -match '^HTTP/\d(?:\.\d)?\s+\d+') {
            $inHeaders = $true
            continue
        }

        if ($inHeaders -and [string]::IsNullOrWhiteSpace($line)) {
            break
        }

        if ($inHeaders -and $line -match '^([^:]+):\s*(.*)$') {
            $name = $Matches[1].Trim().ToLowerInvariant()
            $value = $Matches[2].Trim()
            if ($headers.ContainsKey($name)) {
                $headers[$name] = "$($headers[$name]), $value"
            } else {
                $headers[$name] = $value
            }
        }
    }

    return $headers
}

function Get-GitHubApiHeaders {
    param([string]$Profile)

    $normalized = Normalize-ProfileName -Profile $Profile
    $token = Read-ProfileToken -Profile $normalized
    $webError = $null

    if (-not [string]::IsNullOrWhiteSpace($token)) {
        $headers = @{
            Authorization = "Bearer $($token.Trim())"
            Accept = 'application/vnd.github+json'
            'X-GitHub-Api-Version' = $apiVersion
            'User-Agent' = 'mainframe-github-account'
        }

        try {
            $response = Invoke-WebRequest -Method Get -Uri "$apiEndpoint/user" -Headers $headers -UseBasicParsing
            return $response.Headers
        } catch {
            $webError = $_.Exception.Message
        }
    }

    try {
        $includeOutput = Invoke-GhProfileCapture -Profile $normalized -GhArgs @('api', '--include', '/user')
        $ghHeaders = Convert-GhIncludeOutputToHeaders -Output $includeOutput
        if ($ghHeaders.Count -gt 0) {
            return $ghHeaders
        }
    } catch {
        if ([string]::IsNullOrWhiteSpace($webError)) {
            $webError = $_.Exception.Message
        } else {
            $webError = "$webError; gh include fallback failed: $($_.Exception.Message)"
        }
    }

    if ([string]::IsNullOrWhiteSpace($webError)) {
        return @{}
    }

    return @{
        'mainframe-error' = $webError
    }
}

function Group-Count {
    param(
        [object[]]$Items,
        [scriptblock]$Selector
    )

    $result = [ordered]@{}
    foreach ($item in @($Items)) {
        $key = [string](& $Selector $item)
        if ([string]::IsNullOrWhiteSpace($key)) {
            $key = 'unknown'
        }

        if (-not $result.Contains($key)) {
            $result[$key] = 0
        }

        $result[$key] = [int]$result[$key] + 1
    }

    return [pscustomobject]$result
}

function Get-GitHubCapabilities {
    param([string]$Profile)

    $normalized = Normalize-ProfileName -Profile $Profile
    $profilePath = Get-ProfilePath -Profile $normalized
    $metadata = Read-ProfileMetadata -ProfilePath $profilePath
    $token = Read-ProfileToken -Profile $normalized
    $status = Get-ProfileStatus -Profile $normalized
    $headers = Get-GitHubApiHeaders -Profile $normalized
    $authority = Get-GitHubProfileAuthority -Profile $normalized

    $user = $null
    $repos = @()
    $orgs = @()
    $apiError = $null
    try {
        $user = Invoke-GitHubApi -Profile $normalized -Method GET -Path '/user' -JsonBody $null
        $repos = @(Invoke-GitHubApiPaged -Profile $normalized -Path '/user/repos?per_page=100&affiliation=owner,collaborator,organization_member&sort=full_name')
        $orgs = @(Invoke-GitHubApiPaged -Profile $normalized -Path '/user/orgs?per_page=100')
    } catch {
        $apiError = $_.Exception.Message
    }

    $repoCount = @($repos).Count
    $ownedCount = 0
    $adminCount = 0
    $pushCount = 0
    $pullCount = 0
    $privateCount = 0
    $publicCount = 0
    $forkCount = 0
    $archivedCount = 0

    foreach ($repo in @($repos)) {
        if ($repo.owner -and $repo.owner.login -and $user -and $repo.owner.login -eq $user.login) { $ownedCount++ }
        if ($repo.permissions -and $repo.permissions.admin -eq $true) { $adminCount++ }
        if ($repo.permissions -and $repo.permissions.push -eq $true) { $pushCount++ }
        if ($repo.permissions -and $repo.permissions.pull -eq $true) { $pullCount++ }
        if ($repo.private -eq $true) { $privateCount++ } else { $publicCount++ }
        if ($repo.fork -eq $true) { $forkCount++ }
        if ($repo.archived -eq $true) { $archivedCount++ }
    }

    $rateReset = $null
    $rateResetHeader = Get-HeaderValue -Headers $headers -Name 'x-ratelimit-reset'
    if ($rateResetHeader -match '^\d+$') {
        try {
            $rateReset = [DateTimeOffset]::FromUnixTimeSeconds([int64]$rateResetHeader).ToLocalTime().ToString('o')
        } catch {
            $rateReset = $null
        }
    }

    $tokenKind = Get-GitHubTokenKind -Token $token
    $scopes = Convert-CommaHeaderToArray -Value (Get-HeaderValue -Headers $headers -Name 'x-oauth-scopes')
    $acceptedScopes = Convert-CommaHeaderToArray -Value (Get-HeaderValue -Headers $headers -Name 'x-accepted-oauth-scopes')
    $tokenExpiration = Get-HeaderValue -Headers $headers -Name 'github-authentication-token-expiration'
    $headerError = Get-HeaderValue -Headers $headers -Name 'mainframe-error'

    $recommendedNext = New-Object System.Collections.Generic.List[string]
    if (-not $status.HasToken) {
        $recommendedNext.Add('Save a portable token with token-add so the profile survives encrypted mainframe backup.')
    }

    if ($tokenKind -eq 'classic-pat') {
        $recommendedNext.Add('Consider a fine-grained PAT or GitHub App token for narrower repo/org automation.')
    }

    if (@($scopes).Count -eq 0 -and $tokenKind -eq 'fine-grained-pat') {
        $recommendedNext.Add('Fine-grained PAT detected; use endpoint-level permission errors and repo access counts instead of broad OAuth scope names.')
    } elseif (@($scopes).Count -eq 0) {
        $recommendedNext.Add('No broad OAuth scopes were exposed by the API headers; verify token permissions before high-impact automation.')
    }

    if ($repoCount -eq 0 -and -not $apiError) {
        $recommendedNext.Add('No accessible repos found from /user/repos; token may be too narrow or account may have no repo access.')
    }

    [pscustomobject]@{
        service = 'github.com'
        profile = $normalized
        active = $status.IsActive
        githubLogin = if ($user -and $user.login) { [string]$user.login } elseif ($metadata -and $metadata.githubLogin) { [string]$metadata.githubLogin } else { $null }
        auth = [pscustomobject]@{
            hasProfile = $status.Exists
            hasPortableToken = $status.HasToken
            tokenClass = $tokenKind
            fullAuthority = $authority.FullAuthority
            missingDefaultScopes = @($authority.MissingScopes)
            tokenValue = '<redacted>'
            tokenExpiration = $tokenExpiration
            ghConfigDir = $profilePath
        }
        officialSurfaces = [pscustomobject]@{
            cli = 'GitHub CLI gh'
            api = 'GitHub REST API and GraphQL API'
            appAuth = 'GitHub App installation/user tokens'
            tokenAuth = 'fine-grained PAT or classic PAT'
            mcp = 'official github/github-mcp-server'
        }
        apiHeaders = [pscustomobject]@{
            oauthScopes = @($scopes)
            acceptedUserEndpointScopes = @($acceptedScopes)
            rateLimit = Get-HeaderValue -Headers $headers -Name 'x-ratelimit-limit'
            rateRemaining = Get-HeaderValue -Headers $headers -Name 'x-ratelimit-remaining'
            rateResetLocal = $rateReset
            apiError = if (-not [string]::IsNullOrWhiteSpace($headerError)) { $headerError } else { $apiError }
        }
        access = [pscustomobject]@{
            orgCount = @($orgs).Count
            orgLogins = @($orgs | ForEach-Object { [string]$_.login } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object)
            repoCount = $repoCount
            ownedRepoCount = $ownedCount
            adminRepoCount = $adminCount
            pushRepoCount = $pushCount
            pullRepoCount = $pullCount
            privateRepoCount = $privateCount
            publicRepoCount = $publicCount
            forkRepoCount = $forkCount
            archivedRepoCount = $archivedCount
            visibility = Group-Count -Items @($repos) -Selector { param($repo) if ($repo.visibility) { $repo.visibility } elseif ($repo.private -eq $true) { 'private' } else { 'public' } }
        }
        recommendedJarvisRoute = 'Prefer GitHub App or fine-grained PAT for durable automation, gh CLI for local workflows, REST/GraphQL for structured scripts, and browser UI only for settings GitHub does not expose cleanly.'
        recommendedNext = @($recommendedNext)
    }
}

function Write-GitHubCapabilities {
    param([string]$Profile)

    $capabilities = Get-GitHubCapabilities -Profile $Profile
    Write-Host "GitHub capabilities for $($capabilities.profile)"
    Write-Host ''
    [pscustomobject]@{
        Login = $capabilities.githubLogin
        Active = $capabilities.active
        TokenClass = $capabilities.auth.tokenClass
        FullAuthority = $capabilities.auth.fullAuthority
        HasPortableToken = $capabilities.auth.hasPortableToken
        TokenExpiration = $capabilities.auth.tokenExpiration
        OrgCount = $capabilities.access.orgCount
        RepoCount = $capabilities.access.repoCount
        OwnedRepos = $capabilities.access.ownedRepoCount
        AdminRepos = $capabilities.access.adminRepoCount
        PushRepos = $capabilities.access.pushRepoCount
        PrivateRepos = $capabilities.access.privateRepoCount
        PublicRepos = $capabilities.access.publicRepoCount
        OAuthScopes = if (@($capabilities.apiHeaders.oauthScopes).Count -gt 0) { $capabilities.apiHeaders.oauthScopes -join ', ' } else { '(none exposed)' }
        RateRemaining = $capabilities.apiHeaders.rateRemaining
        RateResetLocal = $capabilities.apiHeaders.rateResetLocal
    } | Format-List

    if (-not $capabilities.auth.fullAuthority -and @($capabilities.auth.missingDefaultScopes).Count -gt 0) {
        Write-Host 'Missing default scopes:'
        $capabilities.auth.missingDefaultScopes | ForEach-Object { Write-Host "  - $_" }
        Write-Host ''
    }

    if (@($capabilities.access.orgLogins).Count -gt 0) {
        Write-Host 'Organizations:'
        $capabilities.access.orgLogins | ForEach-Object { Write-Host "  - $_" }
        Write-Host ''
    }

    Write-Host 'Official surfaces:'
    Write-Host "  - CLI: $($capabilities.officialSurfaces.cli)"
    Write-Host "  - API: $($capabilities.officialSurfaces.api)"
    Write-Host "  - App auth: $($capabilities.officialSurfaces.appAuth)"
    Write-Host "  - Token auth: $($capabilities.officialSurfaces.tokenAuth)"
    Write-Host "  - MCP/plugin: $($capabilities.officialSurfaces.mcp)"
    Write-Host ''
    Write-Host "Jarvis route: $($capabilities.recommendedJarvisRoute)"

    if (@($capabilities.recommendedNext).Count -gt 0) {
        Write-Host ''
        Write-Host 'Next:'
        $capabilities.recommendedNext | ForEach-Object { Write-Host "  - $_" }
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
        Write-Host "Removed saved GitHub token profile for: $normalized"
    } else {
        Write-Host "No saved GitHub token profile found for: $normalized"
    }
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
        Write-Warning "Existing GitHub profile was moved to: $backupPath"
    }

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $targetPath) | Out-Null
    if (-not (Test-Path -LiteralPath $targetPath)) {
        Move-Item -LiteralPath $SourcePath -Destination $targetPath
    }

    return $targetPath
}

function Remove-Profile {
    param([string]$Profile)

    $normalized = Normalize-ProfileName -Profile $Profile
    $profilePath = Get-ProfilePath -Profile $normalized
    if (-not (Test-Path -LiteralPath $profilePath)) {
        Write-Host "GitHub profile does not exist: $normalized"
        return
    }

    $backupPath = "$profilePath.logged-out-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Move-Item -LiteralPath $profilePath -Destination $backupPath
    Write-Host "GitHub profile moved to: $backupPath"

    $active = Get-ActiveProfile
    if ($active -eq $normalized -and (Test-Path -LiteralPath $currentFile)) {
        Remove-Item -LiteralPath $currentFile
        Write-Host 'Active GitHub profile cleared.'
    }
}

$command = if ($args.Count -gt 0) { $args[0].ToLowerInvariant() } else { 'help' }
$remaining = @($args | Select-Object -Skip 1)

switch ($command) {
    'help' {
        Show-Usage
    }

    { $_ -in @('login', 'login-limited') } {
        $expectedEmail = $null
        $loginArgs = @()
        if ($remaining.Count -gt 0 -and (Test-LooksLikeEmail -Value $remaining[0])) {
            $expectedEmail = Normalize-ProfileName -Profile $remaining[0]
            $loginArgs = @($remaining | Select-Object -Skip 1)
        } else {
            $loginArgs = @($remaining)
            if ($loginArgs.Count -eq 0 -or $loginArgs[0] -notlike '-*') {
                Write-Warning 'Running github login without a target email is ambiguous when multiple GitHub accounts are involved. Prefer: github-account.ps1 login <email> [gh auth login args...]. Mainframe will refuse to save the profile if the detected email does not match the requested email.'
            }
        }

        if ($loginArgs.Count -gt 0 -and $loginArgs[0] -notlike '-*') {
            throw "Usage: .\github-account.ps1 $command [<email>] [gh auth login args...]"
        }

        $allowLimited = ($command -eq 'login-limited')
        $profile = $null
        if ($loginArgs -contains '--with-token') {
            Write-Warning 'GitHub --with-token login cannot request default OAuth scopes. The resulting token will be checked before the profile is saved.'
        } else {
            $loginArgs = Merge-GitHubLoginScopes -Args $loginArgs -DefaultScopes (Get-GitHubDefaultOAuthScopes)
        }

        $gh = Get-GhCommand
        $pendingRoot = Join-Path $env:TEMP 'mainframe-github-login'
        New-Item -ItemType Directory -Force -Path $pendingRoot | Out-Null
        $profilePath = Join-Path $pendingRoot "pending-$([Guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Force -Path $profilePath | Out-Null
        if ($expectedEmail) {
            Write-Host "Starting GitHub CLI login for $expectedEmail ; mainframe will assert the detected email matches."
        } else {
            Write-Host 'Starting GitHub CLI login; mainframe will detect the account email after auth.'
        }
        $oldConfigDir = $env:GH_CONFIG_DIR
        $oldGhToken = $env:GH_TOKEN
        $oldGitHubToken = $env:GITHUB_TOKEN
        try {
            $env:GH_CONFIG_DIR = $profilePath
            Remove-Item Env:\GH_TOKEN -ErrorAction SilentlyContinue
            Remove-Item Env:\GITHUB_TOKEN -ErrorAction SilentlyContinue
            & $gh auth login @loginArgs
            if ($LASTEXITCODE -ne 0) {
                throw "gh auth login failed with exit code $LASTEXITCODE"
            }
        } finally {
            if ([string]::IsNullOrWhiteSpace($oldConfigDir)) { Remove-Item Env:\GH_CONFIG_DIR -ErrorAction SilentlyContinue } else { $env:GH_CONFIG_DIR = $oldConfigDir }
            if ([string]::IsNullOrWhiteSpace($oldGhToken)) { Remove-Item Env:\GH_TOKEN -ErrorAction SilentlyContinue } else { $env:GH_TOKEN = $oldGhToken }
            if ([string]::IsNullOrWhiteSpace($oldGitHubToken)) { Remove-Item Env:\GITHUB_TOKEN -ErrorAction SilentlyContinue } else { $env:GITHUB_TOKEN = $oldGitHubToken }
        }

        $profile = Resolve-GitHubEmailFromConfigDir -ProfilePath $profilePath
        $token = Read-GitHubTokenFromConfigDir -ProfilePath $profilePath
        if (-not $profile -and -not [string]::IsNullOrWhiteSpace($token)) {
            $profile = Resolve-GitHubEmailFromToken -Token $token
        }

        if (-not $profile) {
            throw 'Login succeeded, but GitHub account email could not be detected. Default scopes include user email access; refusing to save a username or label fallback.'
        }

        if ($expectedEmail -and $profile -ne $expectedEmail) {
            throw "Login was requested for '$expectedEmail' but the authenticated GitHub account is '$profile'. Refusing to save a profile under a mismatched email (mainframe rule 17: profiles keyed by asserted email). Re-run login with the correct account selected in the gh OAuth flow, or without an email arg to save whatever account OAuth returns."
        }

        $profilePath = Move-ProfileDirectory -SourcePath $profilePath -Profile $profile
        $login = Resolve-GitHubLogin -Profile $profile
        Write-Host "Detected GitHub email: $profile"
        if (-not [string]::IsNullOrWhiteSpace($token)) {
            if (-not $allowLimited) {
                Assert-GitHubTokenFullAuthority -Token $token -Profile $profile -Source 'GitHub login token' | Out-Null
            } else {
                Write-Warning 'Saving a limited GitHub login by explicit request. Default mainframe GitHub profiles should use the full default OAuth scope set.'
            }

            Write-GitHubTokenClassWarning -Token $token
            Write-ProfileTokenValue -Profile $profile -Token $token -GitHubLogin $login
            Write-Host "GitHub token profile is ready and active: $profile"
        } else {
            Write-ProfileMetadata -Profile $profile -ProfilePath $profilePath -GitHubLogin $login
            Set-ActiveProfile -Profile $profile
            Write-Host "GitHub profile config is ready and active: $profile"
            Write-Warning 'Login succeeded, but gh auth token could not be exported. Use token-add for encrypted mainframe backup.'
        }
    }

    'refresh-default-scopes' {
        if ($remaining.Count -gt 1) {
            throw 'Usage: .\github-account.ps1 refresh-default-scopes [email|--all]'
        }

        $scopes = Get-GitHubDefaultOAuthScopes
        if ($remaining.Count -eq 1 -and $remaining[0] -eq '--all') {
            if (-not (Test-Path -LiteralPath $accountRoot)) {
                Write-Host 'No GitHub profiles found.'
                return
            }

            $profiles = @(Get-ChildItem -LiteralPath $accountRoot -Directory -Force | Where-Object { $_.Name -match '^[^\s@]+@[^\s@]+\.[^\s@]+$' } | Sort-Object Name)
            foreach ($profileDirectory in $profiles) {
                $profile = Get-ProfileName -Directory $profileDirectory
                Write-Host "Refreshing default GitHub OAuth scopes for: $profile"
                Invoke-GitHubScopeRefresh -Profile $profile -Scopes $scopes
            }
        } else {
            $profile = Get-ProfileOrActive -Profile $(if ($remaining.Count -eq 1) { $remaining[0] } else { $null })
            Write-Host "Refreshing default GitHub OAuth scopes for: $profile"
            Invoke-GitHubScopeRefresh -Profile $profile -Scopes $scopes
        }
    }

    { $_ -in @('token-add', 'add', 'token-add-limited', 'add-limited') } {
        $expectedEmail = $null
        $rest = @()
        if ($remaining.Count -gt 0 -and (Test-LooksLikeEmail -Value $remaining[0])) {
            $expectedEmail = Normalize-ProfileName -Profile $remaining[0]
            $rest = @($remaining | Select-Object -Skip 1)
        } else {
            $rest = @($remaining)
            Write-Warning 'Running token-add without a target email is ambiguous when multiple GitHub accounts are involved. Prefer: github-account.ps1 token-add <email>. Mainframe will refuse to save the profile if the detected email does not match the requested email.'
        }

        if ($rest.Count -gt 0) {
            throw "Usage: .\github-account.ps1 $command [<email>]"
        }

        $allowLimited = $command -in @('token-add-limited', 'add-limited')
        Write-Host 'Paste a GitHub token. Input is hidden; mainframe will detect the account email and save it as token.txt.'
        $token = Read-Host 'GitHub token' -AsSecureString
        $plainToken = Convert-SecureStringToPlainText -SecureString $token
        $profile = Resolve-GitHubEmailFromToken -Token $plainToken
        if (-not $profile) {
            throw 'Could not auto-detect the GitHub account email from that token. Ensure the token has user:email access; refusing to save a username or label fallback.'
        }

        if ($expectedEmail -and $profile -ne $expectedEmail) {
            throw "Token-add was requested for '$expectedEmail' but the token belongs to '$profile'. Refusing to save a profile under a mismatched email (mainframe rule 17: profiles keyed by asserted email)."
        }

        Write-Host "Detected GitHub email: $profile"
        if (-not $allowLimited) {
            Assert-GitHubTokenFullAuthority -Token $plainToken -Profile $profile -Source 'GitHub token-add token' | Out-Null
        } else {
            Write-Warning 'Saving a limited GitHub token by explicit request. Default mainframe GitHub profiles should use the full default OAuth scope set.'
        }

        Write-GitHubTokenClassWarning -Token $plainToken
        $login = $null
        Write-ProfileTokenValue -Profile $profile -Token $plainToken -GitHubLogin $login
        Write-ProfileMetadata -Profile $profile -ProfilePath (Get-ProfilePath -Profile $profile) -GitHubLogin $login
        Write-Host "GitHub token profile is ready and active: $profile"
    }

    { $_ -in @('import-current', 'import-current-limited') } {
        if ($remaining.Count -ne 0) {
            throw "Usage: .\github-account.ps1 $command"
        }

        Import-CurrentToken -AllowLimited:($command -eq 'import-current-limited')
    }

    'token-clear' {
        $profile = Get-ProfileOrActive -Profile $(if ($remaining.Count -ge 1) { $remaining[0] } else { $null })
        Remove-ProfileToken -Profile $profile
    }

    'use' {
        if ($remaining.Count -ne 1) {
            throw 'Usage: .\github-account.ps1 use <email>'
        }

        $profile = Normalize-ProfileName -Profile $remaining[0]
        $profilePath = Get-ProfilePath -Profile $profile
        if (-not (Test-Path -LiteralPath $profilePath)) {
            throw "GitHub profile does not exist yet: $profile"
        }

        Set-ActiveProfile -Profile $profile
        Write-Host "Active GitHub profile: $profile"
    }

    'scope-add' {
        $usage = 'Usage: .\github-account.ps1 scope-add [email] <scope[,scope]...>'
        $resolved = Resolve-GitHubProfileAndScopeArgs -Args $remaining -Usage $usage
        $scopes = Split-GitHubScopes -Values $resolved.Values
        Invoke-GitHubScopeRefresh -Profile $resolved.Profile -Scopes $scopes
    }

    'scope-remove' {
        $usage = 'Usage: .\github-account.ps1 scope-remove [email] <scope[,scope]...>'
        $resolved = Resolve-GitHubProfileAndScopeArgs -Args $remaining -Usage $usage
        $scopes = Split-GitHubScopes -Values $resolved.Values
        Invoke-GitHubScopeRefresh -Profile $resolved.Profile -Scopes $scopes -Remove
    }

    'scope-reset' {
        if ($remaining.Count -gt 1) {
            throw 'Usage: .\github-account.ps1 scope-reset [email]'
        }

        $profile = Get-ProfileOrActive -Profile $(if ($remaining.Count -eq 1) { $remaining[0] } else { $null })
        Invoke-GitHubScopeRefresh -Profile $profile -Scopes @() -Reset
    }

    'run' {
        if ($remaining.Count -lt 1) {
            throw 'Usage: .\github-account.ps1 run [email] <gh args...>'
        }

        if (Test-LooksLikeEmail -Value $remaining[0]) {
            if ($remaining.Count -lt 2) {
                throw 'Usage: .\github-account.ps1 run [email] <gh args...>'
            }

            $profile = Normalize-ProfileName -Profile $remaining[0]
            $ghArgs = @($remaining | Select-Object -Skip 1)
        } else {
            $profile = Get-ProfileOrActive -Profile $null
            $ghArgs = @($remaining)
        }

        Invoke-GhProfile -Profile $profile -GhArgs $ghArgs
    }

    'api' {
        if ($remaining.Count -lt 3) {
            throw 'Usage: .\github-account.ps1 api <email> <GET|POST|PUT|PATCH|DELETE> <api path> [json body]'
        }

        $profile = Normalize-ProfileName -Profile $remaining[0]
        $method = $remaining[1]
        $path = $remaining[2]
        $body = if ($remaining.Count -gt 3) { ($remaining[3..($remaining.Count - 1)] -join ' ') } else { $null }
        ConvertTo-JsonOutput -Value (Invoke-GitHubApi -Profile $profile -Method $method -Path $path -JsonBody $body)
    }

    'whoami' {
        $profile = Get-ProfileOrActive -Profile $(if ($remaining.Count -ge 1) { $remaining[0] } else { $null })
        $user = Invoke-GitHubApi -Profile $profile -Method GET -Path '/user' -JsonBody $null
        [pscustomobject]@{
            login = $user.login
            id = $user.id
            name = $user.name
            html_url = $user.html_url
            type = $user.type
            two_factor_authentication = $user.two_factor_authentication
        } | ConvertTo-Json -Depth 4
    }

    'repos' {
        $profile = Get-ProfileOrActive -Profile $(if ($remaining.Count -ge 1) { $remaining[0] } else { $null })
        $repos = Invoke-GitHubApiPaged -Profile $profile -Path '/user/repos?per_page=100&affiliation=owner,collaborator,organization_member&sort=full_name'
        $repos | ForEach-Object {
            [pscustomobject]@{
                full_name = $_.full_name
                private = $_.private
                fork = $_.fork
                archived = $_.archived
                visibility = $_.visibility
                html_url = $_.html_url
            }
        } | ConvertTo-Json -Depth 8
    }

    'orgs' {
        $profile = Get-ProfileOrActive -Profile $(if ($remaining.Count -ge 1) { $remaining[0] } else { $null })
        ConvertTo-JsonOutput -Value (Invoke-GitHubApiPaged -Profile $profile -Path '/user/orgs?per_page=100')
    }

    'capabilities' {
        $profile = Get-ProfileOrActive -Profile $(if ($remaining.Count -ge 1) { $remaining[0] } else { $null })
        Write-GitHubCapabilities -Profile $profile
    }

    'capabilities-json' {
        $profile = Get-ProfileOrActive -Profile $(if ($remaining.Count -ge 1) { $remaining[0] } else { $null })
        Get-GitHubCapabilities -Profile $profile | ConvertTo-Json -Depth 32
    }

    'authority' {
        if ($remaining.Count -gt 1) {
            throw 'Usage: .\github-account.ps1 authority [email]'
        }

        $profile = Get-ProfileOrActive -Profile $(if ($remaining.Count -eq 1) { $remaining[0] } else { $null })
        Write-GitHubAuthority -Profile $profile
    }

    'authority-json' {
        if ($remaining.Count -gt 1) {
            throw 'Usage: .\github-account.ps1 authority-json [email]'
        }

        $profile = Get-ProfileOrActive -Profile $(if ($remaining.Count -eq 1) { $remaining[0] } else { $null })
        Get-GitHubProfileAuthority -Profile $profile | ConvertTo-Json -Depth 32
    }

    'authority-all-json' {
        if ($remaining.Count -ne 0) {
            throw 'Usage: .\github-account.ps1 authority-all-json'
        }

        if (-not (Test-Path -LiteralPath $accountRoot)) {
            Write-Host '[]'
            return
        }

        @(Get-ChildItem -LiteralPath $accountRoot -Directory -Force |
            Where-Object { $_.Name -match '^[^\s@]+@[^\s@]+\.[^\s@]+$' } |
            Sort-Object Name |
            ForEach-Object { Get-GitHubProfileAuthority -Profile (Get-ProfileName -Directory $_) }) |
            ConvertTo-Json -Depth 32
    }

    'status' {
        $profile = Get-ProfileOrActive -Profile $(if ($remaining.Count -ge 1) { $remaining[0] } else { $null })
        Get-ProfileStatus -Profile $profile | Format-List
    }

    'status-all' {
        if (-not (Test-Path -LiteralPath $accountRoot)) {
            Write-Host 'No GitHub profiles found.'
            return
        }

        $profiles = @(Get-ChildItem -LiteralPath $accountRoot -Directory -Force | Where-Object { $_.Name -match '^[^\s@]+@[^\s@]+\.[^\s@]+$' } | Sort-Object Name)
        if ($profiles.Count -eq 0) {
            Write-Host 'No GitHub profiles found.'
            return
        }

        $profiles |
            ForEach-Object { Get-ProfileStatus -Profile (Get-ProfileName -Directory $_) } |
            Format-Table -AutoSize
    }

    'list' {
        if (-not (Test-Path -LiteralPath $accountRoot)) {
            Write-Host 'No GitHub profiles found.'
            return
        }

        $active = Get-ActiveProfile
        $profiles = @(Get-ChildItem -LiteralPath $accountRoot -Directory -Force | Where-Object { $_.Name -match '^[^\s@]+@[^\s@]+\.[^\s@]+$' } | Sort-Object Name)
        if ($profiles.Count -eq 0) {
            Write-Host 'No GitHub profiles found.'
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
            Write-Host 'No active GitHub email profile set.'
        }
    }

    'path' {
        $profile = Get-ProfileOrActive -Profile $(if ($remaining.Count -ge 1) { $remaining[0] } else { $null })
        Write-Host (Get-ProfilePath -Profile $profile)
    }

    'env' {
        $profile = Get-ProfileOrActive -Profile $(if ($remaining.Count -ge 1) { $remaining[0] } else { $null })
        $profilePath = Get-ProfilePath -Profile $profile
        Write-Host "`$env:GH_CONFIG_DIR = '$profilePath'"
        Write-Host '$env:GH_TOKEN = <profile token if token.txt exists>'
        Write-Host '$env:GITHUB_TOKEN = <profile token if token.txt exists>'
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
