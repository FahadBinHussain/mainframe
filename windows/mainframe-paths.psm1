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
        # the modules moved to windows/ in the 2026-11-15 restructure; an
        # older checkout still has them at the root. either layout counts.
        if ((Test-Path -LiteralPath (Join-Path $candidate 'windows/vault-secret.psm1')) -or
            (Test-Path -LiteralPath (Join-Path $candidate 'vault-secret.psm1'))) { return $candidate }
    }
    return $null
}

function Get-MainframeConfigValue {
    <#
    .SYNOPSIS
        read one key out of mainframe.config.json.

    .DESCRIPTION
        one config file drives both machines, so the lookup lives HERE and
        every consumer asks this function. the candidates are the checkout
        and the profile root - all resolved through this module, so linux
        never gets a windows-only path (a literal '.config\mainframe' never
        matches on linux).

        the working directory is deliberately NOT a candidate: a crafted
        mainframe.config.json in a directory the runner happens to run from
        could override ntfyServer/pagesBase/bwServer/ntfyTopic (M7), and a
        malicious pagesBase points the approval link at an attacker-hosted
        page copy. checkout + profile root suffice.

        returns $null when the key is absent or the file is unreadable.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Key
    )
    $candidates = @(
        (Join-Path $PSScriptRoot '..\mainframe.config.json')
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

function Set-MainframeFileOwnerOnly {
    <#
    .SYNOPSIS
        tighten a file to owner-only (0600) on posix; a no-op on windows,
        where the file inherits the profile directory acl.
    .DESCRIPTION
        the one mode-tightening implementation: [IO.File]::SetUnixFileMode
        where the runtime has it (.NET 7+), `chmod 600` where it does not
        (older pwsh on linux). a failure warns loudly instead of passing
        silently - a secret file left world-readable is a real finding
        (L11/L12), not a cosmetic one.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )
    if ($env:OS -eq 'Windows_NT') { return }
    try {
        $mode = [System.IO.UnixFileMode]::UserRead -bor [System.IO.UnixFileMode]::UserWrite
        [System.IO.File]::SetUnixFileMode($Path, $mode)
        return
    } catch {}
    try {
        & chmod 600 $Path 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { return }
    } catch {}
    Write-MainframeWarning "could not tighten the mode of $Path - it may be readable by other users"
}

function Write-MainframePrivateFile {
    <#
    .SYNOPSIS
        write secret content to a file that is never world-readable, even
        briefly: the bytes land in a 0600 temp file first and are then moved
        over the target, so the target path only ever appears already 0600.
    .DESCRIPTION
        the target is created by a rename, not a truncate: a reader either
        sees the old file or the new one, never a half-written one, and the
        umask never gets a say. the temp file carries a random suffix, so a
        local process cannot guess its name in the microsecond window before
        the chmod lands.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Content
    )
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        $null = New-Item -ItemType Directory -Force -Path $dir
    }
    $tmp = "$Path.$PID.$([guid]::NewGuid().ToString('N').Substring(0, 8)).tmp"
    try {
        [IO.File]::WriteAllText($tmp, $Content, (New-Object System.Text.UTF8Encoding($false)))
        Set-MainframeFileOwnerOnly -Path $tmp
        Move-Item -LiteralPath $tmp -Destination $Path -Force
    } finally {
        if ([IO.File]::Exists($tmp)) {
            [IO.File]::Delete($tmp)
        }
    }
    return $Path
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
    Set-MainframeFileOwnerOnly, `
    Write-MainframePrivateFile, `
    Write-MainframeWarning
