# mainframe

Strict Scoop backup and restore for Windows machines.

`mainframe` captures a Scoop app snapshot plus persisted Scoop settings, then restores them on another machine. It defaults to latest bucket versions on restore.

It can also restore native Windows apps that should not be Scoop-owned. These are service-style exceptions for apps where Scoop's portable package loses important behavior.

## What It Saves

- Scoop buckets and config from `scoop export --config`
- Installed Scoop apps and held-package metadata
- Scoop persisted app data from `$SCOOP\persist`
- Native app installers and settings described in `native-apps.json`
- Optional encrypted tool auth/config from `tool-secrets.manifest.json` (for tools not yet on vault-native secrets: gcloud, gws, firebase, tailscale, telegram, whatsapp, microsoft, bitwarden session)
- Optional user-managed Agent skills from `%USERPROFILE%\.agents\skills`
- Optional Windsurf app data from `%USERPROFILE%\.codeium\windsurf`
- Optional Git global config from `%USERPROFILE%\.gitconfig`

## Files

- `backup.ps1` creates `mainframe-backup.zip` containing `scoopfile.json`, scoop persist data, native app artifacts, and encrypted secrets (unless `-ExcludeSecrets` is passed)
- `restore.ps1` restores Scoop, persisted settings, buckets, apps, native app exceptions, and encrypted secrets from `mainframe-backup.zip`
- `backup-secrets.ps1` creates standalone `tool-secrets.zip` from the paths in `tool-secrets.manifest.json` (used by `restore-secrets.ps1`)
- `restore-secrets.ps1` restores `tool-secrets.zip` and backs up overwritten targets first
- `vault-secret.psm1` shared module: vault-native secrets for the account helpers (neon, supabase, vercel, hf, render, cloudflare, cronjob, github, notion, uptimerobot) — reads/writes per-profile tokens in the Bitwarden vault via `Read-VaultSecret` / `Write-VaultSecretToExisting`; requires an unlocked BW session (session.key from `automata\bitwarden.com\unlock.ps1` or `$env:BW_SESSION`)
- `account-contract.ps1` checks that every `*-account.ps1` helper keeps the shared mainframe account command contract
- `scoop-allowed.json`, `pnpm-allowed.json`, `uv-allowed.json`, `go-allowed.json`, and `pip-allowed.json` are required desired tool allowlists; backup and restore both require them, restore installs every listed item and fails if an allowed install is missing, and `scoopfile.json` metadata is used only for Scoop apps that were in the backup snapshot
- `vercel-account.ps1` manages separate token-only Vercel CLI profiles by email
- `neon-account.ps1` manages separate Neon CLI profiles by email using Neon CLI's per-profile config directory support
- `gws-account.ps1` manages separate Google Workspace CLI profiles by email using `GOOGLE_WORKSPACE_CLI_CONFIG_DIR`; it also reuses those OAuth profiles for Google Search Console API commands
- `gcloud-account.ps1` manages separate Google Cloud CLI profiles by email using `CLOUDSDK_CONFIG`
- `firebase-account.ps1` manages separate Firebase CLI profiles by email using profile-local `XDG_CONFIG_HOME`
- `render-account.ps1` manages separate Render CLI profiles by account email using Render's official `RENDER_CLI_CONFIG_PATH` setting
- `cronjob-account.ps1` manages separate cron-job.org API key profiles by account email for creating, updating, disabling, and inspecting scheduled HTTP jobs
- `cloudflare-account.ps1` manages separate Cloudflare profiles by detected account email, using either API tokens or isolated Wrangler browser auth for Wrangler commands, API calls, zone/DNS inspection, and private state exports
- `github-account.ps1` manages separate GitHub CLI/API token profiles by detected account email for `gh` commands and API calls
- `notion-account.ps1` manages separate Notion API token profiles by account email for API calls, optional `ntn` CLI commands, and page/block inspection
- `microsoft-account.ps1` manages separate Microsoft Graph OAuth profiles by detected account email for delegated Microsoft automation across mail, calendar, contacts, files, tasks, and notes
- `outlook-account.ps1` is a compatibility wrapper around `microsoft-account.ps1` for mail-focused workflows
- `hf-account.ps1` manages separate Hugging Face CLI profiles by detected account email using `HF_HOME` and profile-local token paths
- `devvit-account.ps1` manages separate Reddit Devvit CLI profiles by account email, swapping Devvit's official `%USERPROFILE%\.devvit\token` file into per-profile mainframe storage
- `reddit-account.ps1` manages separate Reddit API OAuth profiles by account email for posting as your own Reddit account
- `reddit-post.ps1` submits Reddit posts/comments through a saved `reddit-account.ps1` profile; it defaults to dry-run unless `-ConfirmPost` is passed
- `scoopfile.json` is the exported package snapshot
- `native-apps.json` describes non-Scoop apps that should be installed normally, plus settings-only entries with `SkipInstall`
- `tool-secrets.manifest.json` is the editable list of auth/config/skill paths to carry across machines
- `tool-secrets.zip` is the private archive created only when secret backup is requested

`restore.ps1` intentionally fails if `scoop-persist.zip` is missing.
If native apps are enabled, it also fails without `native-persist.zip` unless you pass `-SkipNativePersist`.

## Backup

Run from this folder:

```powershell
.\backup.ps1
```

By default it uses `$env:SCOOP`, falling back to `C:\Softwares\Scoop`.

For native apps, it also saves configured settings to `native-persist.zip` and copies installers into `native-installers`.
Entries with `SkipInstall: true` only save and restore settings; they do not run an installer.

Use a custom Scoop root:

```powershell
.\backup.ps1 -ScoopRoot C:\Softwares\Scoop
```

Skip the large Scoop persist archive while updating the package snapshot. Native app artifacts are still refreshed unless you also pass their skip flags:

```powershell
.\backup.ps1 -SkipPersist
```

Only refresh the public package snapshot:

```powershell
.\backup.ps1 -SkipPersist -SkipNativePersist -SkipNativeInstallers
```

Include portable auth/config secrets in the backup (enabled by default):

```powershell
.\backup.ps1
```

Skip the encrypted secrets archive:

```powershell
.\backup.ps1 -ExcludeSecrets
```

You can also refresh only the encrypted secrets archive:

```powershell
.\backup-secrets.ps1
```

## Tool Account Profiles

Vercel token-only profiles plus Neon, Google Workspace CLI, Google Cloud CLI, Firebase CLI, Browser UI automation, Render CLI, cron-job.org API, Cloudflare API, GitHub CLI/API, Notion API/CLI, Microsoft Graph, Hugging Face CLI, Reddit Devvit CLI, and Reddit API OAuth profiles are stored under:

```text
%APPDATA%\mainframe\accounts\
```

This keeps tool auth portable while still using the official CLIs. Mainframe account profile folders are always keyed by account email only; helpers fail or require the email instead of saving username, project-label, workspace-label, account-name, or account-ID fallbacks. `run [email] ...` works across helpers: pass an email to select a profile for that command, or omit it to use the active profile. `env [email]` prints only safe profile wiring and placeholders, never token values. No project `.env` files are scanned or copied.

Every `*-account.ps1` helper is expected to keep this baseline account contract: `login`, `use`, `current`, `list`, `status`, `status-all`, `path`, `env`, and `run`. Service-specific commands can be added on top, but the baseline keeps account muscle memory symmetric. Check the contract with:

```powershell
.\account-contract.ps1
```

Create and use Vercel token profiles. Vercel is token-only in mainframe because browser refresh sessions can go stale, but multi-account switching still works through one `token.txt` per email profile.

```powershell
.\vercel-account.ps1 token-add
.\vercel-account.ps1 login
.\vercel-account.ps1 use user@example.com
.\vercel-account.ps1 status user@example.com
.\vercel-account.ps1 status-all
.\vercel-account.ps1 run user@example.com whoami
.\vercel-account.ps1 run user@example.com deploy --prod
.\vercel-account.ps1 run deploy --prod
```

Each Vercel profile is saved as `%APPDATA%\mainframe\accounts\vercel\<email>\token.txt`, and the active email is saved as `current.json`. Legacy `current.txt` is still read during transition, but new writes use the same JSON pointer shape as the other helpers. Running `token-add` or `login` prompts for a token, calls Vercel's user API with that token, auto-detects the email, and saves the token under the detected email profile. There is no manual profile label fallback, Vercel browser login, refresh token, `auth.json`, or persistent Vercel CLI session storage in mainframe. Commands pass the selected token to the official Vercel CLI through `VERCEL_TOKEN` only while a command runs. Token-backed commands use a throwaway Vercel CLI config directory that is deleted after the run, with `VERCEL_TELEMETRY_DISABLED=1` set for that process. Treat every `token.txt` as a secret; back it up only through the encrypted backup flow.

Create and use Neon profiles:

```powershell
.\neon-account.ps1 api-key-add
.\neon-account.ps1 api-key-add user@example.com
.\neon-account.ps1 use user@example.com
.\neon-account.ps1 whoami user@example.com
.\neon-account.ps1 status user@example.com
.\neon-account.ps1 run user@example.com projects list
.\neon-account.ps1 run projects list
.\neon-account.ps1 run user@example.com branches list --project-id cool-project-123
```

Neon browser OAuth is intentionally disabled in mainframe. Save a Neon API key with `login`/`api-key-add`/`token-add`; the helper detects the owning email from Neon, stores the key under that email profile, and passes it as `NEON_API_KEY` only while a command runs.

Create and use Render profiles:

Install the official Render CLI first: https://render.com/docs/cli

```powershell
.\render-account.ps1 login
.\render-account.ps1 list
.\render-account.ps1 whoami user@example.com
.\render-account.ps1 workspaces user@example.com
.\render-account.ps1 services user@example.com
.\render-account.ps1 run user@example.com deploys list SERVICE_ID -o json
.\render-account.ps1 run workspaces -o json
.\render-account.ps1 psql user@example.com my-database -c "SELECT NOW();" -o text
```

If Render cannot expose an email from `render whoami`, the helper fails instead of saving a username, account ID, or manual label fallback. You can pass the account email explicitly when you already know it:

```powershell
.\render-account.ps1 login user@example.com
```

Create and use cron-job.org API profiles:

Create an API key in the cron-job.org Console settings page, then save it once:

```powershell
.\cronjob-account.ps1 token-add user@example.com
.\cronjob-account.ps1 use user@example.com
.\cronjob-account.ps1 status user@example.com
.\cronjob-account.ps1 jobs user@example.com
```

Create a simple every-minute HTTP job, then inspect or pause it:

```powershell
.\cronjob-account.ps1 create user@example.com https://example.com/api/cron "Example heartbeat"
.\cronjob-account.ps1 job user@example.com 12345
.\cronjob-account.ps1 history user@example.com 12345
.\cronjob-account.ps1 disable user@example.com 12345
.\cronjob-account.ps1 enable user@example.com 12345
```

Export and import cron-job.org job definitions:

```powershell
.\cronjob-account.ps1 export user@example.com
.\cronjob-account.ps1 import user@example.com
.\cronjob-account.ps1 import user@example.com -ConfirmImport -Disabled
```

For custom cron-job.org API calls, use the raw API wrapper:

```powershell
.\cronjob-account.ps1 run user@example.com PATCH /jobs/12345 '{"job":{"enabled":true}}'
.\cronjob-account.ps1 run PATCH /jobs/12345 '{"job":{"enabled":true}}'
```

cron-job.org API keys are saved as `api-key.txt` under the account profile folder. Job exports are saved as `jobs-export.json` under that same folder by default. Treat both files as secrets; back them up only through the encrypted backup flow. If you enable cron-job.org IP restrictions, commands from non-allowlisted machines can fail with HTTP 403.

Create and use Cloudflare profiles:

Use Cloudflare browser auth when you do not want to type the account email. Mainframe runs Wrangler with isolated XDG config/cache paths but leaves the normal Windows browser profile environment alone, so `wrangler login --browser true` opens your default browser profile. After auth, it detects the email from `wrangler whoami --json` and saves that browser auth under the detected email:

```powershell
.\cloudflare-account.ps1 login
.\cloudflare-account.ps1 whoami user@example.com
.\cloudflare-account.ps1 run user@example.com --version
.\cloudflare-account.ps1 run --version
```

For Cloudflare API calls and exports, create a Cloudflare API token from the Cloudflare dashboard, then save it once. The token must be able to read user details so mainframe can detect the email:

```powershell
.\cloudflare-account.ps1 token-add
.\cloudflare-account.ps1 use user@example.com
.\cloudflare-account.ps1 verify user@example.com
.\cloudflare-account.ps1 accounts user@example.com
.\cloudflare-account.ps1 zones user@example.com
```

Inspect DNS records or run raw Cloudflare API calls:

```powershell
.\cloudflare-account.ps1 dns user@example.com ZONE_ID
.\cloudflare-account.ps1 api user@example.com GET /zones
```

If Wrangler is installed, run it through the selected profile. This works with either saved API-token profiles or saved Wrangler browser-auth profiles:

```powershell
.\cloudflare-account.ps1 run user@example.com --version
.\cloudflare-account.ps1 run --version
.\cloudflare-account.ps1 run user@example.com deploy
```

Running `login` detects the Cloudflare account email through Wrangler browser auth and saves a profile-local Wrangler state folder, so multiple Cloudflare accounts can coexist without relying on Wrangler's global last-login state. Running `token-add` detects the Cloudflare account email from token metadata and refuses to save username, account name, account ID, or manual label fallbacks. Some restricted tokens cannot reveal the email; use `login` for Wrangler commands, or create a token that can read the user profile for API/export commands. Some Wrangler commands still need an `account_id` in the project config, or token scopes that allow account lookups. Use `whoami`, `verify`, `accounts`, and `zones` to check the selected profile first.

Export Cloudflare account, zone, and DNS state into the profile folder:

```powershell
.\cloudflare-account.ps1 export user@example.com
```

Cloudflare tokens are saved as `token.txt` under the account profile folder. Browser-login state is saved under `wrangler-oauth` in that same profile folder. State exports are saved as `cloudflare-export.json` under that same folder by default. Treat these files as secrets; DNS records, hostnames, comments, account IDs, routes, OAuth sessions, and origin details can be sensitive. Cloudflare import is intentionally not automated here because blindly replaying DNS or zone state can break production traffic.

Create and use GitHub profiles:

If you already have a normal machine-level GitHub CLI login, import it into mainframe once:

```powershell
.\github-account.ps1 import-current
.\github-account.ps1 use user@example.com
.\github-account.ps1 whoami user@example.com
.\github-account.ps1 repos user@example.com
.\github-account.ps1 status-all
```

You can also save a GitHub token directly, or run the official `gh` CLI/API through the selected profile:

```powershell
.\github-account.ps1 token-add user@example.com
.\github-account.ps1 run user@example.com repo list --limit 20
.\github-account.ps1 run repo list --limit 20
.\github-account.ps1 api user@example.com GET /user
```

GitHub profiles use profile-local `GH_CONFIG_DIR`. Running `login`, `token-add`, or `import-current` detects the GitHub account email and refuses to save login/username/manual-label fallbacks. `login` and `token-add` accept an optional `<email>` first arg — when provided, mainframe asserts that the detected email matches and refuses to save a profile under a mismatched email (rule 17: keyed by asserted email). Tokens or CLI sessions must expose email, usually through `user:email` access. Portable tokens are saved as `token.txt` and are passed to official GitHub tooling as `GH_TOKEN` and `GITHUB_TOKEN` only while a profile command runs. Treat `token.txt` as a secret; back it up only through the encrypted backup flow.

**Token class preference (rule 27: durable auth).** GitHub OAuth tokens emitted by `gh auth login` start with `gho_` and expire (8 hours to 1 year) or can be revoked by session GC. For durable mainframe auth, generate a classic PAT (`ghp_`) or fine-grained PAT (`github_pat_`) with full scopes and "No expiration" at https://github.com/settings/tokens, then run `github-account.ps1 token-add <email>`. Saving a `gho_` token triggers a non-blocking warning recommending a PAT.

Create and use Notion profiles:

If you already have a Notion token in `NOTION_API_TOKEN`, `NOTION_ACCESS_TOKEN`, or `NOTION_TOKEN`, import it into mainframe once. Mainframe calls Notion `/users/me`, detects the account email when Notion exposes it, and saves the profile under that email:

```powershell
.\notion-account.ps1 import-current
.\notion-account.ps1 use user@example.com
.\notion-account.ps1 me user@example.com
.\notion-account.ps1 users user@example.com
```

You can also save a Notion personal access token or integration token directly, inspect accessible pages/blocks, or run the official `ntn` CLI when installed:

```powershell
.\notion-account.ps1 token-add
.\notion-account.ps1 search user@example.com '{"page_size":10}'
.\notion-account.ps1 page user@example.com PAGE_ID
.\notion-account.ps1 blocks user@example.com BLOCK_ID
.\notion-account.ps1 run user@example.com api v1/users/me
.\notion-account.ps1 run api v1/users/me
.\notion-account.ps1 api user@example.com GET /users/me
```

Notion's script installer is currently macOS/Linux only and the `ntn` package reports native Windows as unsupported on this machine, so the API commands are the dependable native Windows path for now. The `run` command is still here for WSL/Linux/macOS or future Windows-compatible `ntn` releases.

When Notion exposes the owner's email from `/users/me`, `token-add` and `import-current` auto-detect it. If a restricted token cannot reveal an email, the helper fails without saving anything and you can pass the account email explicitly, for example `.\notion-account.ps1 token-add user@example.com`. Notion profiles use profile-local `NOTION_HOME` for CLI config and pass saved tokens as `NOTION_API_TOKEN`, `NOTION_TOKEN`, and `NOTION_ACCESS_TOKEN` only while a profile command runs. Treat `token.txt` as a secret; back it up only through the encrypted backup flow.

Create and use Microsoft Graph profiles:

Register or reuse a Microsoft public client app that supports personal Microsoft accounts and set its loopback redirect URI to:

```text
http://127.0.0.1:8595/callback/
```

Then log in with delegated Graph scopes and automate Microsoft surfaces through one email-keyed profile:

```powershell
.\microsoft-account.ps1 login user@outlook.com -ClientId YOUR_PUBLIC_CLIENT_ID
.\microsoft-account.ps1 use user@outlook.com
.\microsoft-account.ps1 me user@outlook.com
.\microsoft-account.ps1 unread user@outlook.com -Since 2026-05-30T12:00:00Z
.\microsoft-account.ps1 messages user@outlook.com -Folder inbox -Unread -Top 20
.\microsoft-account.ps1 run user@outlook.com GET /me/drive
.\microsoft-account.ps1 run user@outlook.com GET /me/events?`$top=10
.\microsoft-account.ps1 run user@outlook.com POST /me/sendMail '{"message":{"subject":"Test","body":{"contentType":"Text","content":"Hello"},"toRecipients":[{"emailAddress":{"address":"person@example.com"}}]},"saveToSentItems":true}'
```

`microsoft-account.ps1` uses Microsoft Graph directly instead of the broken local `m365` CLI. The helper defaults to the `consumers` tenant for personal Outlook/Hotmail/Live accounts and asks for broad delegated scopes by default: `openid profile offline_access User.Read Mail.ReadWrite Mail.Send MailboxSettings.ReadWrite Calendars.ReadWrite Contacts.ReadWrite Files.ReadWrite.All Tasks.ReadWrite Notes.ReadWrite ShortNotes.ReadWrite`. It calls Graph `/me`, saves the profile under the detected email only, rejects account mismatches, stores `refresh-token.txt` and `access-token.txt` under `%APPDATA%\mainframe\accounts\microsoft\<email>`, and never prints token values from `status` or `env`. Generic Graph `run`/`api` support `GET`, `POST`, `PATCH`, `PUT`, and `DELETE`, so only run write/delete calls intentionally. `outlook-account.ps1` remains as a thin wrapper for existing mail automation commands.

Create and use Hugging Face profiles:

If you already have a normal machine-level Hugging Face login, import it into mainframe once. Mainframe detects the account email after auth and uses that as the profile name:

```powershell
.\hf-account.ps1 import-current
.\hf-account.ps1 use user@example.com
.\hf-account.ps1 whoami user@example.com
.\hf-account.ps1 run user@example.com models list --author your-hf-account --limit 10
.\hf-account.ps1 run models list --author your-hf-account --limit 10
```

You can also save a Hugging Face user access token directly:

```powershell
.\hf-account.ps1 token-add
.\hf-account.ps1 run user@example.com auth whoami --format json
.\hf-account.ps1 run user@example.com repos create your-hf-account/private-dataset --type dataset --private
```

Hugging Face profiles use profile-local `HF_HOME`, `HF_TOKEN_PATH`, and `HF_STORED_TOKENS_PATH`. `login`, `token-add`, and `import-current` always detect the account email after auth and save the profile under that email. If the email cannot be detected, mainframe fails instead of saving a fallback profile. Portable tokens are also saved as `token.txt` under the account profile folder so the encrypted backup flow can carry them across machines. Treat `token.txt`, `token`, and `stored_tokens` as secrets.

Create and use Reddit Devvit profiles:

Devvit's official CLI stores the current auth token at `%USERPROFILE%\.devvit\token`. This helper keeps per-profile copies under mainframe, then installs the selected token before running `devvit` commands.

```powershell
.\devvit-account.ps1 login user@example.com --copy-paste
.\devvit-account.ps1 list
.\devvit-account.ps1 whoami user@example.com
.\devvit-account.ps1 apps user@example.com
.\devvit-account.ps1 installs user@example.com mySubreddit
.\devvit-account.ps1 run user@example.com upload
.\devvit-account.ps1 run upload
```

If you already logged in with plain `npx devvit login`, import the current token without opening a new browser auth flow:

```powershell
.\devvit-account.ps1 import-current user@example.com
```

Devvit exposes Reddit usernames more naturally than account emails, so mainframe requires the email explicitly and rejects Reddit username/manual-label profile names.

Create and use Reddit API OAuth profiles:

This is the path for posting as your own Reddit account. Create an installed app at https://www.reddit.com/prefs/apps and set its redirect URI to:

```text
http://127.0.0.1:8585/callback/
```

Then log in and post with dry-run first:

```powershell
.\reddit-account.ps1 login user@example.com -ClientId YOUR_CLIENT_ID
.\reddit-account.ps1 whoami user@example.com
.\reddit-account.ps1 run GET /api/v1/me
.\reddit-post.ps1 submit user@example.com r/test "Test title" -Text "Test body" -DryRun
.\reddit-post.ps1 submit user@example.com r/test "Test title" -Text "Test body" -ConfirmPost
```

Reddit OAuth exposes Reddit usernames more naturally than account emails, so mainframe requires the email explicitly and rejects Reddit username/manual-label profile names.

Create and use Google Cloud CLI profiles:

```powershell
.\gcloud-account.ps1 import-current
.\gcloud-account.ps1 use user@example.com
.\gcloud-account.ps1 whoami user@example.com
.\gcloud-account.ps1 status user@example.com
.\gcloud-account.ps1 projects user@example.com
.\gcloud-account.ps1 run user@example.com config list
.\gcloud-account.ps1 run config list
.\gcloud-account.ps1 run user@example.com services enable firebase.googleapis.com --project my-project
```

`gcloud-account.ps1` stores each profile as a normal Google Cloud SDK config directory under `%APPDATA%\mainframe\accounts\gcloud\<email>` and selects it with `CLOUDSDK_CONFIG` only while a command runs. `import-current` copies the current default SDK config into an email-keyed profile, excluding logs. `login` runs `gcloud auth login` inside an isolated profile and refuses to save a project name or label fallback if it cannot detect the account email.

Create and use Firebase CLI profiles:

```powershell
.\firebase-account.ps1 import-current
.\firebase-account.ps1 use user@example.com
.\firebase-account.ps1 whoami user@example.com
.\firebase-account.ps1 status user@example.com
.\firebase-account.ps1 projects user@example.com
.\firebase-account.ps1 run user@example.com init auth
.\firebase-account.ps1 run projects:list
.\firebase-account.ps1 run user@example.com deploy --only auth
```

`firebase-account.ps1` stores each Firebase CLI configstore under `%APPDATA%\mainframe\accounts\firebase\<email>` and selects it with `XDG_CONFIG_HOME` only while a command runs. `import-current` copies the current `firebase-tools.json` into an email-keyed profile. `login` runs `firebase login` inside an isolated profile and refuses to save a project name or label fallback if it cannot detect the account email.

Create and use Google Workspace CLI profiles:

```powershell
.\gws-account.ps1 login user@example.com --services gmail,drive,sheets
.\gws-account.ps1 use user@example.com
.\gws-account.ps1 whoami user@example.com
.\gws-account.ps1 status user@example.com
.\gws-account.ps1 run user@example.com gmail users messages list --params '{"userId":"me"}'
.\gws-account.ps1 run auth status
.\gws-account.ps1 run user@example.com drive files list --params '{"pageSize":10}'
```

Create and use a Search Console-capable Google profile:

```powershell
.\gws-account.ps1 login user@example.com --scopes https://www.googleapis.com/auth/webmasters,https://www.googleapis.com/auth/siteverification
.\gws-account.ps1 gsc user@example.com sites
.\gws-account.ps1 gsc user@example.com add-site https://www.example.com/
.\gws-account.ps1 gsc user@example.com sitemaps sc-domain:example.com
.\gws-account.ps1 gsc user@example.com submit-sitemap sc-domain:example.com https://example.com/sitemap.xml
.\gws-account.ps1 gsc user@example.com inspect-url https://example.com/news/story sc-domain:example.com
.\gws-account.ps1 gsc user@example.com analytics sc-domain:example.com 28 query,page
.\gws-account.ps1 gsc user@example.com verification-token https://example.com/ META SITE
.\gws-account.ps1 gsc user@example.com verify-site https://example.com/ META SITE
.\gws-account.ps1 gsc user@example.com scopes
```

Back these profiles up with the encrypted secrets flow:

```powershell
.\backup.ps1
.\restore.ps1 -IncludeSecrets
```

The encrypted secrets flow also carries user-managed Agent skills from `%USERPROFILE%\.agents\skills`. Codex was uninstalled 2026-08-15 (scoop) and its config removed from this manifest, so `%USERPROFILE%\.codex` is no longer backed up.

Windsurf rule/memory Markdown is carried as part of its natural app data bucket: `%USERPROFILE%\.codeium\windsurf`. This keeps app-specific rules with the app state instead of treating them as cross-tool Agent skills.

The encrypted secrets flow carries `%USERPROFILE%\.gitconfig` for Git identity/config symmetry. It intentionally does not back up `%USERPROFILE%\.git-credentials`; use the dedicated GitHub/Hugging Face profile helpers instead of preserving raw Git credential storage.

## Restore

Extract `mainframe-backup.zip` on the new machine, then double-click `restore.cmd` or run:

```powershell
.\restore.ps1
```

The zip is self-contained: it includes `restore.cmd`, `restore.ps1`, `restore-secrets.ps1`, all backup data, and embedded secrets. No other files are needed.

Run restore from an Administrator PowerShell if `native-apps.json` is present, because service-style native apps need elevation.

Use exact pinned versions from the snapshot instead of latest:

```powershell
.\restore.ps1 -Pinned
```

Skip native app install steps:

```powershell
.\restore.ps1 -SkipNativeApps
```

Restore apps plus embedded secrets (enabled by default):

```powershell
.\restore.ps1
```

Skip secrets restore:

```powershell
.\restore.ps1 -ExcludeSecrets
```

You can also restore from a standalone `tool-secrets.zip`:

```powershell
.\restore-secrets.ps1
```

## Safety

Do not publish `scoop-persist.zip`, `native-persist.zip`, `native-installers`, or `mainframe-backup.zip` in a public repository. They can contain API tokens, databases, editor sessions, machine-specific config, remote access identity, Git identity/config, Windsurf local state, URLs with embedded secrets, request headers, request bodies, account IDs, origin details, DNS records, private Agent skill prompts/scripts, or other private data.

The private artifacts are ignored by Git on purpose. Store them in a private release, encrypted backup, external drive, or private file vault.

`mainframe-backup.zip` uses standard zip compression. Treat it as sensitive: anyone with the file can restore those CLI sessions.

## Notes

Plain `scoop import scoopfile.json` is useful, but it does not restore `$SCOOP\persist`. It also installs normal bucket apps from bucket manifests, which can move forward over time. `mainframe` restores from bucket manifests by default. Pass `-Pinned` to restore exact `bucket/app@version` snapshots instead.

To support another tool later, add its natural config/auth path to `tool-secrets.manifest.json`, then run `.\backup.ps1` again.

## Contributors

<a href="https://github.com/FahadBinHussain/mainframe/graphs/contributors">
  <img src="https://contrib.rocks/image?repo=FahadBinHussain/mainframe" alt="Contributors" />
</a>


