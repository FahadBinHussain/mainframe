# boot.ps1 - mainframe cloud bootstrap. run on ANY fresh windows pc:
#   irm https://raw.githubusercontent.com/FahadBinHussain/mainframe/main/boot.ps1 | iex
# asks for the bitwarden master password ONCE; everything else flows from the vault:
#   vault github token     -> private mainframe-production release (quick + persist zips)
#   vault secrets password -> decrypts mainframe-secrets.zip, the encrypted entry inside
#                             quick, so .ssh, opencode config and account profiles come back too
#   vault tool tokens      -> all *-account.ps1 helpers after restore
# no secrets live in this file. it is public by design - review before running.
#Requires -Version 7
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$Repo = 'FahadBinHussain/mainframe'
$BackupRepo = 'FahadBinHussain/mainframe-production'
$BwServer = 'https://vaultwardenn.onrender.com'
$MainframeDir = Join-Path $HOME 'Downloads\mainframe'
$script:BootTempDir = $null

function Step($m) { Write-Host "`n==> $m" -ForegroundColor Cyan }
function Die($m) {
    if ($script:BootTempDir -and (Test-Path -LiteralPath $script:BootTempDir)) {
        Remove-Item -LiteralPath $script:BootTempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Host "`nFATAL: $m" -ForegroundColor Red
    exit 1
}
function Get-BwItemsOrDie([string]$Search, [string]$Context) {
    $raw = & bw list items --search $Search --raw 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($raw)) {
        Die "failed to read vault items for $Context (bw list items --search '$Search' returned no JSON). ensure the vault is unlocked and contains the expected item."
    }
    try {
        return @($raw | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        Die "failed to parse vault items for $Context (invalid JSON from bw list items --search '$Search')."
    }
}

# --- 0. admin (scoop shims + VSS-based edge restore need it) ---
Step 'checking elevation'
$wid = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not ([Security.Principal.WindowsPrincipal]$wid).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'not admin - relaunching elevated (accept the UAC prompt)'
    Start-Process pwsh -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-Command', "irm https://raw.githubusercontent.com/$Repo/main/boot.ps1 | iex"
    exit
}

# --- 0b. bootstrap tools via built-in winget (no usb, no manual installs) ---
Step 'installing bootstrap tools (powershell 7, git, bitwarden cli, github cli, 7zip)'
foreach ($pkg in @('Microsoft.PowerShell', 'Git.Git', 'Bitwarden.CLI', 'GitHub.cli', '7zip.7zip')) {
    winget install -e --id $pkg --accept-source-agreements --accept-package-agreements --silent 2>$null
    if ($LASTEXITCODE -ne 0) { Write-Host "$($pkg): already installed or winget hiccup (continuing)" }
}
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
# Not every winget install registers on PATH: 7-Zip's installer adds
# nothing at all, so Get-Command 7z fails right after a successful install.
# Probe the well-known install dirs (this used to special-case pwsh only)
# and prepend any that exist, so the check below - and the later bare
# '7z x ...' calls - can actually find the tools.
$knownToolDirs = @(
    (Join-Path $env:ProgramFiles 'PowerShell\7'),
    (Join-Path $env:ProgramFiles 'Git\cmd'),
    (Join-Path $env:ProgramFiles '7-Zip')
)
if (${env:ProgramFiles(x86)}) { $knownToolDirs += Join-Path ${env:ProgramFiles(x86)} '7-Zip' }
foreach ($toolDir in $knownToolDirs) {
    if ((Test-Path -LiteralPath $toolDir) -and ($env:Path -split ';' -notcontains $toolDir)) {
        $env:Path = "$toolDir;$env:Path"
    }
}
# 7-Zip can still be missed when it lives somewhere non-standard (scoop,
# an x86 install the x64 installer upgraded in place, a per-user install).
# Ask the registry where it is, then try the remaining well-known spots.
if (-not (Get-Command 7z -ErrorAction SilentlyContinue)) {
    $sevenZipDirs = @()
    foreach ($regRoot in @('HKLM:\SOFTWARE\7-Zip', 'HKCU:\SOFTWARE\7-Zip')) {
        $reg = Get-ItemProperty -LiteralPath $regRoot -ErrorAction SilentlyContinue
        if ($reg -and $reg.Path) { $sevenZipDirs += $reg.Path }
    }
    $sevenZipFiles = @()
    if ($env:ProgramFiles) { $sevenZipFiles += Join-Path $env:ProgramFiles '7-Zip\7z.exe' }
    if (${env:ProgramFiles(x86)}) { $sevenZipFiles += Join-Path ${env:ProgramFiles(x86)} '7-Zip\7z.exe' }
    if ($env:ProgramW6432) { $sevenZipFiles += Join-Path $env:ProgramW6432 '7-Zip\7z.exe' }
    if ($HOME) { $sevenZipFiles += Join-Path $HOME 'scoop\apps\7zip\current\7z.exe' }
    if ($env:ProgramData) { $sevenZipFiles += Join-Path $env:ProgramData 'scoop\apps\7zip\current\7z.exe' }
    if ($env:LOCALAPPDATA) { $sevenZipFiles += Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\7z.exe' }
    foreach ($sevenZipFile in $sevenZipFiles) {
        if (Test-Path -LiteralPath $sevenZipFile) { $sevenZipDirs += Split-Path $sevenZipFile }
    }
    foreach ($sevenZipDir in $sevenZipDirs) {
        if ((Test-Path -LiteralPath (Join-Path $sevenZipDir '7z.exe')) -and ($env:Path -split ';' -notcontains $sevenZipDir)) {
            $env:Path = "$sevenZipDir;$env:Path"
            Write-Host "7z found at $sevenZipDir - added to PATH for this session"
            break
        }
    }
}
if (-not (Get-Command 7z -ErrorAction SilentlyContinue)) {
    Write-Host "diagnostic: 7z still not found. ProgramFiles=$env:ProgramFiles ProgramFiles(x86)=${env:ProgramFiles(x86)}" -ForegroundColor Yellow
    Write-Host "diagnostic: PATH=$env:Path" -ForegroundColor Yellow
}
foreach ($cmd in @('pwsh', 'git', 'bw', 'gh', '7z')) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) { Die "$cmd missing after winget step - install it manually and re-run" }
}
Write-Host 'all bootstrap tools present'

# --- 1. clone mainframe (public, fast) ---
Step "cloning $Repo"
if (Test-Path $MainframeDir) { Set-Location $MainframeDir; git pull --rebase 2>$null | Out-Null }
else { git clone "https://github.com/$Repo.git" $MainframeDir | Out-Null; if ($LASTEXITCODE -ne 0) { Die "git clone failed (no network? github blocked?)" } }
Set-Location $MainframeDir

$approvalModule = Join-Path $MainframeDir 'vault-approval.psm1'
if (Test-Path -LiteralPath $approvalModule) {
    Import-Module $approvalModule -Force -DisableNameChecking
}

# --- sealed bw email (bw-email.enc.json) ---
# publish-backup.ps1 / seal-bw-email.ps1 seal the vault account email with a
# key derived from the master password (PBKDF2-HMAC-SHA256, 600k iterations,
# AES-256-CBC, HMAC-SHA256 over salt|iv|ciphertext). The blob committed to
# this (public) repo is ciphertext only: useless without the master
# password, which setup asks for anyway. Unsealing it means a fresh machine
# never has to type the email address.
function Get-BwEmailKeyMaterial {
    param([securestring]$Password, [byte[]]$Salt, [int]$Iterations)
    $plain = [System.Net.NetworkCredential]::new('', $Password).Password
    $pwBytes = [System.Text.Encoding]::UTF8.GetBytes($plain)
    $kdf = [System.Security.Cryptography.Rfc2898DeriveBytes]::new($pwBytes, $Salt, $Iterations, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
    try { return ,$kdf.GetBytes(64) } finally { $kdf.Dispose() }
}

function Unseal-BwEmail {
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

# --- 2. bitwarden unlock (1-tap mobile approval or master password) ---
Step 'unlocking bitwarden vault'
# The account lives on a self-hosted Vaultwarden, not bitwarden.com: a
# fresh machine's bw CLI has no server configured and would log in
# against the wrong service. Point it at the right server first
# (idempotent on machines already configured; avoids "Logout required" error).
$bwStatus = & bw status --raw 2>$null | ConvertFrom-Json
if ($bwStatus.serverUrl -ne $BwServer) {
    if ($bwStatus.status -ne 'unauthenticated') {
        & bw logout 2>$null | Out-Null
    }
    & bw config server $BwServer | Out-Null
    $bwStatus = & bw status --raw 2>$null | ConvertFrom-Json
}

$obtainedMasterPw = $null
if ($bwStatus.status -ne 'unlocked') {
    # 1-tap mobile biometric approval (Google-prompt style full-screen intent / ntfy push)
    if (Get-Command Get-VaultMasterPassword -ErrorAction SilentlyContinue) {
        $obtainedMasterPw = Get-VaultMasterPassword -PromptContext 'vault restore'
    }
}

if ($bwStatus.status -eq 'unauthenticated') {
    # Fresh machine: the bw CLI has never been logged in here, so
    # 'bw unlock' fails instantly with 'You are not logged in.' and never
    # prompts for a password at all - which the retry loop below then
    # misreports as 'password rejected'. Log in first, interactively and
    # uncaptured, so the email / password / 2FA prompts behave exactly
    # like a manual 'bw login'. Then lock again so the normal unlock
    # flow below can mint the session key boot.ps1 persists.
    # Resolve the account email without typing it: machine env var, the
    # per-user project config (see below), the address saved by a previous
    # boot on this machine, or git config. A personal address deliberately
    # does NOT live in this repo's tracked files; mainframe.config.json is
    # git-ignored. If nothing has it, ask once and save the answer under
    # %APPDATA%\mainframe for next time.
    $bwEmail = $null
    if (-not [string]::IsNullOrWhiteSpace($env:MAINFRAME_BW_EMAIL)) { $bwEmail = $env:MAINFRAME_BW_EMAIL.Trim() }
    if (-not $bwEmail) {
        # Per-user project setting: copy mainframe.config.example.json to
        # mainframe.config.json in the project root and set bitwardenEmail.
        $configCandidates = @()
        if ($PSScriptRoot) { $configCandidates += Join-Path $PSScriptRoot 'mainframe.config.json' }
        $configCandidates += Join-Path $MainframeDir 'mainframe.config.json'
        foreach ($configPath in $configCandidates) {
            if (Test-Path -LiteralPath $configPath) {
                try {
                    $projectConfig = Get-Content -LiteralPath $configPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                    if ($projectConfig.bitwardenEmail -and ([string]$projectConfig.bitwardenEmail -match '^[^@\s]+@[^@\s]+\.[^@\s]+$')) {
                        $bwEmail = ([string]$projectConfig.bitwardenEmail).Trim()
                        break
                    }
                } catch {
                    Write-Warning "ignoring unreadable project config: $configPath"
                }
            }
        }
    }
    $bwEmailFile = Join-Path $env:APPDATA 'mainframe\bw-email.txt'
    if (-not $bwEmail -and (Test-Path -LiteralPath $bwEmailFile)) {
        $savedEmail = Get-Content -LiteralPath $bwEmailFile -Raw -ErrorAction SilentlyContinue
        if (-not [string]::IsNullOrWhiteSpace($savedEmail)) { $bwEmail = $savedEmail.Trim() }
    }
    if (-not $bwEmail) {
        $gitEmail = & git config --global user.email 2>$null
        if ($gitEmail -and ($gitEmail -match '^[^@\s]+@[^@\s]+\.[^@\s]+$')) { $bwEmail = ([string]$gitEmail).Trim() }
    }
    if (-not $bwEmail) {
        $blobCandidates = @()
        if ($PSScriptRoot) { $blobCandidates += Join-Path $PSScriptRoot 'bw-email.enc.json' }
        $blobCandidates += Join-Path $MainframeDir 'bw-email.enc.json'
        $blobPath = $blobCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        if ($blobPath) {
            if ($obtainedMasterPw) {
                $secPw = ConvertTo-SecureString $obtainedMasterPw -AsPlainText -Force
                $unsealed = Unseal-BwEmail -BlobPath $blobPath -Password $secPw
                if ($unsealed) {
                    $bwEmail = $unsealed
                    Write-Host "email unsealed from bw-email.enc.json - logging in as $bwEmail" -ForegroundColor Green
                }
            }
            if (-not $bwEmail) {
                for ($sealAttempt = 1; $sealAttempt -le 3 -and -not $bwEmail; $sealAttempt++) {
                    $candidatePw = Read-Host "type your bitwarden MASTER PASSWORD (unseals your login email; attempt $sealAttempt of 3)" -AsSecureString
                    $unsealed = Unseal-BwEmail -BlobPath $blobPath -Password $candidatePw
                    if ($unsealed) {
                        $bwEmail = $unsealed
                        $obtainedMasterPw = [System.Net.NetworkCredential]::new('', $candidatePw).Password
                        Write-Host "email unsealed from bw-email.enc.json - logging in as $bwEmail"
                    } elseif ($sealAttempt -lt 3) {
                        Write-Warning 'that password did not unseal the email blob - wrong master password?'
                    }
                }
            }
            if (-not $bwEmail) { Write-Warning 'could not unseal bw-email.enc.json - falling back to typing the email once' }
        }
    }
    if (-not $bwEmail) {
        Write-Host 'bitwarden CLI is not logged in on this machine - one-time login:'
        $bwEmail = Read-Host 'bitwarden EMAIL (asked once per machine; saved for next time)'
    } else {
        Write-Host "bitwarden CLI is not logged in on this machine - logging in as $bwEmail (one-time):"
    }
    $loginOk = $false
    if ($obtainedMasterPw) {
        # Set via the .NET API (same store as $env:BW_PASSWORD)
        [System.Environment]::SetEnvironmentVariable('BW' + '_PASSWORD', $obtainedMasterPw)
        & bw login $bwEmail --passwordenv BW_PASSWORD
        if ($LASTEXITCODE -eq 0) { $loginOk = $true }
        else {
            Remove-Item -Path 'Env:\BW_PASSWORD' -ErrorAction SilentlyContinue
            Write-Warning 'passwordenv login failed - falling back to the interactive login'
        }
    }
    if (-not $loginOk) {
        & bw login $bwEmail
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "login as $bwEmail failed."
            $bwEmail = Read-Host 'bitwarden EMAIL'
            & bw login $bwEmail
            if ($LASTEXITCODE -ne 0) { Die 'bitwarden login failed - re-run boot.ps1 and complete the login prompts.' }
        }
    }
    New-Item -ItemType Directory -Force -Path (Split-Path $bwEmailFile) | Out-Null
    Set-Content -LiteralPath $bwEmailFile -Value $bwEmail -Encoding UTF8
    & bw lock 2>$null | Out-Null
    $bwStatus = & bw status --raw 2>$null | ConvertFrom-Json
}
if ($bwStatus.status -ne 'unlocked') {
    $session = $null

    $invokeBwUnlock = {
        param([switch]$UsePasswordEnv)
        $savedEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            if ($UsePasswordEnv) { $unlockOutput = @(& bw unlock --raw --passwordenv BW_PASSWORD 2>&1) }
            else { $unlockOutput = @(& bw unlock --raw 2>&1) }
            $unlockExit = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $savedEap
        }
        if ($unlockExit -ne 0) { return $null }
        $unlockSession = $unlockOutput | Where-Object { $_ -is [string] -and -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 1
        if ([string]::IsNullOrWhiteSpace($unlockSession)) { return $null }
        return $unlockSession
    }

    if ($obtainedMasterPw) {
        [System.Environment]::SetEnvironmentVariable('BW' + '_PASSWORD', $obtainedMasterPw)
        try {
            $session = & $invokeBwUnlock -UsePasswordEnv
        } finally {
            Remove-Item -Path 'Env:\BW_PASSWORD' -ErrorAction SilentlyContinue
        }
        if ($session) {
            Write-Host 'vault unlocked successfully via 1-tap mobile approval' -ForegroundColor Green
        }
    }

    if (-not $session -and -not [string]::IsNullOrWhiteSpace($env:BW_PASSWORD)) {
        $session = & $invokeBwUnlock -UsePasswordEnv
        if (-not $session) {
            Write-Warning 'BW_PASSWORD was rejected. Falling back to interactive unlock.'
        }
    }

    if (-not $session) {
        Write-Warning '1-tap mobile approval not available or rejected. Falling back to MANUAL PASSWORD ENTRY.'
        $attempt = 0
        while (-not $session -and $attempt -lt 3) {
            $attempt++
            # Prompt here instead of relying on 'bw unlock' prompting: when the
            # unlock output is captured (as $invokeBwUnlock does), bw's own
            # interactive prompt never reaches the user. A secure prompt plus
            # --passwordenv keeps the password env-scoped, in memory only, and
            # never written to disk.
            $securePw = Read-Host "type your bitwarden MASTER PASSWORD (attempt $attempt of 3)" -AsSecureString
            $env:BW_PASSWORD = [Net.NetworkCredential]::new('', $securePw).Password
            try {
                $session = & $invokeBwUnlock -UsePasswordEnv
            } finally {
                Remove-Item -Path 'Env:\BW_PASSWORD' -ErrorAction SilentlyContinue
            }
            if (-not $session -and $attempt -lt 3) {
                Write-Warning 'Bitwarden rejected that password. Please try again.'
            }
        }
    }
    if (-not $session) {
        Die 'vault unlock failed after 3 attempts. verify your master password and keyboard layout, then run boot.ps1 again.'
    }
    $env:BW_SESSION = $session
    Remove-Item -Path 'Env:\BW_PASSWORD' -ErrorAction SilentlyContinue
    $obtainedMasterPw = $null
    # persist for the restore helpers that read session.key
    $sk = Join-Path $env:APPDATA 'mainframe\accounts\bitwarden\session.key'
    New-Item -ItemType Directory -Force -Path (Split-Path $sk) | Out-Null
    Set-Content -LiteralPath $sk -Value $session -Encoding UTF8
} else {
    Write-Host 'vault already unlocked'
}

# --- 3. github token from vault (for the private zip) ---
# take the vault item for the REPO OWNER, not the first token found: the vault holds
# tokens for six github accounts and the first one alphabetically (algojectt) cannot
# see this private repo, so gh answered "release not found" on a machine that had
# done nothing wrong. also no dependency on %APPDATA%\mainframe\accounts\github:
# on a FRESH pc that profile dir only exists AFTER the secrets archive arrives, so
# reading it here (the old code did) guaranteed failure exactly where boot is first used.
$repoOwner = ($BackupRepo -split '/')[0]
Step "fetching github token for $repoOwner from vault"
$ghItems = Get-BwItemsOrDie -Search 'github.com' -Context "github token for $repoOwner"
$ownerItem = $ghItems | Where-Object { $_.name -eq "github.com - $repoOwner" } | Select-Object -First 1
if (-not $ownerItem) {
    $found = (@($ghItems) | ForEach-Object { $_.name }) -join ', '
    Die "vault has no item named 'github.com - $repoOwner' - that is the token which can read $BackupRepo. github items in vault: $found. fix: github-account.ps1 token-add"
}
$ghToken = $null
$ownerNotes = [string]$ownerItem.notes
$ghTokenMatch = [regex]::Match($ownerNotes, '(gh[pousr]_[A-Za-z0-9_]{30,})')
if ($ghTokenMatch.Success -and $ghTokenMatch.Groups.Count -gt 1) { $ghToken = $ghTokenMatch.Groups[1].Value }
if (-not $ghToken) { Die "vault item 'github.com - $repoOwner' has no github token in its notes. fix: github-account.ps1 token-add" }

# --- 3b. secrets archive password (same search + regex publish-backup.ps1 uses) ---
Step 'fetching secrets archive password from vault'
$secretsItems = Get-BwItemsOrDie -Search 'mainframe-production' -Context 'secrets archive password'
$secretsItem = $secretsItems | Where-Object { $_.name -eq 'mainframe-production' } | Select-Object -First 1
if (-not $secretsItem) { Die "no vault item named 'mainframe-production' - it holds the '[secrets archive password]' notes header the release is encrypted with" }
if ($secretsItem.notes -notmatch '(?m)^\[secrets archive password\]\s*\r?\n\s*(\S+)') {
    Die "vault item 'mainframe-production' has no '[secrets archive password]' notes header"
}
$secretsPassword = $Matches[1]

# --- 4. restore mode choice (before download - Q skips the persist zip) ---
Step 'restore mode'
Write-Host '[F]ull = everything (~30min: bulk apps, pnpm/uv, winget, tasks, patches)'
Write-Host '[Q]uick = essentials only (~10min: edge profile, opencode, ditto, secrets, automata-private)'
$mode = 'full'
$pick = Read-Host 'mode? [F]ull/[Q]uick (default F)'
if ($pick -match '^(q|quick)$') { $mode = 'quick' }

# --- 4b. download machine-state zips from private release store ---
# Q = quick only (~225MB: edge profile + config + skills + ditto settings + starred-only Ditto.db + flameshot settings + encrypted secrets)
# F = quick + persist (persist = scoop app data, the only full-mode-only piece)
# the encrypted secrets archive rides INSIDE quick, so both modes get secrets in one download.
Step "downloading machine-state zips from $BackupRepo"
$env:GH_TOKEN = $ghToken
$release = gh release view --repo $BackupRepo --json tagName,assets 2>$null | ConvertFrom-Json
if (-not $release) { Die "no releases in $BackupRepo. run backup.ps1 -Publish on the source machine first." }
$quickAsset = $release.assets | Where-Object name -like '*-quick.zip' | Select-Object -First 1
if (-not $quickAsset) { Die "release $($release.tagName) has no mainframe-quick.zip asset (the core/persist/secrets 3-asset layout was retired - republish from the source machine: .\backup.ps1 -Publish)" }
$wantPersist = $mode -eq 'full'
if ($wantPersist) {
    $persistAsset = $release.assets | Where-Object name -like '*-persist.zip' | Select-Object -First 1
    if (-not $persistAsset) { Die "release $($release.tagName) has no persist asset needed for full restore" }
}
$script:BootTempDir = Join-Path $env:TEMP "mainframe-boot-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $script:BootTempDir -ErrorAction Stop | Out-Null
$quickPath = Join-Path $script:BootTempDir $quickAsset.name
gh release download $release.tagName --repo $BackupRepo --pattern '*-quick.zip' --output $quickPath
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $quickPath)) { Die "quick download failed (token may lack repo scope for private repo $BackupRepo)" }
$persistPath = $null
if ($wantPersist) {
    $persistPath = Join-Path $script:BootTempDir $persistAsset.name
    gh release download $release.tagName --repo $BackupRepo --pattern '*-persist.zip' --output $persistPath
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $persistPath)) { Die "persist download failed" }
}

# --- 5. extract + restore ---
Write-Host "extracting $mode assets + running $mode restore (walk away)"
$extract = Join-Path $script:BootTempDir 'extract'
7z x $quickPath "-o$extract" -y | Out-Null
if ($LASTEXITCODE -gt 1) { Die "7z quick extract failed (is 7zip installed? scoop install 7zip)" }
if ($persistPath) {
    7z x $persistPath "-o$extract" -y | Out-Null
    if ($LASTEXITCODE -gt 1) { Die "7z persist extract failed" }
}
# the encrypted secrets archive travels INSIDE quick. a machine restored without it loses
# .ssh keys, opencode config and the mainframe account profiles - refuse instead.
$encBlob = Join-Path $extract 'mainframe-secrets.zip'
if (-not (Test-Path $encBlob)) {
    Die "$($quickAsset.name) carries no mainframe-secrets.zip entry - restoring it would give you a partial machine. republish from the source machine: .\backup.ps1 -Publish"
}
# decrypt it into the restore root - restore.ps1 looks for
# $BackupRoot\tool-secrets.zip and restores it with restore-secrets.ps1.
7z x $encBlob "-o$extract" "-p$secretsPassword" -y | Out-Null
if ($LASTEXITCODE -gt 1) { Die "secrets decrypt failed (exit $LASTEXITCODE) - wrong password in vault item 'mainframe-production'?" }
if (-not (Test-Path (Join-Path $extract 'tool-secrets.zip'))) {
    Die "decrypted $encBlob but tool-secrets.zip is not at the restore root - the archive layout changed"
}
Write-Host "secrets archive decrypted -> $extract\tool-secrets.zip"

Step 'phase 1: repo restore (scoop, pnpm, uv, tasks, secrets)'
try {
    $restoreScript = Join-Path $MainframeDir 'restore.ps1'
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $restoreScript -Mode $mode -BackupRoot $extract
    if ($LASTEXITCODE -ne 0) { Die "restore.ps1 phase 1 failed (exit $LASTEXITCODE) - scroll up for the exact error" }
} catch {
    Die "restore.ps1 phase 1 failed: $($_.Exception.Message)"
}

# --- 6. tailscale (vault authkey) ---
Step 'provisioning tailscale'
try {
    $tailscaleScript = Join-Path $MainframeDir 'tailscale-account.ps1'
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $tailscaleScript provision 2>$null
} catch { Write-Warning "tailscale provision failed: $($_.Exception.Message) - do it manually later" }

# The restore root contains decrypted secrets; remove the per-run workspace when done.
try {
    Remove-Item -LiteralPath $script:BootTempDir -Recurse -Force -ErrorAction Stop
    $script:BootTempDir = $null
} catch {
    Write-Warning "could not remove temporary restore workspace '$script:BootTempDir': $($_.Exception.Message)"
}

# --- 7. report ---
Step 'DONE - machine restored'
Write-Host @"
  what to check:
  - edge extensions: cws-only ones may need ONE enable click each (edge://extensions)
  - vault helpers:  <repo>\*-account.ps1 status-all
  - vpn:            <repo>\..\automata-private\protonvpn.com\proton-gui.ps1
"@ -ForegroundColor Green
