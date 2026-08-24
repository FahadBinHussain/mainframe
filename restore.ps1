param(
    [string]$ScoopRoot = $(if ($env:SCOOP) { $env:SCOOP } else { "$env:USERPROFILE\scoop" }),
    [string]$BackupRoot,
    [ValidateSet('quick', 'full')][string]$Mode,
    [switch]$Pinned,
    [switch]$ExcludeSecrets,
    [string]$SecretsManifestPath,
    [switch]$SkipNativePersist,
    [hashtable]$CloneRepos = @{
        mainframe = 'https://github.com/<owner>/mainframe.git'
        automata  = 'https://github.com/<owner>/automata.git'
    },
    [string]$DownloadsRoot = "$env:USERPROFILE\Downloads"
)

$ErrorActionPreference = 'Stop'
# Native commands (uv, pip, etc.) that write to stderr (e.g. "already
# installed") would otherwise become terminating errors under Stop and abort
# the whole restore. Let $LASTEXITCODE checks handle native failures instead.
$PSNativeCommandUseErrorActionPreference = $false

# robocopy /COPYALL (ACLs, owner, auditing) requires the "Manage Auditing" user
# right, which only elevated shells have. Running non-elevated used to make every
# /COPYALL robocopy exit 16 (copied nothing) while restore still deleted the
# existing profile first -> silent data loss. Detect elevation once and degrade to
# /COPY:DAT (data, attributes, timestamps) when not elevated so restores always work.
$script:IsElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$script:RoboCopyFlag = if ($script:IsElevated) { '/COPYALL' } else { '/COPY:DAT' }
if (-not $script:IsElevated) {
    Write-Warning 'Not running elevated: robocopy will use /COPY:DAT instead of /COPYALL (file ACLs/owner/auditing will not be restored, data will).'
}

if (-not $BackupRoot) {
    if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'scoopfile.json')) {
        $BackupRoot = $PSScriptRoot
    } elseif (Test-Path -LiteralPath (Join-Path $PWD 'scoopfile.json')) {
        $BackupRoot = $PWD
    } else {
        $BackupRoot = $PSScriptRoot
    }
}

if (-not $Mode) {
    $modeChoice = Read-Host 'Select restore mode: (F)ull restore, or (Q)uick (Edge + opencode + mainframe secrets) [F]'
    $Mode = if ($modeChoice -match '^[Qq]') { 'quick' } else { 'full' }
    Write-Host "Mode selected: $Mode"
}

$scoopfile = Join-Path $BackupRoot 'scoopfile.json'
$persistDir = Join-Path $BackupRoot 'persist'
$nativePersistDir = Join-Path $BackupRoot 'native'
$secretsDir = Join-Path $BackupRoot 'secrets'

if (-not $SecretsManifestPath) {
    $SecretsManifestPath = Join-Path $BackupRoot 'tool-secrets.manifest.json'
}

if ($Mode -ne 'quick' -and -not (Test-Path -LiteralPath $scoopfile)) {
    throw "Missing scoopfile.json next to restore.ps1: $scoopfile"
}

if ($Mode -ne 'quick' -and -not (Test-Path -LiteralPath $persistDir)) {
    throw "Missing persist directory next to restore.ps1: $persistDir"
}

[Environment]::SetEnvironmentVariable('SCOOP', $ScoopRoot, 'User')
$env:SCOOP = $ScoopRoot

function Resolve-TemplateString {
    param(
        [AllowNull()][string]$Value,
        [hashtable]$Values = @{}
    )

    if ($null -eq $Value) {
        return $null
    }

    $resolved = [Environment]::ExpandEnvironmentVariables($Value)
    foreach ($key in $Values.Keys) {
        $resolved = $resolved.Replace("{$key}", [string]$Values[$key])
    }

    return $resolved
}

function Get-MainframeConfigPath {
    param([string]$FileName)

    $candidate = Join-Path $BackupRoot $FileName
    if (Test-Path -LiteralPath $candidate) {
        return $candidate
    }

    throw "Missing required mainframe allowlist: $candidate"
}

function Get-ScoopCommand {
    $cmd = Get-Command scoop -ErrorAction SilentlyContinue
    if ($cmd) {
        return $cmd.Source
    }

    $shim = Join-Path $ScoopRoot 'shims\scoop.ps1'
    if (Test-Path -LiteralPath $shim) {
        return $shim
    }

    return $null
}

function Invoke-Scoop {
    param(
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$Arguments
    )

    $cmd = Get-ScoopCommand
    if (-not $cmd) {
        throw 'Scoop command was not found after installation.'
    }

    & $cmd @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "scoop $($Arguments -join ' ') failed with exit code $LASTEXITCODE"
    }
}

# Run a native command while suppressing $ErrorActionPreference='Stop' aborts
# from native stderr. Windows PowerShell 5.1 turns ANY native stderr line into
# an error record, and under 'Stop' that terminates the whole restore (seen
# with `uv tool install` on an already-installed tool). Restore the caller's
# preference afterwards so cmdlet errors still behave as the script intends.
function Invoke-Native {
    param(
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$Arguments
    )
    $savedEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $Arguments[0] @($Arguments | Select-Object -Skip 1) 2>&1 | Out-Host
        return $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $savedEap
    }
}

function Get-PnpmCommand {
    $cmd = Get-Command pnpm -ErrorAction SilentlyContinue
    if ($cmd) {
        return $cmd.Source
    }

    foreach ($candidate in @(
        (Join-Path $ScoopRoot 'shims\pnpm.ps1'),
        (Join-Path $ScoopRoot 'shims\pnpm.cmd'),
        (Join-Path $ScoopRoot 'apps\pnpm\current\pnpm.exe')
    )) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    return $null
}

function Invoke-Pnpm {
    param(
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$Arguments
    )

    $cmd = Get-PnpmCommand
    if (-not $cmd) {
        throw 'pnpm command was not found after Scoop restore.'
    }

    & $cmd @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "pnpm $($Arguments -join ' ') failed with exit code $LASTEXITCODE"
    }
}

function Add-BucketIfMissing {
    param(
        [string]$Name,
        [string]$Source
    )

    $bucketPath = Join-Path $ScoopRoot "buckets\$Name"
    if (Test-Path -LiteralPath $bucketPath) {
        return
    }

    Invoke-Scoop bucket add $Name $Source
}

function Import-AppRegistryFile {
    param(
        [string]$AppName,
        [string]$RelativePath
    )

    $cmd = Get-ScoopCommand
    if (-not $cmd) {
        return
    }

    $savedEapLocal = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $prefix = & $cmd prefix $AppName 2>$null
    $ErrorActionPreference = $savedEapLocal
    if ($LASTEXITCODE -ne 0 -or -not $prefix) {
        return
    }

    $regFile = Join-Path $prefix $RelativePath
    if (Test-Path -LiteralPath $regFile) {
        Invoke-Native reg import $regFile
    }
}

function Restore-SecretItem {
    param(
        [Parameter(Mandatory)][PSCustomObject]$Item,
        [string]$SecretsDir
    )

    $archiveRelativePath = $Item.ArchivePath -replace '^[\\/]+', ''
    $source = Join-Path $SecretsDir $archiveRelativePath
    $target = Resolve-TemplateString -Value $Item.Source -Values @{
        AppData = $env:APPDATA
        LocalAppData = $env:LOCALAPPDATA
        ProgramData = $env:ProgramData
        UserProfile = $env:USERPROFILE
    }

    Write-Host "DEBUG: source = $source"
    Write-Host "DEBUG: target = $target"
    Write-Host "DEBUG: source exists = $(Test-Path -LiteralPath $source)"

    if (-not (Test-Path -LiteralPath $source)) {
        Write-Warning "Secret entry not found in backup, skipping $($Item.Name): $archiveRelativePath"
        return
    }

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
    if (Test-Path -LiteralPath $source -PathType Container) {
        $null = & robocopy $source $target /E $script:RoboCopyFlag /R:1 /W:1 /NP /NDL /NFL /XJ /XD 'Cache' 'Code Cache' 'GPUCache'
        if ($LASTEXITCODE -gt 7) {
            throw "Robocopy failed restoring secret directory for $($Item.Name) with exit code $LASTEXITCODE"
        }
    } else {
        Copy-Item -LiteralPath $source -Destination $target -Force
    }
    Write-Host "Restored secret: $($Item.Name)"
    Write-Host "DEBUG: target exists after copy = $(Test-Path -LiteralPath $target)"
}

function Restore-ToolSecretsArchive {
    param(
        # Only restore items whose Name matches these strings.
        [string[]]$ItemNames = @(),
        # Skip items whose Name matches these strings (used to avoid re-copying
        # items that were already restored in the early opencode pass).
        [string[]]$SkipNames = @()
    )

    if ($ExcludeSecrets) {
        return
    }

    if (Test-Path -LiteralPath $secretsDir) {
        Write-Host "Restoring secrets from embedded backup..."
        $manifest = Get-Content -LiteralPath $SecretsManifestPath -Raw | ConvertFrom-Json
        $manifestItems = @($manifest.items | Where-Object { -not $_.Disabled })
        if ($ItemNames.Count -gt 0) {
            $manifestItems = @($manifestItems | Where-Object {
                $name = $_.Name
                $match = $false
                foreach ($n in $ItemNames) {
                    if ($name -like "*$n*") { $match = $true; break }
                }
                $match
            })
        }
        if ($SkipNames.Count -gt 0) {
            $manifestItems = @($manifestItems | Where-Object {
                $name = $_.Name
                $match = $false
                foreach ($n in $SkipNames) {
                    if ($name -like "*$n*") { $match = $true; break }
                }
                -not $match
            })
        }
        foreach ($item in $manifestItems) {
            Restore-SecretItem -Item $item -SecretsDir $secretsDir
        }
        return
    }

    $standaloneZip = Join-Path $BackupRoot 'tool-secrets.zip'
    if (Test-Path -LiteralPath $standaloneZip) {
        $script = Join-Path $PSScriptRoot 'restore-secrets.ps1'
        if (-not (Test-Path -LiteralPath $script)) {
            throw "Missing restore-secrets.ps1 next to restore.ps1: $script"
        }
        & $script -ManifestPath $SecretsManifestPath -ArchivePath $standaloneZip
        if ($LASTEXITCODE -ne 0) {
            throw "restore-secrets.ps1 failed with exit code $LASTEXITCODE"
        }
        return
    }

    Write-Warning 'No secrets found in backup (no secrets/ directory or tool-secrets.zip).'
}

function Restore-EdgeProfile {
    $edgeBackupDir = Join-Path $BackupRoot 'edge-profile'
    if (Test-Path -LiteralPath $edgeBackupDir) {
        $edgeDest = Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data'
        $edgeStaging = Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data.restore-staging'
        $edgeProcs = Get-Process -Name 'msedge' -ErrorAction SilentlyContinue
        if ($edgeProcs) {
            Write-Host 'Closing Edge for restore...'
            $edgeProcs | Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 3
        }
        # Copy to a staging dir FIRST, and only swap it into place after the copy
        # succeeds, so a failed robocopy can never leave the user with a deleted,
        # empty profile (happened when /COPYALL failed with exit 16 non-elevated).
        if (Test-Path -LiteralPath $edgeStaging) {
            Remove-Item -LiteralPath $edgeStaging -Recurse -Force
        }
        New-Item -ItemType Directory -Force -Path $edgeStaging | Out-Null
        $rcExit = & robocopy $edgeBackupDir $edgeStaging /E $script:RoboCopyFlag /R:1 /W:1 /NP /NDL /NFL
        if ($LASTEXITCODE -gt 7) {
            Remove-Item -LiteralPath $edgeStaging -Recurse -Force -ErrorAction SilentlyContinue
            throw "Robocopy Edge profile failed with exit code $LASTEXITCODE. Existing Edge profile left untouched - fix the source backup or rerun elevated, then try again."
        }
        if (Test-Path -LiteralPath $edgeDest) {
            Remove-Item -LiteralPath $edgeDest -Recurse -Force
            Write-Host "Removed existing Edge User Data at $edgeDest"
        }
        Move-Item -LiteralPath $edgeStaging -Destination $edgeDest
        Write-Host "Restored Edge browser profile to $edgeDest"
        # Backups taken while Edge was running carry stale first-run/reset markers
        # (First Run, FirstLaunchAfterInstallation, lockfile, Singleton*). If left in
        # place, Edge treats the restored profile as a fresh install and RESETS it on
        # first launch, wiping the restored Local State/keys, cookies, bookmarks, and
        # preferences. Delete them so Edge loads the restored data as-is.
        foreach ($marker in @('First Run', 'FirstLaunchAfterInstallation', 'lockfile', 'SingletonLock', 'SingletonCookie', 'SingletonSocket', 'DevToolsActivePort')) {
            $markerPath = Join-Path $edgeDest $marker
            if (Test-Path -LiteralPath $markerPath) {
                Remove-Item -LiteralPath $markerPath -Force -ErrorAction SilentlyContinue
                Write-Host "Removed stale Edge state marker: $marker"
            }
        }
    } else {
        Write-Warning "No edge-profile backup found, skipping"
    }
}

function Restore-EdgeExtensions {
    $edgeDest = Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data'
    $extListPath = Join-Path $BackupRoot 'edge-profile\extensions-list.json'
    if (-not (Test-Path -LiteralPath $extListPath)) {
        Write-Host "  No extensions-list.json in backup, skipping Edge extension reinstall"
        return
    }
    try {
        $exts = Get-Content -LiteralPath $extListPath -Raw | ConvertFrom-Json
    } catch {
        Write-Warning "  Could not read extensions-list.json: $($_.Exception.Message)"
        return
    }
    if (-not $exts -or $exts.Count -eq 0) {
        Write-Host "  extensions-list.json is empty, skipping Edge extension reinstall"
        return
    }

    # Edge 151+ prunes cross-machine-restored store extensions (machine-bound
    # install signature check). The cross-machine restore path differs for
    # ENABLED vs DISABLED extensions:
    #
    # ENABLED (Edge-store) -> ExtensionInstallForcelist policy. Edge
    # force-installs from the Edge store URL. The forcelist only accepts
    # the Edge store URL -- CWS URLs are silently dropped by the policy handler.
    #
    # ENABLED (CWS-only) + DISABLED (any store) -> Windows registry external
    # loader (HKLM\SOFTWARE\WOW6432Node\Microsoft\Edge\Extensions\<id>).
    # The forcelist CANNOT preserve disabled state (GetDisableReasonsOnInstalled
    # returns {} for policy installs). The registry loader installs as loc=6
    # (external pre-download), NOT policy-controlled: it loads disabled
    # (dr=[8192] DISABLE_EXTERNAL_EXTENSION) and STAYS disabled across
    # relaunches (verified). For enabled CWS-only extensions, the registry
    # loader also installs them disabled -- Edge re-downloads external
    # extensions whenever Secure Preferences is rewritten (ConvertTo-Json
    # triggers it), so ack_external can't be set via prefs edit. The user
    # must enable them once in edge://extensions (one click each).
    # The update_url must be the extension's OWN store URL (from backup):
    # Edge store for Edge-store extensions, clients2.google.com for CWS-only.
    $enabledEdgeExts = @($exts | Where-Object { -not $_.disable_reason -and $_.update_url -match 'edge.microsoft.com' })
    $enabledCwsExts = @($exts | Where-Object { -not $_.disable_reason -and $_.update_url -match 'clients2.google.com' })
    $disabledExts = @($exts | Where-Object { $_.disable_reason })
    $regBase = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Edge\Extensions'
    $policyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge\ExtensionInstallForcelist'
    $edgeUpdateUrl = 'https://edge.microsoft.com/extensionwebstorebase/v1/crx'

    try {
        # Write forcelist for ENABLED Edge-store extensions only.
        if (Test-Path -LiteralPath $policyPath) {
            Remove-Item -LiteralPath $policyPath -Recurse -Force
        }
        New-Item -Path $policyPath -Force | Out-Null
        $i = 0
        foreach ($ext in $enabledEdgeExts) {
            $i++
            New-ItemProperty -Path $policyPath -Name "$i" -Value "$($ext.id);$edgeUpdateUrl" -PropertyType String -Force | Out-Null
        }
        Write-Host "  Wrote ExtensionInstallForcelist for $($enabledEdgeExts.Count) enabled Edge-store extensions"
    } catch {
        Write-Warning "  Could not write ExtensionInstallForcelist policy (need admin?): $($_.Exception.Message)"
        return
    }

    # Write registry external loader keys for DISABLED extensions AND enabled
    # CWS-only extensions (the Edge store can't serve CWS-only ones, so the
    # forcelist path can't install them). Each uses its own update_url from the
    # backup (Edge store or CWS).
    try {
        $regCount = 0
        foreach ($ext in ($enabledCwsExts + $disabledExts)) {
            $url = if ($ext.update_url) { $ext.update_url } else { $edgeUpdateUrl }
            $rk = "$regBase\$($ext.id)"
            if (Test-Path $rk) { Remove-Item $rk -Recurse -Force }
            New-Item -Path $rk -Force | Out-Null
            New-ItemProperty -Path $rk -Name 'update_url' -Value $url -PropertyType String -Force | Out-Null
            $regCount++
        }
        Write-Host "  Wrote registry external loader keys for $regCount extensions ($($enabledCwsExts.Count) enabled CWS, $($disabledExts.Count) disabled)"
    } catch {
        Write-Warning "  Could not write registry external loader keys: $($_.Exception.Message)"
    }

    # Let Edge apply the policies so extensions land. Launch once, wait, then stop.
    $edgeExe = 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
    if (Test-Path -LiteralPath $edgeExe) {
        $existing = Get-Process -Name 'msedge' -ErrorAction SilentlyContinue
        Start-Process -FilePath $edgeExe -ArgumentList '--no-first-run', 'about:blank' | Out-Null
        Start-Sleep -Seconds 25
        Get-Process -Name 'msedge' -ErrorAction SilentlyContinue | Where-Object { $_ -notin $existing } | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        Write-Host "  Launched Edge once to apply extension policy"
    }

    if ($enabledEdgeExts.Count -gt 0) {
        Write-Host "  $($enabledEdgeExts.Count) enabled Edge-store extensions requested via forcelist."
    }
    if ($disabledExts.Count -gt 0) {
        Write-Host "  $($disabledExts.Count) disabled extensions restored via registry external loader (dr=8192, persistent)."
    }
    if ($enabledCwsExts.Count -gt 0) {
        Write-Host "  $($enabledCwsExts.Count) Chrome-Web-Store-only extensions installed via registry loader but DISABLED."
        Write-Host "  Enable them once in edge://extensions (one click each): $($enabledCwsExts.id -join ', ')"
    }

    # Unpacked developer-mode extensions (loc=4). Edge 151+ prunes these from a
    # cross-machine profile too, and --load-extension re-registers them as loc=8
    # (command-line loaded) -- but loc=8 is SKIPPED by InstalledLoader on plain
    # relaunches (extension_registrar/installed_loader.cc), so command-line
    # extensions only persist while the flag is passed. Kept as best-effort for
    # dev-mode folders that need to exist on the target.
    # backup.ps1 copied the source folders to edge-profile\unpacked-extensions\
    # and wrote unpacked-extensions.json with their original source paths.
    $unpackedListPath = Join-Path $BackupRoot 'edge-profile\unpacked-extensions.json'
    if (Test-Path -LiteralPath $unpackedListPath) {
        try {
            $unpacked = Get-Content -LiteralPath $unpackedListPath -Raw | ConvertFrom-Json
        } catch {
            $unpacked = $null
        }
        if ($unpacked -and $unpacked.Count -gt 0) {
            $unpackedSrc = Join-Path $BackupRoot 'edge-profile\unpacked-extensions'
            $restoredPaths = @()
            foreach ($ux in $unpacked) {
                $backupPath = Join-Path $unpackedSrc $ux.relative_path
                $orig = $ux.path
                if (Test-Path -LiteralPath $backupPath) {
                    # restore to the same path as the source machine if possible
                    $target = $orig
                    if ($target -and $target -notmatch '^C:\\Users\\Admin') {
                        # different windows user root - just keep original path;
                        # robocopy handles it if the dir exists, else skip
                    }
                    $dir = Split-Path -Parent $target
                    try {
                        New-Item -ItemType Directory -Force -Path $dir | Out-Null
                        & robocopy $backupPath $target /E /COPYALL /R:1 /W:1 /NP /NDL /NFL | Out-Null
                        if (Test-Path -LiteralPath (Join-Path $target 'manifest.json')) {
                            $restoredPaths += $target
                            Write-Host "  Restored unpacked extension $($ux.name) to $target"
                        } else {
                            Write-Warning "  Unpacked extension $($ux.name) restore produced no manifest at $target - skipped"
                        }
                    } catch {
                        Write-Warning "  Could not restore unpacked extension $($ux.name): $($_.Exception.Message)"
                    }
                } else {
                    Write-Warning "  Unpacked extension backup folder not found: $backupPath"
                }
            }
            if ($restoredPaths.Count -gt 0 -and (Test-Path -LiteralPath $edgeExe)) {
                $loadArg = '--load-extension=' + ($restoredPaths -join ',')
                Write-Host "  Launching Edge once with --load-extension to register unpacked extensions..."
                $existing = Get-Process -Name 'msedge' -ErrorAction SilentlyContinue
                Start-Process -FilePath $edgeExe -ArgumentList '--no-first-run', $loadArg, 'about:blank' | Out-Null
                Start-Sleep -Seconds 25
                Get-Process -Name 'msedge' -ErrorAction SilentlyContinue | Where-Object { $_ -notin $existing } | Stop-Process -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 2
                Write-Host "  Registered $($restoredPaths.Count) unpacked extensions via --load-extension"
            }
        }
    }
}

$totalSteps = if ($Mode -eq 'quick') { 4 } else { 12 }
$currentStep = 0

function Update-Step {
    param([string]$Activity)
    $script:currentStep++
    $pct = [Math]::Min(($script:currentStep / $totalSteps) * 100, 100)
    Write-Progress -Activity 'Restoring mainframe' -Status "$Activity ($script:currentStep/$totalSteps)" -PercentComplete $pct
}

if ($Mode -eq 'quick') {
    Update-Step 'Restoring Edge browser profile'
    Restore-EdgeProfile
    Restore-EdgeExtensions

    Update-Step 'Restoring opencode config'
    Restore-ToolSecretsArchive -ItemNames @('opencode')

    Update-Step 'Restoring mainframe secrets'
    Restore-ToolSecretsArchive -SkipNames @('opencode')

    Update-Step 'Setting up Scoop'
    if (-not (Get-ScoopCommand)) {
        try { Set-ExecutionPolicy RemoteSigned -Scope CurrentUser -Force } catch {}
        $env:SCOOP_ALLOW_ADMIN = 'true'
        [Environment]::SetEnvironmentVariable('SCOOP_ALLOW_ADMIN', 'true', 'User')
        $installScript = Join-Path $env:TEMP 'install-scoop.ps1'
        Invoke-WebRequest -Uri 'https://get.scoop.sh' -OutFile $installScript
        $env:SCOOP = $ScoopRoot
        & powershell -NoProfile -ExecutionPolicy Bypass -File $installScript -RunAsAdmin -ScoopDir $ScoopRoot
    }

    New-Item -ItemType Directory -Force -Path $ScoopRoot | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $ScoopRoot 'shims') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $ScoopRoot 'buckets') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $ScoopRoot 'apps') | Out-Null

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Host 'Git not found. Installing via Scoop...'
        Invoke-Scoop install git
    }

    Update-Step 'Installing opencode'
    $opencodeSpec = 'opencode'
    if (Test-Path -LiteralPath $scoopfile) {
        $import = Get-Content -LiteralPath $scoopfile -Raw | ConvertFrom-Json
        foreach ($bucket in $import.buckets) {
            Add-BucketIfMissing -Name $bucket.Name -Source $bucket.Source
        }
        $bucketNames = @($import.buckets | ForEach-Object { $_.Name })
        $opencodeItem = @($import.apps | Where-Object { $_.Name -eq 'opencode' }) | Select-Object -First 1
        if ($opencodeItem) {
            if ($opencodeItem.Version) {
                if ($opencodeItem.Source -in $bucketNames) {
                    $opencodeSpec = "$($opencodeItem.Source)/opencode@$($opencodeItem.Version)"
                } elseif ($opencodeItem.Source -eq '<auto-generated>') {
                    $opencodeSpec = "opencode@$($opencodeItem.Version)"
                } else {
                    $opencodeSpec = "$($opencodeItem.Source)@$($opencodeItem.Version)"
                }
            }
        }
    }
    Write-Host "Installing $opencodeSpec"
    try {
        Invoke-Scoop install $opencodeSpec --no-update-scoop --independent
    } catch {
        Write-Warning "Failed to install $opencodeSpec -- $_. Attempting fallback to latest..."
        Invoke-Scoop install opencode --no-update-scoop --independent
    }

    Write-Progress -Activity 'Restoring mainframe' -Completed
    Write-Host 'Quick restore complete: Edge profile, opencode config, mainframe secrets, and opencode installed.'
    return
}

Update-Step 'Restoring Edge browser profile'
Restore-EdgeProfile
Restore-EdgeExtensions

Update-Step 'Restoring opencode config'
Restore-ToolSecretsArchive -ItemNames @('opencode')

Update-Step 'Setting up Scoop'
if (-not (Get-ScoopCommand)) {
    try { Set-ExecutionPolicy RemoteSigned -Scope CurrentUser -Force } catch {}
    $env:SCOOP_ALLOW_ADMIN = 'true'
    [Environment]::SetEnvironmentVariable('SCOOP_ALLOW_ADMIN', 'true', 'User')
    $installScript = Join-Path $env:TEMP 'install-scoop.ps1'
    Invoke-WebRequest -Uri 'https://get.scoop.sh' -OutFile $installScript
    $env:SCOOP = $ScoopRoot
    & powershell -NoProfile -ExecutionPolicy Bypass -File $installScript -RunAsAdmin -ScoopDir $ScoopRoot
}

New-Item -ItemType Directory -Force -Path $ScoopRoot | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $ScoopRoot 'shims') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $ScoopRoot 'buckets') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $ScoopRoot 'apps') | Out-Null

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host 'Git not found. Installing via Scoop...'
    Invoke-Scoop install git
}

Update-Step 'Restoring persist data'
Write-Host "Restoring persisted Scoop settings from $persistDir"
$persistDest = Join-Path $ScoopRoot 'persist'
New-Item -ItemType Directory -Force -Path $persistDest | Out-Null
& robocopy $persistDir $persistDest /E $script:RoboCopyFlag /R:1 /W:1 /NP /NDL /NFL | Out-Null
if ($LASTEXITCODE -gt 7) {
    Write-Warning "Robocopy persist data failed with exit code $LASTEXITCODE"
} else {
    Write-Host "Restored persist data to $persistDest"
}

$import = Get-Content -LiteralPath $scoopfile -Raw | ConvertFrom-Json

foreach ($item in $import.config.PSObject.Properties) {
    Invoke-Scoop config $item.Name $item.Value
}

foreach ($bucket in $import.buckets) {
    Add-BucketIfMissing -Name $bucket.Name -Source $bucket.Source
}

Update-Step 'Installing Scoop apps'
$scoop = Get-ScoopCommand
$installed = @{}
$listOutput = & $scoop list 2>$null
foreach ($line in $listOutput) {
    if ($line -match '^\s*(\S+)\s+') {
        $appName = $matches[1]
        if ($appName -ne 'Name' -and $appName -ne '----') {
            $installed[$appName] = $true
        }
    }
}
# Also check apps directory for apps that scoop list might miss
$appsDir = Join-Path $ScoopRoot 'apps'
if (Test-Path -LiteralPath $appsDir) {
    Get-ChildItem -LiteralPath $appsDir -Directory | ForEach-Object {
        $installed[$_.Name] = $true
    }
}

$bucketNames = @($import.buckets | ForEach-Object { $_.Name })
$importAppsByName = @{}
foreach ($item in @($import.apps)) {
    $importAppsByName[$item.Name] = $item
}

$allowedAppsFile = Get-MainframeConfigPath -FileName 'scoop-allowed.json'
$allowedApps = @((Get-Content -LiteralPath $allowedAppsFile -Raw | ConvertFrom-Json).apps | Where-Object { $_ })
$restoreApps = @($allowedApps | ForEach-Object {
    if ($importAppsByName.ContainsKey($_)) {
        $importAppsByName[$_]
    } else {
        [PSCustomObject]@{
            Name = $_
            Version = $null
            Source = $null
            Info = ''
            Updated = $null
        }
    }
})
Write-Host "Using Scoop allowlist: $allowedAppsFile ($($restoreApps.Count) apps)"

$appCount = @($restoreApps).Count
$appIndex = 0
$skipped = 0
$installed_count = 0

foreach ($item in $restoreApps) {
    $appIndex++
    $info = @($item.Info -split ', ' | Where-Object { $_ })

    if ($installed.ContainsKey($item.Name)) {
        Write-Host "Skip (installed): $($item.Name) $($installed[$item.Name])"
        $skipped++
        continue
    }

    $installArgs = @('--no-update-scoop', '--independent')
    $holdArgs = @()

    if ('Global install' -in $info) {
        $installArgs += '--global'
        $holdArgs += '--global'
    }

    if ('64bit' -in $info) {
        $installArgs += @('--arch', '64bit')
    } elseif ('32bit' -in $info) {
        $installArgs += @('--arch', '32bit')
    } elseif ('arm64' -in $info) {
        $installArgs += @('--arch', 'arm64')
    }

    $appSpec = if ($item.Version) {
        if ($item.Source -in $bucketNames) {
            "$($item.Source)/$($item.Name)@$($item.Version)"
        } elseif ($item.Source -eq '<auto-generated>') {
            "$($item.Name)@$($item.Version)"
        } else {
            "$($item.Source)@$($item.Version)"
        }
    } else {
        $item.Name
    }

    Write-Progress -Activity 'Restoring mainframe' -Status "Installing $appSpec ($appIndex/$appCount)" -PercentComplete (($currentStep / $totalSteps) * 100)
    Write-Host "Installing $appSpec"
    try {
        Invoke-Scoop install $appSpec @installArgs
        $installed_count++
    } catch {
        Write-Warning "Failed to install $appSpec -- $_. Attempting fallback to latest..."
        $fallbackSpec = if ($item.Source -in $bucketNames) { "$($item.Source)/$($item.Name)" } else { $item.Name }
        try {
            Invoke-Scoop install $fallbackSpec @installArgs
            $installed_count++
            Write-Host "  Fallback succeeded: $fallbackSpec"
        } catch {
            Write-Warning "Fallback also failed for $fallbackSpec -- $_. Skipping."
            continue
        }
    }

    if ('Held package' -in $info) {
        Invoke-Scoop hold $item.Name @holdArgs
    }
}

Write-Host "`nDone: $installed_count installed, $skipped skipped (already present)"

Update-Step 'Installing pnpm global packages'
$pnpmAllowedFile = Get-MainframeConfigPath -FileName 'pnpm-allowed.json'
$pnpmCmd = Get-PnpmCommand
if (-not $pnpmCmd) {
    throw 'pnpm command was not found after Scoop restore.'
}

$pnpmConfigFile = Join-Path $BackupRoot 'pnpm-config.json'
$pnpmGlobalBin = Join-Path $env:USERPROFILE '.pnpm-global\bin'
if (Test-Path -LiteralPath $pnpmConfigFile) {
    $pnpmConfig = Get-Content -LiteralPath $pnpmConfigFile -Raw | ConvertFrom-Json
    if ($pnpmConfig.globalBinDir) {
        $pnpmGlobalBin = $pnpmConfig.globalBinDir
    }
}

Write-Host "Setting pnpm global-bin-dir to: $pnpmGlobalBin"
New-Item -ItemType Directory -Force -Path $pnpmGlobalBin | Out-Null
& $pnpmCmd config set global-bin-dir $pnpmGlobalBin
if ($LASTEXITCODE -ne 0) {
    throw "pnpm config set global-bin-dir failed with exit code $LASTEXITCODE"
}

$pnpmPackages = @((Get-Content -LiteralPath $pnpmAllowedFile -Raw | ConvertFrom-Json).packages | Where-Object { $_ })
Write-Host "Using pnpm allowlist: $pnpmAllowedFile ($($pnpmPackages.Count) packages)"
foreach ($pkg in $pnpmPackages) {
    Write-Host "Installing pnpm global: $pkg"
    $env:CI = 'true'
    $stdinFile = [IO.Path]::GetTempFileName()
    $stdoutFile = [IO.Path]::GetTempFileName()
    $stderrFile = [IO.Path]::GetTempFileName()
    try {
        $proc = Start-Process -FilePath $pnpmCmd -ArgumentList "add","-g",$pkg -RedirectStandardInput $stdinFile -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile -NoNewWindow -Wait -PassThru
        if ($proc.ExitCode -ne 0) {
            throw "pnpm add -g $pkg failed with exit code $($proc.ExitCode)"
        }
    } catch {
        Write-Warning "Failed to install pnpm global $pkg -- $_. Skipping."
    } finally {
        Remove-Item -LiteralPath $stdinFile -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $stdoutFile -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $stderrFile -ErrorAction SilentlyContinue
    }
}
Write-Host "Done: $($pnpmPackages.Count) pnpm global packages"

if (Test-Path -LiteralPath $pnpmGlobalBin) {
    $userPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
    if ($userPath -notlike "*$pnpmGlobalBin*") {
        [Environment]::SetEnvironmentVariable('PATH', "$pnpmGlobalBin;$userPath", 'User')
        $env:PATH = "$pnpmGlobalBin;$env:PATH"
        Write-Host "Added $pnpmGlobalBin to user PATH"
    }
}

Update-Step 'Installing uv tools'
$uvAllowedFile = Get-MainframeConfigPath -FileName 'uv-allowed.json'
$uvCmd = Get-Command uv -ErrorAction SilentlyContinue
if (-not $uvCmd) {
    throw 'uv command was not found after Scoop restore.'
}
$uvPackages = @((Get-Content -LiteralPath $uvAllowedFile -Raw | ConvertFrom-Json).packages | Where-Object { $_ })
Write-Host "Using uv allowlist: $uvAllowedFile ($($uvPackages.Count) tools)"
foreach ($pkg in $uvPackages) {
    Write-Host "Installing uv tool: $pkg"
    $savedEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & uv tool install $pkg 2>&1 | Out-Host
    $ErrorActionPreference = $savedEap
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "uv tool install $pkg failed with exit code $LASTEXITCODE. Skipping."
    }
}
Write-Host "Done: $($uvPackages.Count) uv tools"

Update-Step 'Installing pip packages'
$pipAllowedFile = Get-MainframeConfigPath -FileName 'pip-allowed.json'
$pipCmd = Get-Command pip -ErrorAction SilentlyContinue
if (-not $pipCmd) {
    throw 'pip command was not found after Scoop restore.'
}
$pipPackages = @((Get-Content -LiteralPath $pipAllowedFile -Raw | ConvertFrom-Json).packages | Where-Object { $_ })
Write-Host "Using pip allowlist: $pipAllowedFile ($($pipPackages.Count) packages)"
foreach ($pkg in $pipPackages) {
    Write-Host "Installing pip package: $pkg"
    $savedEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & $pipCmd.Source install $pkg 2>&1 | Out-Host
    $ErrorActionPreference = $savedEap
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "pip install $pkg failed with exit code $LASTEXITCODE. Skipping."
    }
}
Write-Host "Done: $($pipPackages.Count) pip packages"

Update-Step 'Restoring OBS Studio settings'
$obsBackupDir = Join-Path $BackupRoot 'obs-studio'
if (Test-Path -LiteralPath $obsBackupDir) {
    $obsDest = Join-Path $ScoopRoot 'persist\obs-studio\config\obs-studio'
    New-Item -ItemType Directory -Force -Path $obsDest | Out-Null
    $rcExit = & robocopy $obsBackupDir $obsDest /E $script:RoboCopyFlag /R:1 /W:1 /NP /NDL /NFL
    if ($LASTEXITCODE -gt 7) {
        Write-Warning "Robocopy OBS settings failed with exit code $LASTEXITCODE"
    } else {
        Write-Host "Restored OBS scenes, profiles, and config to $obsDest"
    }
} else {
    Write-Warning "No obs-studio backup found, skipping"
}

Update-Step 'Restoring qBittorrent settings'
$qbtBackupDir = Join-Path $BackupRoot 'qbittorrent'
if (Test-Path -LiteralPath $qbtBackupDir) {
    $qbtDest = Join-Path $ScoopRoot 'persist\qbittorrent\profile\qBittorrent'
    New-Item -ItemType Directory -Force -Path $qbtDest | Out-Null
    $rcExit = & robocopy $qbtBackupDir $qbtDest /E $script:RoboCopyFlag /R:1 /W:1 /NP /NDL /NFL
    if ($LASTEXITCODE -gt 7) {
        Write-Warning "Robocopy qBittorrent settings failed with exit code $LASTEXITCODE"
    } else {
        Write-Host "Restored qBittorrent config (WebUI creds, save path, sequential/first-last piece flags) to $qbtDest"
    }
} else {
    Write-Warning "No qbittorrent backup found, skipping"
}

Update-Step 'Cloning mainframe repo'
$mainframeRepo = $CloneRepos['mainframe']
$mainframeDest = Join-Path $DownloadsRoot 'mainframe'
if (-not (Test-Path -LiteralPath $mainframeDest)) {
    Write-Host "Cloning $mainframeRepo to $mainframeDest"
    Invoke-Native git clone $mainframeRepo $mainframeDest
} else {
    Write-Host "Mainframe repo already exists at $mainframeDest, pulling latest"
    Invoke-Native git -C $mainframeDest pull --ff-only
}

$automataRepo = $CloneRepos['automata']
$automataDest = Join-Path $DownloadsRoot 'automata'
if (-not (Test-Path -LiteralPath $automataDest)) {
    Write-Host "Cloning $automataRepo to $automataDest"
    Invoke-Native git clone $automataRepo $automataDest
} else {
    Write-Host "Automata repo already exists at $automataDest, pulling latest"
    Invoke-Native git -C $automataDest pull --ff-only
}

Import-AppRegistryFile -AppName 'python' -RelativePath 'install-pep-514.reg'
Import-AppRegistryFile -AppName '7zip' -RelativePath 'install-context.reg'

# qBittorrent / VLC file associations — exported per key by backup.ps1
$appAssoc = Get-ChildItem -LiteralPath $BackupRoot -Filter '*-assoc-*.reg' -ErrorAction SilentlyContinue
foreach ($f in $appAssoc) {
    Write-Host "Importing $($f.Name)"
    Invoke-Native reg.exe import $f.FullName
}

# mpv context menu ("Play with mpv") + user environment (PATH with python312 /
# site-packages\vapoursynth) - sign out or reboot after restore for the PATH to
# reach new processes.
foreach ($mpvReg in @('mpv-contextmenu.reg', 'user-env.reg')) {
    $f = Join-Path $BackupRoot $mpvReg
    if (Test-Path -LiteralPath $f) {
        Write-Host "Importing $mpvReg"
        Invoke-Native reg.exe import $f
    }
}

Update-Step 'Restoring scheduled tasks'
$tasksDir = Join-Path $BackupRoot 'scheduled-tasks'
if (Test-Path -LiteralPath $tasksDir) {
    $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $taskFailures = @()
    Get-ChildItem -LiteralPath $tasksDir -Filter '*.xml' | ForEach-Object {
        $taskName = $_.BaseName
        Write-Host "Importing scheduled task: $taskName"
        [xml]$xml = Get-Content -LiteralPath $_.FullName -Raw
        $ns = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
        $ns.AddNamespace("t", "http://schemas.microsoft.com/windows/2004/02/mit/task")
        $userIdNode = $xml.SelectSingleNode("//t:UserId", $ns)
        if ($userIdNode) {
            $userIdNode.InnerText = $currentUser
        }
        try {
            Register-ScheduledTask -Xml $xml.OuterXml -TaskName $taskName -Force | Out-Null
            Write-Host "  Installed: $taskName"
        } catch {
            # Tasks with RunLevel=HighestAvailable need admin to register
            # (HRESULT 0x80070005). Do not abort the whole restore over it -
            # warn and keep going; the task can be installed from an elevated shell.
            $taskFailures += $taskName
            Write-Warning "  Could not register $taskName ($($_.Exception.Message))"
        }
    }
    if ($taskFailures.Count -gt 0) {
        Write-Warning "Scheduled tasks not installed (need elevation): $($taskFailures -join ', '). Re-run restore.ps1 from an elevated shell to install them."
    }
}

Update-Step 'Restoring secrets'
Restore-ToolSecretsArchive -SkipNames @('opencode')

$agentsMdSrc = Join-Path $BackupRoot 'AGENTS.md'
if (Test-Path -LiteralPath $agentsMdSrc) {
    $agentsMdDest = Join-Path $env:USERPROFILE 'AGENTS.md'
    Copy-Item -LiteralPath $agentsMdSrc -Destination $agentsMdDest -Force
    Write-Host 'Restored AGENTS.md'
}

$agentSkillsSrc = Join-Path $BackupRoot '.agents\skills'
if (Test-Path -LiteralPath $agentSkillsSrc) {
    $agentSkillsDest = Join-Path $env:USERPROFILE '.agents\skills'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $agentSkillsDest) | Out-Null
    & robocopy $agentSkillsSrc $agentSkillsDest /E $script:RoboCopyFlag /R:1 /W:1 /NP /NDL /NFL | Out-Null
    if ($LASTEXITCODE -gt 7) {
        Write-Warning "Robocopy .agents\skills failed with exit code $LASTEXITCODE"
    } else {
        Write-Host 'Restored .agents\skills'
    }
}

$gitconfigSrc = Join-Path $BackupRoot '.gitconfig'
if (Test-Path -LiteralPath $gitconfigSrc) {
    $gitconfigDest = Join-Path $env:USERPROFILE '.gitconfig'
    Copy-Item -LiteralPath $gitconfigSrc -Destination $gitconfigDest -Force
    Write-Host 'Restored .gitconfig'
}

$goCmd = Get-Command go -ErrorAction SilentlyContinue
if (-not $goCmd) {
    throw 'go command was not found after Scoop restore.'
}
$goAllowedFile = Get-MainframeConfigPath -FileName 'go-allowed.json'
$goPkgImport = Get-Content -LiteralPath $goAllowedFile -Raw | ConvertFrom-Json
Write-Host "Using Go allowlist: $goAllowedFile ($(@($goPkgImport.packages).Count) packages)"
foreach ($pkg in @($goPkgImport.packages)) {
    $pkgPath = if ($pkg -is [string]) { $pkg } else { $pkg.path }
    $tags = if ($pkg -is [string]) { @() } else { @($pkg.tags) }
    $version = if ($pkg -is [string]) { 'latest' } else { if ($pkg.version) { $pkg.version } else { 'latest' } }
    # Derive the binary name from the last path segment (e.g. .../cmd/wacli -> wacli)
    $binaryName = ($pkgPath -split '/')[-1]
    $goBinDir = if ($env:GOPATH) { $env:GOPATH } else { Join-Path $env:USERPROFILE 'go' }
    $binaryPath = Join-Path $goBinDir "bin\$binaryName.exe"
    if (Test-Path -LiteralPath $binaryPath) {
        Write-Host "Skip (installed): $binaryName"
        continue
    }
    Write-Host "Installing Go package: $pkgPath@$version"
    $env:CGO_ENABLED = '1'
    $installArgs = @('install')
    if ($tags.Count -gt 0) {
        $installArgs += @('-tags', ($tags -join ','))
    }
    $installArgs += "$pkgPath@$version"
    Invoke-Native go @installArgs
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "go $($installArgs -join ' ') failed with exit code $LASTEXITCODE. Skipping."
    } else {
        Write-Host "Installed $pkgPath"
    }
}
$goBin = Join-Path $env:USERPROFILE 'go\bin'
if (Test-Path -LiteralPath $goBin) {
    $userPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
    if ($userPath -notlike "*$goBin*") {
        [Environment]::SetEnvironmentVariable('PATH', "$goBin;$userPath", 'User')
        Write-Host "Added $goBin to user PATH"
    }
}

Update-Step 'Installing winget packages'
$wingetCmd = Get-Command winget -ErrorAction SilentlyContinue
if (-not $wingetCmd) {
    Write-Warning 'winget not found, skipping winget package install.'
} else {
    $wingetAllowedFile = Get-MainframeConfigPath -FileName 'winget-allowed.json'
    $wingetImport = Get-Content -LiteralPath $wingetAllowedFile -Raw | ConvertFrom-Json
    Write-Host "Using winget allowlist: $wingetAllowedFile ($(@($wingetImport.packages).Count) packages)"
    $installed_count = 0
    $skipped = 0
    foreach ($pkg in @($wingetImport.packages)) {
        $pkgId = if ($pkg -is [string]) { $pkg } else { $pkg.id }
        # Check if already installed
        $savedEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $existing = winget list --id $pkgId -e --accept-source-agreements 2>$null | Out-String
        $ErrorActionPreference = $savedEap
        if ($LASTEXITCODE -eq 0 -and $existing -match [regex]::Escape($pkgId)) {
            Write-Host "Skip (installed): $pkgId"
            $skipped++
            continue
        }
        Write-Host "Installing winget package: $pkgId"
        Invoke-Native winget install --id $pkgId -e --scope machine --accept-package-agreements --accept-source-agreements
        if ($LASTEXITCODE -ne 0) {
            # 0x8a150010 = APPINSTALLER_CLI_ERROR_NO_APPLICABLE_INSTALLER. manifests
            # with no declared Scope (Unknown) can never match a forced --scope machine
            # (observed: Windscribe, Wakatime.DesktopWakatime). retry without the
            # scope flag so winget uses the installer's own scope.
            if (([uint32]$LASTEXITCODE) -eq 0x8a150010) {
                Write-Warning "winget install $pkgId failed with 0x8a150010 (no applicable installer for machine scope). Retrying without --scope..."
                Invoke-Native winget install --id $pkgId -e --accept-package-agreements --accept-source-agreements
                if ($LASTEXITCODE -ne 0) {
                    Write-Warning "winget install $pkgId (unscoped retry) failed with exit code $LASTEXITCODE. Skipping."
                } else {
                    Write-Host "Installed $pkgId"
                    $installed_count++
                }
            } else {
                Write-Warning "winget install $pkgId failed with exit code $LASTEXITCODE. Skipping."
            }
        } else {
            Write-Host "Installed $pkgId"
            $installed_count++
        }
    }
    Write-Host "Done: $installed_count installed, $skipped skipped (already present)"

    # Restore persist data for winget packages that have it (AnyDesk, Directory Opus, etc.).
    # Backup wrote these under <BackupRoot>\native\<archivePath> using the same Write-NativePersistArchive function.
    $wingetPersistPkgs = @($wingetImport.packages | Where-Object { $_.persist })
    if ($wingetPersistPkgs.Count -gt 0 -and -not $SkipNativePersist) {
        foreach ($pkg in $wingetPersistPkgs) {
            Write-Host "Restoring persist for $($pkg.id)..."
            # Stop the service if it's a service-style app (DirectoryOpus/AnyDesk run as processes, not services, so this is mostly a no-op)
            $procName = if ($pkg.id -eq 'AnyDesk.AnyDesk') { 'anydesk' } elseif ($pkg.id -eq 'GPSoftware.DirectoryOpus') { 'dopus','dopusrt' } else { $null }
            $procsWereRunning = @()
            if ($procName) {
                foreach ($pn in @($procName)) {
                    $running = Get-Process -Name $pn -ErrorAction SilentlyContinue
                    if ($running) {
                        $procsWereRunning += $pn
                        $running | Stop-Process -Force -ErrorAction SilentlyContinue
                        Write-Host "  Stopped $pn for persist restore"
                    }
                }
                if ($procsWereRunning.Count -gt 0) { Start-Sleep -Seconds 2 }
            }
            try {
                foreach ($entry in @($pkg.persist)) {
                    $src = Join-Path $nativePersistDir $entry.archivePath
                    if (-not (Test-Path -LiteralPath $src)) {
                        Write-Warning "  Persist entry not found in backup: $($entry.archivePath)"
                        continue
                    }
                    $target = Resolve-TemplateString -Value $entry.path
                    New-Item -ItemType Directory -Force -Path $target | Out-Null
                    & robocopy $src $target /E $script:RoboCopyFlag /R:1 /W:1 /NP /NDL /NFL | Out-Null
                    if ($LASTEXITCODE -gt 7) {
                        Write-Warning "  Robocopy persist ($($entry.archivePath)) failed with exit code $LASTEXITCODE"
                    } else {
                        Write-Host "  Restored $($entry.archivePath) -> $target"
                    }
                }
            } finally {
                # Restart processes we stopped (DOpus at least benefits from it)
                foreach ($pn in $procsWereRunning) {
                    Start-Process -FilePath $pn -ErrorAction SilentlyContinue
                }
            }
        }
    }
}

# Re-apply local patches that the fresh scoop installs wipe out.
# - alist: terabox dm-domain fix (scoop reinstalls official binary without the patch)
# - ditto: user's merged-but-unreleased starred-clips PRs (scoop reinstalls official 3.25.113.0)
# Both patchers live in automata; skip quietly if absent (backup may not include automata).
Update-Step 'Re-applying local binary patches (alist, ditto)'
$automata = Join-Path $env:USERPROFILE 'Downloads\automata'
$alistPatcher = Join-Path $automata 'tools\alist-terabox\alist-terabox-patcher.ps1'
if (Test-Path -LiteralPath $alistPatcher) {
    Write-Host 'Re-applying AList terabox patch...'
    & pwsh -NoProfile -File $alistPatcher -NoRestart 2>&1 | Write-Host
} else {
    Write-Warning "alist patcher not found: $alistPatcher"
}
$dittoPatcher = Join-Path $automata 'tools\alist-terabox\ditto-fork-build.ps1'
if (Test-Path -LiteralPath $dittoPatcher) {
    Write-Host 'Re-building Ditto from fork (starred-clips PRs)...'
    & pwsh -NoProfile -File $dittoPatcher 2>&1 | Write-Host
} else {
    Write-Warning "ditto patcher not found: $dittoPatcher"
}

Write-Progress -Activity 'Restoring mainframe' -Completed
Write-Host 'Bootstrap complete. Restart PowerShell or log out/in if shell integration is not visible yet.'

