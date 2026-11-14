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
# Sessions expire after 1 hour (configurable via MAINFRAME_VAULT_TTL_MINUTES or
# mainframe.config.json vaultTtlMinutes); an expired session is EXPIRED, not
# just locked - `bw logout` revokes the CLI's tokens server-side and wipes its
# local cache, so the old session key stops working for real. the next vault
# use is a full login through 1-tap mobile approval on phone via vault-approval.psm1.
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
        unseal the vault account email from bw-email.enc.json.

    .DESCRIPTION
        the blob in the repo is ciphertext only: PBKDF2-HMAC-SHA256 (600k
        iterations) over the master password, AES-256-CBC, HMAC-SHA256 over
        salt|iv|ciphertext. a fresh machine never has to type the email
        address - the master password is enough.

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
    $sessionFile = Get-MainframeSessionKeyPath
    if (Test-Path -LiteralPath $sessionFile) {
        Remove-Item -LiteralPath $sessionFile -Force -ErrorAction SilentlyContinue
    }
    $ttlFile = [System.IO.Path]::ChangeExtension($sessionFile, '.ttl')
    if (Test-Path -LiteralPath $ttlFile) {
        Remove-Item -LiteralPath $ttlFile -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -Path 'Env:\BW_SESSION' -ErrorAction SilentlyContinue
    Remove-Item -Path 'Env:\MAINFRAME_VAULT_APPROVED_TTL' -ErrorAction SilentlyContinue
    Clear-VaultSessionCache
    Clear-VaultItemsCache
    & $BwPath lock 2>$null | Out-Null
    Write-Host "Bitwarden vault locked." -ForegroundColor Green
}

function Expire-VaultSession {
    <#
    .SYNOPSIS
        really end the vault session: log the CLI out and purge the cache.

    .DESCRIPTION
        lock is not expiry. `bw lock` leaves the CLI logged in, the local
        vault cache on disk and the old session key able to decrypt it - so
        a session that only "expired" by policy kept working for days after
        its TTL (the muse container ran 7 days on one approval). expiry runs
        `bw logout`: the server revokes the CLI's tokens and the CLI wipes
        its local data, so the old session key has nothing left to decrypt
        and the next vault use is a full login through the phone approval.

        the local purge never depends on the server: session.key, session.ttl
        and the env vars go even when logout fails (no network, no CLI). the
        logout is verified with `bw status` afterwards - a CLI that is still
        logged in is reported LOUDLY and locked as a fallback, never silently
        left half-expired. one limit is inherent and cannot be fixed here: a
        session key or token copied BEFORE the expiry stays a valid decryption
        key for a copied vault cache - expiry kills the live session, not a
        copy made earlier.
    #>
    param([string]$BwPath = 'bw')
    $sessionFile = Get-MainframeSessionKeyPath
    $loggedOut = $false
    try {
        $logoutOut = @(& $BwPath logout 2>&1)
        $loggedOut = ($LASTEXITCODE -eq 0)
        if (-not $loggedOut) {
            Write-MainframeWarning "bw logout failed ($($logoutOut -join ' ')) - purging the local session anyway"
        }
    } catch {
        Write-MainframeWarning "bw logout could not run ($_) - purging the local session anyway"
    }
    if (Test-Path -LiteralPath $sessionFile) {
        Remove-Item -LiteralPath $sessionFile -Force -ErrorAction SilentlyContinue
    }
    $ttlFile = [System.IO.Path]::ChangeExtension($sessionFile, '.ttl')
    if (Test-Path -LiteralPath $ttlFile) {
        Remove-Item -LiteralPath $ttlFile -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -Path 'Env:\BW_SESSION' -ErrorAction SilentlyContinue
    Remove-Item -Path 'Env:\MAINFRAME_VAULT_APPROVED_TTL' -ErrorAction SilentlyContinue
    Clear-VaultSessionCache
    Clear-VaultItemsCache
    try {
        $status = & $BwPath status 2>$null | Out-String | ConvertFrom-Json
        if ($status -and $status.status -ne 'unauthenticated') {
            Write-MainframeWarning "the vault session did NOT expire - bw status is still '$($status.status)' after logout; locking the vault instead"
            & $BwPath lock 2>$null | Out-Null
        }
    } catch {
        Write-MainframeWarning "could not verify the logout with bw status ($_) - the local session is purged, the server side is unconfirmed"
    }
    Write-Host "vault session expired (logged out)." -ForegroundColor Green
    return $loggedOut
}

function Get-VaultSession {
    param([switch]$AllowExpired)

    $sessionFile = Get-MainframeSessionKeyPath
    $ttlMinutes = Get-VaultSessionTtlMinutes

    if (Test-Path -LiteralPath $sessionFile) {
        $fileInfo = Get-Item -LiteralPath $sessionFile
        $age = (Get-Date) - $fileInfo.LastWriteTime

        if (-not $AllowExpired -and $ttlMinutes -gt 0 -and $age.TotalMinutes -ge $ttlMinutes) {
            Write-Host "vault session expired ($([math]::Round($age.TotalMinutes))m >= ${ttlMinutes}m TTL) - expiring it (logout + purge)" -ForegroundColor Yellow
            Expire-VaultSession | Out-Null
            return $null
        }

        return (Get-Content -LiteralPath $sessionFile -Raw).Trim()
    }

    if ($env:BW_SESSION) {
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
        log the bw CLI in with the master password - the first use after a
        session expiry, when the CLI is logged out and unlock alone cannot work.

    .DESCRIPTION
        the one login implementation: the account email comes out of the
        sealed blob (bw-email.enc.json, unlocked by the master password
        itself) or $env:MAINFRAME_BW_EMAIL, then `bw login`. vault-flow.ps1
        and Ensure-VaultSession both call it, so a fresh machine and an
        expired session log in the same way. returns the email it logged in
        as, and throws when the email cannot be resolved or the login fails.
    #>
    param(
        [string]$BwPath = 'bw',
        [Parameter(Mandatory = $true)][string]$Password,
        [string]$Checkout = $PSScriptRoot
    )
    $email = $null
    $blob = Join-Path $Checkout 'bw-email.enc.json'
    if (Test-Path -LiteralPath $blob) {
        $secure = ConvertTo-SecureString $Password -AsPlainText -Force
        $email = Unseal-BwEmail -BlobPath $blob -Password $secure
    }
    if (-not $email) { $email = [string]$env:MAINFRAME_BW_EMAIL }
    if (-not $email) {
        throw 'the bw CLI is logged out and the account email could not be unsealed - set MAINFRAME_BW_EMAIL or run the setup that asks for the master password'
    }
    [System.Environment]::SetEnvironmentVariable('BW_PASSWORD', $Password)
    try {
        & $BwPath login $email --passwordenv BW_PASSWORD 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "bw login failed for $email" }
    } finally {
        Remove-Item -Path 'Env:\BW_PASSWORD' -ErrorAction SilentlyContinue
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
            # an expired session logs the CLI out, so the first use after an
            # expiry is a full login, not an unlock - unlock alone fails on
            # a logged-out CLI.
            $statusVal = $null
            try {
                $statusRaw = & bw status 2>$null | Out-String
                if ($statusRaw) { $statusVal = ($statusRaw | ConvertFrom-Json).status }
            } catch {}
            if ($statusVal -eq 'unauthenticated') {
                Write-Host 'bw is logged out after the session expiry - logging in again' -ForegroundColor Yellow
                Invoke-VaultLogin -Password $pw | Out-Null
            }
            [System.Environment]::SetEnvironmentVariable('BW_PASSWORD', $pw)
            try {
                $unlockOut = @(& bw unlock --raw --passwordenv BW_PASSWORD 2>&1)
                $rawKey = $unlockOut | Where-Object { $_ -is [string] -and $_ -match '^[A-Za-z0-9+/=]{20,}$' } | Select-Object -Last 1
                if ($rawKey) {
                    $sessionFile = Set-VaultSessionKey -SessionKey $rawKey
                    $env:BW_SESSION = $rawKey.Trim()
                    Clear-VaultSessionCache
                    Clear-VaultItemsCache
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
                Remove-Item -Path 'Env:\BW_PASSWORD' -ErrorAction SilentlyContinue
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
    Set-Content -LiteralPath $sessionFile -Value $SessionKey.Trim() -Encoding UTF8 -NoNewline

    $ttlFile = [System.IO.Path]::ChangeExtension($sessionFile, '.ttl')
    if ($TtlMinutes -gt 0) {
        Set-Content -LiteralPath $ttlFile -Value ([string]$TtlMinutes) -Encoding UTF8 -NoNewline
        Write-Host "session TTL set to $TtlMinutes minutes ($([math]::Round($TtlMinutes / 60)) hours) at $ttlFile" -ForegroundColor Green
    } else {
        Remove-Item -LiteralPath $ttlFile -Force -ErrorAction SilentlyContinue
    }

    # owner-only on the posix side; windows inherits the profile acl
    if ($env:OS -ne 'Windows_NT') {
        try {
            $mode = [System.IO.UnixFileMode]::UserRead -bor [System.IO.UnixFileMode]::UserWrite
            [System.IO.File]::SetUnixFileMode($sessionFile, $mode)
            if ($TtlMinutes -gt 0 -and (Test-Path -LiteralPath $ttlFile)) {
                [System.IO.File]::SetUnixFileMode($ttlFile, $mode)
            }
        } catch {
            Write-MainframeWarning "could not tighten the mode of $sessionFile - it may be readable by other users"
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

Export-ModuleMember -Function Get-VaultSession, Set-VaultSessionKey, Test-VaultSession, Ensure-VaultSession, Lock-VaultSession, Expire-VaultSession, Invoke-VaultLogin, Get-VaultSessionTtlMinutes, Get-VaultBwServer, Get-VaultItems, Clear-VaultItemsCache, Find-VaultItemByEmail, Get-SecretFromNotes, Read-VaultSecret, Update-VaultItemNotes, Write-VaultSecretToExisting, New-VaultItem, Clear-VaultSessionCache, Get-BwEmailKeyMaterial, Unseal-BwEmail, Get-MainframeProfileRoot, Get-MainframeAccountsDir, Get-MainframeAccountDir, Get-MainframeSessionKeyPath, Get-MainframeCheckoutRoot
