<#
.SYNOPSIS
    rotate the ntfy approval topic: the vault first, then this machine.

.DESCRIPTION
    generates a new 32-char [a-z0-9] topic from a cryptographic rng and
    writes it in two places, in this order:

      1. the vault item `github.com/FahadBinHussain/mainframe /
         mainframe.ntfy-topic` (a secure note, topic value in notes) -
         FIRST, and the rotation refuses loudly here if there is no live
         bw session. nothing local is touched when the vault write cannot
         happen.
      2. the local config: ntfyTopic in the profile config
         (~/.config/mainframe/mainframe.config.json on linux,
         %APPDATA%\mainframe\mainframe.config.json on windows), and the
         checkout-root mainframe.config.json too IF it carries a
         ntfyTopic.
      3. the bootstrap bundle: the updated profile config is PUT to the
         relay under the permanent bootstrap link's token (local config
         bootstrapToken first, else the token in the vault bootstrap-link
         item), so a new machine bootstrapping from the link gets the NEW
         topic. a failed push FAILS LOUDLY at the end (exit 1) with the
         exact recovery (windows/new-bootstrap-link.ps1 -PushOnly) - the
         rotation itself is NOT rolled back.

    the vault is the canonical topic now: every other machine converges
    to it on its next vault flow with a live session
    (Sync-VaultNtfyTopicFromVault in vault-approval.psm1), with no
    command sent to it at all. -Topic is the fallback for applying a
    value that was generated out-of-band (offline), not the procedure
    for moving machines any more.

    the topic is ONE value shared by every machine + the phone, so a
    rotation only works if all of them land on the SAME new value.
    RACE: rotate from ONE machine at a time. two simultaneous rotations
    both write the vault and the last one wins; a machine that rotated
    with the losing value converges to the winner on its next flow, but
    the phone may have been told the loser's value - so never rotate
    from two machines at once, and if it happens anyway, rotate once
    more from a single machine to settle on one value.

    the new topic is NEVER printed by default - it would land in logs
    and transcripts, which is how the old one leaked (the runner printed
    it on every approval until 2026-11-15). -ShowTopic prints this run's
    value (your terminal only); -ShowCurrent prints the topic already in
    the config without changing anything - the recovery path if you
    rotated without showing it. never re-run plain to "see" the value:
    that rotates AGAIN.

    writes are atomic (temp file + move) and the config keeps mode 0600
    on non-windows. a missing or unparseable profile config refuses
    loudly and writes nothing.

    see docs/ntfy-topic-rotation.md for the full rollout order
    (phone subscribes first, machines converge, phone drops the old
    topic last, then verify).
#>
param(
    [switch]$ShowTopic,
    [switch]$ShowCurrent,
    [string]$Topic,
    [string]$BwPath = 'bw'
)

$ErrorActionPreference = 'Stop'

$script:VaultNtfyTopicVaultItemName = 'github.com/FahadBinHussain/mainframe / mainframe.ntfy-topic'
$script:VaultBootstrapLinkItemName = 'github.com/FahadBinHussain/mainframe / mainframe.bootstrap-link'
$script:BwLastError = ''

function New-NtfyTopic {
    # 32 chars of [a-z0-9] from a cryptographic rng, rejection-sampled
    # (252 = 7 * 36) so there is no modulo bias.
    $alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789'
    $chars = New-Object char[] 32
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $i = 0
        while ($i -lt 32) {
            $buf = New-Object byte[] 32
            $rng.GetBytes($buf)
            foreach ($b in $buf) {
                if ($i -ge 32) { break }
                if ($b -lt 252) {
                    $chars[$i] = $alphabet[$b % 36]
                    $i++
                }
            }
        }
    } finally {
        $rng.Dispose()
    }
    return -join $chars
}

function Test-NtfyTopicFormat {
    param([string]$Value)
    # -cmatch, not -match: -match is case-insensitive, so it would accept
    # uppercase (and a topic with uppercase is a different topic than its
    # lowercase form on the relay - it must not pass validation).
    return ($Value -cmatch '^[a-z0-9]{32}$')
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
    # install locations. throws loudly when nothing is found - a rotation
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
    throw "bw CLI not found on PATH or at the known install locations - a rotation needs a live bw session to write the vault item first. install the bitwarden CLI and unlock the vault, then re-run this script. nothing was changed."
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
    # the topic itself is never in an argument list - it travels via
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

function Set-VaultNtfyTopic {
    # write the topic into the vault item FIRST - before any local config
    # is touched. throws loudly on any failure (no live session, bw
    # error, create/edit refused) so the caller never half-rotates.
    # idempotent: when the item already holds this value, nothing is
    # written - that is the crash-recovery path (a previous run wrote the
    # vault and died before the local config).
    param(
        [Parameter(Mandatory = $true)]
        [string]$Topic,
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
    $listOut = Invoke-Bw -Bw $Bw -Arguments (@('list', 'items', '--search', $script:VaultNtfyTopicVaultItemName) + $SessionArgs)
    if ($null -eq $listOut) {
        throw "bw list items failed - cannot find the vault topic item, refusing to rotate. ($script:BwLastError) nothing was changed."
    }
    $items = ConvertFrom-BwJsonArray -Json $listOut
    # --search is a substring match: only the exact item name is the topic.
    $item = @($items | Where-Object { [string]$_.name -eq $script:VaultNtfyTopicVaultItemName }) | Select-Object -First 1
    if ($item -and ([string]$item.notes).Trim() -eq $Topic) {
        Write-Host 'vault topic item already holds this value - nothing to write there (a previous run wrote the vault and stopped before the local config).'
        return
    }
    if ($item) {
        $itemJson = Invoke-Bw -Bw $Bw -Arguments (@('get', 'item', [string]$item.id) + $SessionArgs)
        if (-not $itemJson) {
            throw "bw get item failed for the vault topic item - refusing to rotate. ($script:BwLastError) nothing was changed."
        }
        try {
            $full = $itemJson | ConvertFrom-Json
        } catch {
            throw "bw get item returned unparseable json - refusing to rotate. nothing was changed."
        }
        $full.notes = $Topic
        $encoded = Invoke-Bw -Bw $Bw -Arguments @('encode') -Stdin ($full | ConvertTo-Json -Depth 10 -Compress)
        if (-not $encoded) {
            throw "bw encode failed for the updated vault topic item - refusing to rotate. ($script:BwLastError) nothing was changed."
        }
        $edited = Invoke-Bw -Bw $Bw -Arguments (@('edit', 'item', [string]$item.id) + $SessionArgs) -Stdin $encoded.Trim()
        if ($null -eq $edited) {
            throw "bw edit item failed for the vault topic item - refusing to rotate. ($script:BwLastError) nothing was changed."
        }
        Write-Host "vault topic item updated: $script:VaultNtfyTopicVaultItemName"
        return
    }
    # the item is built explicitly: the rust bw CLI's `get template
    # item.securenote` returns just {"type":0} — no name/notes fields
    # to fill in, and the wrong type for a SecureNote (2) — so the
    # template is worse than useless here (measured 2026-11-15: the
    # first real link creation died setting .name on it, and the
    # rotate script had the same latent call).
    $newItem = [pscustomobject]@{
        type = 2
        name = $script:VaultNtfyTopicVaultItemName
        notes = $Topic
        secureNote = [pscustomobject]@{ type = 0 }
    }
    $encoded = Invoke-Bw -Bw $Bw -Arguments @('encode') -Stdin ($newItem | ConvertTo-Json -Depth 10 -Compress)
    if (-not $encoded) {
        throw "bw encode failed for the new vault topic item - refusing to rotate. ($script:BwLastError) nothing was changed."
    }
    $created = Invoke-Bw -Bw $Bw -Arguments (@('create', 'item') + $SessionArgs) -Stdin $encoded.Trim()
    if ($null -eq $created) {
        throw "bw create item failed for the vault topic item - refusing to rotate. ($script:BwLastError) nothing was changed."
    }
    Write-Host "vault topic item created: $script:VaultNtfyTopicVaultItemName"
}

function Test-BootstrapTokenFormat {
    param([string]$Value)
    # -cmatch, not -match: the token alphabet is case-sensitive, and a
    # case-insensitive check would accept values the relay rejects.
    return ($Value -cmatch '^[A-Za-z0-9_-]{22}$')
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

function Get-BootstrapRelayBase {
    # the relay base is the ntfyServer with the trailing /ntfy mount
    # stripped - the bootstrap endpoint lives next to it. same guards as
    # new-bootstrap-link.ps1: the server must end in /ntfy and the base
    # must be https, or the config goes nowhere.
    param([string]$NtfyServer)
    if ([string]::IsNullOrWhiteSpace($NtfyServer)) {
        throw 'no ntfyServer in the local config - the bootstrap endpoint lives on the worker relay, not on ntfy.sh.'
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

function Get-VaultBootstrapLink {
    # the link stored in the vault bootstrap-link item, or $null when the
    # item does not exist yet. throws loudly when the session is dead or
    # bw fails - the caller reports that as its own failure, not as "no
    # link". the session was already proven live by the topic write, so
    # a failure here means the vault broke mid-run.
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
        throw 'no live bw session - the vault went away mid-run (the rotation already happened, vault + local are new). unlock the vault and re-push the bundle.'
    }
    $listOut = Invoke-Bw -Bw $Bw -Arguments (@('list', 'items', '--search', $script:VaultBootstrapLinkItemName) + $SessionArgs)
    if ($null -eq $listOut) {
        throw "bw list items failed - cannot find the vault bootstrap-link item. ($script:BwLastError)"
    }
    $items = ConvertFrom-BwJsonArray -Json $listOut
    # --search is a substring match: only the exact item name is the link.
    $item = @($items | Where-Object { [string]$_.name -eq $script:VaultBootstrapLinkItemName }) | Select-Object -First 1
    if (-not $item) { return $null }
    return ([string]$item.notes).Trim()
}

function Invoke-BootstrapBundlePush {
    # push the UPDATED profile config to the relay under the permanent
    # bootstrap link's token, so the link serves the new topic. never
    # throws: every failure comes back as a result object, because the
    # rotation already happened and the caller reports the failure at
    # the end (with the exact recovery) instead of rolling anything back.
    # the bundle is the profile config file re-read raw after the write -
    # the in-memory object is never trusted to be what landed on disk.
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProfileConfig,
        [Parameter(Mandatory = $true)]
        [string]$Bw,
        [string[]]$SessionArgs = @()
    )
    $fail = {
        param([string]$Message, [string]$Recovery)
        return [pscustomobject]@{ Success = $false; Message = $Message; Recovery = $Recovery }
    }
    try {
        $bundle = Get-Content -LiteralPath $ProfileConfig -Raw -ErrorAction Stop
        $cfg = $bundle | ConvertFrom-Json -ErrorAction Stop
    } catch {
        return (& $fail "could not re-read the updated profile config ($($_.Exception.Message))" 're-push with: pwsh windows/new-bootstrap-link.ps1 -PushOnly')
    }
    try {
        $relayBase = Get-BootstrapRelayBase -NtfyServer $cfg.ntfyServer
    } catch {
        return (& $fail "the relay base cannot be derived: $($_.Exception.Message)" 'fix ntfyServer in the local config (it must be the worker relay url ending in /ntfy), then re-push with: pwsh windows/new-bootstrap-link.ps1 -PushOnly')
    }
    $token = $null
    if ($cfg.bootstrapToken -and (Test-BootstrapTokenFormat -Value $cfg.bootstrapToken)) {
        $token = $cfg.bootstrapToken
    } else {
        try {
            $vaultLink = Get-VaultBootstrapLink -Bw $Bw -SessionArgs $SessionArgs
        } catch {
            return (& $fail "the vault bootstrap-link item could not be read: $($_.Exception.Message)" 'unlock the vault, then re-push with: pwsh windows/new-bootstrap-link.ps1 -PushOnly')
        }
        if ($vaultLink) {
            $token = Get-BootstrapTokenFromLink -Link $vaultLink
        }
        if (-not $token) {
            return (& $fail 'no bootstrap link was ever created - the local config has no bootstrapToken and the vault holds no bootstrap link' 'create the link once with: pwsh windows/new-bootstrap-link.ps1 (the rotation itself already happened - vault + local are new, the bundle is stale until the link exists)')
        }
    }
    try {
        $null = Invoke-RestMethod -Uri "$relayBase/bootstrap/$token" -Method Put -Body $bundle -ContentType 'application/json' -TimeoutSec 15 -ErrorAction Stop
    } catch {
        return (& $fail "the relay refused the bundle: $(Get-RestErrorDetail -ErrorRecord $_)" 're-push with: pwsh windows/new-bootstrap-link.ps1 -PushOnly')
    }
    return [pscustomobject]@{ Success = $true; Message = 'pushed'; Recovery = '' }
}

# --- argument validation ----------------------------------------------------
if ($ShowTopic -and $ShowCurrent) {
    throw 'pick one: -ShowTopic rotates AND shows the new value, -ShowCurrent only shows the value already in the config. never both.'
}
if ($ShowCurrent -and $Topic) {
    throw '-ShowCurrent changes nothing, so -Topic has nothing to apply to. drop -Topic, or drop -ShowCurrent to rotate.'
}
if ($Topic -and -not (Test-NtfyTopicFormat -Value $Topic)) {
    throw '-Topic must be exactly 32 chars of [a-z0-9] - got something else, refusing to write it.'
}

# --- config paths -----------------------------------------------------------
# profile root via the repo's own helper when importable, else os-detect.
# MAINFRAME_PROFILE_ROOT wins in both branches - it is the repo's own
# override, and it is also how this script is tested against a temp config.
$profileRoot = $null
$pathsModule = Join-Path $PSScriptRoot 'mainframe-paths.psm1'
if (Test-Path -LiteralPath $pathsModule) {
    try {
        Import-Module $pathsModule -DisableNameChecking -ErrorAction Stop
        $profileRoot = Get-MainframeProfileRoot
    } catch {
        $profileRoot = $null
    }
}
if (-not $profileRoot) {
    if ($env:MAINFRAME_PROFILE_ROOT) {
        $profileRoot = $env:MAINFRAME_PROFILE_ROOT
    } elseif ($env:OS -eq 'Windows_NT') {
        $profileRoot = Join-Path $env:APPDATA 'mainframe'
    } else {
        $xdg = if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path $HOME '.config' }
        $profileRoot = Join-Path $xdg 'mainframe'
    }
}
$profileConfig = Join-Path $profileRoot 'mainframe.config.json'
# checkout root is the parent of this script's folder.
$checkoutConfig = Join-Path (Split-Path -Parent $PSScriptRoot) 'mainframe.config.json'

# --- read the profile config (both modes need it) ---------------------------
if (-not (Test-Path -LiteralPath $profileConfig)) {
    throw "profile config not found: $profileConfig - refusing to rotate a machine that has no config. set the machine up first."
}
try {
    $profileJson = Get-Content -LiteralPath $profileConfig -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
} catch {
    throw "profile config is not parseable json: $profileConfig - refusing to write anything. fix the file by hand first. ($($_.Exception.Message))"
}
$currentTopic = $profileJson.ntfyTopic

if ($ShowCurrent) {
    # read-only mode: show what is there, change nothing.
    if (-not $currentTopic) {
        throw "profile config has no ntfyTopic: $profileConfig - nothing to show."
    }
    Write-Host 'WARNING: the topic below will land in logs/transcripts if this output is captured. copy it, then clear scrollback if you care.'
    Write-Host "current ntfy topic: $currentTopic"
    Write-Host 'nothing changed - this was a read-only show.'
    exit 0
}

if (-not $currentTopic) {
    throw "profile config has no ntfyTopic: $profileConfig - refusing to invent one here. set the topic first, then rotate."
}

# --- determine the new topic ------------------------------------------------
if ($Topic) {
    $newTopic = $Topic
    if ($newTopic -eq $currentTopic) {
        throw '-Topic is the same value this machine already has - that is not a rotation. generate a fresh one (plain run) or pass a different value.'
    }
} else {
    do {
        $newTopic = New-NtfyTopic
    } while ($newTopic -eq $currentTopic)
}

# --- read the checkout config, if it exists ---------------------------------
# read BEFORE writing anything: an unparseable checkout config refuses
# loudly here, while nothing has been touched yet.
$checkoutJson = $null
$checkoutHasTopic = $false
if (Test-Path -LiteralPath $checkoutConfig) {
    try {
        $checkoutJson = Get-Content -LiteralPath $checkoutConfig -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "checkout config is not parseable json: $checkoutConfig - refusing to rotate with a half-readable fleet config. fix the file by hand first. ($($_.Exception.Message))"
    }
    $checkoutHasTopic = [bool]$checkoutJson.ntfyTopic
}

# --- write the vault item FIRST ---------------------------------------------
# the vault is the canonical topic: every other machine converges to it on
# its next vault flow. a failure here throws loudly and NO local config is
# touched - a half-rotated fleet (local new, vault old) would converge
# this machine straight back to the old topic on its next flow.
$bw = Resolve-BwPath -Wanted $BwPath
$sessionArgs = @(Get-BwSessionArgs -ProfileRoot $profileRoot)
Set-VaultNtfyTopic -Topic $newTopic -Bw $bw -SessionArgs $sessionArgs

# --- write: profile first, then checkout ------------------------------------
$profileJson.ntfyTopic = $newTopic
Write-JsonAtomically -Path $profileConfig -JsonObject $profileJson
Write-Host "rotated: ntfyTopic in $profileConfig"
if ($checkoutJson) {
    if ($checkoutHasTopic) {
        $checkoutJson.ntfyTopic = $newTopic
        try {
            Write-JsonAtomically -Path $checkoutConfig -JsonObject $checkoutJson
            Write-Host "rotated: ntfyTopic in $checkoutConfig (checkout config carried a topic too)"
        } catch {
            throw "profile config was updated but the checkout config write failed: $checkoutConfig - the machine is half-rotated (checkout still has the OLD topic, and the checkout wins on reads). fix the file and re-run this script with -Topic to finish. ($($_.Exception.Message))"
        }
    } else {
        Write-Host "WARNING: checkout config exists but carries no ntfyTopic, left alone: $checkoutConfig"
    }
}

# --- push the bundle: the permanent link must serve the NEW topic --------
# the rotation is done (vault + local are new). the push never throws: a
# failure comes back as a result, is reported in the next steps below,
# and fails the run LOUDLY at the very end with the exact recovery. the
# rotation is never rolled back because the push failed.
$pushResult = Invoke-BootstrapBundlePush -ProfileConfig $profileConfig -Bw $bw -SessionArgs $sessionArgs
$newFingerprint = $newTopic.Substring(0, 4)

# --- next steps (the topic itself is never printed here by default) ---------
Write-Host ''
if ($ShowTopic) {
    Write-Host 'WARNING: the new topic is printed below because you asked with -ShowTopic. it will land in logs/transcripts if this output is captured - copy it, then clear scrollback if you care.'
    Write-Host "new ntfy topic: $newTopic"
    Write-Host ''
    Write-Host 'next steps (the vault holds the new topic; machines converge on their own):'
    Write-Host '  1. phone FIRST: ntfy app -> subscribe to the new topic, KEEP the old one for now.'
    Write-Host '     (the topic must be typed into the phone by hand - there is no automation for that step.)'
    Write-Host '  2. every other machine converges automatically at its next vault flow - no commands to send.'
    Write-Host '     (each machine logs "ntfy topic converged from the vault" when it switches.)'
    Write-Host '  3. once every machine has converged, drop the old phone subscription.'
    Write-Host '  4. verify: trigger one approval and confirm the phone shows it.'
} else {
    Write-Host 'the new topic is NOT printed here (it would land in logs/transcripts).'
    Write-Host 'next steps (the vault holds the new topic; machines converge on their own):'
    Write-Host '  1. on THIS machine, show the new topic (your terminal only):'
    Write-Host '     pwsh windows/rotate-ntfy-topic.ps1 -ShowCurrent'
    Write-Host '     (warning: the value will land in logs/transcripts - copy it, then clear scrollback if you care.)'
    Write-Host '     never re-run this script plain to "see" the value - that rotates AGAIN.'
    Write-Host '  2. phone FIRST: ntfy app -> subscribe to the new topic, KEEP the old one for now.'
    Write-Host '     (the topic must be typed into the phone by hand - there is no automation for that step.)'
    Write-Host '  3. every other machine converges automatically at its next vault flow - no commands to send.'
    Write-Host '     (each machine logs "ntfy topic converged from the vault" when it switches.)'
    Write-Host '  4. once every machine has converged, drop the old phone subscription.'
    Write-Host '  5. verify: trigger one approval and confirm the phone shows it.'
}
Write-Host 'honest limit: the OLD topic stays usable - there is no relay-side deny list. rotation limits future exposure, it does not revoke the old topic.'
Write-Host ''
if ($pushResult.Success) {
    Write-Host "bootstrap bundle: pushed - the permanent link now serves the new topic (fingerprint $newFingerprint). a new machine bootstrapping from the link gets the new topic."
} else {
    Write-Host "bootstrap bundle: NOT pushed - $($pushResult.Message)"
    Write-Host 'the rotation itself already happened (vault + local are new) and is NOT rolled back - only the bundle is stale.'
}
if (-not $pushResult.Success) {
    Write-Host ''
    Write-Host 'BOOTSTRAP BUNDLE PUSH FAILED - the permanent link still serves the OLD topic. a new machine bootstrapping from it now would land on the old topic.'
    Write-Host "recovery: $($pushResult.Recovery)"
    # throw, not exit 1: an exit inside a script invoked with & from
    # another script behaves like a return (measured 2026-11-15) and
    # would NOT fail the run. a throw fails the run everywhere.
    throw "bootstrap bundle push failed: $($pushResult.Message) recovery: $($pushResult.Recovery)"
}
