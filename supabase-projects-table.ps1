# List all Supabase projects across all mainframe accounts (Management REST API, no CLI dependency).
# Mirrors neon-projects-table.ps1. Profiles keyed by email under
#   %APPDATA%\mainframe\accounts\supabase\<email>\token.txt  (Personal Access Token sbp_...)
# Endpoint: GET /v1/projects per token (list all projects the PAT can see), plus per-project detail.
# Status meanings: ACTIVE_HEALTHY, ACTIVE, INACTIVE (paused), COMING_UP, RESTORING, UNKNOWN.

$ErrorActionPreference = 'Stop'
$accountRoot = Join-Path $env:APPDATA 'mainframe\accounts\supabase'
$apiBase = 'https://api.supabase.com'

if (-not (Test-Path $accountRoot)) {
    Write-Host 'No supabase accounts found.'
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

    try {
        $projects = @((Invoke-RestMethod -Uri "$apiBase/v1/projects" -Headers $headers) | Where-Object { $_ })
    } catch {
        $rows += [pscustomobject]@{
            Account=$email; Project='-'; Ref='-'; Org='-'; Region='-'
            DbVersion='-'; Status="API ERR: $($_.Exception.Message)"; Created='-'
        }
        continue
    }

    if ($projects.Count -eq 0) {
        $rows += [pscustomobject]@{
            Account=$email; Project='(no projects)'; Ref='-'; Org='-'; Region='-'
            DbVersion='-'; Status='NO PROJECTS'; Created='-'
        }
        continue
    }

    foreach ($p in $projects) {
        $orgName = $p.organization_slug
        if (-not $orgName) { $orgName = $p.organization_id }
        $dbVersion = '-'
        if ($p.database -and $p.database.version) { $dbVersion = $p.database.version }

        $rows += [pscustomobject]@{
            Account   = $email
            Project   = $p.name
            Ref       = $p.ref
            Org       = $orgName
            OrgId     = $p.organization_id
            Region    = $p.region
            DbVersion = $dbVersion
            Status    = $p.status
            Created   = $p.created_at
        }
    }
}

if ($rows.Count -eq 0) {
    Write-Host 'No Supabase projects found.'
    exit 0
}

# Summary by account
Write-Host '### Summary by account'
$summary = $rows | Group-Object Account | ForEach-Object {
    [pscustomobject]@{
        Account  = $_.Name
        Projects = $_.Count
        Orgs     = ($_.Group | Select-Object -ExpandProperty Org -Unique) -join '; '
    }
}
$summary | Format-Table -AutoSize -Wrap

# Per-project table
Write-Host ''
Write-Host '### Per-project'
$rows | Select-Object Account, Project, Ref, Org, Region, DbVersion, Status, Created |
    Format-Table -AutoSize -Wrap

# Markdown
Write-Host ''
Write-Host '### Markdown Table'
Write-Host '| Account | Project | Ref | Org | Region | DB | Status | Created |'
Write-Host '|---------|---------|-----|-----|--------|----|--------|---------|'
foreach ($r in $rows) {
    Write-Host "| $($r.Account) | $($r.Project) | $($r.Ref) | $($r.Org) | $($r.Region) | $($r.DbVersion) | $($r.Status) | $($r.Created) |"
}