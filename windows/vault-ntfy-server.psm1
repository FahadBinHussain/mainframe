<#
.SYNOPSIS
    vault-held ntfy relay server: every machine converges its local
    ntfyServer to the vault value on its next vault flow.

.DESCRIPTION
    mirrors the topic convergence in vault-approval.psm1
    (Sync-VaultNtfyTopicFromVault) exactly, for the relay instead of
    the topic: the vault item
    `github.com/FahadBinHussain/mainframe / mainframe.ntfy-server`
    (securenote, the full relay /ntfy url in the notes) is canonical,
    and a machine whose local config differs updates it atomically
    (mode 0600) at vault-flow time. no item, a dead session, or a
    malformed vault value all leave the local config exactly as it is.

    it lives in its own module instead of next to the topic sync in
    vault-approval.psm1 because that file was mid-edit when this
    landed; moving these two functions in beside the topic sync is a
    clean-up for later, the behavior is identical either way.

    the server url is NOT a secret (the topic is the credential), so
    the convergence log names the new relay in full - same as the
    vault flow already logs the relay it approves through.
#>

# the same place (see mainframe-paths.psm1).
Import-Module (Join-Path $PSScriptRoot 'mainframe-paths.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'mainframe-json.psm1') -Force -DisableNameChecking

$script:VaultNtfyServerVaultItemName = 'github.com/FahadBinHussain/mainframe / mainframe.ntfy-server'

function Invoke-VaultServerBwCommand {
    <#
    .SYNOPSIS
        run the bw CLI with a hard timeout. returns stdout on success,
        $null on any failure (bw missing, non-zero exit, timeout) - the
        sync treats every failure as "no live session", never as an
        error. the same shape as Invoke-BwApprovalCommand in
        vault-approval.psm1, which is not exported.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        [int]$TimeoutSeconds = 10
    )

    $bw = Get-Command bw -ErrorAction SilentlyContinue
    if (-not $bw) { return $null }
    try {
        # Arguments (not ArgumentList) so windows powershell 5.1 works too.
        $quoted = foreach ($a in $Arguments) { '"' + ($a -replace '"', '\"') + '"' }
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $bw.Source
        $psi.Arguments = ($quoted -join ' ')
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
            try { $proc.Kill() } catch {}
            return $null
        }
        $out = $proc.StandardOutput.ReadToEnd()
        if ($proc.ExitCode -ne 0) { return $null }
        return $out
    } catch {
        return $null
    }
}

function Test-VaultServerLiveSession {
    <#
    .SYNOPSIS
        true when the bw CLI reports unlocked - the only condition under
        which the server may be fetched from the vault without a user
        step. never prompts, never throws.
    #>
    param([string]$Session = $null)

    $args = @('status')
    if ($Session) { $args += @('--session', $Session) }
    $out = Invoke-VaultServerBwCommand -Arguments $args -TimeoutSeconds 10
    if (-not $out) { return $false }
    try {
        $status = $out | ConvertFrom-Json
        return ($status.status -eq 'unlocked')
    } catch {
        return $false
    }
}

function Get-VaultNtfyServerFromVault {
    <#
    .SYNOPSIS
        the canonical ntfy relay server from the vault item (notes), or
        $null. never throws. a malformed vault value is ignored with a
        loud warning - a bad item must never poison the local config.
    .DESCRIPTION
        valid means: an https url whose path is exactly /ntfy (a
        trailing slash is tolerated and trimmed). anything else - http,
        a bare host, a wrong path - is malformed. the relay host itself
        is not validated beyond that: the fleet moves relays by editing
        this one item, so the item must be free to name a new host.
    #>
    param([string]$Session = $null)

    if (-not (Test-VaultServerLiveSession -Session $Session)) { return $null }
    $args = @('list', 'items', '--search', $script:VaultNtfyServerVaultItemName)
    if ($Session) { $args += @('--session', $Session) }
    $out = Invoke-VaultServerBwCommand -Arguments $args -TimeoutSeconds 15
    if (-not $out) { return $null }
    try {
        $items = ConvertFrom-JsonArray -Json $out
    } catch {
        return $null
    }
    # --search is a substring match: only the exact item name is the server.
    $item = @($items | Where-Object { [string]$_.name -eq $script:VaultNtfyServerVaultItemName }) | Select-Object -First 1
    if (-not $item -or -not $item.notes) { return $null }
    $server = ([string]$item.notes).Trim().TrimEnd('/')
    if ($server -cnotmatch '^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?/ntfy$') {
        Write-MainframeWarning 'the vault ntfy-server item holds a malformed value (expected an https url ending in /ntfy) - ignoring it, the local config is unchanged. fix the vault item, or delete it to keep the local value.'
        return $null
    }
    return $server
}

function Sync-VaultNtfyServerFromVault {
    <#
    .SYNOPSIS
        converge the local config to the vault-held ntfy server. returns
        $true when the vault server was read (whether or not a write
        happened), $false when there is no live session, no vault item,
        or a malformed value - in all of those cases the local config is
        left exactly as it is (existing behavior). never throws.
    .DESCRIPTION
        writes go to every config file that carries a server: the profile
        config and the checkout-root config (the checkout wins on reads,
        so leaving it stale would shadow the converged value). each write
        is atomic and 0600, via Write-MainframePrivateFile. a config that
        is missing or carries no server is left alone; an unparseable one
        is warned about loudly and left alone. a real change is logged
        LOUDLY with the new relay in full - the server url is not a
        secret. an already-converged machine stays silent.
    #>
    param(
        [string]$Session = $null,
        [string]$ProfileConfigPath = $null,
        [string]$CheckoutConfigPath = $null
    )

    $vaultServer = Get-VaultNtfyServerFromVault -Session $Session
    if (-not $vaultServer) { return $false }
    $profileConfig = if ($ProfileConfigPath) { $ProfileConfigPath } else { (Join-Path (Get-MainframeProfileRoot) 'mainframe.config.json') }
    $checkoutConfig = if ($CheckoutConfigPath) { $CheckoutConfigPath } else { (Join-Path $PSScriptRoot '..\mainframe.config.json') }
    $changed = $false
    foreach ($path in @($profileConfig, $checkoutConfig)) {
        if (-not $path -or -not (Test-Path -LiteralPath $path)) { continue }
        try {
            $json = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        } catch {
            Write-MainframeWarning "ntfy server convergence: config is not parseable json, left alone: $path"
            continue
        }
        if (-not $json.ntfyServer) { continue }
        if ([string]$json.ntfyServer -eq $vaultServer) { continue }
        $json.ntfyServer = $vaultServer
        try {
            $content = ($json | ConvertTo-Json -Depth 10) + "`n"
            Write-MainframePrivateFile -Path $path -Content $content | Out-Null
            $changed = $true
        } catch {
            Write-MainframeWarning "ntfy server convergence: could not write $path - the local config is unchanged. ($($_.Exception.Message))"
        }
    }
    if ($changed) {
        Write-MainframeWarning "ntfy server converged from the vault (now $vaultServer) - the local config was stale"
    }
    return $true
}

Export-ModuleMember -Function `
    Get-VaultNtfyServerFromVault, `
    Sync-VaultNtfyServerFromVault
