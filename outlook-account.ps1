$ErrorActionPreference = 'Stop'

$target = Join-Path $PSScriptRoot 'microsoft-account.ps1'
if (-not (Test-Path -LiteralPath $target)) {
    throw "microsoft-account.ps1 was not found next to outlook-account.ps1: $target"
}

& $target @args
exit $LASTEXITCODE
