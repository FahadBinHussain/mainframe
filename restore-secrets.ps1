param(
    [string]$ManifestPath = (Join-Path $PSScriptRoot 'tool-secrets.manifest.json'),
    [string]$ArchivePath = (Join-Path $PSScriptRoot 'tool-secrets.zip'),
    [switch]$NoExistingBackup
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

$manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
$items = @($manifest.items | Where-Object { -not $_.Disabled })
if ($items.Count -eq 0) {
    throw "No enabled secret paths found in $ManifestPath"
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
