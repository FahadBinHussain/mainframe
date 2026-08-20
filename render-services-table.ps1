# List all Render services across all mainframe accounts (REST API, no render CLI dependency)
#
# Calls https://api.render.com/v1/services per profile API key.
# Lists: service id, name, type, status, repo, last deploy time, region,
# plan, and branch.

$ErrorActionPreference = 'Stop'
$accountRoot = Join-Path $env:APPDATA 'mainframe\accounts\render'

if (-not (Test-Path $accountRoot)) {
    Write-Host 'No Render accounts found.'
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

    # Owner info
    $ownerName = '-'
    try {
        $owners = Invoke-RestMethod -Uri 'https://api.render.com/v1/owners' -Headers $headers -TimeoutSec 30
        if ($owners -and $owners.Count -gt 0 -and $owners[0].owner -and $owners[0].owner.name) {
            $ownerName = $owners[0].owner.name
        }
    } catch { }

    try {
        $servicesRaw = Invoke-RestMethod -Uri 'https://api.render.com/v1/services?limit=100' -Headers $headers -TimeoutSec 30
    } catch {
        $rows += [pscustomobject]@{
            Account = $email; OwnerName = $ownerName; Service = '-'; ServiceId = '-'; Type = '-'
            Status = '-'; Repo = '-'; Branch = '-'; Region = '-'; Plan = '-'; LastDeploy = '-'
        }
        continue
    }

    # Render v1/services returns objects with a 'service' property wrapper
    $services = @()
    foreach ($item in $servicesRaw) {
        if ($item.service) { $services += $item.service }
        elseif ($item.id)  { $services += $item }
    }

    if ($services.Count -eq 0) {
        $rows += [pscustomobject]@{
            Account = $email; OwnerName = $ownerName; Service = '(none)'; ServiceId = '-'; Type = '-'
            Status = '-'; Repo = '-'; Branch = '-'; Region = '-'; Plan = '-'; LastDeploy = '-'
        }
        continue
    }

    foreach ($s in $services) {
        $serviceId = if ($s.id) { $s.id } else { '-' }
        $serviceName = if ($s.name) { $s.name } else { '-' }
        $svcType = if ($s.type) { $s.type } else { '-' }

        $isSuspended = ($s.suspended -eq 'suspended')
        $hasUrl = $s.serviceDetails -and $s.serviceDetails.url
        if ($isSuspended) { $status = 'suspended' }
        elseif ($hasUrl)  { $status = 'live' }
        else              { $status = 'not_live' }

        $repo = '-'
        if ($s.repo) {
            $repo = if ($s.repo -match 'github\.com/') { ($s.repo -split 'github\.com/')[1] } else { $s.repo }
        }

        $branch = if ($s.branch) { $s.branch } else { '-' }
        $region = if ($s.region) { $s.region } elseif ($s.serviceDetails -and $s.serviceDetails.region) { $s.serviceDetails.region } else { '-' }
        $plan = if ($s.serviceDetails -and $s.serviceDetails.plan) { $s.serviceDetails.plan } else { '-' }

        $lastDeploy = '-'
        try {
            $deploys = Invoke-RestMethod -Uri "https://api.render.com/v1/services/$serviceId/deploys?limit=1" -Headers $headers -TimeoutSec 30 -ErrorAction SilentlyContinue
            if ($deploys -and $deploys.Count -gt 0) {
                $d = $deploys[0]
                $ts = if ($d.deploy -and $d.deploy.createdAt) { $d.deploy.createdAt } elseif ($d.createdAt) { $d.createdAt } else { $null }
                if ($ts) {
                    try { $lastDeploy = ([datetime]$ts).ToString('yyyy-MM-dd') } catch { $lastDeploy = $ts }
                }
            }
        } catch { }

        $rows += [pscustomobject]@{
            Account    = $email
            OwnerName  = $ownerName
            Service    = $serviceName
            ServiceId  = $serviceId
            Type       = $svcType
            Status     = $status
            Repo       = $repo
            Branch     = $branch
            Region     = $region
            Plan       = $plan
            LastDeploy = $lastDeploy
        }
    }
}

if ($rows.Count -eq 0) {
    Write-Host 'No Render services found.'
    exit 0
}

# Summary by account
Write-Host '### Summary by account'
$summary = $rows | Where-Object { $_.Service -ne '(none)' } | Group-Object Account | ForEach-Object {
    [pscustomobject]@{
        Account  = $_.Name
        Services = $_.Count
    }
}
if ($summary.Count -eq 0) {
    foreach ($email in $accounts) {
        [pscustomobject]@{ Account = $email; Services = 0 } | Format-Table -AutoSize
    }
} else {
    $summary | Format-Table -AutoSize
}

Write-Host ''
Write-Host '### Per-service'
$rows | Select-Object Account, OwnerName, Service, Type, Status, Repo, Branch, Region, Plan, LastDeploy |
    Format-Table -AutoSize -Wrap

# Markdown
Write-Host ''
Write-Host '### Markdown Table'
Write-Host '| Account | Owner | Service | Type | Status | Repo | Branch | Region | Plan | Last Deploy |'
Write-Host '|---------|-------|---------|------|--------|------|--------|--------|------|-------------|'
foreach ($r in $rows) {
    Write-Host "| $($r.Account) | $($r.OwnerName) | $($r.Service) | $($r.Type) | $($r.Status) | $($r.Repo) | $($r.Branch) | $($r.Region) | $($r.Plan) | $($r.LastDeploy) |"
}
