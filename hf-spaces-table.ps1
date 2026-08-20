# List all Hugging Face Spaces across all mainframe accounts (REST API, no hf CLI dependency)
#
# Calls https://huggingface.co/api/spaces per profile token.
# Uses ?author=<username> to return only spaces owned by the logged-in user.
# Lists: space id (namespace/name), sdk, privacy, likes, tags, last modified,
# runtime, and status.

$ErrorActionPreference = 'Stop'
$accountRoot = Join-Path $env:APPDATA 'mainframe\accounts\hf'

if (-not (Test-Path $accountRoot)) {
    Write-Host 'No Hugging Face accounts found.'
    exit 0
}

$accounts = Get-ChildItem $accountRoot -Directory |
    Where-Object { $_.Name -match '^[^\s@]+@[^\s@]+\.[^\s@]+$' } |
    Select-Object -ExpandProperty Name

$rows = @()

foreach ($email in $accounts) {
    $tokenPath = Join-Path $accountRoot "$email\token.txt"
    if (-not (Test-Path $tokenPath)) { continue }
    $token = (Get-Content $tokenPath -Raw).Trim()
    if ([string]::IsNullOrWhiteSpace($token)) { continue }

    $headers = @{ 'Authorization' = "Bearer $token"; 'Accept' = 'application/json' }

    # Detect username from whoami
    $username = $null
    try {
        $me = Invoke-RestMethod -Uri 'https://huggingface.co/api/whoami-v2' -Headers $headers -TimeoutSec 30
        if ($me.name) { $username = $me.name } elseif ($me.id) { $username = $me.id }
    } catch { }

    if ([string]::IsNullOrWhiteSpace($username)) {
        $rows += [pscustomobject]@{
            Account = $email; Space = '-'; SDK = '-'; Privacy = '-'; Likes = 0
            Tags = '-'; LastModified = '-'; CreatedAt = '-'; Runtime = '-'; Status = 'USER ERR: cannot detect HF username'
        }
        continue
    }

    try {
        $spacesRaw = Invoke-RestMethod -Uri "https://huggingface.co/api/spaces?author=$username&limit=1000" -Headers $headers -TimeoutSec 60
    } catch {
        $rows += [pscustomobject]@{
            Account = $email; Space = '-'; SDK = '-'; Privacy = '-'; Likes = 0
            Tags = '-'; LastModified = '-'; CreatedAt = '-'; Runtime = '-'; Status = "API ERR: $($_.Exception.Message)"
        }
        continue
    }

    # Normalize: API may return a single object (not array) when count=1
    $spaces = if ($spacesRaw -is [array]) { $spacesRaw } else { @($spacesRaw) }

    if (-not $spaces -or $spaces.Count -eq 0) {
        $rows += [pscustomobject]@{
            Account = $email; Space = '(none)'; SDK = '-'; Privacy = '-'; Likes = 0
            Tags = '-'; LastModified = '-'; CreatedAt = '-'; Runtime = '-'; Status = 'NO SPACES'
        }
        continue
    }

    foreach ($s in $spaces) {
        $spaceId = if ($s.id) { $s.id } else { '-' }
        $sdk = if ($s.sdk) { $s.sdk } else { '-' }
        $privacy = if ($s.private -eq $true) { 'private' } else { 'public' }
        $likes = if ($s.likes) { [int]$s.likes } else { 0 }
        $tags = if ($s.tags) { ($s.tags | Select-Object -First 3) -join ', ' } else { '-' }
        $lastModified = if ($s.lastModified) {
            try { ([datetime]$s.lastModified).ToString('yyyy-MM-dd') } catch { $s.lastModified }
        } else { '-' }
        $createdAt = if ($s.createdAt) {
            try { ([datetime]$s.createdAt).ToString('yyyy-MM-dd') } catch { $s.createdAt }
        } else { '-' }

        # Detail: runtime stage + lastModified per space (best-effort)
        $runtime = '-'
        $status = '-'
        try {
            $detail = Invoke-RestMethod -Uri "https://huggingface.co/api/spaces/$spaceId" -Headers $headers -TimeoutSec 30 -ErrorAction SilentlyContinue
            if ($detail.runtime -and $detail.runtime.stage) { $runtime = $detail.runtime.stage }
            if ($detail.runtime -and $detail.runtime.errorMessage) { $status = $detail.runtime.errorMessage }
            if ($detail.lastModified -and $lastModified -eq '-') {
                try { $lastModified = ([datetime]$detail.lastModified).ToString('yyyy-MM-dd') } catch { $lastModified = $detail.lastModified }
            }
        } catch { }

        $rows += [pscustomobject]@{
            Account      = $email
            Space        = $spaceId
            SDK          = $sdk
            Privacy      = $privacy
            Likes        = $likes
            Tags         = $tags
            LastModified = $lastModified
            CreatedAt    = $createdAt
            Runtime      = $runtime
            Status       = if ($status -ne '-') { $status } else { 'OK' }
        }
    }
}

if ($rows.Count -eq 0) {
    Write-Host 'No Hugging Face Spaces found.'
    exit 0
}

# Summary by account
Write-Host '### Summary by account'
$summary = $rows | Where-Object { $_.Status -notlike 'API ERR*' -and $_.Space -ne '(none)' } | Group-Object Account | ForEach-Object {
    [pscustomobject]@{
        Account = $_.Name
        Spaces  = $_.Count
    }
}
if ($summary.Count -eq 0) {
    foreach ($email in $accounts) {
        [pscustomobject]@{ Account = $email; Spaces = 0 } | Format-Table -AutoSize
    }
} else {
    $summary | Format-Table -AutoSize
}

Write-Host ''
Write-Host '### Per-space'
$rows | Select-Object Account, Space, SDK, Privacy, Likes, Tags, LastModified, Runtime, Status |
    Format-Table -AutoSize -Wrap

# Markdown
Write-Host ''
Write-Host '### Markdown Table'
Write-Host '| Account | Space | SDK | Privacy | Likes | Tags | Last Modified | Runtime | Status |'
Write-Host '|---------|-------|-----|---------|-------|------|---------------|---------|--------|'
foreach ($r in $rows) {
    $tagsEsc = ($r.Tags -replace '\|', '\\|')
    Write-Host "| $($r.Account) | $($r.Space) | $($r.SDK) | $($r.Privacy) | $($r.Likes) | $tagsEsc | $($r.LastModified) | $($r.Runtime) | $($r.Status) |"
}
