#Requires -Version 7
# Native Windows launcher; boot.ps1 owns all machine changes.
[CmdletBinding()]
param([switch]$DryRun)

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

function Invoke-MainframeBootstrap {
    param([switch]$DryRun)
    $platform = Get-MainframePlatform
    if ($platform -ne 'Windows') {
        throw "Unsupported operating system for bootstrap.ps1: $platform. On Linux, use Bash with bootstrap.sh."
    }
    $scriptName = 'boot.ps1'
    Write-Host "mainframe: selected $platform -> $scriptName"
    if ($DryRun) {
        Write-Host 'Dry run: no downloads, bootstrap execution, or machine changes.'
        return
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
    Invoke-MainframeBootstrap -DryRun:$DryRun
}
