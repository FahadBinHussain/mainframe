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
# Sessions expire after 1 hour by default (configurable via MAINFRAME_VAULT_TTL_MINUTES or
# mainframe.config.json vaultTtlMinutes); a 1-tap mobile approval grants up to 12 hours
# (720 minutes, the max - the approval page's ttl, clamped in vault-approval.psm1).
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
$script:DefaultSessionTtlMinutes = 60

# the profile root is resolved by one shared module, so windows and linux read
# the same place (see mainframe-paths.psm1).
Import-Module (Join-Path $PSScriptRoot 'mainframe-paths.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'mainframe-json.psm1') -Force -DisableNameChecking

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
    # the config lookup lives in mainframe-paths.psm1, so linux reads the
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
    return 'https://vaultwardenn.onrender.com'
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
# fresh session. the wrapper (expire-vault-session.ps1) double-checks age
# + key hash before expiring, and every path unregisters the job when it
# is done, so no orphaned task/timer/sleeper is left behind.

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
    $tr = "`"$PwshPath`" -NoProfile -NonInteractive -File `"$WrapperPath`" -ProfileRoot `"$ProfileRoot`" -BwPath `"$BwPath`""
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
    $arguments += @('-NoProfile', '-NonInteractive', '-File', $WrapperPath, '-ProfileRoot', $ProfileRoot, '-BwPath', $BwPath)
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
    $arguments = "-NoProfile -NonInteractive -File `"$WrapperPath`" -ProfileRoot `"$ProfileRoot`" -BwPath `"$BwPath`" -DelaySeconds $Seconds"
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
        expire-vault-session.ps1 at unlock + TTL, which calls the full
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

    $wrapperPath = Join-Path $PSScriptRoot 'expire-vault-session.ps1'
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

    $isWindows = ($env:OS -eq 'Windows_NT')
    $order = if ($Mechanism -eq 'Auto') {
        if ($isWindows) { @('SchTasks', 'Sleeper') } else { @('Systemd', 'Sleeper') }
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
        otherwise stand down. called by expire-vault-session.ps1.

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
        vault-flow.ps1 and Ensure-VaultSession both call it, so a fresh
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

    $approvalModule = Join-Path $PSScriptRoot 'vault-approval.psm1'
    if (-not (Get-Command Get-VaultMasterPassword -ErrorAction SilentlyContinue) -and (Test-Path -LiteralPath $approvalModule)) {
        Import-Module $approvalModule -Force -DisableNameChecking
    }

    if (Get-Command Get-VaultMasterPassword -ErrorAction SilentlyContinue) {
        # Check again right before prompting in case another agent just unlocked
        if (Test-VaultSession) {
            return $true
        }

        $promptStartTimeUtc = [DateTime]::UtcNow
        Write-Host "`n==> vault session is locked or expired (1-hour TTL)." -ForegroundColor Yellow
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
                    $sessionFile = Set-VaultSessionKey -SessionKey $rawKey -ScheduleExpiry
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
        [int]$TtlMinutes = 0,
        [switch]$ScheduleExpiry
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

    if ($ScheduleExpiry) {
        # time-based expiry: register the one-shot job that runs the full
        # Expire-VaultSession at the TTL mark. best-effort - a failed
        # registration must never fail the unlock; the lazy check in
        # Get-VaultSession is the backstop, and Register warns loudly.
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

# Upsert the secret into an existing item's notes: replace the value under the
# given header while preserving the rest of the notes (recovery codes, etc.).
# Creates the item if it does not exist yet (ItemName/Username required then).
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

Export-ModuleMember -Function Get-VaultSession, Set-VaultSessionKey, Test-VaultSession, Ensure-VaultSession, Lock-VaultSession, Expire-VaultSession, Register-VaultSessionExpiry, Unregister-VaultSessionExpiry, Invoke-VaultSessionExpiryCheck, Invoke-VaultLogin, Get-VaultAccountEmail, New-VaultPasswordFile, Remove-VaultPasswordFile, Get-VaultSessionTtlMinutes, Get-VaultBwServer, Get-VaultItems, Clear-VaultItemsCache, Find-VaultItemByEmail, Get-SecretFromNotes, Read-VaultSecret, Update-VaultItemNotes, Write-VaultSecretToExisting, New-VaultItem, Clear-VaultSessionCache, Get-BwEmailKeyMaterial, Unseal-BwEmail, Get-MainframeProfileRoot, Get-MainframeAccountsDir, Get-MainframeAccountDir, Get-MainframeSessionKeyPath, Get-MainframeCheckoutRoot
