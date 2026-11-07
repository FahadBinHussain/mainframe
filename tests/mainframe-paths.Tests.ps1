# No Pester dependency. Runs under windows powershell 5.1 AND pwsh 7.
#
# The point of this module is that ONE rule decides where the profile lives,
# on both platforms. These checks pin that rule down, including the linux
# branch - which is exercised here by clearing $env:OS, the flag the module
# uses to tell windows from linux.
$ErrorActionPreference = 'Stop'
$module = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../mainframe-paths.psm1'))

$script:checks = 0
function Assert-True($Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:checks++
}
function Assert-Equal($Expected, $Actual, [string]$Message) {
    if ($Expected -ne $Actual) { throw "FAIL: $Message`n  expected: $Expected`n  actual:   $Actual" }
    $script:checks++}

# 1. the module parses
$parseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($module, [ref]$null, [ref]$parseErrors)
Assert-True ($parseErrors.Count -eq 0) 'mainframe-paths.psm1 parses'

Import-Module $module -Force -DisableNameChecking

# keep the environment exactly as we found it
$saved = @{}
foreach ($name in @('MAINFRAME_PROFILE_ROOT', 'MAINFRAME_HOME', 'XDG_CONFIG_HOME', 'OS')) {
    $saved[$name] = [Environment]::GetEnvironmentVariable($name)
}
function Restore-Env {
    foreach ($name in $saved.Keys) {
        [Environment]::SetEnvironmentVariable($name, $saved[$name])
    }
}

try {
    # 2. the windows layout is unchanged - existing profiles stay where they are
    [Environment]::SetEnvironmentVariable('MAINFRAME_PROFILE_ROOT', $null)
    [Environment]::SetEnvironmentVariable('XDG_CONFIG_HOME', $null)
    $env:OS = 'Windows_NT'
    Assert-Equal (Join-Path $env:APPDATA 'mainframe') (Get-MainframeProfileRoot) `
        'windows keeps %APPDATA%\mainframe'

    # 3. the linux layout is the XDG one
    $env:OS = $null   # not windows
    $env:XDG_CONFIG_HOME = Join-Path $HOME '.xdg-test'
    Assert-Equal (Join-Path (Join-Path $HOME '.xdg-test') 'mainframe') (Get-MainframeProfileRoot) `
        'linux follows XDG_CONFIG_HOME'

    # 4. without XDG it falls back to ~/.config
    $env:XDG_CONFIG_HOME = $null
    Assert-Equal (Join-Path (Join-Path $HOME '.config') 'mainframe') (Get-MainframeProfileRoot) `
        'linux falls back to ~/.config/mainframe'

    # 5. the override wins over everything
    [Environment]::SetEnvironmentVariable('MAINFRAME_PROFILE_ROOT', '/tmp/mf-profile')
    Assert-Equal '/tmp/mf-profile' (Get-MainframeProfileRoot) 'the override wins'

    # 6. the nested paths hang off the profile root and use the platform separator
    [Environment]::SetEnvironmentVariable('MAINFRAME_PROFILE_ROOT', $null)
    $env:OS = $null
    $env:XDG_CONFIG_HOME = Join-Path $HOME '.xdg-test'
    $root = Get-MainframeProfileRoot
    Assert-Equal (Join-Path $root 'accounts') (Get-MainframeAccountsDir) 'the accounts dir sits under the profile root'
    Assert-Equal (Join-Path (Join-Path $root 'accounts') 'vercel') (Get-MainframeAccountDir -Account 'vercel') `
        'an account dir sits under the accounts dir'
    Assert-Equal (Join-Path (Join-Path (Join-Path $root 'accounts') 'bitwarden') 'session.key') `
        (Get-MainframeSessionKeyPath) 'the session key sits under accounts/bitwarden'

    # 7. a linux profile root must not contain a windows separator
    if ($root -like '*/*') {
        Assert-True (-not $root.Contains('\')) 'a linux profile root has no backslash in it'
    }

    # 8. the checkout root honours the override
    [Environment]::SetEnvironmentVariable('MAINFRAME_HOME', '/opt/mainframe')
    Assert-Equal '/opt/mainframe' (Get-MainframeCheckoutRoot) 'MAINFRAME_HOME wins for the checkout root'
    [Environment]::SetEnvironmentVariable('MAINFRAME_HOME', $null)

    # 9. no USERPROFILE (a linux box has none): the lookup must not die
    # building its candidate list. regression - the list was built eagerly,
    # so Join-Path on the empty USERPROFILE threw before the $HOME
    # candidates were ever tried, and the approval-signing key lookup (the
    # first linux caller of this function) crashed on exactly that.
    $savedUserProfile = [Environment]::GetEnvironmentVariable('USERPROFILE')
    try {
        [Environment]::SetEnvironmentVariable('USERPROFILE', $null)
        $expectedCheckout = Join-Path $HOME 'Downloads/mainframe'
        if (Test-Path (Join-Path $expectedCheckout 'vault-secret.psm1')) {
            Assert-Equal $expectedCheckout (Get-MainframeCheckoutRoot) `
                'checkout root resolves through $HOME with no USERPROFILE'
        } else {
            $null = Get-MainframeCheckoutRoot
            Assert-True $true 'checkout root lookup survives a missing USERPROFILE'
        }
    } finally {
        [Environment]::SetEnvironmentVariable('USERPROFILE', $savedUserProfile)
    }
} finally {
    Restore-Env
}

Write-Host "mainframe-paths checks: $script:checks passed"
