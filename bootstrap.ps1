#Requires -Version 7
# Native Windows launcher; boot.ps1 owns all machine changes.
[CmdletBinding()]
param([switch]$DryRun)

function Get-MainframePlatform {
    if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) { return 'Windows' }
    throw 'bootstrap.ps1 supports Windows only. On Linux, use Bash with bootstrap.sh; no automatic fallback is performed.'
}

function Invoke-MainframeNativeBootstrap {
    param([string]$Platform, [string]$Path)
    if ($Platform -ne 'Windows') { throw 'bootstrap.ps1 supports Windows only. On Linux, use Bash with bootstrap.sh.' }
    & (Join-Path $PSHOME 'pwsh.exe') -NoProfile -ExecutionPolicy Bypass -File $Path
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
