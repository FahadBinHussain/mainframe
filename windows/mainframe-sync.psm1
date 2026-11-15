<#
.SYNOPSIS
    self-healing checkout sync: keep the running mainframe checkout on
    its upstream tip, without ever asking a human to pull, reset, or
    relay a command to another machine.

.DESCRIPTION
    Sync-MainframeCheckout is called at the start of vault-flow.ps1
    (and its python twin sync_checkout in linux/linux_real.py runs at
    the start of the linux engine), BEFORE the repo modules load - so a
    machine that is behind, or sitting on rewritten history, heals
    itself on its next vault flow and then runs the fresh code.

    algorithm (both implementations agree):

      1. not a git checkout, git missing, or no origin remote: warn
         LOUDLY and skip. the flow proceeds with local code.
      2. no upstream branch: warn loudly and skip.
      3. git pull --ff-only. success (already current, or fast-forwarded)
         means done - silent.
      4. pull failed (divergent history, e.g. after a history rewrite):
         stash uncommitted changes if the tree is dirty, fetch, reset
         --hard to the upstream ref, pop the stash. untracked files are
         never touched (no -u, no clean).
      5. any step failing warns LOUDLY and aborts the sync, leaving the
         checkout as-is. a failed stash pop keeps the work in the stash
         (recoverable) and says so - it is never dropped.

    the sync NEVER blocks an approval or a run: every failure mode ends
    in "proceed with local code + a loud warning". the function never
    throws.

    the reset targets the current branch's UPSTREAM ref (origin/main on
    main), not a hardcoded branch - a feature-branch checkout resets to
    its own upstream. unpushed local commits are counted and warned
    about before the reset; the reset keeps them in the reflog only.
#>

function Invoke-GitCommand {
    <#
    .SYNOPSIS
        run git with a hard timeout. returns a pscustomobject with
        ExitCode/Stdout/Stderr, or $null when git is missing or the call
        times out. never throws.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        [string]$WorkingDirectory = $null,
        [int]$TimeoutSeconds = 60
    )

    $git = Get-Command git -ErrorAction SilentlyContinue
    if (-not $git) { return $null }
    try {
        # Arguments (not ArgumentList) so windows powershell 5.1 works too.
        $quoted = foreach ($a in $Arguments) { '"' + ($a -replace '"', '\"') + '"' }
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $git.Source
        $psi.Arguments = ($quoted -join ' ')
        if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
            try { $proc.Kill() } catch {}
            return $null
        }
        return [pscustomobject]@{
            ExitCode = $proc.ExitCode
            Stdout   = $proc.StandardOutput.ReadToEnd()
            Stderr   = $proc.StandardError.ReadToEnd()
        }
    } catch {
        return $null
    }
}

function Write-SyncWarning {
    # stderr, never stdout - vault-flow.ps1 prints a JSON document there.
    param([string]$Message)
    [Console]::Error.WriteLine("mainframe-sync: $Message")
}

function Sync-MainframeCheckout {
    <#
    .SYNOPSIS
        bring the checkout at $Checkout onto its upstream tip. returns
        $true when the checkout is on the upstream tip afterwards
        (synced, or already current), $false when the sync was skipped
        or failed - in which case the caller proceeds with local code
        and the warning is already printed. never throws.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Checkout
    )

    try {
        if (-not (Test-Path -LiteralPath $Checkout -PathType Container)) {
            Write-SyncWarning "not a directory, skipping self-sync: $Checkout"
            return $false
        }
        if (-not (Test-Path -LiteralPath (Join-Path $Checkout '.git'))) {
            Write-SyncWarning "not a git checkout, skipping self-sync: $Checkout"
            return $false
        }
        if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
            Write-SyncWarning 'git not found on PATH, skipping self-sync'
            return $false
        }
        $origin = Invoke-GitCommand -Arguments @('-C', $Checkout, 'remote', 'get-url', 'origin') -TimeoutSeconds 30
        if (-not $origin -or $origin.ExitCode -ne 0) {
            Write-SyncWarning "no origin remote, skipping self-sync: $Checkout"
            return $false
        }
        $upstreamOut = Invoke-GitCommand -Arguments @('-C', $Checkout, 'rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{u}') -TimeoutSeconds 30
        if (-not $upstreamOut -or $upstreamOut.ExitCode -ne 0) {
            Write-SyncWarning "no upstream branch, skipping self-sync: $Checkout"
            return $false
        }
        $upstream = $upstreamOut.Stdout.Trim()
        if (-not $upstream) {
            Write-SyncWarning "no upstream branch, skipping self-sync: $Checkout"
            return $false
        }

        # fast path: already current, or a clean fast-forward.
        $pulled = Invoke-GitCommand -Arguments @('-C', $Checkout, 'pull', '--ff-only') -TimeoutSeconds 60
        if ($pulled -and $pulled.ExitCode -eq 0) { return $true }

        # slow path: divergent history (a rewrite, or unpushed local
        # commits against a moved upstream). stash, fetch, reset, pop.
        $stashed = $false
        $status = Invoke-GitCommand -Arguments @('-C', $Checkout, 'status', '--porcelain') -TimeoutSeconds 30
        if ($status -and $status.ExitCode -eq 0 -and $status.Stdout.Trim()) {
            $stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            $stash = Invoke-GitCommand -Arguments @('-C', $Checkout, 'stash', 'push', '-m', "mainframe self-sync $stamp") -TimeoutSeconds 30
            if (-not $stash -or $stash.ExitCode -ne 0) {
                Write-SyncWarning 'git stash failed - aborting the sync, the checkout is left exactly as-is.'
                return $false
            }
            $stashed = $true
        }

        $fetched = Invoke-GitCommand -Arguments @('-C', $Checkout, 'fetch', 'origin') -TimeoutSeconds 60
        if (-not $fetched -or $fetched.ExitCode -ne 0) {
            Write-SyncWarning 'git fetch origin failed (no network?) - aborting the sync, the checkout is left as-is.'
            if ($stashed) {
                $restored = Invoke-GitCommand -Arguments @('-C', $Checkout, 'stash', 'pop') -TimeoutSeconds 30
                if (-not $restored -or $restored.ExitCode -ne 0) {
                    Write-SyncWarning 'the stash could not be popped back after the failed fetch - your uncommitted changes are in the stash (git stash list), recover them by hand.'
                }
            }
            return $false
        }

        $ahead = Invoke-GitCommand -Arguments @('-C', $Checkout, 'rev-list', '--count', '@{u}..HEAD') -TimeoutSeconds 30
        if ($ahead -and $ahead.ExitCode -eq 0) {
            $aheadCount = 0
            if ([int]::TryParse($ahead.Stdout.Trim(), [ref]$aheadCount) -and $aheadCount -gt 0) {
                Write-SyncWarning "this checkout has $aheadCount local commit(s) not on $upstream - the reset below keeps them in the reflog only (git reflog to recover)."
            }
        }

        $reset = Invoke-GitCommand -Arguments @('-C', $Checkout, 'reset', '--hard', $upstream) -TimeoutSeconds 60
        if (-not $reset -or $reset.ExitCode -ne 0) {
            Write-SyncWarning "git reset --hard $upstream failed - aborting the sync, the checkout is left as-is."
            if ($stashed) {
                $restored = Invoke-GitCommand -Arguments @('-C', $Checkout, 'stash', 'pop') -TimeoutSeconds 30
                if (-not $restored -or $restored.ExitCode -ne 0) {
                    Write-SyncWarning 'the stash could not be popped back after the failed reset - your uncommitted changes are in the stash (git stash list), recover them by hand.'
                }
            }
            return $false
        }

        if ($stashed) {
            $popped = Invoke-GitCommand -Arguments @('-C', $Checkout, 'stash', 'pop') -TimeoutSeconds 30
            if (-not $popped -or $popped.ExitCode -ne 0) {
                Write-SyncWarning "the stash pop conflicted after the reset - your uncommitted changes are STILL in the stash (git stash list), resolve them by hand. the stash was NOT dropped."
                return $false
            }
        }
        Write-SyncWarning "checkout was reset to $upstream (divergent history) - uncommitted changes preserved."
        return $true
    } catch {
        Write-SyncWarning "self-sync hit an unexpected error - aborting, the checkout is left as-is. ($($_.Exception.Message))"
        return $false
    }
}

Export-ModuleMember -Function Sync-MainframeCheckout
