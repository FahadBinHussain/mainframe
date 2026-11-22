#Requires -Version 7
# Native Windows launcher; boot.ps1 owns all machine changes.
# -BootstrapLink <url> downloads the config bundle from the relay
# (permanent link from windows/mainframe.ps1 vault bootstrap-link) and places it as
# mainframe.config.json before the bootstrap runs. -ConfigOnly places the
# config and stops (no bootstrap dispatched).
[CmdletBinding()]
param([switch]$DryRun, [string]$BootstrapLink, [switch]$ConfigOnly)

function Get-MainframePlatform {
    if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) { return 'Windows' }
    throw 'bootstrap.ps1 supports Windows only. On Linux, use Bash with bootstrap.sh; no automatic fallback is performed.'
}

function Get-MainframePwshPath {
    # $PSHOME only contains pwsh.exe when the current host is already
    # PowerShell 7. Under Windows PowerShell 5.1 - the only shell on a fresh
    # machine, and the one 'irm ... | iex' runs in - $PSHOME is
    # ...\WindowsPowerShell\v1.0, which holds powershell.exe, not pwsh.exe.
    # So probe the places PowerShell 7 actually installs to, in order.
    $candidates = @()
    if ($PSHOME) { $candidates += Join-Path $PSHOME 'pwsh.exe' }
    $onPath = Get-Command 'pwsh.exe' -ErrorAction SilentlyContinue
    if (-not $onPath) { $onPath = Get-Command 'pwsh' -ErrorAction SilentlyContinue }
    if ($onPath) { $candidates += $onPath.Source }
    if ($env:ProgramFiles) {
        $candidates += Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
        $candidates += Join-Path $env:ProgramFiles 'PowerShell\6\pwsh.exe'
    }
    if ($env:LOCALAPPDATA) { $candidates += Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe' }
    if ($HOME) { $candidates += Join-Path $HOME 'scoop\apps\pwsh\current\pwsh.exe' }
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) { return $candidate }
    }
    return $null
}

function Invoke-MainframeNativeBootstrap {
    param([string]$Platform, [string]$Path)
    if ($Platform -ne 'Windows') { throw 'bootstrap.ps1 supports Windows only. On Linux, use Bash with bootstrap.sh.' }
    $pwsh = Get-MainframePwshPath
    if (-not $pwsh) {
        # Fresh machine with no PowerShell 7 at all: boot.ps1 installs it via
        # winget, but boot.ps1 cannot start until pwsh exists, so the
        # launcher has to do this one step itself.
        if (Get-Command 'winget' -ErrorAction SilentlyContinue) {
            Write-Host 'mainframe: PowerShell 7 not found - installing it with winget'
            winget install -e --id Microsoft.PowerShell --accept-source-agreements --accept-package-agreements --silent 2>$null
            $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
            $pwsh = Get-MainframePwshPath
        }
    }
    if (-not $pwsh) {
        throw "PowerShell 7 (pwsh.exe) was not found on this machine and could not be installed automatically. Install it (winget install Microsoft.PowerShell) and re-run. Note: under Windows PowerShell 5.1, `$PSHOME contains powershell.exe, not pwsh.exe."
    }
    & $pwsh -NoProfile -ExecutionPolicy Bypass -File $Path
    if ($LASTEXITCODE -ne 0) {
        throw "mainframe $Platform bootstrap failed (exit $LASTEXITCODE)."
    }
}

function Get-MainframeBootstrapProfileRoot {
    # standalone: this launcher runs on a fresh machine where the repo is
    # not cloned yet, so it cannot dot-source mainframe.ps1. the
    # profile root is %APPDATA%\mainframe on windows; MAINFRAME_PROFILE_ROOT
    # overrides it (tests + the test runner's isolation).
    if ($env:MAINFRAME_PROFILE_ROOT) { return $env:MAINFRAME_PROFILE_ROOT }
    if (-not $env:APPDATA) { throw 'APPDATA is not set - cannot locate the mainframe profile root.' }
    return Join-Path $env:APPDATA 'mainframe'
}

# One-link bootstrap: download the config bundle from the relay and
# place it as mainframe.config.json (atomic). The link is permanent:
# GET is repeatable, so a failed download can simply be re-run.
# MAINFRAME_BOOTSTRAP_TEST_BUNDLE (a local file path) replaces the
# download - test hook only, never used in production.
function Install-MainframeBootstrapConfig {
    param([string]$BootstrapLink)
    if ($BootstrapLink -notmatch '^https://[^/]+/bootstrap/[A-Za-z0-9_-]{22}$') {
        throw "not a bootstrap link: $BootstrapLink (expected https://<relay>/bootstrap/<22-char token>)"
    }
    $profileRoot = Get-MainframeBootstrapProfileRoot
    New-Item -ItemType Directory -Force -Path $profileRoot | Out-Null
    $configPath = Join-Path $profileRoot 'mainframe.config.json'
    $tempFile = Join-Path $profileRoot ('.mainframe.config.json.tmp.' + [guid]::NewGuid().ToString('N'))
    try {
        # the temp file starts empty; the download fills it. the chmod
        # runs AFTER the download, not before: Copy-Item and
        # Invoke-WebRequest recreate the file on overwrite and reset its
        # mode to 644 (measured 2026-11-15), so a pre-download chmod
        # would not survive. on windows there is nothing to tighten -
        # the file lives under APPDATA, which is user-private.
        New-Item -ItemType File -Path $tempFile -Force | Out-Null
        if ($env:MAINFRAME_BOOTSTRAP_TEST_BUNDLE) {
            if (-not (Test-Path -LiteralPath $env:MAINFRAME_BOOTSTRAP_TEST_BUNDLE -PathType Leaf)) {
                throw "test bundle not readable: $env:MAINFRAME_BOOTSTRAP_TEST_BUNDLE"
            }
            Copy-Item -LiteralPath $env:MAINFRAME_BOOTSTRAP_TEST_BUNDLE -Destination $tempFile -Force
        } else {
            try {
                Invoke-WebRequest -Uri $BootstrapLink -OutFile $tempFile -ErrorAction Stop
            } catch {
                throw "the bootstrap link download failed - check the link and your network, then re-run (the link is permanent, a failed download loses nothing). ($($_.Exception.Message))"
            }
        }
        if (-not $IsWindows -and (Get-Command chmod -ErrorAction SilentlyContinue)) {
            & chmod 0600 $tempFile
        }
        # the relay validated the bundle at creation; this catches a
        # corrupt or truncated download (or an error page) before it
        # becomes the config.
        $raw = Get-Content -LiteralPath $tempFile -Raw -ErrorAction Stop
        try {
            $config = $raw | ConvertFrom-Json -ErrorAction Stop
        } catch {
            throw "the downloaded bundle is not valid JSON. re-run to retry the download; if it persists, the bundle itself is bad - re-push it from an existing machine (windows/mainframe.ps1 vault bootstrap-link -PushOnly) and re-run. ($($_.Exception.Message))"
        }
        if (-not $config.ntfyTopic -or ($config.ntfyTopic -notmatch '^[a-z0-9]{32}$')) {
            throw 'the downloaded bundle has no valid ntfyTopic - it is corrupt or not a config. re-run to retry the download; if it persists, the bundle itself is bad - re-push it from an existing machine (windows/mainframe.ps1 vault bootstrap-link -PushOnly) and re-run.'
        }
        Move-Item -LiteralPath $tempFile -Destination $configPath -Force
        return $configPath
    } catch {
        if (Test-Path -LiteralPath $tempFile) { Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue }
        throw
    }
}

function Invoke-MainframeBootstrap {
    param([switch]$DryRun, [string]$BootstrapLink, [switch]$ConfigOnly)
    $platform = Get-MainframePlatform
    if ($platform -ne 'Windows') {
        throw "Unsupported operating system for bootstrap.ps1: $platform. On Linux, use Bash with bootstrap.sh."
    }
    $scriptName = 'boot.ps1'
    Write-Host "mainframe: selected $platform -> $scriptName"
    if ($DryRun) {
        Write-Host 'Dry run: no downloads, bootstrap execution, or machine changes.'
        if ($BootstrapLink) {
            Write-Host 'Dry run: would download the bootstrap bundle from the relay (no download happens on a dry run).'
        }
        return
    }

    if ($BootstrapLink) {
        $configPath = Install-MainframeBootstrapConfig -BootstrapLink $BootstrapLink
        Write-Host "mainframe: bootstrap config placed at $configPath"
        if ($ConfigOnly) {
            Write-Host 'mainframe: config placed, -ConfigOnly: no bootstrap dispatched.'
            return
        }
    } elseif ($ConfigOnly) {
        throw '-ConfigOnly needs -BootstrapLink (there is nothing to place without a link).'
    }

    $temporaryDirectory = $null
    try {
        if ($PSScriptRoot) {
            $path = Join-Path $PSScriptRoot $scriptName
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                throw "Selected bootstrap is missing: $path"
            }
        } else {
            # Remote scriptblock launch has no local sibling script.
            $temporaryDirectory = Join-Path ([IO.Path]::GetTempPath()) ('mainframe-launch-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $temporaryDirectory -ErrorAction Stop | Out-Null
            $path = Join-Path $temporaryDirectory $scriptName
            Invoke-WebRequest -Uri "https://raw.githubusercontent.com/FahadBinHussain/mainframe/main/$scriptName" -OutFile $path -ErrorAction Stop
        }
        Invoke-MainframeNativeBootstrap -Platform $platform -Path $path
    } finally {
        if ($temporaryDirectory) {
            Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force -ErrorAction Stop
        }
    }
}

# Dot-sourcing loads functions only, allowing offline tests with mocked dispatch.
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-MainframeBootstrap -DryRun:$DryRun -BootstrapLink $BootstrapLink -ConfigOnly:$ConfigOnly
}
