#Requires -Version 7
# Shared launcher; the platform bootstraps own all machine changes.
[CmdletBinding()]
param([switch]$DryRun)

function Get-MainframePlatform {
    if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) { return 'Windows' }
    if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Linux)) { return 'Linux' }
    throw 'Unsupported operating system. mainframe supports Windows and Linux only.'
}

function Invoke-MainframeNativeBootstrap {
    param([string]$Platform, [string]$Path)
    if ($Platform -eq 'Windows') {
        & (Join-Path $PSHOME 'pwsh.exe') -NoProfile -ExecutionPolicy Bypass -File $Path
    } else {
        $bash = Get-Command bash -CommandType Application -ErrorAction Stop
        & $bash.Source $Path
    }
    if ($LASTEXITCODE -ne 0) {
        throw "mainframe $Platform bootstrap failed (exit $LASTEXITCODE)."
    }
}

function Invoke-MainframeBootstrap {
    param([switch]$DryRun)
    $platform = Get-MainframePlatform
    $scriptName = switch ($platform) {
        'Windows' { 'boot.ps1' }
        'Linux' { 'boot.sh' }
        default { throw "Unsupported operating system: $platform. mainframe supports Windows and Linux only." }
    }
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
            # The same command can be pasted into PowerShell or a POSIX shell.
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
