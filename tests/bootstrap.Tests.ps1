#Requires -Version 7
# No Pester dependency. Native bootstraps are NEVER executed by these tests.
$ErrorActionPreference = 'Stop'
$launcher = Join-Path $PSScriptRoot '../bootstrap.ps1'
$source = Get-Content -LiteralPath $launcher -Raw
$script:dispatches = @()
$script:downloads = 0
$script:checks = 0

function Assert-True($Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:checks++
}
function Assert-Throws([scriptblock]$Action, [string]$Pattern) {
    try { & $Action } catch {
        Assert-True ($_.Exception.Message -like $Pattern) "expected error matching $Pattern, got $_"
        return
    }
    throw "FAIL: expected error matching $Pattern"
}
function Set-TestDoubles {
    function script:Get-MainframePlatform { return $script:testPlatform }
    function script:Invoke-MainframeNativeBootstrap {
        param([string]$Platform, [string]$Path)
        $script:dispatches += [pscustomobject]@{ Platform = $Platform; Path = $Path }
        if ($script:failDispatch) { throw 'fixture bootstrap failure' }
    }
    function script:Invoke-WebRequest {
        param([string]$Uri, [string]$OutFile, $ErrorAction)
        $script:downloads++
        if ($script:failDownload) { throw 'fixture download failure' }
        Set-Content -LiteralPath $OutFile -Value '# inert test fixture, never executed'
    }
}

# Parse every new/existing PowerShell entry point without executing boot.ps1.
foreach ($file in @($launcher, (Join-Path $PSScriptRoot '../boot.ps1'))) {
    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$parseErrors)
    Assert-True ($parseErrors.Count -eq 0) "$file parses"
}
. $launcher
$expectedPlatform = if ($IsWindows) { 'Windows' } elseif ($IsLinux) { 'Linux' } else { $null }
if ($expectedPlatform) { Assert-True ((Get-MainframePlatform) -eq $expectedPlatform) 'real runtime detection' }
Set-TestDoubles

foreach ($platform in @('Windows', 'Linux')) {
    $script:testPlatform = $platform
    $before = $script:dispatches.Count
    $output = Invoke-MainframeBootstrap -DryRun 6>&1 | Out-String
    Assert-True ($output -match "selected $platform -> boot\.") "$platform dry-run announces route"
    Assert-True ($script:dispatches.Count -eq $before) "$platform dry-run does not dispatch"
    Assert-True ($script:downloads -eq 0) "$platform dry-run does not download"
    $output = Invoke-MainframeBootstrap 6>&1 | Out-String
    $expectedFile = if ($platform -eq 'Windows') { 'boot.ps1' } else { 'boot.sh' }
    $last = $script:dispatches[-1]
    Assert-True ($last.Platform -eq $platform) "$platform dispatch"
    Assert-True ((Split-Path $last.Path -Leaf) -eq $expectedFile) "$platform native file"
    Assert-True ($script:downloads -eq 0) 'local checkout needs no downloads'
}
$script:testPlatform = 'Darwin'
Assert-Throws { Invoke-MainframeBootstrap -DryRun } '*Unsupported operating system*'
$script:testPlatform = 'Linux'
$script:failDispatch = $true
Assert-Throws { Invoke-MainframeBootstrap } '*fixture bootstrap failure*'
$script:failDispatch = $false

# Missing local native script must fail instead of falling back to the network.
$fixtureDirectory = Join-Path ([IO.Path]::GetTempPath()) ('mainframe-test-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $fixtureDirectory | Out-Null
    $fixtureLauncher = Join-Path $fixtureDirectory 'bootstrap.ps1'
    Copy-Item -LiteralPath $launcher -Destination $fixtureLauncher
    . $fixtureLauncher
    Set-TestDoubles
    Assert-Throws { Invoke-MainframeBootstrap } '*Selected bootstrap is missing*'
    Assert-True ($script:downloads -eq 0) 'missing local script does not download'
} finally {
    Remove-Item -LiteralPath $fixtureDirectory -Recurse -Force
}

# Emulate irm/scriptblock launch (no local PSScriptRoot), mocking HTTP + execution.
. ([scriptblock]::Create($source))
Set-TestDoubles
foreach ($platform in @('Windows', 'Linux')) {
    $script:testPlatform = $platform
    Invoke-MainframeBootstrap
    $last = $script:dispatches[-1]
    Assert-True ($last.Platform -eq $platform) "$platform remote dispatch"
    Assert-True (-not (Test-Path -LiteralPath (Split-Path $last.Path))) 'temporary download removed'
}
$script:failDownload = $true
Assert-Throws { Invoke-MainframeBootstrap } '*fixture download failure*'
$script:failDownload = $false
$script:failDispatch = $true
Assert-Throws { Invoke-MainframeBootstrap } '*fixture bootstrap failure*'
Assert-True (-not (Test-Path -LiteralPath (Split-Path $script:dispatches[-1].Path))) 'temporary script removed on failure'
Write-Host "PASS: $script:checks checks; no native bootstrap was executed."
