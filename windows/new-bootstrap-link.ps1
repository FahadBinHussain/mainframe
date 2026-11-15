<#
    new-bootstrap-link.ps1 - create (or rotate) the ONE permanent bootstrap link

    reads the local mainframe.config.json and serves it from the relay
    under a client-generated unguessable 128-bit token. prints ONE link
    and nothing else secret - never the config, never the topic.

    the link is PERMANENT: GET is repeatable, it never expires, and a
    failed download can simply be re-run. there is exactly one link:
    a plain run generates a fresh token, stores the new link in the
    vault, PUTs the current config under it, deletes the old token's
    bundle, and writes the new token into the local profile config.
    rotation (windows/rotate-ntfy-topic.ps1) re-pushes the bundle under
    the same token, so the link always serves the current config.

    the link goes to a new machine, where bootstrap.sh / bootstrap.ps1
    downloads the bundle, places the config, clones mainframe and runs
    the restore. no file copying between machines, ever.

    the vault item `github.com/FahadBinHussain/mainframe /
    mainframe.bootstrap-link` (a secure note, the full link in notes)
    is written FIRST, before the relay or the local config is touched -
    so a live bw session is required. a dead session fails LOUDLY and
    nothing is changed.

    the bundle is mainframe.config.json ONLY (topic + server + pagesBase
    + email + this link's token) - no signing key, it self-heals from
    the vault after the first unlock.

    usage:
        pwsh windows/new-bootstrap-link.ps1 [-DryRun | -PushOnly]

    -DryRun validates the config and prints the relay base + topic
    fingerprint without creating anything.
    -PushOnly re-pushes the current local config under the EXISTING
    token (local config bootstrapToken first, else the vault item's
    link). no new token, no vault write, no link printed - the recovery
    path when a rotation's bundle push failed.
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$PushOnly,
    [string]$BwPath = 'bw'
)

$ErrorActionPreference = 'Stop'

$script:VaultBootstrapLinkItemName = 'github.com/FahadBinHussain/mainframe / mainframe.bootstrap-link'
$script:BwLastError = ''

function Get-BootstrapRelayBase {
    param([string]$NtfyServer)
    if ([string]::IsNullOrWhiteSpace($NtfyServer)) {
        throw 'no ntfyServer in the local config - the bootstrap endpoint lives on the worker relay, not on ntfy.sh. set ntfyServer to the worker relay url (ending in /ntfy) and re-run.'
    }
    $server = $NtfyServer.TrimEnd('/')
    if (-not $server.EndsWith('/ntfy')) {
        throw "ntfyServer '$server' does not end in /ntfy - the bootstrap endpoint lives next to the relay's /ntfy mount. refusing to send the config anywhere else (sending it to plain ntfy.sh would publish it to a public topic)."
    }
    $base = $server.Substring(0, $server.Length - 5)
    if (-not $base.StartsWith('https://')) {
        throw "relay base '$base' is not https - refusing to send the config over plain http."
    }
    return $base
}

function New-BootstrapToken {
    # 128 bits from a cryptographic rng, base64url without padding:
    # 16 bytes -> exactly 22 chars of [A-Za-z0-9_-].
    $bytes = New-Object byte[] 16
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($bytes)
    } finally {
        $rng.Dispose()
    }
    return ([Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_'))
}

function Test-BootstrapTokenFormat {
    param([string]$Value)
    # -cmatch, not -match: the token alphabet is case-sensitive, and a
    # case-insensitive check would accept values the relay rejects.
    return ($Value -cmatch '^[A-Za-z0-9_-]{22}$')
}

function Test-NtfyTopicFormat {
    param([string]$Value)
    return ($Value -cmatch '^[a-z0-9]{32}$')
}

function Get-BootstrapTokenFromLink {
    # the token is the last path segment of a bootstrap link, or $null
    # when the value is not a bootstrap link at all.
    param([string]$Link)
    if (-not $Link) { return $null }
    if ($Link.Trim() -cmatch '^https://[^/]+/bootstrap/([A-Za-z0-9_-]{22})$') {
        return $Matches[1]
    }
    return $null
}

function Get-RestErrorDetail {
    # one readable line out of a failed Invoke-RestMethod: the http
    # status when the runtime kept it, plus the relay's own error field
    # when the body carried one. 429 names the wait - the relay answers
    # Retry-After: 60.
    param($ErrorRecord)
    $detail = $ErrorRecord.Exception.Message
    $status = $null
    try {
        if ($ErrorRecord.Exception.Response -and $ErrorRecord.Exception.Response.StatusCode) {
            $status = [int]$ErrorRecord.Exception.Response.StatusCode
        }
    } catch {}
    if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
        try {
            $detail = ($ErrorRecord.ErrorDetails.Message | ConvertFrom-Json).error
        } catch {
            $detail = $ErrorRecord.ErrorDetails.Message
        }
    }
    if ($status -eq 429) {
        return "HTTP 429 (rate-limited - wait 60 seconds and re-run): $detail"
    }
    if ($status) {
        return "HTTP ${status}: $detail"
    }
    return $detail
}

function Write-JsonAtomically {
    # write one config file: temp file in the same dir + move, so a
    # failure never leaves a half-written config behind. temp file is
    # removed on failure. no BOM (a BOM breaks some json readers).
    param([string]$Path, [object]$JsonObject)
    $content = ($JsonObject | ConvertTo-Json -Depth 10) + "`n"
    $dir = Split-Path -Parent $Path
    $tmp = Join-Path $dir ('.' + (Split-Path -Leaf $Path) + '.tmp-' + [Guid]::NewGuid().ToString('N'))
    try {
        [System.IO.File]::WriteAllText($tmp, $content, [System.Text.UTF8Encoding]::new($false))
        if ($env:OS -ne 'Windows_NT') {
            # the config holds the topic: keep it owner-only like the original.
            & chmod 600 $tmp
            if ($LASTEXITCODE -ne 0) { throw "chmod 600 failed on $tmp - refusing to install a config with loose permissions." }
        }
        Move-Item -LiteralPath $tmp -Destination $Path -Force
    } catch {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        throw
    }
}

function Resolve-BwPath {
    # the bw CLI: -BwPath wins when it names a file (a path with a
    # separator is used literally); otherwise PATH, then the known linux
    # install locations. throws loudly when nothing is found - a link
    # without bw cannot write the vault item, and must not proceed.
    param([string]$Wanted)
    if ($Wanted -match '[\\/]') {
        if (Test-Path -LiteralPath $Wanted) { return $Wanted }
        throw "bw not found at -BwPath '$Wanted' - pass the real bw path, or put bw on PATH."
    }
    $found = Get-Command $Wanted -ErrorAction SilentlyContinue
    if ($found) { return $found.Source }
    $candidates = @(
        (Join-Path $HOME '.local/bin/bw')
        (Join-Path $HOME '.local/share/mainframe/tools/bw/bw')
    )
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }
    }
    throw "bw CLI not found on PATH or at the known install locations - the bootstrap link must be written to the vault item first, and that needs a live bw session. install the bitwarden CLI and unlock the vault, then re-run this script. nothing was changed."
}

function Get-BwSessionArgs {
    # --session args from the cached session key file when it exists.
    # the vault flow caches the key at accounts/bitwarden/session.key
    # under the profile root; without it, bw falls back to BW_SESSION or
    # its own state, and the status check below is the judge.
    param([string]$ProfileRoot)
    $sessionFile = Join-Path (Join-Path (Join-Path $ProfileRoot 'accounts') 'bitwarden') 'session.key'
    if (Test-Path -LiteralPath $sessionFile) {
        try {
            $key = (Get-Content -LiteralPath $sessionFile -Raw -ErrorAction Stop).Trim()
            if ($key) { return @('--session', $key) }
        } catch {}
    }
    return @()
}

function Invoke-Bw {
    # run bw, return stdout on exit 0, $null otherwise. stderr goes to a
    # temp file so stdout stays clean JSON for the calls that parse it,
    # and the error text lands in $script:BwLastError for the caller's
    # message. -Stdin pipes a string to the child (encode/create/edit).
    # the link itself is never in an argument list - it travels via
    # stdin JSON, never via a process command line anyone can read.
    param(
        [Parameter(Mandatory = $true)]
        [string]$Bw,
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        [string]$Stdin = $null
    )
    $errFile = [IO.Path]::GetTempFileName()
    try {
        if ($null -ne $Stdin) {
            $out = $Stdin | & $Bw @Arguments 2>$errFile
        } else {
            $out = & $Bw @Arguments 2>$errFile
        }
        $script:BwLastError = ''
        if (Test-Path -LiteralPath $errFile) {
            $err = Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue
            if ($err) { $script:BwLastError = $err.Trim() }
        }
        if ($LASTEXITCODE -ne 0) { return $null }
        if ($null -eq $out) { return '' }
        return ($out -join "`n")
    } catch {
        $script:BwLastError = $_.Exception.Message
        return $null
    } finally {
        Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue
    }
}

function ConvertFrom-BwJsonArray {
    # bw list output is a JSON array; windows powershell 5.1 turns '[]'
    # into $null, so an empty result is checked before parsing.
    param([string]$Json)
    if (-not $Json -or $Json.Trim() -eq '' -or $Json.Trim() -eq '[]') { return @() }
    return @($Json | ConvertFrom-Json)
}

function Assert-BwSessionLive {
    # the vault item is written (or read) only with a live session.
    # throws loudly when the vault is locked - the caller never proceeds
    # to the relay or the local config on a dead session.
    param(
        [Parameter(Mandatory = $true)]
        [string]$Bw,
        [string[]]$SessionArgs = @()
    )
    $statusOut = Invoke-Bw -Bw $Bw -Arguments (@('status') + $SessionArgs)
    $status = $null
    if ($statusOut) {
        try { $status = $statusOut | ConvertFrom-Json } catch { $status = $null }
    }
    if (-not $status -or $status.status -ne 'unlocked') {
        throw "no live bw session - the vault item must be written FIRST, and the vault is locked. unlock the vault (run the vault flow), then re-run this script. nothing was changed."
    }
}

function Find-VaultBootstrapLinkItem {
    # the vault link item by exact name, or $null when there is none.
    # throws loudly when bw itself fails - an unreadable vault is not
    # the same as a missing item, and the caller must not guess.
    param(
        [Parameter(Mandatory = $true)]
        [string]$Bw,
        [string[]]$SessionArgs = @()
    )
    $listOut = Invoke-Bw -Bw $Bw -Arguments (@('list', 'items', '--search', $script:VaultBootstrapLinkItemName) + $SessionArgs)
    if ($null -eq $listOut) {
        throw "bw list items failed - cannot find the vault bootstrap-link item, refusing to continue. ($script:BwLastError) nothing was changed."
    }
    $items = ConvertFrom-BwJsonArray -Json $listOut
    # --search is a substring match: only the exact item name is the link.
    return @($items | Where-Object { [string]$_.name -eq $script:VaultBootstrapLinkItemName }) | Select-Object -First 1
}

function Set-VaultBootstrapLink {
    # write the link into the vault item FIRST - before the relay or any
    # local config is touched. throws loudly on any failure (no live
    # session, bw error, create/edit refused) so the caller never
    # half-creates a link.
    param(
        [Parameter(Mandatory = $true)]
        [string]$Link,
        [Parameter(Mandatory = $true)]
        [string]$Bw,
        [string[]]$SessionArgs = @()
    )
    Assert-BwSessionLive -Bw $Bw -SessionArgs $SessionArgs
    $item = Find-VaultBootstrapLinkItem -Bw $Bw -SessionArgs $SessionArgs
    if ($item) {
        $itemJson = Invoke-Bw -Bw $Bw -Arguments (@('get', 'item', [string]$item.id) + $SessionArgs)
        if (-not $itemJson) {
            throw "bw get item failed for the vault bootstrap-link item - refusing to continue. ($script:BwLastError) nothing was changed."
        }
        try {
            $full = $itemJson | ConvertFrom-Json
        } catch {
            throw "bw get item returned unparseable json - refusing to continue. nothing was changed."
        }
        $full.notes = $Link
        $encoded = Invoke-Bw -Bw $Bw -Arguments @('encode') -Stdin ($full | ConvertTo-Json -Depth 10 -Compress)
        if (-not $encoded) {
            throw "bw encode failed for the updated vault bootstrap-link item - refusing to continue. ($script:BwLastError) nothing was changed."
        }
        $edited = Invoke-Bw -Bw $Bw -Arguments (@('edit', 'item', [string]$item.id) + $SessionArgs) -Stdin $encoded.Trim()
        if ($null -eq $edited) {
            throw "bw edit item failed for the vault bootstrap-link item - refusing to continue. ($script:BwLastError) nothing was changed."
        }
        Write-Host "vault bootstrap-link item updated: $script:VaultBootstrapLinkItemName"
        return
    }
    # the item is built explicitly: the rust bw CLI's `get template
    # item.securenote` returns just {"type":0} — no name/notes fields
    # to fill in, and the wrong type for a SecureNote (2) — so the
    # template is worse than useless here (measured 2026-11-15: the
    # first real link creation died setting .name on it).
    $newItem = [pscustomobject]@{
        type = 2
        name = $script:VaultBootstrapLinkItemName
        notes = $Link
        secureNote = [pscustomobject]@{ type = 0 }
    }
    $encoded = Invoke-Bw -Bw $Bw -Arguments @('encode') -Stdin ($newItem | ConvertTo-Json -Depth 10 -Compress)
    if (-not $encoded) {
        throw "bw encode failed for the new vault bootstrap-link item - refusing to continue. ($script:BwLastError) nothing was changed."
    }
    $created = Invoke-Bw -Bw $Bw -Arguments (@('create', 'item') + $SessionArgs) -Stdin $encoded.Trim()
    if ($null -eq $created) {
        throw "bw create item failed for the vault bootstrap-link item - refusing to continue. ($script:BwLastError) nothing was changed."
    }
    Write-Host "vault bootstrap-link item created: $script:VaultBootstrapLinkItemName"
}

function Get-VaultBootstrapLink {
    # the link stored in the vault item, or $null when the item does not
    # exist yet. throws loudly when the session is dead or bw fails -
    # the caller reports that as its own failure, not as "no link".
    param(
        [Parameter(Mandatory = $true)]
        [string]$Bw,
        [string[]]$SessionArgs = @()
    )
    Assert-BwSessionLive -Bw $Bw -SessionArgs $SessionArgs
    $item = Find-VaultBootstrapLinkItem -Bw $Bw -SessionArgs $SessionArgs
    if (-not $item) { return $null }
    return ([string]$item.notes).Trim()
}

function Invoke-BootstrapPut {
    # PUT the bundle under one token. a 2xx is success; anything else
    # throws with the relay's own detail. when the relay echoes a url
    # back it must be the link just PUT - a different url means the
    # relay stored the bundle somewhere else, and the printed link
    # would be a lie.
    param(
        [Parameter(Mandatory = $true)]
        [string]$RelayBase,
        [Parameter(Mandatory = $true)]
        [string]$Token,
        [Parameter(Mandatory = $true)]
        [string]$BundleJson
    )
    $link = "$RelayBase/bootstrap/$Token"
    try {
        $response = Invoke-RestMethod -Uri $link -Method Put -Body $BundleJson -ContentType 'application/json' -TimeoutSec 15 -ErrorAction Stop
    } catch {
        throw "the relay refused the bootstrap bundle: $(Get-RestErrorDetail -ErrorRecord $_)"
    }
    if ($response -and $response.url -and ([string]$response.url) -ne $link) {
        throw 'the relay answered with a different bootstrap link than the one just stored - the relay is misbehaving. nothing local was changed.'
    }
}

function Invoke-BootstrapDelete {
    # DELETE one token's bundle. 204 (or any 2xx) is success; anything
    # else throws - the caller retries once, then gives up loudly.
    param(
        [Parameter(Mandatory = $true)]
        [string]$RelayBase,
        [Parameter(Mandatory = $true)]
        [string]$Token
    )
    try {
        $null = Invoke-RestMethod -Uri "$RelayBase/bootstrap/$Token" -Method Delete -TimeoutSec 15 -ErrorAction Stop
    } catch {
        throw "the relay refused to delete the old bootstrap bundle: $(Get-RestErrorDetail -ErrorRecord $_)"
    }
}

# --- argument validation ----------------------------------------------------
if ($DryRun -and $PushOnly) {
    throw 'pick one: -DryRun validates without creating anything, -PushOnly re-pushes the bundle under the existing link. never both.'
}

# --- config paths -----------------------------------------------------------
$pathsModule = Join-Path $PSScriptRoot 'mainframe-paths.psm1'
if (-not (Test-Path -LiteralPath $pathsModule -PathType Leaf)) {
    throw "mainframe-paths.psm1 not found next to this script ($pathsModule) - run it from the mainframe repo."
}
Import-Module $pathsModule -DisableNameChecking -ErrorAction Stop

$profileRoot = Get-MainframeProfileRoot
$configPath = Join-Path $profileRoot 'mainframe.config.json'
if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    throw "no local config at $configPath - nothing to bootstrap from. this machine has no mainframe config yet."
}
$rawConfig = Get-Content -LiteralPath $configPath -Raw -ErrorAction Stop
try {
    $config = $rawConfig | ConvertFrom-Json -ErrorAction Stop
} catch {
    throw "the local config at $configPath is not valid JSON: $($_.Exception.Message)"
}
if (-not $config.ntfyTopic -or -not (Test-NtfyTopicFormat -Value $config.ntfyTopic)) {
    throw 'the local config has no valid ntfyTopic (32 lowercase letters/digits) - refusing to bootstrap from a broken config.'
}
$relayBase = Get-BootstrapRelayBase -NtfyServer $config.ntfyServer
$fingerprint = $config.ntfyTopic.Substring(0, 4)
$oldToken = $config.bootstrapToken

if ($DryRun) {
    Write-Host "config valid (topic fingerprint $fingerprint). would PUT it to $relayBase/bootstrap/<new-token> - no link created."
    return
}

if ($PushOnly) {
    # re-push the current local config under the EXISTING token: the
    # local config's bootstrapToken first, else the vault item's link.
    # no new token, no vault write, no link printed.
    $token = $null
    if ($oldToken -and (Test-BootstrapTokenFormat -Value $oldToken)) {
        $token = $oldToken
    } else {
        $bw = Resolve-BwPath -Wanted $BwPath
        $sessionArgs = @(Get-BwSessionArgs -ProfileRoot $profileRoot)
        $vaultLink = Get-VaultBootstrapLink -Bw $bw -SessionArgs $sessionArgs
        if ($vaultLink) {
            # the vault link points at the relay it was created on. when
            # the local config has since moved to a different relay, the
            # PUT below lands on the new relay while the vault link still
            # serves the old relay's bundle - warn loudly, do not guess.
            if ($vaultLink -cmatch '^(https://[^/]+)/bootstrap/[A-Za-z0-9_-]{22}$') {
                if ($Matches[1] -ne $relayBase) {
                    Write-Host 'WARNING: the vault bootstrap link points at a different relay than the local config (ntfyServer changed since the link was created). the bundle is re-pushed to the current relay, but the vault link still serves the old relay. re-run this script plain (no -PushOnly) to create a fresh link for the current relay.'
                }
            }
            $token = Get-BootstrapTokenFromLink -Link $vaultLink
        }
        if (-not $token) {
            throw 'no bootstrap token found anywhere - the local config has no bootstrapToken and the vault holds no bootstrap link. the link was never created: run this script plain once (pwsh windows/new-bootstrap-link.ps1) to create it. nothing was changed.'
        }
    }
    try {
        Invoke-BootstrapPut -RelayBase $relayBase -Token $token -BundleJson $rawConfig
    } catch {
        throw "$($_.Exception.Message) nothing was changed locally - fix the relay problem and re-run with -PushOnly."
    }
    Write-Host "bootstrap bundle re-pushed under the existing permanent link (topic fingerprint $fingerprint). the link is unchanged - it now serves the current config."
    return
}

# --- plain run: create-or-rotate --------------------------------------------
$newToken = New-BootstrapToken
$newLink = "$relayBase/bootstrap/$newToken"

# vault FIRST: the link is stored before the relay or the local config is
# touched, so a failure here (dead session, bw error) leaves nothing
# half-created.
$bw = Resolve-BwPath -Wanted $BwPath
$sessionArgs = @(Get-BwSessionArgs -ProfileRoot $profileRoot)
Set-VaultBootstrapLink -Link $newLink -Bw $bw -SessionArgs $sessionArgs

# the bundle is the config WITH the new token, so a machine that
# bootstraps from the link holds a complete config (and can re-push the
# bundle itself after a rotation, without a vault read). the local
# config write below stores these exact bytes.
$config.bootstrapToken = $newToken
$bundleJson = $config | ConvertTo-Json -Depth 10
try {
    Invoke-BootstrapPut -RelayBase $relayBase -Token $newToken -BundleJson $bundleJson
} catch {
    throw "$($_.Exception.Message) the vault already holds the new link, but its bundle was never stored - re-run this script plain to generate a fresh link and retry. nothing local was changed."
}

# retire the old token's bundle, when the local config had one. a fresh
# token never equals the old one, but the guard is what stops a freak
# collision from deleting the bundle just PUT.
if ($oldToken -and (Test-BootstrapTokenFormat -Value $oldToken) -and $oldToken -ne $newToken) {
    $deleted = $false
    $deleteError = ''
    foreach ($attempt in 1..2) {
        try {
            Invoke-BootstrapDelete -RelayBase $relayBase -Token $oldToken
            $deleted = $true
            break
        } catch {
            $deleteError = $_.Exception.Message
            if ($attempt -eq 1) { Start-Sleep -Seconds 2 }
        }
    }
    if (-not $deleted) {
        # LOUD, and the old token/link is never printed: the warning
        # must be safe to paste anywhere. the orphaned bundle is
        # unguessable (128-bit token) and inert - it serves the previous
        # config to nobody who does not already hold the old link. the
        # local config still carries the old token, so a plain re-run
        # retries the cleanup with a fresh link.
        Write-Host 'WARNING: the old bootstrap bundle could not be deleted (tried twice - the relay refused, or the network dropped). the new link is live and the vault holds it, but the local config still carries the old token and was NOT updated.'
        Write-Host "relay error: $deleteError"
        Write-Host 'the orphaned bundle is unguessable (128-bit token) and inert - it can only be fetched by someone who already holds the old link.'
        Write-Host 'recovery: re-run this script plain (pwsh windows/new-bootstrap-link.ps1) - it generates a fresh link and retries the cleanup.'
        # throw, not exit 1: an exit inside a script invoked with & from
        # another script behaves like a return (measured 2026-11-15) and
        # would NOT fail the run. a throw fails the run everywhere - the
        # harness turns it into exit 1, and a direct run exits 1 too.
        throw 'old bootstrap bundle cleanup failed - the local config was NOT updated. re-run this script plain to retry the cleanup.'
    }
} elseif ($oldToken -and -not (Test-BootstrapTokenFormat -Value $oldToken)) {
    Write-Host 'WARNING: the local config carries a malformed bootstrapToken - ignoring it (there is no valid old bundle to delete).'
}

# local config LAST: the same bytes that were PUT, atomically, 0600.
Write-JsonAtomically -Path $configPath -JsonObject $config

Write-Host 'bootstrap link (permanent - serves the current config; treat it like the config itself):'
Write-Host $newLink
Write-Host "saved in the vault: $script:VaultBootstrapLinkItemName"
if ($oldToken -and (Test-BootstrapTokenFormat -Value $oldToken)) {
    Write-Host 'the previous link was retired (its bundle was deleted).'
}
