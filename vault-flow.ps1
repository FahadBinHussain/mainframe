<#
.SYNOPSIS
    the ONE vault flow, callable from windows and from linux.

.DESCRIPTION
    This is the single implementation of the vault leg. Windows runs it
    through the module directly, linux runs it through this CLI - there is no
    second, python copy of the flow any more.

    What it does, in order:

      1. if a fresh cached session exists (the profile root's
         accounts/bitwarden/session.key, 60 minute TTL), it is reused and the
         phone is NOT asked for anything.
      2. otherwise the master password is fetched with the 1-tap phone
         approval, exactly like the windows flow: an RSA-2048 keypair, a
         2-digit code, an ntfy push, and the ciphertext comes back over the
         relay (or ntfy directly).
      3. on a machine where the bw CLI is logged out, the sealed email blob
         (bw-email.enc.json) is unsealed with that master password and the CLI
         is logged in.
      4. the vault is unlocked, the session key is cached (0600), and the
         items are read with the cached session.

    Output: a JSON object on stdout (with -Json, which is the default for
    machine callers). The master password is NEVER part of the output.

        {
          "githubToken":       "...",
          "secretsPassword":   "...",
          "email":             "...",
          "sessionCached":     true,
          "approvalRequested": false,
          "sessionPath":       "/root/.config/mainframe/accounts/bitwarden/session.key",
          "ttlMinutes":        60
        }

    Logs go to stderr so stdout stays machine-readable.

.EXAMPLE
    pwsh -NoProfile -File vault-flow.ps1 -Json
#>
param(
    [string]$Checkout = $PSScriptRoot,
    [string]$NtfyTopic = $null,
    [string]$Server = $null,
    [string]$PagesBase = $null,
    [int]$TimeoutSeconds = 600,
    [string]$PromptContext = 'vault restore',
    [string]$BwPath = 'bw',
    [switch]$Lock,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'vault-secret.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'vault-approval.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'mainframe-json.psm1') -Force -DisableNameChecking

function Write-FlowLog {
    param([string]$Message)
    # stderr, so stdout stays a clean JSON document
    [Console]::Error.WriteLine("vault-flow: $Message")
}

function Get-BwStatus {
    $raw = & $BwPath status 2>$null | Out-String
    if (-not $raw.Trim()) { throw 'bw status produced no output - is the bitwarden CLI installed and on PATH?' }
    return $raw | ConvertFrom-Json
}

function Get-VaultSecretsFromItems {
    <#
    .SYNOPSIS
        pull the github token and the mainframe-production secrets password
        out of the vault items.

    .DESCRIPTION
        the same rules the python implementation used, so the two never drift:
        a github token is `gh[pousr]_...`, an item is preferred when its name
        holds BOTH "github" and the repo owner, and the secrets password is
        the notes of the mainframe-production item.
    #>
    param([object[]]$Items)

    $repoOwner = 'fahadbinhussain'
    $tokenPattern = 'gh[pousr]_[A-Za-z0-9_]{20,}'
    $githubToken = ''
    $secretsPassword = ''

    foreach ($item in $Items) {
        $name = ([string]$item.name).ToLowerInvariant()
        $notes = [string]$item.notes
        if (-not $githubToken -and $name.Contains('github') -and $name.Contains($repoOwner)) {
            if ($notes -match $tokenPattern) { $githubToken = $Matches[0] }
        }
        if (-not $secretsPassword -and $name.Contains('mainframe-production')) {
            $secretsPassword = $notes.Trim()
        }
    }
    if (-not $githubToken) {
        foreach ($item in $Items) {
            $name = ([string]$item.name).ToLowerInvariant()
            if ($name.Contains('github') -and ([string]$item.notes) -match $tokenPattern) {
                $githubToken = $Matches[0]
                break
            }
        }
    }
    return [pscustomobject]@{ GitHubToken = $githubToken; SecretsPassword = $secretsPassword }
}

# --- 0. lock on demand (the twin of vault-lock.ps1) ---
if ($Lock) {
    Lock-VaultSession -BwPath $BwPath
    Write-FlowLog "vault session purged at $(Get-MainframeSessionKeyPath)"
    if ($Json) { ConvertTo-Json -InputObject ([ordered]@{ locked = $true; sessionPath = Get-MainframeSessionKeyPath }) -Compress }
    exit 0
}

# --- 1. the cached session (no phone, no master password) ---
$cached = Get-VaultSession
$status = Get-BwStatus
$approvalRequested = $false
$email = ''

if ($cached -and $status.status -ne 'unauthenticated') {
    Write-FlowLog "reusing the cached session (TTL $(Get-VaultSessionTtlMinutes) minutes) - no phone approval needed"
    $items = @(ConvertFrom-JsonArray -Json (& $BwPath list items --session $cached 2>$null | Out-String))
} else {
    if ($cached -and $status.status -eq 'unauthenticated') {
        Write-FlowLog 'the cached session is useless while bw is logged out - asking the phone again'
        Clear-VaultSessionCache
    }
    if ($status.status -eq 'unauthenticated') {
        # a fresh machine: the email comes out of the sealed blob, unlocked by
        # the very master password the phone approval hands over
        Write-FlowLog 'bw is logged out - the 1-tap approval will also unseal the account email'
    }

    Write-FlowLog 'triggering the 1-tap mobile approval'
    $approvalRequested = $true
    $password = Get-VaultMasterPassword -NtfyTopic $NtfyTopic -Server $Server -PagesBase $PagesBase `
        -TimeoutSeconds $TimeoutSeconds -PromptContext $PromptContext
    if (-not $password -or $password -eq '__SESSION_ALREADY_UNLOCKED__') {
        throw 'the phone approval did not return a master password'
    }

    if ($status.status -eq 'unauthenticated') {
        $blob = Join-Path $Checkout 'bw-email.enc.json'
        if (Test-Path -LiteralPath $blob) {
            $secure = ConvertTo-SecureString $password -AsPlainText -Force
            $email = Unseal-BwEmail -BlobPath $blob -Password $secure
            if ($email) { Write-FlowLog 'email unsealed from bw-email.enc.json' }
        }
        if (-not $email) { $email = [string]$env:MAINFRAME_BW_EMAIL }
        if (-not $email) {
            throw 'the bw CLI is logged out and the account email could not be unsealed - set MAINFRAME_BW_EMAIL or run the setup that asks for the master password'
        }
        [System.Environment]::SetEnvironmentVariable('BW_PASSWORD', $password)
        try {
            & $BwPath login $email --passwordenv BW_PASSWORD 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "bw login failed for $email" }
        } finally {
            Remove-Item -Path 'Env:\BW_PASSWORD' -ErrorAction SilentlyContinue
        }
    }

    [System.Environment]::SetEnvironmentVariable('BW_PASSWORD', $password)
    try {
        $unlockOut = @(& $BwPath unlock --raw --passwordenv BW_PASSWORD 2>&1)
    } finally {
        Remove-Item -Path 'Env:\BW_PASSWORD' -ErrorAction SilentlyContinue
        $password = $null
    }
    $session = $unlockOut | Where-Object { $_ -is [string] -and $_ -match '^[A-Za-z0-9+/=]{20,}$' } | Select-Object -Last 1
    if (-not $session) { throw "bw unlock did not return a session key: $($unlockOut -join ' ')" }
    Set-VaultSessionKey -SessionKey $session | Out-Null
    Write-FlowLog "vault session cached at $(Get-MainframeSessionKeyPath)"
    $items = @(ConvertFrom-JsonArray -Json (& $BwPath list items --session $session.Trim() 2>$null | Out-String))
}

$secrets = Get-VaultSecretsFromItems -Items $items
if (-not $secrets.GitHubToken) { Write-FlowLog 'WARNING: no github token found in the vault' }
if (-not $secrets.SecretsPassword) { Write-FlowLog 'WARNING: no mainframe-production secrets password found in the vault' }

$result = [ordered]@{
    githubToken       = $secrets.GitHubToken
    secretsPassword   = $secrets.SecretsPassword
    email             = $email
    sessionCached     = $true
    approvalRequested = $approvalRequested
    sessionPath       = Get-MainframeSessionKeyPath
    ttlMinutes        = Get-VaultSessionTtlMinutes
}

if ($Json) {
    # compress the JSON so a caller cannot mistake the document for a log
    ConvertTo-Json -InputObject $result -Compress -Depth 4
} else {
    Write-Host "github token    : $(if ($secrets.GitHubToken) { 'found' } else { 'MISSING' })"
    Write-Host "secrets password: $(if ($secrets.SecretsPassword) { 'found' } else { 'MISSING' })"
    Write-Host "session path    : $(Get-MainframeSessionKeyPath)"
}
