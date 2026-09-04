# publish-backup.ps1 - upload mainframe-backup.zip to private release store
# usage: publish-backup.ps1 [-ZipPath <path>] [-Keep 10]
# auth chain: bitwarden session.key (from unlock.ps1) -> vault github token -> gh release upload
# fails LOUD on: locked vault, missing token, bad scope, gh error. no fallbacks.
param(
    [string]$ZipPath,
    [string]$Repo = 'FahadBinHussain/mainframe-production',
    [int]$Keep = 10
)
$ErrorActionPreference = 'Stop'

if (-not $ZipPath) { $ZipPath = Join-Path $PSScriptRoot 'mainframe-backup.zip' }
if (-not (Test-Path -LiteralPath $ZipPath)) { throw "backup zip not found: $ZipPath (run backup.ps1 first)" }

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

# --- create release, upload zip (hostname-tagged so laptop+desktop can both publish) ---
$hostname = $env:COMPUTERNAME
$tag = '{0}-{1}' -f (Get-Date -Format 'yyyy-MM-dd-HHmm'), $hostname
$size = '{0:N0} MB' -f ((Get-Item -LiteralPath $ZipPath).Length / 1MB)
gh release create $tag $ZipPath --repo $Repo --title "machine state $hostname $tag" --notes "auto-published by backup.ps1 -Publish ($size)"
if ($LASTEXITCODE -ne 0) { throw "gh release create failed (exit $LASTEXITCODE) - token may lack repo scope or release perms" }
Write-Host "published $tag ($size) -> $Repo"

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
