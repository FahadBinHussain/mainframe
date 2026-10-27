<#
.SYNOPSIS
    Immediately lock the Bitwarden vault and clear the local session key.
.DESCRIPTION
    Purges %APPDATA%\mainframe\accounts\bitwarden\session.key, removes $env:BW_SESSION,
    clears session and item memory caches, and calls 'bw lock'.
    Next time an agent or script requests a vault secret, 1-tap mobile approval
    will be triggered on demand.
#>
param()

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $scriptDir 'vault-secret.psm1') -Force -DisableNameChecking
Lock-VaultSession
