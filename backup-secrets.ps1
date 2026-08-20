param(
    [string]$ManifestPath = (Join-Path $PSScriptRoot 'tool-secrets.manifest.json'),
    [string]$ArchivePath = (Join-Path $PSScriptRoot 'tool-secrets.zip'),
    # Chromium/Edge cache and redownloadable junk dir basenames to skip when
    # copying directory items (agent-browser chrome-profiles are
    # multi-GB; only auth/config state is wanted in the secrets archive).
    # Tokens, cookies, IndexedDB, Local Storage, Login Data, Preferences and
    # extension settings are NOT in this list and are preserved.
    [string[]]$ExcludeDirNames = @(
        # agent-browser profiles are throwaway VSS clones of real Edge (1.9 GB of
        # disposable cache/extension bundles). Zero unique auth state lives here —
        # real browser auth is in %LOCALAPPDATA%\Microsoft\Edge\User Data, and the
        # agent-browser state vault (~/.agent-browser/sessions) is separate. Excluding
        # avoids bloating the secrets archive with regenerable junk.
        'agent-browser',
        'EdgeLLMOnDeviceModel',
        'EdgeLLMRuntime',
        'EdgeLanguageDetectionModel',
        'Edge Entity Extraction',
        'Cache',
        'Code Cache',
        'GPUCache',
        'DawnWebGPUCache',
        'DawnGraphiteCache',
        'ShaderCache',
        'GrShaderCache',
        'GPUPersistentCache',
        'Crashpad',
        'BrowserMetrics',
        'component_crx_cache',
        'extensions_crx_cache',
        'Service Worker'
    )
)

$ErrorActionPreference = 'Stop'

function Resolve-TemplateString {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) {
        return $null
    }

    $values = @{
        AppData = $env:APPDATA
        LocalAppData = $env:LOCALAPPDATA
        ProgramData = $env:ProgramData
        ScriptRoot = $PSScriptRoot
        UserProfile = $env:USERPROFILE
    }

    $resolved = [Environment]::ExpandEnvironmentVariables($Value)
    foreach ($key in $values.Keys) {
        $resolved = $resolved.Replace("{$key}", [string]$values[$key])
    }

    return $resolved
}

function Get-SafeArchivePath {
    param([string]$ArchivePath)

    $relative = $ArchivePath -replace '^[\\/]+', ''
    if (-not $relative) {
        throw 'Manifest item has an empty archivePath.'
    }

    if ($relative -match '(^|[\\/])\.\.([\\/]|$)') {
        throw "Manifest archivePath cannot contain '..': $ArchivePath"
    }

    return $relative
}

function Copy-PathIntoStage {
    param(
        [string]$Source,
        [string]$Destination,
        [string[]]$ExcludeDirNames = @(),
        [string[]]$ExcludeFileNames = @()
    )

    if (Test-Path -LiteralPath $Source -PathType Container) {
        New-Item -ItemType Directory -Force -Path $Destination | Out-Null
        $rcLog = Join-Path $env:TEMP "robocopy-log-$(Get-Random).txt"
        $rcArgs = @($Source, $Destination, '/E', '/COPYALL', '/R:1', '/W:1', '/NP', '/NDL', '/NFL', "/LOG:$rcLog")
        if ($ExcludeDirNames -and $ExcludeDirNames.Count -gt 0) {
            $rcArgs += '/XD'
            $rcArgs += $ExcludeDirNames
        }
        if ($ExcludeFileNames -and $ExcludeFileNames.Count -gt 0) {
            $rcArgs += '/XF'
            $rcArgs += $ExcludeFileNames
        }
        & robocopy @rcArgs
        $rcExit = $LASTEXITCODE
        $logContent = $null
        if (Test-Path $rcLog) {
            $logContent = Get-Content $rcLog -Raw
            Remove-Item $rcLog -Force -ErrorAction SilentlyContinue
        }
        if ($rcExit -gt 7) {
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
                throw "Robocopy failed with exit code $rcExit"
            }
        }
        return
    }

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Destination) | Out-Null
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
}

if (-not (Test-Path -LiteralPath $ManifestPath)) {
    throw "Missing secrets manifest: $ManifestPath"
}

$manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
$items = @($manifest.items | Where-Object { -not $_.Disabled })
if ($items.Count -eq 0) {
    throw "No enabled secret paths found in $ManifestPath"
}

$tempRoot = Join-Path $env:TEMP "mainframe-tool-secrets-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null

try {
    $copied = 0

    foreach ($item in $items) {
        $source = Resolve-TemplateString -Value $item.Source
        if (-not (Test-Path -LiteralPath $source)) {
            Write-Warning "Secret path not found, skipping $($item.Name): $source"
            continue
        }

        $archiveRelativePath = Get-SafeArchivePath -ArchivePath $item.ArchivePath
        $destination = Join-Path $tempRoot $archiveRelativePath
        Write-Host "Copying $($item.Name)..."
        $itemExcludeDirs = @($item.ExcludeDirs)
        $itemExcludeFiles = @($item.ExcludeFiles)
        Copy-PathIntoStage -Source $source -Destination $destination -ExcludeDirNames ($ExcludeDirNames + $itemExcludeDirs) -ExcludeFileNames $itemExcludeFiles
        $copied++
        Write-Host "Staged secret path: $($item.Name)"
    }

    if ($copied -eq 0) {
        throw 'No secret paths were found on this machine, so no archive was created.'
    }

    if (Test-Path -LiteralPath $ArchivePath) {
        Remove-Item -LiteralPath $ArchivePath -Force
    }

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $ArchivePath) | Out-Null

    Write-Host "Writing secrets archive: $ArchivePath"
    # Use 7-Zip to produce a standard .zip. Compress-Archive chokes on large
    # multi-file trees ("Stream was too long" / "Stream was not readable") due
    # to its internal buffering; 7z is reliable and still emits a portable zip.
    $sevenZip = (Get-Command 7z.exe -ErrorAction SilentlyContinue).Source
    if (-not $sevenZip) {
        $sevenZip = (Get-Command 7z -ErrorAction SilentlyContinue).Source
    }
    if ($sevenZip) {
        # -bt shows bad-file diagnostics; -xr!$Recycle.Bin style exclusions not needed here.
        & $sevenZip a -tzip -mx5 -bso0 -bsp0 -bse2 -y $ArchivePath (Join-Path $tempRoot '*') | Out-Null
        # 7z exit codes: 0 = OK, 1 = warnings (locked files skipped, acceptable here), >=2 = fatal.
        if ($LASTEXITCODE -ge 2) {
            throw "7z failed with exit code $LASTEXITCODE while writing $ArchivePath"
        }
    } else {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        if (Test-Path -LiteralPath $ArchivePath) { Remove-Item -LiteralPath $ArchivePath -Force }
        [System.IO.Compression.ZipFile]::CreateFromDirectory($tempRoot, $ArchivePath, [System.IO.Compression.CompressionLevel]::Optimal, $false)
    }
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Warning 'tool-secrets.zip is private. Do not commit it, publish it, or store it unencrypted.'
