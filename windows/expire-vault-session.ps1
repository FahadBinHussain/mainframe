# expire-vault-session.ps1 - the scheduled-expiry entry point.
#
# invoked by the one-shot scheduled job registered at unlock (schtasks on
# windows, a systemd transient timer on linux, a detached sleeper as
# fallback) - never run by hand unless you mean to expire the session NOW.
# imports vault-secret.psm1 and runs Invoke-VaultSessionExpiryCheck, which
# expires the session only if it is actually due (age + key-hash guards
# stop a stale job from killing a fresh session) and always unregisters
# the pending job before returning, so no orphaned task/timer is left.
#
# the scheduler passes -ProfileRoot and -BwPath explicitly (full paths):
# a scheduled context has no guarantee of the user's env. measured on this
# VM 2026-11-15: a systemd-run service runs with an EMPTY HOME (so `bw`
# would look for its CLI state in the wrong place) and a private /tmp, so
# the registration passes HOME via --setenv and the wrapper takes the bw
# path as an argument. on windows, bare `pwsh` is NOT on PATH in the
# scheduled-task context (the MojifyReload task failed exactly this way),
# so the registration records the full pwsh path in the task command.

[CmdletBinding()]
param(
    [string]$ProfileRoot,
    [string]$BwPath = 'bw',
    [int]$DelaySeconds = 0
)

$ErrorActionPreference = 'Stop'

if ($ProfileRoot) { $env:MAINFRAME_PROFILE_ROOT = $ProfileRoot }

# the sleeper mechanism starts this script at registration time and waits
# out the TTL here; the scheduler mechanisms invoke it at the TTL mark
# with no delay.
if ($DelaySeconds -gt 0) {
    Start-Sleep -Seconds $DelaySeconds
}

try {
    Import-Module (Join-Path $PSScriptRoot 'vault-secret.psm1') -Force -DisableNameChecking
    $outcome = Invoke-VaultSessionExpiryCheck -BwPath $BwPath
    Write-Host "scheduled expiry finished: $outcome"
    exit 0
} catch {
    Write-Warning "scheduled expiry FAILED: $_"
    exit 1
}
