# Vercel usage overview per account (REST API, no vercel CLI dependency)
#
# important: Vercel's `/v1/usage` REST endpoint requires Pro or Enterprise plan.
# Hobby accounts cannot read numeric usage (CPU-h, GB, invocation count) via the API.
# This script pulls what IS available on Hobby + Pro and reports it per account + per project:
#   - account / team plan and billing status (active, blocked)
#   - softBlock flag (set by Vercel when a Hobby account exceeds monthly usage allowance)
#   - per-project: readyState (READY / BLOCKED / ERROR / etc.), last prod deployment, runtime,
#     Functions created (lambdaRuntimeStats), custom domains, Git repo
#   - totals: projects, deployments in last 30d, BLOCKED count
#
# Hobby plan free-tier monthly allowances (per https://vercel.com/docs/limits, "Usage summary"):
#   Active CPU             4 CPU-hours      (= 14,400 CPU-sec)
#   Provisioned Memory     360 GB-hours     (= 1,296,000 GB-sec)
#   Function Invocations  1,000,000
#   Fast Data Transfer     100 GB           (egress)
#   Fast Origin Transfer    10 GB
#   Cron jobs              100 / project (two free per project: https://vercel.com/docs/cron-jobs/usage-and-pricing)
#   Projects               200
#   Deployments / day      100
#   Deployments / hour     100
#   Concurrent builds      1
#   Build minutes / dep    45
#   Static file uploads    100 MB
#   Runtime function dur   60s max (10s default)
#   Edge Config reads      free
#   Web Analytics events   community limits
#   Image Optimization     community limits
# Pro plan: pay-as-you-go (no included numeric allowance past the included credit + first-N items per resource).
#
# Caveats:
#   - For Hobby accounts Vercel does NOT expose actual numeric usage via REST. Only `softBlock`
#     (boolean on user) and per-project `readyState == "BLOCKED"` indicate a limit was hit.
#     To see concrete GB-hours / invocation counts on Hobby, open the Vercel dashboard Usage tab
#     or run `vercel usage --format json` from the Vercel CLI on a machine where the CLI works.
#   - On Pro/Enterprise, `/v1/usage?from=...&to=...` returns full per-service numbers (not used here
#     because all known accounts are Hobby). To enable: pass --include-usage or set the env var
#     VERCEL_USAGE_INCLUDE_PRO=1 and ensure the token has the right scope.

$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'vault-secret.psm1') -Force

$accountRoot = Join-Path $env:APPDATA 'mainframe\accounts\vercel'
$apiBase = 'https://api.vercel.com'

if (-not (Test-Path $accountRoot)) {
    Write-Host 'No vercel accounts found.'
    exit 0
}

# email-shaped dirs only (matches vercel-account.ps1 Get-VercelProfileDirectories);
# tokens are vault-native, so a profile without a vault entry is simply skipped.
$accounts = Get-ChildItem $accountRoot -Directory |
    Where-Object { $_.Name -match '^[^\s@]+@[^\s@]+\.[^\s@]+$' -and $_.Name -notmatch '\.(deleted|wrong|logged-out|backup)-' } |
    Select-Object -ExpandProperty Name

# Time window for "recent deployments" count (last 30 days, unix ms)
$sinceMs = [int64]([datetimeoffset]::Now.AddDays(-30).ToUnixTimeMilliseconds())

$accountRows = @()
$projectRows = @()
$blockedRows = @()

foreach ($email in $accounts) {
    # vault-native token read (no token.txt in profile dirs since 2026-08-22)
    $token = Read-VaultSecret -Email $email -NamePattern 'vercel.com*' -ValueRegex 'vcp_[A-Za-z0-9]+'
    if ([string]::IsNullOrWhiteSpace($token)) { continue }
    $headers = @{ 'Authorization' = "Bearer $token" }

    # /v2/user -> plan, softBlock
    $userPlan = '-'
    $userStatus = '-'
    $softBlock = '-'
    try {
        $u = (Invoke-RestMethod -Uri "$apiBase/v2/user" -Headers $headers).user
        $userPlan = if ($u.billing.plan) { $u.billing.plan } else { '-' }
        $userStatus = if ($u.billing.status) { $u.billing.status } else { '-' }
        $softBlock = if ($null -ne $u.softBlock) { "$($u.softBlock)" } else { 'false' }
    } catch {
        $accountRows += [pscustomobject]@{
            Account=$email; Team='-'; TeamId='-'; Plan='-'; Status='USER ERR'; Projects=0; Prod_DEPLOY_30d=0; Blocked_Projects=0; SoftBlock='-'; Teams=0
        }
        continue
    }

    # /v2/teams -> each team plan
    try {
        $teams = (Invoke-RestMethod -Uri "$apiBase/v2/teams" -Headers $headers).teams
    } catch {
        $accountRows += [pscustomobject]@{
            Account=$email; Team='-'; TeamId='-'; Plan=$userPlan; Status='TEAMS ERR'; Projects=0; Prod_DEPLOY_30d=0; Blocked_Projects=0; SoftBlock=$softBlock; Teams=0
        }
        continue
    }

    if (-not $teams -or $teams.Count -eq 0) {
        $accountRows += [pscustomobject]@{
            Account=$email; Team='(none)'; TeamId='-'; Plan=$userPlan; Status=$userStatus; Projects=0; Prod_DEPLOY_30d=0; Blocked_Projects=0; SoftBlock=$softBlock; Teams=0
        }
        continue
    }

    foreach ($team in $teams) {
        $teamId   = $team.id
        $teamName = $team.name
        $teamPlan = if ($team.billing.plan) { $team.billing.plan } else { $userPlan }
        $teamStatus = if ($team.billing.status) { $team.billing.status } else { $userStatus }
        $teamBlocked = if ($team.blocked) { 'blocked' } else { 'ok' }

        # List projects for this team
        try {
            $projsResp = Invoke-RestMethod -Uri "$apiBase/v9/projects?limit=100&teamId=$teamId" -Headers $headers
            $projects = $projsResp.projects
        } catch {
            $accountRows += [pscustomobject]@{
                Account=$email; Team=$teamName; TeamId=$teamId; Plan=$teamPlan; Status='PROJ ERR'; Projects=0; Prod_DEPLOY_30d=0; Blocked_Projects=0; SoftBlock=$softBlock; Teams=$teams.Count
            }
            continue
        }

        $blockedCount = 0
        $prodDeploy30d = 0

        foreach ($p in $projects) {
            $prod = $p.targets.production
            $readyState = if ($prod.readyState) { $prod.readyState } else { '-' }
            $lastDeploy = if ($prod.createdAt) {
                $dt = [datetimeoffset]::FromUnixTimeMilliseconds([int64]$prod.createdAt).UtcDateTime
                if ([int64]$prod.createdAt -ge $sinceMs) { $prodDeploy30d++ }
                $dt.ToString('yyyy-MM-dd')
            } else { '-' }
            $repo = if ($p.link -and $p.link.repo) { $p.link.repo } else { '-' }
            $repoOrg = if ($p.link -and $p.link.org) { $p.link.org } else { '-' }
            $runtime = if ($prod.meta.lambdaRuntimeStats) { $prod.meta.lambdaRuntimeStats } else { '-' }
            $type = if ($prod.type) { $prod.type } else { '-' }
            $domains = if ($p.targets.production.alias) { ($p.targets.production.alias | Where-Object { $_ -notlike '*-almas*' -and $_ -notlike '*-alchohol*' -and $_ -notlike '*-git-*' -and -not ($_.EndsWith('.vercel.app') -and $_ -notmatch '^[a-z0-9-]+\.vercel\.app$') } | Select-Object -First 3) -join ';' } else { '-' }
            if (-not $domains -or $domains -eq '') { $domains = '-' }
            if ($readyState -eq 'BLOCKED') { $blockedCount++ }

            $projectRows += [pscustomobject]@{
                Account=$email; Team=$teamName; Project=$p.name; ProjectId=$p.id
                Plan=$teamPlan; ReadyState=$readyState; Type=$type
                LastProdDeploy=$lastDeploy; Runtime=$runtime
                Repo= if ($repo -ne '-') { "$repoOrg/$repo" } else { '-' }
                Domains=$domains
            }

            # If BLOCKED, fetch the most recent BLOCKED deployment to get the actual cause.
            # Sources: /v6/deployments?projectId=...&meta=1  returns errorMessage + seatBlock.blockCode inline.
            # This is the ONLY reliable place to find the human-readable block reason.
            if ($readyState -eq 'BLOCKED') {
                $blockReason = '-'
                $blockCode   = '-'
                $blockCommitAuthor = '-'
                $blockCommitMsg     = '-'
                $blockCreatedAt     = '-'
                $blockDeployUid     = '-'
                try {
                    $depsResp = Invoke-RestMethod -Uri "$apiBase/v6/deployments?projectId=$($p.id)&limit=20&teamId=$teamId&meta=1" -Headers $headers
                    $bDep = $depsResp.deployments | Where-Object { $_.readyState -eq 'BLOCKED' } | Select-Object -First 1
                    if ($bDep) {
                        $blockReason        = if ($bDep.errorMessage) { $bDep.errorMessage } else { '-' }
                        $blockCode          = if ($bDep.seatBlock -and $bDep.seatBlock.blockCode) { $bDep.seatBlock.blockCode } else { '-' }
                        $blockCommitAuthor  = if ($bDep.meta -and $bDep.meta.githubCommitAuthorEmail) { $bDep.meta.githubCommitAuthorEmail } else { '-' }
                        $blockCommitMsg     = if ($bDep.meta -and $bDep.meta.githubCommitMessage) { ($bDep.meta.githubCommitMessage -replace "`r?`n",' ') } else { '-' }
                        $blockCreatedAt     = if ($bDep.createdAt) { [datetimeoffset]::FromUnixTimeMilliseconds([int64]$bDep.createdAt).UtcDateTime.ToString('yyyy-MM-dd HH:mm') } else { '-' }
                        $blockDeployUid     = $bDep.uid
                    }
                } catch {}

                $blockedRows += [pscustomobject]@{
                    Account=$email; Team=$teamName; Project=$p.name
                    BlockCode=$blockCode; Reason=$blockReason
                    CommitAuthor=$blockCommitAuthor; CommitMsg=$blockCommitMsg
                    BlockedAt=$blockCreatedAt; DeployUid=$blockDeployUid
                }
            }
        }

        $accountRows += [pscustomobject]@{
            Account=$email; Team=$teamName; TeamId=$teamId; Plan=$teamPlan; Status="$teamStatus/$teamBlocked"
            Projects=$projects.Count; Prod_DEPLOY_30d=$prodDeploy30d; Blocked_Projects=$blockedCount; SoftBlock=$softBlock; Teams=$teams.Count
        }
    }
}

if ($accountRows.Count -eq 0) {
    Write-Host 'No Vercel accounts with tokens found.'
    exit 0
}

# --- Account summary table ---
Write-Host '### Account / team summary'
Write-Host 'Hobby plan free allowance: 100 GB Fast Data Transfer, 1M Function Invocations, 4 Active CPU-h, 360 Provisioned Memory GB-h, 100 deploys/day.'
Write-Host 'Vercel DOES NOT expose actual numeric usage via REST on Hobby. Use readyState=BLOCKED / softBlock to detect exceeded limits.'
$accountRows | Format-Table -AutoSize

Write-Host ''
Write-Host '### Per-project'
$projectRows | Sort-Object Account, ReadyState, LastProdDeploy -Descending |
    Format-Table -AutoSize

if ($blockedRows.Count -gt 0) {
    Write-Host ''
    Write-Host '### BLOCKED projects — actual reason (fetched from /v6/deployments?meta=1)'
    Write-Host 'Vercel blocks deployments with seatBlock.blockCode + errorMessage.'
    Write-Host 'Most common cause: TEAM_ACCESS_REQUIRED = Git commit author is not a member of the Vercel team that owns the project (security feature: "Authenticate Commit Authors").'
    Write-Host 'Other codes: FRAUDULENT_DEPLOYMENT, BILLING_ISSUE, SPAM_DETECTED, RATE_LIMITED, etc.'
    $blockedRows | Select-Object Account, Project, BlockCode, Reason, CommitAuthor, BlockedAt | Format-Table -AutoSize -Wrap
}

# Markdown
Write-Host ''
Write-Host '### Markdown — account summary'
Write-Host '| Account | Team | Plan | Status | Projects | Prod deploys (30d) | Blocked projects | SoftBlock | Teams |'
Write-Host '|---------|------|------|--------|---------:|--------------------:|------------------:|-----------|------:|'
foreach ($r in $accountRows) {
    Write-Host "| $($r.Account) | $($r.Team) | $($r.Plan) | $($r.Status) | $($r.Projects) | $($r.Prod_DEPLOY_30d) | $($r.Blocked_Projects) | $($r.SoftBlock) | $($r.Teams) |"
}

Write-Host ''
Write-Host '### Markdown — per-project'
Write-Host '| Account | Team | Project | Plan | ReadyState | Type | Last prod deploy | Runtime | Repo | Domains |'
Write-Host '|---------|------|---------|------|------------|------|------------------|---------|------|---------|'
foreach ($r in ($projectRows | Sort-Object Account, ReadyState, LastProdDeploy -Descending)) {
    Write-Host "| $($r.Account) | $($r.Team) | $($r.Project) | $($r.Plan) | $($r.ReadyState) | $($r.Type) | $($r.LastProdDeploy) | $($r.Runtime) | $($r.Repo) | $($r.Domains) |"
}

if ($blockedRows.Count -gt 0) {
    Write-Host ''
    Write-Host '### Markdown — BLOCKED reason'
    Write-Host '| Account | Team | Project | BlockCode | Reason | Commit author | Commit msg | Blocked at | Deploy uid |'
    Write-Host '|---------|------|---------|-----------|--------|---------------|------------|------------|-----------|'
    foreach ($r in $blockedRows) {
        $reason = ($r.Reason -replace '`r?`n',' ' -replace '\|','\\|')
        $msg    = ($r.CommitMsg -replace '`r?`n',' ' -replace '\|','\\|')
        Write-Host "| $($r.Account) | $($r.Team) | $($r.Project) | $($r.BlockCode) | $reason | $($r.CommitAuthor) | $msg | $($r.BlockedAt) | $($r.DeployUid) |"
    }
}
