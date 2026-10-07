# publish-backup.ps1 - upload the two release assets (quick + persist) to the private release store
# usage: publish-backup.ps1 [-QuickZip <path>] [-PersistZip <path>] [-SecretsZip <path>] [-Keep 5]
# auth chain: bitwarden session.key (from unlock.ps1) -> vault github token -> gh release upload
# the secrets archive is AES-256 encrypted with the password held in the vault item
# 'mainframe-production' (notes header '[secrets archive password]') and APPENDED into
# mainframe-quick.zip as the entry mainframe-secrets.zip - quick carries it so BOTH restore
# modes get secrets from one download (until 2026-10-07 it was a third release asset).
# boot.ps1 reads the same vault item to decrypt it on the target machine.
# fails LOUD on: locked vault, missing token, bad scope, missing zips, missing password,
# blob missing/duplicated inside quick, missing asset after upload, gh error. no fallbacks.
param(
    [string]$QuickZip,
    [string]$PersistZip,
    [string]$SecretsZip,
    [string]$Repo = 'FahadBinHussain/mainframe-production',
    [int]$Keep = 5
)
$ErrorActionPreference = 'Stop'

if (-not $QuickZip) { $QuickZip = Join-Path $PSScriptRoot 'mainframe-quick.zip' }
if (-not $PersistZip) { $PersistZip = Join-Path $PSScriptRoot 'mainframe-persist.zip' }
if (-not $SecretsZip) { $SecretsZip = Join-Path $PSScriptRoot 'tool-secrets.zip' }
if (-not (Test-Path -LiteralPath $QuickZip)) { throw "quick zip not found: $QuickZip (run backup.ps1 first)" }
if (-not (Test-Path -LiteralPath $PersistZip)) { throw "persist zip not found: $PersistZip (was backup taken with -SkipPersist? both zips are required)" }
if (-not (Test-Path -LiteralPath $SecretsZip)) { throw "secrets archive not found: $SecretsZip (run .\backup-secrets.ps1 first - backup.ps1 -Publish does that for you)" }

# --- vault session (must be unlocked) ---
$sessionKeyFile = Join-Path $env:APPDATA 'mainframe\accounts\bitwarden\session.key'
if (-not (Test-Path -LiteralPath $sessionKeyFile)) {
    throw "vault is locked: no session.key found. run automata-private\bitwarden.com\unlock.ps1 first, then retry."
}
$env:BW_SESSION = (Get-Content -LiteralPath $sessionKeyFile -Raw).Trim()
$status = & bw status --raw 2>$null | ConvertFrom-Json
if (-not $status -or $status.status -ne 'unlocked') {
    throw "vault still locked after session.key (status=$($status.status)) - refresh it via automata-private\bitwarden.com\unlock.ps1"
}

# --- github token from vault ---
Import-Module (Join-Path $PSScriptRoot 'vault-secret.psm1') -Force
$githubAccountRoot = Join-Path $env:APPDATA 'mainframe\accounts\github'
$currentProfileFile = Join-Path $githubAccountRoot 'current.json'
if (-not (Test-Path -LiteralPath $currentProfileFile)) {
    throw "no active github profile at $currentProfileFile - run github-account.ps1 use <email> first"
}
try {
    $currentProfile = Get-Content -LiteralPath $currentProfileFile -Raw | ConvertFrom-Json
} catch {
    throw "active github profile metadata is unreadable at $currentProfileFile - run github-account.ps1 use <email> first"
}
$email = ([string]$currentProfile.profile).Trim().ToLowerInvariant()
if ($email -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') {
    throw "active github profile is missing a valid email in $currentProfileFile - run github-account.ps1 use <email> first"
}
# Accept both the current 'github.com - <login>' item and the legacy exact
# 'github.com' item. Find-VaultItemByEmail still binds the item to this profile.
$token = Read-VaultSecret -Email $email -NamePattern @('github.com', 'github.com - *') -ValueRegex '(ghp_|github_pat_)[A-Za-z0-9_]+'
if (-not $token) { throw "no github token found in vault for $email (item like 'github.com*')" }
$env:GH_TOKEN = $token

# --- scope preflight: private release upload needs repo access ---
$me = gh api user --jq .login 2>&1
if ($LASTEXITCODE -ne 0) { throw "github token rejected: $me" }
Write-Host "publishing as $me -> $Repo"

# --- secrets archive: AES-256 copy for the release (password lives in the vault only) ---
# boot.ps1 runs this SAME search + regex to decrypt; keep both byte-identical.
function Get-SecretsArchivePassword {
    $items = @(& bw list items --search 'mainframe-production' --raw 2>$null | ConvertFrom-Json)
    $item = $items | Where-Object { $_.name -eq 'mainframe-production' } | Select-Object -First 1
    if (-not $item) { throw "no vault item named 'mainframe-production' - it must hold the '[secrets archive password]' notes header" }
    if ($item.notes -notmatch '(?m)^\[secrets archive password\]\s*\r?\n\s*(\S+)') {
        throw "vault item 'mainframe-production' has no '[secrets archive password]' notes header"
    }
    return $Matches[1]
}
$secretsArchivePassword = Get-SecretsArchivePassword

$sevenZip = (Get-Command 7z.exe -ErrorAction SilentlyContinue).Source
if (-not $sevenZip) { $sevenZip = (Get-Command 7z -ErrorAction SilentlyContinue).Source }
if (-not $sevenZip) { throw '7z not found - install 7zip (scoop install 7zip) before publishing' }
$encZip = Join-Path $PSScriptRoot 'mainframe-secrets.zip'
if (Test-Path -LiteralPath $encZip) { Remove-Item -LiteralPath $encZip -Force }
# push so the stored entry name is exactly tool-secrets.zip - boot extracts the archive
# straight into the restore root, so a nested path would hide it from restore.ps1.
Push-Location (Split-Path -Parent $SecretsZip)
try {
    $zout = & $sevenZip a -tzip -mem=AES256 "-p$secretsArchivePassword" -mx5 -bso0 -bsp0 -y $encZip (Split-Path -Leaf $SecretsZip) 2>&1
    $zexit = $LASTEXITCODE
} finally {
    Pop-Location
}
if ($zexit -ge 2) { throw "7z failed with exit code $zexit while encrypting $SecretsZip`n$(@($zout) -join "`n")" }
$secretsMB = '{0:N1}' -f ((Get-Item -LiteralPath $encZip).Length / 1MB)

# --- tuck the encrypted archive INTO quick: one download serves both restore modes ---
# 7z 'a' on an existing zip adds/updates the one entry without recompressing the other
# ~220 MB, and quick is rebuilt by every backup.ps1 run, so this lands once per build.
Push-Location (Split-Path -Parent $encZip)
try {
    $aout = & $sevenZip a -tzip -bso0 -bsp0 -y $QuickZip (Split-Path -Leaf $encZip) 2>&1
    $aexit = $LASTEXITCODE
} finally {
    Pop-Location
}
if ($aexit -ge 2) { throw "7z failed with exit code $aexit while appending secrets into $QuickZip`n$(@($aout) -join "`n")" }
# verify by LISTING the entries, not by trusting the exit code: a missing blob means boot
# dies on the target machine, a duplicated one means it decrypts the wrong bytes.
$entryLines = @(& $sevenZip l -ba $QuickZip 2>$null)
$blobEntries = @($entryLines | Where-Object { $_ -match '(^|\s)mainframe-secrets\.zip\s*$' })
if ($blobEntries.Count -ne 1) {
    throw "expected exactly 1 mainframe-secrets.zip entry inside $QuickZip, found $($blobEntries.Count) - this release would be unrestorable"
}
Write-Host "quick carries the encrypted secrets archive ($secretsMB MB)"

# --- create release, upload quick + persist (hostname-tagged so laptop+desktop can both publish) ---
$hostname = $env:COMPUTERNAME
$tag = '{0}-{1}' -f (Get-Date -Format 'yyyy-MM-dd-HHmm'), $hostname
$quickMB = '{0:N0}' -f ((Get-Item -LiteralPath $QuickZip).Length / 1MB)
$persistMB = '{0:N0}' -f ((Get-Item -LiteralPath $PersistZip).Length / 1MB)
gh release create $tag $QuickZip $PersistZip --repo $Repo --title "machine state $hostname $tag" --notes "auto-published by backup.ps1 -Publish (quick $quickMB MB incl. secrets $secretsMB MB encrypted + persist $persistMB MB)"
if ($LASTEXITCODE -ne 0) { throw "gh release create failed (exit $LASTEXITCODE) - token may lack repo scope or release perms" }

# verify the upload instead of trusting the exit code: a partial upload leaves a release
# that boot.ps1 can only discover as "no quick asset" on the target machine.
$uploaded = @((gh release view $tag --repo $Repo --json assets 2>$null | ConvertFrom-Json).assets | ForEach-Object { $_.name })
$expectedAssets = @((Split-Path -Leaf $QuickZip), (Split-Path -Leaf $PersistZip))
$missingAssets = @($expectedAssets | Where-Object { $want = $_; -not ($uploaded | Where-Object { $_ -eq $want }) })
if ($missingAssets.Count -gt 0) {
    throw "release $tag uploaded incompletely - missing asset(s): $($missingAssets -join ', ')"
}
Write-Host "published $tag (quick $quickMB MB incl. secrets $secretsMB MB encrypted + persist $persistMB MB) -> $Repo"

# --- prune: keep newest $Keep per hostname ---
# gh release list returns NEWEST-FIRST. tags are yyyy-MM-dd-HHmm-<host>, so sorting
# ascending by tagName gives chronological order; slicing First(count-Keep) then
# removes the OLDEST. (bug 2026-10-03: without the sort the slice took the head of a
# newest-first list, i.e. the release just created -- every daily publish from
# 2026-09-22 to 2026-10-03 was uploaded and immediately deleted, and the count stayed
# pinned at exactly $Keep so nothing looked wrong.)
$releases = gh release list --repo $Repo --limit 200 --json tagName 2>$null | ConvertFrom-Json
$mine = @($releases | Where-Object { $_.tagName -like "*-$hostname" } | Sort-Object tagName)
if ($mine.Count -gt $Keep) {
    $old = $mine | Select-Object -First ($mine.Count - $Keep)
    foreach ($r in $old) {
        gh release delete $r.tagName --repo $Repo --cleanup-tag --yes 2>&1 | Out-Null
        Write-Host "pruned old release $($r.tagName)"
    }
}
# fail LOUD if the prune ate the release we just uploaded
$after = gh release list --repo $Repo --limit 200 --json tagName 2>$null | ConvertFrom-Json
if (-not ($after | Where-Object { $_.tagName -eq $tag })) {
    throw "prune deleted the just-created release $tag - prune is still sorting wrong"
}
Write-Host "verified: $tag survived prune"
Write-Host "done: $Repo now holds $([Math]::Min($mine.Count, $Keep)) releases for $hostname"
