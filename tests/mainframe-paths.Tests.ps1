# No Pester dependency. Runs under windows powershell 5.1 AND pwsh 7.
#
# The point of this module is that ONE rule decides where the profile lives,
# on both platforms. These checks pin that rule down, including the linux
# branch - which is exercised here by clearing $env:OS, the flag the module
# uses to tell windows from linux.
$ErrorActionPreference = 'Stop'
$module = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\windows\mainframe-paths.psm1'))

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
        if (Test-Path (Join-Path $expectedCheckout 'windows\vault-secret.psm1')) {
            Assert-Equal $expectedCheckout (Get-MainframeCheckoutRoot) `
                'checkout root resolves through $HOME with no USERPROFILE'
        } else {
            $null = Get-MainframeCheckoutRoot
            Assert-True $true 'checkout root lookup survives a missing USERPROFILE'
        }
    } finally {
        [Environment]::SetEnvironmentVariable('USERPROFILE', $savedUserProfile)
    }

    # 10. the working directory is NOT a config candidate (M7): a crafted
    # mainframe.config.json in the directory the runner happens to run from
    # must not override anything - the profile root wins, and a key that
    # exists ONLY in the CWD file is invisible.
    $cwdRoot = Join-Path ([IO.Path]::GetTempPath()) ('mf-paths-cwd-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $cwdDir = Join-Path $cwdRoot 'work'
    $cwdProfile = Join-Path $cwdRoot 'profile'
    New-Item -ItemType Directory -Force -Path $cwdDir, $cwdProfile | Out-Null
    Set-Content -LiteralPath (Join-Path $cwdDir 'mainframe.config.json') -Value '{"testCwdProbeKey123":"cwd-value","testCwdOnlyKey123":"cwd-only"}' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $cwdProfile 'mainframe.config.json') -Value '{"testCwdProbeKey123":"profile-value"}' -Encoding UTF8
    $savedCwd = (Get-Location).Path
    try {
        [Environment]::SetEnvironmentVariable('MAINFRAME_PROFILE_ROOT', $cwdProfile)
        Set-Location -LiteralPath $cwdDir
        Assert-Equal 'profile-value' (Get-MainframeConfigValue -Key 'testCwdProbeKey123') `
            'a CWD config never overrides the profile config'
        Assert-Equal $null (Get-MainframeConfigValue -Key 'testCwdOnlyKey123') `
            'a key that exists only in a CWD config is invisible'
    } finally {
        Set-Location -LiteralPath $savedCwd
        Remove-Item -LiteralPath $cwdRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    # 11. a private file is written 0600, exact bytes, and an overwrite keeps
    # the mode and leaves no temp file behind (L11/L12)
    $privRoot = Join-Path ([IO.Path]::GetTempPath()) ('mf-paths-priv-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $privRoot | Out-Null
    try {
        $privFile = Join-Path $privRoot 'secret.txt'
        Write-MainframePrivateFile -Path $privFile -Content 'first-secret' | Out-Null
        Assert-Equal 'first-secret' ([IO.File]::ReadAllText($privFile)) 'the private file holds the exact bytes'
        $privMode = $null
        if ($env:OS -ne 'Windows_NT' -and (Get-Command stat -ErrorAction SilentlyContinue)) {
            $privMode = ((& stat -c %a $privFile 2>$null) -join '').Trim()
            Assert-Equal '600' $privMode 'the private file is created 0600'
        }
        Write-MainframePrivateFile -Path $privFile -Content 'second-secret' | Out-Null
        Assert-Equal 'second-secret' ([IO.File]::ReadAllText($privFile)) 'an overwrite replaces the bytes'
        if ($null -ne $privMode) {
            $privMode2 = ((& stat -c %a $privFile 2>$null) -join '').Trim()
            Assert-Equal '600' $privMode2 'an overwrite keeps the file 0600'
        }
        $leftovers = @(Get-ChildItem -LiteralPath $privRoot -Filter '*.tmp' -ErrorAction SilentlyContinue)
        Assert-Equal 0 $leftovers.Count 'no temp file is left behind'

        # 12. the mode helper tightens an existing loose file (posix only)
        $looseFile = Join-Path $privRoot 'loose.txt'
        Set-Content -LiteralPath $looseFile -Value 'x' -NoNewline
        if ($env:OS -ne 'Windows_NT' -and (Get-Command stat -ErrorAction SilentlyContinue)) {
            & chmod 644 $looseFile
            Set-MainframeFileOwnerOnly -Path $looseFile
            $looseMode = ((& stat -c %a $looseFile 2>$null) -join '').Trim()
            Assert-Equal '600' $looseMode 'the mode helper tightens a loose file to 0600'
        } else {
            Set-MainframeFileOwnerOnly -Path $looseFile
            Assert-True $true 'the mode helper is a no-op on windows'
        }
    } finally {
        Remove-Item -LiteralPath $privRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
} finally {
    Restore-Env
}

Write-Host "mainframe-paths checks: $script:checks passed"
