#Requires -Version 7
# No Pester dependency. No real bootstrap is executed and no network is
# touched: the bundle download is an inert double and the bundle is an
# obvious fake.
$ErrorActionPreference = 'Stop'
$launcher = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../bootstrap.ps1'))
$script:checks = 0
$script:dispatches = @()
$script:downloads = @()
$script:fakeTopic = 'z' * 32
$script:fakeConfig = '{"bitwardenEmail":"test@example.invalid","ntfyTopic":"' + $script:fakeTopic + '","ntfyServer":"https://relay.example.invalid/ntfy","pagesBase":"https://example.invalid","vaultTtlMinutes":60}'
$script:badConfig = '{"pagesBase":"https://example.invalid"}'
$script:testLink = 'https://relay.example.invalid/bootstrap/AAAAAAAAAAAAAAAAAAAAAA'

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
    function script:Get-MainframePlatform { return 'Windows' }
    function script:Invoke-MainframeNativeBootstrap {
        param([string]$Platform, [string]$Path)
        $script:dispatches += [pscustomobject]@{ Platform = $Platform; Path = $Path }
    }
    function script:Invoke-WebRequest {
        param([string]$Uri, [string]$OutFile, $ErrorAction)
        $script:downloads += $Uri
        Assert-True ($Uri -eq $script:testLink) 'downloads the bootstrap link only'
        Set-Content -LiteralPath $OutFile -Value $script:fakeConfig -NoNewline
    }
}

# Parse the launcher without executing boot.ps1.
$parseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($launcher, [ref]$null, [ref]$parseErrors)
Assert-True ($parseErrors.Count -eq 0) 'bootstrap.ps1 parses'
. $launcher
Set-TestDoubles

$oldProfileRoot = $env:MAINFRAME_PROFILE_ROOT
$oldTestBundle = $env:MAINFRAME_BOOTSTRAP_TEST_BUNDLE
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('mf-bootstrap-link-' + [Guid]::NewGuid().ToString('N'))
try {
    $null = New-Item -ItemType Directory -Force -Path $tempRoot
    $profileRoot = Join-Path $tempRoot 'profile'
    $env:MAINFRAME_PROFILE_ROOT = $profileRoot
    $bundleFile = Join-Path $tempRoot 'bundle.json'
    Set-Content -LiteralPath $bundleFile -Value $script:fakeConfig -NoNewline
    $badBundleFile = Join-Path $tempRoot 'bad-bundle.json'
    Set-Content -LiteralPath $badBundleFile -Value $script:badConfig -NoNewline
    $placed = Join-Path $profileRoot 'mainframe.config.json'

    function Reset-LinkState {
        $script:dispatches = @()
        $script:downloads = @()
        if (Test-Path -LiteralPath $profileRoot) { Remove-Item -LiteralPath $profileRoot -Recurse -Force }
        Remove-Item Env:MAINFRAME_BOOTSTRAP_TEST_BUNDLE -ErrorAction SilentlyContinue
    }

    # 1. -ConfigOnly with the test-bundle hook: config lands, values
    #    intact, mode 0600 on POSIX, no download, no dispatch.
    Reset-LinkState
    $env:MAINFRAME_BOOTSTRAP_TEST_BUNDLE = $bundleFile
    $out = Invoke-MainframeBootstrap -BootstrapLink $script:testLink -ConfigOnly 6>&1 | Out-String
    Assert-True ($out -match 'bootstrap config placed') 'config-only announces the placement'
    Assert-True (Test-Path -LiteralPath $placed -PathType Leaf) 'config lands in the profile root'
    Assert-True ((Get-Content -LiteralPath $placed -Raw) -eq $script:fakeConfig) 'config lands byte-identical'
    if (-not $IsWindows) {
        $mode = (& stat -c %a $placed)
        Assert-True ($mode -eq '600') 'config lands mode 0600'
    }
    $leftovers = @(Get-ChildItem -LiteralPath $profileRoot | Where-Object { $_.Name -ne 'mainframe.config.json' })
    Assert-True ($leftovers.Count -eq 0) 'no temp files left behind'
    Assert-True ($script:downloads.Count -eq 0) 'the test hook does not download'
    Assert-True ($script:dispatches.Count -eq 0) 'config-only does not dispatch'

    # 2. the real download path (mocked Invoke-WebRequest, no hook).
    Reset-LinkState
    Invoke-MainframeBootstrap -BootstrapLink $script:testLink -ConfigOnly | Out-Null
    Assert-True ($script:downloads.Count -eq 1) 'the bundle downloads on this run'
    Assert-True (Test-Path -LiteralPath $placed -PathType Leaf) 'download-path config lands'
    Assert-True ((Get-Content -LiteralPath $placed -Raw) -eq $script:fakeConfig) 'download-path config is intact'

    # 3. full flow: config lands, then the bootstrap dispatches to boot.ps1.
    Reset-LinkState
    $env:MAINFRAME_BOOTSTRAP_TEST_BUNDLE = $bundleFile
    Invoke-MainframeBootstrap -BootstrapLink $script:testLink | Out-Null
    Assert-True (Test-Path -LiteralPath $placed -PathType Leaf) 'full flow places the config first'
    Assert-True ($script:dispatches.Count -eq 1) 'full flow dispatches after placement'
    Assert-True ($script:dispatches[-1].Path -eq (Join-Path (Split-Path $launcher) 'boot.ps1')) 'full flow dispatches to boot.ps1'

    # 4. a malformed link fails loudly before any download or placement.
    Reset-LinkState
    Assert-Throws { Invoke-MainframeBootstrap -BootstrapLink 'https://relay.example.invalid/bootstrap/short' -ConfigOnly } '*not a bootstrap link*'
    Assert-True ($script:downloads.Count -eq 0) 'malformed link does not download'
    Assert-True (-not (Test-Path -LiteralPath $placed)) 'malformed link places nothing'

    # 5. a dry run downloads nothing.
    Reset-LinkState
    $env:MAINFRAME_BOOTSTRAP_TEST_BUNDLE = $bundleFile
    $out = Invoke-MainframeBootstrap -DryRun -BootstrapLink $script:testLink 6>&1 | Out-String
    Assert-True ($out -match 'no download happens on a dry run') 'dry run says no download happens'
    Assert-True ($script:downloads.Count -eq 0) 'dry run does not download'
    Assert-True (-not (Test-Path -LiteralPath $placed)) 'dry run places nothing'
    Assert-True ($script:dispatches.Count -eq 0) 'dry run does not dispatch'

    # 6. an invalid bundle fails loudly and places nothing.
    Reset-LinkState
    $env:MAINFRAME_BOOTSTRAP_TEST_BUNDLE = $badBundleFile
    Assert-Throws { Invoke-MainframeBootstrap -BootstrapLink $script:testLink -ConfigOnly } '*no valid ntfyTopic*'
    Assert-True (-not (Test-Path -LiteralPath $placed)) 'invalid bundle places nothing'

    # 7. -ConfigOnly without a link is a loud error, not a silent no-op.
    Reset-LinkState
    Assert-Throws { Invoke-MainframeBootstrap -ConfigOnly } '*needs -BootstrapLink*'
} finally {
    if ($null -eq $oldProfileRoot) { Remove-Item Env:MAINFRAME_PROFILE_ROOT -ErrorAction SilentlyContinue } else { $env:MAINFRAME_PROFILE_ROOT = $oldProfileRoot }
    if ($null -eq $oldTestBundle) { Remove-Item Env:MAINFRAME_BOOTSTRAP_TEST_BUNDLE -ErrorAction SilentlyContinue } else { $env:MAINFRAME_BOOTSTRAP_TEST_BUNDLE = $oldTestBundle }
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host "bootstrap-link checks: $script:checks passed"
