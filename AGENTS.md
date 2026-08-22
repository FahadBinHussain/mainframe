# mainframe workflows

durable workflows for agents using the mainframe account helpers.

this file documents reusable knowledge for operating the `*-account.ps1` helpers and their bulk-table scripts. anything machine- or account-specific (real emails, org/project ids, service ids, urls, hostnames, credentials) intentionally lives OUTSIDE this repo in the local `%APPDATA%\mainframe\accounts\<tool>\<email>\` profile dirs — never commit it.

conventions used below:
- `<email>` — a real account email, resolved per the tool account workflow (check `current`/`status-all` first, switch with `use`)
- `<repo>` — the path to this repo clone (default `%USERPROFILE%\Downloads\mainframe`)
- profile dirs: `%APPDATA%\mainframe\accounts\<tool>\<email>\`

## account helper contract

every `*-account.ps1` helper implements the same contract (`login`, `use`, `current`, `list`, `status`, `status-all`, `path`, `env`, `run`) plus tool-specific subcommands. `account-contract.ps1` validates the contract across all helpers — run it after adding or editing a helper.

- profiles are keyed by account email only; if email cannot be detected after auth, fail or ask — never save a username/label/workspace fallback.
- **secrets are vault-native (2026-08-22)**: api keys / tokens live in the Bitwarden vault as LOGIN items named by the platform (e.g. `console.neon.tech - <user>`, `vercel.com - <user>`, `dash.cloudflare.com`, `www.notion.so`, `uptimerobot.com`, `github.com - <handle>`), with the secret value in the item's notes under a platform header (e.g. `[api keys]`, `[tokens]`, `[API Tokens]`, `User Access Tokens`, `Access Tokens`, `[token]`, `[api key]`) followed by the value. helpers read/write them via the shared module `vault-secret.psm1` (`Read-VaultSecret` / `Write-VaultSecretToExisting`). **no secrets are stored in the profile dir anymore** — `%APPDATA%\mainframe\accounts\<tool>\<email>\` holds only `profile.json`/`current.json` metadata and tool CLI config state (render cli.yaml, cloudflare account-id, notion workspace-id, wrangler oauth state). unlock the vault first (`automata\bitwarden.com\unlock.ps1` writes `%APPDATA%\mainframe\accounts\bitwarden\session.key`, or set `$env:BW_SESSION`); if locked, helpers throw a clear "unlock first" message. token format per tool (used as the vault-value regex): neon `napi_`, supabase `sbp_v0_`, vercel `vcp_`, hf `hf_`, render `rnd_`, cloudflare `cfut_`, github `ghp_`/`github_pat_`, notion `ntn_`/`secret_`, uptimerobot `u<digits>-<hex>`, cron-job.org base64. some vault items are keyed by github handle or a different email than the profile — the lookup falls back to matching the profile email line in the item notes.
- before using a service, check the active account first (`status-all`/`current`); if the task targets a specific project/repo/space, verify which account owns it and switch before proceeding.

## neon: list all projects for an account

context: neon projects can be under personal accounts or organizations. `projects list` without `--org-id` only returns personal projects. org-owned projects require `--org-id`.

### prerequisites
- mainframe neon profiles in `%APPDATA%\mainframe\accounts\neon\`
- neonctl installed: `pnpm add -g neonctl`

### steps

1. **check which account is active**
   ```
   <repo>\neon-account.ps1 current
   ```

2. **switch to the target account if needed**
   ```
   <repo>\neon-account.ps1 use <email>
   ```

3. **list organizations for the account**
   ```
   <repo>\neon-account.ps1 run <email> orgs list --output json
   ```
   or via api:
   ```
   <repo>\neon-account.ps1 api <email> GET organizations
   ```

4. **list projects — personal first**
   ```
   <repo>\neon-account.ps1 run <email> projects list --output json
   ```

5. **list projects per organization**
   for each org id from step 3:
   ```
   <repo>\neon-account.ps1 run <email> projects list --org-id <org-id> --output json
   ```

6. **shortcut: projects-json helper** (auto-detects org if only one exists)
   ```
   <repo>\neon-account.ps1 projects-json <email>
   ```
   if multiple orgs, specify `--org-id`:
   ```
   <repo>\neon-account.ps1 projects-json <email> --org-id <org-id>
   ```

7. **get connection string for a project**
   ```
   <repo>\neon-account.ps1 run <email> connection-string --project-id <project-id> --branch main --database <dbname> --role <role> --output json --no-color
   ```

### notes
- personal projects = no `--org-id` flag
- org projects = `--org-id` required
- if `projects list` returns empty, check orgs first
- the helper supports json output for programmatic parsing: add `--output json --no-color --no-analytics`
- api key auth (`--api-key`) is preferred over browser oauth for automation
- the `neon-account.ps1` helper preserves the api key per profile and injects it into `neonctl` commands

## neon: bulk scripts at mainframe root

two helper scripts live next to the account helpers and iterate every mainframe neon profile automatically (no need to pass an email):

- `<repo>\neon-hours-table.ps1` — per-project compute (CU-hours) remaining table across all accounts, against the Free plan quota (100 CU-hours/project/month). the quickest "how much neon is left" check.
- `<repo>\neon-projects-table.ps1` — prints every project across all accounts (personal + per-org), with org names.
- `neon-hours-table.ps1 -Json` returns the same sorted project records as JSON for scheduled consumers (e.g. a CU-hour warning notifier).

### run
```
<repo>\neon-hours-table.ps1
<repo>\neon-projects-table.ps1
```

### quota and metering (read this — easy to get wrong)
official source: https://neon.com/docs/introduction/plans  (Free: 100 CU-hours/project/month, 0.5 GB storage/project, 5 GB egress/month, resets each billing period).

- **quota** is per-project per-month: **100 CU-hours = 360,000 CU-seconds** per project bucket. NOT 190h, NOT 191.67h (those were old/wrong guesses). NOT per-account or per-org — each project has its own 100 CU-h bucket.
- **⚠️ `compute_time_seconds` (project-detail endpoint) is LIFETIME-CUMULATIVE, not period-bounded.** It grows monotonically across all consumption periods since project creation — it does NOT reset at `consumption_period_start`. Treating it as the current-period value is a bug: after a quota reset, the script keeps reporting accumulated lifetime usage as if it were this period's, producing false "still 93 CU-h used" warnings while Neon UI shows 0. witnessed 2026-08-01 (lifetime 335132s = 93.09 h, period 168s = 0.047 h on one project).
- **⚠️ v2 consumption_history/projects endpoint (the only per-project period-bounded one) is Launch+ only** — returns 403 on Free. cannot be used for mainframe Neon accounts (all Free).
- **the only period-bounded Free-plan endpoint is `/organizations/{org_id}/consumption`** (returns `periods[*].compute_time` for the current period). It's org-aggregated — no per-project breakdown on Free.
- **recommended layout: each Neon account hosts exactly 1 project** — keeps per-org == per-project metering exact on Free (org-aggregated consumption). create a new project only on an account with 0 projects. if an account must hold several, note that its org row combines their usage.
- **design decision in `neon-hours-table.ps1`**: report per-org using the org consumption endpoint. matches Neon UI exactly. NO local state file needed (period value is read directly from the API every run). `ProjectId` field is set to the org id so a dedup key (one warning per period) still works. `Project` field is a comma-joined list of project names for visibility. Multi-project orgs surface combined usage but the Free quota is per-project — for strict per-project accounting you'd need Launch+ (paid) — flag to user before recommending a paid plan.
- **`active_time_seconds`** (also lifetime-cumulative) is the wall-clock time the endpoint was reachable, NOT billed — informational only.
- **`cpu_used_sec`** is an alias of `compute_time_seconds`; same lifetime semantics. do not use either as a period-bounded signal on Free.
- **`synthetic_storage_size`** (bytes) on the project detail; `peak_data_storage` (bytes) on the org consumption endpoint. Both vs 0.5 GB (536,870,912 bytes) per project on Free.
- **scale-to-zero**: Free plan = always 5 min idle, cannot be disabled. BUT if `default_endpoint_settings.suspend_timeout_seconds = 0` (set via paid-plan feature or older api), the endpoint stays alive — `active_time_seconds` keeps growing while `compute_time_seconds` does not. do not use active_time as billing signal.
- **`consumption_period_start` / `consumption_period_end`** on the detail endpoint = billing window (free resets on the 1st of the month for most accounts).
- `subscription_type` from `detail.owner.subscription_type` is the real plan id (`free_v3`, etc.); the orgs-endpoint `org.plan` (`free`) is a simplified label — use `detail.owner.subscription_type` when accuracy matters. the consumption endpoint's `plan_details` object also exposes `name` + `version.major`/`version.minor` for fine-grained plan identification.

### how the script queries neon (no neonctl dependency)
`neon-hours-table.ps1` calls the rest api directly (neonctl is broken on windows under pnpm — see gotcha below). previous versions read the wrong metered field (`active_time` instead of `compute_time_seconds`) and wrong quota (`190` instead of `100 CU-h/project`).

rest api flow the script uses:
1. get the api key: `(Get-Content "$env:APPDATA\mainframe\accounts\neon\<email>\api-key.txt" -Raw).Trim()`
2. headers: `Authorization: Bearer <api-key>`, `Accept: application/json`
3. list orgs (this works with an api-key bearer token):
   ```
   GET https://console.neon.tech/api/v2/users/me/organizations
   ```
   (`/api/v2/orgs` and `/api/v2/users/me/organizations/list` do not exist — only `/users/me/organizations`. `/api/v2/users/me` returns 404 for org api keys, do not use.)
4. list projects per org (`org_id` is required on v2 — without it, neon returns `org_id is required`):

### ⚠️ TRAP: "org_id is required" does NOT mean the account is broken (read this before troubleshooting)
**If you call `GET /api/v2/projects` (without `?org_id=...`) and get a 400 with `"org_id is required"`, the account is NOT broken, the key is NOT stale, and the user does NOT need to log into the Neon web console.** this is by design on v2 — neon migrated accounts to "organizations" and the v2 `/projects` endpoint refuses to auto-infer the org from the bearer token. every neon account migrated to v2 has a working org; the key is fine; no web-console login is required to "provision" anything.

do NOT do any of these (a previous agent wasted an hour doing all of them):
1. do NOT re-issue the api key. the key is valid (`/users/me` returns 200).
2. do NOT log into the Neon web console to "trigger org provisioning". the org already exists.
3. do NOT switch accounts or report "symmetry broken / accounts orphaned". they are not.
4. do NOT call `/users/me/orgs` (404) — the correct endpoint is `/users/me/organizations` (plural, full word).
5. do NOT try to invent an `org_id` like `default` or `self` — they 404 with `not an organization member`.

**correct one-liner to discover org + projects for an account:**
```powershell
$key = (Get-Content "$env:APPDATA\mainframe\accounts\neon\<email>\api-key.txt" -Raw).Trim()
$headers = @{ 'Authorization' = "Bearer $key"; 'Accept' = 'application/json' }
$orgs = (Invoke-RestMethod -Uri 'https://console.neon.tech/api/v2/users/me/organizations' -Headers $headers).organizations
foreach ($org in $orgs) {
    $projects = (Invoke-RestMethod -Uri "https://console.neon.tech/api/v2/projects?org_id=$($org.id)&limit=100" -Headers $headers).projects
    Write-Host "org=$($org.name) id=$($org.id) plan=$($org.plan) projects=$($projects.Count)"
    foreach ($p in $projects) { Write-Host "  - $($p.name) ($($p.id))" }
}
```
**to get a project's DATABASE_URL** (common reason agents are looking at neon in the first place):
```powershell
$key = (Get-Content "$env:APPDATA\mainframe\accounts\neon\<email>\api-key.txt" -Raw).Trim()
$headers = @{ 'Authorization' = "Bearer $key"; 'Accept' = 'application/json' }
$projectId = '<project-id>'
$branchId  = (Invoke-RestMethod -Uri "https://console.neon.tech/api/v2/projects/$projectId/branches" -Headers $headers).branches[0].id
$uri = (Invoke-RestMethod -Uri "https://console.neon.tech/api/v2/projects/$projectId/connection_uri?database_name=neondb&branch_id=$branchId&role_name=neondb_owner" -Headers $headers).uri
Write-Host $uri   # postgresql://neondb_owner:npg_xxx@ep-...neon.tech/neondb?...
```
**to create a new project under the account's existing org** (also does NOT require web console login):
```powershell
$headers = @{ 'Authorization' = "Bearer $key"; 'Accept' = 'application/json' }
$orgs = (Invoke-RestMethod -Uri 'https://console.neon.tech/api/v2/users/me/organizations' -Headers $headers).organizations
$body = @{ project = @{ name = '<new-project-name>'; region_id = '<region-id>'; pg_version = 17 } } | ConvertTo-Json -Depth 3
$r = Invoke-WebRequest -Uri 'https://console.neon.tech/api/v2/projects' -Method Post -Headers $headers -Body $body -ContentType 'application/json' -UseBasicParsing -SkipHttpErrorCheck
# note: the response body contains project_id but the connection_uri field is empty — fetch it separately with the connection_uri endpoint above using the returned branch id
```
the only endpoints that exist for discovery are:
- `GET /api/v2/users/me/organizations` (✅ the only org-listing endpoint — plural, full word)
- `GET /api/v2/projects?org_id=<org_id>` (✅ requires org_id on v2)
- `GET /api/v2/projects/<project_id>` (✅ project detail)
- `GET /api/v2/projects/<project_id>/branches` (✅ list branches under a project)
- `GET /api/v2/projects/<project_id>/endpoints` (✅ list endpoints under a project)
- `GET /api/v2/projects/<project_id>/connection_uri?database_name=neondb&branch_id=<id>&role_name=neondb_owner` (✅ fetch DATABASE_URL)
endpoints that do NOT exist: `/api/v2/orgs`, `/api/v2/users/me/orgs`, `/api/v2/users/me/organizations/list`, `/api/v1/projects` (404 on v2). `/api/v2/users/me` exists but is not the discovery endpoint — use it only for plan/projects_limit introspection.

5. for each project, fetch detail (required because the list endpoint does NOT return `compute_time_seconds` in v2 — it only returns the shortened `active_time` alias):
   ```
   GET https://console.neon.tech/api/v2/projects/<project-id>
   ```
   this is the only place to get authoritative `compute_time_seconds`, `consumption_period_start/end`, `default_endpoint_settings`, and `owner.subscription_type`.
6. compute per project: `cu_h_used = compute_time_seconds / 3600`, `cu_h_left = (360000 - compute_time_seconds) / 3600`. status OVER >= 100%, LOW >= 85%, else OK.

### gotcha: neonctl is currently broken on windows under pnpm
`neon-account.ps1 run`/`projects-json` still invoke `neonctl` via `& $neon.Source ...`. if neonctl was installed through `pnpm add -g neonctl`, only a `/bin/sh` shell shim is left at `scoop\apps\pnpm\current\bin\neonctl` with no matching `neonctl.cmd`/`neonctl.ps1`, pointing at a `global/.../node_modules/neonctl/dist/cli.js` that may not exist. under pwsh on windows these shims can't run, so the scripts silently fail. sanity-check: if a script reports 0 projects for every account, the neonctl call almost certainly failed.

both `neon-hours-table.ps1` and `neon-projects-table.ps1` were migrated to the rest api (above) and no longer require neonctl. `neon-account.ps1 run`/`projects-json` still use neonctl — to migrate when needed, or fix neonctl: `pnpm add -g neonctl` plus verifying a windows-runnable `neonctl.cmd` exists.

## vercel: bulk scripts at mainframe root

- `<repo>\vercel-usage-table.ps1` — per-account + per-project usage overview across all mainframe vercel profiles. reports plan, billing status, `softBlock` flag, projects count, prod deployments in last 30d, BLOCKED projects, runtime (Functions created), last prod deploy, repo, domains. this is the "vercel what's left / who's blocked" check.
- `<repo>\vercel-projects-table.ps1` — older script, prints a simple per-account list of personal + team projects. `vercel-usage-table.ps1` supersedes this for usage/limits audits.

### run
```
<repo>\vercel-usage-table.ps1
<repo>\vercel-projects-table.ps1
```

### quota and metering (read this — easy to get wrong)
official source: https://vercel.com/docs/limits  (Hobby "Usage summary" section).

**Hobby plan free allowances (per billing period, monthly cycle scoped to the team):**
- Active CPU: **4 CPU-hours**
- Provisioned Memory: **360 GB-hours**
- Function Invocations: **1,000,000**
- Fast Data Transfer (egress): **100 GB**
- Fast Origin Transfer: **10 GB**
- Projects: 200, Deployments/day: 100, Deployments/hour: 100, Concurrent builds: 1, Build minutes/deployment: 45, Static file uploads: 100 MB
- Cron jobs: 100 per project (2 free per project on Hobby), Runtime function duration: 60s max (10s default)

**important REST API caveat:** Vercel's `/v1/usage?from=...&to=...` endpoint (which returns concrete numeric usage — CPU-h, GB-h, invocation counts, bandwidth) **requires Pro or Enterprise plan**. On Hobby it returns `{"code":"plan_upgrade_required","message":"This API endpoint is only available to Teams on the Pro or Enterprise plan."}`. So on Hobby you CANNOT read real numeric usage via REST.

**on Hobby, the only signals of limit-exceeded are:**
- `user.softBlock` (boolean) on `/v2/user` — set by Vercel when an account exceeds its Hobby monthly allowance (typically bandwidth or invocations). usually transient until the period resets.
- `team.blocked` (boolean) on `/v2/teams` — same on team scope.
- `project.targets.production.readyState == "BLOCKED"` on `/v9/projects` — **NOT always a quota hit.** Common cause is actually `TEAM_ACCESS_REQUIRED` (see below).

### BLOCKED ≠ quota limit (read this)
`readyState == "BLOCKED"` does NOT necessarily mean "Vercel blocked this project for hitting a Hobby limit". it means "Vercel refused to promote this deployment for some reason". to know the real reason, fetch the deployment record:

```
GET https://api.vercel.com/v6/deployments?projectId=<project-id>&limit=20&teamId=<team-id>&meta=1
```

this returns a `deployments[]` array with inline fields:
- `errorMessage` — human-readable reason ("The Deployment was blocked because the commit author does not have contributing access to the project on Vercel.")
- `seatBlock.blockCode` — machine code. observed codes so far:
  - `TEAM_ACCESS_REQUIRED` — most common. Git commit author identity (verified GitHub account) is NOT a member of the Vercel team that owns the project. This is Vercel's "Authenticate Commit Authors" security feature, NOT a quota issue. fix: create a local deployment-alignment commit authored with the target Vercel account email (`git -c user.email="<target-vercel-email>" -c user.name="<name>" commit --allow-empty -m "deployment alignment"`; empty commit only when there is no real scoped change), or add the GitHub identity to the team, or disable the feature on the project's Git settings.
  - others (not yet observed here): `FRAUDULENT_DEPLOYMENT`, `BILLING_ISSUE`, `SPAM_DETECTED`, `RATE_LIMITED` — these are actual abuse/quota blocks.
- `meta.githubCommitAuthorEmail`, `meta.githubCommitMessage` — context for who/what triggered the block.

**caveat**: the `/v13/deployments/{uid}` GET (single deployment) sometimes 404s on older deployments (retention purged), but the list endpoint `/v6/deployments?projectId=...&meta=1` keeps returning the BLOCKED records inline with their errorMessage. always use the list endpoint with `meta=1`, do NOT rely on the single-deployment GET.

note: `readyState == "ERROR"` (build failure) can ALSO show `errorMessage: "The Deployment was blocked because..."` when the same security feature refuses a build — observed where earlier ERROR deployments have the IDENTICAL `TEAM_ACCESS_REQUIRED` block message. so always check errorMessage content, not just the readyState label.

to get concrete numeric usage on Hobby (CPU-h, GB-h, invocations) — open the Vercel dashboard Usage tab or run `vercel usage --format json` from the Vercel CLI (which uses an internal endpoint different from `/v1/usage`).

### how the script queries vercel (no vercel CLI dependency)
`vercel-usage-table.ps1` calls the REST API directly (no vercel CLI). the vercel CLI can be broken on windows under pnpm — same shim issue as neonctl — only a stale `/bin/sh` shim remains pointing at a non-existent `vc.js`. the script does NOT depend on the CLI.

rest api flow:
1. get the token: `(Get-Content "$env:APPDATA\mainframe\accounts\vercel\<email>\token.txt" -Raw).Trim()`
2. headers: `Authorization: Bearer <token>`.
3. user info (plan, softBlock):
   ```
   GET https://api.vercel.com/v2/user
   ```
   `user.billing.plan` ∈ {hobby, pro, enterprise}, `user.billing.status` = active, `user.softBlock` = true/false.
4. teams:
   ```
   GET https://api.vercel.com/v2/teams
   ```
   `team.billing.plan`, `team.billing.status`, `team.blocked`.
5. projects per team:
   ```
   GET https://api.vercel.com/v9/projects?limit=100&teamId=<team-id>
   ```
   each project has `targets.production` with `readyState` (READY / BLOCKED / ERROR / CANCELED / ...), `createdAt` (last prod deploy, unix ms), `type` (LAMBDAS = Functions, null = static), `meta.lambdaRuntimeStats` (Functions created count, per-runtime {nodejs:N, provided:N, ...}).
6. recent prod deployment count (per project): read `targets.production.createdAt` and count where createdAt >= now - 30d.
7. **BLOCKED reason extraction**: for every project where `targets.production.readyState == "BLOCKED"`, the script fetches `/v6/deployments?projectId=<id>&limit=20&teamId=<team-id>&meta=1` and finds the first deployment whose `readyState` is `"BLOCKED"`, then surfaces its `errorMessage` + `seatBlock.blockCode` + `meta.githubCommitAuthorEmail` + `meta.githubCommitMessage`. this is reported as a separate "BLOCKED reason" section after the per-project table.

status is reported as `<userStatus>/<teamBlocked>` per team, and per-project `readyState` shows which projects are blocked. the BLOCKED-reason section explains WHY each one was blocked.

### gotcha: pagination
`/v9/projects?limit=100` paginates; the script uses `limit=100` but only fetches the first page. if a team exceeds 100 projects in future, add pagination (the response contains `pagination.next`).


## agent-browser: launching agent-browser with mainframe profile

> **PROFILE LIFETIME = 1 RUN.** Every `run` / `login` / `exec` invocation re-syncs the email-keyed profile dir from real Edge via `/MIR` delta-sync (VSS shadow → robocopy). The profile dir **persists on disk between runs** for fast delta syncs, but `/MIR` overwrites any in-profile changes with the real Edge state on next spawn. Nothing you write inside the profile persists to the next run — bookmarks, downloads, extension installs, settings changes, `edge://extensions` toggles, saved passwords, anything agent-browser writes to the user-data-dir is **overwritten on the next spawn**. Treat each `run` as a disposable one-shot session:
> - **do not** rely on in-profile state surviving across runs (cookies/localStorage do survive because they come from real Edge via the re-clone — but anything you *change* inside the copy does not).
> - **do not** "install this extension into the profile so it's there next time" — it will be wiped. Pass extensions via `-Extension <path>` on each `run`, or keep them in your real Edge install so the re-clone brings them in.
> - **do not** recommend a user "fix" a corrupt extension by clicking Repair in `edge://extensions` — the next sync replaces the copy anyway.
> - persisted things live in real Edge (`%LOCALAPPDATA%\Microsoft\Edge\User Data`) or in the agent-browser state vault under `~/.agent-browser/sessions/` (cookies/localStorage snapshots), NOT in the mainframe profile dir.
> - if a task needs durable profile-side changes (passwords, bookmarks, settings), make them in real Edge directly — never inside the agent-browser throwaway copy.
> - there is no way to "resume" a previous run's profile; each `run` is a fresh VSS clone. design automation accordingly (login inside the same `run` that does the work, or use `agent-browser-auth save`/`state save` for cross-run session state in `~/.agent-browser/`, not the profile dir).

context: agent-browser is a browser automation service. it has its own per-email profile directory at `%APPDATA%\mainframe\accounts\agent-browser\<email>\` and its own helper `<repo>\agent-browser-account.ps1`. **the email-keyed dir IS Chromium's `--user-data-dir`** (contains `Default/` plus sibling state files like `Local State`, `extensions_crx_cache`, `component_crx_cache`, etc., mirroring real Edge's User Data layout) — no `chrome-profile` subdir.

### prerequisites
- agent-browser installed: `npm i -g agent-browser && agent-browser install`
- a mainframe agent-browser profile in `%APPDATA%\mainframe\accounts\agent-browser\<email>\`, created via `login` (or seeded by copying the real Edge User Data dir in — see "edge-cdp copy" section below)
- an elevated shell with VSS enabled for full-profile sync (see below)

### the helper already does everything — do not set env vars manually
`agent-browser-account.ps1` injects both `--profile` and `--executable-path` flags per invocation. in particular `run`/`login`/`exec`/`close`:
- inject `--profile %APPDATA%\mainframe\accounts\agent-browser\<email>` (the email-keyed dir directly, NOT a `chrome-profile` subdir)
- inject `--executable-path` pointing at the installed Edge/Chromium binary (default `C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe`)
- `run`/`login` call `agent-browser open` — omit `-Url` to default to `https://example.com`. do NOT pass `about:blank` (vanilla) — that triggers agent-browser's "relaunched browser" bug which corrupts state
- `run`/`login` inject `AGENT_BROWSER_ARGS=--restore-last-session` (Chromium passthrough via agent-browser's documented env) before spawn so Edge auto-restores the tabs from the synced `Default/Sessions/Session_*`/`Tabs_*` files instead of leaving them behind a manual "Restore" button. the env is preserved around the spawn (restored to its prior value afterwards) so it never leaks into the parent shell.

so the correct way to launch is:
```
<repo>\agent-browser-account.ps1 run   <email>                                 # defaults to https://example.com
<repo>\agent-browser-account.ps1 run   <email> -Url https://example.com
<repo>\agent-browser-account.ps1 exec   <email> snapshot -i
<repo>\agent-browser-account.ps1 exec   <email> get url
<repo>\agent-browser-account.ps1 close  <email>
```
`exec` passes any agent-browser subcommand against the persistent profile (snapshot, get, click, fill, ...).

### do NOT do these (broke things once)
1. do not `Stop-Process msedge` / `Stop-Process chrome` to "clean up" — it kills the user's regular browser. use `agent-browser-account.ps1 close` or `agent-browser close --all` (that stops only the daemon agent-browser spawned, not the user's personal Edge).
2. do not set `AGENT_BROWSER_PROFILE` / `AGENT_BROWSER_EXECUTABLE_PATH` at the User environment-scope expecting it to "always launch with profile". the helper re-derives these per invocation and hand-setting them silently breaks sessions. if a one-off run without the helper is needed, set them in the current shell only (`$env:...`) and clear them afterwards.
3. do not pass an arbitrary `--profile` directory to raw `agent-browser`. always use the helper.

### edge-cdp sync-on-launch (full Edge clone, refreshed every session)

for 24/7 CDP use against a logged-in Edge profile without losing extensions or corrupting the user's real Edge install, the helper **auto-copies the real Edge User Data dir into the mainframe profile dir before every spawn**. this gives a fresh throwaway copy per session — whatever CDP prunes during the session stays in the copy, never touching real Edge.

how it works:
- the `Sync-EdgeProfileToMainframe` function (inlined in `agent-browser-account.ps1`, also exists as standalone `edge-cdp-profile-sync.ps1`) runs **before every `run`/`login`/`exec` spawn**.
- robocopy `/MIR` mirrors the real Edge User Data dir → `%APPDATA%\mainframe\accounts\agent-browser\<email>\`, using an exclude list like `backup.ps1`'s (caches, telemetry, edge component dirs, isolated leveldb blobs, history, db temps). `Local State` (cookie master key), `Default\Extensions`, `Default\Network\Cookies`, `Default\Preferences` (install signatures) all come across — **no files skipped due to locks**.
- `mainframe-profile.json` (extensions list) and session state dirs (`mainframe-sessions`, `sessions`) are **preserved across the /MIR** — staged to temp, then restored.
- **VSS snapshot path (the only path, needs admin)**: a Volume Shadow Copy of the system drive is taken via `Win32_ShadowCopy.Create` (`ClientAccessible` context), then a directory symlink is created with `cmd /c mklink /d <tmp> \\?\GLOBALROOT\Device\HarddiskVolumeShadowCopyN\` so robocopy can read the shadow through a normal Win32 path. this lets robocopy copy **files Edge holds with exclusive write handles** (Cookies, Local State, Preferences, Session Storage) without closing real Edge. shadow is dropped immediately after sync (post-success or post-failure). there is **no fallback** — if VSS shadow creation or `mklink` fails (typically "shell not elevated" or VSS disabled), `Sync-EdgeProfileToMainframe` throws and the spawn aborts. kill-real-Edge was intentionally removed as a fallback because a non-VSS robocopy against the live path silently skips locked files (Cookies, Local State, Preferences, Session Storage) and produces a corrupt profile.
- copy size is ~370 MB (cache dirs excluded). first sync takes ~30s with VSS; subsequent `/MIR` syncs are delta-fast since robocopy only re-copies changed files.

**prereq: an elevated shell with VSS enabled.** sync (and therefore every `run`/`login`/`exec`) will throw if launched non-elevated or with VSS unavailable — there is no Edge-kill fallback to silently keep going.
```
<repo>\agent-browser-account.ps1 run   <email>                                 # defaults to https://example.com
<repo>\agent-browser-account.ps1 run   <email> -Url https://example.com
<repo>\agent-browser-account.ps1 exec  <email> snapshot -i
```

caveat: during any given CDP session, Edge's dev-mode install-signature verification prunes Microsoft-bundled component extensions and a handful of user-installed ones. the **next session's sync replaces the pruned copy with a fresh one from real Edge**, so the pruned set never accumulates and never reaches the user's real Edge profile.

manual sync (one-off, e.g. testing or seeding a new profile):
```
<repo>\edge-cdp-profile-sync.ps1 -Email <email>
```

### stale DevToolsActivePort / SingletonLock
if `agent-browser open` fails with `Failed to connect: ... actively refused it (os error 10061)` right after launching Edge, the profile dir has a stale `DevToolsActivePort` and/or `SingletonLock` from a previous crashed session. fix:
```
Remove-Item "$env:APPDATA\mainframe\accounts\agent-browser\<email>\DevToolsActivePort" -Force -ErrorAction SilentlyContinue
Remove-Item "$env:APPDATA\mainframe\accounts\agent-browser\<email>\SingletonLock" -Force -ErrorAction SilentlyContinue
```
then retry. a successful launch will recreate both files.

### env helper (for ad-hoc, not permanent)
`agent-browser-account.ps1 env [email]` prints the exact env vars to set for that profile (`AGENT_BROWSER_PROFILE`, `MAINFRAME_AGENT_BROWSER_EMAIL`, `MAINFRAME_AGENT_BROWSER_RESTORE`, `AGENT_BROWSER_RESTORE`). use these only in the current shell when scripting against raw `agent-browser` and skip the helper. do NOT persist them at user/machine env scope.

### spawning from an AI agent's bash/shell tool (detached workflow)
**known opencode bug:** calling `agent-browser open` (or the helper's `run`/`login`/`exec`) from an AI agent's bash tool polls forever — the browser launches but the tool never returns control. `exec` is especially bad because it re-runs VSS sync (killing any already-running session) AND polls. **never call `run`/`login`/`exec`/`open` directly from the agent bash tool.**

the working pattern is a **3-step detached workflow**: sync externally → spawn externally → control via detached commands.

#### step 1: sync the profile (standalone, returns cleanly)
run the standalone sync script directly from the agent bash tool — it does VSS shadow + robocopy + extension repair, then returns. no browser is spawned, no polling:
```
& "<repo>\edge-cdp-profile-sync.ps1" -Email <email>
```
this is safe to call from the agent bash tool. it refreshes the profile copy from real Edge. skip if a recent sync already happened (e.g. a previous `run` in the same hour).

#### step 2: spawn the browser detached (Start-Process)
spawn `agent-browser open` in a detached pwsh window via `Start-Process` so the agent bash tool returns immediately. the browser opens in its own window and stays running:
```powershell
$email = "<email>"
$profileDir = "$env:APPDATA\mainframe\accounts\agent-browser\$email"
# clean stale locks if a previous session crashed
Remove-Item "$profileDir\DevToolsActivePort" -Force -EA SilentlyContinue
Remove-Item "$profileDir\SingletonLock" -Force -EA SilentlyContinue
Start-Process pwsh -ArgumentList '-NoExit','-Command',@"
`$env:AGENT_BROWSER_PROFILE = '$profileDir'
`$env:AGENT_BROWSER_EXECUTABLE_PATH = 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
agent-browser open 'https://example.com'
"@ -WindowStyle Normal
```
stealth flags (`--disable-blink-features=AutomationControlled,--disable-features=AutomationControlled`) are inherited automatically from the User-scope `AGENT_BROWSER_ARGS` env var (see "Google sign-in under CDP" note below). if that env var is not set on this machine, add it to the script block above:
```
`$env:AGENT_BROWSER_ARGS = '--disable-blink-features=AutomationControlled,--disable-features=AutomationControlled'
```

#### step 3: control the running session (detached commands)
after the browser is running, send `agent-browser` commands via `Start-Process` with output redirected to a temp file. the agent bash tool reads the temp file to get results. **do not run `agent-browser` commands directly in the agent bash tool — they poll too.** pattern:
```powershell
$email = "<email>"
$profileDir = "$env:APPDATA\mainframe\accounts\agent-browser\$email"
$outFile = "$env:TEMP\ab-out.txt"
Remove-Item $outFile -EA SilentlyContinue
Start-Process pwsh -ArgumentList '-Command',@"
`$env:AGENT_BROWSER_PROFILE = '$profileDir'
`$env:AGENT_BROWSER_EXECUTABLE_PATH = 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
agent-browser snapshot -i -c 2>&1 | Out-File '$outFile' -Encoding utf8
"@ -WindowStyle Hidden
Start-Sleep -Seconds 6   # adjust per command complexity
Get-Content $outFile -Raw -EA SilentlyContinue
```
encoding gotcha: `agent-browser eval` output piped through
`Out-File -Encoding utf8` mojibakes non-ascii (pwsh decodes the utf8 stdout
as cp437 first). for eval results that may contain non-ascii, set `[Console]::OutputEncoding = [Text.Encoding]::UTF8`
at the top of the spawned command AND write with `[IO.File]::WriteAllText($f, $v, [Text.Encoding]::UTF8)`
instead of `Out-File`. for pure capture/verification work, `[IO.File]::WriteAllText` alone is enough.
working commands tested with this pattern:
- `agent-browser get url` — current page URL (~3s)
- `agent-browser get title` — current page title (~3s)
- `agent-browser snapshot -i -c` — interactive element tree (~6s)
- `agent-browser snapshot` — full accessibility tree (~8s)
- `agent-browser click <ref>` — click an element by ref (~4s)
- `agent-browser fill <selector> "<value>"` — fill an input (~4s)
- `agent-browser navigate <url>` — go to a URL (~5s)
- `agent-browser screenshot` — save a screenshot to default dir (~5s)
- `agent-browser cookies get` — list all cookies (~4s)
- `agent-browser cookies set <name> <value> --url <url>` — set a cookie (~4s)

adjust `Start-Sleep` based on command complexity. snapshots and screenshots take longer than `get url`.

#### step 4: close the session
```
agent-browser close --all
```
this stops only the agent-browser-spawned Edge daemon, not the user's personal Edge. safe to run from the agent bash tool (returns quickly).

#### troubleshooting
- **"Failed to connect: ... actively refused it (os error 10061)"**: stale `DevToolsActivePort`/`SingletonLock` in the profile dir. delete them (see "stale DevToolsActivePort" section above) and retry the spawn.
- **Google sign-in blocked ("This browser or app may not be secure")**: stealth flags missing. verify `AGENT_BROWSER_ARGS` is set (User env or inline in the spawn script block). see "Google sign-in under CDP" note below.
- **commands return empty output**: the detached pwsh process may still be running. increase `Start-Sleep`, or check if the temp file exists yet with `Test-Path`.
- **browser didn't launch**: check if a previous Edge session is still holding the profile dir. run `agent-browser close --all` first, clean stale locks, then retry.

### which account to use
check active first:
```
<repo>\agent-browser-account.ps1 current
<repo>\agent-browser-account.ps1 status-all
```
switch with `agent-browser-account.ps1 use <email>`. rules from the tool account workflow still apply — every supported agent-browser profile is keyed by account email; if you cannot detect email after login, fail/ask instead of saving a username/label fallback.

- no live-edge / CDP-attach mode. the only mode is sync-then-spawn (above). `live-edge`/`live-edge-off`/`liveEdgeProfile` were removed because Edge's `--remote-debugging-port` always trips dev-mode extension signature verification, pruning component extensions even on a junctioned user-data-dir, and once even pruned the real Edge profile. the sync-then-spawn workaround (fresh throwaway copy per session) avoids that entirely. CDP-attach's other appeal was reusing an active Google sign-in to dodge "This browser or app may not be secure".
- **Google sign-in under CDP requires stealth flags.** Empirically verified: even with the synced real-Edge profile (which carries the live Google cookies via VSS), navigating to `myaccount.google.com` from a freshly synced automation-Edge spawn returns "This browser or app may not be secure. Try using a different browser." — the original assumption that "the copied profile retains the real Edge cookies, so Google sessions still work" is **wrong**. Google fingerprints the CDP-controlled browser via `navigator.webdriver=true` and the Blink `AutomationControlled` feature, then refuses to honor the cookies. **Fix:** `AGENT_BROWSER_ARGS` is set to `--disable-blink-features=AutomationControlled,--disable-features=AutomationControlled` at **User env scope** so every `agent-browser` invocation (raw or via the helper) gets stealth by default. The helper also re-injects these flags on every spawn as a safety net. With those flags, Google sign-in works inside the synced profile. **Do not remove those flags** (neither the User env var nor the helper injection) or Google sign-in breaks. Other sites (GitHub, etc.) work without the stealth flags, but Google is strict and needs them.

## agent-browser: lightweight cookies mode (cookies save/run/verify/status)

a refresher/notifier can need a logged-in session for a site but should not carry the ~370 MB synced profile or require VSS elevation every run. this mode stores only the domain-filtered cookies (a few KB) and spawns a throwaway ~20 MB profile with them injected. no VSS sync, works non-elevated after the one-time save.

### commands
```
<repo>\agent-browser-account.ps1 cookies save   <email> [-Domains <site.com>] [-FromSession]
<repo>\agent-browser-account.ps1 cookies run    <email> [-Url https://<site>]
<repo>\agent-browser-account.ps1 cookies verify <email> [-Url ...]   # headless, prints VERDICT
<repo>\agent-browser-account.ps1 cookies status <email>
```
- `save` — exports cookies for the domains from the REAL-EDGE-synced profile via VSS (needs one elevated run), or from the live agent-browser session with `-FromSession` (no sync — capture right after a manual login inside agent-browser). export → `%APPDATA%\mainframe\accounts\agent-browser\cookies\<email>.cookies.json` + `.meta.json` sidecar. profile is keyed by email; `cookies-lite\<email>\` is the throwaway profile dir.
- `run` — spawns a headed window with cookies injected and the target URL open (meant for manual/refresher use).
- `verify` — fully scripted headless check: warmup → import → navigate → snapshot → VERDICT (LOGGED IN when site markers present, else LOGIN REQUIRED).

### verified behavior + gotchas
1. **`open` BLOCKS FOREVER** (agent-browser poll bug) — never put it mid-script; it must be the LAST command in run mode. scripted sequences use `cookies get --json` (spawns the browser AND returns cleanly) as warmup + `navigate` for page changes.
2. **cold daemon rejects the first `Network.setCookies` batch** with "Invalid cookie fields" (mystery failures on first spawn). always warm up with `cookies get --json` BEFORE `cookies set --curl`. warm daemon imports are reliable.
3. **never `$globals -join ' '` raw paths into a spawned script** — `C:\Program Files (x86)\...` unquoted becomes a PowerShell expression (`(x86)` → "x86 not recognized") and the whole spawned pwsh dies with NO output files (verify times out with zero evidence). quote every value arg (`'--profile', $dir` → `"'$dir'"`).
4. **`2>&1 | Out-File` over a multi-line spawned script silently drops lines / can block forever** — redirect each command to its OWN file with `*>` instead.
5. **ConvertTo-Json unwraps single-element arrays** → the importer says "no cookies found in input". always `ConvertTo-Json -AsArray` for exports/imports.
6. **some sites validate sessions across BOTH domains** — e.g. facebook-family sites delete `c_user`/`xs`/`sb` cookies on page load if only one co-domain is imported. the helper duplicates every family cookie on the co-domain(s) at import time; that's what makes the session stick.
7. import drops `httpOnly` + `expires` (persistent cookies become session cookies) — harmless because every run re-imports fresh.
8. the lite profile dir PERSISTS between runs (not `/MIR`-wiped like full profiles) — after the first successful login the session cookies live on disk, so later runs are faster; re-import keeps them fresh.
9. stale daemon races: if a headed browser from a previous run is still holding the lite profile dir, a new headless spawn can stall (SingletonLock contention) → verify timeout. `agent-browser close --all` first, or bump the wait.

### scope: site-tuned, generic mechanics
- the vault + lite-profile mechanics are SITE-AGNOSTIC: `cookies save -Domains <any-site>` captures any site's cookies and `run/verify -Url <any-site>` injects them into the throwaway profile. the defaults (e.g. `facebook.com,messenger.com`) are just defaults.
- the parts that are SITE-SPECIFIC: (1) the dual-domain co-copy (gotcha 6) fires only for configured cookie families; (2) the `verify` VERDICT heuristic greps for site login markers vs the logged-in UI — for other sites the verdict can misclassify; the snapshot dump is the reliable evidence there. adjust the heuristics per site.

## tailscale: persistent remote access helper

context: tailscale (wireguard mesh vpn) gives persistent remote access to a machine (and any
other machine it's installed on) over any internet connection - no port forwarding, works across
different wifi/networks. installed via scoop (`extras/tailscale`, MSI-extracted); the `Tailscale`
windows service is `Automatic` and runs `<scoop>\apps\tailscale\current\tailscaled.exe`
(substitute the scoop root path if different).
helper: `<repo>\tailscale-account.ps1` (contract PASS).

### setup pattern
- node: `<hostname>` (100.x tailnet IP, DNS <hostname>.ts.net.), tailnet owner:
  the tailnet account email (profile dir `%APPDATA%\mainframe\accounts\tailscale\<email>\`).
- joined with `tailscale up --authkey=... --unattended --hostname=<hostname>`; `--auto-update` on.
- **permanence settings**: admin console must have "Disable key expiry" enabled for the node
  (console > Machines > <node> > Disable key expiry) - without it the node key expires
  ~180 days and can drop. `--no-session-expiry` is NOT a valid flag in tailscale 1.102.2 set
  (do not retry it); unattended mode + disabled key expiry is what keeps it logged in forever.
- profiles are keyed by account email; the real login email is detected from
  `tailscale status --json` as `User.<self.UserID>.LoginName` (fallback CurrentTailnet.Name).
- live node IPs / hostnames / tailnet DNS names are NOT repo material (repo is public) — keep them in local AGENTS.md / the admin console.

### usage
```
<repo>\tailscale-account.ps1 status-all
<repo>\tailscale-account.ps1 status [email]
<repo>\tailscale-account.ps1 run -- <tailscale args>
<repo>\tailscale-account.ps1 ssh <email> <user>@<tailnet-host> [cmd]
<repo>\tailscale-account.ps1 ip | peers | nodes
<repo>\tailscale-account.ps1 up | down | login <email> | logout [email]
<repo>\tailscale-account.ps1 key-add <email> <tskey-...>
<repo>\tailscale-account.ps1 provision <email> <hostname>
<repo>\tailscale-account.ps1 backup <email> | restore <email>
```
`run --` proxies any tailscale cli call; `ssh` resolves the peer to its 100.x IP and uses
OpenSSH with the key named by `$env:TAILSCALE_SSH_KEY_NAME` (default `id_ed25519`,
StrictHostKeyChecking=accept-new) - tailscale ssh is only used when the ssh key is missing
(needs the admin-console SSH policy otherwise).

### fleet workflow (N pcs, all in one tailnet, mainframe backup/restore)
1. **once per tailnet**: generate ONE *reusable* auth key in the admin console
   (Settings > Keys > Auth keys > Generate > Reusable ON, Ephemeral OFF) and store it:
   `tailscale-account.ps1 key-add <email> tskey-...`
   → saved to `%APPDATA%\mainframe\accounts\tailscale\<email>\authkey.txt`.
   mainframe `backup.ps1` already snapshots `%APPDATA%\mainframe\accounts\` so the key
   travels with every mainframe backup/restore automatically. (auth keys max 90-day
   expiry — rotation only affects NEW joins, existing nodes keep working; regenerate +
   `key-add` once a year, or store a non-expiring API access token in the same file and
   mint one-shot keys via the admin API instead.)
2. **on any new pc**: `scoop install tailscale` (service auto-registers) → restore the
   mainframe backup (or copy just that profile dir) →
   `tailscale-account.ps1 provision <email> <hostname>` → joins the tailnet as its OWN
   node (own 100.x IP, `--unattended --auto-update`), no browser, no per-machine key.
   check it: `tailscale-account.ps1 nodes` or `status-all`.
3. **identity migration (same node on another machine)**: `backup <email>` on the source
   machine (snapshots `tailscaled.state` into the profile dir) → copy profile dir →
   `restore <email>` on the target + restart Tailscale service → target adopts that
   node's identity (same IP/hostname). only ONE machine may hold an identity at a time.
4. **permanence per node**: admin console > Machines > node > "Disable key expiry" (else
   node key expires ~180 days). `--no-session-expiry` is NOT a valid flag in 1.102.2 set
   - unattended + disabled key expiry is the permanent combo.

### gotchas
- **firewall/WFP block**: a policing firewall (e.g. a VPN client's WFP filter) can deny `tailscaled.exe` outbound
  sockets (symptom: `tailscale up --authkey`/`login` hang forever with no output, `status`
  works, daemon log shows `dial log.tailscale.com:443 ... connectex: An attempt was made to
  access a socket in a way forbidden by its access permissions`). fix = allow tailscaled.exe
  egress in the policing product, then retry. `Test-NetConnection` from a normal shell can pass while tailscaled is still blocked -
  the deny is per-process.
- `tailscale up --timeout=25s` converts the silent hang into a real error ("timeout waiting
  for Tailscale service to enter a Running state") - always use a timeout when debugging joins.
- two tailscaled.exe processes (main + `/subproc` child) is NORMAL - the subproc is the
  privilege-separated helper, not a conflict; do not kill it.
- stale hung `tailscale login` CLI processes block subsequent joins - kill them before retrying.
- wiping `%LOCALAPPDATA%\Tailscale` + `C:\ProgramData\Tailscale` resets an unauthenticated
  node cleanly (service recreates state) - safe only while Logged out.
- scoop shim vs real binary: use `<scoop>\apps\tailscale\current\tailscale.exe`
  when redirecting output from scripts (shim behaves fine normally; direct binary avoids
  ambiguity).
- **admin console moved to `console.tailscale.com` (2026-07-23)**: old `login.tailscale.com/admin/...` links 404;
  docs URLs are stale. OAuth clients no longer live under Settings > Keys - they're on the **Trust credentials**
  page (`console.tailscale.com/admin/settings/trust-credentials`) via the Credential > OAuth > pick operations
  (Devices Read+Write) > Generate credential flow. client id looks like `kbEruMptnw11CNTRL`, secret like
  `tskey-client-...` (never expires; shown once).
- **API cleanup via OAuth client**: oauth client id/secret stored at
  `%APPDATA%\mainframe\accounts\tailscale\<email>\oauth.json` (vault copy: `console.tailscale.com` item).
  mint a 1h token with `POST https://api.tailscale.com/api/v2/oauth/token` (client_credentials),
  then `GET/DELETE https://api.tailscale.com/api/v2/tailnet/<email>/devices` / `api/v2/device/{id}`.
  useful for deleting stale ephemeral nodes (e.g. leftover deploy nodes).
- **helper ssh from an agent shell**: `TAILSCALE_SSH_KEY_NAME` is read from the
  ENVIRONMENT - agent shells don't inherit it, so the helper falls back to `id_ed25519` and
  auth prompts/hangs. always set `$env:TAILSCALE_SSH_KEY_NAME = '<fleet key name>'` in the
  same command before calling `tailscale-account.ps1 ssh ...`, and wrap the ssh in
  `Start-Job` + `Wait-Job -Timeout` so the shell tool returns even if ssh stalls.
- **VPN clients can block direct sockets**: a VPN service can WFP-block ALL non-tunnel
  traffic incl. LAN + tailnet peer dials. for direct-socket work on such a machine:
  stop the VPN client + service, do the work, then restore. the NCF is per-process and NOT
  influenced by service stop alone while the client runs.

## skills dir nesting guard

`~/.agents/skills` was once copied into itself multiple levels deep
(`skills\skills\skills\...`) by a botched skill install/sync, duplicating ~25 MB and
making the skill loader read stale deep copies. fixed by pruning the chain and adding
a self-healing guard in `agent-rules-sync.ps1` (runs at every logon): if
`~/.agents\skills\skills\skills` (depth >= 2) exists, the whole nested chain is a copy
artifact and gets deleted, keeping only the top-level tree. `backup.ps1` already skips
nested `skills` dirs via `/XD skills` when archiving `~/.agents\skills`. if nested
`...\skills\skills\...` paths ever appear again, re-check the tree for nesting.

## uptimerobot: status page + monitor helper

helper: `<repo>\uptimerobot-account.ps1` (contract PASS). profiles at `%APPDATA%\mainframe\accounts\uptimerobot\<email>\` (api-key.txt).

### v3 is the ONLY API that works for writes
- v2 `/v2/newMonitor` returns HTTP 403 `access_denied: You are not allowed to use some settings with your current plan` on current accounts (all fields, even minimal). do NOT debug v2 - it is broken.
- use v3: `https://api.uptimerobot.com/v3/<path>` with `Authorization: Bearer <api-key>` and camelCase JSON bodies (`friendlyName`, `url`, `type: "http"`, `interval`, `timeout`).
- endpoints: `GET /monitors`, `GET /monitors/:id`, `POST /monitors` (create), `DELETE /monitors/:id`, `POST /monitors/:id/pause`, `POST /monitors/:id/start` (pause/resume - `PATCH ... {status:...}` is rejected with "property status should not exist"), `GET /psps`, `POST /psps`, `PATCH /psps/:id {monitorIds:[...]}`. edit = v3 `PATCH /monitors/:id` with camelCase delta (`friendlyName`, `timeout`, ...) - returns the full updated monitor; v2 `/v2/editMonitor` silently no-ops (stat "ok" but nothing changes - verified 2026-08-14).
- rate limit: FREE = 10 req/min; pace creations (8s sleep worked). 429 bodies carry X-RateLimit-* headers.
- list via v3 `GET /monitors` or v2 `POST /getMonitors` form-encoded `{api_key, format=json}` (v2 works for reads).

### status pages (PSP)
- create monitors under a PSP (public status page) so they aggregate on one page.
- PSPs can be password protected (password set by user, not stored in the repo); the urlKey in the PSP record maps to the public status page URL.

## huggingface: space secrets/variables (no CLI support)

the `hf` CLI has no secrets/variables command; use the HF REST API with the mainframe profile token (read from `%APPDATA%\mainframe\accounts\hf\<email>\token`) and `Authorization: Bearer <token>`.

- **secrets are write-only**: `POST https://huggingface.co/api/spaces/<owner>/<space>/secrets` (body `{"key":"NAME","value":"secret","description":"..."}`) upserts, `DELETE` with body `{"key":"NAME"}` removes, `GET` returns only key names + `updatedAt` (values NEVER returned).
- to READ values back use **variables**: `GET https://huggingface.co/api/spaces/<owner>/<space>/variables` returns `{"KEY":{"key":"KEY","value":"...","updatedAt":"..."}}` with values; `POST .../variables` upserts with the same body shape.
- pattern: store config you need to read back as a *variable*, store actual secrets (API keys, tokens) you never need to retrieve as *secrets*.
- `hf repos create --secrets` requires `space_sdk` even for existing Spaces and is not the right path for secret management.
- **repo deletion** (spaces or any repo): `DELETE https://huggingface.co/api/repos/delete` with JSON body `{"name":"<repo-name-only>","organization":"<owner>","type":"space"}` - NOT `DELETE /api/spaces/<owner>/<name>` (that 404s with "Cannot DELETE") and NOT `{"name":"<owner>/<name>"}` (404 "Repository not found"); split owner into `organization` + bare `name`. verify with GET `/api/spaces/<owner>/<name>` -> 404.

## cron-job.org: job inventory

helper: `<repo>\cronjob-account.ps1`. job inventory lives in the local profile docs / account sheet, NOT this repo (repo is public). API notes:

- job creation is PUT /jobs (POST 404s); API rate-limits hard (429, wait ~15-20s between creates); GET /jobs/<id> returns `{jobDetails:{...}}` shape; PATCH /jobs/<id> bodies MUST use `{"job":{...}}` (delta only) - `{"jobDetails":{...}}` gets HTTP 400; headers in `extendedData.headers` are a DICTIONARY {key:value}, NOT an array (array form gets HTTP 500); `lastStatus` codes: 1=OK, 2=DNS fail, 3=connect fail, 4=HTTP error (incl. 3xx when `redirectSuccess` false), 5=timeout.
- do NOT use `"each"` strings for schedule values; use numeric `-1` arrays like the helper's `create`.
- manual-executions endpoint (`POST /jobs/<id>/executions`) is flaky (silent success then nothing in history) - verify via scheduled runs instead.
- keep-alive pattern: every hosted service (Render free, HF Space, Vercel free) gets a GET keep-alive job so free instances don't sleep. name pattern `<provider> keep-alive - <name>`; HF Space roots that redirect `/` -> `/signin` (302) need `redirectSuccess: true` PATCHed or the job reports lastStatus 4.
- `lastStatus` codes: 1=OK, 2=DNS fail, 3=connect fail, 4=HTTP error, 5=timeout.

### vercel: multi-account deploy BLOCKED workaround (TEAM_ACCESS_REQUIRED)

- Hobby/team deploys without a GitHub login connection: avoid paid team-member upgrades and reconnecting GitHub per account.
- detect: deploy shows `readyState: BLOCKED` with `seatBlock.blockCode: TEAM_ACCESS_REQUIRED` (Git author lacks team access).
- surface ALL blocked projects across accounts at once: `<repo>\vercel-usage-table.ps1` - its BLOCKED-reason section shows the blockCode + commit author per project.
- fix: create a local deployment-alignment commit authored with the target Vercel account email before deploying: `git -c user.email="<target-vercel-email>" -c user.name="<name>" commit --allow-empty -m "deployment alignment"` (empty commit only when there is no real scoped change to commit).
- then redeploy and verify the live URL/domain.
- never pay for team-member seat upgrades or reconnect GitHub per account to work around this.

## supabase: account helper

helper: `<repo>\supabase-account.ps1` (contract PASS). profiles at `%APPDATA%\mainframe\accounts\supabase\<email>\` (token.txt = Personal Access Token `sbp_...`). Management API base `https://api.supabase.com` (v1), Bearer auth. token fingerprint + status via `status`/`status-all`; backup.ps1 already snapshots the accounts dir so supabase profiles travel with every mainframe backup/restore.

### adding an account (vault-first flow)
1. create the token in the dashboard: supabase.com/dashboard/account/tokens -> Generate new token -> "Expires in" dropdown -> **"Never"** (a short-lived token dies and the profile breaks; rotate manually when needed).
2. user saves the token into a password vault, then the agent syncs and reads it back from the vault item, then writes `token.txt` into the profile dir.
3. write `profile.json` (tool/service/profile/apiEndpoint/apiVersion/keyPath/updatedAt) + `current.json` for active state — the helper's `login` does this interactively too.
4. verify with `.\supabase-account.ps1 run <email> GET v1/projects` (and `organizations`).

### bulk scripts at mainframe root (mirror the neon equivalents)
- `<repo>\supabase-projects-table.ps1` — every project across all supabase profiles (name, ref, org, region, db version, status, created). mirror of `neon-projects-table.ps1`.
- `<repo>\supabase-usage-table.ps1` — per-project usage vs Free quota (500 MB database) using `config/disk/util` `fs_used_bytes` (byte-identical to the dashboard Database size). `-Json` for scheduled consumers. mirror of `neon-hours-table.ps1`.
- quota/limits: Free plan = 500 MB DB per project (Storage 1 GB + Egress 5 GB have NO public per-project Management API endpoint — not reported). paused projects return HTTP 500 on disk/util (expected → Status `n/a (paused?)`). rate limits: 120 req/min per user per project/org, analytics endpoints 30 req/min.
- env overrides: `SUPABASE_FREE_DB_MB` (default 500), `SUPABASE_LOW_PCT` (default 0.85).

### commands
`login`/`token-add`, `token-clear`, `use`, `run`, `projects`, `project <ref>`, `organizations`, `api-keys <ref>`, `status`, `status-all`, `list`, `current`, `path`, `env`, `logout`.

### gotchas
- **token is write-only in the dashboard after creation** — only the vault copy can be re-read; keep the vault item in sync.
- `/v1/projects` on a brand-new account returns `[]` while `/v1/organizations` already returns the org — an empty project list is NOT a broken token.
- `run` restricts the host to `api.supabase.com` (path can be full URL or bare like `v1/projects`; bare paths get `/v1` prefixed).
- profiles keyed by account email only — never store username/label/project-name fallbacks.