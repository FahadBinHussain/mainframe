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
# mainframe.config.json vaultTtlMinutes); expired sessions auto-lock and prompt
# for 1-tap mobile approval on phone via vault-approval.psm1.
#
# Performance: Get-VaultItems caches bw list items per session so the vault is
# queried at most once per process. Write operations (Update-VaultItemNotes,
# New-VaultItem, Write-VaultSecretToExisting) invalidate the cache so subsequent
# reads see the new item. Call Clear-VaultItemsCache to force a re-read.

$script:VaultItemsCache = $null
$script:VaultItemsCacheSession = $null
$script:VaultSessionOkSession = $null
$script:DefaultSessionTtlMinutes = 60

function Get-VaultSessionTtlMinutes {
    if ($env:MAINFRAME_VAULT_TTL_MINUTES) {
        try { return [int]$env:MAINFRAME_VAULT_TTL_MINUTES } catch {}
    }
    $cfgCandidates = @(
        (Join-Path $PSScriptRoot 'mainframe.config.json'),
        (Join-Path (Get-Location) 'mainframe.config.json'),
        (Join-Path $HOME '.config\mainframe\mainframe.config.json')
    )
    foreach ($cfgPath in $cfgCandidates) {
        if (Test-Path -LiteralPath $cfgPath) {
            try {
                $cfg = Get-Content -LiteralPath $cfgPath -Raw | ConvertFrom-Json
                if ($cfg.vaultTtlMinutes) { return [int]$cfg.vaultTtlMinutes }
                if ($cfg.sessionTtlMinutes) { return [int]$cfg.sessionTtlMinutes }
            } catch {}
        }
    }
    return $script:DefaultSessionTtlMinutes
}

function Lock-VaultSession {
    $sessionFile = Join-Path $env:APPDATA 'mainframe\accounts\bitwarden\session.key'
    if (Test-Path -LiteralPath $sessionFile) {
        Remove-Item -LiteralPath $sessionFile -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -Path 'Env:\BW_SESSION' -ErrorAction SilentlyContinue
    Clear-VaultSessionCache
    Clear-VaultItemsCache
    & bw lock 2>$null | Out-Null
    Write-Host "Bitwarden vault locked." -ForegroundColor Green
}

function Get-VaultSession {
    param([switch]$AllowExpired)

    $sessionFile = Join-Path $env:APPDATA 'mainframe\accounts\bitwarden\session.key'
    $ttlMinutes = Get-VaultSessionTtlMinutes

    if (Test-Path -LiteralPath $sessionFile) {
        $fileInfo = Get-Item -LiteralPath $sessionFile
        $age = (Get-Date) - $fileInfo.LastWriteTime

        if (-not $AllowExpired -and $ttlMinutes -gt 0 -and $age.TotalMinutes -ge $ttlMinutes) {
            Write-Host "vault session expired ($([math]::Round($age.TotalMinutes))m >= ${ttlMinutes}m TTL) - locking vault" -ForegroundColor Yellow
            Lock-VaultSession
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
            [System.Environment]::SetEnvironmentVariable('BW_PASSWORD', $pw)
            try {
                $unlockOut = @(& bw unlock --raw --passwordenv BW_PASSWORD 2>&1)
                $rawKey = $unlockOut | Where-Object { $_ -is [string] -and $_ -match '^[A-Za-z0-9+/=]{20,}$' } | Select-Object -Last 1
                if ($rawKey) {
                    $sessionFile = Join-Path $env:APPDATA 'mainframe\accounts\bitwarden\session.key'
                    New-Item -ItemType Directory -Force -Path (Split-Path $sessionFile) | Out-Null
                    Set-Content -LiteralPath $sessionFile -Value $rawKey.Trim() -Encoding UTF8 -NoNewline
                    $env:BW_SESSION = $rawKey.Trim()
                    Clear-VaultSessionCache
                    Clear-VaultItemsCache
                    Write-Host "vault unlocked successfully with fresh 1-hour session" -ForegroundColor Green
                    return $true
                } else {
                    Write-Warning "bw unlock did not return a valid session key: $($unlockOut -join ' ')"
                }
            } finally {
                Remove-Item -Path 'Env:\BW_PASSWORD' -ErrorAction SilentlyContinue
                $pw = $null
            }
        }
    }

    return $false
}

function Clear-VaultSessionCache {
    $script:VaultSessionOkSession = $null
}

function Get-VaultItems {
    if (-not (Ensure-VaultSession)) {
        throw 'Bitwarden vault is locked or approval was not completed. Use 1-tap mobile approval or run automata-private\bitwarden.com\unlock.ps1.'
    }

    $session = Get-VaultSession
    if ($null -ne $script:VaultItemsCache -and $script:VaultItemsCacheSession -eq $session) {
        return $script:VaultItemsCache
    }

    $items = @(bw list items --session $env:BW_SESSION 2>$null | ConvertFrom-Json)
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

Export-ModuleMember -Function Get-VaultSession, Test-VaultSession, Ensure-VaultSession, Lock-VaultSession, Get-VaultSessionTtlMinutes, Get-VaultItems, Clear-VaultItemsCache, Find-VaultItemByEmail, Get-SecretFromNotes, Read-VaultSecret, Update-VaultItemNotes, Write-VaultSecretToExisting, New-VaultItem, Clear-VaultSessionCache
