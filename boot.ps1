# boot.ps1 - mainframe cloud bootstrap. run on ANY fresh windows pc:
#   irm https://raw.githubusercontent.com/FahadBinHussain/mainframe/main/boot.ps1 | iex
# asks for the bitwarden master password ONCE; everything else flows from the vault:
#   vault github token -> private mainframe-production release zip (machine state)
#   vault tool tokens  -> all *-account.ps1 helpers after restore
# no secrets live in this file. it is public by design - review before running.
#Requires -Version 7
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$Repo = 'FahadBinHussain/mainframe'
$BackupRepo = 'FahadBinHussain/mainframe-production'
$MainframeDir = Join-Path $HOME 'Downloads\mainframe'

function Step($m) { Write-Host "`n==> $m" -ForegroundColor Cyan }
function Die($m) { Write-Host "`nFATAL: $m" -ForegroundColor Red; exit 1 }

# --- 0. admin (scoop shims + VSS-based edge restore need it) ---
Step 'checking elevation'
$wid = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not ([Security.Principal.WindowsPrincipal]$wid).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'not admin - relaunching elevated (accept the UAC prompt)'
    Start-Process pwsh -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-Command', "irm https://raw.githubusercontent.com/$Repo/main/boot.ps1 | iex"
    exit
}

# --- 0b. bootstrap tools via built-in winget (no usb, no manual installs) ---
Step 'installing bootstrap tools (git, bitwarden cli, github cli, 7zip)'
foreach ($pkg in @('Git.Git', 'Bitwarden.CLI', 'GitHub.cli', '7zip.7zip')) {
    winget install -e --id $pkg --accept-source-agreements --accept-package-agreements --silent 2>$null
    if ($LASTEXITCODE -ne 0) { Write-Host "$($pkg): already installed or winget hiccup (continuing)" }
}
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
foreach ($cmd in @('git', 'bw', 'gh', '7z')) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) { Die "$cmd missing after winget step - install it manually and re-run" }
}
Write-Host 'all bootstrap tools present'

# --- 1. clone mainframe (public, fast) ---
Step "cloning $Repo"
if (Test-Path $MainframeDir) { Set-Location $MainframeDir; git pull --rebase 2>$null | Out-Null }
else { git clone "https://github.com/$Repo.git" $MainframeDir | Out-Null; if ($LASTEXITCODE -ne 0) { Die "git clone failed (no network? github blocked?)" } }
Set-Location $MainframeDir

# --- 2. bitwarden unlock (the ONE password you type) ---
Step 'unlocking bitwarden vault'
$bwStatus = & bw status --raw 2>$null | ConvertFrom-Json
if ($bwStatus.status -ne 'unlocked') {
    $session = & bw unlock --raw --passwordenv BW_PASSWORD 2>$null
    if (-not $session -or $LASTEXITCODE -ne 0) {
        # bw unlock without env var: fall back to interactive prompt (still one password)
        Write-Host 'type your bitwarden MASTER PASSWORD:'
        $session = & bw unlock --raw
    }
    if (-not $session) { Die 'vault unlock failed (wrong password?)' }
    $env:BW_SESSION = $session
    # persist for the restore helpers that read session.key
    $sk = Join-Path $env:APPDATA 'mainframe\accounts\bitwarden\session.key'
    New-Item -ItemType Directory -Force -Path (Split-Path $sk) | Out-Null
    Set-Content -LiteralPath $sk -Value $session -Encoding UTF8
} else {
    Write-Host 'vault already unlocked'
}

# --- 3. github token from vault (for the private zip) ---
Step 'fetching github token from vault'
$ghProfile = Get-ChildItem (Join-Path $env:APPDATA 'mainframe\accounts\github') -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
$ghToken = $null
if ($ghProfile) {
    $items = & bw list items --search 'github.com' --raw 2>$null | ConvertFrom-Json
    foreach ($it in $items) {
        if ($it.notes -match '(gh[pousr]_[A-Za-z0-9_]{30,})') { $ghToken = $Matches[1]; break }
    }
}
if (-not $ghToken) { Die "no github token in vault (searched 'github.com' items). add one: github-account.ps1 token-add" }

# --- 4. download latest machine-state zip from private release store ---
Step "downloading latest machine-state zip from $BackupRepo"
$env:GH_TOKEN = $ghToken
$release = gh release view --repo $BackupRepo --json tagName,assets 2>$null | ConvertFrom-Json
if (-not $release) { Die "no releases in $BackupRepo. run backup.ps1 -Publish on the source machine first." }
$asset = $release.assets | Where-Object name -like '*.zip' | Select-Object -First 1
if (-not $asset) { Die "release $($release.tagName) has no zip asset" }
$zipPath = Join-Path $env:TEMP $asset.name
gh release download $release.tagName --repo $BackupRepo --pattern '*.zip' --output $zipPath
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $zipPath)) { Die "release download failed (token may lack repo scope for private repo $BackupRepo)" }
Write-Host ("downloaded {0:N0} MB ({1})" -f ((Get-Item $zipPath).Length/1MB), $release.tagName)

# --- 5. extract + full restore ---
Step 'extracting backup + running full restore (15-30 min, walk away)'
$extract = Join-Path $env:TEMP 'mainframe-boot-extract'
if (Test-Path $extract) { Remove-Item $extract -Recurse -Force }
7z x $zipPath "-o$extract" -y | Out-Null
if ($LASTEXITCODE -gt 1) { Die "7z extract failed (is 7zip installed? scoop install 7zip)" }

Step 'phase 1: repo restore (scoop, pnpm, uv, tasks, secrets)'
& (Join-Path $MainframeDir 'restore.ps1') -Mode full -ExcludeSecrets -BackupRoot $extract
if ($LASTEXITCODE -ne 0) { Die "restore.ps1 phase 1 failed - scroll up for the exact error" }

# --- 6. tailscale (vault authkey) ---
Step 'provisioning tailscale'
try {
    & (Join-Path $MainframeDir 'tailscale-account.ps1') provision 2>$null
} catch { Write-Warning "tailscale provision failed: $($_.Exception.Message) - do it manually later" }

# --- 7. report ---
Step 'DONE - machine restored'
Write-Host @"
  what to check:
  - edge extensions: cws-only ones may need ONE enable click each (edge://extensions)
  - vault helpers:  <repo>\*-account.ps1 status-all
  - vpn:            <repo>\..\automata\protonvpn.com\proton-gui.ps1
"@ -ForegroundColor Green
