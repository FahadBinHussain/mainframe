param(
    [string]$ScoopRoot = $(if ($env:SCOOP) { $env:SCOOP } else { 'C:\Softwares\Scoop' }),
    [string]$OutputDir = $PSScriptRoot,
    [string]$AllowedAppsFile = (Join-Path $PSScriptRoot 'scoop-allowed.json'),
    [switch]$SkipPersist,
    [switch]$ExcludeSecrets,
    [string]$SecretsManifestPath,
    [switch]$SkipNativePersist,
    [string[]]$ScheduledTasksToExport = @()
)

$ErrorActionPreference = 'Stop'

# === Elevation guard ===
# VSS shadow creation and /COPYALL robocopies require admin. Refuse to produce a broken backup otherwise.
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "This script needs an elevated PowerShell (VSS + robocopy /COPYALL require admin)." -ForegroundColor Red
    Write-Host '  Re-launch via backup.cmd (which elevates) or run from a "Run as administrator" shell.' -ForegroundColor Yellow
    throw 'Elevation required.'
}

# === VSS (Volume Shadow Copy) helpers ===
# Creates a VSS shadow of C:\ and mounts it via a directory symlink so robocopy
# can read locked files (Cookies, Local State, dopus.dat, etc.) without closing
# the app that holds them. Same technique as edge-cdp-profile-sync.ps1.
# Requires an elevated shell with VSS enabled.

function New-VssShadow {
    param([string]$Volume = 'C:\')

    $mc = New-Object System.Management.ManagementClass(
        [System.Management.ManagementScope]::new('\\.\root\cimv2'),
        [System.Management.ManagementPath]::new('Win32_ShadowCopy'),
        $null)
    $inParams = $mc.GetMethodParameters('Create')
    $inParams['Volume']  = $Volume
    $inParams['Context'] = 'ClientAccessible'
    $outParams = $mc.InvokeMethod('Create', $inParams, $null)
    if ($outParams.ReturnValue -ne 0) {
        throw "Win32_ShadowCopy.Create returned error code $($outParams.ReturnValue) (7=not supported, 8=volume not found, 12=max snapshots exceeded) - usually means this shell is not elevated"
    }
    $shadowId = $outParams.ShadowID
    $shadow = Get-CimInstance -ClassName Win32_ShadowCopy | Where-Object { $_.Id -eq $shadowId } | Select-Object -First 1
    if (-not $shadow) { throw "shadow created (ID=$shadowId) but not returned by Win32_ShadowCopy query" }
    Write-Host "[vss] shadow created: $($shadow.DeviceObject)" -ForegroundColor Cyan
    return $shadow.DeviceObject
}

function Convert-ToShadowPath {
    param(
        [Parameter(Mandatory)][string]$RealPath,
        [Parameter(Mandatory)][string]$ShadowDevice
    )
    # robocopy can't read \\?\GLOBALROOT\... device paths directly.
    # create a dir symlink pointing at the shadow root, then append the
    # path-after-drive to get a normal Win32 path into the shadow.
    $vssLink = Join-Path $env:TEMP "vss-link-$([Guid]::NewGuid().ToString('N'))"
    $mkOut = cmd /c mklink /d "$vssLink" "$ShadowDevice\" 2>&1
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $vssLink -PathType Container)) {
        throw "mklink /d failed (exit=$LASTEXITCODE, output=$mkOut)"
    }
    $pathAfterDrive = $RealPath -replace '^[A-Za-z]:\\',''
    $shadowPath = Join-Path $vssLink $pathAfterDrive
    if (-not (Test-Path -LiteralPath $shadowPath)) {
        Remove-Item -LiteralPath $vssLink -Force -Recurse -ErrorAction SilentlyContinue
        throw "VSS symlink created but couldn't resolve $shadowPath"
    }
    return [pscustomobject]@{ ShadowPath = $shadowPath; Link = $vssLink }
}

function Remove-VssShadow {
    param(
        [string]$ShadowDevice,
        [string]$VssLink
    )
    if ($ShadowDevice) {
        try {
            $shadows = Get-CimInstance -ClassName Win32_ShadowCopy | Where-Object { $_.DeviceObject -eq $ShadowDevice }
            $shadows | Remove-CimInstance -ErrorAction SilentlyContinue
            Write-Host "[vss] shadow dropped: $ShadowDevice" -ForegroundColor DarkGray
        } catch {}
    }
    if ($VssLink -and (Test-Path -LiteralPath $VssLink)) {
        Remove-Item -LiteralPath $VssLink -Force -Recurse -ErrorAction SilentlyContinue
    }
}

$scoopfile = Join-Path $OutputDir 'scoopfile.json'
$persistIncludeFile = Join-Path $PSScriptRoot 'persist-include.json'
$persistPath = Join-Path $ScoopRoot 'persist'

if (-not $SecretsManifestPath) {
    $SecretsManifestPath = Join-Path $PSScriptRoot 'tool-secrets.manifest.json'
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

    throw 'Scoop command not found.'
}

function Invoke-RobocopyLockedAware {
    param(
        [Parameter(Mandatory)]
        [string[]]$RobocopyArgs,
        [string]$Context = 'robocopy'
    )
    $rcLog = Join-Path $env:TEMP "robocopy-log-$(Get-Random).txt"
    $RobocopyArgs += "/LOG:$rcLog"
    $null = robocopy @RobocopyArgs
    $rcExit = $LASTEXITCODE
    $logContent = $null
    if (Test-Path $rcLog) {
        $logContent = Get-Content $rcLog -Raw
        Remove-Item $rcLog -Force -ErrorAction SilentlyContinue
    }
    if ($rcExit -le 7) { return }
    $skipped = @()
    if ($logContent) {
        $matches = [regex]::Matches($logContent, 'ERROR \d+ \(0x[0-9A-Fa-f]+\) Copying File\s+([^\r\n]+)')
        foreach ($m in $matches) {
            $filePath = $m.Groups[1].Value.Trim()
            if ($filePath) {
                $skipped += $filePath
                Write-Warning "file $filePath is locked, skipping and going ahead"
            }
        }
    }
    if ($rcExit -ge 16 -or $skipped.Count -eq 0) {
        throw "$Context failed with exit code $rcExit"
    }
}

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

function Get-MainframeAccountRoot {
    param([string]$Service)

    Join-Path $env:APPDATA "mainframe\accounts\$Service"
}

function Write-NativePersistArchive {
    param(
        [object[]]$Apps,
        [string]$VssShadowDevice
    )

    if ($SkipNativePersist -or $Apps.Count -eq 0) {
        return
    }

    $appsWithPersist = @($Apps | Where-Object { @($_.Persist).Count -gt 0 })
    if ($appsWithPersist.Count -eq 0) {
        return
    }

    $nativeDir = Join-Path $OutputDir 'native'
    New-Item -ItemType Directory -Force -Path $nativeDir | Out-Null

    foreach ($app in $appsWithPersist) {
        $serviceWasRunning = $false
        if ($app.ServiceName) {
            $service = Get-Service -Name $app.ServiceName -ErrorAction SilentlyContinue
            if ($service -and $service.Status -ne 'Stopped') {
                $serviceWasRunning = $true
                Stop-Service -Name $app.ServiceName -Force
            }
        }

        try {
            foreach ($entry in @($app.Persist)) {
                $source = Resolve-TemplateString -Value $entry.Path
                if (-not (Test-Path -LiteralPath $source)) {
                    Write-Warning "Native persist path not found: $source"
                    continue
                }

                $destination = Join-Path $nativeDir $entry.ArchivePath
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null

                # Try VSS first (if a shadow is available) to avoid closing the app.
                # Falls back to direct robocopy (which skips locked files) if VSS
                # isn't available or fails for this path.
                $actualSource = $source
                $vssInfo = $null
                if ($VssShadowDevice -and $source -match '^[A-Za-z]:\\') {
                    try {
                        $vssInfo = Convert-ToShadowPath -RealPath $source -ShadowDevice $VssShadowDevice
                        $actualSource = $vssInfo.ShadowPath
                    } catch {
                        Write-Warning "VSS path resolution failed for $($app.Name), falling back to direct copy: $($_.Exception.Message)"
                        $vssInfo = $null
                    }
                }
                Invoke-RobocopyLockedAware -RobocopyArgs @($actualSource, $destination, '/E', '/COPYALL', '/R:1', '/W:1', '/NP', '/NDL', '/NFL', '/XD', 'Thumbnail Cache', 'Cache', 'logs') -Context "native persist $($app.Name)"
                if ($vssInfo) { Remove-VssShadow -VssLink $vssInfo.Link }
            }
        } finally {
            if ($serviceWasRunning) {
                Start-Service -Name $app.ServiceName -ErrorAction SilentlyContinue
            }
        }
    }
}

function Write-ToolSecretsArchive {
    if ($ExcludeSecrets) {
        return
    }

    $manifest = Get-Content -LiteralPath $SecretsManifestPath -Raw | ConvertFrom-Json
    $secretsDir = Join-Path $OutputDir 'secrets'
    New-Item -ItemType Directory -Force -Path $secretsDir | Out-Null
    $values = @{
        AppData = $env:APPDATA
        LocalAppData = $env:LOCALAPPDATA
        ProgramData = $env:ProgramData
        ScriptRoot = $PSScriptRoot
        UserProfile = $env:USERPROFILE
    }
    foreach ($item in @($manifest.items | Where-Object { -not $_.Disabled })) {
        $source = Resolve-TemplateString -Value $item.Source -Values $values
        if (-not (Test-Path -LiteralPath $source)) {
            Write-Warning "Secret path not found, skipping $($item.Name): $source"
            continue
        }
        $dest = Join-Path $secretsDir $item.ArchivePath
        Write-Host "Copying secret: $($item.Name)"
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
        if (Test-Path -LiteralPath $source -PathType Container) {
            # Exclude large on-device LLM models, runtime packages, browser UI temp/cache dirs,
            # IndexedDB blob storage, SQLite temps, and history files to keep backup sizes minimal.
            # Per-item excludeDirs/excludeFiles from the manifest get appended (robocopy accepts
            # multiple /XD and /XF), e.g. opencode log + tool-output scratch.
            $rcArgs = @(
                $source, $dest, '/E', '/COPYALL', '/R:1', '/W:1', '/NP', '/NDL', '/NFL',
                '/XD', 'agent-browser', 'Cache', 'Code Cache', 'GPUCache', 'Service Worker', 'Storage', 'Session Storage', 'Local Storage', 'Crashpad', 'component_crx_cache', 'BrowserMetrics', 'Safe Browsing', 'GrShaderCache', 'ShaderCache', 'DawnGraphiteCache', 'DawnWebGPUCache', 'GraphiteDawnCache', 'Shared Dictionary', 'File System', 'logs', 'xet', 'shard-cache', 'blob-storage', 'EdgeLLMOnDeviceModel', 'EdgeLLMRuntime', 'Edge Entity Extraction', '*.blob', 'cached-microdescs', 'cached-certs', 'cached-consensus', 'geoip', 'GeoIP', 'ProvenanceData', 'ProvenanceDataTensors', 'https_photos.google.com_0.indexeddb.leveldb', 'https_www.messenger.com_0.indexeddb.leveldb', 'https_www.facebook.com_0.indexeddb.leveldb', 'https_www.reddit.com_0.indexeddb.leveldb',
                '/XF', 'History', 'load_statistics.db', '*.db-journal', '*.db-wal', '*.db-shm', '*.pdb', '*.js.map', '*.wasm', 'typescript.js', '*.quant.ort'
            )
            if ($item.ExcludeDirs) {
                $rcArgs += '/XD'
                $rcArgs += @($item.ExcludeDirs)
            }
            if ($item.ExcludeFiles) {
                $rcArgs += '/XF'
                $rcArgs += @($item.ExcludeFiles)
            }
            Invoke-RobocopyLockedAware -RobocopyArgs $rcArgs -Context "secret $($item.Name)"
        } else {
            Copy-Item -LiteralPath $source -Destination $dest -Force
        }
    }
}

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$realOutputDir = $OutputDir
$OutputDir = Join-Path $env:TEMP "mainframe-backup-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$scoopfile = Join-Path $OutputDir 'scoopfile.json'

$scoop = Get-ScoopCommand
Write-Host "Writing $scoopfile"
$exportJson = & $scoop export --config
if ($LASTEXITCODE -ne 0) {
    throw "scoop export failed with exit code $LASTEXITCODE"
}

$export = $exportJson | ConvertFrom-Json

$globalAppsDir = Join-Path $ScoopRoot 'apps'
if (Test-Path -LiteralPath $globalAppsDir) {
    $existingNames = @($export.apps | ForEach-Object { $_.Name })
    Get-ChildItem -LiteralPath $globalAppsDir -Directory | ForEach-Object {
        if ($existingNames -contains $_.Name) { return }
        $installJson = Join-Path $_.FullName 'install.json'
        if (-not (Test-Path -LiteralPath $installJson)) { return }
        $installData = Get-Content -LiteralPath $installJson -Raw | ConvertFrom-Json
        if ($installData.global -ne $true) { return }
        $manifestJson = Join-Path $_.FullName 'current\manifest.json'
        $version = $null
        $source = '<auto-generated>'
        if (Test-Path -LiteralPath $manifestJson) {
            $manifest = Get-Content -LiteralPath $manifestJson -Raw | ConvertFrom-Json
            $version = $manifest.version
            $source = $manifest.homepage
        }
        $export.apps += [PSCustomObject]@{
            Name = $_.Name
            Version = $version
            Source = $source
            Info = 'Global install'
            Updated = (Get-Item $_.FullName).LastWriteTime.ToString('o')
        }
        Write-Host "  Found global app: $($_.Name)"
    }
}

if (-not (Test-Path -LiteralPath $AllowedAppsFile)) {
    throw "Missing required allowlist: $AllowedAppsFile"
}

$allowed = (Get-Content -LiteralPath $AllowedAppsFile -Raw | ConvertFrom-Json).apps
$filtered = @($export.apps | Where-Object { $allowed -contains $_.Name })
$export.apps = $filtered
$export | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $scoopfile -Encoding UTF8
Write-Host "Filtered to $($filtered.Count) allowed apps (from $($allowed.Count) in list)"

if ($SkipPersist) {
    Write-Warning 'Skipped scoop persist data.'
} else {
    if (-not (Test-Path -LiteralPath $persistPath)) {
        throw "Scoop persist folder not found: $persistPath"
    }

    $persistInclude = if (Test-Path -LiteralPath $persistIncludeFile) {
        (Get-Content -LiteralPath $persistIncludeFile -Raw | ConvertFrom-Json).include
    } else {
        @('*')
    }

    $persistDir = Join-Path $OutputDir 'persist'
    New-Item -ItemType Directory -Force -Path $persistDir | Out-Null
    Write-Host "Copying scoop persist data to $persistDir"
    $excludeDirs = @(
        'pnpm', 'cursor', 'android-clt', 'qbittorrent', 'nodejs-lts',
        'vscode', 'rustup', 'python', 'windsurf',
        'bun', 'deno', 'uv', 'php', 'gcc', 'discord', 'mariadb', 'postgresql', 'lmstudio',
        'steam',
        'obs-studio'
    )
    $torBrowserCacheExcludes = @(
        'storage', 'shader-cache',
        'sessionstore-backups', 'cache2', 'thumbnails',
        'cached-microdescs', 'cached-certs', 'cached-consensus',
        'Cache', 'code cache', 'GPUCache', 'Service Worker'
    )
    $torBrowserFileExcludes = @('cached-microdesc*', 'cached-certs', 'cached-descriptors*', 'geoip', 'geoip6', '*.sock', '*.log')
    $obsCacheExcludes = @('logs', 'crashes', 'profiler_data', 'locale', 'luma_wipes', 'obs-studio', 'data', 'obs-plugins')
    if ($persistInclude.Count -eq 1 -and $persistInclude[0] -eq '*') {
        $items = Get-ChildItem -LiteralPath $persistPath -Directory | Where-Object { $_.Name -notin $excludeDirs }
        foreach ($item in $items) {
            $dest = Join-Path $persistDir $item.Name
            if ($item.Name -eq 'tor-browser') {
                $torRoboArgs = @($item.FullName, $dest, '/E', '/COPYALL', '/R:1', '/W:1', '/NP', '/NDL', '/NFL', '/XD') + $torBrowserCacheExcludes + @('/XF') + $torBrowserFileExcludes + @('/XD', 'moz-extension+++*')
                Invoke-RobocopyLockedAware -RobocopyArgs $torRoboArgs -Context "persist tor-browser"
            } elseif ($item.Name -eq 'windhawk') {
                Invoke-RobocopyLockedAware -RobocopyArgs @($item.FullName, $dest, '/E', '/COPYALL', '/R:1', '/W:1', '/NP', '/NDL', '/NFL', '/XD', 'Cache', 'CachedData', 'Service Worker', 'Code Cache', 'GPUCache') -Context "persist windhawk"
            } elseif ($item.Name -eq 'ditto') {
                # Ditto's clip DB can be huge (2GB+); keep settings, skip the DB.
                Invoke-RobocopyLockedAware -RobocopyArgs @($item.FullName, $dest, '/E', '/COPYALL', '/R:1', '/W:1', '/NP', '/NDL', '/NFL', '/XF', 'Ditto.db') -Context "persist ditto"
            } else {
                Invoke-RobocopyLockedAware -RobocopyArgs @($item.FullName, $dest, '/E', '/COPYALL', '/R:1', '/W:1', '/NP', '/NDL', '/NFL') -Context "persist $($item.Name)"
            }
        }
    } else {
        foreach ($item in $persistInclude) {
            $src = Join-Path $persistPath $item
            if (Test-Path -LiteralPath $src) {
                $dest = Join-Path $persistDir $item
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
                Invoke-RobocopyLockedAware -RobocopyArgs @($src, $dest, '/E', '/COPYALL', '/R:1', '/W:1', '/NP', '/NDL', '/NFL') -Context "persist $item"
            }
        }
    }
}

# Winget-managed apps may also have persist directories (AnyDesk, Directory Opus, etc.).
# Shape winget-allowed packages into the same {Name, Persist, ServiceName} shape Write-NativePersistArchive expects.
# Create a shared VSS shadow for native persist copies (Directory Opus holds
# dopus.dat with an exclusive handle; without VSS we'd have to kill DOpus).
$wingetAllowedPersistFile = Join-Path $PSScriptRoot 'winget-allowed.json'
if (Test-Path -LiteralPath $wingetAllowedPersistFile) {
    $wingetAllowedCfg = Get-Content -LiteralPath $wingetAllowedPersistFile -Raw | ConvertFrom-Json
    $wingetAppsForPersist = @($wingetAllowedCfg.packages | Where-Object { $_.persist } | ForEach-Object {
        [PSCustomObject]@{ Name = $_.id; Persist = $_.persist; ServiceName = $null }
    })
    if ($wingetAppsForPersist.Count -gt 0) {
        $nativeShadowDevice = $null
        try {
            $nativeShadowDevice = New-VssShadow
            Write-Host "[vss] using shadow for native persist (DOpus left running)" -ForegroundColor Cyan
        } catch {
            Write-Warning "VSS unavailable for native persist ($($_.Exception.Message)) - will copy directly (locked files skipped)"
        }
        try {
            Write-NativePersistArchive -Apps $wingetAppsForPersist -VssShadowDevice $nativeShadowDevice
        } finally {
            if ($nativeShadowDevice) { Remove-VssShadow -ShadowDevice $nativeShadowDevice }
        }
    }
}

Write-ToolSecretsArchive

Write-Host "Exporting uv tools..."
$uvAllowedFile = Join-Path $PSScriptRoot 'uv-allowed.json'
$uvGlobalsFile = Join-Path $OutputDir 'uv-tools.json'
if (-not (Test-Path -LiteralPath $uvAllowedFile)) {
    throw "Missing required allowlist: $uvAllowedFile"
}

$allowed = (Get-Content -LiteralPath $uvAllowedFile -Raw | ConvertFrom-Json).packages
$allTools = @()
$toolListOutput = & uv tool list 2>$null
foreach ($line in $toolListOutput) {
    if ($line -match '^\s*(\S+)') {
        $toolName = $matches[1]
        if ($toolName -ne 'Name' -and $toolName -ne '----' -and $toolName -notin @('No', 'Tool')) {
            $allTools += $toolName
        }
    }
}
$filtered = @($allTools | Where-Object { $allowed -contains $_ })
@{ packages = @($filtered) } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $uvGlobalsFile -Encoding UTF8
Write-Host "Exported $($filtered.Count) uv tools (from $($allowed.Count) in allowlist)"

Write-Host "Exporting pnpm global packages..."
$pnpmAllowedFile = Join-Path $PSScriptRoot 'pnpm-allowed.json'
$pnpmGlobalsFile = Join-Path $OutputDir 'pnpm-globals.json'
if (-not (Test-Path -LiteralPath $pnpmAllowedFile)) {
    throw "Missing required allowlist: $pnpmAllowedFile"
}

$allowed = (Get-Content -LiteralPath $pnpmAllowedFile -Raw | ConvertFrom-Json).packages
@{ packages = @($allowed) } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $pnpmGlobalsFile -Encoding UTF8
Write-Host "Exported $($allowed.Count) pnpm global packages from allowlist"

Write-Host "Exporting pnpm config..."
$pnpmConfigFile = Join-Path $OutputDir 'pnpm-config.json'
$pnpmGlobalBinDir = $null
try {
    $pnpmGlobalBinDir = pnpm config get global-bin-dir 2>$null
} catch {}
if (-not $pnpmGlobalBinDir) {
    $pnpmGlobalBinDir = Join-Path $env:USERPROFILE '.pnpm-global\bin'
}
@{ globalBinDir = $pnpmGlobalBinDir } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $pnpmConfigFile -Encoding UTF8
Write-Host "Exported pnpm global-bin-dir: $pnpmGlobalBinDir"

Write-Host "Exporting pip packages..."
$pipAllowedFile = Join-Path $PSScriptRoot 'pip-allowed.json'
$pipPackagesFile = Join-Path $OutputDir 'pip-packages.json'
if (-not (Test-Path -LiteralPath $pipAllowedFile)) {
    throw "Missing required allowlist: $pipAllowedFile"
}

$allowed = (Get-Content -LiteralPath $pipAllowedFile -Raw | ConvertFrom-Json).packages
$installed = @()
$freezeLines = & pip list --format=freeze 2>$null
foreach ($line in $freezeLines) {
    if ($line -match '^([^=]+)==') {
        $installed += $matches[1]
    }
}
$filtered = @($installed | Where-Object { $allowed -contains $_ })
@{ packages = @($filtered) } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $pipPackagesFile -Encoding UTF8
Write-Host "Exported $($filtered.Count) pip packages (from $($allowed.Count) in allowlist)"

Write-Host "Backing up OBS Studio settings..."
$obsPersistConfig = Join-Path $persistPath 'obs-studio\config\obs-studio'
if (Test-Path -LiteralPath $obsPersistConfig) {
    $obsDest = Join-Path $OutputDir 'obs-studio'
    New-Item -ItemType Directory -Force -Path $obsDest | Out-Null
    Invoke-RobocopyLockedAware -RobocopyArgs @(
        $obsPersistConfig, $obsDest, '/E', '/COPYALL', '/R:1', '/W:1', '/NP', '/NDL', '/NFL',
        '/XD', 'logs', 'crashes', 'profiler_data', 'Cache', 'Code Cache', 'GPUCache', 'Service Worker', 'DawnGraphiteCache', 'DawnWebGPUCache', 'ShaderCache', 'GrShaderCache', 'GraphiteDawnCache', 'blob_storage', 'Network', 'component_crx_cache', 'WidevineCdm',
        '/XF', '*.db-journal', '*.db-wal', '*.db-shm'
    ) -Context 'OBS settings'
    Write-Host "  Copied OBS scenes, profiles, and config"
} else {
    Write-Warning "OBS persist config not found: $obsPersistConfig"
}

Write-Host "Backing up qBittorrent settings..."
$qbtPersistConfig = Join-Path $persistPath 'qbittorrent\profile\qBittorrent'
if (Test-Path -LiteralPath $qbtPersistConfig) {
    $qbtDest = Join-Path $OutputDir 'qbittorrent'
    New-Item -ItemType Directory -Force -Path $qbtDest | Out-Null
    Invoke-RobocopyLockedAware -RobocopyArgs @(
        $qbtPersistConfig, $qbtDest, '/E', '/COPYALL', '/R:1', '/W:1', '/NP', '/NDL', '/NFL',
        '/XD', 'downloads', 'cache', 'logs',
        '/XF', 'lockfile'
    ) -Context 'qBittorrent settings'
    Write-Host "  Copied qBittorrent config, WebUI creds, categories, and watched folders (downloads excluded)"
} else {
    Write-Warning "qBittorrent persist config not found: $qbtPersistConfig"
}

# mpv "Play with mpv" context menu + user environment (PATH with python312 +
# site-packages\vapoursynth for vsscript.dll) - registry snapshots so a machine
# migration restores them alongside the scoop apps. The vs-rife software folder
# itself is NOT part of mainframe backup - it's covered by the separate
# software-folder backup.
& reg.exe export "HKCU\Software\Classes\*\shell\Play with mpv" (Join-Path $OutputDir 'mpv-contextmenu.reg') /y *> $null
if ($LASTEXITCODE -eq 0) { Write-Host 'Exported mpv context menu (Play with mpv)' }
& reg.exe export "HKCU\Environment" (Join-Path $OutputDir 'user-env.reg') /y *> $null
if ($LASTEXITCODE -eq 0) { Write-Host 'Exported user environment (PATH)' }

Write-Host "Backing up Edge browser profile..."
$edgeUserData = Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data'
# VSS: copy Edge User Data from a Volume Shadow Copy so we DON'T need to close
# real Edge. Edge holds Cookies, Local State, Preferences, Session Storage with
# exclusive write handles - a live robocopy silently skips them and produces a
# corrupt profile. VSS reads the shadow (point-in-time snapshot) so all locked
# files come through without closing Edge.
if (Test-Path -LiteralPath $edgeUserData) {
    $edgeShadowDevice = $null
    $edgeShadowInfo = $null
    try {
        $edgeShadowDevice = New-VssShadow
        $edgeShadowInfo = Convert-ToShadowPath -RealPath $edgeUserData -ShadowDevice $edgeShadowDevice
        $edgeUserDataShadow = $edgeShadowInfo.ShadowPath
        Write-Host "[vss] using shadow for Edge (real Edge left running)" -ForegroundColor Cyan
        $edgeDest = Join-Path $OutputDir 'edge-profile'
        New-Item -ItemType Directory -Force -Path $edgeDest | Out-Null
        Invoke-RobocopyLockedAware -RobocopyArgs @(
            $edgeUserDataShadow, $edgeDest, '/E', '/COPYALL', '/R:1', '/W:1', '/NP', '/NDL', '/NFL', '/XJ',
            '/XD', 'Cache', 'Code Cache', 'GPUCache', 'Service Worker', 'DawnGraphiteCache', 'DawnWebGPUCache', 'GrShaderCache', 'ShaderCache', 'GraphiteDawnCache', 'blob_storage', 'Crashpad', 'component_crx_cache', 'ProvenanceData', 'ProvenanceDataTensors', 'Subresource Filter', 'BrowserMetrics', 'Safe Browsing', 'Shared Dictionary', 'File System', 'logs', '*.blob', 'Edge Entity Extraction', 'Edge Shopping', 'Edge Wallet', 'EdgeCoupons', 'EdgeLanguageDetectionModel', 'Edge Sidebar', 'EdgeTravel', 'EdgeCDSScheduler', 'EdgePushNotificationClient', 'EdgeDrop', 'EdgeCollections', 'EdgeTrackingPrevention', 'EdgeFavoritesBackup', 'WidevineCdm', 'image_cache', 'Speech Recognition', 'RecoveryImproved', 'hyphen-data', 'ZxcvbnData', 'OneAuth', 'Edge Signal Triggers', 'https_photos.google.com_0.indexeddb.leveldb', 'https_www.messenger.com_0.indexeddb.leveldb', 'https_www.facebook.com_0.indexeddb.leveldb', 'https_www.reddit.com_0.indexeddb.leveldb', 'https_dbc-*_0.indexeddb.leveldb', 'https_accounts.cloud.databricks.com_0.indexeddb.leveldb', 'https_docs.google.com_0.indexeddb.leveldb', 'https_drive.google.com_0.indexeddb.leveldb',
            '/XF', 'History', 'load_statistics.db', '*.db-journal', '*.db-wal', '*.db-shm', '*.js.map', '*.wasm', 'typescript.js', '*.quant.ort'
        ) -Context 'Edge profile (VSS)'
        Write-Host "  Copied Edge browser profile via VSS"
    } catch {
        Write-Warning "VSS Edge backup failed: $($_.Exception.Message)"
        Write-Warning "Falling back to closing Edge for backup..."
        $edgeProcs = Get-Process -Name 'msedge' -ErrorAction SilentlyContinue
        if ($edgeProcs) {
            $edgeProcs | Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 3
        }
        $edgeDest = Join-Path $OutputDir 'edge-profile'
        New-Item -ItemType Directory -Force -Path $edgeDest | Out-Null
        Invoke-RobocopyLockedAware -RobocopyArgs @(
            $edgeUserData, $edgeDest, '/E', '/COPYALL', '/R:1', '/W:1', '/NP', '/NDL', '/NFL', '/XJ',
            '/XD', 'Cache', 'Code Cache', 'GPUCache', 'Service Worker', 'DawnGraphiteCache', 'DawnWebGPUCache', 'GrShaderCache', 'ShaderCache', 'GraphiteDawnCache', 'blob_storage', 'Crashpad', 'component_crx_cache', 'ProvenanceData', 'ProvenanceDataTensors', 'Subresource Filter', 'BrowserMetrics', 'Safe Browsing', 'Shared Dictionary', 'File System', 'logs', '*.blob', 'Edge Entity Extraction', 'Edge Shopping', 'Edge Wallet', 'EdgeCoupons', 'EdgeLanguageDetectionModel', 'Edge Sidebar', 'EdgeTravel', 'EdgeCDSScheduler', 'EdgePushNotificationClient', 'EdgeDrop', 'EdgeCollections', 'EdgeTrackingPrevention', 'EdgeFavoritesBackup', 'WidevineCdm', 'image_cache', 'Speech Recognition', 'RecoveryImproved', 'hyphen-data', 'ZxcvbnData', 'OneAuth', 'Edge Signal Triggers', 'https_photos.google.com_0.indexeddb.leveldb', 'https_www.messenger.com_0.indexeddb.leveldb', 'https_www.facebook.com_0.indexeddb.leveldb', 'https_www.reddit.com_0.indexeddb.leveldb', 'https_dbc-*_0.indexeddb.leveldb', 'https_accounts.cloud.databricks.com_0.indexeddb.leveldb', 'https_docs.google.com_0.indexeddb.leveldb', 'https_drive.google.com_0.indexeddb.leveldb',
            '/XF', 'History', 'load_statistics.db', '*.db-journal', '*.db-wal', '*.db-shm', '*.js.map', '*.wasm', 'typescript.js', '*.quant.ort'
        ) -Context 'Edge profile (fallback)'
        Write-Host "  Copied Edge browser profile (fallback)"
    } finally {
        if ($edgeShadowDevice) { Remove-VssShadow -ShadowDevice $edgeShadowDevice -VssLink $edgeShadowInfo.Link }
    }
} else {
    Write-Warning "Edge User Data not found: $edgeUserData"
}

# Extract the store-installed extension list from the backed-up profile so a
# restore on a DIFFERENT pc can force-reinstall them from the store. Edge 151+
# validates store-extension install signatures against the machine ID (RLZ) -
# a profile restored on another pc fails that check and Edge silently removes
# every loc=1 store extension on first launch. The extension FILES and settings
# we copy can't survive that, but the store reinstall via ExtensionInstallForcelist
# policy can (see restore.ps1 Restore-EdgeExtensions).
$edgeBackupProfile = Join-Path $OutputDir 'edge-profile\Default\Secure Preferences'
if (Test-Path -LiteralPath $edgeBackupProfile) {
    try {
        $edgeSp = Get-Content -LiteralPath $edgeBackupProfile -Raw | ConvertFrom-Json
        $edgeStoreExts = @()
        if ($edgeSp.extensions.settings.PSObject.Properties) {
            foreach ($prop in $edgeSp.extensions.settings.PSObject.Properties) {
                $ext = $prop.Value
                if ($ext.location -eq 1 -and $ext.manifest.update_url) {
                    $edgeStoreExts += [pscustomobject]@{
                        id             = $prop.Name
                        name           = $ext.manifest.name
                        update_url     = $ext.manifest.update_url
                        version        = $ext.manifest.version
                        disable_reason = $ext.disable_reasons
                    }
                }
            }
        }
        $edgeExtListPath = Join-Path $OutputDir 'edge-profile\extensions-list.json'
        $edgeStoreExts | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $edgeExtListPath -Encoding UTF8
        Write-Host "  Saved $($edgeStoreExts.Count) Edge store extensions to edge-profile\extensions-list.json"
    } catch {
        Write-Warning "Could not extract Edge extension list: $($_.Exception.Message)"
    }
} else {
    Write-Host "  No Edge Secure Preferences found to extract extensions from"
}

# Back up unpacked developer-mode extensions (loc=4) — they load from local
# project folders outside the Edge profile. Edge 151+ prunes loc=4 entries
# cross-machine, but --load-extension on the target machine re-registers them
# as loc=8 (command-line loaded) which persists. We copy the source folders
# into the backup so restore.ps1 can place them on the target.
$edgeBackupProfile = Join-Path $OutputDir 'edge-profile\Default\Secure Preferences'
if (Test-Path -LiteralPath $edgeBackupProfile) {
    try {
        $edgeSp = Get-Content -LiteralPath $edgeBackupProfile -Raw | ConvertFrom-Json
        $unpackedExts = @()
        if ($edgeSp.extensions.settings.PSObject.Properties) {
            foreach ($prop in $edgeSp.extensions.settings.PSObject.Properties) {
                $ext = $prop.Value
                if ($ext.location -eq 4 -and $ext.path) {
                    $unpackedExts += [pscustomobject]@{
                        id   = $prop.Name
                        name = $ext.manifest.name
                        path = $ext.path
                    }
                }
            }
        }
        if ($unpackedExts.Count -gt 0) {
            $unpackedDest = Join-Path $OutputDir 'edge-profile\unpacked-extensions'
            New-Item -ItemType Directory -Force -Path $unpackedDest | Out-Null
            $withPaths = @()
            foreach ($ux in $unpackedExts) {
                $src = $ux.path
                $rel = $null
                if (Test-Path -LiteralPath $src) {
                    $folderName = Split-Path -Leaf $src
                    $dest = Join-Path $unpackedDest "$($ux.id)-$folderName"
                    & robocopy $src $dest /E /COPYALL /R:1 /W:1 /NP /NDL /NFL | Out-Null
                    $rel = "$($ux.id)-$folderName"
                } else {
                    Write-Warning "  Unpacked extension source not found: $src"
                }
                # Build the record in one shot so relative_path is always a member
                # (mutating a hashtable-derived PSCustomObject via $ux.x = throws
                # under StrictMode and previously swallowed the whole try block,
                # leaving unpacked-extensions.json unwritten).
                $withPaths += [pscustomobject]@{
                    id            = $ux.id
                    name          = $ux.name
                    path          = $ux.path
                    relative_path = $rel
                }
            }
            $unpackedListPath = Join-Path $OutputDir 'edge-profile\unpacked-extensions.json'
            $withPaths | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $unpackedListPath -Encoding UTF8
            Write-Host "  Backed up $($withPaths.Count) unpacked dev-mode extensions to edge-profile\unpacked-extensions"
        }
    } catch {
        Write-Warning "Could not extract unpacked extension info: $($_.Exception.Message)"
    }
}

Write-Host "Exporting scheduled tasks..."
$tasksDir = Join-Path $OutputDir 'scheduled-tasks'
New-Item -ItemType Directory -Force -Path $tasksDir | Out-Null
$taskNames = $ScheduledTasksToExport
foreach ($taskName in $taskNames) {
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($task) {
        $task | Export-ScheduledTask | Out-File -LiteralPath (Join-Path $tasksDir "$taskName.xml") -Encoding UTF8
        Write-Host "  Exported: $taskName"
    }
}

foreach ($script in @('restore.cmd', 'restore.ps1', 'restore-secrets.ps1', 'tool-secrets.manifest.json', 'wipe.cmd', 'wipe.ps1')) {
    $src = Join-Path $PSScriptRoot $script
    if (Test-Path -LiteralPath $src) {
        Copy-Item -LiteralPath $src -Destination (Join-Path $OutputDir $script) -Force
    }
}

foreach ($allowlist in @('scoop-allowed.json', 'pnpm-allowed.json', 'uv-allowed.json', 'go-allowed.json', 'winget-allowed.json', 'pip-allowed.json')) {
    $src = Join-Path $PSScriptRoot $allowlist
    if (Test-Path -LiteralPath $src) {
        Copy-Item -LiteralPath $src -Destination (Join-Path $OutputDir $allowlist) -Force
        Write-Host "Copied $allowlist"
    } else {
        Write-Warning "Missing allowlist in source, backup may be incomplete: $allowlist"
    }
}

$agentsMd = Join-Path $env:USERPROFILE 'AGENTS.md'
if (Test-Path -LiteralPath $agentsMd) {
    Copy-Item -LiteralPath $agentsMd -Destination (Join-Path $OutputDir 'AGENTS.md') -Force
    Write-Host 'Copied AGENTS.md'
}

$agentSkills = Join-Path $env:USERPROFILE '.agents\skills'
if (Test-Path -LiteralPath $agentSkills) {
    $dest = Join-Path $OutputDir '.agents\skills'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
    # Use robocopy instead of Copy-Item to skip self-nested 'skills' subdirs
    # (a botched skill install/sync copied the tree into itself 6+ levels deep,
    # duplicating ~24 MB). /XD skills excludes any subdir named 'skills' inside
    # the source, breaking the recursion.
    Invoke-RobocopyLockedAware -RobocopyArgs @(
        $agentSkills, $dest, '/E', '/COPYALL', '/R:1', '/W:1', '/NP', '/NDL', '/NFL', '/XD', 'skills'
    ) -Context '.agents\skills'
    Write-Host 'Copied .agents\skills'
}

$gitconfig = Join-Path $env:USERPROFILE '.gitconfig'
if (Test-Path -LiteralPath $gitconfig) {
    Copy-Item -LiteralPath $gitconfig -Destination (Join-Path $OutputDir '.gitconfig') -Force
    Write-Host 'Copied .gitconfig'
}

# qBittorrent file associations (.torrent / magnet) live in HKCU\Software\Classes —
# export them per key so they survive machine migrations alongside the zip.
# restored by restore.ps1 (reg import of each qb-assoc-*.reg).
$qbAssocKeys = @{
    'qb-assoc-torrent.reg'      = 'HKCU\Software\Classes\.torrent'
    'qb-assoc-torrentclass.reg' = 'HKCU\Software\Classes\qBittorrent.Torrent'
    'qb-assoc-magnet.reg'       = 'HKCU\Software\Classes\magnet'
    'qb-assoc-urlhandler.reg'   = 'HKCU\Software\Classes\qBittorrentURLHandler'
}
foreach ($entry in $qbAssocKeys.GetEnumerator()) {
    $regFile = Join-Path $OutputDir $entry.Key
    & reg.exe export $entry.Value $regFile /y *> $null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Exported $($entry.Key)"
    } else {
        Write-Host "qBittorrent assoc key not present, skipped: $($entry.Value)" -ForegroundColor DarkGray
    }
}

# VLC file associations — same treatment as qBittorrent above: media extensions
# mapped to the single VLC.media ProgID under HKCU\Software\Classes.
$vlcAssocExtensions = @(
    '.3gp', '.3g2', '.asf', '.avi', '.divx', '.dv', '.flv', '.m2ts', '.m4v', '.mkv', '.mov', '.mp4', '.mpeg', '.mpg', '.mts', '.ogm', '.ogv', '.rm', '.rmvb', '.ts', '.vob', '.webm', '.wmv',
    '.aac', '.ac3', '.aiff', '.amr', '.ape', '.au', '.flac', '.m1a', '.m2a', '.m3u', '.m3u8', '.m4a', '.mka', '.mp1', '.mp2', '.mp3', '.mpa', '.oga', '.ogg', '.opus', '.ra', '.ram', '.spx', '.wav', '.wma', '.wpl', '.pls', '.xspf', '.asx'
)
foreach ($ext in $vlcAssocExtensions) {
    $regFile = Join-Path $OutputDir ('vlc-assoc' + $ext.Replace('.', '-') + '.reg')
    & reg.exe export "HKCU\Software\Classes\$ext" $regFile /y *> $null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Exported vlc-assoc$($ext.Replace('.', '-')).reg"
    } else {
        Write-Host "VLC assoc key not present, skipped: $ext" -ForegroundColor DarkGray
    }
}
& reg.exe export "HKCU\Software\Classes\VLC.media" (Join-Path $OutputDir 'vlc-assoc-media.reg') /y *> $null
if ($LASTEXITCODE -eq 0) { Write-Host 'Exported vlc-assoc-media.reg' }

# 7-Zip file associations — archive extensions mapped to the single 7-Zip.archive
# ProgID under HKCU\Software\Classes, same backup/restore treatment as above.
$sevenZipAssocExtensions = @(
    '.7z', '.zip', '.rar', '.tar', '.gz', '.bz2', '.xz', '.lzma', '.lzh', '.lha', '.arj', '.cab', '.iso', '.wim', '.swm', '.esd', '.cpio', '.z', '.tgz', '.tbz2', '.txz', '.001', '.apk', '.deb', '.rpm', '.jar', '.war', '.ear', '.dmg', '.fat', '.hfs', '.ntfs', '.vhd', '.vhdx', '.qcow', '.qcow2', '.udf', '.xar', '.zst', '.lz4', '.br', '.msi', '.crx', '.pkg'
)
foreach ($ext in $sevenZipAssocExtensions) {
    $regFile = Join-Path $OutputDir ('7z-assoc' + $ext.Replace('.', '-') + '.reg')
    & reg.exe export "HKCU\Software\Classes\$ext" $regFile /y *> $null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Exported 7z-assoc$($ext.Replace('.', '-')).reg"
    } else {
        Write-Host "7-Zip assoc key not present, skipped: $ext" -ForegroundColor DarkGray
    }
}
& reg.exe export "HKCU\Software\Classes\7-Zip.archive" (Join-Path $OutputDir '7z-assoc-archive.reg') /y *> $null
if ($LASTEXITCODE -eq 0) { Write-Host 'Exported 7z-assoc-archive.reg' }

$backupZip = Join-Path $realOutputDir 'mainframe-backup.zip'
if (Test-Path -LiteralPath $backupZip) {
    Remove-Item -LiteralPath $backupZip -Force
}
$srcDir = $OutputDir
Write-Host "Compressing $srcDir to $backupZip..."
$stagingDir = Join-Path $env:TEMP "mainframe-zip-stage-$(Get-Random)"
New-Item -ItemType Directory -Force -Path $stagingDir | Out-Null
Invoke-RobocopyLockedAware -RobocopyArgs @($srcDir, $stagingDir, '/E', '/COPYALL', '/R:1', '/W:1', '/NP', '/NDL', '/NFL', '/XJ', '/XF', '*.sock', 'dopus.dat', '*.pdb') -Context 'zip staging'
# 7zip with -tzip produces a standard .zip; handles long paths (>260 chars) that Compress-Archive cannot
$sevenZip = Get-Command '7z' -ErrorAction SilentlyContinue
if (-not $sevenZip) { $sevenZip = Get-Command '7z.exe' -ErrorAction SilentlyContinue }
if ($sevenZip) {
    Push-Location $stagingDir
    & $sevenZip.Source a -tzip -mmt=on -mx=5 $backupZip '*' | Out-Null
    Pop-Location
    if ($LASTEXITCODE -gt 1) { throw "7zip compression failed with exit code $LASTEXITCODE" }
} else {
    Write-Warning '7zip not found, falling back to Compress-Archive (may fail on long paths)'
    Push-Location $stagingDir
    Compress-Archive -Path '*' -DestinationPath $backupZip -Force
    Pop-Location
}
Remove-Item -LiteralPath $stagingDir -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "Wrote $backupZip"
Remove-Item -LiteralPath $srcDir -Recurse -Force -ErrorAction SilentlyContinue

Write-Warning 'Review private artifacts before sharing. They may contain tokens, databases, editor state, remote access identity, or other private data.'
