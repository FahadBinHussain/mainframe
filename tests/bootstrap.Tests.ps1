#Requires -Version 7
# No Pester dependency. Real native bootstraps are NEVER executed by these tests.
$ErrorActionPreference = 'Stop'
$launcher = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../bootstrap.ps1'))
$source = Get-Content -LiteralPath $launcher -Raw
$script:dispatches = @()
$script:downloads = 0
$script:downloadPaths = @()
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
        $script:downloadPaths += $OutFile
        Assert-True ($Uri -eq 'https://raw.githubusercontent.com/FahadBinHussain/mainframe/main/boot.ps1') 'downloads Windows child only'
        Set-Content -LiteralPath $OutFile -Value '# inert test fixture, never executed'
        if ($script:failDownload) { throw 'fixture download failure' }
    }
}

# Parse the launcher and unchanged restore entry point without executing boot.ps1.
foreach ($file in @($launcher, (Join-Path $PSScriptRoot '../boot.ps1'))) {
    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$parseErrors)
    Assert-True ($parseErrors.Count -eq 0) "$file parses"
}
. $launcher
if ($IsWindows) {
    Assert-True ((Get-MainframePlatform) -eq 'Windows') 'real Windows detection'
} else {
    Assert-Throws { Get-MainframePlatform } '*Windows only*bootstrap.sh*'
}
# Preserve the real dispatch function to test its guard and native failure handling.
$nativeDispatch = ${function:Invoke-MainframeNativeBootstrap}
Assert-Throws { & $nativeDispatch -Platform Linux -Path 'never-executed' } '*Windows only*bootstrap.sh*'
Set-TestDoubles
$script:testPlatform = 'Windows'
$output = Invoke-MainframeBootstrap -DryRun 6>&1 | Out-String
Assert-True ($output -match 'mainframe: selected Windows -> boot\.ps1') 'preview announces exact Windows route'
Assert-True ($script:dispatches.Count -eq 0) 'preview does not dispatch'
Assert-True ($script:downloads -eq 0) 'preview does not download'
Invoke-MainframeBootstrap
Assert-True ($script:dispatches[-1].Platform -eq 'Windows') 'Windows dispatch'
Assert-True ($script:dispatches[-1].Path -eq (Join-Path (Split-Path $launcher) 'boot.ps1')) 'uses sibling script'
Assert-True ($script:downloads -eq 0) 'local checkout does not download'
foreach ($platform in @('Linux', 'Darwin', 'Unknown')) {
    $script:testPlatform = $platform
    Assert-Throws { Invoke-MainframeBootstrap -DryRun } '*Unsupported operating system*bootstrap.sh*'
    Assert-Throws { Invoke-MainframeBootstrap } '*Unsupported operating system*bootstrap.sh*'
}
$script:testPlatform = 'Windows'
$script:failDispatch = $true
Assert-Throws { Invoke-MainframeBootstrap } '*fixture bootstrap failure*'
$script:failDispatch = $false

# A missing local child must fail instead of falling back to the network.
$fixtureDirectory = Join-Path ([IO.Path]::GetTempPath()) ('mainframe test ' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $fixtureDirectory | Out-Null
    $fixtureLauncher = Join-Path $fixtureDirectory 'bootstrap.ps1'
    Copy-Item -LiteralPath $launcher -Destination $fixtureLauncher
    . $fixtureLauncher
    Set-TestDoubles
    Invoke-MainframeBootstrap -DryRun
    Assert-Throws { Invoke-MainframeBootstrap } '*Selected bootstrap is missing*'
    Assert-True ($script:downloads -eq 0) 'missing local script does not download'
    Set-Content -LiteralPath (Join-Path $fixtureDirectory 'boot.ps1') -Value '# inert fixture'
    Invoke-MainframeBootstrap
    Assert-True ($script:dispatches[-1].Path -eq (Join-Path $fixtureDirectory 'boot.ps1')) 'local paths with spaces preserved'

    # Exercise native exit checking using an inert .ps1, never the real child.
    $fakeChild = Join-Path $fixtureDirectory 'inert-child.ps1'
    Set-Content -LiteralPath $fakeChild -Value '$global:LASTEXITCODE = 37'
    & {
        function Join-Path { param($Path, $ChildPath) return $fakeChild }
        Assert-Throws { & $nativeDispatch -Platform Windows -Path 'never-executed' } '*failed (exit 37)*'
        Set-Content -LiteralPath $fakeChild -Value '$global:LASTEXITCODE = 0'
        & $nativeDispatch -Platform Windows -Path 'never-executed'
        Assert-True ($LASTEXITCODE -eq 0) 'inert native child success'
    }
} finally {
    Remove-Item -LiteralPath $fixtureDirectory -Recurse -Force
}

# Emulate a remote scriptblock with no PSScriptRoot; HTTP and dispatch are inert.
. ([scriptblock]::Create($source))
Set-TestDoubles
$beforeDispatch = $script:dispatches.Count
Invoke-MainframeBootstrap -DryRun
Assert-True ($script:downloads -eq 0) 'remote preview does not download'
Assert-True ($script:dispatches.Count -eq $beforeDispatch) 'remote preview does not dispatch'
Invoke-MainframeBootstrap
Assert-True ($script:dispatches[-1].Platform -eq 'Windows') 'remote Windows dispatch'
Assert-True (-not (Test-Path -LiteralPath (Split-Path $script:downloadPaths[-1]))) 'temporary download removed after success'
$script:failDownload = $true
Assert-Throws { Invoke-MainframeBootstrap } '*fixture download failure*'
Assert-True (-not (Test-Path -LiteralPath (Split-Path $script:downloadPaths[-1]))) 'partial download removed after failure'
$script:failDownload = $false
$script:failDispatch = $true
Assert-Throws { Invoke-MainframeBootstrap } '*fixture bootstrap failure*'
Assert-True (-not (Test-Path -LiteralPath (Split-Path $script:dispatches[-1].Path))) 'temporary script removed after dispatch failure'
Write-Host "PASS: $script:checks checks; no real native bootstrap was executed."
