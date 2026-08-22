# vault-secret.ps1 - shared Bitwarden vault read/write for mainframe account helpers
#
# Vault-native secrets: each helper stores per-profile secrets in the Bitwarden
# vault as a LOGIN item named by the platform (e.g. "console.neon.tech - <user>"),
# with the secret value in the item's notes under a platform-specific header
# (e.g. "[api keys]`n<value>"). This module finds the item by the profile email
# and extracts/updates the value. No secrets are stored in the mainframe profile dir.
#
# Session: read from %APPDATA%\mainframe\accounts\bitwarden\session.key (written
# by automata\bitwarden.com\unlock.ps1) or $env:BW_SESSION. If the vault is locked,
# calls fail with a clear message asking the user to unlock first.

function Get-VaultSession {
    if ($env:BW_SESSION) {
        return [string]$env:BW_SESSION
    }

    $sessionFile = Join-Path $env:APPDATA 'mainframe\accounts\bitwarden\session.key'
    if (Test-Path -LiteralPath $sessionFile) {
        return (Get-Content -LiteralPath $sessionFile -Raw).Trim()
    }

    return $null
}

function Test-VaultSession {
    $session = Get-VaultSession
    if ([string]::IsNullOrWhiteSpace($session)) {
        return $false
    }

    $env:BW_SESSION = $session
    try {
        $status = bw status 2>$null | ConvertFrom-Json
        return ($status.status -eq 'unlocked')
    } catch {
        return $false
    }
}

function Get-VaultItems {
    if (-not (Test-VaultSession)) {
        throw 'Bitwarden vault is locked or no session found. Run automata\bitwarden.com\unlock.ps1 first, or set $env:BW_SESSION.'
    }

    $items = @(bw list items --session $env:BW_SESSION 2>$null | ConvertFrom-Json)
    return $items
}

function Find-VaultItemByEmail {
    param(
        [string]$Email,
        [string]$NamePattern = '*'
    )

    $normalizedEmail = $Email.Trim().ToLowerInvariant()
    $items = Get-VaultItems

    # primary: login.username matches the email exactly
    $item = $items | Where-Object {
        $_.name -like $NamePattern -and
        $_.login.username -and
        ([string]$_.login.username).Trim().ToLowerInvariant() -eq $normalizedEmail
    } | Select-Object -First 1
    if ($item) {
        return $item
    }

    # fallback: notes contain the email on its own line (github/uptimerobot convention)
    $item = $items | Where-Object {
        $_.name -like $NamePattern -and
        $_.notes -and
        (@($_.notes -split "`r?`n") | Where-Object { $_.Trim().ToLowerInvariant() -eq $normalizedEmail })
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
        [string]$NamePattern,
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

    if (-not (Test-VaultSession)) {
        throw 'Bitwarden vault is locked. Run automata\bitwarden.com\unlock.ps1 first.'
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
}

function New-VaultItem {
    param(
        [string]$Name,
        [AllowNull()][string]$Username,
        [AllowNull()][string]$Uri,
        [AllowNull()][string]$Notes
    )

    if (-not (Test-VaultSession)) {
        throw 'Bitwarden vault is locked. Run automata\bitwarden.com\unlock.ps1 first.'
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
    return $obj.id
}

# Upsert the secret into an existing item's notes: replace the value under the
# given header while preserving the rest of the notes (recovery codes, etc.).
# Creates the item if it does not exist yet (ItemName/Username required then).
function Write-VaultSecretToExisting {
    param(
        [string]$Email,
        [string]$NamePattern,
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

Export-ModuleMember -Function Get-VaultSession, Test-VaultSession, Get-VaultItems, Find-VaultItemByEmail, Get-SecretFromNotes, Read-VaultSecret, Update-VaultItemNotes, Write-VaultSecretToExisting, New-VaultItem
