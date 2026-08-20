# Supabase usage/quota table across all mainframe accounts (Management REST API, no CLI dependency).
# Mirrors neon-hours-table.ps1. Profiles keyed by email under
#   %APPDATA%\mainframe\accounts\supabase\<email>\token.txt  (Personal Access Token sbp_...)
#
# Free plan quotas (official: https://supabase.com/pricing, per project, monthly):
#   - Database: 500 MB  (signal: disk util `fs_used_bytes` from GET /v1/projects/{ref}/config/disk/util)
#   - Storage:  1 GB    (no public per-project usage endpoint on the Management API — not reported)
#   - Egress:   5 GB    (no public per-project usage endpoint on the Management API — not reported)
#   - API requests: no hard Free cap (analytics usage.api-requests-count reported when readable)
#
# ⚠️ Metering reality (verified 2026-08-20):
#   - `fs_used_bytes` includes postgres + system overhead, not just user tables — it is the same
#     number the Supabase dashboard "Database size" gauge shows (byte-identical), so treat it as
#     the DB-against-quota signal.
#   - `config/disk/util` returns HTTP 500 with "Failed to get disk utilization" on INACTIVE
#     (paused) projects — expected, not an error. API-count analytics return empty results there too.
#   - `config/disk` (allocated size, default 8 GB gp3) always works and is reported as Disk_GB.
#   - rate limits: 120 req/min per user per project/org; analytics endpoints 30 req/min.
#
# Design decision: report per project. Status = OVER / LOW / OK against the 500 MB Free DB quota
# when disk util is readable; 'n/a' when the project is paused. `-Json` for scheduled consumers.

param(
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
$accountRoot = Join-Path $env:APPDATA 'mainframe\accounts\supabase'
$apiBase = 'https://api.supabase.com'

# Free plan: 500 MB database per project. Overridable for future plan changes.
$FREE_DB_MB  = if ($env:SUPABASE_FREE_DB_MB)  { [double]$env:SUPABASE_FREE_DB_MB }  else { 500 }
$LOW_PCT     = if ($env:SUPABASE_LOW_PCT)     { [double]$env:SUPABASE_LOW_PCT }     else { 0.85 }

if (-not (Test-Path $accountRoot)) {
    Write-Host 'No supabase accounts found.'
    exit 0
}

$accounts = Get-ChildItem $accountRoot -Directory |
    Where-Object { $_.Name -match '^[^\s@]+@[^\s@]+\.[^\s@]+$' } |
    Select-Object -ExpandProperty Name

$results = @()
foreach ($email in $accounts) {
    $tokenPath = Join-Path $accountRoot "$email\token.txt"
    if (-not (Test-Path $tokenPath)) { continue }
    $token = (Get-Content $tokenPath -Raw).Trim()
    if ([string]::IsNullOrWhiteSpace($token)) { continue }

    $headers = @{ 'Authorization' = "Bearer $token"; 'Accept' = 'application/json' }

    try {
        $projects = @((Invoke-RestMethod -Uri "$apiBase/v1/projects" -Headers $headers) | Where-Object { $_ })
    } catch {
        $results += [pscustomobject]@{
            Account=$email; Project='-'; Ref='-'; Org='-'; Status="API ERR: $($_.Exception.Message)"
            Disk_MB=0; Disk_GB=0; Api_Reqs=0; Quota_MB=$FREE_DB_MB; Pct=0
        }
        continue
    }

    if ($projects.Count -eq 0) {
        $results += [pscustomobject]@{
            Account=$email; Project='(no projects)'; Ref='-'; Org='-'; Status='NO PROJECTS'
            Disk_MB=0; Disk_GB=0; Api_Reqs=0; Quota_MB=$FREE_DB_MB; Pct=0
        }
        continue
    }

    foreach ($p in $projects) {
        $orgName = if ($p.organization_slug) { $p.organization_slug } else { $p.organization_id }

        # Allocated disk (works always, even paused).
        $diskGB = 0
        try {
            $d = Invoke-RestMethod -Uri "$apiBase/v1/projects/$($p.ref)/config/disk" -Headers $headers
            if ($d.attributes.size_gb) { $diskGB = [double]$d.attributes.size_gb }
        } catch { }

        # DB usage (fs_used_bytes) — 500 on paused projects, that is expected.
        $usedMB = $null
        $apiReqs = $null
        try {
            $u = Invoke-RestMethod -Uri "$apiBase/v1/projects/$($p.ref)/config/disk/util" -Headers $headers
            if ($u.metrics.fs_used_bytes) { $usedMB = [math]::Round([double]$u.metrics.fs_used_bytes / 1MB, 1) }
        } catch { }

        try {
            $a = Invoke-RestMethod -Uri "$apiBase/v1/projects/$($p.ref)/analytics/endpoints/usage.api-requests-count" -Headers $headers
            if ($a.result -and $a.result.Count -gt 0 -and $null -ne $a.result[0].count) { $apiReqs = [long]$a.result[0].count }
        } catch { }

        $used = if ($null -ne $usedMB) { $usedMB } else { 0 }
        $pct  = if ($null -ne $usedMB) { [math]::Round(($used / $FREE_DB_MB) * 100, 1) } else { $null }
        $st   = if ($null -eq $usedMB) { 'n/a (paused?)' }
                elseif ($used -ge $FREE_DB_MB)        { 'OVER LIMIT' }
                elseif ($used -ge $FREE_DB_MB * $LOW_PCT) { 'LOW' }
                else                                  { 'OK' }

        $results += [pscustomobject]@{
            Account    = $email
            Project    = $p.name
            Ref        = $p.ref
            Org        = $orgName
            Status     = $st
            Project_State = $p.status
            Disk_MB    = $used
            Disk_GB    = $diskGB
            Api_Reqs   = if ($null -ne $apiReqs) { $apiReqs } else { 0 }
            Quota_MB   = $FREE_DB_MB
            Pct        = if ($null -ne $pct) { $pct } else { 0 }
        }
    }
}

if ($results.Count -eq 0) {
    Write-Host 'No Supabase projects found.'
    exit 0
}

$sorted = $results | Sort-Object Disk_MB -Descending

if ($Json) {
    $sorted | ConvertTo-Json -Depth 4
    exit 0
}

# Console table
$sorted | Select-Object Account, Project, Project_State, Disk_MB, Disk_GB, Api_Reqs, Pct, Status |
    Format-Table -AutoSize

Write-Host ''
Write-Host "Quota: Supabase Free plan = $FREE_DB_MB MB database per project (per-project, monthly)."
Write-Host 'Usage source: GET /v1/projects/{ref}/config/disk/util (fs_used_bytes = dashboard Database size, byte-identical).'
Write-Host 'Paused projects return 500 on disk/util -> Status n/a. Storage (1 GB) and egress (5 GB) have no public per-project endpoint on the Management API.'
$totalMB = [math]::Round(($sorted | Measure-Object Disk_MB -Sum).Sum, 1)
Write-Host "Total across $($sorted.Count) projects: $totalMB MB disk used."

# Markdown table
Write-Host ''
Write-Host '### Markdown Table'
Write-Host '| Account | Project | Ref | Org | State | Disk MB | Disk GB | API reqs | % of 500MB | Status |'
Write-Host '|---------|---------|-----|-----|-------|--------:|--------:|---------:|-----------:|--------|'
foreach ($r in $sorted) {
    Write-Host "| $($r.Account) | $($r.Project) | $($r.Ref) | $($r.Org) | $($r.Project_State) | $($r.Disk_MB) | $($r.Disk_GB) | $($r.Api_Reqs) | $($r.Pct) | $($r.Status) |"
}