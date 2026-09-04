# publish-backup.ps1 - upload split backup zips to private release store
# usage: publish-backup.ps1 [-CoreZip <path>] [-PersistZip <path>] [-Keep 10]
# auth chain: bitwarden session.key (from unlock.ps1) -> vault github token -> gh release upload
# fails LOUD on: locked vault, missing token, bad scope, missing zips, gh error. no fallbacks.
param(
    [string]$CoreZip,
    [string]$PersistZip,
    [string]$Repo = 'FahadBinHussain/mainframe-production',
    [int]$Keep = 10
)
$ErrorActionPreference = 'Stop'

if (-not $CoreZip) { $CoreZip = Join-Path $PSScriptRoot 'mainframe-core.zip' }
if (-not $PersistZip) { $PersistZip = Join-Path $PSScriptRoot 'mainframe-persist.zip' }
if (-not (Test-Path -LiteralPath $CoreZip)) { throw "core zip not found: $CoreZip (run backup.ps1 first)" }
if (-not (Test-Path -LiteralPath $PersistZip)) { throw "persist zip not found: $PersistZip (was backup taken with -SkipPersist? both zips are required)" }

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
$ghProfiles = Get-ChildItem (Join-Path $env:APPDATA 'mainframe\accounts\github') -Directory -ErrorAction SilentlyContinue
if (-not $ghProfiles) { throw "no github profile in %APPDATA%\mainframe\accounts\github - run github-account.ps1 token-add first" }
$email = $ghProfiles[0].Name
# token lives under the [tokens] header of the 'github.com - <login>' item
# (same lookup github-account.ps1 uses)
$token = Read-VaultSecret -Email $email -NamePattern 'github.com - *' -ValueRegex '(ghp_|github_pat_)[A-Za-z0-9_]+'
if (-not $token) { throw "no github token found in vault for $email (item like 'github.com*')" }
$env:GH_TOKEN = $token

# --- scope preflight: private release upload needs repo access ---
$me = gh api user --jq .login 2>&1
if ($LASTEXITCODE -ne 0) { throw "github token rejected: $me" }
Write-Host "publishing as $me -> $Repo"

# --- create release, upload both zips (hostname-tagged so laptop+desktop can both publish) ---
$hostname = $env:COMPUTERNAME
$tag = '{0}-{1}' -f (Get-Date -Format 'yyyy-MM-dd-HHmm'), $hostname
$coreMB = '{0:N0}' -f ((Get-Item -LiteralPath $CoreZip).Length / 1MB)
$persistMB = '{0:N0}' -f ((Get-Item -LiteralPath $PersistZip).Length / 1MB)
gh release create $tag $CoreZip $PersistZip --repo $Repo --title "machine state $hostname $tag" --notes "auto-published by backup.ps1 -Publish (core $coreMB MB + persist $persistMB MB)"
if ($LASTEXITCODE -ne 0) { throw "gh release create failed (exit $LASTEXITCODE) - token may lack repo scope or release perms" }
Write-Host "published $tag (core $coreMB MB + persist $persistMB MB) -> $Repo"

# --- prune: keep newest $Keep per hostname ---
$releases = gh release list --repo $Repo --limit 200 --json tagName 2>$null | ConvertFrom-Json
$mine = @($releases | Where-Object { $_.tagName -like "*-$hostname" })
if ($mine.Count -gt $Keep) {
    $old = $mine | Select-Object -First ($mine.Count - $Keep)
    foreach ($r in $old) {
        gh release delete $r.tagName --repo $Repo --cleanup-tag --yes 2>&1 | Out-Null
        Write-Host "pruned old release $($r.tagName)"
    }
}
Write-Host "done: $Repo now holds $([Math]::Min($mine.Count, $Keep)) releases for $hostname"
