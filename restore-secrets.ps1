param(
    [string]$ManifestPath = (Join-Path $PSScriptRoot 'tool-secrets.manifest.json'),
    [string]$ArchivePath = (Join-Path $PSScriptRoot 'tool-secrets.zip'),
    # Same filters restore.ps1 applies to the embedded secrets/ tree. They matter on
    # the standalone-zip path (boot.ps1 remote restore): without them the "opencode
    # first" step would restore EVERYTHING and the next step would redo it all.
    [string[]]$ItemNames = @(),
    [string[]]$SkipNames = @(),
    [switch]$NoExistingBackup
)

$ErrorActionPreference = 'Stop'

function Report-WacliPayloadPreserved {
    param([Parameter(Mandatory)][string]$ArchivePath)
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    $zip = $null
    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($ArchivePath)
        $found = @($zip.Entries | Where-Object { $_.FullName -replace '\\','/' -match '(?i)(^|/)NativeState/wacli(/|$)' })
        if ($found.Count -gt 0) {
            Write-Warning 'Preserved WACLI NativeState/wacli payload detected; it is Linux-native state and is not activated or remapped into Windows accounts.'
        }
    } finally { if ($zip) { $zip.Dispose() } }
}

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

function Test-WacliReservedArchiveSource {
    param([Parameter(Mandatory)][string]$Source)

    # Custom manifests must not make a Windows target receive NativeState/wacli
    # itself, a descendant, or a parent directory containing that tree.
    $normalized = $Source -replace '\\', '/'
    if ($normalized -match '(?i)(^|/)NativeState/wacli(/|$)') {
        return $true
    }
    if (Test-Path -LiteralPath $Source -PathType Container) {
        $reserved = Get-ChildItem -LiteralPath $Source -Directory -Recurse -Force -ErrorAction Stop |
            Where-Object { ($_.FullName -replace '\\', '/') -match '(?i)(^|/)NativeState/wacli(/|$)' } |
            Select-Object -First 1
        if ($reserved) { return $true }
    }
    return $false
}

function Copy-PathContents {
    param(
        [string]$Source,
        [string]$Destination
    )

    if (Test-Path -LiteralPath $Source -PathType Container) {
        New-Item -ItemType Directory -Force -Path $Destination | Out-Null
        Get-ChildItem -LiteralPath $Source -Force | Copy-Item -Destination $Destination -Recurse -Force
        return
    }

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Destination) | Out-Null
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
}

function Backup-ExistingTarget {
    param(
        [string]$Target,
        [string]$ArchiveRelativePath,
        [string]$BackupRoot
    )

    if ($NoExistingBackup -or -not (Test-Path -LiteralPath $Target)) {
        return
    }

    $backupPath = Join-Path $BackupRoot $ArchiveRelativePath
    Copy-PathContents -Source $Target -Destination $backupPath
    Write-Host "Backed up existing target: $Target"
}

if (-not (Test-Path -LiteralPath $ManifestPath)) {
    throw "Missing secrets manifest: $ManifestPath"
}

if (-not (Test-Path -LiteralPath $ArchivePath)) {
    throw "Missing secrets archive: $ArchivePath"
}
Report-WacliPayloadPreserved -ArchivePath $ArchivePath

$manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
$disabledSecrets = @($manifest.disabled) + @($manifest.disabled_items)
$enabled = @($manifest.items | Where-Object { (-not $_.Disabled) -and ($_.Name -notin $disabledSecrets) })
if ($enabled.Count -eq 0) {
    throw "No enabled secret paths found in $ManifestPath"
}

$items = $enabled
if ($ItemNames.Count -gt 0) {
    $items = @($items | Where-Object {
        $name = $_.Name
        $match = $false
        foreach ($n in $ItemNames) { if ($name -like "*$n*") { $match = $true; break } }
        $match
    })
}
if ($SkipNames.Count -gt 0) {
    $items = @($items | Where-Object {
        $name = $_.Name
        $match = $false
        foreach ($n in $SkipNames) { if ($name -like "*$n*") { $match = $true; break } }
        -not $match
    })
}
if ($items.Count -eq 0) {
    Write-Host "No secret items match this filter (ItemNames='$($ItemNames -join ',')' SkipNames='$($SkipNames -join ',')') - nothing to restore in this step."
    return
}

$tempRoot = Join-Path $env:TEMP "mainframe-tool-secrets-$([Guid]::NewGuid().ToString('N'))"
$backupRoot = Join-Path $PSScriptRoot "tool-secrets-restore-backups\$(Get-Date -Format 'yyyyMMdd-HHmmss')"
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null

try {
    Write-Host "Extracting secrets archive: $ArchivePath"
    Expand-Archive -LiteralPath $ArchivePath -DestinationPath $tempRoot -Force

    foreach ($item in $items) {
        $target = Resolve-TemplateString -Value $item.Source
        $archiveRelativePath = Get-SafeArchivePath -ArchivePath $item.ArchivePath
        $source = Join-Path $tempRoot $archiveRelativePath

        if (-not (Test-Path -LiteralPath $source)) {
            Write-Warning "Archive entry not found, skipping $($item.Name): $archiveRelativePath"
            continue
        }

        if (Test-WacliReservedArchiveSource -Source $source) {
            Write-Warning "Skipping secret item '$($item.Name)': archive source contains reserved NativeState/wacli payload; it is preserved and never copied to a Windows target."
            continue
        }

        Backup-ExistingTarget -Target $target -ArchiveRelativePath $archiveRelativePath -BackupRoot $backupRoot
        Copy-PathContents -Source $source -Destination $target
        Write-Host "Restored secret path: $($item.Name)"
    }
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

if (-not $NoExistingBackup -and (Test-Path -LiteralPath $backupRoot)) {
    Write-Host "Existing secret targets were backed up to: $backupRoot"
}

Write-Warning 'Restart shells and apps after restoring secrets so they reload auth/config files.'
