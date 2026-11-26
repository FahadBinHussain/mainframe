<#
.SYNOPSIS
    mainframe: the ONE script. every mainframe operation lives here.

.DESCRIPTION
    god-script rule (user order 2026-11-22): no more tiny scattered
    scripts. vault was the first group merged in (2026-11-22) - the vault
    flow, lock, expiry, email sealer, bootstrap link, and ntfy topic
    rotation, plus the modules they used, all live in this one file now.
    backup, restore, and the rest join as subcommands later.

    merged in (deleted as separate files):
      vault-flow.ps1, vault-lock.ps1, expire-vault-session.ps1,
      seal-bw-email.ps1, new-bootstrap-link.ps1, rotate-ntfy-topic.ps1,
      vault-secret.psm1, vault-approval.psm1, vault-ntfy-server.psm1,
      mainframe-paths.psm1, mainframe-json.psm1, mainframe-sync.psm1

    the vault expiry is ENFORCED (user order 2026-11-22): every unlock
    registers the one-shot expiry job (schtasks / systemd / sleeper) -
    the session ALWAYS expires at its TTL mark. default TTL is 12 hours
    (720 minutes); change it with vaultTtlMinutes in mainframe.config.json
    or the MAINFRAME_VAULT_TTL_MINUTES env var.

    dot-sourcing this file loads every function without running anything,
    so the tests import it that way instead of the old modules.

.EXAMPLE
    pwsh -NoProfile -File mainframe.ps1 vault unlock -Json
.EXAMPLE
    pwsh -NoProfile -File mainframe.ps1 vault status
#>
param(
    [Parameter(Position = 0)][string]$Group,
    [Parameter(Position = 1)][string]$Action,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest
)

$ErrorActionPreference = 'Stop'
# stdout belongs to result documents. the vault code narrates with
# Write-Host, which lands in the information stream - silencing it keeps
# stdout a clean JSON document on both windows powershell 5.1 and pwsh 7.
$InformationPreference = 'SilentlyContinue'


# ======================================================================
# mainframe-json.psm1 - top level (header + script-scope state; imports removed)
# ======================================================================

<#
.SYNOPSIS
    json that behaves the same on windows powershell 5.1 and on pwsh 7.

.DESCRIPTION
    ConvertFrom-Json disagrees between the two runtimes: windows powershell
    5.1 hands a json ARRAY over as ONE object, pwsh 7 enumerates it.

        $x = '[{"a":1},{"a":2}]' | ConvertFrom-Json
        # 5.1: $x is System.Object[] of length 2, but the PIPELINE emitted it
        #      as a single item
        # 7.x: the pipeline emitted two items

    so `@($json | ConvertFrom-Json)` is an array CONTAINING an array on 5.1,
    and a flat list on 7.x. every consumer then walks a nested array:
    $item.name returns the names of ALL items at once, and a lookup can
    quietly return the wrong one.

    ConvertFrom-JsonArray always returns a flat list, on both runtimes.

    dependency-free, runs on windows powershell 5.1 and pwsh 7.
#>


# ======================================================================
# mainframe-paths.psm1 - top level (header + script-scope state; imports removed)
# ======================================================================

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


# ======================================================================
# vault-ntfy-server.psm1 - top level (header + script-scope state; imports removed)
# ======================================================================

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

$script:VaultNtfyServerVaultItemName = 'github.com/FahadBinHussain/mainframe / mainframe.ntfy-server'


# ======================================================================
# vault-approval.psm1 - top level (header + script-scope state; imports removed)
# ======================================================================

<#
.SYNOPSIS
    Cross-platform 1-tap mobile biometric approval for Bitwarden vault restore.
.DESCRIPTION
    Generates an ephemeral RSA-2048 keypair, dispatches an urgent push notification
    to ntfy, pops up a full-screen approval prompt via ADB if a phone is attached,
    and listens on the single-use relay topic for client-side encrypted master password.
#>

# the profile root is resolved by one shared script, so windows and linux read
# the same place (see Get-MainframeProfileRoot below).


# topic-only auth: there is no ntfy credential in the design any more.
# the topic name in mainframe.config.json is the only credential - a
# request that knows it may publish and read, no header or token is ever
# sent. (an earlier design carried an ntfy access token / basic auth in
# the config and a relay credential on the worker; both were removed
# 2026-11-15 because every new machine needed a manual handover step.)


# The approval descriptor: the exact set of facts the phone is asked to trust.
#
# The link fragment carries the RSA public key (k), the single-use topic (sid),
# the verification code, the expiry and where the answer may be posted - plus
# a signature (sig) over k/sid/code/exp/srv, made with ONE shared EC P-256 key
# for the whole ecosystem (approval-signing.key in the profile root, public
# half pinned in the page). The page verifies the signature before it offers
# the approve button: a link nobody signed warns loudly, and a link signed
# with the wrong key is refused outright. A missing key means an UNSIGNED
# link, which the page warns about but still allows - that only happens on
# existing machines during the transition (a new device gets key+topic
# together in the pack, so its first approval is already signed). The key
# self-heals from the vault whenever a live session exists (see
# Sync-VaultApprovalSigningKeyFromVault), so after the first unlock every
# approval is signed and the approval itself never fails for a missing key.
# (An earlier per-machine registration design was removed 2026-11-15 because
# every new machine needed a manual registration step; the shared key
# replaces it - see docs/approval-signing-bootstrap.md.)

# the query on the approval page URL. it busts the browser cache, so a phone
# that still has an OLD page cached fetches the new one instead of using it.
# bump it whenever the page changes in a way that matters for an already
# opened link.
$script:VaultApprovalPageVersion = 'topic1'


# --- link signing (C1): ONE shared EC P-256 key for the whole ecosystem -----
#
# This is deliberately NOT the per-machine registration design that was
# removed 2026-11-15 (it needed a manual registration step per machine, and
# the user rejected it): one key pair, private half in the profile root as
# approval-signing.key (SEC1 PEM, EC P-256, 0600), public half pinned in the
# approval page. The runner signs k/sid/code/exp/srv and the page verifies
# against the pinned key, so a link from anyone else fails closed.
#
# A new device needs ZERO setup: the key travels WITH the topic in the
# migration pack, so a device that can send an approval at all already has
# the key and its FIRST approval is signed. (A device without the topic
# cannot approve - the runner fails loudly with "no ntfy topic configured"
# - so there is no "new device, no key" case.) The unsigned link only
# occurs on EXISTING machines during the transition, when their vault
# session is dead at the moment of the first approval after the warn-mode
# page deploys: unsigned approval (page warns, allows) -> fingerprint ->
# unlock -> the runner fetches the key with the session the unlock just
# created -> all later approvals signed.
#
# Three heal points, one rule - the fetch runs ONLY when a live session
# already exists, never prompts, never blocks, never attempts against a
# locked vault:
#   1. flow-start-when-live (vault unlock, cached session): the session
#      is already live and no approval is needed at all - heal the key now.
#   2. request-time-if-live (Get-VaultApprovalLinkSigningKey): the approval
#      is being built and a live session happens to exist - heal, then sign.
#   3. after-unlock (vault unlock + Ensure-VaultSession): the unlock just
#      proved a live session - heal, so the NEXT approval is signed.
# Signing never fails or delays an approval: any failure here degrades to
# an unsigned link.
#
# Scheme (interop-proven: pwsh ECDsa signs, Node WebCrypto verifies):
# ECDSA P-256 + SHA-256, signature = 64-byte raw R||S (P1363, which is what
# .NET ECDsa.SignData returns by default), base64url, no padding, carried as
# the fragment param `sig`. Payload, byte-exact on both sides:
# k LF sid LF code LF exp LF srv (UTF-8), where exp/srv are the exact strings
# placed in the URL ('' when the param is absent).
#
# This is a DIFFERENT key from the old RSA machine key above
# (mainframe.approval-signing.key + Get-VaultApprovalSigningKey): that one is
# dead code the user has not decided to remove, and nothing here touches it.
$script:VaultApprovalLinkSigningKeyFileName = 'approval-signing.key'
$script:VaultApprovalLinkSigningVaultItemName = 'github.com/FahadBinHussain/mainframe / approval-signing.key'


# --- vault-held ntfy topic (self-maintaining convergence) ------------------
# the topic is the ONLY credential for the approval channel, and until
# 2026-11-15 it lived only in each machine's local config - so a rotation
# meant touching every machine by hand (and a human relaying commands to
# machines with no direct access). now the vault holds the canonical
# topic, and every machine converges to it on its next vault flow with a
# live session. the local config is still the bootstrap (a locked vault
# cannot be read before the first unlock), and the fallback when the
# session is dead or the item does not exist yet. the item is a secure
# note named like the signing-key item, topic value in notes:
# github.com/FahadBinHussain/mainframe / mainframe.ntfy-topic
$script:VaultNtfyTopicVaultItemName = 'github.com/FahadBinHussain/mainframe / mainframe.ntfy-topic'


# --- single flight: one phone prompt at a time -------------------------------
#
# Every requester used to mint its own keypair + topic and push its own
# notification. Two agents that start together therefore produced two prompts
# on the phone, and both of them polled the relay every 2 seconds - which is
# exactly how the ntfy rate limit gets tripped, and a tripped limit also eats
# the push (see AGENTS.md). The phone must not be asked twice for one unlock.
#
# So the request that gets the phone is serialised through one small file next
# to session.key:
#
#   <profile root>/accounts/bitwarden/approval.lock
#
# - the first requester creates it (atomic create, never a truncate) and asks
#   the phone. it owns the turn until it either gets the password, times out,
#   or crashes.
# - everybody else reads it and WAITS. a waiter never pushes, never opens the
#   phone, and never polls the relay - it only watches session.key and the lock
#   file, so a queue of agents costs the relay nothing.
# - the turn has a deadline written into the file (its own wait window plus a
#   margin), so a crashed holder cannot wedge the queue: once it lapses, one
#   waiter takes over and asks the phone. that is the "wait until the request
#   is stale, then send the next one" rule.
# - a waiter returns __SESSION_ALREADY_UNLOCKED__ the moment any session is
#   unlocked while it waits, so a queue drains without a second tap.
#
# The lock always records who holds it (pid, host, agent, model, code), so a
# queue reads as "waiting on code [42] by opencode @ LAPTOP-MAIN", not silence.
$script:VaultApprovalLockMarginSeconds = 15   # how long past its own wait a request keeps the turn
$script:VaultApprovalLockGraceSeconds = 5     # how long past the deadline before a waiter takes over
$script:VaultApprovalLockSettleSeconds = 20   # keep the turn while the caller writes session.key


# ======================================================================
# vault-secret.psm1 - top level (header + script-scope state; imports removed)
# ======================================================================

# vault-secret.ps1 - shared Bitwarden vault read/write for mainframe account helpers
#
# Vault-native secrets: each helper stores per-profile secrets in the Bitwarden
# vault as a LOGIN item named by the bare platform domain (e.g. "console.neon.tech";
# github alone uses "github.com - <handle>"). Two accounts on one domain are told
# apart by login.username/URI, never by a name suffix (the old "[2]" and " - <user>"
# suffixes were removed 2026-10). The secret value sits in the item's notes under
# a platform-specific header (e.g. "[api keys]`n<value>"). This module finds the
# item by the profile email and extracts/updates the value. No secrets are stored
# in the mainframe profile dir.
#
# Session: read from %APPDATA%\mainframe\accounts\bitwarden\session.key (written
# by automata-private\bitwarden.com\unlock.ps1 or 1-tap mobile approval) or $env:BW_SESSION.
# Sessions expire after 12 hours by default (configurable via MAINFRAME_VAULT_TTL_MINUTES or
# mainframe.config.json vaultTtlMinutes); the phone approval page's 12-hour
# checkbox now matches the default (720 minutes, the max - clamped here).
# Expiry is TIME-based, not use-based: every unlock registers a one-shot
# scheduled expiry (schtasks on Windows, a systemd transient timer on Linux,
# a detached sleeper as fallback) that runs the full Expire-VaultSession
# (bw lock + purge + verify) at the TTL mark with no vault use needed.
# The lazy check in Get-VaultSession (file age vs TTL) remains the backstop
# for the restart window - a reboot between unlock and TTL kills the
# scheduled job, so the session file is still on disk until the next vault
# use expires it. Re-unlock replaces the pending job (fixed name,
# unregister-first), and a manual lock/expire cancels it. An env-only
# session ($env:BW_SESSION with no session file) is only trusted when
# MAINFRAME_VAULT_SESSION_STARTED_UNIX proves its age - an unmarked env
# session is refused, because the file (the age authority) is gone.
#
# Performance: Get-VaultItems caches bw list items per session so the vault is
# queried at most once per process. Write operations (Update-VaultItemNotes,
# New-VaultItem, Write-VaultSecretToExisting) invalidate the cache so subsequent
# reads see the new item. Call Clear-VaultItemsCache to force a re-read.

$script:VaultItemsCache = $null
$script:VaultItemsCacheSession = $null
$script:VaultSessionOkSession = $null
$script:DefaultSessionTtlMinutes = 720  # 12 hours (user order 2026-11-22); vaultTtlMinutes / MAINFRAME_VAULT_TTL_MINUTES overrides

# the profile root is resolved by one shared script, so windows and linux read
# the same place (see Get-MainframeProfileRoot below).


# --- scheduled expiry -------------------------------------------------------
# expiry is TIME-based: every unlock registers a one-shot job that runs the
# full Expire-VaultSession at the TTL mark with no vault use needed. the
# lazy check in Get-VaultSession stays as the backstop for the restart
# window (a reboot between unlock and TTL kills the scheduled job - the
# systemd timer is transient, the sleeper is a process, and a schtasks
# one-shot task survives a reboot but the wrapper's age/hash guards still
# apply - so the session file is still on disk until the next vault use
# expires it). mechanisms, in preference order:
#   windows: schtasks one-shot (fixed name MainframeVaultExpiry) -> sleeper
#   linux:   systemd-run transient timer (fixed unit mainframe-vault-expiry)
#            -> sleeper
# the sleeper is a detached pwsh process running the wrapper with
# -DelaySeconds; it dies on reboot, which is why it is only the fallback.
# registration is replace-on-register (fixed name, unregister-first), so a
# re-unlock can never leave a stale job that fires early and kills the
# fresh session. the wrapper (mainframe.ps1 vault expire) double-checks age
# + key hash before expiring, and every path unregisters the job when it
# is done, so no orphaned task/timer/sleeper is left behind.


# Upsert the secret into an existing item's notes: replace the value under the
# given header while preserving the rest of the notes (recovery codes, etc.).
# Creates the item if it does not exist yet (ItemName/Username required then).


# ======================================================================
# mainframe-sync.psm1 - top level (header + script-scope state; imports removed)
# ======================================================================

<#
.SYNOPSIS
    self-healing checkout sync: keep the running mainframe checkout on
    its upstream tip, without ever asking a human to pull, reset, or
    relay a command to another machine.

.DESCRIPTION
    Sync-MainframeCheckout is called at the start of vault unlock
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


# ======================================================================
# functions from mainframe-json.psm1
# ======================================================================

function ConvertFrom-JsonArray {
    <#
    .SYNOPSIS
        parse a json document into a flat list of items.

    .PARAMETER Json
        the document. a json array gives one entry per element; a json object
        gives a single entry.
    #>
    param([AllowNull()][AllowEmptyString()][string]$Json)

    if ([string]::IsNullOrWhiteSpace($Json)) { return @() }
    $parsed = ConvertFrom-Json -InputObject $Json
    if ($null -eq $parsed) { return @() }
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($entry in $parsed) { $list.Add($entry) }
    return $list.ToArray()
}


# ======================================================================
# functions from mainframe-paths.psm1
# ======================================================================

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
        used by the helpers in other repos to find mainframe.ps1.
        $env:MAINFRAME_HOME wins; otherwise the well known clone
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
        if ((Test-Path -LiteralPath (Join-Path $candidate 'windows/mainframe.ps1')) -or
            (Test-Path -LiteralPath (Join-Path $candidate 'windows/vault-secret.psm1')) -or
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
        stdout belongs to the machine: mainframe.ps1 vault unlock prints its result
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


# ======================================================================
# functions from vault-ntfy-server.psm1
# ======================================================================

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


# ======================================================================
# functions from vault-approval.psm1
# ======================================================================

function Get-MiniMaxSessionId {
    # The MiniMax Code desktop app gives each session an id that shows up in
    # two places: an env var when the runtime sets one, and the session
    # workspace path the agent runs in. The v2 session tree on disk is keyed
    # by that id, which is how the active model can be read back ground-truth.
    foreach ($name in @('MINIMAX_SESSION_ID', 'MAVIS_SESSION_ID', 'MINIMAX_CODE_SESSION_ID', 'MINIMAX_CONVERSATION_ID')) {
        $v = [Environment]::GetEnvironmentVariable($name)
        if ($v) { return $v.Trim() }
    }
    try {
        $cwd = (Get-Location).Path
        if ($cwd -match 'sessions[\\/](mvs_[A-Za-z0-9]+)') { return $matches[1] }
    } catch {}
    return $null
}

function Get-MiniMaxModelFromDisk {
    param([string]$SessionId = $null)

    # Ground truth: MiniMax Code writes the request payload of every LLM call
    # to <data>/v2/sessions/<yyyy>/<mm>/<dd>/<hh-mm-ss-mmm>-session_<b64url-id>/llm-call.json
    # and that file carries the model the call actually used.
    $root = Join-Path $HOME '.minimax\v2\sessions'
    if (-not (Test-Path -LiteralPath $root)) { return $null }

    $files = @()
    if ($SessionId) {
        $enc = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($SessionId)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
        $files = @(Get-ChildItem -LiteralPath $root -Recurse -Filter 'llm-call.json' -ErrorAction SilentlyContinue |
                Where-Object { $_.Directory.Name -like "*_${enc}" })
        # an explicitly asked-for session is authoritative: if it has no
        # llm-call.json then the model is simply unknown. falling back to
        # another session here would put the wrong model on the phone card.
        if ($files.Count -eq 0) { return $null }
    } else {
        # No session id to scope with: fall back to the session that wrote an
        # llm-call.json most recently. The window is short on purpose - a
        # finished session must not keep claiming the tag after the agent
        # moved on.
        $cutoff = (Get-Date).AddMinutes(-15)
        $files = @(Get-ChildItem -LiteralPath $root -Recurse -Filter 'llm-call.json' -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -ge $cutoff })
    }
    if ($files.Count -eq 0) { return $null }

    $f = $files | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    try {
        $j = Get-Content -LiteralPath $f.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($j.model) { return ([string]$j.model).Trim() }
    } catch {}
    return $null
}

function Get-CallerIdentity {
    param(
        [string]$Agent,
        [string]$Model,
        [string]$PromptContext = $null
    )

    # 1. Explicit or context-inferred browser requests from web UI
    if (-not $Agent -and $PromptContext -and ($PromptContext -match 'monitor' -or $PromptContext -match 'browser')) {
        return [PSCustomObject]@{
            Agent = 'browser'
            Model = $null
        }
    }

    # 2. An explicit operator override wins over everything else.
    if (-not $Agent) {
        $Agent = $env:MAINFRAME_AGENT_NAME
    }
    if (-not $Model) {
        $Model = $env:MAINFRAME_MODEL_NAME
        if (-not $Model) { $Model = $env:MODEL_NAME }
        if (-not $Model) { $Model = $env:AI_MODEL }
    }

    # 3. Process ancestry BEFORE the generic environment variables.
    #    Two things make the env vars untrustworthy on their own:
    #      - a harness env var leaks DOWN into long-lived services (the
    #        monitor api inherits the agent that started it), and
    #      - a compatibility flag can lie: MiniMax Code sets
    #        OPENCODE_DISABLE_CHANNEL_DB for opencode compatibility, and the
    #        flag is set machine-wide on this laptop - so the env branch
    #        must never treat the bare flag as an identity (2026-11-26).
    #    The process tree cannot be inherited wrongly, so it decides first.
    if (-not $Agent) {
        $p = $null
        try { $p = (Get-Process -Id $PID -ErrorAction SilentlyContinue).Parent } catch { $p = $null }
        while ($p) {
            $name = ''
            try { $name = $p.ProcessName.ToLower() } catch { $name = '' }
            # If running under node.exe serving the monitor, it's the browser
            if ($name -match 'node') {
                $cmd = ''
                try { $cmd = (Get-CimInstance Win32_Process -Filter "ProcessId = $($p.Id)" -ErrorAction SilentlyContinue).CommandLine } catch { $cmd = '' }
                if ($cmd -match 'monitor' -or $cmd -match 'server\.ts') {
                    $Agent = 'browser'
                    break
                }
            }
            if ($name -match 'minimax|mcode') { $Agent = 'minimax-code'; break }
            if ($name -match 'qoder') { $Agent = 'qoder'; break }
            if ($name -match 'claude') { $Agent = 'claude-code'; break }
            if ($name -match 'opencode') { $Agent = 'opencode'; break }
            if ($name -match 'cursor') { $Agent = 'cursor'; break }
            if ($name -match 'windsurf') { $Agent = 'windsurf'; break }
            if ($name -match 'codex') { $Agent = 'codex'; break }
            if ($name -match 'antigravity') { $Agent = 'antigravity'; break }
            try { $p = $p.Parent } catch { $p = $null }
        }
    }

    # 4. The named agent env vars, now only as a fallback.
    if (-not $Agent) {
        $Agent = $env:AGENT_NAME
        if (-not $Agent) { $Agent = $env:AI_AGENT }
        if (-not $Agent) { $Agent = $env:HARNESS_NAME }
    }

    # 5. Environment variables, last resort.
    if (-not $Agent) {
        if ($env:QODER_CLI -or $env:QODER_PRODUCT_ID -or $env:QODER_SESSION_TYPE) {
            # qoder sets OPENCODE_DISABLE_CHANNEL_DB for compatibility, so it
            # must be tested before the opencode branch or it reads as opencode
            $Agent = 'qoder'
        } elseif ($env:OPENCODE -or $env:OPENCODE_SESSION) {
            $Agent = 'opencode'
        } elseif ($env:CLAUDE_CODE -or $env:CLAUDE_PROJECT_DIR) {
            $Agent = 'claude-code'
        } elseif ($env:CODEX -or $env:CODEX_MODEL) {
            $Agent = 'codex'
        } elseif ($env:AIDER_MODEL) {
            $Agent = 'aider'
        } elseif ($env:ANTIGRAVITY_AGENT -or $env:ANTIGRAVITY_CONVERSATION_ID) {
            $Agent = 'antigravity'
        } else {
            # the OPENCODE_DISABLE_CHANNEL_DB compat flag is deliberately NOT
            # an identity signal: it is set machine-wide on this laptop, so
            # every agent's unlock read as 'opencode' when nothing else
            # identified the caller (2026-11-26). a bare flag means unknown.
            $Agent = 'terminal'
        }
    }

    # Human / browser / terminal callers do not have an LLM model
    if ($Agent -eq 'browser' -or $Agent -eq 'terminal') {
        return [PSCustomObject]@{
            Agent = $Agent
            Model = $null
        }
    }

    # Resolve Model via Ground-Truth Thread Inspection or Environment
    if (-not $Model) {
        $Model = $env:MAINFRAME_MODEL_NAME
        if (-not $Model) { $Model = $env:MODEL_NAME }
        if (-not $Model) { $Model = $env:AI_MODEL }
    }

    if (-not $Model) {
        if ($Agent -eq 'antigravity' -and $env:ANTIGRAVITY_CONVERSATION_ID) {
            # Ground-truth: inspect Antigravity conversation transcript on disk
            $appData = if ($env:ANTIGRAVITY_APP_DATA_DIR) { $env:ANTIGRAVITY_APP_DATA_DIR } else { (Join-Path $HOME '.gemini\antigravity') }
            $transcript = Join-Path $appData "brain\$($env:ANTIGRAVITY_CONVERSATION_ID)\.system_generated\logs\transcript.jsonl"
            if (Test-Path -LiteralPath $transcript) {
                # Check recent lines first for any mid-thread model switches
                $recent = Get-Content -LiteralPath $transcript -Tail 100 -ErrorAction SilentlyContinue
                if ($recent) {
                    $matches = @($recent | Select-String -Pattern "Model Selection.*?from\s+.*?\s+to\s+(.+?)\.\s+No need")
                    if ($matches.Count -gt 0) {
                        $Model = $matches[-1].Matches[0].Groups[1].Value.Trim()
                    }
                }
                # Check initial lines (Step 0) if no recent change
                if (-not $Model) {
                    $head = Get-Content -LiteralPath $transcript -TotalCount 50 -ErrorAction SilentlyContinue
                    if ($head) {
                        $matches = @($head | Select-String -Pattern "Model Selection.*?from\s+.*?\s+to\s+(.+?)\.\s+No need")
                        if ($matches.Count -gt 0) {
                            $Model = $matches[-1].Matches[0].Groups[1].Value.Trim()
                        }
                    }
                }
            }
            if (-not $Model -and $env:ANTIGRAVITY_MODEL) {
                $Model = $env:ANTIGRAVITY_MODEL
            }
        } elseif ($Agent -eq 'opencode') {
            if ($env:OPENCODE_MODEL) { $Model = $env:OPENCODE_MODEL }
        } elseif ($Agent -eq 'minimax-code') {
            # MiniMax Code exposes no model env var, so the ground truth is
            # the session tree on disk: every LLM call writes llm-call.json
            # into the session's folder, and the folder name carries the
            # session id (base64url). Reading the model back from the file
            # that the call itself wrote beats guessing.
            if ($env:MINIMAX_MODEL) { $Model = $env:MINIMAX_MODEL }
            elseif ($env:MINIMAX_MODEL_NAME) { $Model = $env:MINIMAX_MODEL_NAME }
            elseif ($env:MAVIS_MODEL) { $Model = $env:MAVIS_MODEL }
            if (-not $Model) {
                $Model = Get-MiniMaxModelFromDisk -SessionId (Get-MiniMaxSessionId)
            }
        } elseif ($Agent -eq 'claude-code') {
            if ($env:ANTHROPIC_MODEL) { $Model = $env:ANTHROPIC_MODEL }
        } elseif ($Agent -eq 'codex') {
            if ($env:CODEX_MODEL) { $Model = $env:CODEX_MODEL }
        } elseif ($Agent -eq 'aider') {
            if ($env:AIDER_MODEL) { $Model = $env:AIDER_MODEL }
        }
    }

    return [PSCustomObject]@{
        Agent = $Agent
        Model = $Model
    }
}

function Get-VaultConfigValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Key
    )

    # one config file drives both machines: linux_real.py reads the same keys,
    # so a windows box and a linux box can be pointed at the same relay and
    # the same approval page without touching code. the lookup itself lives
    # in mainframe-paths.psm1 - a literal '.config\mainframe' never matches
    # on linux, so the profile root has to be resolved the portable way.
    return Get-MainframeConfigValue -Key $Key
}

function Get-VaultNtfyTopic {
    param(
        [string]$Topic = $null
    )

    # the approval channel is only private when the topic name is unguessable,
    # so there is deliberately no built-in default: an unconfigured machine
    # fails here instead of broadcasting requests on a public topic.
    if (-not $Topic) { $Topic = $env:MAINFRAME_NTFY_TOPIC }
    if (-not $Topic) {
        $Topic = Get-VaultConfigValue -Key 'ntfyTopic'
    }
    if (-not $Topic) {
        throw "no ntfy topic configured: set `$env:MAINFRAME_NTFY_TOPIC, or ntfyTopic in mainframe.config.json. Use a long random topic name -- anyone who knows it can read approval requests and post fake ones."
    }
    return $Topic
}

function Get-VaultNtfyServer {
    param(
        [string]$Server = $null
    )

    # the relay only has to speak the ntfy http api. a machine whose egress
    # proxy denies ntfy.sh points this at a reachable ntfy-compatible relay;
    # the phone keeps using the same ntfy app and the same topic.
    if (-not $Server) { $Server = $env:MAINFRAME_NTFY_SERVER }
    if (-not $Server) { $Server = Get-VaultConfigValue -Key 'ntfyServer' }
    if (-not $Server) { $Server = 'https://ntfy.sh' }
    return $Server.TrimEnd('/')
}

function Get-VaultPagesBase {
    param(
        [string]$PagesBase = $null,
        [string]$ToolRepo = 'FahadBinHussain/mainframe'
    )

    # the approval card is a static file, so any host that serves it works.
    # a first-party deployment keeps the tap link off a raw github.io path.
    if (-not $PagesBase) { $PagesBase = $env:MAINFRAME_PAGES_BASE }
    if (-not $PagesBase) { $PagesBase = Get-VaultConfigValue -Key 'pagesBase' }
    if (-not $PagesBase) {
        $owner = ($ToolRepo -split '/')[0]
        # lowercased so windows and linux emit the exact same approval url
        $PagesBase = "https://$($owner.ToLower()).github.io/mainframe"
    }
    return $PagesBase.TrimEnd('/')
}

function ConvertTo-DerLength {
    param([int]$Length)

    # DER length: short form under 128, otherwise the long form with the
    # number of length bytes in the top bits.
    if ($Length -lt 0x80) { return ,([byte[]]@($Length)) }
    $bytes = New-Object System.Collections.Generic.List[byte]
    $value = $Length
    while ($value -gt 0) {
        $bytes.Insert(0, [byte]($value -band 0xFF))
        $value = $value -shr 8
    }
    $out = New-Object System.Collections.Generic.List[byte]
    $out.Add([byte](0x80 -bor $bytes.Count))
    $out.AddRange($bytes.ToArray())
    return ,$out.ToArray()
}

function ConvertTo-DerInteger {
    param([byte[]]$Value)

    # a DER INTEGER is signed, so a leading zero byte goes in front when the
    # top bit of the first content byte is set. leading zero bytes that are
    # already there are dropped.
    $start = 0
    while ($start -lt ($Value.Length - 1) -and $Value[$start] -eq 0) { $start++ }
    $body = New-Object System.Collections.Generic.List[byte]
    for ($i = $start; $i -lt $Value.Length; $i++) { $body.Add($Value[$i]) }
    if ($body.Count -gt 0 -and ($body[0] -band 0x80) -ne 0) { $body.Insert(0, [byte]0) }

    $length = ConvertTo-DerLength $body.Count
    $out = New-Object System.Collections.Generic.List[byte]
    $out.Add([byte]0x02)
    $out.AddRange($length)
    $out.AddRange($body.ToArray())
    return ,$out.ToArray()
}

function ConvertTo-DerSequence {
    param([byte[]]$Content)

    $length = ConvertTo-DerLength $Content.Length
    $out = New-Object System.Collections.Generic.List[byte]
    $out.Add([byte]0x30)
    $out.AddRange($length)
    $out.AddRange($Content)
    return ,$out.ToArray()
}

function ConvertTo-DerBitString {
    param([byte[]]$Content)

    # a BIT STRING carries the number of unused bits in the first content byte
    $length = ConvertTo-DerLength ($Content.Length + 1)
    $out = New-Object System.Collections.Generic.List[byte]
    $out.Add([byte]0x03)
    $out.AddRange($length)
    $out.Add([byte]0x00)
    $out.AddRange($Content)
    return ,$out.ToArray()
}

function ConvertTo-SubjectPublicKeyInfoManual {
    param(
        [Parameter(Mandatory = $true)]
        [System.Security.Cryptography.RSA]$Rsa
    )

    # hand rolled SubjectPublicKeyInfo:
    #
    #   SEQUENCE {
    #     SEQUENCE { OID 1.2.840.113549.1.1.1, NULL },
    #     BIT STRING { SEQUENCE { modulus INTEGER, exponent INTEGER } }
    #   }
    #
    # this is the .NET framework path - see ConvertTo-SubjectPublicKeyInfo.
    $public = $Rsa.ExportParameters($false)

    $rsaPublicKey = ConvertTo-DerSequence (
        (ConvertTo-DerInteger $public.Modulus) + (ConvertTo-DerInteger $public.Exponent)
    )

    $algorithm = ConvertTo-DerSequence ([byte[]]@(
        0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01,
        0x05, 0x00
    ))

    return ,(ConvertTo-DerSequence ($algorithm + (ConvertTo-DerBitString $rsaPublicKey)))
}

function ConvertTo-SubjectPublicKeyInfo {
    param(
        [Parameter(Mandatory = $true)]
        [System.Security.Cryptography.RSA]$Rsa
    )

    # The approval page imports this key with WebCrypto as 'spki', so it has
    # to be a real SubjectPublicKeyInfo DER structure.
    #
    # RSA.ExportSubjectPublicKeyInfo() is .NET Core only. windows powershell
    # 5.1 (.NET framework) has no such method and no RSAExtensions type at
    # all, and RSA.Create() there returns an RSACng - so calling the method
    # there dies with "does not contain a method named
    # 'ExportSubjectPublicKeyInfo'". that breaks the 1-tap unlock for every
    # helper invoked through `powershell -File`, because the unlock flow runs
    # inside windows powershell.
    #
    # so: use the native method when the runtime has it, and build the same
    # bytes by hand when it does not. the hand rolled encoder is byte for byte
    # identical to the native one - there is a test for that.
    if ([System.Security.Cryptography.RSA].GetMethod('ExportSubjectPublicKeyInfo')) {
        return ,($Rsa.ExportSubjectPublicKeyInfo())
    }
    return ,(ConvertTo-SubjectPublicKeyInfoManual -Rsa $Rsa)
}

function Get-VaultApprovalSigningKeyPath {
    param([string]$Path = $null)

    if ($Path) { return $Path }
    if ($env:MAINFRAME_APPROVAL_SIGNING_KEY) { return $env:MAINFRAME_APPROVAL_SIGNING_KEY }
    $root = Get-MainframeCheckoutRoot
    if ($root) { return (Join-Path $root 'mainframe.approval-signing.key') }
    return $null
}

function New-VaultApprovalSigningKeyFile {
    <#
    .SYNOPSIS
        mint this machine's own approval signing key and write it to -Path.
    .DESCRIPTION
        RSA-2048, exported in the same JSON shape the loader reads
        (n/e/d/p/q/dp/dq/qi, base64). Returns the public half as base64url
        SubjectPublicKeyInfo - the string the approval page encrypts the
        master password to (RSA-OAEP), so only this machine can read it
        back.

        A machine generates its key exactly once, on its first approval
        request; after that the file just loads. The private half never
        leaves the machine.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $rsa = [System.Security.Cryptography.RSA]::Create(2048)
    try {
        $p = $rsa.ExportParameters($true)
        $key = [ordered]@{
            n  = [Convert]::ToBase64String($p.Modulus)
            e  = [Convert]::ToBase64String($p.Exponent)
            d  = [Convert]::ToBase64String($p.D)
            p  = [Convert]::ToBase64String($p.P)
            q  = [Convert]::ToBase64String($p.Q)
            dp = [Convert]::ToBase64String($p.DP)
            dq = [Convert]::ToBase64String($p.DQ)
            qi = [Convert]::ToBase64String($p.InverseQ)
        }
        $dir = Split-Path -Parent $Path
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        [IO.File]::WriteAllText($Path, ($key | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
        try {
            if ([Environment]::OSVersion.Platform -eq [PlatformID]::Unix) { & chmod 600 $Path | Out-Null }
        } catch { }
        $spki = ConvertTo-SubjectPublicKeyInfo -Rsa $rsa
        return [Convert]::ToBase64String($spki).Replace('+', '-').Replace('/', '_').TrimEnd('=')
    } finally {
        $rsa.Dispose()
    }
}

function Get-VaultApprovalSigningKey {
    <#
    .SYNOPSIS
        this machine's RSA private key (the phone page encrypts the
        master password to its public half).
    .DESCRIPTION
        Each machine has its OWN key. When no key was provisioned for
        this machine and none is configured, the first call mints a pair
        (New-VaultApprovalSigningKeyFile) and uses it straight away -
        there is no registration list and no approval step for a new
        machine. The ntfy topic is the credential that gates who can ask
        for an approval; the key only carries the password back encrypted
        (RSA-OAEP), so the relay never sees it in the clear.

        An explicitly configured key (-Path, or
        $env:MAINFRAME_APPROVAL_SIGNING_KEY) that is missing still throws
        the restore message: that is a broken restore, not a first run.
    #>
    param([string]$Path = $null)

    $keyPath = Get-VaultApprovalSigningKeyPath -Path $Path
    if (-not $keyPath) {
        throw "no approval signing key path: set `$env:MAINFRAME_APPROVAL_SIGNING_KEY to the key file, or keep the mainframe checkout where mainframe.approval-signing.key sits next to mainframe.config.json. the key is kept in the bitwarden vault as github.com/FahadBinHussain/mainframe/mainframe.approval-signing.key and is restored by C:\Users\Admin\Downloads\automata-private\tools\env-sync.ps1 -Repo mainframe."
    }
    if (-not (Test-Path -LiteralPath $keyPath)) {
        if ($Path -or $env:MAINFRAME_APPROVAL_SIGNING_KEY) {
            throw "the approval signing key is missing: $keyPath. restore it from the bitwarden vault (github.com/FahadBinHussain/mainframe/mainframe.approval-signing.key) with C:\Users\Admin\Downloads\automata-private\tools\env-sync.ps1 -Repo mainframe. without it the phone page has no public key to encrypt the password to, so no approval can complete."
        }
        # first run on this machine: mint the key and use it. no
        # registration, no list - the topic is the credential.
        $null = New-VaultApprovalSigningKeyFile -Path $keyPath
    }
    $raw = Get-Content -LiteralPath $keyPath -Raw
    try {
        $key = $raw | ConvertFrom-Json
    } catch {
        throw "the approval signing key at $keyPath is not valid JSON: $($_.Exception.Message)"
    }
    foreach ($field in @('n', 'e', 'd', 'p', 'q', 'dp', 'dq', 'qi')) {
        if (-not $key.$field) {
            throw "the approval signing key at $keyPath has no '$field' field - it is not a mainframe approval key file"
        }
    }
    $rsa = [System.Security.Cryptography.RSA]::Create()
    try {
        $rsa.ImportParameters([System.Security.Cryptography.RSAParameters]@{
                Modulus  = [Convert]::FromBase64String($key.n)
                Exponent = [Convert]::FromBase64String($key.e)
                D        = [Convert]::FromBase64String($key.d)
                P        = [Convert]::FromBase64String($key.p)
                Q        = [Convert]::FromBase64String($key.q)
                DP       = [Convert]::FromBase64String($key.dp)
                DQ       = [Convert]::FromBase64String($key.dq)
                InverseQ = [Convert]::FromBase64String($key.qi)
            })
    } catch {
        $rsa.Dispose()
        throw "the approval signing key at $keyPath could not be loaded: $($_.Exception.Message)"
    }
    return $rsa
}

function Get-VaultApprovalPublicKey {
    <#
    .SYNOPSIS
        the signing public key as base64url SubjectPublicKeyInfo.
    .DESCRIPTION
        The same string travels in the approval link as `k`. It is public
        by design - it encrypts the password, it does not decrypt it.
    #>
    param([string]$Path = $null)

    $rsa = Get-VaultApprovalSigningKey -Path $Path
    try {
        $spki = ConvertTo-SubjectPublicKeyInfo -Rsa $rsa
        return [Convert]::ToBase64String($spki).Replace('+', '-').Replace('/', '_').TrimEnd('=')
    } finally {
        $rsa.Dispose()
    }
}

function Get-VaultApprovalLinkSigningKeyPath {
    <#
    .SYNOPSIS
        where the shared link-signing private key lives: the profile root,
        resolved through Get-MainframeProfileRoot, never a hardcoded path.
    #>
    param([string]$Path = $null)

    if ($Path) { return $Path }
    return (Join-Path (Get-MainframeProfileRoot) $script:VaultApprovalLinkSigningKeyFileName)
}

function Get-VaultApprovalLinkPayload {
    <#
    .SYNOPSIS
        the exact bytes the link signature covers: k LF sid LF code LF exp
        LF srv. exp/srv are the strings as serialized into the URL ('' when
        the param is absent) - sign the string, never re-format it.
    #>
    param(
        [string]$Key,
        [string]$Sid,
        [string]$Code,
        [string]$Exp = '',
        [string]$Server = ''
    )

    if ($null -eq $Key) { $Key = '' }
    if ($null -eq $Sid) { $Sid = '' }
    if ($null -eq $Code) { $Code = '' }
    if ($null -eq $Exp) { $Exp = '' }
    if ($null -eq $Server) { $Server = '' }
    return ($Key + "`n" + $Sid + "`n" + $Code + "`n" + $Exp + "`n" + $Server)
}

function Get-VaultApprovalLinkSignature {
    <#
    .SYNOPSIS
        sign a link payload with the shared EC key. returns the 64-byte raw
        R||S signature as base64url, no padding.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [System.Security.Cryptography.ECDsa]$Key,
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Payload
    )

    # SignData's default format is P1363 (raw R||S) - 64 bytes for P-256,
    # which is exactly what WebCrypto's ECDSA verify expects.
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Payload)
    $sig = $Key.SignData($bytes, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
    return [Convert]::ToBase64String($sig).Replace('+', '-').Replace('/', '_').TrimEnd('=')
}

function Invoke-BwApprovalCommand {
    <#
    .SYNOPSIS
        run the bw CLI with a hard timeout. returns stdout on success, $null
        on any failure (bw missing, non-zero exit, timeout) - the signing
        path treats every failure as "no live session", never as an error.
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

function Test-VaultApprovalLiveSession {
    <#
    .SYNOPSIS
        true when the bw CLI reports unlocked - the only condition under
        which the signing key may be fetched from the vault without a user
        step. never prompts, never throws.
    #>
    param([string]$Session = $null)

    $args = @('status')
    if ($Session) { $args += @('--session', $Session) }
    $out = Invoke-BwApprovalCommand -Arguments $args -TimeoutSeconds 10
    if (-not $out) { return $false }
    try {
        $status = $out | ConvertFrom-Json
        return ($status.status -eq 'unlocked')
    } catch {
        return $false
    }
}

function Sync-VaultApprovalSigningKeyFromVault {
    <#
    .SYNOPSIS
        self-heal the shared link-signing key: if the profile-root key file
        is missing and a live bw session exists, fetch the PEM from the
        vault (item notes) and save it 0600. returns $true when the key file
        exists afterwards, $false otherwise. never throws, never prints the
        key, never prompts - a failure just means the next link is unsigned.
    .DESCRIPTION
        DEADLOCK EDGE (future enforcement): under unsigned-refused
        enforcement, "session dead + key file lost" at the same time is a
        deadlock - the runner cannot approve (unsigned refused) and cannot
        fetch the key (no session). recovery is re-delivering key+topic
        together via the migration pack. two simultaneous failures; noted
        honestly here, not engineered around.
    #>
    param(
        [string]$Session = $null,
        [string]$Path = $null
    )

    $keyPath = if ($Path) { $Path } else { Get-VaultApprovalLinkSigningKeyPath }
    if (Test-Path -LiteralPath $keyPath) { return $true }
    if (-not (Test-VaultApprovalLiveSession -Session $Session)) { return $false }
    $args = @('list', 'items', '--search', $script:VaultApprovalLinkSigningVaultItemName)
    if ($Session) { $args += @('--session', $Session) }
    $out = Invoke-BwApprovalCommand -Arguments $args -TimeoutSeconds 15
    if (-not $out) { return $false }
    try {
        $items = ConvertFrom-JsonArray -Json $out
    } catch {
        return $false
    }
    # --search is a substring match: only the exact item name is the key.
    $item = @($items | Where-Object { [string]$_.name -eq $script:VaultApprovalLinkSigningVaultItemName }) | Select-Object -First 1
    if (-not $item -or -not $item.notes) { return $false }
    $pem = ([string]$item.notes).Trim()
    if ($pem -notmatch 'BEGIN EC PRIVATE KEY') { return $false }
    try {
        Write-MainframePrivateFile -Path $keyPath -Content ($pem + "`n") | Out-Null
        return $true
    } catch {
        return $false
    }
}

function Get-VaultApprovalLinkSigningKey {
    <#
    .SYNOPSIS
        the shared EC P-256 link-signing key, or $null when this machine has
        none (unsigned link). a missing file self-heals from the vault when
        a live session exists; otherwise the link just goes out unsigned.
        never throws - signing must never fail an approval.
    #>
    param([string]$Path = $null)

    $keyPath = if ($Path) { $Path } else { Get-VaultApprovalLinkSigningKeyPath }
    if (-not (Test-Path -LiteralPath $keyPath)) {
        $null = Sync-VaultApprovalSigningKeyFromVault -Path $keyPath
        if (-not (Test-Path -LiteralPath $keyPath)) { return $null }
    }
    try {
        $pem = [IO.File]::ReadAllText($keyPath)
        $ecdsa = [System.Security.Cryptography.ECDsa]::Create()
        try {
            # ImportFromPem is .NET Core only - windows powershell 5.1 has no
            # such method, so a 5.1 runner signs nothing (unsigned link).
            # the check is by NAME: the only overload takes a ReadOnlySpan,
            # and a GetMethod call naming [string] finds nothing even where
            # the method exists (powershell binds the string to the span
            # implicitly at the call below).
            $import = @([System.Security.Cryptography.ECDsa].GetMethods() | Where-Object { $_.Name -eq 'ImportFromPem' })
            if ($import.Count -eq 0) { $ecdsa.Dispose(); return $null }
            $ecdsa.ImportFromPem($pem)
        } catch {
            $ecdsa.Dispose()
            return $null
        }
        return $ecdsa
    } catch {
        return $null
    }
}

function Get-VaultNtfyTopicFromVault {
    <#
    .SYNOPSIS
        the canonical ntfy topic from the vault item (notes), or $null.
        never throws, never prints the value. a malformed vault value
        (not 32 chars of [a-z0-9]) is ignored with a loud warning - a bad
        item must never poison the local config.
    #>
    param([string]$Session = $null)

    if (-not (Test-VaultApprovalLiveSession -Session $Session)) { return $null }
    $args = @('list', 'items', '--search', $script:VaultNtfyTopicVaultItemName)
    if ($Session) { $args += @('--session', $Session) }
    $out = Invoke-BwApprovalCommand -Arguments $args -TimeoutSeconds 15
    if (-not $out) { return $null }
    try {
        $items = ConvertFrom-JsonArray -Json $out
    } catch {
        return $null
    }
    # --search is a substring match: only the exact item name is the topic.
    $item = @($items | Where-Object { [string]$_.name -eq $script:VaultNtfyTopicVaultItemName }) | Select-Object -First 1
    if (-not $item -or -not $item.notes) { return $null }
    $topic = ([string]$item.notes).Trim()
    if ($topic -cnotmatch '^[a-z0-9]{32}$') {
        Write-MainframeWarning 'the vault ntfy-topic item holds a malformed value (not 32 chars of [a-z0-9]) - ignoring it, the local config is unchanged. fix the item with windows/mainframe.ps1 vault rotate-topic.'
        return $null
    }
    return $topic
}

function Sync-VaultNtfyTopicFromVault {
    <#
    .SYNOPSIS
        converge the local config to the vault-held topic. returns $true
        when the vault topic was read (whether or not a write happened),
        $false when there is no live session, no vault item, or a malformed
        value - in all of those cases the local config is left exactly as
        it is (existing behavior). never throws, never prints the value.
    .DESCRIPTION
        writes go to every config file that carries a topic: the profile
        config and the checkout-root config (the checkout wins on reads,
        so leaving it stale would shadow the converged value). each write
        is atomic and 0600, via Write-MainframePrivateFile. a config that
        is missing or carries no topic is left alone; an unparseable one
        is warned about loudly and left alone. a real change is logged
        LOUDLY with the 4-char fingerprint only - an already-converged
        machine stays silent.
    #>
    param(
        [string]$Session = $null,
        [string]$ProfileConfigPath = $null,
        [string]$CheckoutConfigPath = $null
    )

    $vaultTopic = Get-VaultNtfyTopicFromVault -Session $Session
    if (-not $vaultTopic) { return $false }
    $profileConfig = if ($ProfileConfigPath) { $ProfileConfigPath } else { (Join-Path (Get-MainframeProfileRoot) 'mainframe.config.json') }
    $checkoutConfig = if ($CheckoutConfigPath) { $CheckoutConfigPath } else { (Join-Path $PSScriptRoot '..\mainframe.config.json') }
    $changed = $false
    foreach ($path in @($profileConfig, $checkoutConfig)) {
        if (-not $path -or -not (Test-Path -LiteralPath $path)) { continue }
        try {
            $json = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        } catch {
            Write-MainframeWarning "ntfy topic convergence: config is not parseable json, left alone: $path"
            continue
        }
        if (-not $json.ntfyTopic) { continue }
        if ([string]$json.ntfyTopic -eq $vaultTopic) { continue }
        $json.ntfyTopic = $vaultTopic
        try {
            $content = ($json | ConvertTo-Json -Depth 10) + "`n"
            Write-MainframePrivateFile -Path $path -Content $content | Out-Null
            $changed = $true
        } catch {
            Write-MainframeWarning "ntfy topic convergence: could not write $path - the local config is unchanged. ($($_.Exception.Message))"
        }
    }
    if ($changed) {
        Write-MainframeWarning "ntfy topic converged from the vault (now $(Get-NtfyTopicFingerprint -Topic $vaultTopic)) - the local config was stale"
    }
    return $true
}

function Get-NtfyTopicFingerprint {
    <#
    .SYNOPSIS
        what the terminal is allowed to print about the ntfy topic: the
        first 4 chars + an ellipsis. the topic is the ONLY credential, so
        the full name never appears in output (H1).
    #>
    param([string]$Topic)

    if (-not $Topic) { return '?' }
    $head = $Topic.Substring(0, [Math]::Min(4, $Topic.Length))
    return "$head…"
}

function Get-VaultApprovalUrl {
    param(
        [Parameter(Mandatory = $true)]
        [System.Security.Cryptography.RSA]$Rsa,
        [string]$ToolRepo = 'FahadBinHussain/mainframe',
        [string]$PromptContext = 'vault access',
        [string]$HostName = $env:COMPUTERNAME,
        [string]$Agent = $null,
        [string]$Model = $null,
        # how long the runner will keep waiting. landing this in the link lets
        # the phone page say "stale" instead of offering a tap nobody hears.
        [int]$ExpiresInSeconds = 0,
        [string]$PagesBase = $null,
        [string]$Server = $null
    )

    $identity = Get-CallerIdentity -Agent $Agent -Model $Model -PromptContext $PromptContext
    $resolvedAgent = $identity.Agent
    $resolvedModel = $identity.Model

    $derBytes = ConvertTo-SubjectPublicKeyInfo -Rsa $Rsa
    $k = [Convert]::ToBase64String($derBytes).Replace('+', '-').Replace('/', '_').TrimEnd('=')

    $sidBytes = New-Object byte[] 12
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($sidBytes)
    $sidHex = -join ($sidBytes | ForEach-Object { $_.ToString('x2') })
    $sid = "mf-vault-$sidHex"

    # Cryptographic random 4-digit verification code for Number Matching
    # (1000 + uniform 0..8999 from 2 random bytes - the modulo bias over a
    # 16-bit space is not worth mentioning). It stays a user-matching aid,
    # not a secret.
    $codeBytes = New-Object byte[] 2
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($codeBytes)
    $code = (1000 + ([BitConverter]::ToUInt16($codeBytes, 0) % 9000)).ToString()

    $escapedCtx = [Uri]::EscapeDataString($PromptContext)
    $escapedHost = [Uri]::EscapeDataString($HostName)
    $escapedAgent = [Uri]::EscapeDataString($resolvedAgent)
    $modelParam = if ($resolvedModel) { "&model=" + [Uri]::EscapeDataString($resolvedModel) } else { "" }
    $expUnix = if ($ExpiresInSeconds -gt 0) { [DateTimeOffset]::UtcNow.AddSeconds($ExpiresInSeconds).ToUnixTimeSeconds() } else { $null }
    $expParam = if ($null -ne $expUnix) { "&exp=$expUnix" } else { "" }

    $owner = ($ToolRepo -split '/')[0]
    $resolvedPages = Get-VaultPagesBase -PagesBase $PagesBase -ToolRepo $ToolRepo
    $resolvedRelay = Get-VaultNtfyServer -Server $Server
    # the relay hint rides in the link so the card posts the ciphertext back
    # to the same relay this runner reads. without it the page would
    # hardcode ntfy.sh and a machine behind a relay would never see the
    # approval land.
    $relayHint = if ($resolvedRelay -ne 'https://ntfy.sh') { $resolvedRelay } else { '' }

    $url = "$resolvedPages/docs/vault-tab.html?v=$script:VaultApprovalPageVersion#k=$k&sid=$sid&code=$code&host=$escapedHost&ctx=$escapedCtx&agent=$escapedAgent$modelParam$expParam"
    if ($resolvedRelay -ne 'https://ntfy.sh') {
        $url += "&srv=$([Uri]::EscapeDataString($resolvedRelay))"
    }

    # link signing (C1): sign the exact strings in the URL. exp/srv are ''
    # when the param is absent. k/sid/code/exp are URL-safe so raw ==
    # escaped; srv is signed UNescaped because the page URL-decodes the
    # fragment before verifying. a missing key means an unsigned link - the
    # page warns but allows it, and the approval never fails for it.
    $expString = if ($null -ne $expUnix) { "$expUnix" } else { '' }
    $srvString = $relayHint
    $signature = $null
    $signedPayload = $null
    $linkKey = Get-VaultApprovalLinkSigningKey
    if ($linkKey) {
        try {
            $signedPayload = Get-VaultApprovalLinkPayload -Key $k -Sid $sid -Code $code -Exp $expString -Server $srvString
            $signature = Get-VaultApprovalLinkSignature -Key $linkKey -Payload $signedPayload
            $url += "&sig=$signature"
        } catch {
            $signature = $null
            $signedPayload = $null
        } finally {
            $linkKey.Dispose()
        }
    }

    return [PSCustomObject]@{
        Url           = $url
        Sid           = $sid
        Code          = $code
        Key           = $k
        Agent         = $resolvedAgent
        Model         = $resolvedModel
        ExpiresAtUnix = $expUnix
        Server        = $relayHint
        Signature     = $signature
        SignedPayload = $signedPayload
    }
}

function Send-VaultApprovalNotification {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Topic,
        [Parameter(Mandatory = $true)]
        [string]$Url,
        [string]$HostName = $env:COMPUTERNAME,
        [string]$Code = $null,
        [string]$PromptContext = "vault access",
        [string]$Agent = $null,
        [string]$Model = $null,
        [string]$Server = $null
    )

    $resolvedServer = Get-VaultNtfyServer -Server $Server
    # topic-only auth: every publish is anonymous. knowing the topic name
    # is the credential - no header is ever sent.
    try {
        $callerTag = if ($Agent) { "$HostName - $Agent" } else { $HostName }
        $title = if ($Code) { "Vault Unlock: Code [$Code] ($callerTag)" } else { "Vault Unlock ($callerTag)" }
        $actionTitle = if ($Code) { "Unlock [$Code]" } else { "Unlock Vault" }
        $headers = @{
            'Title'   = $title
            'Priority'= 'urgent'
            'Tags'    = 'lock,key'
            'Click'   = $Url
            'Actions' = "view, $actionTitle, $Url, clear=true"
            # explicit text/plain: a relay in front of ntfy must be able to
            # read the body back byte for byte.
            'Content-Type' = 'text/plain; charset=utf-8'
        }
        $bodyParts = @("Request from $HostName")
        if ($Agent) { $bodyParts += "Agent: $Agent" }
        if ($Model) { $bodyParts += "Model: $Model" }
        $bodyParts += "Action: $PromptContext"
        $bodyParts += "Verification Code: [$Code]"
        $bodyParts += "Tap to verify matching number on terminal and approve."
        $body = $bodyParts -join "`n"
        $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($body)
        $null = Invoke-RestMethod -Uri "$resolvedServer/$Topic" -Method Post -Headers $headers -Body $bodyBytes -TimeoutSec 10 -ErrorAction Stop
        return $true
    } catch {
        $status = 0
        try { $status = [int]$_.Exception.Response.StatusCode } catch { $status = 0 }
        if ($status -eq 401 -or $status -eq 403) {
            # the relay answers 403 only when the topic or server is wrong -
            # there is no credential to set, the topic name in
            # mainframe.config.json is the credential. without this warning
            # the only symptom is a phone that never buzzes. the topic
            # itself is never printed - only its fingerprint (H1).
            Write-MainframeWarning "ntfy refused the push (HTTP $status, topic '$(Get-NtfyTopicFingerprint -Topic $Topic)'): the relay or topic is misconfigured. check ntfyTopic and ntfyServer in mainframe.config.json - there is no credential to set."
        } else {
            Write-MainframeWarning "ntfy push dispatch (topic '$(Get-NtfyTopicFingerprint -Topic $Topic)') failed: $_"
        }
        return $false
    }
}

function Send-VaultRequestExpired {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Sid,
        [string]$HostName = $env:COMPUTERNAME,
        [string]$Code = $null,
        [string]$Server = $null
    )

    $resolvedServer = Get-VaultNtfyServer -Server $Server
    # the runner stopped waiting, so the card must stop offering a tap nobody
    # hears. the marker rides the same single-use topic the card already polls.
    try {
        $body = ConvertTo-Json -Compress -InputObject ([ordered]@{
                mf   = 'expired'
                at   = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
                host = $HostName
                code = $Code
            })
        $headers = @{
            'Title'    = 'Vault Request Expired'
            'Priority' = 'low'
            'Tags'     = 'hourglass'
            'Content-Type' = 'text/plain; charset=utf-8'
        }
        $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($body)
        $null = Invoke-RestMethod -Uri "$resolvedServer/$Sid" -Method Post -Headers $headers -Body $bodyBytes -TimeoutSec 10 -ErrorAction Stop
        return $true
    } catch {
        Write-MainframeWarning "could not publish the expired marker to '$Sid': $_"
        return $false
    }
}

function Open-VaultApprovalOnPhone {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url
    )

    $adb = Get-Command adb -ErrorAction SilentlyContinue
    if (-not $adb) { return $false }

    try {
        $devices = & adb devices 2>$null
        if ($devices -match '([A-Za-z0-9_-]+)\s+device\b') {
            Write-Host "phone attached via adb - popping up full-screen prompt on phone..." -ForegroundColor Green
            & adb shell input keyevent KEYCODE_WAKEUP 2>$null
            & adb shell "am start -a android.intent.action.VIEW -d '$Url'" 2>$null
            return $true
        }
    } catch {
        # ignore adb errors
    }
    return $false
}

function Test-VaultApprovalCiphertext {
    param(
        [string]$Value,
        [System.Security.Cryptography.RSA]$Rsa = $null
    )

    if (-not $Value) { return $false }
    $Value = $Value.Trim()
    # RSA-2048 / OAEP-SHA256 is always one 256-byte block, which is 344 base64
    # chars. anything else on the relay topic is noise (status markers, garbage
    # posted by whoever knows the topic) and must be skipped, not returned.
    if ($Value.Length -ne 344) { return $false }
    if ($Value -notmatch '^[A-Za-z0-9+/]+={0,2}$') { return $false }
    try {
        $bytes = [Convert]::FromBase64String($Value)
    } catch {
        return $false
    }
    if ($bytes.Length -ne 256) { return $false }
    if ($Rsa) {
        # a well-formed block this key cannot decrypt is not our approval --
        # accepting it would kill the real one inside the poll window.
        try {
            $null = $Rsa.Decrypt($bytes, [System.Security.Cryptography.RSAEncryptionPadding]::OaepSHA256)
        } catch {
            return $false
        }
    }
    return $true
}

function Select-VaultApprovalCiphertext {
    <#
    .SYNOPSIS
        pick the FIRST valid ciphertext out of one raw relay poll. a fake
        posted after the real one must never win (M5), and a flood of fakes
        must not burn the whole poll on trial decryptions.
    .DESCRIPTION
        lines are tried in arrival order. shape is checked first (cheap);
        only a well-formed block costs a trial decrypt, at most
        MaxTrialsPerPoll of them per call. lines already trial-decrypted in
        an earlier poll are remembered in -Tested and skipped, so a flood
        is worked through poll by poll instead of re-tried forever - the
        real ciphertext is eventually reached even behind 200 fakes.
        returns the first valid ciphertext, or $null.
    #>
    param(
        [AllowEmptyString()]
        [string]$Body,
        [System.Security.Cryptography.RSA]$Rsa = $null,
        [System.Collections.Generic.HashSet[string]]$Tested = $null,
        [int]$MaxTrialsPerPoll = 10
    )

    if (-not $Body) { return $null }
    $trials = 0
    foreach ($rawLine in ($Body -split "`n")) {
        $line = $rawLine.Trim()
        if (-not $line) { continue }
        if ($Tested -and $Tested.Contains($line)) { continue }
        if (-not (Test-VaultApprovalCiphertext -Value $line)) { continue }
        if ($trials -ge $MaxTrialsPerPoll) { break }
        $trials++
        if ($Tested) { [void]$Tested.Add($line) }
        if (Test-VaultApprovalCiphertext -Value $line -Rsa $Rsa) { return $line }
    }
    return $null
}

function Wait-VaultApprovalCiphertext {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Sid,
        [int]$TimeoutSeconds = 300,
        [string]$LocalFileName = 'mainframe-vault-pass.enc',
        [DateTime]$StartTimeUtc = [DateTime]::MinValue,
        [System.Security.Cryptography.RSA]$Rsa = $null,
        [string]$Server = $null
    )

    $resolvedServer = Get-VaultNtfyServer -Server $Server
    # two joins, not one: a 'Downloads\file' literal would look for a file
    # NAMED "Downloads\file" inside $HOME on linux, and the browser tab's
    # download would never be found.
    $downloadPath = Join-Path (Join-Path $HOME 'Downloads') $LocalFileName
    $sessionFile = Get-MainframeSessionKeyPath
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $pollDelay = 2
    # ciphertexts already trial-decrypted in an earlier poll: skipped, so a
    # flood of fakes is worked through instead of re-tried forever (M5).
    $testedCiphertexts = New-Object System.Collections.Generic.HashSet[string]

    while ([DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Seconds $pollDelay

        # 1. Check if another agent completed the unlock while we were waiting
        if ($StartTimeUtc -ne [DateTime]::MinValue -and (Test-Path -LiteralPath $sessionFile)) {
            $fi = Get-Item -LiteralPath $sessionFile
            if ($fi.LastWriteTimeUtc -ge $StartTimeUtc) {
                return '__SESSION_ALREADY_UNLOCKED__'
            }
        }

        # 2. Poll relay topic
        try {
            # topic-only auth: the poll carries no credential - knowing the
            # sid topic name is what authorises the read.
            $pollHeaders = @{}
            # Invoke-RestMethod parses a JSON body into an object, which turns
            # an expired marker into something no regex can recognise. the
            # webrequest content stays text, so markers and ciphertext look
            # the way they were posted.
            $resp = Invoke-WebRequest -Uri "$resolvedServer/$Sid/raw?poll=1" -Method Get -Headers $pollHeaders -TimeoutSec 5 -ErrorAction Stop
            $body = [string]$resp.Content
            if ($body) {
                # raw returns every message on the topic, newline separated.
                # only a payload that is a valid RSA block for this request is
                # an approval; expired markers and spoofed bodies are skipped so
                # they cannot end the wait. the FIRST valid block wins - a fake
                # posted after the real one must never displace it (M5).
                $found = Select-VaultApprovalCiphertext -Body $body -Rsa $Rsa -Tested $testedCiphertexts -MaxTrialsPerPoll 10
                if ($found) {
                    return $found
                }
                # bound the memory: re-testing a thousand old lines costs one
                # slow poll, keeping them forever costs the whole wait.
                if ($testedCiphertexts.Count -gt 1000) { $testedCiphertexts.Clear() }
            }
            $pollDelay = 2
        } catch {
            # ntfy rate-limits per ip. polling every 2 seconds on top of
            # another pending approval is enough to trip it, and a tripped
            # limit also eats the *push* - the phone then never hears about
            # the request at all. back off hard.
            $status = $null
            if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
            if ($status -eq 429) {
                $pollDelay = 30
                Write-MainframeWarning "relay rate limit hit (429) - backing off to $pollDelay seconds"
            } else {
                $pollDelay = [Math]::Min($pollDelay * 2, 30)
            }
        }

        # 3. Check local file
        if (Test-Path -LiteralPath $downloadPath) {
            try {
                $content = (Get-Content -LiteralPath $downloadPath -Raw).Trim()
                Remove-Item -LiteralPath $downloadPath -Force -ErrorAction SilentlyContinue
                if (Test-VaultApprovalCiphertext -Value $content -Rsa $Rsa) {
                    return $content
                }
                if ($content) {
                    Write-MainframeWarning "ignoring $LocalFileName -- not a valid approval payload for this request"
                }
            } catch {
                # file locked or transient read issue
            }
        }
    }
    return $null
}

function Decrypt-VaultApprovalCiphertext {
    param(
        [Parameter(Mandatory = $true)]
        [System.Security.Cryptography.RSA]$Rsa,
        [Parameter(Mandatory = $true)]
        [string]$Ciphertext
    )

    if (-not (Test-VaultApprovalCiphertext -Value $Ciphertext)) {
        throw "approval payload is not a well-formed 256-byte RSA ciphertext (length $($Ciphertext.Length)) -- refusing to treat it as the master password"
    }
    $cipherBytes = [Convert]::FromBase64String($Ciphertext)
    $plainBytes = $Rsa.Decrypt($cipherBytes, [System.Security.Cryptography.RSAEncryptionPadding]::OaepSHA256)
    $plain = [System.Text.Encoding]::UTF8.GetString($plainBytes)

    $pw = $plain
    $ttlMinutes = 0
    if ($plain.StartsWith('{') -and $plain.EndsWith('}')) {
        try {
            $parsed = $plain | ConvertFrom-Json
            if ($parsed.pw) {
                $pw = [string]$parsed.pw
                if ($parsed.ttl) { $ttlMinutes = [int]$parsed.ttl }
                elseif ($parsed.ttlMinutes) { $ttlMinutes = [int]$parsed.ttlMinutes }
                # the TTL comes from the phone side: trust it, but clamp it -
                # a session longer than 12 hours is never what was asked for.
                if ($ttlMinutes -gt 720) { $ttlMinutes = 720 }
            }
        } catch {}
    }

    if ($ttlMinutes -gt 0) {
        $env:MAINFRAME_VAULT_APPROVED_TTL = [string]$ttlMinutes
        $script:LastApprovedTtlMinutes = $ttlMinutes
        Write-Host "mobile approval requested extended session: $ttlMinutes minutes ($([math]::Round($ttlMinutes / 60)) hours)" -ForegroundColor Green
    } else {
        Remove-Item Env:MAINFRAME_VAULT_APPROVED_TTL -ErrorAction SilentlyContinue
        $script:LastApprovedTtlMinutes = $null
    }

    return $pw
}

function Get-VaultApprovedTtlMinutes {
    if ($env:MAINFRAME_VAULT_APPROVED_TTL) {
        try { return [int]$env:MAINFRAME_VAULT_APPROVED_TTL } catch {}
    }
    if ($script:LastApprovedTtlMinutes) {
        return [int]$script:LastApprovedTtlMinutes
    }
    return 0
}

function Get-VaultApprovalLockPath {
    <#
    .SYNOPSIS
        the one lock file that serialises phone approval requests.
    #>
    $dir = Join-Path (Get-MainframeAccountsDir) 'bitwarden'
    if (-not (Test-Path -LiteralPath $dir)) {
        $null = New-Item -ItemType Directory -Force -Path $dir -ErrorAction Stop
    }
    return (Join-Path $dir 'approval.lock')
}

function ConvertFrom-VaultApprovalLockJson {
    param([string]$Json, [string]$Path)

    if (-not $Json -or -not $Json.Trim()) { return $null }
    try {
        $data = $Json | ConvertFrom-Json
    } catch {
        return $null
    }
    if (-not $data.token) { return $null }

    $started = if ($data.startedAt) { [long]$data.startedAt } else { 0 }
    $expires = if ($data.expiresAt) { [long]$data.expiresAt } else { 0 }
    $startedLocal = if ($started -gt 0) {
        [DateTimeOffset]::FromUnixTimeSeconds($started).LocalDateTime.ToString('HH:mm:ss')
    } else {
        'unknown'
    }

    return [pscustomobject]@{
        Path           = $Path
        Token          = [string]$data.token
        Pid            = [int]$data.pid
        Host           = [string]$data.host
        Context        = [string]$data.context
        Agent          = [string]$data.agent
        Model          = [string]$data.model
        State          = [string]$data.state
        Code           = [string]$data.code
        Sid            = [string]$data.sid
        StartedAtUnix  = $started
        ExpiresAtUnix  = $expires
        StartedAtLocal = $startedLocal
        Data           = $data
    }
}

function Read-VaultApprovalLock {
    param([string]$Path = (Get-VaultApprovalLockPath))

    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $json = $null
    try {
        $json = [IO.File]::ReadAllText($Path)
    } catch {
        # a holder rewriting the record (or a transient share violation) reads
        # as "no record yet"; the caller loops, it never treats this as owned.
        return $null
    }
    return (ConvertFrom-VaultApprovalLockJson -Json $json -Path $Path)
}

function Write-VaultApprovalLockFile {
    <#
    .SYNOPSIS
        create the lock record atomically. returns $false when somebody already
        holds the turn - the create either wins the whole file or loses it, so
        two requesters can never both believe they own the phone.
    #>
    param(
        [string]$Path,
        [System.Collections.IDictionary]$Data
    )

    $tmp = "$Path.$PID.$([guid]::NewGuid().ToString('N').Substring(0, 8)).tmp"
    $json = ConvertTo-Json -InputObject $Data -Compress
    try {
        [IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
        # the record carries the sid + code: 0600 before the move, so the
        # lock file is never created with default perms (L11).
        Set-MainframeFileOwnerOnly -Path $tmp
        [IO.File]::Move($tmp, $Path)
        return $true
    } catch [System.IO.IOException] {
        return $false
    } finally {
        if ([IO.File]::Exists($tmp)) {
            [IO.File]::Delete($tmp)
        }
    }
}

function Set-VaultApprovalRequestDetails {
    <#
    .SYNOPSIS
        stamp the verification code / relay topic onto our own lock record, so
        a queue can say which request it is waiting on.
    #>
    param(
        [string]$Path,
        [string]$Token,
        [string]$Code,
        [string]$Sid
    )

    $current = Read-VaultApprovalLock -Path $Path
    if (-not $current -or $current.Token -ne $Token) { return $false }
    $current.Data.code = $Code
    $current.Data.sid = $Sid
    try {
        [IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $current.Data -Compress))
        return $true
    } catch {
        Write-MainframeWarning "could not record the approval code on $Path - the queue will show it without a code: $_"
        return $false
    }
}

function Remove-VaultApprovalLock {
    <#
    .SYNOPSIS
        delete the lock, but only while it still carries the expected token -
        a record that somebody took over is never deleted out from under them.
    #>
    param(
        [string]$Path,
        [string]$Token
    )

    $current = Read-VaultApprovalLock -Path $Path
    if (-not $current) { return $true }
    if ($Token -and $current.Token -ne $Token) { return $false }
    Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    return (-not (Test-Path -LiteralPath $Path))
}

function Test-VaultSessionKeyFresh {
    <#
    .SYNOPSIS
        true when a session key was written at or after the given moment - the
        same rule Wait-VaultApprovalCiphertext uses to notice another agent's
        unlock.
    #>
    param(
        [string]$SessionFile = (Get-MainframeSessionKeyPath),
        [DateTime]$SinceUtc = [DateTime]::MinValue
    )

    if ($SinceUtc -eq [DateTime]::MinValue) { return $false }
    if (-not (Test-Path -LiteralPath $SessionFile)) { return $false }
    try {
        $written = (Get-Item -LiteralPath $SessionFile).LastWriteTimeUtc
        return ($written -ge $SinceUtc.ToUniversalTime())
    } catch {
        return $false
    }
}

function Enter-VaultApprovalRequest {
    <#
    .SYNOPSIS
        take the phone turn, or wait quietly until the live request goes stale.

    .DESCRIPTION
        Returns an object with either:
            Acquired = $true   - this caller owns the prompt and must close the
                                 request when it is done (Close-VaultApprovalRequest)
            AlreadyUnlocked    - a session key appeared while waiting; nothing
                                 was pushed and nothing must be
        It throws when the queue itself cannot move (a dead holder that never
        releases, an unreadable lock path), so a stuck queue is never silent.
    #>
    param(
        [string]$PromptContext = 'vault access',
        [int]$TimeoutSeconds = 300,
        [string]$Agent = $null,
        [string]$Model = $null,
        [string]$HostName = $env:COMPUTERNAME,
        [DateTime]$SinceUtc = [DateTime]::MinValue,
        [int]$QueueTimeoutSeconds = 0
    )

    $path = Get-VaultApprovalLockPath
    $sessionFile = Get-MainframeSessionKeyPath
    if ($SinceUtc -eq [DateTime]::MinValue) { $SinceUtc = [DateTime]::UtcNow }
    if ($QueueTimeoutSeconds -le 0) {
        # enough turns for a stampede to drain, and never less than ten minutes
        # so a slow tap is not cut short by the queue itself.
        $QueueTimeoutSeconds = [Math]::Max(600, $TimeoutSeconds * 4)
    }
    $queueDeadline = [DateTime]::UtcNow.AddSeconds($QueueTimeoutSeconds)
    $waitingOn = ''
    $waited = $false

    while ($true) {
        if (Test-VaultSessionKeyFresh -SessionFile $sessionFile -SinceUtc $SinceUtc) {
            if ($waited) {
                Write-Host 'the vault was unlocked while this request waited - no phone prompt was sent' -ForegroundColor Green
            }
            return [pscustomobject]@{ Acquired = $false; AlreadyUnlocked = $true; Path = $path; Token = $null }
        }

        if ([DateTime]::UtcNow -gt $queueDeadline) {
            $owner = Read-VaultApprovalLock -Path $path
            $ownerText = if ($owner) {
                "code [$($owner.Code)] by $($owner.Agent) @ $($owner.Host), pid $($owner.Pid), expires $($owner.ExpiresAtUnix)"
            } else {
                'nobody - the lock file is gone'
            }
            throw "another agent's phone approval has been in flight for more than $QueueTimeoutSeconds seconds and this request gave up waiting. nothing was pushed to the phone from this request. lock: $path; holder: $ownerText"
        }

        $holder = Read-VaultApprovalLock -Path $path
        $nowUnix = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

        if ($holder -and $holder.ExpiresAtUnix -gt $nowUnix) {
            $holderId = "$($holder.Pid)|$($holder.StartedAtUnix)"
            if ($holderId -ne $waitingOn) {
                $waitingOn = $holderId
                $waited = $true
                $codeText = if ($holder.Code) { "code [$($holder.Code)]" } else { 'no code yet' }
                $left = [int]($holder.ExpiresAtUnix - $nowUnix)
                Write-Host ("another request already has the phone ({0}, {1} @ {2}, started {3}, {4}s left) - waiting quietly, no second prompt" -f $codeText, $holder.Agent, $holder.Host, $holder.StartedAtLocal, $left) -ForegroundColor Yellow
            }
            Start-Sleep -Seconds 2
            continue
        }

        if ($holder) {
            # the deadline lapsed: either the holder crashed, or it is in its
            # last seconds (it still deletes its own record when it finishes).
            # the grace window keeps a live holder from losing its own turn.
            if ($holder.State -eq 'approved') {
                # the previous request succeeded and held the turn only while
                # its caller wrote session.key. that state is terminal, so it
                # is safe to reuse the slot right away.
                $null = Remove-VaultApprovalLock -Path $path -Token $holder.Token
            } elseif ($holder.ExpiresAtUnix -le ($nowUnix - $script:VaultApprovalLockGraceSeconds)) {
                if (Remove-VaultApprovalLock -Path $path -Token $holder.Token) {
                    Write-MainframeWarning ("taking over the expired phone approval ({0} from {1} @ {2}, started {3}) - this request is now the one asking" -f $(if ($holder.Code) { "code [$($holder.Code)]" } else { 'no code' }), $holder.Agent, $holder.Host, $holder.StartedAtLocal)
                }
            }
            Start-Sleep -Seconds 1
            continue
        }

        $token = [guid]::NewGuid().ToString('N')
        $startedAt = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $expiresAt = $startedAt + [Math]::Max(30, $TimeoutSeconds) + $script:VaultApprovalLockMarginSeconds
        $record = [ordered]@{
            token     = $token
            pid       = $PID
            host      = $HostName
            context   = $PromptContext
            agent     = $Agent
            model     = $Model
            state     = 'pending'
            code      = ''
            sid       = ''
            startedAt = $startedAt
            expiresAt = $expiresAt
        }
        if (Write-VaultApprovalLockFile -Path $path -Data $record) {
            if ($waited) {
                Write-Host 'the earlier request is gone - this request now asks the phone' -ForegroundColor Cyan
            }
            return [pscustomobject]@{
                Acquired      = $true
                AlreadyUnlocked = $false
                Path          = $path
                Token         = $token
                StartedAtUnix = $startedAt
                ExpiresAtUnix = $expiresAt
            }
        }
        # somebody else created it first; loop and wait on them
        Start-Sleep -Milliseconds 200
    }
}

function Close-VaultApprovalRequest {
    <#
    .SYNOPSIS
        give the turn back. -Approved keeps it for a moment, because the caller
        still has to run `bw unlock` and write session.key - a waiter that
        grabbed the turn in that gap would push a second prompt.
    #>
    param(
        [string]$Path,
        [string]$Token,
        [switch]$Approved
    )

    if (-not $Path -or -not $Token) { return }
    $current = Read-VaultApprovalLock -Path $Path
    if (-not $current) { return }
    if ($current.Token -ne $Token) {
        # our record lapsed while we were still waiting; whoever took over owns
        # the file now, so leave it (and say so - this is not normal).
        Write-MainframeWarning "the approval lock at $Path was taken over by another request while this one was still running - leaving it alone"
        return
    }

    if ($Approved) {
        $current.Data.state = 'approved'
        $current.Data.expiresAt = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + $script:VaultApprovalLockSettleSeconds
        try {
            [IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $current.Data -Compress))
            return
        } catch {
            Write-MainframeWarning "could not mark the approval lock as resolved - releasing it now: $_"
        }
    }
    $null = Remove-VaultApprovalLock -Path $Path -Token $Token
}

function Get-VaultMasterPassword {
    [CmdletBinding()]
    param(
        [string]$NtfyTopic = $null,
        [string]$PromptContext = "vault access",
        [int]$TimeoutSeconds = 300,
        [string]$Agent = $null,
        [string]$Model = $null,
        [string]$HostName = $env:COMPUTERNAME,
        [DateTime]$StartTimeUtc = [DateTime]::MinValue,
        [string]$Server = $null,
        [string]$PagesBase = $null,
        [int]$QueueTimeoutSeconds = 0
    )

    # Resolve ntfy topic
    if (-not $NtfyTopic) {
        $NtfyTopic = Get-VaultNtfyTopic
    }
    $resolvedServer = Get-VaultNtfyServer -Server $Server

    # A call means "the caller believes the vault is locked". Freshness is
    # measured from here, so a session another agent writes while we queue
    # reads as "already unlocked" instead of as a reason to ask again.
    if ($StartTimeUtc -eq [DateTime]::MinValue) {
        $StartTimeUtc = [DateTime]::UtcNow
    }

    # Single flight: one prompt on the phone, everybody else waits for it.
    $turn = Enter-VaultApprovalRequest -PromptContext $PromptContext -TimeoutSeconds $TimeoutSeconds `
        -Agent $Agent -Model $Model -HostName $HostName -SinceUtc $StartTimeUtc `
        -QueueTimeoutSeconds $QueueTimeoutSeconds
    if ($turn.AlreadyUnlocked) {
        return '__SESSION_ALREADY_UNLOCKED__'
    }

    $approved = $false
    $rsa = $null
    try {
        $rsa = [System.Security.Cryptography.RSA]::Create(2048)
        $session = Get-VaultApprovalUrl -Rsa $rsa -PromptContext $PromptContext -HostName $HostName -Agent $Agent -Model $Model -ExpiresInSeconds $TimeoutSeconds -Server $resolvedServer -PagesBase $PagesBase
        $url = $session.Url
        $sid = $session.Sid
        $code = $session.Code
        $resolvedAgent = $session.Agent
        $resolvedModel = $session.Model
        # The wake-up push goes to the topic the phone listens on, the answer
        # comes back to the single-use sid topic.
        $null = Set-VaultApprovalRequestDetails -Path $turn.Path -Token $turn.Token -Code $code -Sid $sid

        $callerDisplay = if ($resolvedModel) { "$resolvedAgent ($resolvedModel) @ $HostName" } else { "$resolvedAgent @ $HostName" }

        Write-Host "`n==> 1-tap mobile approval for $PromptContext" -ForegroundColor Cyan
        Write-Host "==================================================" -ForegroundColor Green
        Write-Host "  VERIFICATION CODE: [ $code ]" -ForegroundColor Green
        Write-Host "  Caller: $callerDisplay" -ForegroundColor White
        Write-Host "  Context: $PromptContext" -ForegroundColor Gray
        Write-Host "  (Ensure the number on your phone matches $code)" -ForegroundColor Yellow
        Write-Host "==================================================" -ForegroundColor Green
        # the full URL carries k/sid/code - it lands in transcripts and logs,
        # so it only prints with -Verbose (L19). the phone gets it via the
        # push, not the terminal.
        Write-Verbose "approval url: $url"

        if ($NtfyTopic) {
            $sent = Send-VaultApprovalNotification -Topic $NtfyTopic -Url $url -Code $code -PromptContext $PromptContext -HostName $HostName -Agent $resolvedAgent -Model $resolvedModel -Server $resolvedServer
            if ($sent) {
                Write-Host "push notification sent (ntfy topic $(Get-NtfyTopicFingerprint -Topic $NtfyTopic))" -ForegroundColor Green
            } else {
                # rule 8: no silent degradation. without the push the phone
                # never hears about this request, so waiting would burn the
                # whole timeout and fail for a reason nobody was told about.
                throw "phone approval push failed, so the phone was never notified. the request was NOT sent to the relay at $resolvedServer. check the relay (a 429 here means the ntfy rate limit is tripped - another pending approval polling every 2s is usually the cause). no approval can arrive now."
            }
        }

        $opened = Open-VaultApprovalOnPhone -Url $url

        Write-Host "waiting for 1-tap fingerprint approval on phone (or ~/Downloads/mainframe-vault-pass.enc) ..." -ForegroundColor Yellow
        $ct = Wait-VaultApprovalCiphertext -Sid $sid -TimeoutSeconds $TimeoutSeconds -StartTimeUtc $StartTimeUtc -Rsa $rsa -Server $resolvedServer

        if ($ct -eq '__SESSION_ALREADY_UNLOCKED__') {
            $null = Send-VaultRequestExpired -Sid $sid -HostName $HostName -Code $code -Server $resolvedServer
            return '__SESSION_ALREADY_UNLOCKED__'
        }

        if ($ct) {
            $pw = Decrypt-VaultApprovalCiphertext -Rsa $rsa -Ciphertext $ct
            # the caller runs `bw unlock` next; keep the turn a little longer so
            # no queued waiter beats it to a second prompt.
            $approved = $true
            # the runner only ever sees ciphertext: it cannot know whether the
            # phone side tapped fingerprint or typed the password, so the log
            # must not claim a method. (2026-11-15: this line used to say
            # "via 1-tap biometric approval" unconditionally, and two approvals
            # were misreported as fingerprint when the user had typed.)
            Write-Host "password decrypted successfully" -ForegroundColor Green
            try {
                $accountsDir = Join-Path (Get-MainframeAccountsDir) 'bitwarden'
                if (-not (Test-Path -LiteralPath $accountsDir)) {
                    $null = New-Item -ItemType Directory -Force -Path $accountsDir -ErrorAction SilentlyContinue
                }
                $lastApprovalFile = Join-Path $accountsDir 'last-approval.json'
                $lastApproval = [ordered]@{
                    at      = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
                    agent   = $resolvedAgent
                    model   = $resolvedModel
                    context = $PromptContext
                    host    = $HostName
                    code    = $code
                    state   = 'approved'
                }
                # 0600 via the private-file write: the record carries the
                # approval code (L11).
                Write-MainframePrivateFile -Path $lastApprovalFile -Content ($lastApproval | ConvertTo-Json -Compress) | Out-Null
            } catch {}
            return $pw
        } else {
            $null = Send-VaultRequestExpired -Sid $sid -HostName $HostName -Code $code -Server $resolvedServer
            Write-MainframeWarning "phone approval timed out after $TimeoutSeconds seconds."
            return $null
        }
    } finally {
        if ($rsa) { $rsa.Dispose() }
        # the turn is always given back: on a password, on a timeout, on a
        # failed push, and on a throw. a queue never stalls behind a dead run.
        Close-VaultApprovalRequest -Path $turn.Path -Token $turn.Token -Approved:$approved
    }
}


# ======================================================================
# functions from vault-secret.psm1
# ======================================================================

function Get-BwEmailKeyMaterial {
    param([securestring]$Password, [byte[]]$Salt, [int]$Iterations)
    $plain = [System.Net.NetworkCredential]::new('', $Password).Password
    $pwBytes = [System.Text.Encoding]::UTF8.GetBytes($plain)
    $kdf = [System.Security.Cryptography.Rfc2898DeriveBytes]::new($pwBytes, $Salt, $Iterations, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
    try { return ,$kdf.GetBytes(64) } finally { $kdf.Dispose() }
}

function Unseal-BwEmail {
    <#
    .SYNOPSIS
        unseal the vault account email from a bw-email.enc.json blob.

    .DESCRIPTION
        the blob is ciphertext only: PBKDF2-HMAC-SHA256 (600k
        iterations) over the master password, AES-256-CBC, HMAC-SHA256 over
        salt|iv|ciphertext. a fresh machine never has to type the email
        address - the master password is enough.

        the LIVE blob lives in the profile root
        (~/.config/mainframe/bw-email.enc.json); the copy in the public
        repo root is a LEGACY fallback only (H2 - it is an offline oracle
        for the master password in a public repo). callers resolve which
        blob to unseal through Get-VaultAccountEmail, never by path alone.

        it lives in this module so windows and linux unseal it the same way
        (it used to be a pair of functions inside boot.ps1 only, and linux
        had its own copy in python).
    #>
    param([string]$BlobPath, [securestring]$Password)
    try {
        $blob = Get-Content -LiteralPath $BlobPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $salt = [Convert]::FromBase64String([string]$blob.salt)
        $iv = [Convert]::FromBase64String([string]$blob.iv)
        $ct = [Convert]::FromBase64String([string]$blob.ct)
        $macExpected = [Convert]::FromBase64String([string]$blob.mac)
        $km = Get-BwEmailKeyMaterial -Password $Password -Salt $salt -Iterations ([int]$blob.iter)
        $encKey = New-Object byte[] 32; [Array]::Copy($km, 0, $encKey, 0, 32)
        $macKey = New-Object byte[] 32; [Array]::Copy($km, 32, $macKey, 0, 32)
        $hmac = [System.Security.Cryptography.HMACSHA256]::new($macKey)
        $macInput = New-Object byte[] ($salt.Length + $iv.Length + $ct.Length)
        [Array]::Copy($salt, 0, $macInput, 0, $salt.Length)
        [Array]::Copy($iv, 0, $macInput, $salt.Length, $iv.Length)
        [Array]::Copy($ct, 0, $macInput, $salt.Length + $iv.Length, $ct.Length)
        $macActual = $hmac.ComputeHash($macInput)
        $hmac.Dispose()
        if ($macExpected.Length -ne $macActual.Length) { return $null }
        $diff = 0
        for ($i = 0; $i -lt $macExpected.Length; $i++) { $diff = $diff -bor ($macExpected[$i] -bxor $macActual[$i]) }
        if ($diff -ne 0) { return $null }
        $aes = [System.Security.Cryptography.Aes]::Create()
        $aes.Key = $encKey; $aes.IV = $iv
        $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
        $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
        $pt = $aes.CreateDecryptor().TransformFinalBlock($ct, 0, $ct.Length)
        $aes.Dispose()
        $email = [System.Text.Encoding]::UTF8.GetString($pt)
        if ($email -match '^[^@\s]+@[^@\s]+\.[^@\s]+$') { return $email }
        return $null
    } catch { return $null }
}

function Get-VaultAccountEmail {
    <#
    .SYNOPSIS
        resolve the bitwarden account email for a login, in order: the
        profile-dir blob, bitwardenEmail in mainframe.config.json, the
        LEGACY repo-root blob, then $env:MAINFRAME_BW_EMAIL. throws LOUDLY,
        naming the missing profile blob, when no source yields an email.
    .DESCRIPTION
        a blob that exists but does not unseal (wrong password for it) does
        NOT stop the lookup: the next source is tried, because the email is
        the same whichever source carries it. the legacy repo blob warns
        loudly every time it actually supplies the email - it is an offline
        oracle for the master password in a PUBLIC repo, and a machine that
        still relies on it needs its profile copy restored.
    #>
    param(
        [Parameter(Mandatory = $true)][securestring]$Password,
        [string]$Checkout = (Split-Path $PSScriptRoot -Parent)
    )

    # 1. the profile-dir blob - the live copy, never in the repo.
    $profileBlob = Join-Path (Get-MainframeProfileRoot) 'bw-email.enc.json'
    if (Test-Path -LiteralPath $profileBlob) {
        $email = Unseal-BwEmail -BlobPath $profileBlob -Password $Password
        if ($email) { return $email }
    }
    # 2. bitwardenEmail in mainframe.config.json - already plaintext there.
    $configured = Get-MainframeConfigValue -Key 'bitwardenEmail'
    if ($configured -and ($configured -match '^[^@\s]+@[^@\s]+\.[^@\s]+$')) { return $configured.Trim() }
    # 3. LEGACY: the repo-root blob, for machines mid-transition only.
    $repoBlob = Join-Path $Checkout 'bw-email.enc.json'
    if (Test-Path -LiteralPath $repoBlob) {
        $email = Unseal-BwEmail -BlobPath $repoBlob -Password $Password
        if ($email) {
            Write-MainframeWarning "the account email came from the LEGACY repo blob $repoBlob (public repo - an offline oracle for the master password). copy it to $profileBlob and remove the repo copy."
            return $email
        }
    }
    # 4. explicit operator override.
    if ($env:MAINFRAME_BW_EMAIL) { return ([string]$env:MAINFRAME_BW_EMAIL).Trim() }
    throw "the bw CLI is logged out and the account email could not be resolved: no profile blob at $profileBlob, no bitwardenEmail in mainframe.config.json, no usable repo blob, and MAINFRAME_BW_EMAIL is unset. restore the profile blob ($profileBlob) or set bitwardenEmail."
}

function New-VaultPasswordFile {
    <#
    .SYNOPSIS
        write the master password to a 0600 temp file for `bw
        --passwordfile` (L13): bw reads the password as the file's first
        line, so it never sits in the process environment where any
        same-user process can read /proc/<pid>/environ.
    .DESCRIPTION
        the caller MUST delete the file with Remove-VaultPasswordFile in a
        finally block - the file holds the master password in the clear.
    #>
    param([Parameter(Mandatory = $true)][string]$Password)

    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("bw-pw-$PID-$([guid]::NewGuid().ToString('N').Substring(0, 8)).txt")
    [IO.File]::WriteAllText($tmp, $Password + "`n", (New-Object System.Text.UTF8Encoding($false)))
    Set-MainframeFileOwnerOnly -Path $tmp
    return $tmp
}

function Remove-VaultPasswordFile {
    <#
    .SYNOPSIS
        delete a password file made by New-VaultPasswordFile, overwriting
        its bytes first (best-effort - the overwrite does not reach the
        page cache or a copy made earlier, it just leaves nothing in the
        file itself).
    #>
    param([string]$Path)

    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return }
    try {
        $len = (Get-Item -LiteralPath $Path).Length
        if ($len -gt 0) {
            [IO.File]::WriteAllBytes($Path, (New-Object byte[] $len))
        }
    } catch {}
    Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
}

function Get-VaultSessionTtlMinutes {
    # 1. Check if the active session specifies a custom TTL (e.g. 12-hour mobile approval = 720m)
    $sessionFile = Get-MainframeSessionKeyPath
    if ($sessionFile) {
        $ttlFile = [System.IO.Path]::ChangeExtension($sessionFile, '.ttl')
        if (Test-Path -LiteralPath $ttlFile) {
            try {
                $val = [int]((Get-Content -LiteralPath $ttlFile -Raw).Trim())
                if ($val -gt 0) { return $val }
            } catch {}
        }
    }
    if ($env:MAINFRAME_VAULT_TTL_MINUTES) {
        try { return [int]$env:MAINFRAME_VAULT_TTL_MINUTES } catch {}
    }
    # the config lookup lives in this script, so linux reads the
    # profile root the same way windows does.
    foreach ($key in @('vaultTtlMinutes', 'sessionTtlMinutes')) {
        $value = Get-MainframeConfigValue -Key $key
        if ($value) { try { return [int]$value } catch {} }
    }
    return $script:DefaultSessionTtlMinutes
}

function Get-VaultBwServer {
    <#
    .SYNOPSIS
        the bitwarden server the CLI has to talk to.

    .DESCRIPTION
        one place, so windows and linux point the CLI at the same vault:
        $env:MAINFRAME_BW_SERVER wins, then bwServer in mainframe.config.json,
        then the self-hosted vaultwarden instance.
    #>
    if ($env:MAINFRAME_BW_SERVER) { return $env:MAINFRAME_BW_SERVER.TrimEnd('/') }
    $configured = Get-MainframeConfigValue -Key 'bwServer'
    if ($configured) { return $configured.TrimEnd('/') }
    return 'https://vaultwardenn-5is6.onrender.com'
}

function Lock-VaultSession {
    param([string]$BwPath = 'bw')
    # a manual lock cancels the pending scheduled expiry too - the session
    # is already gone, so the job must not fire later against a fresh
    # session (and must not leave an orphan behind).
    try { Unregister-VaultSessionExpiry | Out-Null } catch {}
    $sessionFile = Get-MainframeSessionKeyPath
    if (Test-Path -LiteralPath $sessionFile) {
        Remove-Item -LiteralPath $sessionFile -Force -ErrorAction SilentlyContinue
    }
    $ttlFile = [System.IO.Path]::ChangeExtension($sessionFile, '.ttl')
    if (Test-Path -LiteralPath $ttlFile) {
        Remove-Item -LiteralPath $ttlFile -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -Path 'Env:\BW_SESSION' -ErrorAction SilentlyContinue
    Remove-Item -Path 'Env:\MAINFRAME_VAULT_SESSION_STARTED_UNIX' -ErrorAction SilentlyContinue
    Remove-Item -Path 'Env:\MAINFRAME_VAULT_APPROVED_TTL' -ErrorAction SilentlyContinue
    Clear-VaultSessionCache
    Clear-VaultItemsCache
    & $BwPath lock 2>$null | Out-Null
    Write-Host "Bitwarden vault locked." -ForegroundColor Green
}

function Expire-VaultSession {
    <#
    .SYNOPSIS
        end the vault session: lock the CLI and purge the local session.

    .DESCRIPTION
        expiry means LOCK, not logout (owner's decision, 2026-11-21). the CLI
        stays signed in, the vault is locked, and the local session files are
        purged, so no helper can keep using the old key and the next vault use
        is a phone approval + `bw unlock` - NOT a re-login. the panel shows a
        locked vault instead of "signed out", which is what an expiry looks
        like to the owner.

        what this gives up: `bw logout` used to revoke the CLI's tokens
        server-side and wipe its local data, so a copy of the session key
        taken BEFORE the expiry had nothing left to decrypt. the CLI's local
        encrypted cache now stays on disk, so such a copy can still decrypt
        a copy of that cache. the live session is still dead - the session
        key, the ttl, the env vars and the in-process caches are purged here.

        the local purge never depends on the CLI: session.key, session.ttl
        and the env vars go even when the lock fails (no network, no CLI).
        the lock is verified with `bw status` afterwards - a CLI that is
        still unlocked is reported LOUDLY and locked again, and a CLI that
        is unauthenticated (it wiped its own state earlier) is reported
        LOUDLY too, never silently left half-expired.
    #>
    param([string]$BwPath = 'bw')
    # a manual expire cancels the pending scheduled expiry first - the job
    # is redundant now, and cancelling it keeps the next unlock's job the
    # only one that can fire.
    try { Unregister-VaultSessionExpiry | Out-Null } catch {}
    $sessionFile = Get-MainframeSessionKeyPath
    $locked = $false
    try {
        $lockOut = @(& $BwPath lock 2>&1)
        $locked = ($LASTEXITCODE -eq 0)
        if (-not $locked) {
            Write-MainframeWarning "bw lock failed ($($lockOut -join ' ')) - purging the local session anyway"
        }
    } catch {
        Write-MainframeWarning "bw lock could not run ($_) - purging the local session anyway"
    }
    if (Test-Path -LiteralPath $sessionFile) {
        Remove-Item -LiteralPath $sessionFile -Force -ErrorAction SilentlyContinue
    }
    $ttlFile = [System.IO.Path]::ChangeExtension($sessionFile, '.ttl')
    if (Test-Path -LiteralPath $ttlFile) {
        Remove-Item -LiteralPath $ttlFile -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -Path 'Env:\BW_SESSION' -ErrorAction SilentlyContinue
    Remove-Item -Path 'Env:\MAINFRAME_VAULT_SESSION_STARTED_UNIX' -ErrorAction SilentlyContinue
    Remove-Item -Path 'Env:\MAINFRAME_VAULT_APPROVED_TTL' -ErrorAction SilentlyContinue
    Clear-VaultSessionCache
    Clear-VaultItemsCache
    try {
        $status = & $BwPath status 2>$null | Out-String | ConvertFrom-Json
        if ($status) {
            if ($status.status -eq 'unlocked') {
                Write-MainframeWarning "the vault session did NOT expire - bw status is still 'unlocked' after the lock; locking again"
                & $BwPath lock 2>$null | Out-Null
            } elseif ($status.status -eq 'unauthenticated') {
                Write-MainframeWarning "the CLI is unauthenticated after the expiry (it wiped its own state earlier) - the vault is locked, but the next use needs a full login"
            }
        }
    } catch {
        Write-MainframeWarning "could not verify the lock with bw status ($_) - the local session is purged, the cli state is unconfirmed"
    }
    Write-Host "vault session expired (locked - the cli stays signed in)." -ForegroundColor Green
    return $locked
}

function Get-VaultSessionExpiryStatePath {
    return (Join-Path (Split-Path (Get-MainframeSessionKeyPath)) 'expiry.json')
}

function Get-VaultSessionKeyHash {
    param([Parameter(Mandatory = $true)][string]$SessionKey)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($SessionKey.Trim())
        $hash = $sha.ComputeHash($bytes)
        return ([BitConverter]::ToString($hash)).Replace('-', '').ToLowerInvariant().Substring(0, 16)
    } finally { $sha.Dispose() }
}

function Get-VaultSessionExpiryState {
    $statePath = Get-VaultSessionExpiryStatePath
    if (-not (Test-Path -LiteralPath $statePath)) { return $null }
    try { return (Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json) } catch { return $null }
}

function Invoke-VaultExpiryNativeCommand {
    param([string]$Command, [string[]]$Arguments)
    try {
        $out = @(& $Command @Arguments 2>&1)
        return @{ ExitCode = $LASTEXITCODE; Output = ($out -join ' ') }
    } catch {
        return @{ ExitCode = -1; Output = "$_" }
    }
}

function Register-VaultSessionExpirySchTasks {
    param([datetime]$ExpiresAt, [string]$PwshPath, [string]$WrapperPath, [string]$ProfileRoot, [string]$BwPath)
    if (-not (Get-Command schtasks -ErrorAction SilentlyContinue)) { return $false }
    # schtasks ONCE is minute-granular: round the trigger UP to the next
    # minute boundary, so the job never fires before the TTL mark (at most
    # ~1 minute late). /SD is required - without it schtasks assumes today,
    # and a 12h expiry would fire up to 12h early. /SD parses in the
    # system locale, so format the date with the current culture.
    $trigger = $ExpiresAt.AddSeconds(-$ExpiresAt.Second)
    if ($trigger -le $ExpiresAt) { $trigger = $trigger.AddMinutes(1) }
    $culture = Get-Culture
    $dateStr = $trigger.ToString($culture.DateTimeFormat.ShortDatePattern, $culture)
    $timeStr = $trigger.ToString('HH:mm', [System.Globalization.CultureInfo]::InvariantCulture)
    # the FULL pwsh path, never bare `pwsh`: bare pwsh is not on PATH in
    # the scheduled-task context (the MojifyReload task failed exactly
    # this way, Last Result -2147024894 = file not found).
    $tr = "`"$PwshPath`" -NoProfile -NonInteractive -File `"$WrapperPath`" vault expire -ProfileRoot `"$ProfileRoot`" -BwPath `"$BwPath`""
    $result = Invoke-VaultExpiryNativeCommand -Command 'schtasks' -Arguments @('/Create', '/TN', 'MainframeVaultExpiry', '/TR', $tr, '/SC', 'ONCE', '/SD', $dateStr, '/ST', $timeStr, '/F')
    if ($result.ExitCode -ne 0) {
        Write-MainframeWarning "schtasks could not create the expiry task ($($result.Output))"
        return $false
    }
    return $true
}

function Register-VaultSessionExpirySystemd {
    param([int]$Seconds, [string]$PwshPath, [string]$WrapperPath, [string]$ProfileRoot, [string]$BwPath)
    if (-not (Get-Command systemd-run -ErrorAction SilentlyContinue)) { return $false }
    # measured 2026-11-15 on this VM: a systemd-run transient service runs
    # with an EMPTY HOME and a private /tmp, so HOME (and XDG_CONFIG_HOME
    # when set) must be passed explicitly or `bw` cannot find its CLI
    # state. transient units self-remove after firing (verified), and a
    # duplicate unit name fails, so registration always unregisters first.
    $homeDir = if ($env:HOME) { $env:HOME } else { [Environment]::GetFolderPath('UserProfile') }
    $arguments = @("--on-active=$($Seconds)s", '--unit=mainframe-vault-expiry', '--description=mainframe vault session expiry')
    if ($homeDir) { $arguments += "--setenv=HOME=$homeDir" }
    if ($env:XDG_CONFIG_HOME) { $arguments += "--setenv=XDG_CONFIG_HOME=$($env:XDG_CONFIG_HOME)" }
    $arguments += $PwshPath
    $arguments += @('-NoProfile', '-NonInteractive', '-File', $WrapperPath, 'vault', 'expire', '-ProfileRoot', $ProfileRoot, '-BwPath', $BwPath)
    $result = Invoke-VaultExpiryNativeCommand -Command 'systemd-run' -Arguments $arguments
    if ($result.ExitCode -ne 0) {
        Write-MainframeWarning "systemd-run could not create the expiry timer ($($result.Output))"
        return $false
    }
    return $true
}

function Register-VaultSessionExpirySleeper {
    param([int]$Seconds, [string]$PwshPath, [string]$WrapperPath, [string]$ProfileRoot, [string]$BwPath)
    $logDir = Split-Path (Get-MainframeSessionKeyPath)
    # one pre-built argument string, not an array: Windows PowerShell 5.1
    # joins an array with bare spaces (paths with spaces break), while a
    # single string is passed verbatim on both editions.
    $arguments = "-NoProfile -NonInteractive -File `"$WrapperPath`" vault expire -ProfileRoot `"$ProfileRoot`" -BwPath `"$BwPath`" -DelaySeconds $Seconds"
    $startArgs = @{
        FilePath               = $PwshPath
        ArgumentList           = $arguments
        RedirectStandardOutput = (Join-Path $logDir 'expiry.log')
        RedirectStandardError  = (Join-Path $logDir 'expiry.err.log')
        PassThru               = $true
    }
    if ($env:OS -eq 'Windows_NT') { $startArgs['WindowStyle'] = 'Hidden' }
    try {
        return (Start-Process @startArgs)
    } catch {
        Write-MainframeWarning "could not start the expiry sleeper ($_) "
        return $null
    }
}

function Register-VaultSessionExpiry {
    <#
    .SYNOPSIS
        schedule the real expiry of the current session at its TTL mark.

    .DESCRIPTION
        registers a one-shot job (schtasks on windows, a systemd transient
        timer on linux, a detached sleeper as fallback) that runs
        mainframe.ps1 vault expire at unlock + TTL, which calls the full
        Expire-VaultSession (bw lock + purge + verify). the job's state
        (expiry time, TTL, session key hash, session mtime, mechanism) is
        recorded 0600 in expiry.json next to session.key, so the wrapper
        can refuse to expire a session that was re-unlocked after the job
        was registered.

        replace-on-register: any pending job is cancelled FIRST, then the
        new one is registered, under a fixed name - a stale job can never
        fire early and kill a fresh session.

        best-effort from the unlock's perspective: returns $false (and
        warns loudly) when no mechanism works, and the unlock still
        succeeds - the lazy check in Get-VaultSession is the backstop.
        -Mechanism forces one mechanism (used by the tests, which fake the
        scheduler binaries on PATH); Auto tries the platform order.
    #>
    param(
        [Parameter(Mandatory = $true)][int]$TtlMinutes,
        [string]$SessionKey,
        [ValidateSet('Auto', 'SchTasks', 'Systemd', 'Sleeper')][string]$Mechanism = 'Auto'
    )
    if ($TtlMinutes -le 0) { return $false }
    $sessionFile = Get-MainframeSessionKeyPath
    if (-not (Test-Path -LiteralPath $sessionFile)) { return $false }

    $wrapperPath = Join-Path $PSScriptRoot 'mainframe.ps1'
    if (-not (Test-Path -LiteralPath $wrapperPath)) {
        Write-MainframeWarning "scheduled expiry unavailable: the wrapper is missing at $wrapperPath"
        return $false
    }

    $keyForHash = if ([string]::IsNullOrWhiteSpace($SessionKey)) { (Get-Content -LiteralPath $sessionFile -Raw).Trim() } else { $SessionKey.Trim() }
    $fileInfo = Get-Item -LiteralPath $sessionFile
    $expiresAt = (Get-Date).AddMinutes($TtlMinutes)
    $seconds = $TtlMinutes * 60

    # replace-on-register: cancel the old entry FIRST.
    try { Unregister-VaultSessionExpiry | Out-Null } catch {}

    $pwshPath = (Get-Process -Id $PID).Path
    $profileRoot = Get-MainframeProfileRoot
    $bwPath = 'bw'
    $bwCmd = Get-Command bw -ErrorAction SilentlyContinue
    if ($bwCmd -and $bwCmd.Source) { $bwPath = $bwCmd.Source }

    # NOTE: named $onWindows, not $isWindows - $IsWindows is a read-only
    # automatic variable and the name is case-insensitive, so $isWindows
    # = ... throws in a dot-sourced script (it only worked in the old
    # module because a module's session state let it shadow).
    $onWindows = ($env:OS -eq 'Windows_NT')
    $order = if ($Mechanism -eq 'Auto') {
        if ($onWindows) { @('SchTasks', 'Sleeper') } else { @('Systemd', 'Sleeper') }
    } else {
        @($Mechanism)
    }

    $chosen = $null
    $sleeper = $null
    foreach ($candidate in $order) {
        switch ($candidate) {
            'SchTasks' {
                if (Register-VaultSessionExpirySchTasks -ExpiresAt $expiresAt -PwshPath $pwshPath -WrapperPath $wrapperPath -ProfileRoot $profileRoot -BwPath $bwPath) { $chosen = 'schtasks' }
            }
            'Systemd' {
                if (Register-VaultSessionExpirySystemd -Seconds $seconds -PwshPath $pwshPath -WrapperPath $wrapperPath -ProfileRoot $profileRoot -BwPath $bwPath) { $chosen = 'systemd' }
            }
            'Sleeper' {
                $sleeper = Register-VaultSessionExpirySleeper -Seconds $seconds -PwshPath $pwshPath -WrapperPath $wrapperPath -ProfileRoot $profileRoot -BwPath $bwPath
                if ($sleeper) { $chosen = 'sleeper' }
            }
        }
        if ($chosen) { break }
    }
    if (-not $chosen) {
        Write-MainframeWarning "no scheduled-expiry mechanism worked on this machine (tried: $($order -join ', ')) - the lazy expiry check on next vault use is the only backstop"
        return $false
    }

    $state = [ordered]@{
        expiresAtUnix     = [DateTimeOffset]::UtcNow.AddMinutes($TtlMinutes).ToUnixTimeSeconds()
        ttlMinutes        = $TtlMinutes
        sessionHash       = Get-VaultSessionKeyHash -SessionKey $keyForHash
        sessionMtimeUnix  = [DateTimeOffset]::new($fileInfo.LastWriteTimeUtc).ToUnixTimeSeconds()
        mechanism         = $chosen
        taskName          = 'MainframeVaultExpiry'
        unitName          = 'mainframe-vault-expiry'
        sleeperPid        = if ($sleeper) { $sleeper.Id } else { $null }
        sleeperStartedUnix = if ($sleeper) { [DateTimeOffset]::new($sleeper.StartTime.ToUniversalTime()).ToUnixTimeSeconds() } else { $null }
        pwshPath          = $pwshPath
        wrapperPath       = $wrapperPath
        profileRoot       = $profileRoot
        bwPath            = $bwPath
        registeredAtUnix  = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    }
    $statePath = Get-VaultSessionExpiryStatePath
    New-Item -ItemType Directory -Force -Path (Split-Path $statePath) | Out-Null
    Write-MainframePrivateFile -Path $statePath -Content ($state | ConvertTo-Json -Depth 4) | Out-Null
    Write-Host "vault session will expire automatically at $($expiresAt.ToString('yyyy-MM-dd HH:mm')) (in $TtlMinutes minutes, via $chosen)" -ForegroundColor Green
    return $true
}

function Unregister-VaultSessionExpiry {
    <#
    .SYNOPSIS
        cancel the pending scheduled expiry, if any. never throws.

    .DESCRIPTION
        removes the job for the mechanism recorded in expiry.json (schtasks
        /Delete, systemctl stop of the TIMER only - never the service, which
        is the wrapper itself while firing - or killing the sleeper - the
        sleeper is only killed when its start time matches the recorded one,
        so a reused PID is never killed), then deletes expiry.json. with no
        state file it still attempts the schtasks + systemd removals by
        fixed name (a job whose state file was deleted by hand must not
        survive); a sleeper without state cannot be found and is left to
        its wrapper guard, which stands down on a fresh session.
    #>
    $state = Get-VaultSessionExpiryState
    $mechanisms = if ($state -and $state.mechanism) { @([string]$state.mechanism) } else { @('schtasks', 'systemd') }
    foreach ($mechanism in $mechanisms) {
        switch ($mechanism) {
            'schtasks' {
                if (Get-Command schtasks -ErrorAction SilentlyContinue) {
                    $null = Invoke-VaultExpiryNativeCommand -Command 'schtasks' -Arguments @('/Delete', '/TN', 'MainframeVaultExpiry', '/F')
                }
            }
            'systemd' {
                if (Get-Command systemctl -ErrorAction SilentlyContinue) {
                    # stop ONLY the timer, never the service: the service is
                    # the wrapper itself while it is firing, and stopping it
                    # kills the wrapper mid-expiry (proven 2026-11-15: the
                    # journal showed the service stopping the same second
                    # the wrapper printed "expiring it", and nothing after
                    # it ran). the service is transient and exits on its
                    # own; the pending job is the timer, and stopping a
                    # fired timer is a harmless no-op.
                    $null = Invoke-VaultExpiryNativeCommand -Command 'systemctl' -Arguments @('stop', 'mainframe-vault-expiry.timer')
                }
            }
            'sleeper' {
                if ($state -and $state.sleeperPid) {
                    try {
                        $sleeperPid = [int]$state.sleeperPid
                        if ($sleeperPid -eq $PID) {
                            # never suicide: the caller IS the sleeper (the
                            # wrapper expiring its own session calls Expire,
                            # which unregisters) - just drop the state file
                            # below and let this process finish and exit.
                        } else {
                            $proc = Get-Process -Id $sleeperPid -ErrorAction Stop
                            $startedUnix = [DateTimeOffset]::new($proc.StartTime.ToUniversalTime()).ToUnixTimeSeconds()
                            if ($null -eq $state.sleeperStartedUnix -or [math]::Abs($startedUnix - [long]$state.sleeperStartedUnix) -le 2) {
                                # Kill + WaitForExit (not Stop-Process): the wait
                                # reaps the child, so it is really gone when
                                # Unregister returns - Stop-Process returns
                                # before the process exits and a zombie lingers.
                                $proc.Kill()
                                $null = $proc.WaitForExit(5000)
                            }
                        }
                    } catch {}
                }
            }
        }
    }
    $statePath = Get-VaultSessionExpiryStatePath
    if (Test-Path -LiteralPath $statePath) {
        Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue
    }
    return $true
}

function Invoke-VaultSessionExpiryCheck {
    <#
    .SYNOPSIS
        the scheduled-expiry entry point: expire the session if it is due,
        otherwise stand down. called by mainframe.ps1 vault expire.

    .DESCRIPTION
        guards (a stale job must NEVER kill a fresh session):
        - no session file -> nothing to expire (a manual lock or an earlier
          expiry already handled it).
        - session file younger than the recorded TTL -> the user re-unlocked
          after this job was registered; stand down.
        - session key hash or mtime differs from the recorded values -> the
          session was re-unlocked after this job was registered; stand down.
        - no state file -> fall back to the lazy rule (file age vs
          Get-VaultSessionTtlMinutes); the job still expires the session
          if it is due.
        always unregisters the pending job before returning (self-cleanup),
        so no orphaned task/timer/sleeper is left behind. returns
        'expired', 'skipped-fresh', or 'skipped-missing'.
    #>
    param([string]$BwPath = 'bw')
    $sessionFile = Get-MainframeSessionKeyPath
    $state = Get-VaultSessionExpiryState
    $outcome = 'skipped-missing'
    try {
        if (-not (Test-Path -LiteralPath $sessionFile)) {
            Write-Host 'scheduled expiry: no session file - nothing to expire (already locked or expired).'
            $outcome = 'skipped-missing'
        } else {
            $fileInfo = Get-Item -LiteralPath $sessionFile
            $ageMinutes = ((Get-Date) - $fileInfo.LastWriteTime).TotalMinutes
            $ttlMinutes = if ($state -and $state.ttlMinutes) { [int]$state.ttlMinutes } else { Get-VaultSessionTtlMinutes }
            $key = (Get-Content -LiteralPath $sessionFile -Raw).Trim()
            $hashOk = $true
            if ($state -and $state.sessionHash) {
                $hashOk = ((Get-VaultSessionKeyHash -SessionKey $key) -eq [string]$state.sessionHash)
            }
            $mtimeOk = $true
            if ($state -and $state.sessionMtimeUnix) {
                $mtimeOk = ([DateTimeOffset]::new($fileInfo.LastWriteTimeUtc).ToUnixTimeSeconds() -eq [long]$state.sessionMtimeUnix)
            }
            if ($ttlMinutes -gt 0 -and $ageMinutes -ge $ttlMinutes -and $hashOk -and $mtimeOk) {
                Write-Host "scheduled expiry: session is $([math]::Round($ageMinutes))m old (>= ${ttlMinutes}m TTL) - expiring it (lock + purge)."
                Expire-VaultSession -BwPath $BwPath | Out-Null
                $outcome = 'expired'
            } else {
                $reason = if (-not $hashOk -or -not $mtimeOk) { 'the session was re-unlocked after this job was registered' } else { "the session is only $([math]::Round($ageMinutes))m old (< ${ttlMinutes}m TTL)" }
                Write-Host "scheduled expiry: standing down - $reason."
                $outcome = 'skipped-fresh'
            }
        }
    } finally {
        try { Unregister-VaultSessionExpiry | Out-Null } catch {}
    }
    return $outcome
}

function Get-VaultSession {
    $sessionFile = Get-MainframeSessionKeyPath
    $ttlMinutes = Get-VaultSessionTtlMinutes

    if (Test-Path -LiteralPath $sessionFile) {
        $fileInfo = Get-Item -LiteralPath $sessionFile
        $age = (Get-Date) - $fileInfo.LastWriteTime

        if ($ttlMinutes -gt 0 -and $age.TotalMinutes -ge $ttlMinutes) {
            Write-Host "vault session expired ($([math]::Round($age.TotalMinutes))m >= ${ttlMinutes}m TTL) - expiring it (lock + purge)" -ForegroundColor Yellow
            Expire-VaultSession | Out-Null
            return $null
        }

        # the file is the age authority: stamp its mtime into the env
        # marker, so a BW_SESSION copied from this file later carries a
        # provable age (see the env branch below).
        $env:MAINFRAME_VAULT_SESSION_STARTED_UNIX = [string][DateTimeOffset]::new($fileInfo.LastWriteTimeUtc).ToUnixTimeSeconds()
        return (Get-Content -LiteralPath $sessionFile -Raw).Trim()
    }

    if ($env:BW_SESSION) {
        # env-only session: the file (the age authority) is gone, so the
        # start marker is the ONLY proof of age. an env var with no marker
        # was set by something other than a mainframe unlock (a manual
        # export, a copied value) and its age is unknowable - it could be
        # a session that expired long ago, kept alive only because env vars
        # have no mtime. refuse it, clear it in-process so nothing else
        # here can use it either, and force a fresh unlock. the marker is
        # set by Get-VaultSession itself (from the file mtime, above) and
        # by Ensure-VaultSession at unlock, and it propagates to child
        # processes with BW_SESSION, so a legitimately unlocked session
        # always carries one.
        $startedRaw = $env:MAINFRAME_VAULT_SESSION_STARTED_UNIX
        if ([string]::IsNullOrWhiteSpace($startedRaw)) {
            Write-MainframeWarning "BW_SESSION is set but its age is unknown (no session file and no start marker) - refusing it. unlock again through the approval flow."
            Remove-Item -Path 'Env:\BW_SESSION' -ErrorAction SilentlyContinue
            return $null
        }
        $startedUnix = 0
        if (-not [long]::TryParse($startedRaw.Trim(), [ref]$startedUnix)) {
            Write-MainframeWarning "BW_SESSION start marker is unreadable ('$startedRaw') - refusing the env session. unlock again through the approval flow."
            Remove-Item -Path 'Env:\BW_SESSION' -ErrorAction SilentlyContinue
            return $null
        }
        $ageMinutes = ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $startedUnix) / 60.0
        if ($ttlMinutes -gt 0 -and $ageMinutes -ge $ttlMinutes) {
            Write-Host "vault session expired (env session age $([math]::Round($ageMinutes))m >= ${ttlMinutes}m TTL) - expiring it (lock + purge)" -ForegroundColor Yellow
            Expire-VaultSession | Out-Null
            return $null
        }
        return [string]$env:BW_SESSION
    }

    return $null
}

function Test-VaultSession {
    $session = Get-VaultSession
    if ([string]::IsNullOrWhiteSpace($session)) {
        return $false
    }

    # cache a positive result per session so repeated calls (e.g. status-all
    # iterating every profile) don't spawn `bw status` each time.
    if ($script:VaultSessionOkSession -eq $session) {
        return $true
    }

    $env:BW_SESSION = $session
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        try {
            $rawStatus = bw status --session $session 2>$null
            if ($rawStatus) {
                $status = $rawStatus | ConvertFrom-Json
                if ($status.status -eq 'unlocked') {
                    $script:VaultSessionOkSession = $session
                    return $true
                } elseif ($status.status -in @('locked', 'unauthenticated')) {
                    return $false
                }
            }
        } catch {}
        if ($attempt -lt 2) {
            Start-Sleep -Milliseconds 300
        }
    }
    return $false
}

function Invoke-VaultLogin {
    <#
    .SYNOPSIS
        log the bw CLI in with the master password - only needed when the CLI
        is unauthenticated (it wiped its own state). an expiry now LOCKS the
        CLI, so unlock alone is enough after a normal expiry.

    .DESCRIPTION
        the one login implementation: the account email comes out of
        Get-VaultAccountEmail (profile blob, config bitwardenEmail, legacy
        repo blob, or $env:MAINFRAME_BW_EMAIL), then `bw login`.
        vault unlock and Ensure-VaultSession both call it, so a fresh
        machine and an expired session log in the same way. returns the
        email it logged in as, and throws when the email cannot be resolved
        or the login fails. the password travels via a 0600 temp file
        (--passwordfile), never the process environment (L13).
    #>
    param(
        [string]$BwPath = 'bw',
        [Parameter(Mandatory = $true)][string]$Password,
        [string]$Checkout = (Split-Path $PSScriptRoot -Parent)
    )
    $secure = ConvertTo-SecureString $Password -AsPlainText -Force
    $email = Get-VaultAccountEmail -Password $secure -Checkout $Checkout
    $pwFile = New-VaultPasswordFile -Password $Password
    try {
        & $BwPath login $email --passwordfile $pwFile 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "bw login failed for $email" }
    } finally {
        Remove-VaultPasswordFile -Path $pwFile
    }
    return $email
}

function Ensure-VaultSession {
    param(
        [int]$TimeoutSeconds = 120,
        [switch]$NoPrompt,
        [string]$Agent,
        [string]$Model,
        [string]$PromptContext = 'vault access'
    )

    if (Test-VaultSession) {
        return $true
    }

    if ($NoPrompt) {
        return $false
    }


    if (Get-Command Get-VaultMasterPassword -ErrorAction SilentlyContinue) {
        # Check again right before prompting in case another agent just unlocked
        if (Test-VaultSession) {
            return $true
        }

        $promptStartTimeUtc = [DateTime]::UtcNow
        $ttlMinutes = Get-VaultSessionTtlMinutes
        $ttlDesc = if ($ttlMinutes -ge 60) { "$([math]::Round($ttlMinutes / 60))-hour TTL" } else { "$ttlMinutes-minute TTL" }
        Write-Host "`n==> vault session is locked or expired ($ttlDesc)." -ForegroundColor Yellow
        Write-Host "triggering 1-tap mobile approval prompt on phone..." -ForegroundColor Cyan
        $pw = Get-VaultMasterPassword -PromptContext $PromptContext -TimeoutSeconds $TimeoutSeconds -Agent $Agent -Model $Model -StartTimeUtc $promptStartTimeUtc
        if ($pw -eq '__SESSION_ALREADY_UNLOCKED__') {
            Write-Host "vault was unlocked by another agent - reusing fresh session" -ForegroundColor Green
            return $true
        }
        if ($pw) {
            # an expiry LOCKS the cli (it stays signed in), so the first use
            # after an expiry is an unlock, not a login. a full login is only
            # needed when the cli is unauthenticated - it wiped its own state
            # earlier (a dead refresh token), which unlock alone cannot fix.
            $statusVal = $null
            try {
                $statusRaw = & bw status 2>$null | Out-String
                if ($statusRaw) { $statusVal = ($statusRaw | ConvertFrom-Json).status }
            } catch {}
            if ($statusVal -eq 'unauthenticated') {
                Write-Host 'bw is logged out (it wiped its own state) - logging in again' -ForegroundColor Yellow
                Invoke-VaultLogin -Password $pw | Out-Null
            }
            # the password travels via a 0600 temp file (--passwordfile),
            # never the process environment (L13).
            $pwFile = New-VaultPasswordFile -Password $pw
            try {
                $unlockOut = @(& bw unlock --raw --passwordfile $pwFile 2>&1)
                $rawKey = $unlockOut | Where-Object { $_ -is [string] -and $_ -match '^[A-Za-z0-9+/=]{20,}$' } | Select-Object -Last 1
                if ($rawKey) {
                    $sessionFile = Set-VaultSessionKey -SessionKey $rawKey
                    $env:BW_SESSION = $rawKey.Trim()
                    # the start marker is the env session's proof of age
                    # (Get-VaultSession refuses an unmarked env session once
                    # the file is gone); it propagates to child processes
                    # with BW_SESSION.
                    $env:MAINFRAME_VAULT_SESSION_STARTED_UNIX = [string][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
                    Clear-VaultSessionCache
                    Clear-VaultItemsCache
                    # self-heal (C1): the unlock just proved a live session,
                    # so cache the shared approval signing key now if this
                    # machine does not have it yet - the next approval is
                    # signed from the first tap. best-effort, never fails
                    # the unlock.
                    try {
                        if (Get-Command Sync-VaultApprovalSigningKeyFromVault -ErrorAction SilentlyContinue) {
                            $null = Sync-VaultApprovalSigningKeyFromVault -Session $rawKey.Trim()
                        }
                    } catch {}
                    $activeTtl = Get-VaultSessionTtlMinutes
                    $sessionDesc = if ($activeTtl -gt 60) {
                        "$([math]::Round($activeTtl / 60))-hour session ($activeTtl minutes TTL)"
                    } else {
                        "1-hour session"
                    }
                    Write-Host "vault unlocked successfully with fresh $sessionDesc" -ForegroundColor Green
                    return $true
                } else {
                    Write-MainframeWarning "bw unlock did not return a valid session key: $($unlockOut -join ' ')"
                }
            } finally {
                Remove-VaultPasswordFile -Path $pwFile
                $pw = $null
            }
        }
    }

    return $false
}

function Set-VaultSessionKey {
    <#
    .SYNOPSIS
        cache the raw bw session key, 0600, where both platforms look for it.

    .DESCRIPTION
        the file lives in the profile root (mainframe-paths.psm1), so windows
        and linux share ONE session cache location - the same file, the same
        TTL, the same rules.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$SessionKey,
        [int]$TtlMinutes = 0
    )

    if ($TtlMinutes -le 0 -and $env:MAINFRAME_VAULT_APPROVED_TTL) {
        try { $TtlMinutes = [int]$env:MAINFRAME_VAULT_APPROVED_TTL } catch {}
    }

    $sessionFile = Get-MainframeSessionKeyPath
    New-Item -ItemType Directory -Force -Path (Split-Path $sessionFile) | Out-Null
    # no world-readable window (L12): the key lands in a 0600 temp file
    # first and is moved over the target, so session.key is never created
    # with default perms and then tightened - it only ever appears already
    # 0600.
    Write-MainframePrivateFile -Path $sessionFile -Content $SessionKey.Trim() | Out-Null

    $ttlFile = [System.IO.Path]::ChangeExtension($sessionFile, '.ttl')
    if ($TtlMinutes -gt 0) {
        Write-MainframePrivateFile -Path $ttlFile -Content ([string]$TtlMinutes) | Out-Null
        Write-Host "session TTL set to $TtlMinutes minutes ($([math]::Round($TtlMinutes / 60)) hours) at $ttlFile" -ForegroundColor Green
    } else {
        Remove-Item -LiteralPath $ttlFile -Force -ErrorAction SilentlyContinue
    }

    # time-based expiry is ENFORCED (user order 2026-11-22): every unlock
    # registers the one-shot job that runs the full Expire-VaultSession at
    # the TTL mark. best-effort - a failed registration must never fail
    # the unlock; the lazy check in Get-VaultSession is the backstop, and
    # Register warns loudly.
    $effectiveTtl = $TtlMinutes
    if ($effectiveTtl -le 0) { $effectiveTtl = Get-VaultSessionTtlMinutes }
    if ($effectiveTtl -gt 0) {
        try {
            $scheduled = Register-VaultSessionExpiry -TtlMinutes $effectiveTtl -SessionKey $SessionKey
            if (-not $scheduled) {
                Write-MainframeWarning 'could not register the scheduled expiry for this session - the lazy expiry check on next vault use is the only backstop'
            }
        } catch {
            Write-MainframeWarning "scheduled-expiry registration failed ($_) - the lazy expiry check on next vault use is the only backstop"
        }
    }
    return $sessionFile
}

function Clear-VaultSessionCache {
    $script:VaultSessionOkSession = $null
}

function ConvertTo-VaultItemList {
    <#
    .SYNOPSIS
        flatten the `bw list items` json into a plain list of items.

    .DESCRIPTION
        windows powershell 5.1 and pwsh 7 disagree here. 5.1 hands the whole
        json array over as ONE object, 7 enumerates it. without this, every
        consumer on 5.1 walks a NESTED array: $item.name then returns the
        names of ALL items at once, and a lookup can quietly return the wrong
        item. always go through here.
    #>
    param([AllowNull()][string]$Json)

    return ConvertFrom-JsonArray -Json $Json
}

function Get-VaultItems {
    if (-not (Ensure-VaultSession)) {
        throw 'Bitwarden vault is locked or approval was not completed. Use 1-tap mobile approval or run automata-private\bitwarden.com\unlock.ps1.'
    }

    $session = Get-VaultSession
    if ($null -ne $script:VaultItemsCache -and $script:VaultItemsCacheSession -eq $session) {
        return $script:VaultItemsCache
    }

    $raw = bw list items --session $env:BW_SESSION 2>$null | Out-String
    $items = ConvertTo-VaultItemList -Json $raw
    $script:VaultItemsCache = $items
    $script:VaultItemsCacheSession = $session
    return $items
}

function Clear-VaultItemsCache {
    $script:VaultItemsCache = $null
    $script:VaultItemsCacheSession = $null
}

function Find-VaultItemByEmail {
    param(
        [string]$Email,
        [string[]]$NamePattern = '*'
    )

    $normalizedEmail = $Email.Trim().ToLowerInvariant()
    $items = Get-VaultItems

    # primary: login.username matches the email exactly
    $item = $items | Where-Object {
        $vaultItem = $_
        (@($NamePattern | Where-Object { $vaultItem.name -like $_ }).Count -gt 0) -and
        $vaultItem.login.username -and
        ([string]$vaultItem.login.username).Trim().ToLowerInvariant() -eq $normalizedEmail
    } | Select-Object -First 1
    if ($item) {
        return $item
    }

    # fallback: notes contain the email on its own line (github/uptimerobot convention)
    $item = $items | Where-Object {
        $vaultItem = $_
        (@($NamePattern | Where-Object { $vaultItem.name -like $_ }).Count -gt 0) -and
        $vaultItem.notes -and
        (@($vaultItem.notes -split "`r?`n") | Where-Object { $_.Trim().ToLowerInvariant() -eq $normalizedEmail })
    } | Select-Object -First 1
    if ($item) {
        return $item
    }

    return $null
}

function Get-SecretFromNotes {
    param(
        [AllowNull()][string]$Notes,
        [string]$ValueRegex
    )

    if ([string]::IsNullOrWhiteSpace($Notes) -or [string]::IsNullOrWhiteSpace($ValueRegex)) {
        return $null
    }

    if ($Notes -match $ValueRegex) {
        return $Matches[0]
    }

    return $null
}

function Read-VaultSecret {
    param(
        [string]$Email,
        [string[]]$NamePattern,
        [string]$ValueRegex
    )

    $item = Find-VaultItemByEmail -Email $Email -NamePattern $NamePattern
    if (-not $item) {
        return $null
    }

    return Get-SecretFromNotes -Notes $item.notes -ValueRegex $ValueRegex
}

function Update-VaultItemNotes {
    param(
        [string]$ItemId,
        [AllowNull()][string]$NewNotes
    )

    if (-not (Ensure-VaultSession)) {
        throw 'Bitwarden vault is locked or approval was not completed. Run automata-private\bitwarden.com\unlock.ps1, or set $env:BW_SESSION.'
    }

    $item = bw get item $ItemId --session $env:BW_SESSION 2>$null | ConvertFrom-Json
    if (-not $item) {
        throw "Could not load vault item $ItemId"
    }

    if (-not $item.PSObject.Properties['notes']) {
        $item | Add-Member -NotePropertyName notes -NotePropertyValue $NewNotes -Force
    } else {
        $item.notes = $NewNotes
    }

    $item | ConvertTo-Json -Depth 12 | bw encode | bw edit item $ItemId --session $env:BW_SESSION | Out-Null
    Clear-VaultItemsCache
    Clear-VaultSessionCache
}

function New-VaultItem {
    param(
        [string]$Name,
        [AllowNull()][string]$Username,
        [AllowNull()][string]$Uri,
        [AllowNull()][string]$Notes
    )

    if (-not (Ensure-VaultSession)) {
        throw 'Bitwarden vault is locked or approval was not completed. Run automata-private\bitwarden.com\unlock.ps1, or set $env:BW_SESSION.'
    }

    $login = @{ username = $Username; password = $null }
    if ($Uri) {
        $login.uris = @(@{ uri = $Uri })
    }

    $newItem = @{
        type = 1
        name = $Name
        notes = $Notes
        favorite = $false
        fields = @()
        login = $login
    } | ConvertTo-Json -Depth 12

    $created = $newItem | bw encode | bw create item --session $env:BW_SESSION
    $obj = $created | ConvertFrom-Json
    Clear-VaultItemsCache
    Clear-VaultSessionCache
    return $obj.id
}

function Write-VaultSecretToExisting {
    param(
        [string]$Email,
        [string[]]$NamePattern,
        [string]$Header,
        [string]$Value,
        [AllowNull()][string]$ItemName,
        [AllowNull()][string]$Username,
        [AllowNull()][string]$Uri
    )

    $item = Find-VaultItemByEmail -Email $Email -NamePattern $NamePattern
    if (-not $item) {
        if ([string]::IsNullOrWhiteSpace($ItemName)) {
            throw "No vault item found for $Email matching $NamePattern (and no ItemName provided to create one)"
        }
        $newId = New-VaultItem -Name $ItemName -Username $Username -Uri $Uri -Notes "$Header`n$Value"
        return $newId
    }

    $oldNotes = if ($item.notes) { [string]$item.notes } else { '' }
    $newNotes = "$Header`n$Value"

    $remaining = @()
    $oldLines = @($oldNotes -split "`r?`n")
    $skipCount = 0
    for ($i = 0; $i -lt $oldLines.Count; $i++) {
        $line = $oldLines[$i]
        if ($skipCount -gt 0) {
            $skipCount--
            continue
        }
        if ($line.Trim() -eq $Header) {
            # skip the header line and the following value line
            $skipCount = 1
            continue
        }
        $remaining += $line
    }

    $tail = @($remaining | Where-Object { $_ -and $_.Trim() }) -join "`n"
    if ($tail) {
        $newNotes += "`n`n" + $tail
    }

    Update-VaultItemNotes -ItemId $item.id -NewNotes $newNotes
    return $item.id
}


# ======================================================================
# functions from mainframe-sync.psm1
# ======================================================================

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
    # stderr, never stdout - mainframe.ps1 vault unlock prints a JSON document there.
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


# ======================================================================
# functions from vault-flow.ps1
# ======================================================================

function Write-FlowLog {
    param([string]$Message)
    # stderr, so stdout stays a clean JSON document
    [Console]::Error.WriteLine("vault-flow: $Message")
}

function Write-FlowResult {
    <#
    .SYNOPSIS
        publish the result document - on stdout, and to -OutputPath when the
        caller wants to read it from a file instead of parsing a stream.
    #>
    param([object]$Result)
    $json = ConvertTo-Json -InputObject $Result -Compress -Depth 4
    if ($OutputPath) {
        $parent = Split-Path -Parent $OutputPath
        if ($parent -and -not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Force -Path $parent | Out-Null
        }
        Set-Content -LiteralPath $OutputPath -Value $json -Encoding UTF8 -NoNewline
    }
    # the success stream, not the host: a caller that captures stdout gets
    # the document and nothing else.
    Write-Output $json
}

function Get-BwStatus {
    $raw = & $BwPath status 2>$null | Out-String
    if (-not $raw.Trim()) { throw 'bw status produced no output - is the bitwarden CLI installed and on PATH?' }
    return $raw | ConvertFrom-Json
}

function Initialize-BwServer {
    <#
    .SYNOPSIS
        point the bw CLI at the right server, exactly like boot.ps1 does.

    .DESCRIPTION
        a fresh linux box has a bw CLI that knows no server, and one that was
        pointed elsewhere must be moved - otherwise the flow would unlock the
        wrong vault. the server comes from Get-VaultBwServer, so windows and
        linux agree on it.
    #>
    param([string]$BwPath = 'bw')
    $expected = Get-VaultBwServer
    $status = Get-BwStatus
    $current = ([string]$status.serverUrl).TrimEnd('/')
    if ($current -ne $expected) {
        Write-FlowLog "the bw CLI points at '$current' - switching it to '$expected'"
        if ([string]$status.status -ne 'unauthenticated') {
            & $BwPath logout 2>$null | Out-Null
        }
        & $BwPath config server $expected 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "bw config server $expected failed" }
        $status = Get-BwStatus
    }
    return $status
}

function Get-VaultSecretsFromItems {
    <#
    .SYNOPSIS
        pull the github token and the mainframe-production secrets password
        out of the vault items.

    .DESCRIPTION
        the same rules the python implementation used, so the two never drift:
        a github token is `gh[pousr]_...`, an item is preferred when its name
        holds BOTH "github" and the repo owner, and the secrets password is
        the notes of the mainframe-production item.
    #>
    param([object[]]$Items)

    $repoOwner = 'fahadbinhussain'
    $tokenPattern = 'gh[pousr]_[A-Za-z0-9_]{20,}'
    $githubToken = ''
    $secretsPassword = ''

    foreach ($item in $Items) {
        $name = ([string]$item.name).ToLowerInvariant()
        $notes = [string]$item.notes
        if (-not $githubToken -and $name.Contains('github') -and $name.Contains($repoOwner)) {
            if ($notes -match $tokenPattern) { $githubToken = $Matches[0] }
        }
        if (-not $secretsPassword -and $name.Contains('mainframe-production')) {
            $secretsPassword = $notes.Trim()
        }
    }
    if (-not $githubToken) {
        foreach ($item in $Items) {
            $name = ([string]$item.name).ToLowerInvariant()
            if ($name.Contains('github') -and ([string]$item.notes) -match $tokenPattern) {
                $githubToken = $Matches[0]
                break
            }
        }
    }
    return [pscustomobject]@{ GitHubToken = $githubToken; SecretsPassword = $secretsPassword }
}


# ======================================================================
# functions from seal-bw-email.ps1
# ======================================================================

function Seal-BwEmail {
    param([string]$Email, [securestring]$Password)
    $salt = New-Object byte[] 16
    $iv = New-Object byte[] 16
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($salt); $rng.GetBytes($iv); $rng.Dispose()
    $iterations = 600000
    $km = Get-BwEmailKeyMaterial -Password $Password -Salt $salt -Iterations $iterations
    $encKey = New-Object byte[] 32; [Array]::Copy($km, 0, $encKey, 0, 32)
    $macKey = New-Object byte[] 32; [Array]::Copy($km, 32, $macKey, 0, 32)
    $aes = [System.Security.Cryptography.Aes]::Create()
    $aes.Key = $encKey; $aes.IV = $iv
    $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
    $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
    $plainBytes = [System.Text.Encoding]::UTF8.GetBytes($Email)
    $ct = $aes.CreateEncryptor().TransformFinalBlock($plainBytes, 0, $plainBytes.Length)
    $aes.Dispose()
    $macInput = New-Object byte[] ($salt.Length + $iv.Length + $ct.Length)
    [Array]::Copy($salt, 0, $macInput, 0, $salt.Length)
    [Array]::Copy($iv, 0, $macInput, $salt.Length, $iv.Length)
    [Array]::Copy($ct, 0, $macInput, $salt.Length + $iv.Length, $ct.Length)
    $hmac = [System.Security.Cryptography.HMACSHA256]::new($macKey)
    $mac = $hmac.ComputeHash($macInput)
    $hmac.Dispose()
    return [ordered]@{
        v    = 1
        kdf  = 'PBKDF2-HMAC-SHA256'
        iter = $iterations
        salt = [Convert]::ToBase64String($salt)
        iv   = [Convert]::ToBase64String($iv)
        ct   = [Convert]::ToBase64String($ct)
        mac  = [Convert]::ToBase64String($mac)
    }
}


# ======================================================================
# functions from new-bootstrap-link.ps1
# ======================================================================

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
    $matches = @($items | Where-Object { [string]$_.name -eq $script:VaultBootstrapLinkItemName })
    if ($matches.Count -gt 1) {
        # duplicates happen when a bw create/edit "fails" client-side
        # (Premature close / socket hang up) after the server already
        # applied it, and the retry creates another item - measured
        # 2026-11-15 (four same-name link items after one flaky run).
        # picking the first match would silently edit the wrong one,
        # so refuse and name the ids to clean up instead.
        $ids = ($matches | ForEach-Object { [string]$_.id }) -join ', '
        throw "found $($matches.Count) vault items named '$script:VaultBootstrapLinkItemName' (ids: $ids) - refusing to guess which one is the link. delete all but one with 'bw delete item <id>' (keep the one whose link matches the local config), then re-run. nothing was changed."
    }
    return $matches | Select-Object -First 1
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
    # the item is built explicitly: the bw CLI's (2026.10.0) `get
    # template item.securenote` returns just {"type":0} — no
    # name/notes fields to fill in, and the wrong type for a
    # SecureNote (2) — so the template is worse than useless here
    # (measured 2026-11-15: the first real link creation died
    # setting .name on it).
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


# ======================================================================
# functions from rotate-ntfy-topic.ps1
# ======================================================================

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
    $matches = @($items | Where-Object { [string]$_.name -eq $script:VaultNtfyTopicVaultItemName })
    if ($matches.Count -gt 1) {
        # duplicates happen when a bw create/edit "fails" client-side
        # (Premature close / socket hang up) after the server already
        # applied it, and the retry creates another item - measured
        # 2026-11-15 (four same-name bootstrap-link items after one
        # flaky run; the topic item has the same shape). picking the
        # first match would silently edit the wrong one, so refuse and
        # name the ids to clean up instead.
        $ids = ($matches | ForEach-Object { [string]$_.id }) -join ', '
        throw "found $($matches.Count) vault items named '$script:VaultNtfyTopicVaultItemName' (ids: $ids) - refusing to guess which one is the topic. delete all but one with 'bw delete item <id>' (keep the one whose notes match the current topic), then re-run. nothing was changed."
    }
    $item = $matches | Select-Object -First 1
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
    # the item is built explicitly: the bw CLI's (2026.10.0) `get
    # template item.securenote` returns just {"type":0} — no
    # name/notes fields to fill in, and the wrong type for a
    # SecureNote (2) — so the template is worse than useless here
    # (measured 2026-11-15: the first real link creation died
    # setting .name on it, and the rotate script had the same
    # latent call).
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
        return (& $fail "could not re-read the updated profile config ($($_.Exception.Message))" 're-push with: pwsh windows/mainframe.ps1 vault bootstrap-link -PushOnly')
    }
    try {
        $relayBase = Get-BootstrapRelayBase -NtfyServer $cfg.ntfyServer
    } catch {
        return (& $fail "the relay base cannot be derived: $($_.Exception.Message)" 'fix ntfyServer in the local config (it must be the worker relay url ending in /ntfy), then re-push with: pwsh windows/mainframe.ps1 vault bootstrap-link -PushOnly')
    }
    $token = $null
    if ($cfg.bootstrapToken -and (Test-BootstrapTokenFormat -Value $cfg.bootstrapToken)) {
        $token = $cfg.bootstrapToken
    } else {
        try {
            $vaultLink = Get-VaultBootstrapLink -Bw $Bw -SessionArgs $SessionArgs
        } catch {
            return (& $fail "the vault bootstrap-link item could not be read: $($_.Exception.Message)" 'unlock the vault, then re-push with: pwsh windows/mainframe.ps1 vault bootstrap-link -PushOnly')
        }
        if ($vaultLink) {
            $token = Get-BootstrapTokenFromLink -Link $vaultLink
        }
        if (-not $token) {
            return (& $fail 'no bootstrap link was ever created - the local config has no bootstrapToken and the vault holds no bootstrap link' 'create the link once with: pwsh windows/mainframe.ps1 vault bootstrap-link (the rotation itself already happened - vault + local are new, the bundle is stale until the link exists)')
        }
    }
    try {
        $null = Invoke-RestMethod -Uri "$relayBase/bootstrap/$token" -Method Put -Body $bundle -ContentType 'application/json' -TimeoutSec 15 -ErrorAction Stop
    } catch {
        return (& $fail "the relay refused the bundle: $(Get-RestErrorDetail -ErrorRecord $_)" 're-push with: pwsh windows/mainframe.ps1 vault bootstrap-link -PushOnly')
    }
    return [pscustomobject]@{ Success = $true; Message = 'pushed'; Recovery = '' }
}


# ======================================================================
# new in the god script: read-only vault status (no phone, no unlock)
# ======================================================================

function Invoke-VaultStatus {
    <#
    .SYNOPSIS
        read-only vault status: server, lock state, session age.
    #>
    param(
        [string]$BwPath = 'bw',
        [switch]$Json
    )
    # the merged helpers call bare `bw`; point PATH at the binary the
    # caller named when it is a path (same fix as the unlock flow).
    if ($BwPath -match '[\\/]') {
        $bwDir = Split-Path -Parent $BwPath
        if ($bwDir -and (Test-Path -LiteralPath $bwDir)) {
            $env:PATH = "$bwDir$([IO.Path]::PathSeparator)$env:PATH"
        }
    }
    $expected = Get-VaultBwServer
    $status = $null
    try {
        $raw = & $BwPath status 2>$null | Out-String
        if ($raw) { $status = $raw | ConvertFrom-Json }
    } catch { $status = $null }
    $sessionFile = Get-MainframeSessionKeyPath
    $sessionAge = $null; $sessionFresh = $false
    if (Test-Path -LiteralPath $sessionFile) {
        $age = (Get-Date) - (Get-Item -LiteralPath $sessionFile).LastWriteTime
        $sessionAge = [int]$age.TotalMinutes
        $ttl = Get-VaultSessionTtlMinutes
        $sessionFresh = ($ttl -le 0 -or $age.TotalMinutes -lt $ttl)
    }
    # bare `bw status` says "locked" even when the flow's file-cached
    # session is live (the session lives in session.key, not in bw's own
    # state) - so the effective state comes from Test-VaultSession.
    $effective = $false
    try { $effective = Test-VaultSession } catch { $effective = $false }
    $info = [ordered]@{
        serverExpected    = $expected
        serverCurrent     = if ($status) { [string]$status.serverUrl } else { $null }
        serverMatches     = ($status -and ([string]$status.serverUrl).TrimEnd('/') -eq $expected.TrimEnd('/'))
        cliStatus         = if ($status) { [string]$status.status } else { 'unreachable' }
        effectiveUnlocked = $effective
        email             = if ($status) { [string]$status.userEmail } else { $null }
        lastSync          = if ($status) { [string]$status.lastSync } else { $null }
        sessionCached     = (Test-Path -LiteralPath $sessionFile)
        sessionAgeMinutes = $sessionAge
        sessionFresh      = $sessionFresh
    }
    if ($Json) { $info | ConvertTo-Json -Depth 3; return }
    Write-Host "vault server (expected): $($info.serverExpected)"
    Write-Host "vault server (bw CLI):   $($info.serverCurrent)"
    Write-Host "server matches:          $($info.serverMatches)"
    Write-Host "cli status:              $($info.cliStatus)"
    Write-Host "effective (cached session): $($info.effectiveUnlocked)"
    Write-Host "email:                   $($info.email)"
    Write-Host "last sync:               $($info.lastSync)"
    Write-Host "session cached:          $($info.sessionCached)"
    if ($null -ne $sessionAge) { Write-Host "session age:             ${sessionAge} min (fresh: $sessionFresh)" }
}


# ======================================================================
# dispatcher helpers
# ======================================================================

function Convert-RestToArgs {
    # parse the leftover CLI tokens (-Name value / -Switch / --name=value)
    # into a splatting hashtable for the target function, using its own
    # parameter metadata to tell switches from value parameters.
    param([string]$FunctionName, [string[]]$Rest)
    $cmd = Get-Command $FunctionName -CommandType Function -ErrorAction Stop
    $params = $cmd.Parameters
    $out = @{}
    $i = 0
    while ($i -lt $Rest.Count) {
        $tok = $Rest[$i]
        if ($tok -match '^--?([^=:]+)(?:[=:](.*))?$') {
            $name = $Matches[1]
            $inlineVal = $Matches[2]
            # .Contains, not a second -match: -match would overwrite $Matches
            $hasInline = $tok.Contains('=') -or $tok.Contains(':')
            $canon = $params.Keys | Where-Object { $_ -ieq $name } | Select-Object -First 1
            if (-not $canon) { throw "unknown parameter '-$name' for $FunctionName" }
            $isSwitch = ($params[$canon].ParameterType -eq [switch])
            if ($isSwitch) {
                if ($hasInline) {
                    if ($inlineVal -match '^(?i:true|false)$') { $out[$canon] = ($inlineVal -match '(?i)^true$') }
                    else { throw "switch '-$name' takes no value (got '$inlineVal')" }
                } else { $out[$canon] = $true }
                $i++
            } else {
                if ($hasInline) { $out[$canon] = $inlineVal; $i++ }
                else {
                    if ($i + 1 -ge $Rest.Count) { throw "parameter '-$name' needs a value" }
                    $out[$canon] = $Rest[$i + 1]; $i += 2
                }
            }
        } else {
            throw "unexpected positional argument '$tok' for $FunctionName (all parameters are named)"
        }
    }
    return $out
}

function Show-MainframeUsage {
    @'
mainframe: the ONE script. usage:
  mainframe.ps1 vault unlock        [-BwPath <path>] [-Json] [-PromptContext <text>] [-TimeoutSeconds <n>] [-Lock] [-LockIfStale] [-OutputPath <path>] [-NtfyTopic <t>] [-Server <url>] [-PagesBase <url>] [-Checkout <path>]
  mainframe.ps1 vault lock
  mainframe.ps1 vault status        [-BwPath <path>] [-Json]
  mainframe.ps1 vault expire        [-BwPath <path>] [-ProfileRoot <path>] [-DelaySeconds <n>]
  mainframe.ps1 vault seal-email
  mainframe.ps1 vault bootstrap-link [-BwPath <path>] [-DryRun] [-PushOnly]
  mainframe.ps1 vault rotate-topic  [-BwPath <path>] [-Topic <topic>] [-ShowTopic] [-ShowCurrent]
'@
}


# ======================================================================
# action: Invoke-VaultUnlock
# ======================================================================

<#
.SYNOPSIS
    the ONE vault flow, callable from windows and from linux.

.DESCRIPTION
    This is the single implementation of the vault leg. Windows runs it
    through the module directly, linux runs it through this CLI - there is no
    second, python copy of the flow any more.

    What it does, in order:

      1. if a fresh cached session exists (the profile root's
         accounts/bitwarden/session.key, 12-hour TTL by default), it is reused and the
         phone is NOT asked for anything.
      2. otherwise the master password is fetched with the 1-tap phone
         approval, exactly like the windows flow: an RSA-2048 keypair, a
         4-digit code, an ntfy push, and the ciphertext comes back over the
         relay (or ntfy directly).
      3. on a machine where the bw CLI is logged out, the sealed email blob
         (bw-email.enc.json) is unsealed with that master password and the CLI
         is logged in.
      4. the vault is unlocked, the session key is cached (0600), and the
         items are read with the cached session.

    Output: a JSON object on stdout (with -Json, which is the default for
    machine callers). The master password is NEVER part of the output.

        {
          "githubToken":       "...",
          "secretsPassword":   "...",
          "email":             "...",
          "sessionCached":     true,
          "sessionReused":     true,
          "approvalRequested": false,
          "sessionPath":       "/root/.config/mainframe/accounts/bitwarden/session.key",
          "ttlMinutes":        60
        }

    Logs go to stderr so stdout stays machine-readable. -OutputPath writes
    the same document to a file, so a caller never has to parse a stream.

    -Lock always locks the vault and purges the cached session. -LockIfStale
    locks only when the cached session is NOT fresh - so a run inside the TTL
    leaves the vault unlocked and the next run needs no phone.

.EXAMPLE
    pwsh -NoProfile -File mainframe.ps1 vault unlock -Json
#>

function Invoke-VaultUnlock {
    param(
        [string]$Checkout = (Split-Path $PSScriptRoot -Parent),
        [string]$NtfyTopic = $null,
        [string]$Server = $null,
        [string]$PagesBase = $null,
        [int]$TimeoutSeconds = 600,
        [string]$PromptContext = 'vault restore',
        [string]$BwPath = 'bw',
        [switch]$Lock,
        [switch]$LockIfStale,
        [string]$OutputPath = $null,
        [switch]$Json
    )

    # stdout belongs to the result document. the modules narrate with Write-Host,
    # which lands in the information stream - silencing it keeps stdout a clean
    # JSON document on both windows powershell 5.1 and pwsh 7.
    # self-healing sync FIRST, before the repo modules load: a checkout that is
    # behind, or sitting on rewritten history, heals itself here and the modules
    # below load fresh. the sync never blocks the flow - a failure warns loudly
    # and the flow proceeds with local code.
    $null = Sync-MainframeCheckout -Checkout $Checkout
    # the flow's own calls use $BwPath, but the imported modules call bare `bw`.
    # on windows bw is on PATH; on linux it usually is not (the local install
    # lives under the work root), so point PATH at the binary the flow was told
    # to use. without this every module call dies with "the term 'bw' is not
    # recognized" - found 2026-11-14 running the vault leg on a muse vm.
    if ($BwPath -match '[\\/]') {
        $bwDir = Split-Path -Parent $BwPath
        if ($bwDir -and (Test-Path -LiteralPath $bwDir)) {
            $env:PATH = "$bwDir$([IO.Path]::PathSeparator)$env:PATH"
        }
    }


    # --- 0. lock on demand (the twin of vault lock) ---
    # -Lock always locks. -LockIfStale locks only when there is no FRESH cached
    # session, so a run inside the TTL leaves the vault unlocked and the next run
    # needs no phone. the rule lives HERE, in the one implementation, so linux
    # does not grow a second copy of it.
    if ($Lock -or $LockIfStale) {
        $sessionFile = Get-MainframeSessionKeyPath
        $fresh = $false
        if ($LockIfStale -and (Test-Path -LiteralPath $sessionFile)) {
            $age = (Get-Date) - (Get-Item -LiteralPath $sessionFile).LastWriteTime
            $ttl = Get-VaultSessionTtlMinutes
            $fresh = ($ttl -le 0 -or $age.TotalMinutes -lt $ttl)
        }
        if ($fresh) {
            Write-FlowLog 'the cached session is still fresh - leaving the vault unlocked'
        } elseif ($Lock) {
            Lock-VaultSession -BwPath $BwPath
            Write-FlowLog "vault session purged at $sessionFile"
        } else {
            # -LockIfStale with a stale session: the TTL has lapsed, so this is
            # an expiry, not a lock - the CLI logs out for real.
            Expire-VaultSession -BwPath $BwPath | Out-Null
            Write-FlowLog "vault session expired at $sessionFile"
        }
        if ($Json) {
            Write-FlowResult ([ordered]@{ locked = (-not $fresh); sessionPath = $sessionFile })
        }
        return
    }

    # --- 1. the cached session (no phone, no master password) ---
    $cached = Get-VaultSession
    $status = Initialize-BwServer -BwPath $BwPath
    $approvalRequested = $false
    $sessionReused = $false
    $email = ''

    if ($cached -and $status.status -ne 'unauthenticated') {
        Write-FlowLog "reusing the cached session (TTL $(Get-VaultSessionTtlMinutes) minutes) - no phone approval needed"
        $sessionReused = $true
        # opportunistic heal (C1, flow-start-when-live): the session is live
        # and no approval is needed at all - cache the shared approval signing
        # key now if this machine lacks it, so the next approval is signed from
        # the first tap. best-effort, never fails the flow.
        try { $null = Sync-VaultApprovalSigningKeyFromVault -Session $cached.Trim() } catch {}
        # same moment, same rule: converge the local ntfy topic to the
        # vault-held one, so a rotation reaches this machine without anyone
        # touching it. best-effort, never fails the flow.
        try { $null = Sync-VaultNtfyTopicFromVault -Session $cached.Trim() } catch {}
        # same moment, same rule: converge the local ntfy relay server to
        # the vault-held one, so a relay move reaches this machine without
        # anyone touching it. best-effort, never fails the flow.
        try { $null = Sync-VaultNtfyServerFromVault -Session $cached.Trim() } catch {}
        $items = @(ConvertFrom-JsonArray -Json (& $BwPath list items --session $cached 2>$null | Out-String))
    } else {
        if ($cached -and $status.status -eq 'unauthenticated') {
            Write-FlowLog 'the cached session is useless while bw is logged out - asking the phone again'
            Clear-VaultSessionCache
        }
        if ($status.status -eq 'unauthenticated') {
            # a fresh machine: the email comes out of the sealed blob, unlocked by
            # the very master password the phone approval hands over
            Write-FlowLog 'bw is logged out - the 1-tap approval will also unseal the account email'
        }

        Write-FlowLog 'triggering the 1-tap mobile approval'
        # the channel is resolved by the module, from the same config file the
        # windows side reads - so the operator sees which relay and page are in
        # use without the caller having to resolve anything itself.
        #
        # the topic is NOT logged: it is the whole privacy of the approval channel
        # (anyone who has it can read requests and push fake cards), and this log
        # goes to a screen someone may paste. only the relay and the page are named.
        $approvalTopic = Get-VaultNtfyTopic -Topic $NtfyTopic
        $approvalServer = Get-VaultNtfyServer -Server $Server
        $approvalPages = Get-VaultPagesBase -PagesBase $PagesBase
        Write-FlowLog "phone approval channel: relay '$approvalServer', page '$approvalPages'"
        $approvalRequested = $true
        $password = Get-VaultMasterPassword -NtfyTopic $approvalTopic -Server $approvalServer -PagesBase $approvalPages `
            -TimeoutSeconds $TimeoutSeconds -PromptContext $PromptContext
        if (-not $password -or $password -eq '__SESSION_ALREADY_UNLOCKED__') {
            throw 'the phone approval did not return a master password'
        }

        if ($status.status -eq 'unauthenticated') {
            $email = Invoke-VaultLogin -BwPath $BwPath -Password $password -Checkout $Checkout
            Write-FlowLog 'bw logged in again'
        }

        # the password travels via a 0600 temp file (--passwordfile), never the
        # process environment (L13).
        $pwFile = New-VaultPasswordFile -Password $password
        try {
            $unlockOut = @(& $BwPath unlock --raw --passwordfile $pwFile 2>&1)
        } finally {
            Remove-VaultPasswordFile -Path $pwFile
            $password = $null
        }
        $session = $unlockOut | Where-Object { $_ -is [string] -and $_ -match '^[A-Za-z0-9+/=]{20,}$' } | Select-Object -Last 1
        if (-not $session) { throw "bw unlock did not return a session key: $($unlockOut -join ' ')" }
        # Set-VaultSessionKey registers the one-shot expiry job (time-based
        # expiry is enforced - the session always expires at its TTL mark).
        Set-VaultSessionKey -SessionKey $session | Out-Null
        # self-heal (C1): the unlock just proved a live session - cache the
        # shared approval signing key now if this machine lacks it, so the NEXT
        # approval is signed. best-effort, never fails the flow.
        try { $null = Sync-VaultApprovalSigningKeyFromVault -Session $session.Trim() } catch {}
        # same moment, same rule: converge the local ntfy topic to the
        # vault-held one, so the next approval goes to the current topic.
        # best-effort, never fails the flow.
        try { $null = Sync-VaultNtfyTopicFromVault -Session $session.Trim() } catch {}
        # same moment, same rule: converge the local ntfy relay server to
        # the vault-held one, so the next approval goes to the current
        # relay. best-effort, never fails the flow.
        try { $null = Sync-VaultNtfyServerFromVault -Session $session.Trim() } catch {}
        Write-FlowLog "vault session cached at $(Get-MainframeSessionKeyPath)"
        $items = @(ConvertFrom-JsonArray -Json (& $BwPath list items --session $session.Trim() 2>$null | Out-String))
    }

    $secrets = Get-VaultSecretsFromItems -Items $items
    if (-not $secrets.GitHubToken) { Write-FlowLog 'WARNING: no github token found in the vault' }
    if (-not $secrets.SecretsPassword) { Write-FlowLog 'WARNING: no mainframe-production secrets password found in the vault' }

    $result = [ordered]@{
        githubToken       = $secrets.GitHubToken
        secretsPassword   = $secrets.SecretsPassword
        email             = $email
        sessionCached     = $true
        sessionReused     = $sessionReused
        approvalRequested = $approvalRequested
        sessionPath       = Get-MainframeSessionKeyPath
        ttlMinutes        = Get-VaultSessionTtlMinutes
    }

    if ($Json) {
        # compress the JSON so a caller cannot mistake the document for a log
        Write-FlowResult $result
    } else {
        Write-Output "github token    : $(if ($secrets.GitHubToken) { 'found' } else { 'MISSING' })"
        Write-Output "secrets password: $(if ($secrets.SecretsPassword) { 'found' } else { 'MISSING' })"
        Write-Output "session path    : $(Get-MainframeSessionKeyPath)"
    }
}


# ======================================================================
# action: Invoke-VaultLock
# ======================================================================

<#
.SYNOPSIS
    Immediately lock the Bitwarden vault and clear the local session key.
.DESCRIPTION
    Purges %APPDATA%\mainframe\accounts\bitwarden\session.key, removes $env:BW_SESSION,
    clears session and item memory caches, and calls 'bw lock'.
    Next time an agent or script requests a vault secret, 1-tap mobile approval
    will be triggered on demand.
#>

function Invoke-VaultLock {
    Lock-VaultSession
}


# ======================================================================
# action: Invoke-VaultExpire
# ======================================================================

# vault expire - the scheduled-expiry entry point.
#
# invoked by the one-shot scheduled job registered at unlock (schtasks on
# windows, a systemd transient timer on linux, a detached sleeper as
# fallback) - never run by hand unless you mean to expire the session NOW.
# runs Invoke-VaultSessionExpiryCheck, which
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

function Invoke-VaultExpire {
    [CmdletBinding()]
    param(
        [string]$ProfileRoot,
        [string]$BwPath = 'bw',
        [int]$DelaySeconds = 0
    )

    if ($ProfileRoot) { $env:MAINFRAME_PROFILE_ROOT = $ProfileRoot }

    # the sleeper mechanism starts this script at registration time and waits
    # out the TTL here; the scheduler mechanisms invoke it at the TTL mark
    # with no delay.
    if ($DelaySeconds -gt 0) {
        Start-Sleep -Seconds $DelaySeconds
    }

    try {
        $outcome = Invoke-VaultSessionExpiryCheck -BwPath $BwPath
        Write-Host "scheduled expiry finished: $outcome"
        return
    } catch {
        Write-Warning "scheduled expiry FAILED: $_"
        throw
    }
}


# ======================================================================
# action: Invoke-SealBwEmail
# ======================================================================

# vault seal-email - one-time sealer for fresh-machine restores.
# Seals the bitwarden account email with a key derived from the master
# password into bw-email.enc.json (ciphertext only) and pushes it to this
# repo. boot.ps1 unseals it with the master password setup asks for anyway,
# so a fresh machine never has to type the email. Run once on a machine
# where the bw CLI is logged in; publish-backup.ps1 also seals automatically
# on publish when the blob is missing. Delete the blob and re-run to
# re-seal (e.g. after an email change).

function Invoke-SealBwEmail {
    $bwStatus = & bw status --raw 2>$null | ConvertFrom-Json
    if (-not $bwStatus -or $bwStatus.status -eq 'unauthenticated') {
        Write-Host 'bw CLI is not logged in here - logging in (interactive):'
        & bw login
        if ($LASTEXITCODE -ne 0) { throw 'bw login failed' }
        $bwStatus = & bw status --raw 2>$null | ConvertFrom-Json
    }
    $bwEmail = [string]$bwStatus.userEmail
    if ([string]::IsNullOrWhiteSpace($bwEmail)) { $bwEmail = Read-Host 'bitwarden EMAIL' }
    $sealPw = Read-Host "master password (seals $bwEmail into bw-email.enc.json)" -AsSecureString
    $sealedBlob = Seal-BwEmail -Email $bwEmail -Password $sealPw
    $blobPath = Join-Path $PSScriptRoot '..\bw-email.enc.json'
    Set-Content -LiteralPath $blobPath -Value ($sealedBlob | ConvertTo-Json) -Encoding UTF8
    & git -C (Join-Path $PSScriptRoot '..') add -- bw-email.enc.json 2>$null | Out-Null
    & git -C (Join-Path $PSScriptRoot '..') commit -m 'chore: seal bw email blob' -- bw-email.enc.json 2>$null | Out-Null
    & git -C (Join-Path $PSScriptRoot '..') push 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Host 'done: bw-email.enc.json pushed (ciphertext only) - fresh-machine setups now ask only for the master password' }
    else { Write-Warning 'git push failed - bw-email.enc.json is written locally; commit and push it manually' }
}


# ======================================================================
# action: Invoke-NewBootstrapLink
# ======================================================================

<#
    vault bootstrap-link - create (or rotate) the ONE permanent bootstrap link

    reads the local mainframe.config.json and serves it from the relay
    under a client-generated unguessable 128-bit token. prints ONE link
    and nothing else secret - never the config, never the topic.

    the link is PERMANENT: GET is repeatable, it never expires, and a
    failed download can simply be re-run. there is exactly one link:
    a plain run generates a fresh token, stores the new link in the
    vault, PUTs the current config under it, deletes the old token's
    bundle, and writes the new token into the local profile config.
    rotation (windows/mainframe.ps1 vault rotate-topic) re-pushes the bundle under
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
        pwsh windows/mainframe.ps1 vault bootstrap-link [-DryRun | -PushOnly]

    -DryRun validates the config and prints the relay base + topic
    fingerprint without creating anything.
    -PushOnly re-pushes the current local config under the EXISTING
    token (local config bootstrapToken first, else the vault item's
    link). no new token, no vault write, no link printed - the recovery
    path when a rotation's bundle push failed.
#>

function Invoke-NewBootstrapLink {
    [CmdletBinding()]
    param(
        [switch]$DryRun,
        [switch]$PushOnly,
        [string]$BwPath = 'bw'
    )

    $script:VaultBootstrapLinkItemName = 'github.com/FahadBinHussain/mainframe / mainframe.bootstrap-link'
    $script:BwLastError = ''


    # --- argument validation ----------------------------------------------------
    if ($DryRun -and $PushOnly) {
        throw 'pick one: -DryRun validates without creating anything, -PushOnly re-pushes the bundle under the existing link. never both.'
    }

    # --- config paths -----------------------------------------------------------

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
                throw 'no bootstrap token found anywhere - the local config has no bootstrapToken and the vault holds no bootstrap link. the link was never created: run this script plain once (pwsh windows/mainframe.ps1 vault bootstrap-link) to create it. nothing was changed.'
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
    # Add-Member, not direct assignment: a config created before the
    # bootstrapToken field existed has no such property, and assigning
    # a new property to a ConvertFrom-Json object throws (measured
    # 2026-11-15 — the first real link creation died here, after the
    # vault item was already created). -Force replaces the value when
    # the property already exists (rotation).
    $config | Add-Member -NotePropertyName 'bootstrapToken' -NotePropertyValue $newToken -Force
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
            Write-Host 'recovery: re-run this script plain (pwsh windows/mainframe.ps1 vault bootstrap-link) - it generates a fresh link and retries the cleanup.'
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
}


# ======================================================================
# action: Invoke-RotateNtfyTopic
# ======================================================================

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
         exact recovery (windows/mainframe.ps1 vault bootstrap-link -PushOnly) - the
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

function Invoke-RotateNtfyTopic {
    param(
        [switch]$ShowTopic,
        [switch]$ShowCurrent,
        [string]$Topic,
        [string]$BwPath = 'bw'
    )

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
        $matches = @($items | Where-Object { [string]$_.name -eq $script:VaultBootstrapLinkItemName })
        if ($matches.Count -gt 1) {
            # same duplicate shape as the topic item above: a "failed"
            # create/edit that landed server-side, then a retry that made
            # another item. refuse to guess which link is the live one.
            $ids = ($matches | ForEach-Object { [string]$_.id }) -join ', '
            throw "found $($matches.Count) vault items named '$script:VaultBootstrapLinkItemName' (ids: $ids) - refusing to guess which one is the link. delete all but one with 'bw delete item <id>' (keep the one whose link matches the local config), then re-run."
        }
        $item = $matches | Select-Object -First 1
        if (-not $item) { return $null }
        return ([string]$item.notes).Trim()
    }

    $script:VaultNtfyTopicVaultItemName = 'github.com/FahadBinHussain/mainframe / mainframe.ntfy-topic'
    $script:VaultBootstrapLinkItemName = 'github.com/FahadBinHussain/mainframe / mainframe.bootstrap-link'
    $script:BwLastError = ''


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
    $profileRoot = Get-MainframeProfileRoot
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
        return
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
}


# ======================================================================
# dispatcher: runs ONLY when invoked directly, never when dot-sourced
# (tests dot-source this file to load the functions).
# ======================================================================

if ($MyInvocation.InvocationName -ne '.') {
    $actions = @{
        'vault unlock'         = 'Invoke-VaultUnlock'
        'vault lock'           = 'Invoke-VaultLock'
        'vault status'         = 'Invoke-VaultStatus'
        'vault expire'         = 'Invoke-VaultExpire'
        'vault seal-email'     = 'Invoke-SealBwEmail'
        'vault bootstrap-link' = 'Invoke-NewBootstrapLink'
        'vault rotate-topic'   = 'Invoke-RotateNtfyTopic'
    }
    if (-not $Group -or $Group -in @('-h', '--help', 'help')) {
        Show-MainframeUsage
        exit 0
    }
    if ($Group -eq 'vault' -and -not $Action) {
        Show-MainframeUsage
        exit 0
    }
    $key = "$Group $Action".Trim()
    if (-not $actions.ContainsKey($key)) {
        [Console]::Error.WriteLine("mainframe: unknown command '$key'")
        Show-MainframeUsage
        exit 2
    }
    $fn = $actions[$key]
    try {
        $splat = Convert-RestToArgs -FunctionName $fn -Rest $Rest
        & $fn @splat
        exit 0
    } catch {
        [Console]::Error.WriteLine("mainframe: $_")
        exit 1
    }
}
