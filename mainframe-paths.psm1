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
    $candidates = @()
    if ($env:USERPROFILE) { $candidates += (Join-Path $env:USERPROFILE 'Downloads\mainframe') }
    $candidates += (Join-Path $HOME 'Downloads\mainframe')
    $candidates += (Join-Path $HOME 'Downloads/mainframe')
    $candidates += (Join-Path $HOME '.local/share/mainframe')
    foreach ($candidate in $candidates) {
        if (-not $candidate) { continue }
        if (Test-Path -LiteralPath (Join-Path $candidate 'vault-secret.psm1')) { return $candidate }
    }
    return $null
}

function Get-MainframeConfigValue {
    <#
    .SYNOPSIS
        read one key out of mainframe.config.json.

    .DESCRIPTION
        one config file drives both machines, so the lookup lives HERE and
        every consumer asks this function. the candidates are the checkout,
        the working directory and the profile root - all resolved through
        this module, so linux never gets a windows-only path (a literal
        '.config\mainframe' never matches on linux).

        returns $null when the key is absent or the file is unreadable.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Key
    )
    $candidates = @(
        (Join-Path $PSScriptRoot 'mainframe.config.json')
        (Join-Path (Get-Location) 'mainframe.config.json')
        (Join-Path (Get-MainframeProfileRoot) 'mainframe.config.json')
    )
    foreach ($candidate in $candidates) {
        if (-not $candidate) { continue }
        if (Test-Path -LiteralPath $candidate) {
            try {
                $json = Get-Content -LiteralPath $candidate -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                $value = $json.$Key
                if ($value) { return ([string]$value).Trim() }
            } catch {}
        }
    }
    return $null
}

function Write-MainframeWarning {
    <#
    .SYNOPSIS
        write a warning to stderr, never to stdout.

    .DESCRIPTION
        stdout belongs to the machine: vault-flow.ps1 prints its result
        document there, and a caller reads stdout as json. a Write-Warning
        lands on stdout in pwsh 7 when the output is redirected, so it would
        corrupt that document - warnings go to stderr instead.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )
    [Console]::Error.WriteLine("vault: $Message")
}

Export-ModuleMember -Function `
    Get-MainframeProfileRoot, `
    Get-MainframeAccountsDir, `
    Get-MainframeAccountDir, `
    Get-MainframeSessionKeyPath, `
    Get-MainframeCheckoutRoot, `
    Get-MainframeConfigValue, `
    Write-MainframeWarning
