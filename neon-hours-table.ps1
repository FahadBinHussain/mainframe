# Neon compute hours remaining per org (Free plan: 100 CU-hours/project/month, resets monthly).
# Queries the Neon REST API directly (no neonctl dependency; neonctl is broken on Windows under pnpm).
# Source of quota: https://neon.com/docs/introduction/plans  (Free: 100 CU-hours/project/month, resets each billing period)
#
# ⚠️ Metering reality (verified 2026-08-01):
#   - project-detail `compute_time_seconds` is LIFETIME-CUMULATIVE (never resets), NOT current-period.
#     Treating it as period usage made stale usage look real after a quota reset — the bug that fired
#     a bogus "93 CU-h used" warning on 2026-08-01 while Neon UI showed ~0 used this period.
#   - The only period-bounded Free-plan endpoint is `/organizations/{org_id}/consumption`,
#     returning `periods[*].compute_time` (period-cumulative CU-sec). It is org-aggregated —
#     no per-project breakdown on Free. v2 consumption_history/projects is Launch+ only (403 on Free).
#   - empirically (2026-08-11): most mainframe neon accounts have exactly 1 project in 1 org,
#     so org-level == project-level for them. exception: one account has 3 projects in 1 org
#     (that org row combines their usage); some newer accounts have 1 org with 0 projects yet.
#   - design decision: report per-org. ProjectId is set to the org id so a dedup key stays
#     usable (one warning per org per period). Project names are comma-joined for visibility.
#   - no local state file needed — period value is read directly from the API every run and matches
#     what Neon Console shows on the org dashboard.

param(
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
$accountRoot = Join-Path $env:APPDATA 'mainframe\accounts\neon'
$apiBase = 'https://console.neon.tech/api/v2'

# Free plan: 100 CU-hours/project/month. 100 CU-h = 360,000 CU-sec.
$FREE_CU_HOURS = 100
$FREE_CU_SEC   = $FREE_CU_HOURS * 3600

if (-not (Test-Path $accountRoot)) {
    Write-Host 'No neon accounts found.'
    exit 0
}

$accounts = Get-ChildItem $accountRoot -Directory |
    Where-Object { $_.Name -match '^[^\s@]+@[^\s@]+\.[^\s@]+$' } |
    Select-Object -ExpandProperty Name

$results = @()
foreach ($email in $accounts) {
    $apiKeyPath = Join-Path $accountRoot "$email\api-key.txt"
    if (-not (Test-Path $apiKeyPath)) { continue }
    $apiKey = (Get-Content $apiKeyPath -Raw).Trim()
    if ([string]::IsNullOrWhiteSpace($apiKey)) { continue }

    $headers = @{ 'Authorization' = "Bearer $apiKey"; 'Accept' = 'application/json' }

    # List orgs for this account. (/api/v2/orgs returns 404 — use /users/me/organizations)
    try {
        $orgsResp = Invoke-RestMethod -Uri "$apiBase/users/me/organizations" -Headers $headers
    } catch {
        $results += [pscustomobject]@{
            Account=$email; Project='-'; ProjectId='-'; OrgId='-'; Plan='-'
            CU_Hours_Used=0; CU_Hours_Left=0; Pct=0
            Projects_Count=0; Quota_Reset='-'; Status="API ERR: $($_.Exception.Message)"
        }
        continue
    }
    if (-not $orgsResp.organizations -or $orgsResp.organizations.Count -eq 0) {
        $results += [pscustomobject]@{
            Account=$email; Project='(no org)'; ProjectId='-'; OrgId='-'; Plan='-'
            CU_Hours_Used=0; CU_Hours_Left=$FREE_CU_HOURS; Pct=0
            Projects_Count=0; Quota_Reset='-'; Status='NO ORG'
        }
        continue
    }

    foreach ($org in $orgsResp.organizations) {
        # List projects under the org (needed for project names + storage info).
        $projects = @()
        try {
            $r = Invoke-RestMethod -Uri "$apiBase/projects?org_id=$($org.id)&limit=100" -Headers $headers
            $projects = @($r.projects)
        } catch {
            $results += [pscustomobject]@{
                Account=$email; Project='(proj err)'; ProjectId=$org.id; OrgId=$org.id; Plan=$org.plan
                CU_Hours_Used=0; CU_Hours_Left=$FREE_CU_HOURS; Pct=0
                Projects_Count=0; Quota_Reset='-'; Status="proj ERR: $($_.Exception.Message)"
            }
            continue
        }

        if ($projects.Count -eq 0) {
            $results += [pscustomobject]@{
                Account=$email; Project='(no projects)'; ProjectId=$org.id; OrgId=$org.id; Plan=$org.plan
                CU_Hours_Used=0; CU_Hours_Left=$FREE_CU_HOURS; Pct=0
                Projects_Count=0; Quota_Reset='-'; Status='NO PROJECTS'
            }
            continue
        }

        # Period-bounded org consumption — the authoritative current-period compute_time.
        # Source: GET /organizations/{org_id}/consumption. Returns periods[] sorted oldest->newest;
        # take the latest one (current period).
        $period = $null
        $consumptionErr = $null
        try {
            $c = Invoke-RestMethod -Uri "$apiBase/organizations/$($org.id)/consumption" -Headers $headers
            if ($c.periods -and $c.periods.Count -gt 0) { $period = $c.periods[$c.periods.Count - 1] }
        } catch {
            $consumptionErr = $_.Exception.Message
        }

        # Peak storage across projects (peak_data_storage is bytes-current-period from consumption endpoint;
        # fall back to summing per-project synthetic_storage_size if absent).
        $peakDataStorageBytes = if ($period -and $period.peak_data_storage) { [double]$period.peak_data_storage } else { 0 }
        if ($peakDataStorageBytes -eq 0 -and $projects.Count -gt 0) {
            foreach ($p in $projects) {
                try {
                    $d = (Invoke-RestMethod -Uri "$apiBase/projects/$($p.id)" -Headers $headers).project
                    if ($d.synthetic_storage_size) { $peakDataStorageBytes += [double]$d.synthetic_storage_size }
                } catch { }
            }
        }

        # Compute period usage in CU-seconds.
        $ctSec = if ($period -and $period.compute_time) { [double]$period.compute_time } else { 0 }
        $atSec = if ($period -and $period.active_time)  { [double]$period.active_time  } else { 0 }
        $quotaReset  = if ($period -and $period.period_end)  { $period.period_end  } else { '-' }
        $quotaStart  = if ($period -and $period.period_start) { $period.period_start } else { '-' }
        $projectNames = ($projects | ForEach-Object { $_.name }) -join ','
        $projectId    = $org.id   # dedup key uses ProjectId — set to org id so one warning per org/period
        $plan         = if ($period -and $period.plan_details -and $period.plan_details.name) {
                            "$($period.plan_details.name) v$($period.plan_details.version.major).$($period.plan_details.version.minor)"
                        } else { $org.plan }

        $cuUsed    = [math]::Round($ctSec / 3600, 2)
        $cuLeft    = [math]::Round((($FREE_CU_SEC - $ctSec) / 3600), 2)
        $pct       = [math]::Round(($ctSec / $FREE_CU_SEC) * 100, 1)
        $activeH   = [math]::Round($atSec / 3600, 1)
        $storageMB = [math]::Round($peakDataStorageBytes / 1MB, 1)
        $st        = if     ($ctSec -ge $FREE_CU_SEC)        { 'OVER LIMIT' }
                    elseif ($ctSec -ge $FREE_CU_SEC * 0.85)   { 'LOW' }
                    else                                     { 'OK' }
        if ($consumptionErr) { $st = "CONSUMPTION ERR: $consumptionErr" }

        # Free-plan quota is per-project-per-month, so an org with N projects actually has N×100 CU-h.
        # Surface both: per-quota (one project's bucket) and a combined view across the org's projects.
        $results += [pscustomobject]@{
            Account         = $email
            Project         = $projectNames
            ProjectId       = $projectId
            OrgId           = $org.id
            Plan            = $plan
            CU_Hours_Used   = $cuUsed
            CU_Hours_Left   = $cuLeft
            Pct             = $pct
            Active_Hours    = $activeH
            Storage_MB      = $storageMB
            Projects_Count   = $projects.Count
            Quota_Reset     = $quotaReset
            Period_Start    = $quotaStart
            Status          = $st
        }
    }
}

if ($results.Count -eq 0) {
    Write-Host 'No Neon projects found.'
    exit 0
}

$sorted = $results | Sort-Object CU_Hours_Used -Descending

if ($Json) {
    $sorted | ConvertTo-Json -Depth 4
    exit 0
}

# Console table
$sorted | Select-Object Account, Project, Projects_Count, CU_Hours_Used, CU_Hours_Left, Pct, Active_Hours, Storage_MB, Status |
    Format-Table -AutoSize

Write-Host ''
Write-Host 'Quota: Free plan = 100 CU-hours per project per month (per-project-per-period, resets monthly).'
Write-Host 'Usage source: GET /organizations/{org_id}/consumption (period-bounded compute_time; matches Neon UI). Orgs with N projects have N x 100 CU-h combined.'
Write-Host "Total across $($sorted.Count) orgs: $([math]::Round(($sorted | Measure-Object CU_Hours_Used -Sum).Sum,2)) CU-h used, $((100 * ($sorted | Measure-Object Projects_Count -Sum).Sum)) CU-h combined allowance."

# Markdown table
Write-Host ''
Write-Host '### Markdown Table'
Write-Host '| Account | Project(s) | Project_count | Org ID | Plan | CU-h used | CU-h left | % | Active h | Storage MB | Period start | Quota reset | Status |'
Write-Host '|---------|-----------|--------------:|---------|------|----------:|----------:|--:|---------:|-----------:|--------------|-------------|-------|'
foreach ($r in $sorted) {
    Write-Host "| $($r.Account) | $($r.Project) | $($r.Projects_Count) | $($r.OrgId) | $($r.Plan) | $($r.CU_Hours_Used) | $($r.CU_Hours_Left) | $($r.Pct) | $($r.Active_Hours) | $($r.Storage_MB) | $($r.Period_Start) | $($r.Quota_Reset) | $($r.Status) |"
}
