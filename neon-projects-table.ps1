# List all Neon projects across all mainframe accounts (REST API, no neonctl dependency)
# On v2, all projects live under an org — there is no "personal project" concept anymore.
# This script lists every project for every account, with org name/id, region, branch, endpoint host,
# pg version, autoscaling CU, suspend timeout, storage size, and the project's current compute usage
# (compute_time_seconds = billable CU-sec; see neon-hours-table.ps1 for quota math).

$ErrorActionPreference = 'Stop'
$accountRoot = Join-Path $env:APPDATA 'mainframe\accounts\neon'
$apiBase = 'https://console.neon.tech/api/v2'

if (-not (Test-Path $accountRoot)) {
    Write-Host 'No neon accounts found.'
    exit 0
}

$accounts = Get-ChildItem $accountRoot -Directory |
    Where-Object { $_.Name -match '^[^\s@]+@[^\s@]+\.[^\s@]+$' } |
    Select-Object -ExpandProperty Name

$rows = @()
foreach ($email in $accounts) {
    $apiKeyPath = Join-Path $accountRoot "$email\api-key.txt"
    if (-not (Test-Path $apiKeyPath)) { continue }
    $apiKey = (Get-Content $apiKeyPath -Raw).Trim()
    if ([string]::IsNullOrWhiteSpace($apiKey)) { continue }

    $headers = @{ 'Authorization' = "Bearer $apiKey"; 'Accept' = 'application/json' }

    try {
        $orgsResp = Invoke-RestMethod -Uri "$apiBase/users/me/organizations" -Headers $headers
    } catch {
        $rows += [pscustomobject]@{
            Account=$email; Org='-'; OrgId='-'; Project='-'; ProjectId='-'
            Region='-'; PgVersion='-'; CU_min=0; CU_max=0; Suspend_s=0
            Storage_MB=0; Branch='-'; EndpointHost='-'; Plan='-'; Status="API ERR: $($_.Exception.Message)"
        }
        continue
    }
    if (-not $orgsResp.organizations -or $orgsResp.organizations.Count -eq 0) {
        $rows += [pscustomobject]@{
            Account=$email; Org='(none)'; OrgId='-'; Project='-'; ProjectId='-'
            Region='-'; PgVersion='-'; CU_min=0; CU_max=0; Suspend_s=0
            Storage_MB=0; Branch='-'; EndpointHost='-'; Plan='-'; Status='NO ORG'
        }
        continue
    }

    foreach ($org in $orgsResp.organizations) {
        try {
            $r = Invoke-RestMethod -Uri "$apiBase/projects?org_id=$($org.id)&limit=100" -Headers $headers
        } catch {
            $rows += [pscustomobject]@{
                Account=$email; Org=$org.name; OrgId=$org.id; Project='(proj err)'; ProjectId='-'
                Region='-'; PgVersion='-'; CU_min=0; CU_max=0; Suspend_s=0
                Storage_MB=0; Branch='-'; EndpointHost='-'; Plan=$org.plan; Status="proj ERR: $($_.Exception.Message)"
            }
            continue
        }

        foreach ($p in $r.projects) {
            # Detail is optional here (it adds region/branch/endpoint info that the list endpoint omits on v2).
            $detail = $null
            try {
                $detail = (Invoke-RestMethod -Uri "$apiBase/projects/$($p.id)" -Headers $headers).project
            } catch { $detail = $p }

            # Branches + endpoints for richer info
            $branchName = '-'
            $endpointHost = '-'
            try {
                $br = Invoke-RestMethod -Uri "$apiBase/projects/$($p.id)/branches?limit=100" -Headers $headers
                if ($br.branchs) {
                    $primary = $br.branchs | Where-Object { $_.primary } | Select-Object -First 1
                    if (-not $primary) { $primary = $br.branchs[0] }
                    if ($primary) { $branchName = $primary.name }
                } elseif ($br.branches) {
                    $primary = $br.branches | Where-Object { $_.primary } | Select-Object -First 1
                    if (-not $primary) { $primary = $br.branches[0] }
                    if ($primary) { $branchName = $primary.name }
                }
            } catch {}
            try {
                $ep = Invoke-RestMethod -Uri "$apiBase/projects/$($p.id)/endpoints" -Headers $headers
                $rw = $ep.endpoints | Where-Object { $_.type -eq 'read_write' } | Select-Object -First 1
                if ($rw) { $endpointHost = $rw.host }
            } catch {}

            $cuMin     = if ($detail.default_endpoint_settings.autoscaling_limit_min_cu) { [double]$detail.default_endpoint_settings.autoscaling_limit_min_cu } else { 0 }
            $cuMax     = if ($detail.default_endpoint_settings.autoscaling_limit_max_cu) { [double]$detail.default_endpoint_settings.autoscaling_limit_max_cu } else { 0 }
            $suspendTo = if ($detail.default_endpoint_settings.suspend_timeout_seconds) { [int]$detail.default_endpoint_settings.suspend_timeout_seconds } else { 0 }
            $plan      = if ($detail.owner.subscription_type) { $detail.owner.subscription_type } else { $org.plan }
            $storageB  = if ($detail.synthetic_storage_size)   { [double]$detail.synthetic_storage_size }   else { 0 }
            $storageMB = [math]::Round($storageB / 1MB, 1)
            $region    = if ($detail.region_id) { $detail.region_id } else { '-' }
            $pgVer     = if ($detail.pg_version) { $detail.pg_version } else { '-' }

            $rows += [pscustomobject]@{
                Account      = $email
                Org          = $org.name
                OrgId        = $org.id
                Project      = $detail.name
                ProjectId    = $p.id
                Region       = $region
                PgVersion    = $pgVer
                CU_min       = $cuMin
                CU_max       = $cuMax
                Suspend_s    = $suspendTo
                Storage_MB   = $storageMB
                Branch       = $branchName
                EndpointHost = $endpointHost
                Plan         = $plan
                Status       = 'OK'
            }
        }
    }
}

if ($rows.Count -eq 0) {
    Write-Host 'No Neon projects found.'
    exit 0
}

# Summary by account
Write-Host '### Summary by account'
$summary = $rows | Group-Object Account | ForEach-Object {
    [pscustomobject]@{
        Account    = $_.Name
        Projects   = $_.Count
        Orgs       = ($_.Group | Select-Object -ExpandProperty Org -Unique) -join '; '
    }
}
$summary | Format-Table -AutoSize -Wrap

# Per-project table (skip the long Region column in the console to avoid wrap noise; it's in markdown)
Write-Host ''
Write-Host '### Per-project'
$rows | Select-Object Account, Project, ProjectId, Org, PgVersion, CU_min, CU_max, Suspend_s, Storage_MB, Branch, EndpointHost, Plan |
    Format-Table -AutoSize -Wrap

# Markdown
Write-Host ''
Write-Host '### Markdown Table'
Write-Host '| Account | Project | Project ID | Org | Region | Pg | CU min | CU max | Suspend s | Storage MB | Branch | Endpoint host | Plan |'
Write-Host '|---------|---------|------------|-----|--------|----|--------|--------|-----------|-----------:|--------|---------------|------|'
foreach ($r in $rows) {
    Write-Host "| $($r.Account) | $($r.Project) | $($r.ProjectId) | $($r.Org) | $($r.Region) | $($r.PgVersion) | $($r.CU_min) | $($r.CU_max) | $($r.Suspend_s) | $($r.Storage_MB) | $($r.Branch) | $($r.EndpointHost) | $($r.Plan) |"
}
