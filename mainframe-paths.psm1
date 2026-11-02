<#
.SYNOPSIS
    where mainframe keeps its profile data, on windows and on linux.

.DESCRIPTION
    ONE answer to "where does this live", so both platforms read the same
    place and the helpers behave identically:

        windows : %APPDATA%\mainframe
        linux   : $XDG_CONFIG_HOME\mainframe  (or ~/.config/mainframe)

    this module is the ONLY place that knows those rules. vault-secret.psm1
    and vault-approval.psm1 import it, and every account helper resolves its
    profile through it - so a helper that runs on linux finds the same
    account profiles, the same session key and the same tool state that
    windows does.

    overrides:
        $env:MAINFRAME_PROFILE_ROOT  - use this profile root verbatim
        $env:MAINFRAME_HOME          - the mainframe checkout itself

    it is dependency-free and runs on windows powershell 5.1 and pwsh 7.
#>

function Get-MainframeProfileRoot {
    if ($env:MAINFRAME_PROFILE_ROOT) { return $env:MAINFRAME_PROFILE_ROOT }
    if ($env:OS -eq 'Windows_NT') {
        # the windows layout is unchanged - existing profiles stay put
        return (Join-Path $env:APPDATA 'mainframe')
    }
    # linux follows the XDG base directory spec
    $xdg = if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { (Join-Path $HOME '.config') }
    return (Join-Path $xdg 'mainframe')
}

function Get-MainframeAccountsDir {
    <#
    .SYNOPSIS
        the directory that holds the per-tool account profiles
        (vercel, github, hf, ...).
    #>
    return (Join-Path (Get-MainframeProfileRoot) 'accounts')
}

function Get-MainframeAccountDir {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Account
    )
    return (Join-Path (Get-MainframeAccountsDir) $Account)
}

function Get-MainframeSessionKeyPath {
    <#
    .SYNOPSIS
        the cached raw bw session key - the same file on both platforms.
    #>
    return (Join-Path (Join-Path (Get-MainframeAccountsDir) 'bitwarden') 'session.key')
}

function Get-MainframeCheckoutRoot {
    <#
    .SYNOPSIS
        the mainframe checkout itself, for scripts that need the repo.

    .DESCRIPTION
        used by the helpers in other repos to find vault-secret.psm1 and
        friends. $env:MAINFRAME_HOME wins; otherwise the well known clone
        locations are searched. $null means "not found" - never a guess.
    #>
    if ($env:MAINFRAME_HOME) { return $env:MAINFRAME_HOME }
    $candidates = @(
        (Join-Path $env:USERPROFILE 'Downloads\mainframe')
        (Join-Path $HOME 'Downloads\mainframe')
        (Join-Path $HOME 'Downloads/mainframe')
        (Join-Path $HOME '.local/share/mainframe')
    )
    foreach ($candidate in $candidates) {
        if (-not $candidate) { continue }
        if (Test-Path -LiteralPath (Join-Path $candidate 'vault-secret.psm1')) { return $candidate }
    }
    return $null
}

Export-ModuleMember -Function `
    Get-MainframeProfileRoot, `
    Get-MainframeAccountsDir, `
    Get-MainframeAccountDir, `
    Get-MainframeSessionKeyPath, `
    Get-MainframeCheckoutRoot
