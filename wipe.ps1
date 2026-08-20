param(
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'

$AppData = $env:APPDATA
$LocalAppData = $env:LOCALAPPDATA
$ProgramData = $env:ProgramData
$ScriptRoot = $PSScriptRoot
$UserProfile = $env:USERPROFILE

function Resolve-SecretPath {
    param([AllowNull()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    $resolved = [Environment]::ExpandEnvironmentVariables($Value)
    $values = @{
        AppData = $AppData
        LocalAppData = $LocalAppData
        ProgramData = $ProgramData
        ScriptRoot = $ScriptRoot
        UserProfile = $UserProfile
    }
    foreach ($key in $values.Keys) {
        $resolved = $resolved.Replace("{$key}", [string]$values[$key])
    }
    return $resolved
}

function Get-WipeTargets {
    $targets = @()

    # 1) tool secrets the backup/restore manifest tracks (keeps wipe in sync)
    $manifestPath = Join-Path $PSScriptRoot 'tool-secrets.manifest.json'
    if (Test-Path -LiteralPath $manifestPath) {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        foreach ($item in @($manifest.items | Where-Object { -not $_.Disabled })) {
            $p = Resolve-SecretPath -Value $item.Source
            if ($p) { $targets += $p }
        }
    }

    # 2) Edge browser profile (cookies, sessions, saved passwords) backed up by backup.ps1
    $targets += (Join-Path $LocalAppData 'Microsoft\Edge\User Data')

    # 3) git credential/config
    $targets += (Join-Path $UserProfile '.gitconfig')

    # 4) native app persist paths (AnyDesk, Directory Opus, etc.)
    $wingetAllowed = Join-Path $PSScriptRoot 'winget-allowed.json'
    if (Test-Path -LiteralPath $wingetAllowed) {
        $cfg = Get-Content -LiteralPath $wingetAllowed -Raw | ConvertFrom-Json
        foreach ($pkg in @($cfg.packages)) {
            foreach ($entry in @($pkg.persist)) {
                $p = Resolve-SecretPath -Value $entry.path
                if ($p) { $targets += $p }
            }
        }
    }

    return @($targets | Where-Object { $_ } | Select-Object -Unique)
}

Write-Host 'Mainframe secret wipe'
Write-Host ''

$targets = @(Get-WipeTargets)
$existing = @($targets | Where-Object { Test-Path -LiteralPath $_ })

if ($existing.Count -eq 0) {
    Write-Host 'No mainframe secret targets found. Nothing to wipe.'
    exit 0
}

Write-Host "Found $($existing.Count) secret location(s):"
foreach ($t in $existing) {
    $kind = if (Test-Path -LiteralPath $t -PathType Container) { 'dir ' } else { 'file' }
    Write-Host "  [$kind] $t"
}
Write-Host ''

if ($WhatIf) {
    Write-Host '[WhatIf] Would remove the locations above.'
    exit 0
}

$confirm = Read-Host 'Type YES to wipe all of the above (including your Edge browser profile)'
if ($confirm -ne 'YES') {
    Write-Host 'Aborted.'
    exit 1
}

foreach ($t in $existing) {
    try {
        if (Test-Path -LiteralPath $t -PathType Container) {
            $isEdge = $t -like '*Microsoft\Edge\User Data'
            if ($isEdge) {
                Get-Process -Name 'msedge' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 3
            }
        }
        Remove-Item -LiteralPath $t -Recurse -Force -ErrorAction Stop
        Write-Host "Wiped: $t"
    } catch {
        Write-Warning "Failed to wipe $t -- $($_.Exception.Message)"
    }
}
Write-Host 'Wipe complete.'