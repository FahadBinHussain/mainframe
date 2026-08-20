$ErrorActionPreference = 'Stop'

$accountRoot = Join-Path $env:APPDATA 'mainframe\accounts\render'
$currentFile = Join-Path $accountRoot 'current.json'

function Show-Usage {
    @(
        'Render account profile helper',
        '',
        'Profiles are keyed by account email only and stored in:',
        '  %APPDATA%\mainframe\accounts\render\<email>',
        '',
        'Render CLI isolation uses the official RENDER_CLI_CONFIG_PATH file setting.',
        'This helper clears any inherited RENDER_API_KEY while running profiles so a',
        'machine-level API key cannot silently override the selected profile.',
        '',
        'API key profiles store the key and use it directly with Render REST API.',
        'Email is auto-detected from the API key via /v1/owners endpoint.',
        '',
        'Usage:',
        '  .\render-account.ps1 login [email] [render login args...]',
        '  .\render-account.ps1 api-key-add [email]',
        '  .\render-account.ps1 use <email>',
        '  .\render-account.ps1 run [email] <render args...>',
        '  .\render-account.ps1 whoami [email]',
        '  .\render-account.ps1 workspaces [email]',
        '  .\render-account.ps1 services [email]',
        '  .\render-account.ps1 psql <email> <render psql args...>',
        '  .\render-account.ps1 status [email]',
        '  .\render-account.ps1 status-all',
        '  .\render-account.ps1 list',
        '  .\render-account.ps1 current',
        '  .\render-account.ps1 path [email]',
        '  .\render-account.ps1 env [email]',
        '  .\render-account.ps1 logout <email>',
        '',
        'Examples:',
        '  .\render-account.ps1 login',
        '  .\render-account.ps1 login user@example.com',
        '  .\render-account.ps1 api-key-add',
        '  .\render-account.ps1 api-key-add user@example.com',
        '  .\render-account.ps1 use user@example.com',
        '  .\render-account.ps1 whoami user@example.com',
        '  .\render-account.ps1 run user@example.com workspaces -o json',
        '  .\render-account.ps1 run workspaces -o json',
        '  .\render-account.ps1 run user@example.com services -o json --confirm',
        '  .\render-account.ps1 psql user@example.com my-database -c "SELECT NOW();" -o text'
    ) -join [Environment]::NewLine | Write-Host
}

function Normalize-ProfileName {
    param([string]$Profile)

    if ([string]::IsNullOrWhiteSpace($Profile)) {
        throw 'Email profile is required.'
    }

    $normalized = $Profile.Trim().ToLowerInvariant()
    if ($normalized -notmatch '^[^\s@]+@[^\s@]+\.[^\s@]+$') {
        throw "Render profile must be an account email, not a label or username: $Profile"
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

function Get-ConfigPath {
    param([string]$ProfilePath)

    return Join-Path $ProfilePath 'cli.yaml'
}

function Get-ApiKeyPath {
    param([string]$ProfilePath)

    return Join-Path $ProfilePath 'api-key.txt'
}

function Get-RenderApiEmail {
    param([string]$ApiKey)

    if ([string]::IsNullOrWhiteSpace($ApiKey)) {
        throw 'Render API key is empty.'
    }

    try {
        $response = Invoke-RestMethod -Method GET -Uri 'https://api.render.com/v1/owners' -Headers @{ Authorization = "Bearer $ApiKey" } -ErrorAction Stop
        if ($response -and $response.Count -gt 0 -and $response[0].owner -and $response[0].owner.email) {
            $email = $response[0].owner.email
            $normalized = Normalize-ProfileName -Profile $email
            return $normalized
        }
    } catch {
        throw "Render API key verification failed. $($_.Exception.Message)"
    }

    throw 'Render API key verification succeeded, but the account email could not be detected.'
}

function Write-ProfileApiKey {
    param(
        [AllowNull()][string]$Email,
        [Security.SecureString]$ApiKey
    )

    $plainKey = $null
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($ApiKey)
    try {
        $plainKey = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }

    $detectedEmail = Get-RenderApiEmail -ApiKey $plainKey
    if (-not [string]::IsNullOrWhiteSpace($Email)) {
        $requestedEmail = Normalize-ProfileName -Profile $Email
        if ($requestedEmail -ne $detectedEmail) {
            throw "Render API key belongs to $detectedEmail, not $requestedEmail."
        }
    }

    $profilePath = Get-ProfilePath $detectedEmail
    New-Item -ItemType Directory -Force -Path $profilePath | Out-Null
    $plainKey.Trim() | Set-Content -LiteralPath (Get-ApiKeyPath -ProfilePath $profilePath) -NoNewline -Encoding UTF8
    Write-ProfileMetadata -Profile $detectedEmail -ProfilePath $profilePath
    Set-ActiveProfile -Profile $detectedEmail
    Write-Host "Render API key profile is ready and active: $detectedEmail"
}

function Get-RenderCommand {
    $cmd = Get-Command render -ErrorAction SilentlyContinue
    if ($cmd) {
        return $cmd.Source
    }

    throw 'Render CLI was not found. Install it from https://render.com/docs/cli. No official Scoop bucket package was found on this machine.'
}

function Write-ProfileMetadata {
    param(
        [string]$Profile,
        [string]$ProfilePath
    )

    New-Item -ItemType Directory -Force -Path $ProfilePath | Out-Null
    [ordered]@{
        tool = 'render'
        profile = $Profile
        configPath = (Get-ConfigPath -ProfilePath $ProfilePath)
        updatedAt = (Get-Date).ToString('o')
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $ProfilePath 'profile.json') -Encoding UTF8
}

function Set-ActiveProfile {
    param([string]$Profile)

    $normalized = Normalize-ProfileName -Profile $Profile
    New-Item -ItemType Directory -Force -Path $accountRoot | Out-Null
    [ordered]@{
        tool = 'render'
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
        throw 'No email was provided and no active Render email profile is set. Run .\render-account.ps1 use <email>.'
    }

    return Normalize-ProfileName -Profile $active
}

function Invoke-WithRenderProfile {
    param(
        [string]$ProfilePath,
        [scriptblock]$Script
    )

    New-Item -ItemType Directory -Force -Path $ProfilePath | Out-Null
    $configPath = Get-ConfigPath -ProfilePath $ProfilePath

    $oldConfigPath = $env:RENDER_CLI_CONFIG_PATH
    $oldApiKey = $env:RENDER_API_KEY
    try {
        $env:RENDER_CLI_CONFIG_PATH = $configPath
        Remove-Item Env:\RENDER_API_KEY -ErrorAction SilentlyContinue
        & $Script
    } finally {
        if ([string]::IsNullOrWhiteSpace($oldConfigPath)) {
            Remove-Item Env:\RENDER_CLI_CONFIG_PATH -ErrorAction SilentlyContinue
        } else {
            $env:RENDER_CLI_CONFIG_PATH = $oldConfigPath
        }

        if ([string]::IsNullOrWhiteSpace($oldApiKey)) {
            Remove-Item Env:\RENDER_API_KEY -ErrorAction SilentlyContinue
        } else {
            $env:RENDER_API_KEY = $oldApiKey
        }
    }
}

function Invoke-RenderProfileCapture {
    param(
        [string]$ProfilePath,
        [string[]]$RenderArgs
    )

    $render = Get-RenderCommand
    $script:renderCaptureOutput = @()
    $script:renderCaptureExitCode = 0
    Invoke-WithRenderProfile -ProfilePath $ProfilePath -Script {
        $script:renderCaptureOutput = @(& $render @RenderArgs 2>&1)
        $script:renderCaptureExitCode = $LASTEXITCODE
    }

    $output = @($script:renderCaptureOutput)
    $exitCode = $script:renderCaptureExitCode
    Remove-Variable -Name renderCaptureOutput -Scope Script -ErrorAction SilentlyContinue
    Remove-Variable -Name renderCaptureExitCode -Scope Script -ErrorAction SilentlyContinue

    if ($exitCode -ne 0) {
        $output | ForEach-Object { Write-Host $_ }
        throw "render $($RenderArgs -join ' ') failed with exit code $exitCode"
    }

    return ($output -join [Environment]::NewLine)
}

function Find-ProfileNameInText {
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }

    $emailMatch = [regex]::Match($Text, '[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($emailMatch.Success) {
        return Normalize-ProfileName -Profile $emailMatch.Value
    }

    return $null
}

function Find-ProfileNameInObject {
    param([AllowNull()]$Value)

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [string]) {
        return Find-ProfileNameInText -Text $Value
    }

    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        foreach ($item in $Value) {
            $profile = Find-ProfileNameInObject -Value $item
            if ($profile) {
                return $profile
            }
        }
        return $null
    }

    foreach ($propertyName in @('email', 'Email', 'userEmail', 'UserEmail')) {
        if ($Value.PSObject.Properties.Name -contains $propertyName) {
            $candidate = [string]$Value.$propertyName
            if (-not [string]::IsNullOrWhiteSpace($candidate)) {
                try {
                    return Normalize-ProfileName -Profile $candidate
                } catch {
                    $profile = Find-ProfileNameInText -Text $candidate
                    if ($profile) {
                        return $profile
                    }
                }
            }
        }
    }

    return Find-ProfileNameInText -Text ($Value | ConvertTo-Json -Depth 8 -Compress)
}

function Resolve-LoggedInRenderProfile {
    param([string]$ProfilePath)

    $jsonText = Invoke-RenderProfileCapture -ProfilePath $ProfilePath -RenderArgs @('whoami', '-o', 'json')
    if (-not [string]::IsNullOrWhiteSpace($jsonText)) {
        try {
            $json = $jsonText | ConvertFrom-Json
            $profile = Find-ProfileNameInObject -Value $json
            if ($profile) {
                return $profile
            }
        } catch {
            $profile = Find-ProfileNameInText -Text $jsonText
            if ($profile) {
                return $profile
            }
        }
    }

    $text = Invoke-RenderProfileCapture -ProfilePath $ProfilePath -RenderArgs @('whoami', '-o', 'text')
    return Find-ProfileNameInText -Text $text
}

function Invoke-RenderProfile {
    param(
        [string]$Profile,
        [string[]]$RenderArgs
    )

    $normalized = Normalize-ProfileName -Profile $Profile
    $profilePath = Get-ProfilePath -Profile $normalized
    if (-not (Test-Path -LiteralPath $profilePath)) {
        throw "Render profile does not exist yet: $normalized. Run .\render-account.ps1 login $normalized first."
    }

    $render = Get-RenderCommand
    Invoke-WithRenderProfile -ProfilePath $profilePath -Script {
        & $render @RenderArgs
        if ($LASTEXITCODE -ne 0) {
            throw "render $($RenderArgs -join ' ') failed with exit code $LASTEXITCODE"
        }
    }
}

function Get-ProfileStatus {
    param([string]$Profile)

    $normalized = Normalize-ProfileName -Profile $Profile
    $profilePath = Get-ProfilePath -Profile $normalized
    $configPath = Get-ConfigPath -ProfilePath $profilePath
    $apiKeyPath = Get-ApiKeyPath -ProfilePath $profilePath
    $exists = Test-Path -LiteralPath $profilePath
    $hasConfig = Test-Path -LiteralPath $configPath
    $hasApiKey = Test-Path -LiteralPath $apiKeyPath
    $active = Get-ActiveProfile

    [pscustomobject]@{
        Profile = $normalized
        Exists = $exists
        IsActive = ($active -eq $normalized)
        ConfigPath = $configPath
        HasConfig = $hasConfig
        HasApiKey = $hasApiKey
        State = if (-not $exists) { 'missing-profile' } elseif (-not $hasConfig -and -not $hasApiKey) { 'missing-cli-config' } elseif ($hasApiKey) { 'api-key' } else { 'configured' }
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
        Write-Host "Render profile does not exist: $normalized"
        return
    }

    $backupPath = "$profilePath.logged-out-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Move-Item -LiteralPath $profilePath -Destination $backupPath
    Write-Host "Render profile moved to: $backupPath"

    $active = Get-ActiveProfile
    if ($active -eq $normalized -and (Test-Path -LiteralPath $currentFile)) {
        Remove-Item -LiteralPath $currentFile
        Write-Host 'Active Render profile cleared.'
    }
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
            $loginArgs = @($remaining)
        }

        $render = Get-RenderCommand
        $pendingRoot = Join-Path $env:TEMP 'mainframe-render-login'
        New-Item -ItemType Directory -Force -Path $pendingRoot | Out-Null
        $profilePath = if ($profile) {
            Get-ProfilePath -Profile $profile
        } else {
            Join-Path $pendingRoot "pending-$([Guid]::NewGuid().ToString('N'))"
        }
        New-Item -ItemType Directory -Force -Path $profilePath | Out-Null

        $displayProfile = if ($profile) { $profile } else { 'auto-detect email after login' }
        Write-Host "Opening Render CLI browser login for profile: $displayProfile"
        Invoke-WithRenderProfile -ProfilePath $profilePath -Script {
            & $render login @loginArgs
            if ($LASTEXITCODE -ne 0) {
                throw "render login failed with exit code $LASTEXITCODE"
            }
        }

        if (-not $profile) {
            $profile = Resolve-LoggedInRenderProfile -ProfilePath $profilePath
            if (-not $profile) {
                throw 'Login succeeded, but Render account email could not be detected automatically. Refusing to save a label, username, account name, or account ID fallback.'
            }

            $targetPath = Get-ProfilePath -Profile $profile
            if ((Test-Path -LiteralPath $targetPath) -and ((Resolve-Path -LiteralPath $targetPath).Path -ne (Resolve-Path -LiteralPath $profilePath).Path)) {
                $backupPath = "$targetPath.backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
                Move-Item -LiteralPath $targetPath -Destination $backupPath
                Write-Warning "Existing Render profile was moved to: $backupPath"
            }

            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $targetPath) | Out-Null
            if (-not (Test-Path -LiteralPath $targetPath)) {
                Move-Item -LiteralPath $profilePath -Destination $targetPath
            }

            $profilePath = $targetPath
            Write-Host "Detected Render email: $profile"
        }

        Write-ProfileMetadata -Profile $profile -ProfilePath $profilePath
        Set-ActiveProfile -Profile $profile
        Write-Host "Render CLI profile is ready and active: $profile"
    }

    'api-key-add' {
        if ($remaining.Count -gt 2) {
            throw 'Usage: .\render-account.ps1 api-key-add [email] [api-key]'
        }

        $email = if ($remaining.Count -ge 1 -and (Test-LooksLikeEmail -Value $remaining[0])) { Normalize-ProfileName -Profile $remaining[0] } else { $null }
        $apiKeyArg = if ($email -and $remaining.Count -eq 2) { $remaining[1] } elseif (-not $email -and $remaining.Count -eq 1) { $remaining[0] } else { $null }

        $apiKey = $null
        if ($apiKeyArg) {
            $apiKey = ConvertTo-SecureString -String $apiKeyArg -AsPlainText -Force
        } else {
            Write-Host 'Paste a Render API key (starts with rnd_). The value will not be printed.'
            $apiKey = Read-Host -AsSecureString 'Render API key'
        }
        Write-ProfileApiKey -Email $email -ApiKey $apiKey
    }

    'use' {
        if ($remaining.Count -ne 1) {
            throw 'Usage: .\render-account.ps1 use <email>'
        }

        $profile = Normalize-ProfileName -Profile $remaining[0]
        $profilePath = Get-ProfilePath -Profile $profile
        if (-not (Test-Path -LiteralPath $profilePath)) {
            throw "Render profile does not exist yet: $profile"
        }

        Set-ActiveProfile -Profile $profile
        Write-Host "Active Render profile: $profile"
    }

    'run' {
        if ($remaining.Count -lt 1) {
            throw 'Usage: .\render-account.ps1 run [email] <render args...>'
        }

        if (Test-LooksLikeEmail -Value $remaining[0]) {
            if ($remaining.Count -lt 2) {
                throw 'Usage: .\render-account.ps1 run [email] <render args...>'
            }

            $profile = Normalize-ProfileName -Profile $remaining[0]
            $renderArgs = @($remaining | Select-Object -Skip 1)
        } else {
            $profile = Get-ProfileOrActive -Profile $null
            $renderArgs = @($remaining)
        }

        Invoke-RenderProfile -Profile $profile -RenderArgs $renderArgs
    }

    'whoami' {
        $profile = Get-ProfileOrActive -Profile $(if ($remaining.Count -ge 1) { $remaining[0] } else { $null })
        Invoke-RenderProfile -Profile $profile -RenderArgs @('whoami')
    }

    'workspaces' {
        $profile = Get-ProfileOrActive -Profile $(if ($remaining.Count -ge 1) { $remaining[0] } else { $null })
        Invoke-RenderProfile -Profile $profile -RenderArgs @('workspaces', '-o', 'json')
    }

    'services' {
        $profile = Get-ProfileOrActive -Profile $(if ($remaining.Count -ge 1) { $remaining[0] } else { $null })
        Invoke-RenderProfile -Profile $profile -RenderArgs @('services', '-o', 'json', '--confirm')
    }

    'psql' {
        if ($remaining.Count -lt 2) {
            throw 'Usage: .\render-account.ps1 psql <email> <render psql args...>'
        }

        $profile = Normalize-ProfileName -Profile $remaining[0]
        $psqlArgs = @('psql') + @($remaining | Select-Object -Skip 1)
        Invoke-RenderProfile -Profile $profile -RenderArgs $psqlArgs
    }

    'status' {
        $profile = Get-ProfileOrActive -Profile $(if ($remaining.Count -ge 1) { $remaining[0] } else { $null })
        Get-ProfileStatus -Profile $profile | Format-List
    }

    'status-all' {
        if (-not (Test-Path -LiteralPath $accountRoot)) {
            Write-Host 'No Render CLI profiles found.'
            return
        }

        $profiles = @(Get-ChildItem -LiteralPath $accountRoot -Directory -Force | Where-Object { $_.Name -match '^[^\s@]+@[^\s@]+\.[^\s@]+$' } | Sort-Object Name)
        if ($profiles.Count -eq 0) {
            Write-Host 'No Render CLI profiles found.'
            return
        }

        $profiles |
            ForEach-Object { Get-ProfileStatus -Profile (Get-ProfileName -Directory $_) } |
            Format-Table -AutoSize
    }

    'list' {
        if (-not (Test-Path -LiteralPath $accountRoot)) {
            Write-Host 'No Render CLI profiles found.'
            return
        }

        $active = Get-ActiveProfile
        $profiles = Get-ChildItem -LiteralPath $accountRoot -Directory | Where-Object { $_.Name -match '^[^\s@]+@[^\s@]+\.[^\s@]+$' } | Sort-Object Name
        if (-not $profiles) {
            Write-Host 'No Render CLI profiles found.'
            return
        }

        foreach ($profileDir in $profiles) {
            $profile = Get-ProfileName -Directory $profileDir
            $prefix = if ($profile -eq $active) { '*' } else { ' ' }
            Write-Host "$prefix $profile"
        }
    }

    'current' {
        $active = Get-ActiveProfile
        if ($active) {
            Write-Host $active
        } else {
            Write-Host 'No active Render email profile set.'
        }
    }

    'path' {
        $profile = Get-ProfileOrActive -Profile $(if ($remaining.Count -ge 1) { $remaining[0] } else { $null })
        Write-Host (Get-ProfilePath -Profile $profile)
    }

    'env' {
        $profile = Get-ProfileOrActive -Profile $(if ($remaining.Count -ge 1) { $remaining[0] } else { $null })
        $profilePath = Get-ProfilePath -Profile $profile
        $configPath = Get-ConfigPath -ProfilePath $profilePath
        $apiKeyPath = Get-ApiKeyPath -ProfilePath $profilePath
        $hasApiKey = Test-Path -LiteralPath $apiKeyPath
        Write-Host "`$env:RENDER_CLI_CONFIG_PATH = '$configPath'"
        Write-Host 'Remove RENDER_API_KEY from the environment when using profile-isolated Render CLI auth.'
        if ($hasApiKey) {
            Write-Host "`$env:RENDER_API_KEY = '<profile api key>' (stored at $apiKeyPath)"
            Write-Host 'Use with Render REST API: https://api.render.com/v1/...'
        } else {
            Write-Host "`$env:RENDER_API_KEY = '<missing api key>'"
        }
    }

    'logout' {
        if ($remaining.Count -ne 1) {
            throw 'Usage: .\render-account.ps1 logout <email>'
        }

        Remove-Profile -Profile $remaining[0]
    }

    default {
        Show-Usage
        throw "Unknown command: $command"
    }
}
