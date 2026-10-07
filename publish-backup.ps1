# publish-backup.ps1 - upload split backup zips + encrypted secrets to private release store
# usage: publish-backup.ps1 [-CoreZip <path>] [-PersistZip <path>] [-SecretsZip <path>] [-Keep 5]
# auth chain: bitwarden session.key (from unlock.ps1) -> vault github token -> gh release upload
# the secrets archive is AES-256 encrypted with the password held in the vault item
# 'mainframe-production' (notes header '[secrets archive password]') BEFORE it is uploaded;
# boot.ps1 reads the same item to decrypt it on the target machine.
# fails LOUD on: locked vault, missing token, bad scope, missing zips, missing password,
# missing asset after upload, gh error. no fallbacks.
param(
    [string]$CoreZip,
    [string]$PersistZip,
    [string]$SecretsZip,
    [string]$Repo = 'FahadBinHussain/mainframe-production',
    [int]$Keep = 5
)
$ErrorActionPreference = 'Stop'

if (-not $CoreZip) { $CoreZip = Join-Path $PSScriptRoot 'mainframe-core.zip' }
if (-not $PersistZip) { $PersistZip = Join-Path $PSScriptRoot 'mainframe-persist.zip' }
if (-not $SecretsZip) { $SecretsZip = Join-Path $PSScriptRoot 'tool-secrets.zip' }
if (-not (Test-Path -LiteralPath $CoreZip)) { throw "core zip not found: $CoreZip (run backup.ps1 first)" }
if (-not (Test-Path -LiteralPath $PersistZip)) { throw "persist zip not found: $PersistZip (was backup taken with -SkipPersist? both zips are required)" }
if (-not (Test-Path -LiteralPath $SecretsZip)) { throw "secrets archive not found: $SecretsZip (run .\backup-secrets.ps1 first - backup.ps1 -Publish does that for you)" }

# --- vault session (must be unlocked) ---
$sessionKeyFile = Join-Path $env:APPDATA 'mainframe\accounts\bitwarden\session.key'
if (-not (Test-Path -LiteralPath $sessionKeyFile)) {
    throw "vault is locked: no session.key found. run automata\bitwarden.com\unlock.ps1 first, then retry."
}
$env:BW_SESSION = (Get-Content -LiteralPath $sessionKeyFile -Raw).Trim()
$status = & bw status --raw 2>$null | ConvertFrom-Json
if (-not $status -or $status.status -ne 'unlocked') {
    throw "vault still locked after session.key (status=$($status.status)) - refresh it via automata\bitwarden.com\unlock.ps1"
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

# --- create release, upload all three zips (hostname-tagged so laptop+desktop can both publish) ---
$hostname = $env:COMPUTERNAME
$tag = '{0}-{1}' -f (Get-Date -Format 'yyyy-MM-dd-HHmm'), $hostname
$coreMB = '{0:N0}' -f ((Get-Item -LiteralPath $CoreZip).Length / 1MB)
$persistMB = '{0:N0}' -f ((Get-Item -LiteralPath $PersistZip).Length / 1MB)
gh release create $tag $CoreZip $PersistZip $encZip --repo $Repo --title "machine state $hostname $tag" --notes "auto-published by backup.ps1 -Publish (core $coreMB MB + persist $persistMB MB + secrets $secretsMB MB, encrypted)"
if ($LASTEXITCODE -ne 0) { throw "gh release create failed (exit $LASTEXITCODE) - token may lack repo scope or release perms" }

# verify the upload instead of trusting the exit code: a partial upload leaves a release
# that boot.ps1 can only discover as "no secrets asset" on the target machine.
$uploaded = @((gh release view $tag --repo $Repo --json assets 2>$null | ConvertFrom-Json).assets | ForEach-Object { $_.name })
$expectedAssets = @((Split-Path -Leaf $CoreZip), (Split-Path -Leaf $PersistZip), (Split-Path -Leaf $encZip))
$missingAssets = @($expectedAssets | Where-Object { $want = $_; -not ($uploaded | Where-Object { $_ -eq $want }) })
if ($missingAssets.Count -gt 0) {
    throw "release $tag uploaded incompletely - missing asset(s): $($missingAssets -join ', ')"
}
Write-Host "published $tag (core $coreMB MB + persist $persistMB MB + secrets $secretsMB MB encrypted) -> $Repo"

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
