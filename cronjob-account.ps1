$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'vault-secret.psm1') -Force

$accountRoot = Join-Path $env:APPDATA 'mainframe\accounts\cronjob'
$currentFile = Join-Path $accountRoot 'current.json'
$apiEndpoint = 'https://api.cron-job.org'

function Show-Usage {
    @(
        'cron-job.org API account profile helper',
        '',
        'Profiles are keyed by account email only and stored in:',
        '  %APPDATA%\mainframe\accounts\cronjob\<email>',
        '',
        'cron-job.org uses API keys from the Console settings page. This helper',
        'stores one API key per mainframe profile and sends it as a Bearer token.',
        '',
        'Usage:',
        '  .\cronjob-account.ps1 login <email>',
        '  .\cronjob-account.ps1 token-add <email>',
        '  .\cronjob-account.ps1 token-clear [email]',
        '  .\cronjob-account.ps1 use <email>',
        '  .\cronjob-account.ps1 run [email] <GET|PUT|PATCH|DELETE> <api path> [json body]',
        '  .\cronjob-account.ps1 jobs [email]',
        '  .\cronjob-account.ps1 job <email> <job-id>',
        '  .\cronjob-account.ps1 create <email> <url> [title]',
        '  .\cronjob-account.ps1 enable <email> <job-id>',
        '  .\cronjob-account.ps1 disable <email> <job-id>',
        '  .\cronjob-account.ps1 history <email> <job-id>',
        '  .\cronjob-account.ps1 history-item <email> <job-id> <identifier>',
        '  .\cronjob-account.ps1 delete <email> <job-id>',
        '  .\cronjob-account.ps1 export <email> [output-path]',
        '  .\cronjob-account.ps1 import <email> [input-path] [-ConfirmImport] [-Disabled]',
        '  .\cronjob-account.ps1 status [email]',
        '  .\cronjob-account.ps1 status-all',
        '  .\cronjob-account.ps1 list',
        '  .\cronjob-account.ps1 current',
        '  .\cronjob-account.ps1 path [email]',
        '  .\cronjob-account.ps1 env [email]',
        '  .\cronjob-account.ps1 logout [email]',
        '',
        'Examples:',
        '  .\cronjob-account.ps1 login user@example.com',
        '  .\cronjob-account.ps1 token-add user@example.com',
        '  .\cronjob-account.ps1 jobs user@example.com',
        '  .\cronjob-account.ps1 create user@example.com https://example.com/api/cron "Example heartbeat"',
        '  .\cronjob-account.ps1 disable user@example.com 12345',
        '  .\cronjob-account.ps1 export user@example.com',
        '  .\cronjob-account.ps1 import user@example.com -ConfirmImport -Disabled',
        '  .\cronjob-account.ps1 run user@example.com PATCH /jobs/12345 ''{"job":{"enabled":true}}''',
        '  .\cronjob-account.ps1 run PATCH /jobs/12345 ''{"job":{"enabled":true}}'''
    ) -join [Environment]::NewLine | Write-Host
}

function Normalize-ProfileName {
    param([string]$Profile)

    if ([string]::IsNullOrWhiteSpace($Profile)) {
        throw 'Email profile is required.'
    }

    $normalized = $Profile.Trim().ToLowerInvariant()
    if ($normalized -notmatch '^[^\s@]+@[^\s@]+\.[^\s@]+$') {
        throw "cron-job.org profile must be an account email, not a label or username: $Profile"
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

function Get-ProfileTokenPath {
    param([string]$ProfilePath)

    return Join-Path $ProfilePath 'api-key.txt'
}

function Get-DefaultJobsExportPath {
    param([string]$ProfilePath)

    return Join-Path $ProfilePath 'jobs-export.json'
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

function Get-TokenFingerprint {
    param([AllowNull()][string]$Token)

    if ([string]::IsNullOrWhiteSpace($Token)) {
        return $null
    }

    $bytes = [Text.Encoding]::UTF8.GetBytes($Token)
    $hash = [Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
    return (($hash | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0, 12)
}

function Write-ProfileMetadata {
    param(
        [string]$Profile,
        [string]$ProfilePath
    )

    New-Item -ItemType Directory -Force -Path $ProfilePath | Out-Null
    [ordered]@{
        tool = 'cronjob'
        service = 'cron-job.org'
        profile = $Profile
        apiEndpoint = $apiEndpoint
        tokenPath = (Get-ProfileTokenPath -ProfilePath $ProfilePath)
        updatedAt = (Get-Date).ToString('o')
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $ProfilePath 'profile.json') -Encoding UTF8
}

function Write-ProfileToken {
    param(
        [string]$Profile,
        [Security.SecureString]$Token
    )

    $normalized = Normalize-ProfileName -Profile $Profile
    $profilePath = Get-ProfilePath -Profile $normalized
    Write-ProfileMetadata -Profile $normalized -ProfilePath $profilePath
    $plainToken = Convert-SecureStringToPlainText -SecureString $Token
    $userPrefix = ($normalized -split '@')[0]
    Write-VaultSecretToExisting -Email $normalized -NamePattern 'console.cron-job.org' -Header '[api keys]' -Value $plainToken.Trim() -ItemName "console.cron-job.org - $userPrefix" -Username $normalized -Uri 'https://console.cron-job.org/settings/api'
    Set-ActiveProfile -Profile $normalized
}

function Read-ProfileToken {
    param([string]$Profile)

    $normalized = Normalize-ProfileName -Profile $Profile
    $token = Read-VaultSecret -Email $normalized -NamePattern 'console.cron-job.org' -ValueRegex '[A-Za-z0-9+/]{20,}={0,2}'
    if ([string]::IsNullOrWhiteSpace($token)) {
        throw "cron-job.org API key profile does not exist yet: $normalized. Run .\cronjob-account.ps1 token-add $normalized first."
    }

    return $token
}

function Remove-ProfileToken {
    param([string]$Profile)

    $normalized = Normalize-ProfileName -Profile $Profile
    $profilePath = Get-ProfilePath -Profile $normalized
    $tokenPath = Get-ProfileTokenPath -ProfilePath $profilePath
    if (Test-Path -LiteralPath $tokenPath) {
        Remove-Item -LiteralPath $tokenPath -Force
        Write-Host "Removed saved cron-job.org API key profile for: $normalized"
    } else {
        Write-Host "No saved cron-job.org API key profile found for: $normalized"
    }
}

function Set-ActiveProfile {
    param([string]$Profile)

    $normalized = Normalize-ProfileName -Profile $Profile
    New-Item -ItemType Directory -Force -Path $accountRoot | Out-Null
    [ordered]@{
        tool = 'cronjob'
        service = 'cron-job.org'
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
        throw 'No email was provided and no active cron-job.org email profile is set. Run .\cronjob-account.ps1 use <email>.'
    }

    return Normalize-ProfileName -Profile $active
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

function Get-ProfileStatus {
    param([string]$Profile)

    $normalized = Normalize-ProfileName -Profile $Profile
    $profilePath = Get-ProfilePath -Profile $normalized
    $tokenPath = Get-ProfileTokenPath -ProfilePath $profilePath
    $exists = Test-Path -LiteralPath $profilePath
    $token = Read-VaultSecret -Email $normalized -NamePattern 'console.cron-job.org' -ValueRegex '[A-Za-z0-9+/]{20,}={0,2}'
    $hasApiKey = -not [string]::IsNullOrWhiteSpace($token)
    $active = Get-ActiveProfile

    [pscustomobject]@{
        Profile = $normalized
        Exists = $exists
        IsActive = ($active -eq $normalized)
        HasApiKey = $hasApiKey
        ApiKeyFingerprint = Get-TokenFingerprint -Token $token
        ApiEndpoint = $apiEndpoint
        TokenPath = $tokenPath
        State = if (-not $exists) { 'missing-profile' } elseif (-not $hasApiKey) { 'missing-api-key' } elseif ($active -eq $normalized) { 'active' } else { 'configured' }
    }
}

function Get-ApiPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw 'API path is required.'
    }

    if ($Path -match '^https?://') {
        $uri = [uri]$Path
        if ($uri.Host -ne 'api.cron-job.org') {
            throw 'Only https://api.cron-job.org URLs are allowed.'
        }

        return $uri.PathAndQuery
    }

    if ($Path.StartsWith('/')) {
        return $Path
    }

    return "/$Path"
}

function Invoke-CronJobApi {
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
            throw "cron-job.org API $methodUpper $apiPath failed: HTTP $statusCode $statusDescription"
        }

        throw "cron-job.org API $methodUpper $apiPath failed: $($_.Exception.Message)"
    }
}

function ConvertTo-JsonOutput {
    param([AllowNull()]$Value)

    if ($null -eq $Value) {
        Write-Host '{}'
        return
    }

    $Value | ConvertTo-Json -Depth 16
}

function Get-JobDetailsFromResponse {
    param([AllowNull()]$Response)

    if ($null -eq $Response) {
        return $null
    }

    if ($Response.PSObject.Properties.Name -contains 'jobDetails') {
        return $Response.jobDetails
    }

    return $Response
}

function Export-CronJobJobs {
    param(
        [string]$Profile,
        [AllowNull()][string]$OutputPath
    )

    $normalized = Normalize-ProfileName -Profile $Profile
    $profilePath = Get-ProfilePath -Profile $normalized
    if ([string]::IsNullOrWhiteSpace($OutputPath)) {
        $OutputPath = Get-DefaultJobsExportPath -ProfilePath $profilePath
    }
    if (-not [IO.Path]::IsPathRooted($OutputPath)) {
        $OutputPath = Join-Path (Get-Location) $OutputPath
    }

    $jobsResponse = Invoke-CronJobApi -Profile $normalized -Method GET -Path '/jobs' -JsonBody $null
    $jobs = @($jobsResponse.jobs)
    $jobDetails = @()
    foreach ($job in $jobs) {
        if ($null -eq $job.jobId) {
            continue
        }

        $detailsResponse = Invoke-CronJobApi -Profile $normalized -Method GET -Path "/jobs/$($job.jobId)" -JsonBody $null
        $details = Get-JobDetailsFromResponse -Response $detailsResponse
        if ($details) {
            $jobDetails += $details
        }
    }

    $export = [ordered]@{
        tool = 'cronjob'
        service = 'cron-job.org'
        schemaVersion = 1
        profile = $normalized
        apiEndpoint = $apiEndpoint
        exportedAt = (Get-Date).ToString('o')
        note = 'Private cron-job.org job export. URLs, headers, bodies, and basic-auth fields may contain secrets.'
        jobs = @($jobDetails)
    }

    $outputParent = Split-Path -Parent $OutputPath
    if (-not [string]::IsNullOrWhiteSpace($outputParent)) {
        New-Item -ItemType Directory -Force -Path $outputParent | Out-Null
    }
    $export | ConvertTo-Json -Depth 32 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
    Write-Host "Exported $($jobDetails.Count) cron-job.org jobs for $normalized to: $OutputPath"
}

function Get-RemainingArgsWithoutSwitches {
    param(
        [string[]]$Items,
        [string[]]$SwitchNames
    )

    $result = New-Object System.Collections.Generic.List[string]
    foreach ($item in $Items) {
        if ($SwitchNames -contains $item) {
            continue
        }

        $result.Add($item)
    }

    return @($result)
}

function Test-ArgSwitch {
    param(
        [string[]]$Items,
        [string[]]$Names
    )

    foreach ($item in $Items) {
        if ($Names -contains $item) {
            return $true
        }
    }

    return $false
}

function ConvertTo-ImportJobPayload {
    param(
        [object]$Job,
        [bool]$Disabled
    )

    $readOnlyFields = @('jobId', 'lastStatus', 'lastDuration', 'lastExecution', 'nextExecution', 'type')
    $jobPayload = [ordered]@{}
    foreach ($property in $Job.PSObject.Properties) {
        if ($readOnlyFields -contains $property.Name) {
            continue
        }

        if ($property.Name -eq 'enabled' -and $Disabled) {
            $jobPayload[$property.Name] = $false
            continue
        }

        $jobPayload[$property.Name] = $property.Value
    }

    if ($Disabled -and -not ($jobPayload.Keys -contains 'enabled')) {
        $jobPayload['enabled'] = $false
    }

    return ([ordered]@{ job = $jobPayload } | ConvertTo-Json -Depth 32 -Compress)
}

function Import-CronJobJobs {
    param(
        [string]$Profile,
        [AllowNull()][string]$InputPath,
        [bool]$ConfirmImport,
        [bool]$Disabled
    )

    $normalized = Normalize-ProfileName -Profile $Profile
    $profilePath = Get-ProfilePath -Profile $normalized
    if ([string]::IsNullOrWhiteSpace($InputPath)) {
        $InputPath = Get-DefaultJobsExportPath -ProfilePath $profilePath
    }

    if (-not (Test-Path -LiteralPath $InputPath)) {
        throw "cron-job.org jobs export not found: $InputPath"
    }

    $export = Get-Content -LiteralPath $InputPath -Raw | ConvertFrom-Json
    $jobs = @($export.jobs)
    if (-not $ConfirmImport) {
        Write-Host "Dry run: $($jobs.Count) cron-job.org jobs would be imported for $normalized from: $InputPath"
        Write-Host 'Pass -ConfirmImport to create jobs. Pass -Disabled to force imported jobs to start disabled.'
        return
    }

    $createdJobIds = @()
    foreach ($job in $jobs) {
        $payload = ConvertTo-ImportJobPayload -Job $job -Disabled $Disabled
        $result = Invoke-CronJobApi -Profile $normalized -Method PUT -Path '/jobs' -JsonBody $payload
        if ($result.jobId) {
            $createdJobIds += [int]$result.jobId
        }
    }

    [pscustomobject]@{
        Profile = $normalized
        Imported = $jobs.Count
        CreatedJobIds = @($createdJobIds)
        Disabled = $Disabled
    } | ConvertTo-Json -Depth 8
}

function New-EveryMinuteJobPayload {
    param(
        [string]$Url,
        [AllowNull()][string]$Title
    )

    if ([string]::IsNullOrWhiteSpace($Url)) {
        throw 'URL is required.'
    }

    $job = [ordered]@{
        url = $Url
        enabled = $true
        saveResponses = $false
        schedule = [ordered]@{
            timezone = 'UTC'
            expiresAt = 0
            hours = @(-1)
            mdays = @(-1)
            minutes = @(-1)
            months = @(-1)
            wdays = @(-1)
        }
        requestMethod = 0
    }

    if (-not [string]::IsNullOrWhiteSpace($Title)) {
        $job.title = $Title
    }

    return ([ordered]@{ job = $job } | ConvertTo-Json -Depth 12 -Compress)
}

function Remove-Profile {
    param([string]$Profile)

    $normalized = Normalize-ProfileName -Profile $Profile
    $profilePath = Get-ProfilePath -Profile $normalized
    if (-not (Test-Path -LiteralPath $profilePath)) {
        Write-Host "cron-job.org profile does not exist: $normalized"
        return
    }

    $backupPath = "$profilePath.logged-out-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Move-Item -LiteralPath $profilePath -Destination $backupPath
    Write-Host "cron-job.org profile moved to: $backupPath"

    $active = Get-ActiveProfile
    if ($active -eq $normalized -and (Test-Path -LiteralPath $currentFile)) {
        Remove-Item -LiteralPath $currentFile
        Write-Host 'Active cron-job.org profile cleared.'
    }
}

$command = if ($args.Count -gt 0) { $args[0].ToLowerInvariant() } else { 'help' }
$remaining = @($args | Select-Object -Skip 1)

switch ($command) {
    'help' {
        Show-Usage
    }

    { $_ -in @('login', 'token-add', 'add') } {
        if ($remaining.Count -lt 1) {
            throw 'Usage: .\cronjob-account.ps1 login <email>'
        }

        $profile = Normalize-ProfileName -Profile $remaining[0]
        Write-Host "Paste a cron-job.org API key for $profile. Input is hidden; it will be saved as api-key.txt for symmetric mainframe backup/restore."
        $token = Read-Host 'cron-job.org API key' -AsSecureString
        Write-ProfileToken -Profile $profile -Token $token
        Write-Host "cron-job.org API key profile is ready and active: $profile"
    }

    'token-clear' {
        $profile = Get-ProfileOrActive -Profile $(if ($remaining.Count -ge 1) { $remaining[0] } else { $null })
        Remove-ProfileToken -Profile $profile
    }

    'use' {
        if ($remaining.Count -ne 1) {
            throw 'Usage: .\cronjob-account.ps1 use <email>'
        }

        $profile = Normalize-ProfileName -Profile $remaining[0]
        $profilePath = Get-ProfilePath -Profile $profile
        if (-not (Test-Path -LiteralPath (Get-ProfileTokenPath -ProfilePath $profilePath))) {
            throw "cron-job.org profile does not exist yet: $profile"
        }

        Set-ActiveProfile -Profile $profile
        Write-Host "Active cron-job.org profile: $profile"
    }

    'run' {
        if ($remaining.Count -lt 2) {
            throw 'Usage: .\cronjob-account.ps1 run [email] <GET|PUT|PATCH|DELETE> <api path> [json body]'
        }

        if (Test-LooksLikeEmail -Value $remaining[0]) {
            if ($remaining.Count -lt 3) {
                throw 'Usage: .\cronjob-account.ps1 run [email] <GET|PUT|PATCH|DELETE> <api path> [json body]'
            }

            $profile = Normalize-ProfileName -Profile $remaining[0]
            $apiArgs = @($remaining | Select-Object -Skip 1)
        } else {
            $profile = Get-ProfileOrActive -Profile $null
            $apiArgs = @($remaining)
        }

        $method = $apiArgs[0]
        $path = $apiArgs[1]
        $body = if ($apiArgs.Count -gt 2) { ($apiArgs[2..($apiArgs.Count - 1)] -join ' ') } else { $null }
        ConvertTo-JsonOutput -Value (Invoke-CronJobApi -Profile $profile -Method $method -Path $path -JsonBody $body)
    }

    'jobs' {
        $profile = Get-ProfileOrActive -Profile $(if ($remaining.Count -ge 1) { $remaining[0] } else { $null })
        ConvertTo-JsonOutput -Value (Invoke-CronJobApi -Profile $profile -Method GET -Path '/jobs' -JsonBody $null)
    }

    'job' {
        if ($remaining.Count -lt 2) {
            throw 'Usage: .\cronjob-account.ps1 job <email> <job-id>'
        }

        $profile = Normalize-ProfileName -Profile $remaining[0]
        $jobId = [int]$remaining[1]
        ConvertTo-JsonOutput -Value (Invoke-CronJobApi -Profile $profile -Method GET -Path "/jobs/$jobId" -JsonBody $null)
    }

    'create' {
        if ($remaining.Count -lt 2) {
            throw 'Usage: .\cronjob-account.ps1 create <email> <url> [title]'
        }

        $profile = Normalize-ProfileName -Profile $remaining[0]
        $url = $remaining[1]
        $title = if ($remaining.Count -gt 2) { ($remaining[2..($remaining.Count - 1)] -join ' ') } else { $null }
        $body = New-EveryMinuteJobPayload -Url $url -Title $title
        ConvertTo-JsonOutput -Value (Invoke-CronJobApi -Profile $profile -Method PUT -Path '/jobs' -JsonBody $body)
    }

    'enable' {
        if ($remaining.Count -lt 2) {
            throw 'Usage: .\cronjob-account.ps1 enable <email> <job-id>'
        }

        $profile = Normalize-ProfileName -Profile $remaining[0]
        $jobId = [int]$remaining[1]
        ConvertTo-JsonOutput -Value (Invoke-CronJobApi -Profile $profile -Method PATCH -Path "/jobs/$jobId" -JsonBody '{"job":{"enabled":true}}')
    }

    'disable' {
        if ($remaining.Count -lt 2) {
            throw 'Usage: .\cronjob-account.ps1 disable <email> <job-id>'
        }

        $profile = Normalize-ProfileName -Profile $remaining[0]
        $jobId = [int]$remaining[1]
        ConvertTo-JsonOutput -Value (Invoke-CronJobApi -Profile $profile -Method PATCH -Path "/jobs/$jobId" -JsonBody '{"job":{"enabled":false}}')
    }

    'history' {
        if ($remaining.Count -lt 2) {
            throw 'Usage: .\cronjob-account.ps1 history <email> <job-id>'
        }

        $profile = Normalize-ProfileName -Profile $remaining[0]
        $jobId = [int]$remaining[1]
        ConvertTo-JsonOutput -Value (Invoke-CronJobApi -Profile $profile -Method GET -Path "/jobs/$jobId/history" -JsonBody $null)
    }

    'history-item' {
        if ($remaining.Count -lt 3) {
            throw 'Usage: .\cronjob-account.ps1 history-item <email> <job-id> <identifier>'
        }

        $profile = Normalize-ProfileName -Profile $remaining[0]
        $jobId = [int]$remaining[1]
        $identifier = [uri]::EscapeDataString([string]$remaining[2])
        ConvertTo-JsonOutput -Value (Invoke-CronJobApi -Profile $profile -Method GET -Path "/jobs/$jobId/history/$identifier" -JsonBody $null)
    }

    'delete' {
        if ($remaining.Count -lt 2) {
            throw 'Usage: .\cronjob-account.ps1 delete <email> <job-id>'
        }

        $profile = Normalize-ProfileName -Profile $remaining[0]
        $jobId = [int]$remaining[1]
        ConvertTo-JsonOutput -Value (Invoke-CronJobApi -Profile $profile -Method DELETE -Path "/jobs/$jobId" -JsonBody $null)
    }

    'export' {
        if ($remaining.Count -lt 1) {
            throw 'Usage: .\cronjob-account.ps1 export <email> [output-path]'
        }

        $profile = Normalize-ProfileName -Profile $remaining[0]
        $outputPath = if ($remaining.Count -gt 1) { $remaining[1] } else { $null }
        Export-CronJobJobs -Profile $profile -OutputPath $outputPath
    }

    'import' {
        if ($remaining.Count -lt 1) {
            throw 'Usage: .\cronjob-account.ps1 import <email> [input-path] [-ConfirmImport] [-Disabled]'
        }

        $profile = Normalize-ProfileName -Profile $remaining[0]
        $importArgs = @($remaining | Select-Object -Skip 1)
        $confirmImport = Test-ArgSwitch -Items $importArgs -Names @('-ConfirmImport', '--confirm-import')
        $disabled = Test-ArgSwitch -Items $importArgs -Names @('-Disabled', '--disabled')
        $freeArgs = @(Get-RemainingArgsWithoutSwitches -Items $importArgs -SwitchNames @('-ConfirmImport', '--confirm-import', '-Disabled', '--disabled'))
        $inputPath = if ($freeArgs.Count -gt 0) { $freeArgs[0] } else { $null }
        Import-CronJobJobs -Profile $profile -InputPath $inputPath -ConfirmImport $confirmImport -Disabled $disabled
    }

    'status' {
        $profile = Get-ProfileOrActive -Profile $(if ($remaining.Count -ge 1) { $remaining[0] } else { $null })
        Get-ProfileStatus -Profile $profile | Format-List
    }

    'status-all' {
        if (-not (Test-Path -LiteralPath $accountRoot)) {
            Write-Host 'No cron-job.org profiles found.'
            return
        }

        $profiles = @(Get-ChildItem -LiteralPath $accountRoot -Directory -Force | Where-Object { $_.Name -match '^[^\s@]+@[^\s@]+\.[^\s@]+$' } | Sort-Object Name)
        if ($profiles.Count -eq 0) {
            Write-Host 'No cron-job.org profiles found.'
            return
        }

        $profiles |
            ForEach-Object { Get-ProfileStatus -Profile (Get-ProfileName -Directory $_) } |
            Format-Table -AutoSize
    }

    'list' {
        if (-not (Test-Path -LiteralPath $accountRoot)) {
            Write-Host 'No cron-job.org profiles found.'
            return
        }

        $active = Get-ActiveProfile
        $profiles = @(Get-ChildItem -LiteralPath $accountRoot -Directory -Force | Where-Object { $_.Name -match '^[^\s@]+@[^\s@]+\.[^\s@]+$' } | Sort-Object Name)
        if ($profiles.Count -eq 0) {
            Write-Host 'No cron-job.org profiles found.'
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
            Write-Host 'No active cron-job.org email profile set.'
        }
    }

    'path' {
        $profile = Get-ProfileOrActive -Profile $(if ($remaining.Count -ge 1) { $remaining[0] } else { $null })
        Write-Host (Get-ProfilePath -Profile $profile)
    }

    'env' {
        $profile = Get-ProfileOrActive -Profile $(if ($remaining.Count -ge 1) { $remaining[0] } else { $null })
        $profilePath = Get-ProfilePath -Profile $profile
        $tokenPath = Get-ProfileTokenPath -ProfilePath $profilePath
        $tokenState = if (Test-Path -LiteralPath $tokenPath) { '<profile api key>' } else { '<missing api key>' }
        Write-Host "`$env:CRONJOB_API_KEY = $tokenState"
        Write-Host "`$env:CRONJOB_API_ENDPOINT = '$apiEndpoint'"
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

