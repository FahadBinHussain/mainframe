$ErrorActionPreference = 'Stop'

$accountRoot = Join-Path $env:APPDATA 'mainframe\accounts\hf'
$currentFile = Join-Path $accountRoot 'current.json'
$defaultHfHome = Join-Path $env:USERPROFILE '.cache\huggingface'

function Show-Usage {
    @(
        'Hugging Face account profile helper',
        '',
        'Profiles are keyed by the Hugging Face account email detected after auth:',
        '  %APPDATA%\mainframe\accounts\hf\<email>',
        '',
        'Hugging Face CLI isolation uses HF_HOME plus profile-local token paths.',
        'This helper clears inherited HF_TOKEN while running a profile unless the',
        'selected profile has its own saved token.',
        '',
        'Usage:',
        '  .\hf-account.ps1 login [hf auth login args...]',
        '  .\hf-account.ps1 token-add',
        '  .\hf-account.ps1 import-current',
        '  .\hf-account.ps1 token-clear [email]',
        '  .\hf-account.ps1 use <email>',
        '  .\hf-account.ps1 run [email] <hf args...>',
        '  .\hf-account.ps1 whoami [email]',
        '  .\hf-account.ps1 auth-list [email]',
        '  .\hf-account.ps1 status [email]',
        '  .\hf-account.ps1 status-all',
        '  .\hf-account.ps1 list',
        '  .\hf-account.ps1 current',
        '  .\hf-account.ps1 path [email]',
        '  .\hf-account.ps1 env [email]',
        '  .\hf-account.ps1 logout [email]',
        '',
        'Examples:',
        '  .\hf-account.ps1 import-current',
        '  .\hf-account.ps1 token-add',
        '  .\hf-account.ps1 whoami user@example.com',
        '  .\hf-account.ps1 run user@example.com models list --author your-hf-account --limit 10',
        '  .\hf-account.ps1 run models list --author your-hf-account --limit 10',
        '  .\hf-account.ps1 run user@example.com repos create your-hf-account/private-dataset --type dataset --private'
    ) -join [Environment]::NewLine | Write-Host
}

function Normalize-ProfileName {
    param([string]$Profile)

    if ([string]::IsNullOrWhiteSpace($Profile)) {
        throw 'Email profile is required.'
    }

    $normalized = $Profile.Trim().ToLowerInvariant()
    if ($normalized -notmatch '^[^\s@]+@[^\s@]+\.[^\s@]+$') {
        throw "Hugging Face profile must be an account email, not a username/project label: $Profile"
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

function Get-PortableTokenPath {
    param([string]$ProfilePath)

    return Join-Path $ProfilePath 'token.txt'
}

function Get-HfTokenPath {
    param([string]$ProfilePath)

    return Join-Path $ProfilePath 'token'
}

function Get-HfStoredTokensPath {
    param([string]$ProfilePath)

    return Join-Path $ProfilePath 'stored_tokens'
}

function Get-DefaultTokenPath {
    return Join-Path $defaultHfHome 'token'
}

function Get-DefaultStoredTokensPath {
    return Join-Path $defaultHfHome 'stored_tokens'
}

function Get-HfCommand {
    $cmd = Get-Command hf -ErrorAction SilentlyContinue
    if ($cmd) {
        return $cmd.Source
    }

    throw 'Hugging Face CLI was not found. Install it with: python -m pip install -U "huggingface_hub[cli]"'
}

function Get-CurlCommand {
    $cmd = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($cmd) {
        return $cmd.Source
    }

    throw 'curl.exe was not found. It is required for Hugging Face email detection on this machine.'
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

function Resolve-HfEmailFromToken {
    param([string]$Token)

    if ([string]::IsNullOrWhiteSpace($Token)) {
        throw 'Hugging Face token is empty.'
    }

    $curl = Get-CurlCommand
    $headerFile = Join-Path $env:TEMP "mainframe-hf-auth-$([Guid]::NewGuid().ToString('N')).txt"
    try {
        "Authorization: Bearer $($Token.Trim())" | Set-Content -LiteralPath $headerFile -NoNewline -Encoding ASCII
        $jsonText = & $curl -sS -H "@$headerFile" -H 'User-Agent: mainframe-hf-email-detect' 'https://huggingface.co/api/whoami-v2'
        if ($LASTEXITCODE -ne 0) {
            throw "Hugging Face email detection failed with curl exit code $LASTEXITCODE"
        }

        $json = $jsonText | ConvertFrom-Json
        if (-not $json.email) {
            throw 'Hugging Face email detection failed: /api/whoami-v2 did not return an email.'
        }

        return Normalize-ProfileName -Profile ([string]$json.email)
    } finally {
        Remove-Item -LiteralPath $headerFile -Force -ErrorAction SilentlyContinue
    }
}

function Write-ProfileMetadata {
    param(
        [string]$Profile,
        [string]$ProfilePath
    )

    New-Item -ItemType Directory -Force -Path $ProfilePath | Out-Null
    [ordered]@{
        tool = 'hf'
        service = 'huggingface.co'
        profile = $Profile
        hfHome = $ProfilePath
        tokenPath = (Get-HfTokenPath -ProfilePath $ProfilePath)
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

function Write-ProfileTokenValue {
    param(
        [string]$Profile,
        [string]$Token
    )

    if ([string]::IsNullOrWhiteSpace($Token)) {
        throw 'Hugging Face token is empty.'
    }

    $normalized = Normalize-ProfileName -Profile $Profile
    $profilePath = Get-ProfilePath -Profile $normalized
    New-Item -ItemType Directory -Force -Path $profilePath | Out-Null
    $Token.Trim() | Set-Content -LiteralPath (Get-PortableTokenPath -ProfilePath $profilePath) -NoNewline -Encoding UTF8
    $Token.Trim() | Set-Content -LiteralPath (Get-HfTokenPath -ProfilePath $profilePath) -NoNewline -Encoding UTF8
    Write-ProfileMetadata -Profile $normalized -ProfilePath $profilePath
    Set-ActiveProfile -Profile $normalized
}

function Write-ProfileToken {
    param(
        [string]$Profile,
        [Security.SecureString]$Token
    )

    Write-ProfileTokenValue -Profile $Profile -Token (Convert-SecureStringToPlainText -SecureString $Token)
}

function Read-ProfileToken {
    param([string]$Profile)

    $normalized = Normalize-ProfileName -Profile $Profile
    $profilePath = Get-ProfilePath -Profile $normalized
    foreach ($tokenPath in @(
        (Get-PortableTokenPath -ProfilePath $profilePath),
        (Get-HfTokenPath -ProfilePath $profilePath)
    )) {
        if (Test-Path -LiteralPath $tokenPath) {
            $token = (Get-Content -LiteralPath $tokenPath -Raw).Trim()
            if (-not [string]::IsNullOrWhiteSpace($token)) {
                return $token
            }
        }
    }

    return $null
}

function Set-ActiveProfile {
    param([string]$Profile)

    $normalized = Normalize-ProfileName -Profile $Profile
    New-Item -ItemType Directory -Force -Path $accountRoot | Out-Null
    [ordered]@{
        tool = 'hf'
        service = 'huggingface.co'
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
        throw 'No email was provided and no active Hugging Face email profile is set. Run .\hf-account.ps1 use <email>.'
    }

    return Normalize-ProfileName -Profile $active
}

function Invoke-WithHfProfile {
    param(
        [string]$ProfilePath,
        [AllowNull()][string]$Token,
        [scriptblock]$Script
    )

    New-Item -ItemType Directory -Force -Path $ProfilePath | Out-Null
    $oldHfHome = $env:HF_HOME
    $oldHfToken = $env:HF_TOKEN
    $oldHfTokenPath = $env:HF_TOKEN_PATH
    $oldStoredTokensPath = $env:HF_STORED_TOKENS_PATH

    try {
        $env:HF_HOME = $ProfilePath
        $env:HF_TOKEN_PATH = Get-HfTokenPath -ProfilePath $ProfilePath
        $env:HF_STORED_TOKENS_PATH = Get-HfStoredTokensPath -ProfilePath $ProfilePath
        if ([string]::IsNullOrWhiteSpace($Token)) {
            Remove-Item Env:\HF_TOKEN -ErrorAction SilentlyContinue
        } else {
            $env:HF_TOKEN = $Token
        }

        & $Script
    } finally {
        if ([string]::IsNullOrWhiteSpace($oldHfHome)) {
            Remove-Item Env:\HF_HOME -ErrorAction SilentlyContinue
        } else {
            $env:HF_HOME = $oldHfHome
        }

        if ([string]::IsNullOrWhiteSpace($oldHfToken)) {
            Remove-Item Env:\HF_TOKEN -ErrorAction SilentlyContinue
        } else {
            $env:HF_TOKEN = $oldHfToken
        }

        if ([string]::IsNullOrWhiteSpace($oldHfTokenPath)) {
            Remove-Item Env:\HF_TOKEN_PATH -ErrorAction SilentlyContinue
        } else {
            $env:HF_TOKEN_PATH = $oldHfTokenPath
        }

        if ([string]::IsNullOrWhiteSpace($oldStoredTokensPath)) {
            Remove-Item Env:\HF_STORED_TOKENS_PATH -ErrorAction SilentlyContinue
        } else {
            $env:HF_STORED_TOKENS_PATH = $oldStoredTokensPath
        }
    }
}

function Invoke-HfProfile {
    param(
        [string]$Profile,
        [string[]]$HfArgs
    )

    $normalized = Normalize-ProfileName -Profile $Profile
    $profilePath = Get-ProfilePath -Profile $normalized
    if (-not (Test-Path -LiteralPath $profilePath)) {
        throw "Hugging Face profile does not exist yet: $normalized. Run .\hf-account.ps1 token-add or .\hf-account.ps1 import-current first, then use the detected email profile."
    }

    $hf = Get-HfCommand
    $token = Read-ProfileToken -Profile $normalized
    Invoke-WithHfProfile -ProfilePath $profilePath -Token $token -Script {
        & $hf @HfArgs
        if ($LASTEXITCODE -ne 0) {
            throw "hf $($HfArgs -join ' ') failed with exit code $LASTEXITCODE"
        }
    }
}

function Invoke-HfProfileCapture {
    param(
        [string]$Profile,
        [string[]]$HfArgs
    )

    $normalized = Normalize-ProfileName -Profile $Profile
    $profilePath = Get-ProfilePath -Profile $normalized
    $hf = Get-HfCommand
    $token = Read-ProfileToken -Profile $normalized
    $script:hfCaptureOutput = @()
    $script:hfCaptureExitCode = 0
    Invoke-WithHfProfile -ProfilePath $profilePath -Token $token -Script {
        $script:hfCaptureOutput = @(& $hf @HfArgs 2>&1)
        $script:hfCaptureExitCode = $LASTEXITCODE
    }

    $output = @($script:hfCaptureOutput)
    $exitCode = $script:hfCaptureExitCode
    Remove-Variable -Name hfCaptureOutput -Scope Script -ErrorAction SilentlyContinue
    Remove-Variable -Name hfCaptureExitCode -Scope Script -ErrorAction SilentlyContinue

    if ($exitCode -ne 0) {
        throw "hf $($HfArgs -join ' ') failed with exit code $exitCode"
    }

    return ($output -join [Environment]::NewLine)
}

function Import-CurrentToken {
    param()

    $token = $null
    $source = $null
    if (-not [string]::IsNullOrWhiteSpace($env:HF_TOKEN)) {
        $token = $env:HF_TOKEN.Trim()
        $source = 'HF_TOKEN environment variable'
    } else {
        $defaultTokenPath = Get-DefaultTokenPath
        if (Test-Path -LiteralPath $defaultTokenPath) {
            $token = (Get-Content -LiteralPath $defaultTokenPath -Raw).Trim()
            $source = $defaultTokenPath
        }
    }

    if ([string]::IsNullOrWhiteSpace($token)) {
        throw 'No current Hugging Face token was found in HF_TOKEN or the default token path.'
    }

    $normalized = Resolve-HfEmailFromToken -Token $token
    Write-ProfileTokenValue -Profile $normalized -Token $token
    $profilePath = Get-ProfilePath -Profile $normalized
    $defaultStoredTokens = Get-DefaultStoredTokensPath
    if (Test-Path -LiteralPath $defaultStoredTokens) {
        Copy-Item -LiteralPath $defaultStoredTokens -Destination (Get-HfStoredTokensPath -ProfilePath $profilePath) -Force
    }

    Write-ProfileMetadata -Profile $normalized -ProfilePath $profilePath
    Write-Host "Imported current Hugging Face token into profile: $normalized"
    Write-Host "Source: $source"
}

function Get-ProfileStatus {
    param([string]$Profile)

    $normalized = Normalize-ProfileName -Profile $Profile
    $profilePath = Get-ProfilePath -Profile $normalized
    $metadata = Read-ProfileMetadata -ProfilePath $profilePath
    $token = Read-ProfileToken -Profile $normalized
    $exists = Test-Path -LiteralPath $profilePath
    $hasPortableToken = Test-Path -LiteralPath (Get-PortableTokenPath -ProfilePath $profilePath)
    $hasHfToken = Test-Path -LiteralPath (Get-HfTokenPath -ProfilePath $profilePath)
    $hasStoredTokens = Test-Path -LiteralPath (Get-HfStoredTokensPath -ProfilePath $profilePath)
    $active = Get-ActiveProfile

    [pscustomobject]@{
        Profile = $normalized
        Exists = $exists
        IsActive = ($active -eq $normalized)
        HasPortableToken = $hasPortableToken
        HasHfToken = $hasHfToken
        HasStoredTokens = $hasStoredTokens
        TokenStatus = if ([string]::IsNullOrWhiteSpace($token)) { 'missing' } else { 'present' }
        HfHome = $profilePath
        State = if (-not $exists) { 'missing-profile' } elseif (-not ($hasPortableToken -or $hasHfToken)) { 'missing-token' } elseif ($active -eq $normalized) { 'active' } else { 'configured' }
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

function Move-ProfileDirectory {
    param(
        [string]$SourcePath,
        [string]$Profile
    )

    $targetPath = Get-ProfilePath -Profile $Profile
    if ((Test-Path -LiteralPath $targetPath) -and ((Resolve-Path -LiteralPath $targetPath).Path -ne (Resolve-Path -LiteralPath $SourcePath).Path)) {
        $backupPath = "$targetPath.backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Move-Item -LiteralPath $targetPath -Destination $backupPath
        Write-Warning "Existing Hugging Face profile was moved to: $backupPath"
    }

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $targetPath) | Out-Null
    if (-not (Test-Path -LiteralPath $targetPath)) {
        Move-Item -LiteralPath $SourcePath -Destination $targetPath
    }

    return $targetPath
}

function Remove-ProfileToken {
    param([string]$Profile)

    $normalized = Normalize-ProfileName -Profile $Profile
    $profilePath = Get-ProfilePath -Profile $normalized
    $removed = $false
    foreach ($tokenPath in @(
        (Get-PortableTokenPath -ProfilePath $profilePath),
        (Get-HfTokenPath -ProfilePath $profilePath),
        (Get-HfStoredTokensPath -ProfilePath $profilePath)
    )) {
        if (Test-Path -LiteralPath $tokenPath) {
            Remove-Item -LiteralPath $tokenPath -Force
            $removed = $true
        }
    }

    if ($removed) {
        Write-Host "Removed saved Hugging Face token profile for: $normalized"
    } else {
        Write-Host "No saved Hugging Face token profile found for: $normalized"
    }
}

function Remove-Profile {
    param([string]$Profile)

    $normalized = Normalize-ProfileName -Profile $Profile
    $profilePath = Get-ProfilePath -Profile $normalized
    if (-not (Test-Path -LiteralPath $profilePath)) {
        Write-Host "Hugging Face profile does not exist: $normalized"
        return
    }

    $backupPath = "$profilePath.logged-out-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Move-Item -LiteralPath $profilePath -Destination $backupPath
    Write-Host "Hugging Face profile moved to: $backupPath"

    $active = Get-ActiveProfile
    if ($active -eq $normalized -and (Test-Path -LiteralPath $currentFile)) {
        Remove-Item -LiteralPath $currentFile
        Write-Host 'Active Hugging Face profile cleared.'
    }
}

$command = if ($args.Count -gt 0) { $args[0].ToLowerInvariant() } else { 'help' }
$remaining = @($args | Select-Object -Skip 1)

switch ($command) {
    'help' {
        Show-Usage
    }

    'login' {
        $loginArgs = @($remaining)
        $hf = Get-HfCommand
        $pendingRoot = Join-Path $env:TEMP 'mainframe-hf-login'
        New-Item -ItemType Directory -Force -Path $pendingRoot | Out-Null
        $profilePath = Join-Path $pendingRoot "pending-$([Guid]::NewGuid().ToString('N'))"
        $pendingPath = $profilePath
        New-Item -ItemType Directory -Force -Path $profilePath | Out-Null
        try {
            Write-Host 'Starting Hugging Face CLI login. The saved profile will be the detected account email.'
            Invoke-WithHfProfile -ProfilePath $profilePath -Token $null -Script {
                & $hf auth login @loginArgs
                if ($LASTEXITCODE -ne 0) {
                    throw "hf auth login failed with exit code $LASTEXITCODE"
                }
            }

            $token = $null
            foreach ($tokenPath in @(
                (Get-HfTokenPath -ProfilePath $profilePath),
                (Get-PortableTokenPath -ProfilePath $profilePath)
            )) {
                if (Test-Path -LiteralPath $tokenPath) {
                    $token = (Get-Content -LiteralPath $tokenPath -Raw).Trim()
                    if (-not [string]::IsNullOrWhiteSpace($token)) {
                        break
                    }
                }
            }

            if ([string]::IsNullOrWhiteSpace($token)) {
                throw 'Hugging Face login finished, but no token was saved in the profile path.'
            }

            $profile = Resolve-HfEmailFromToken -Token $token
            $profilePath = Move-ProfileDirectory -SourcePath $profilePath -Profile $profile
            Write-ProfileMetadata -Profile $profile -ProfilePath $profilePath
            Set-ActiveProfile -Profile $profile
            Write-Host "Hugging Face email profile is ready and active: $profile"
        } catch {
            if (Test-Path -LiteralPath $pendingPath) {
                Remove-Item -LiteralPath $pendingPath -Recurse -Force -ErrorAction SilentlyContinue
            }

            throw
        }
    }

    { $_ -in @('token-add', 'add') } {
        if ($remaining.Count -ne 0) {
            throw 'Usage: .\hf-account.ps1 token-add'
        }

        Write-Host 'Paste a Hugging Face access token. Input is hidden; mainframe will save it under the detected account email.'
        $token = Read-Host 'Hugging Face token' -AsSecureString
        $plainToken = Convert-SecureStringToPlainText -SecureString $token
        $profile = Resolve-HfEmailFromToken -Token $plainToken
        Write-ProfileTokenValue -Profile $profile -Token $plainToken
        Write-ProfileMetadata -Profile $profile -ProfilePath (Get-ProfilePath -Profile $profile)
        Write-Host "Hugging Face email profile is ready and active: $profile"
    }

    'import-current' {
        if ($remaining.Count -ne 0) {
            throw 'Usage: .\hf-account.ps1 import-current'
        }

        Import-CurrentToken
    }

    'token-clear' {
        $profile = Get-ProfileOrActive -Profile $(if ($remaining.Count -ge 1) { $remaining[0] } else { $null })
        Remove-ProfileToken -Profile $profile
    }

    'use' {
        if ($remaining.Count -ne 1) {
            throw 'Usage: .\hf-account.ps1 use <email>'
        }

        $profile = Normalize-ProfileName -Profile $remaining[0]
        $profilePath = Get-ProfilePath -Profile $profile
        if (-not (Test-Path -LiteralPath $profilePath)) {
            throw "Hugging Face profile does not exist yet: $profile"
        }

        Set-ActiveProfile -Profile $profile
        Write-Host "Active Hugging Face profile: $profile"
    }

    'run' {
        if ($remaining.Count -lt 1) {
            throw 'Usage: .\hf-account.ps1 run [email] <hf args...>'
        }

        if (Test-LooksLikeEmail -Value $remaining[0]) {
            if ($remaining.Count -lt 2) {
                throw 'Usage: .\hf-account.ps1 run [email] <hf args...>'
            }

            $profile = Normalize-ProfileName -Profile $remaining[0]
            $hfArgs = @($remaining | Select-Object -Skip 1)
        } else {
            $profile = Get-ProfileOrActive -Profile $null
            $hfArgs = @($remaining)
        }

        Invoke-HfProfile -Profile $profile -HfArgs $hfArgs
    }

    'whoami' {
        $profile = Get-ProfileOrActive -Profile $(if ($remaining.Count -ge 1) { $remaining[0] } else { $null })
        Invoke-HfProfile -Profile $profile -HfArgs @('auth', 'whoami', '--format', 'json')
    }

    'auth-list' {
        $profile = Get-ProfileOrActive -Profile $(if ($remaining.Count -ge 1) { $remaining[0] } else { $null })
        Invoke-HfProfile -Profile $profile -HfArgs @('auth', 'list')
    }

    'status' {
        $profile = Get-ProfileOrActive -Profile $(if ($remaining.Count -ge 1) { $remaining[0] } else { $null })
        Get-ProfileStatus -Profile $profile | Format-List
    }

    'status-all' {
        if (-not (Test-Path -LiteralPath $accountRoot)) {
            Write-Host 'No Hugging Face profiles found.'
            return
        }

        $profiles = @(Get-ChildItem -LiteralPath $accountRoot -Directory -Force | Where-Object { $_.Name -match '^[^\s@]+@[^\s@]+\.[^\s@]+$' } | Sort-Object Name)
        if ($profiles.Count -eq 0) {
            Write-Host 'No Hugging Face profiles found.'
            return
        }

        $profiles |
            ForEach-Object { Get-ProfileStatus -Profile (Get-ProfileName -Directory $_) } |
            Format-Table -AutoSize
    }

    'list' {
        if (-not (Test-Path -LiteralPath $accountRoot)) {
            Write-Host 'No Hugging Face profiles found.'
            return
        }

        $active = Get-ActiveProfile
        $profiles = @(Get-ChildItem -LiteralPath $accountRoot -Directory -Force | Where-Object { $_.Name -match '^[^\s@]+@[^\s@]+\.[^\s@]+$' } | Sort-Object Name)
        if ($profiles.Count -eq 0) {
            Write-Host 'No Hugging Face profiles found.'
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
            Write-Host 'No active Hugging Face email profile set.'
        }
    }

    'path' {
        $profile = Get-ProfileOrActive -Profile $(if ($remaining.Count -ge 1) { $remaining[0] } else { $null })
        Write-Host (Get-ProfilePath -Profile $profile)
    }

    'env' {
        $profile = Get-ProfileOrActive -Profile $(if ($remaining.Count -ge 1) { $remaining[0] } else { $null })
        $profilePath = Get-ProfilePath -Profile $profile
        Write-Host "`$env:HF_HOME = '$profilePath'"
        Write-Host "`$env:HF_TOKEN_PATH = '$(Get-HfTokenPath -ProfilePath $profilePath)'"
        Write-Host "`$env:HF_STORED_TOKENS_PATH = '$(Get-HfStoredTokensPath -ProfilePath $profilePath)'"
        Write-Host 'Do not set machine-level HF_TOKEN when using profile-isolated Hugging Face auth.'
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
