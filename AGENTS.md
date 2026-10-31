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
- **invoking the helpers on this box (2026-10-10)**: the default powershell execution policy blocks `& <helper>.ps1 ...` with `UnauthorizedAccess` — call them as `pwsh -NoProfile -ExecutionPolicy Bypass -File <repo>\<tool>-account.ps1 ...` instead. `run` takes the target tool's raw subcommand args with the binary name OMITTED and an optional `<email>` first: `<helper> run auth status` / `<helper> run <email> repo view <owner>/<repo> --json name,visibility` — passing `gh`/`hf`/etc. as the first arg fails loud with `unknown command "gh" for "gh"` (the helper already invokes the binary). also note `gh auth logout` REFUSES to run while `GH_TOKEN` is in the environment (*"first clear the value from the environment"*, exit 1) — to forget a stored host entry run it with only `GH_CONFIG_DIR` set (`Remove-Item Env:GH_TOKEN` first), then re-check via the helper. fixed a stale invalid `default`-style user entry in the github profile's `hosts.yml` this way on 2026-10-10 — it made `run auth status` exit 1 (*"X Failed to log in ... The token in default is invalid"*) while the GH_TOKEN profile was fine all along. **and run `account-contract.ps1` under pwsh, never `powershell`**: under 5.1 it aborts on `agent-browser-account.ps1` with *"17 error(s)"* (first: `Unexpected token 'usually'`) because these helpers use PS7 syntax, so the alphabetically-earlier file dies before minimax is ever reached and the whole run is meaningless; `[Parser]::ParseFile` agrees — 0 errors under pwsh 7.6, 17 under 5.1.
- **secrets are vault-native (2026-08-22)**: api keys / tokens live in the Bitwarden vault as LOGIN items named by the bare platform domain (e.g. `console.neon.tech`, `vercel.com`, `dash.cloudflare.com`, `www.notion.so`, `uptimerobot.com`, `github.com - <handle>`), with the secret value in the item's notes under a platform header (e.g. `[api keys]`, `[tokens]`, `[API Tokens]`, `User Access Tokens`, `Access Tokens`, `[token]`, `[api key]`, `[refresh token]`, `Auth keys`) followed by the value. helpers read/write them via the shared module `vault-secret.psm1` (`Read-VaultSecret` / `Write-VaultSecretToExisting`). **no secrets are stored in the profile dir anymore** — `%APPDATA%\mainframe\accounts\<tool>\<email>\` holds only `profile.json`/`current.json` metadata and tool CLI config state (render cli.yaml, cloudflare account-id, notion workspace-id, wrangler oauth state). unlock the vault first (`automata-private\bitwarden.com\unlock.ps1` writes `%APPDATA%\mainframe\accounts\bitwarden\session.key`, or set `$env:BW_SESSION`); if locked, helpers throw a clear "unlock first" message. token format per tool (used as the vault-value regex): neon `napi_`, supabase `sbp_v0_`, vercel `vcp_`, hf `hf_`, render `rnd_`, cloudflare `cfut_`, github `ghp_`/`github_pat_`, notion `ntn_`/`secret_`, uptimerobot `u<digits>-<hex>`, cron-job.org base64, tailscale `tskey-auth-`, microsoft `[A-Za-z0-9._$*!-]{50,}` (refresh token). some vault items are keyed by github handle or a different email than the profile — the lookup falls back to matching the profile email line in the item notes. **naming rule (2026-10)**: the item name is the bare domain only. two accounts on one domain are told apart by `login.username`/URI, never by a name suffix — the old `[2]` bracket suffix and ` - <user>` suffix are gone (0 bracketed items in the vault as of 2026-10-03). `github.com - <handle>` is the sole exception, kept because `publish-backup.ps1` and `github-account.ps1` match that pattern.
- **github: a bare-handle `login.username` makes a valid token look missing (2026-10-06)**: `Find-VaultItemByEmail` matches `login.username == profile email` first, then falls back to a notes line equal to the email. a `github.com - <handle>` item with `login.username = <handle>` satisfies neither, so `Read-ProfileToken` returns null — `status-all` prints `HasToken=False / TokenStatus=missing` and `run <email> gh ...` fails with *"populate the GH_TOKEN environment variable"* (exit 4) — while the `ghp_` in the notes is perfectly valid. **diagnose first**: read the item and probe the token directly (`Authorization: Bearer <token>` against `api.github.com/user`, check `x-oauth-scopes`) before believing it expired. **fix**: set `login.username` to the profile email. bw 2026.5.0 has no `bw item edit` command and no `--username` flag — use `bw edit item <id> <base64-of-full-item-json>` (get the item, mutate `login.username`, re-encode; posting the whole item back is the only safe form). same class of bug as the huggingface trap below.
- **vault cache (2026-09-01)**: `vault-secret.psm1` `Get-VaultItems` now caches `bw list items` per session so the vault is queried at most once per process. Write operations (Update-VaultItemNotes, New-VaultItem, Write-VaultSecretToExisting) invalidate the cache. Call `Clear-VaultItemsCache` to force a re-read. This fixes `status-all` timeout (was ~20× `bw list items` per profile, now 1×) and speeds up every helper that iterates profiles. **unwrap gotcha (2026-10-08)**: the function returns the whole 1256-item collection as ONE wrapped object — piping it straight into `Where-Object` runs the predicate ONCE against the array (member-enumerated `.name` contains the needle → truthy → everything passes), so a naive filter silently selects ALL items; a write loop using that pattern clobbered 10 unrelated items' `DATABASE_URL` before being caught (all 10 restored same day from local clones + `vercel env pull`). ALWAYS unwrap first — `$items = @(@(Get-VaultItems)[0])` — and assert the filtered match count is what you expect (usually 1) BEFORE any write.
- **`Read-VaultSecret` needs `-ValueRegex` or it silently returns null (2026-10-08)**: `Get-SecretFromNotes` returns null when `ValueRegex` is blank (no default), so `Read-VaultSecret -NamePattern 'github.com - *'` — no `-ValueRegex`, no `-Email` — always comes back null and reads like "vault broken / token missing" when it is a call-shape error. `-Email` also matters: `Find-VaultItemByEmail` with an empty email falls back to matching a BLANK line in the notes, so item selection becomes non-deterministic. for a token read that cannot go wrong use the `boot.ps1` recipe: `bw list items --search 'github.com' --raw` → exact `name -eq 'github.com - <owner>'` item → notes regex `(gh[pousr]_[A-Za-z0-9_]{30,})`; in a fresh shell set `$env:BW_SESSION` from `%APPDATA%\mainframe\accounts\bitwarden\session.key` first (or run via the module, which reads that file itself).
- before using a service, check the active account first (`status-all`/`current`); if the task targets a specific project/repo/space, verify which account owns it and switch before proceeding.

## gws: invalid_client is a stale client secret, not a dead session (fixed 2026-10-11)

helper: `<repo>\gws-account.ps1` (google workspace cli `@googleworkspace/cli`, native `gws.exe`). profiles at `%APPDATA%\mainframe\accounts\gws\<email>\`. this is the **gmail send route** — `--scopes` defaults to the full set including `https://www.googleapis.com/auth/gmail.modify` (which covers send).

```powershell
# send — userId is a REQUIRED path param; omitting it fails loud with
#   "Required path parameter userId is missing. Provide it via --params" (400, exit 3)
pwsh -NoProfile -ExecutionPolicy Bypass -File <repo>\gws-account.ps1 run <email> gmail users messages send --params '{"userId":"me"}' --json '{"raw":"<base64url rfc2822>"}'
pwsh -NoProfile -ExecutionPolicy Bypass -File <repo>\gws-account.ps1 run <email> gmail users messages list --params '{"userId":"me","maxResults":1}'
pwsh -NoProfile -ExecutionPolicy Bypass -File <repo>\gws-account.ps1 run <email> gmail users messages get   --params '{"userId":"me","id":"<id>","format":"full"}'
```

**every** `gmail users ...` call needs `--params '{"userId":"me"}'`, not just `get`/`list`. the error names the missing param precisely, so read it — do not re-derive auth or scope from a 400.

building the `raw` payload (RFC 2822 + base64url). note the subject/body may carry non-ascii (em dashes, quotes): the console mangles their display, so verify the BYTES, not the render. non-ascii in the subject must be RFC 2047 encoded (`=?UTF-8?B?<base64>?=`) or the header is malformed; the body only needs `Content-Type: text/plain; charset="UTF-8"`:

```powershell
$body = "hi," + "`r`n" + "`r`n" + "line with a " + [char]0x2014 + " em dash" + "`r`n" + "`r`n" + "thanks"
$subjEnc = '=?UTF-8?B?' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($subject)) + '?='
$msg = "To: $to`r`nSubject: $subjEnc`r`nMIME-Version: 1.0`r`nContent-Type: text/plain; charset=`"UTF-8`"`r`nContent-Transfer-Encoding: 8bit`r`n`r`n$body"   # CRLF everywhere
$rawUrl = ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($msg))).TrimEnd('=').Replace('+','-').Replace('/','_')
```

verify before trusting a screenshot of the message: re-decode the base64url and assert `$msg.Contains([char]0x2014)` — the terminal prints `-` for `—`, so a message that LOOKS wrong can be right and vice versa. confirm delivery by `get ... "format":"full"` and reading `payload.headers` (`To`/`From`/`Subject`); note `--params '{"metadataHeaders":"To,Subject"}'` returns an EMPTY headers array, so `format: full` is the one that actually works.

### the bug

every `run` failed with `invalid_client: The provided client secret is invalid` (401) while the refresh token was perfectly valid. the instinct is to re-login (re-consent in the browser) — that is the WRONG fix and it does not help, because the client secret is what is broken, not the session. it reads exactly like "my session expired, allow again".

### why patching `client_secret.json` does nothing

gws reads the client secret out of **`credentials.enc`**, not `client_secret.json`. the profile dir has both, and only the encrypted one is consulted when it carries a `client_secret` field (all of them do). editing the json is a silent no-op — the error stays byte-identical, which makes it look like the secret itself is dead upstream.

### the real secret lives in the youtube profile

the same google oauth client is used by the youtube scripts (client id is not repo material — read it out of the profile), which store the secret DPAPI-encrypted at `%APPDATA%\mainframe\accounts\youtube\client.dpapi`. that copy is valid; the gws copies were a stale rotation of the same client. prove it before touching anything — mint with each secret and see which one google accepts:

```powershell
$body = @{ client_id='<id>'; client_secret=<secret>; refresh_token=<rt>; grant_type='refresh_token' }
Invoke-RestMethod -Uri 'https://oauth2.googleapis.com/token' -Method Post -Body $body -ContentType 'application/x-www-form-urlencoded'
```

**diagnose first, never assume**: compare the stored secrets by hash before deciding which is stale. two different 35-char secrets for one client id is the signature.

### `credentials.enc` format

`AES-256-GCM`, key = base64 of `.encryption_key` (44 chars → 32 bytes), file layout **12-byte nonce prefix + ciphertext + 16-byte auth tag suffix**. decrypt/re-encrypt recipe that works (backups first — `credentials.enc.bak-<stamp>`):

```powershell
$key=[Convert]::FromBase64String((Get-Content "$dir\.encryption_key" -Raw).Trim())
$enc=[IO.File]::ReadAllBytes("$dir\credentials.enc")
$nonce=[byte[]]::new(12);[Array]::Copy($enc,0,$nonce,0,12)
$ctLen=$enc.Length-12-16; $ct=[byte[]]::new($ctLen);[Array]::Copy($enc,12,$ct,0,$ctLen)
$tag=[byte[]]::new(16);[Array]::Copy($enc,12+$ctLen,$tag,0,16)
$pt=[byte[]]::new($ctLen); [System.Security.Cryptography.AesGcm]::new($key).Decrypt($nonce,$ct,$tag,$pt)
$o=[Text.Encoding]::UTF8.GetString($pt)|ConvertFrom-Json   # client_id / client_secret / refresh_token
# re-encrypt: RANDOMIZE the nonce, never reuse the old one
$newPt=[Text.Encoding]::UTF8.GetBytes(($o|ConvertTo-Json -Compress -Depth 10))
$newNonce=[byte[]]::new(12); [Security.Cryptography.RandomNumberGenerator]::Fill($newNonce)
$newCt=[byte[]]::new($newPt.Length); $newTag=[byte[]]::new(16)
[System.Security.Cryptography.AesGcm]::new($key).Encrypt($newNonce,$newPt,$newCt,$newTag)   # see the arg-order trap
$out=[byte[]]::new(12+$newPt.Length+16)
[Array]::Copy($newNonce,0,$out,0,12); [Array]::Copy($newCt,0,$out,12,$newPt.Length); [Array]::Copy($newTag,0,$out,12+$newPt.Length,16)
[IO.File]::WriteAllBytes("$dir\credentials.enc",$out)
```

- **⚠️ `AesGcm.Encrypt` argument order is `(nonce, plaintext, CIPHERTEXT, tag)`** — ciphertext third, tag fourth. `Decrypt` is `(nonce, ciphertext, tag, plaintext)`. passing tag third on the encrypt side makes .NET compare your plaintext against the 16-byte tag and throw `Plaintext and ciphertext must have the same length` *even when both arrays are the same length* — and the throw happens AFTER the write in a naive loop, so the on-disk file is already corrupt. always round-trip-decrypt the file you just wrote and assert the secret before moving to the next profile.
- keep `client_secret.json` in sync with the same value so any other reader stays consistent; patch **every** gws profile dir at once — a half-repaired set is how this bug hides (one account works, the others look like dead sessions). list them with `<repo>\gws-account.ps1 list`.

### scope checks per account (2026-10-11)

`gmail.modify` is NOT uniform — a profile can be healthy and still be unable to send. as of 2026-10-11 two of the three profiles carried it and one carried only `youtube.force-ssl` + openid/email/profile (fixed by re-consent that day). `credentials.enc` does not store a `scopes` field, so always read the granted set from the **token endpoint response**, not the file — that is the only place the truth lives:

```
POST https://oauth2.googleapis.com/token   (same body as the mint above)
  → the response `scope` field is the authoritative granted set
```

a missing scope is the one thing that genuinely requires `login <email>` (a browser consent click) — nothing else about a broken profile does. run it detached — `gws auth login` blocks on the loopback callback and will hang an agent shell for the full timeout:

```powershell
Start-Process pwsh -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','<repo>\gws-account.ps1','login','<email>' -RedirectStandardOutput 'C:\tmp\gws-login-out.txt' -RedirectStandardError 'C:\tmp\gws-login-err.txt' -WindowStyle Hidden
```

the auth url is printed on **stderr** with `redirect_uri=http://localhost:<port>`; if no browser tab appeared, extract it from the err file and `Start-Process` it by hand. completion signal = the `gws.exe` process named `auth login` exits and stdout prints `"status": "success"` with the scope list.

### refresh tokens are permanent here — do not re-consent preventively

google expires refresh tokens after 7 days **only** for apps whose oauth consent screen is in *testing* status. one of these profiles was minted **2026-05-18** and still minted a working access token on 2026-10-11 (146 days of no re-auth) → this client's consent screen is **published**, so tokens do not age out. they only die if unused for 6 months or manually revoked. `gws auth login` hardcodes `prompt=select_account+consent`, so a manual `login` always shows the allow screen — that is cosmetic to the login command only; `run` never prompts.

### the helper itself was the blocker twice over, not google (fixed 2026-10-16)

two faults stacked, and both read like auth from the outside:

1. `Get-GwsCommand` used to return `Get-Command gws` verbatim, and PATH resolves the bare
   extensionless pnpm posix shim (`scoop\apps\pnpm\current\bin\gws`, a `#!/bin/sh` file) before
   anything else. pwsh cannot execute a document, so the call produced NO output and an EMPTY
   `$LASTEXITCODE`: `throw "... failed with exit code "` with nothing after it is that signature,
   never a google error. those bare shims are now `*.posix-only-shim.bak` (the same rename the
   vercel/pnpm gotcha below prescribes) and `837f70a` added the extensionless-match guard.
2. that commit probed `gws.cmd` first, which then hit the cmd requoting bug: pwsh hands the
   argument line back through cmd.exe, which strips the inner quotes off a JSON `--params` value,
   so every call came back `error[validation]: Invalid --params JSON: key must be a string at
   line 1 column 2` (exit **3**) while the identical args through `gws.ps1` return exit 0.
   `Get-GwsCommand` now probes `.ps1` first - verified 2026-10-16 on gmail `users.messages.list`
   and drive `files.list`, both exit 0.

read the exit code before blaming auth: **empty** = posix shim, **3** = arg quoting, **2** = dead
refresh token, **403** = project permission, **401 invalid_client** = the stale-secret bug above.

### status re-check 2026-10-16: the client is alive, every fault is per-account

`gws auth status` on all three profiles: `credential_source client_secret.json`, `encryption_valid true`, `client_config_exists true`, same
client id and same quota project across the three (the values live in each profile's
`credentials.enc` and are not repo material). there is **no `invalid_client` anywhere** - the
2026-10-11 secret patch is still holding, so do not mint a new oauth client for this.

- `<primary profile>` (whatever `gws-account.ps1 current` prints, `IsActive True`): healthy. gmail
  `users.messages.list` and drive `files.list` both exit 0, `token_valid true`, 16 scopes including
  `drive`.
- `<institution profile>` (the work/school account): every call, gmail AND drive, dies 403
  `Caller does not have required permission to use project <quota project id> ... roles/serviceusage.serviceUsageConsumer`.
  the token side is fine (`token_valid true`, refresh works, `token_cache.json` rewritten
  2026-10-16) - that account is simply not a member of the quota project. fix is an IAM grant by
  whoever owns the project (the console link is in the error text), not a re-login.
- `<secondary profile>` (`IsActive False`): `401 invalid_grant: Token has been expired or
  revoked`, `token_valid false`, refresh token present but dead (last good cache 2026-10-15 20:57).
  this is the one case where the detached `login <email>` recipe above is the real fix; the
  consent screen is published, so it should not recur once re-minted.

### a re-login can land on the WRONG account - always verify the identity (2026-10-19)

the dead secondary profile above was re-minted 2026-10-19 06:34, but the consent flow completed as
a DIFFERENT google account the user owns. `gws auth login` hardcodes `prompt=select_account`, so
with several google sessions in Edge the chooser defaults to the last-active account and gws writes
whatever was picked into that profile's `credentials.enc` without ever comparing it to the profile
dir name. nothing errors: the profile looks healthy, mints fine, and simply serves another mailbox.

- **verify with the API, never from the profile name or `auth status`.** `gws auth status` reports
  `token_valid true` for a wrong-account token. the only truth is the identity endpoint:

  ```powershell
  pwsh -NoProfile -ExecutionPolicy Bypass -File <repo>\gws-account.ps1 run <email> gmail users getProfile --params '{"userId":"me"}'
  # -> {"emailAddress":"...","messagesTotal":N}   emailAddress MUST equal <email>
  ```

- **`gws-account.ps1 login <email>` cannot pre-select the account** - it builds and `Start-Process`es
  the auth URL itself, so there is nowhere to inject a hint. for a wrong-account repair, run the raw
  command with the helper's env and open the URL yourself:

  ```powershell
  $env:GOOGLE_WORKSPACE_CLI_CONFIG_DIR = "$env:APPDATA\mainframe\accounts\gws\<email>"
  $env:GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND = 'file'
  gws auth login --scopes (<same list as $DefaultGwsLoginScopes> -join ',') 2>&1 |
    ForEach-Object { $l=[string]$_; if ($l -match '^\s*(https://accounts\.google\.com/\S+)') { Start-Process ($matches[1] + '&login_hint=<url-encoded email>') } }
  ```

  `login_hint` pre-selects the account in the chooser (it does not skip consent). keep the process
  running - it owns the `localhost:<port>` loopback callback; success prints
  `"account": "<email>"` + the granted scope list and exits 0.

- **the "Google hasn't verified this app" screen names the APP OWNER, not the account signing in.**
  the red line `(...gmail.com) verifies this app with Google` is the GCP project owner contact of the
  shared oauth client - it appears on every consent flow and says nothing about which account is
  being granted. clicking `Advanced` -> `Go to ... (unsafe)` is expected for this client.
- **back up `credentials.enc` before re-login** and delete the consumer caches afterwards. the inbox
  keeps its own mint at `<profile>\inbox-token.json` plus `token_cache.json`; both outlive a re-login
  and will keep serving the OLD mailbox until deleted. `profile.json`/`current.json` `updatedAt` is
  written by the helper's login, so a hand-run consent leaves it stale - bump it or `status-all` lies.

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

8. **count projects across all accounts (or one) — REST, no neonctl**
   ```
   <repo>\neon-account.ps1 projects-count
   <repo>\neon-account.ps1 projects-count <email>
   ```
   lists each profile with its project count (org-scoped keys auto-detected via
   `GET /api/v2/users/me/organizations` + `GET /api/v2/projects?org_id=...`), then prints
   the accounts with 0 projects. added 2026-09-01 to replace the manual per-account
   REST dance when answering "which neon account has 0 projects".

### notes
- personal projects = no `--org-id` flag
- org projects = `--org-id` required
- if `projects list` returns empty, check orgs first
- the helper supports json output for programmatic parsing: add `--output json --no-color --no-analytics`
- api key auth (`--api-key`) is preferred over browser oauth for automation
- the `neon-account.ps1` helper preserves the api key per profile and injects it into `neonctl` commands

## neon: bulk scripts (moved to automata-private 2026-10-08)

**2026-10-08: `neon-hours-table.ps1` + `neon-projects-table.ps1` moved to
`automata-private\neon.com\`** (mainframe -> automata merge) - edit them THERE,
not here; this repo no longer has a copy (both now import `vault-secret.psm1`
by its mainframe absolute path, uptimerobot-account.ps1 style). everything
below still describes the behavior.

two helper scripts (now in `automata-private\neon.com\`) iterate every mainframe neon profile automatically (no need to pass an email):

- `<repo>\..\automata-private\neon.com\neon-hours-table.ps1` — per-project compute (CU-hours) remaining table across all accounts, against the Free plan quota (100 CU-hours/project/month). the quickest "how much neon is left" check.
- `<repo>\..\automata-private\neon.com\neon-projects-table.ps1` — prints every project across all accounts (personal + per-org), with org names.
- `neon-hours-table.ps1 -Json` returns the same sorted project records as JSON for scheduled consumers (e.g. a CU-hour warning notifier).

### run
```
<repo>\..\automata-private\neon.com\neon-hours-table.ps1
<repo>\..\automata-private\neon.com\neon-projects-table.ps1
```

### ⚠️ gotcha: vault migration left the bulk scripts file-blind (fixed 2026-09-13)
both `neon-hours-table.ps1` and `neon-projects-table.ps1` read api keys from
`<profile>\api-key.txt`, but the 2026-08-22 vault migration deleted those files (keys now
live in Bitwarden item `console.neon.tech` under `[api keys]`, regex `napi_`).
result: the scripts skipped EVERY account and printed `No Neon projects found.` — looked
like an outage, was a stale read path. fixed: both now `Import-Module vault-secret.psm1` and
`Read-VaultSecret -Email <profile-email> -NamePattern 'console.neon.tech*' -ValueRegex
'napi_[A-Za-z0-9]+'` per profile (same pattern as `vercel-usage-table.ps1`); profiles
without a vault entry are skipped. when the table prints zero rows, check the read path is
vault-native BEFORE assuming the accounts are empty. `render-services-table.ps1` was also
updated (2026-10-05) to read via `Read-VaultSecret -NamePattern '*render.com*' -ValueRegex 'rnd_[A-Za-z0-9]+'`.

**2026-10-18: `render-services-table.ps1` moved to `automata-private\render.com\`**
(mainframe -> automata merge) - edit it THERE; this repo no longer has a copy
(it imports `vault-secret.psm1` by its mainframe absolute path, uptimerobot-account.ps1
style, like the neon/vercel/supabase tables). the render bulk tooling (this table +
`render-quota.ps1`) now all lives under `automata-private\render.com\`.

### ⚠️ gotcha: `Read-VaultSecret` returns a plain String, not an object (2026-10-02)
`$tok = Read-VaultSecret ...` gives you the secret itself (`System.String`). writing
`$tok.Value` (a natural habit from other `Read-*` helpers) silently yields **empty**, so
`git push "https://x-access-token:$tok.Value@github.com/..."` goes up with no credentials
and GitHub answers `Invalid username or token. Password authentication is not supported`
— which reads like "token expired" when it is actually "you sent nothing". interpolate
`$tok` directly, and if a push ever says *Invalid username or token*, print
`$tok.Length` first before hunting for a stale credential.

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
- **storage metering (v3.2 migration, 2026-10-02)**: Free plan = 0.5 GB (536,870,912 bytes) per project. On `free` v3.2, the org consumption endpoint zeroes the legacy `peak_data_storage` and `data_storage` fields and reports live storage components under `periods[*].v3_metrics`: `root_branch_logical_size`, `root_branch_history_size`, and `child_branch_change_size`. Both `neon-hours-table.ps1` and `lumen-agent` (`resolveNeonStorage`) prefer `peak_data_storage` / `data_storage` when non-zero (v3.1) and otherwise sum those three `v3_metrics` entries directly from the consumption response (no extra per-project detail calls needed; `synthetic_storage_size` on project detail only reflects logical size and omits branch history).
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
**to get a project's DATABASE_URL** (common reason agents are looking at neon in the first place).
⚠️ `neon-account.ps1 run <email> connection-string ...` does NOT work on this box — with the
broken pnpm `neonctl` shim it **hangs indefinitely with zero output** (2026-10-14: 240s, no
stdout/stderr at all, not even a throw), so a `run` that "does nothing" is this, not a dead
network. `current`/`use` still respond instantly (they only touch profile files). use the
REST route below instead. also note `api-key.txt` no longer exists (2026-08-22 vault
migration) — the key comes from the vault:
```powershell
Import-Module "C:\Users\Admin\Downloads\mainframe\vault-secret.psm1" -Force
$key = Read-VaultSecret -Email '<email>' -NamePattern 'console.neon.tech*' -ValueRegex 'napi_[A-Za-z0-9]+'
$headers = @{ 'Authorization' = "Bearer $key"; 'Accept' = 'application/json' }
$projectId = '<project-id>'
$branchId  = (Invoke-RestMethod -Uri "https://console.neon.tech/api/v2/projects/$projectId/branches" -Headers $headers).branches | Where-Object { $_.default } | Select-Object -First 1 -ExpandProperty id   # NOT branches[0] — pick the default branch or you audit the wrong DB
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

### ⚠️ TRAP: creating a project returns 400 "org_id is required" even with ?org_id= query param
witnessed 2026-09-01 when provisioning the taskflow db. the create-project endpoint does NOT accept `org_id` as a query parameter (`?org_id=org-...` → 400 "org_id is required"), and a top-level body field also fails. the `org_id` must go INSIDE the `project` body object:
```powershell
$body = @{ project = @{ name='<name>'; region_id='aws-ap-southeast-1'; pg_version=17; org_id='org-<id>' } } | ConvertTo-Json -Depth 3
Invoke-WebRequest -Uri 'https://console.neon.tech/api/v2/projects' -Method Post -Headers $headers -Body $body -ContentType 'application/json' -UseBasicParsing -SkipHttpErrorCheck
```
note: the 201 response DOES include `connection_uris[0].connection_uri` on create (no need to fetch it separately when creating fresh).
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

### gotcha: native stderr aborts restore under Windows PowerShell 5.1
`restore.ps1` sets `$ErrorActionPreference='Stop'`. In PS 5.1, ANY native command stderr line becomes an error record, and under 'Stop' that terminates the whole restore. Commands like `uv tool install` ("already installed"), `reg.exe import` ("The operation completed successfully."), and `git` (divergence hints) all write to stderr and silently killed the restore at those points. The fix is `Invoke-Native` helper (line 134): it runs the command with `$ErrorActionPreference='Continue'` temporarily and `2>&1 | Out-Host` so stderr lines are displayed but don't terminate. Wrap every new native-command call in `Invoke-Native` or the savedEap pattern, NOT bare `& cmd`. Checked call sites as of 2026-08-23: git, reg, go, winget, uv, pip are wrapped; robocopy and scoop/pnpm were empirically safe (their stderr didn't trip). If a future restore step aborts mid-way, check for a bare `& <native>` call and wrap it.

### gotcha: mainframe had drifted back to opencode v1 (fixed 2026-10-07)
three places still said `opencode` (v1) after we moved to **opencode2** (v2), and none of them error - they just quietly do the wrong thing:

1. `scoop-allowed.json` listed `opencode`, not `opencode2`. `backup.ps1` filters the scoop export to the allowlist (`$allowed -contains $_.Name`) and only prints `Filtered to N allowed apps`, so with v2 installed and v1 listed, **the agent was being dropped from every backup** with no warning at all.
2. `restore.ps1` `Install-OpencodePinned` defaulted to `$opencodeSpec = 'opencode'`, matched the scoopfile entry named `opencode`, and its `catch` **fell back silently to `install opencode`** - so a restore installed v1.18.34, which cannot read a v2 config. the fallback is gone: it now throws with the spec that failed (no second method pretending to be the first).
3. `tool-secrets.manifest.json` had no entry for `{UserProfile}\.config\opencode`, which is where v2 keeps `plugins\`, `skills\`, `cli.json`, `opencode.jsonc`, `package.json`. restore would come back with v1 and none of the v2 settings.

also: `restore.ps1` re-applies a local fork patcher (`github.com\anomalyco\opencode\opencode-patcher.ps1`) that rebuilds the **v1** fork for bash pipe hang #44601. running it against a v2 install overwrites v2 with a v1 fork build, so it now checks `scoop\apps\opencode2\current` and skips with a loud warning instead.

v1 and v2 are mutually exclusive (scoop's own notes: uninstall `opencode` before installing `opencode2`), so the allowlist must name exactly one of them. when the agent major version changes again, these four are the places to touch: allowlist, pinned install spec + scoopfile lookup, secrets manifest path, fork patcher guard.

### gotcha: Scoop ignores system 7-Zip unless configured
the bootstrap installs 7-Zip through winget so `boot.ps1` can unpack the restore archives, but Scoop's archive extractor uses its own managed 7zip helper by default and does not use `7z.exe` from `PATH`. installing a `.tgz` package such as `versions/opencode2` before configuring `use_external_7zip` can pass an empty executable path and fail with `Cannot validate argument on parameter 'FilePath'`. `restore.ps1` now verifies the external `7z` command and runs `scoop config use_external_7zip true` before the pinned install.

### gotcha: neonctl is currently broken on windows under pnpm
`neon-account.ps1 run`/`projects-json` still invoke `neonctl` via `& $neon.Source ...`. if neonctl was installed through `pnpm add -g neonctl`, only a `/bin/sh` shell shim is left at `scoop\apps\pnpm\current\bin\neonctl` with no matching `neonctl.cmd`/`neonctl.ps1`, pointing at a `global/.../node_modules/neonctl/dist/cli.js` that may not exist. under pwsh on windows these shims can't run, so the scripts silently fail. sanity-check: if a script reports 0 projects for every account, the neonctl call almost certainly failed.

both `neon-hours-table.ps1` and `neon-projects-table.ps1` were migrated to the rest api (above) and no longer require neonctl. `neon-account.ps1 run`/`projects-json` still use neonctl — to migrate when needed, or fix neonctl: `pnpm add -g neonctl` plus verifying a windows-runnable `neonctl.cmd` exists.

## vercel: bulk scripts (moved to automata-private 2026-10-08)

**2026-10-08: `vercel-usage-table.ps1` moved to `automata-private\vercel.com\`**
(mainframe -> automata merge) - edit it THERE; this repo no longer has a copy
(it imports `vault-secret.psm1` by its mainframe absolute path,
uptimerobot-account.ps1 style). global AGENTS rule 22 was repointed in the same
change. the quota + BLOCKED-workflow sections below still describe it.

- `<repo>\..\automata-private\vercel.com\vercel-usage-table.ps1` — per-account + per-project usage overview across all mainframe vercel profiles. reads tokens from the Bitwarden vault via `Read-VaultSecret` (no `token.txt` files in profile dirs since 2026-08-22 vault migration). reports plan, billing status, `softBlock` flag, projects count, prod deployments in last 30d, BLOCKED projects, runtime (Functions created), last prod deploy, repo, domains. this is the "vercel what's left / who's blocked" check.
- `<repo>\vercel-projects-table.ps1` — older script, prints a simple per-account list of personal + team projects. `vercel-usage-table.ps1` superseded this for usage/limits audits; the script itself no longer exists anywhere (verified 2026-10-08).

### run
```
<repo>\..\automata-private\vercel.com\vercel-usage-table.ps1
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

**fix for the broken CLI (2026-10-06):** `pnpm add -g vercel` reinstalls it in ~20s (62.2.0, shim at `%USERPROFILE%\.pnpm-global\bin\vercel.ps1`, package under `scoop\apps\pnpm\current\global\v11`). verify by artifact + `vercel --version`, not exit code: a stale shim prints `Cannot find module '.../node_modules/vercel/dist/vc.js'` and exits 1. needed whenever `vercel-account.ps1 run ... <cmd>` is used (deploy, `git connect`, `inspect`) — `vercel-usage-table.ps1` never needs the CLI.

**bare posix-only shim in scoop's pnpm bin hangs the CLI (2026-10-15):** `scoop\apps\pnpm\current\bin\vercel` was a 580-byte extensionless `/bin/sh` shim (pnpm 12 puts global bins there) and PATH resolves it BEFORE `%USERPROFILE%\.pnpm-global\bin\vercel.ps1` — `Get-Command vercel` returns the bare file, running it HANGS with zero output, so `vercel-account.ps1 run ... deploy --prod --yes` silently does nothing (no deployment created, empty stdout) while REST subcommands (`api`, `deployments`) keep working through the helper's direct REST path. an EMPTY `run` output is this trap, not auth. fix: `Rename-Item <scoop pnpm bin>\vercel vercel.posix-only-shim.bak` (reversible) so resolution falls through to the real `.ps1`/`.cmd` shims, then `vercel --version` must print before deploying. the same bare-only files existed there for `gws`, `neon`, `neonctl`, `vc` — treat any extensionless file in that bin dir as broken on windows (`Get-ChildItem <dir> | Where-Object { -not $_.Name.Contains('.') }`).

**pnpm global install gotchas (2026-10-06, cost an hour):** the global project (`scoop\apps\pnpm\current\global\v11`) is a single package.json/workspace, so:
- `pnpm add -g <one-pkg>` **replaces the whole dependency set** — every other global CLI's files disappear while its shims stay in `%USERPROFILE%\.pnpm-global\bin`, leaving dead shims that print `Cannot find module '.../global/v11/<hash>/node_modules/<pkg>/...'`.
- `pnpm add -g <pkg> --force` is worse: it relinks into a fresh `global\v11\<hash>` staging dir and rewrites shims to paths that then get purged — at that point *all* global CLIs break at once (this is what killed `agent-browser` mid-session while it was needed for browser work).
- therefore always install/repair the **full set in one command**: `pnpm add -g agent-browser vercel firebase-tools ntn omniroute pinggy`, then verify each with `--version` (`agent-browser`/`vercel`/`vc`/`firebase`/`ntn`/`omniroute`/`pinggy`). `blindspot` (points into `Downloads\blindspot\tools\relay`) and `gws` live elsewhere and are unaffected. never use `--force` here.
- `pinggy` only works after its native addon install script is allowed: `allowBuilds: '@pinggy/pinggy': true` must be in `scoop\persist\pnpm\global\v11\pnpm-workspace.yaml` (pnpm blocks install scripts by default; `@mimo-ai/cli` is the only other allowlisted package), then `pnpm remove -g pinggy` + `pnpm add -g pinggy` so `node-pre-gyp install` downloads `lib/addon.node` from GitHub releases.
- sanity check after any pnpm global command: `pnpm ls -g --depth 0` must list every package you expect - if it shows fewer, the others were just wiped.

**pnpm fixed: upstream bug + frozen scoop user-manifest (2026-10-14)**: the wipe above was pnpm
upstream bug pnpm/pnpm#11587 (v11 shipped global installs as ONE shared dep set, so add/remove of
any package touched all of them), fixed same day by pnpm/pnpm#11588 (each `add -g` gets its own
isolated `global\v11\<hash>\` dir with its own package.json + lockfile). this box stayed buggy
because scoop had installed pnpm from a **user manifest**: `apps\pnpm\<ver>\install.json` holds
`"url": "...\scoop\workspace\pnpm.json"` with no bucket, so `scoop update pnpm` and `scoop status`
compare against that local file - frozen at 11.5.3 since the 2026-06-30 bootstrap - and never
see the bucket. fix: copy `buckets\main\bucket\pnpm.json` over `workspace\pnpm.json`, then
`scoop update pnpm` - now 12.13.0 (persist\global survived, allowBuilds yaml intact).
- `scoop\workspace\*.json` = 16 bootstrap-era local manifests (bitwarden-cli cmake curl deno
  ffmpeg flameshot gcloud gh nodejs-lts parsec pnpm pwsh qbittorrent tor-browser uv vscode).
  for those apps scoop ignores the buckets entirely - that is why they look "up to date" in
  `scoop status` while being weeks behind. refreshing the file is what makes the app updatable.
- pnpm 12 has NO global rebuild (`pnpm rebuild -g` fails: unexpected argument) - to run build
  scripts after allowlisting, remove + re-add the set in one command (rule above still holds).
  newly allowlisted in `persist\pnpm\global\v11\pnpm-workspace.yaml` allowBuilds: `@parcel/watcher`
  `@swc/core` `esbuild` `keytar` `omniroute` `onnxruntime-node` `open-computer-use` `protobufjs`
  (alongside the existing `@pinggy/pinggy` + `@mimo-ai/cli`).
- repaired + verified 2026-10-14: agent-browser 0.39.0, vercel 63.1.2, firebase 15.33.0,
  ntn 0.23.19, omniroute 3.8.51, pinggy 0.6.1, open-computer-use 1.0.0 - `pnpm ls -g --depth 0`
  lists all 7, every shim answers `--version`. isolated dirs mean a future single `add -g` no
  longer wipes the others - keep the one-command habit anyway.

**scoop symmetry: workspace freeze eliminated (2026-10-14)**: `scoop\workspace\*.json` is gone.
conversion for each of the 16 = `scoop uninstall <app>` + `scoop install <bucket>/<app>`
(persist survives, shims rebuild; NEVER `scoop purge` - it deletes persist). an
`apps\<app>\current\install.json` holding `"url"` marks a user-manifest install - bucket
installs write NO install.json at all, so no install.json = symmetric.
- converted same day (12): main = bitwarden-cli cmake curl deno ffmpeg gh pnpm,
  extras = gcloud parsec qbittorrent tor-browser vscode.
- still to convert (4, all blocked by live processes, shown as `Manifest removed` in
  `scoop status` until done): extras/flameshot + main/nodejs-lts pwsh uv. finisher
  (process-guarded, idempotent, also retries the5 running-blocked updates:
  cloudflare-warp cloudflared opencode2 tailscale windows-terminal):
  `powershell -NoProfile -ExecutionPolicy Bypass -File C:\Users\Admin\Downloads\automata-private\scoop\finish-symmetry.ps1`
  - run from cmd or Windows PowerShell, NEVER pwsh - pwsh only converts with zero pwsh
    processes alive, so running it inside pwsh always skips pwsh. rerun until `blocked: none`.
- `scoop export` writes user-manifest installs as `"Source":"<auto-generated>"` (never the
  workspace path - no local path ever ships in a release scoopfile), and restore specs them
  as `app@<version>`, which fails once the bucket moves past that version: until the 4 are
  converted, a fresh restore breaks on exactly those apps.
- scoop output gotcha (bites every script): ERROR + status text rides the INFORMATION stream
  and `$LASTEXITCODE` stays 0 even when a command was blocked or failed - capture with
  `*>&1 | Out-String` and classify by text, never by exit code (the finisher does this).
- bucket git gotchas fixed same day: every `scoop update` printed
  `Need to specify how to reconcile divergent branches` from two personal buckets.
  `buckets\mainframe` was a stale clone still on the pre-public-scrub line (root 2026-05-10
  "Initial scoopcryo restore kit", 157 commits, zero shared commits with the public root
  2026-08-20) - that line is exactly what the rule-5 scrub removed from the remote, so it
  must NEVER be pushed anywhere: preserved as local branch
  `backup/pre-scrub-history-20261014`, then `git reset --hard origin/main` (herdr.json back).
  `buckets\zeldrisho` had 1 legit local doc commit + uncommitted
  `scripts/proton-vpn/service.ps1` WIP: `git pull --rebase --autostash` kept both (now
  [ahead 1]). both clones got `git config pull.rebase false` - a plain rebase-pull refuses
  the dirty tree ("cannot pull with rebase: You have unstaged changes").

**2026-09-01 vault migration:** tokens are no longer stored in `token.txt` files in the profile dir. the script now imports `vault-secret.psm1` and calls `Read-VaultSecret -Email $email -NamePattern 'vercel.com*' -ValueRegex 'vcp_[A-Za-z0-9]+'` per profile. profiles without a vault entry (e.g. the `daffodilresourcehub-8188@vercel` stub) are skipped silently.

rest api flow:
1. get the token from the vault: `Read-VaultSecret -Email $email -NamePattern 'vercel.com*' -ValueRegex 'vcp_[A-Za-z0-9]+'`
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

#### agent-browser exec hang + @e11 quoting fix (2026-09-12)
- **opencode bash hang**: `agent-browser-account.ps1 exec` directly did `& $agentBrowser @fullArgs` in-process. opencode's bash tool waits for pipes to close, so `open`/`snapshot` poll forever (120s timeout). fix: `exec` now detects agent bash (`$env:OPENCODE`/`$env:AGENT`) and routes through `Invoke-AgentBrowserDetachedOutput` (`Start-Process pwsh -WindowStyle Hidden` + temp file poll, 40s). `exec get url` now returns in `0.7s` vs `120s`.
- **VSS kill on exec**: `exec` previously always ran `Sync-EdgeProfileToMainframe` (VSS shadow + robocopy) which `/MIR`-killed any live daemon (the `AGENTS.md` 3-step workflow's already-running browser). fix: `exec` now checks `~/.agent-browser/default.pid` + `Get-Process` — if daemon running, skips VSS sync (`daemon running — skipping VSS sync`) and preserves the session.
- **powershell splat `@e11`**: `click @e11` without quotes is parsed as array splat (`@e11` → variable `e11`), `exec` got `Missing arguments for: click`. fix: `exec` auto-quotes bare `@e\d+` refs (`"'$_'"` in `$cmdArgs` pipeline) so `exec click @e11` and `exec click "@e11"` both work. verified `account-contract.ps1` still `PASS`.
- **`-Extension`/`--extension` ghosts STORE extensions into never-loading loc=8 (2026-09-13)**: loading a real store-installed extension (e.g. Bitwarden, id `jbkfoedolllekgbhcbcoahefnbanhhlh`) via `-Extension <unpacked path>` on a synced-edge spawn does NOT work as intended: agent-browser never appends `--load-extension=` to the `msedge.exe` command line (verified: absent), yet Edge records the entry as `location=8` (kCommandLine) in the copy's `Secure Preferences`. `InstalledLoader` skips kCommandLine entries when the flag isn't present (see "unpacked extensions — the --load-extension bypass" below) → the extension vanishes from EVERY later session, even after dropping `-Extension`, because the loc=8 ghost persists in the copy's prefs and robocopy `/MIR` re-copies it from real Edge prefs only if real Edge itself rewrites the entry. worse: the helper caches the extension list in `mainframe-profile.json` and re-injects `--extension` on later runs with no `-Extension` flag. symptom: "all extensions are there except the one i asked for". fix (verified): `agent-browser close --all`; kill stray agent-browser msedge + node daemon procs; set `extensions: []` in `mainframe-profile.json`; transplant the real Edge `extensions.settings.<id>` object (valid mac, loc=1) into the copy's `Secure Preferences`; relaunch WITHOUT `-Extension` — store extensions from the synced copy load natively (sig repair in edge-cdp-profile-sync keeps them alive). never pass `-Extension` for anything already installed in real Edge.
- **post-open double Edge launch diagnosis (2026-09-20)**: if a synced `agent-browser-account.ps1 run` window appears healthy and then closes/reopens about 10–11 seconds later, this is an agent-browser/helper daemon race, not Edge repairing profile corruption. Reproduction with the active email-keyed profile: two distinct top-level `msedge.exe` processes were observed, each launched by a separate `agent-browser-win32-x64.exe`; no matching Edge crash report or Windows Application Error event existed. The helper's `Sync-EdgeProfileToMainframe` calls `agent-browser close --all`, performs VSS/Robocopy, clears daemon sidecars, and immediately starts `open`; this shutdown/startup transition can leave the shared default namespace in a relaunch state. A direct `agent-browser` launch against the same profile, bypassing the helper sync, launched only once. Do not describe this symptom as Edge self-healing. Installed `agent-browser` was upgraded from `0.34.0` to `0.38.1` on this machine; after closing the old version-mismatched daemon and relaunching, one top-level Edge process remained and the session was reachable. If the symptom returns, check the daemon version and run `agent-browser doctor --json` before changing the Edge profile.
- **Edge 153 interaction hang during Google paste (2026-09-20)**: pasting text into the Google sign-in email field caused the agent-browser window to disappear because Edge itself hung and Windows terminated it. Event Viewer recorded `Application Hang` event 1002 for `msedge.exe` version `153.0.4234.32` at the reproduction time; there was no agent-browser crash report. Microsoft documents a known Edge 153 issue where some web applications become unresponsive during user interaction, and the Stable release notes identify the fix in `153.0.4234.46` (later `.48` was available). When this symptom occurs, check `msedge.exe`'s exact version and update Edge before debugging agent-browser, extensions, or the synced profile. The helper now explicitly launches the installed fixed `153.0.4234.48` executable for agent-browser only; it fails loudly if that executable is missing. Normal system Edge remains unchanged. If neither `.48` nor Edge 152 is available, install a fixed build before retrying the paste workflow.
- **executable pin requires a fresh daemon (2026-09-20)**: agent-browser retains browser launch configuration in its shared daemon. Updating `agent-browser-account.ps1` to point at Edge `.48` does not migrate an already-running default daemon; that daemon can continue launching the old root `msedge.exe` (`153.0.4234.32`). Before validating the pin after a helper change, run `agent-browser close --all`, wait for the old daemon to exit, then launch the helper. Verify the top-level Edge command line contains `Application\153.0.4234.48\msedge.exe`; do not infer the version from the helper source alone.
- **daemon config mismatch = 1-time-use spawn**: after killing/re-patching a session, the FIRST `run`/`exec` often dies with "Daemon version mismatch detected, restarting… A daemon for session 'default' started concurrently with different daemon configuration. Retry the command". this is expected — run the same command once more; the second spawn picks up the new config.

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
**vault-native authkey (2026-09-01)**: the reusable auth key is stored in the
Bitwarden item `console.tailscale.com` notes under the `Auth keys` header (same item
that holds the oauth client secret), keyed by profile email. `key-add` writes the
vault + a legacy `authkey.txt`; `provision` reads the vault (falls back to
authkey.txt); `key-remove` clears both. `tailscaled.state` (machine identity) stays
on disk — that is backup/restore state, not a vault secret.

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
   → saved vault-native to the Bitwarden item `console.tailscale.com` notes under the
   `Auth keys` header (the same item that holds the oauth client secret). a legacy
   `authkey.txt` copy is also written to the profile dir for backward compat, but the
   vault is the source of truth. mainframe `backup.ps1` already snapshots
   `%APPDATA%\mainframe\accounts\` and the vault travels via bitwarden, so the key is
   safe either way. (auth keys max 90-day expiry — rotation only affects NEW joins,
   existing nodes keep working; regenerate + `key-add` once a year, or store a
   non-expiring API access token in the same item and mint one-shot keys via the admin
   API instead.)
2. **on any new pc**: `scoop install tailscale` (service auto-registers) → restore the
   mainframe backup (or copy just that profile dir) →
   `tailscale-account.ps1 provision <email> <hostname>` → joins the tailnet as its OWN
   node (own 100.x IP, `--unattended --auto-update`), no browser, no per-machine key.
   provision reads the auth key from the vault (falls back to the legacy authkey.txt).
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
- **reusable remote script runner**: `automata-private\tailscale.com\remote-run.ps1` wraps the
  scp + ssh + Start-Job/Wait-Job pattern for running a local script on a remote tailnet
  peer from an agent shell. usage: `remote-run.ps1 C:\path\script.ps1 [-Timeout 120]`.
  defaults to the home desktop (`REMOTE_HOST`/`REMOTE_USER`/`TAILSCALE_SSH_KEY_NAME` in
  `tailscale.com\.env.local`). gotchas baked into the script: the remote script always
  lands at the fixed `C:\Users\<user>\AppData\Local\Temp\remote-run-script.ps1` (a space
  in the remote path breaks remote `powershell -File`), the scp target must be ONE
  `user@host:path` argument (a separate path string is misread as a hostname), and a
  timeout kills the lingering ssh process so the remote command can't run away.
- **VPN clients can block direct sockets**: a VPN service can WFP-block ALL non-tunnel
  traffic incl. LAN + tailnet peer dials. for direct-socket work on such a machine:
  stop the VPN client + service, do the work, then restore. the NCF is per-process and NOT
  influenced by service stop alone while the client runs.

## agents.md sync (AgentsMdSync)

**2026-10-02: the script moved to automata-private** (`automata-private\tools\agent-rules-sync\agent-rules-sync.ps1`, part of the mainframe -> automata-private merge) and the `AgentsMdSync` task was repointed there — edit it THERE, not here; this repo no longer has a copy. everything below still describes the behavior:

`agent-rules-sync.ps1` is the logon task `AgentsMdSync`. it watches `~/AGENTS.md` and copies it into each tool's global rules path. grok's copy is a plain file at `~/.grok/rules/AGENTS.md` (no yaml header — grok loads every `*.md` in that directory as instructions and does not strip frontmatter). the running task holds the script in memory, so after editing the script restart `AgentsMdSync` or the new target stays dark until the next logon.

## skills dir nesting guard

`~/.agents/skills` was once copied into itself multiple levels deep
(`skills\skills\skills\...`) by a botched skill install/sync, duplicating ~25 MB and
making the skill loader read stale deep copies. fixed by pruning the chain and adding
a self-healing guard in `agent-rules-sync.ps1` (runs at every logon): if
`~/.agents\skills\skills\skills` (depth >= 2) exists, the whole nested chain is a copy
artifact and gets deleted, keeping only the top-level tree.

**2026-09-02 update: each skill is now a git repo with sparse-checkout.**
All 53 sourced skills under `~/.agents/skills/` are shallow git clones of their upstream
repos, with sparse-checkout set to track only the skill's path within the repo. This
creates a legitimate nested `skills\<name>\` subdirectory inside many skill folders (from
the sparse path like `skills/agent-browser`). `backup.ps1` was updated to exclude `.git`
instead of `skills` when archiving `~/.agents\skills`:
- `/XD .git` replaces the old `/XD skills` — the nested `skills\` dirs now hold real
  git-tracked content and must be included.
- `.git` is excluded (~1.1 GB of fetched history, reproducible from remotes).
- `agent-rules-sync.ps1`'s guard is unaffected — it checks `~/.agents\skills\skills\skills`
  (top-level depth >= 2), not the per-skill nested `skills\` dirs.
- `restore.ps1` restores skills as plain folders (no `.git`). To recover git connectivity:
  re-clone each skill's folder from its known remote URL (sparse-checkout the skill path).
  the per-skill remote URLs are recorded in `git remote -v` inside each folder before
  backup, and in the `skills-changelog.md` report.

## uptimerobot: status page + monitor helper

helper: `<repo>\..\automata-private\uptimerobot.com\uptimerobot-account.ps1` (moved to automata-private, contract PASS). profiles at `%APPDATA%\mainframe\accounts\uptimerobot\<email>\` (api-key.txt).

### v3 is the ONLY API that works for writes
- v2 `/v2/newMonitor` returns HTTP 403 `access_denied: You are not allowed to use some settings with your current plan` on current accounts (all fields, even minimal). do NOT debug v2 - it is broken.
- use v3: `https://api.uptimerobot.com/v3/<path>` with `Authorization: Bearer <api-key>` and camelCase JSON bodies (`friendlyName`, `url`, `type: "http"`, `interval`, `timeout`).
- endpoints: `GET /monitors`, `GET /monitors/:id`, `POST /monitors` (create), `DELETE /monitors/:id`, `POST /monitors/:id/pause`, `POST /monitors/:id/start` (pause/resume - `PATCH ... {status:...}` is rejected with "property status should not exist"), `GET /psps`, `POST /psps`, `PATCH /psps/:id {monitorIds:[...]}`. edit = v3 `PATCH /monitors/:id` with camelCase delta (`friendlyName`, `timeout`, ...) - returns the full updated monitor; v2 `/v2/editMonitor` silently no-ops (stat "ok" but nothing changes - verified 2026-08-14).
- rate limit: FREE = 10 req/min; pace creations (8s sleep worked). 429 bodies carry X-RateLimit-* headers.
- list via v3 `GET /monitors` or v2 `POST /getMonitors` form-encoded `{api_key, format=json}` (v2 works for reads).

### status pages (PSP)
- create monitors under a PSP (public status page) so they aggregate on one page.
- PSPs can be password protected (password set by user, not stored in the repo); the urlKey in the PSP record maps to the public status page URL.

## firebase: account helper + vault on-demand

helper: `<repo>\firebase-account.ps1` (contract PASS). profiles at
`%APPDATA%\mainframe\accounts\firebase\<email>\` selected via `XDG_CONFIG_HOME`;
the real CLI state is `configstore\firebase-tools.json` (the OAuth
`access_token`/`refresh_token`, `expires_in 3599`, scopes
`cloud-platform firebase cloudplatformprojects.readonly`). subcommands: `login`
(reauth via `firebase login --no-localhost`), `use <email>`, `current`, `list`,
`status`/`status-all`, `path`/`env`, `run -- <firebase args>`, `projects`, `apps`,
`sdkconfig`, `whoami`, plus the vault trio `vault-push`/`vault-pull`/`vault-status`/
`vault-status-all`.

- **vault on-demand (2026-09-11, symmetry with vercel/neon)**: the `firebase-tools.json`
  token is stored base64 under a `[firebase-tools.json]` header in the Bitwarden item
  `firebase.google.com - <email>` via `vault-secret.psm1`. `login`/reauth/import-current
  auto-write the vault; `use` auto-syncs from the vault when the local file is missing.
  `vault-push`/`vault-pull`/`vault-status` are the manual edges; `vault-status-all`
  reports synced/missing across profiles. helpers read vault only when the local
  configstore is absent — never silently overwrite a live token.
- **⚠️ the `firebase-tools` OAuth token CANNOT admin-write Identity Toolkit / Service
  Usage / Realtime Database.** Any REST call to `identitytoolkit` (`v2/…/config`,
  `…/identityPlatform:initializeAuth`), `serviceusage` (`services:batchEnable`,
  `…:enable`), or `firebasedatabase` (`CreateDatabaseInstance`) with this bearer returns
  `401 ACCESS_TOKEN_TYPE_UNSUPPORTED` ("Expected OAuth 2 access token, login cookie…").
  `firebase.googleapis.com` GET/PATCH likewise 401s. `gcloud auth login --cred-file`
  rejects the authorized_user JSON ("Only external account or service account …"). **So
  enabling Firebase Auth on a fresh project, publishing the OAuth consent screen, and
  creating the Realtime Database instance must be done in the console — there is no CLI
  /API path with mainframe firebase credentials.** Do not burn time on REST again.
- **free-tier project quota** is the blocker on `projects:create` (`QuotaFailure`,
  ACTIVE + DELETE_REQUESTED count toward it); wait the ~30-day purge or file a
  Cloud Resource Manager quota bump. `DELETE_REQUESTED` projects still count until purge.
- profiles keyed by account email only (mainframe contract); never save a
  project/label/workspace fallback. new project = create under the account that has
  quota, add the other account as Editor if needed (`SOLO_MUST_INVITE_OWNERS` blocks
  inviting a second OWNER on a solo-owner project).

## huggingface: profile token layout (hf-account.ps1)

each `hf` profile dir (`%APPDATA%\mainframe\accounts\hf\<email>\`) can hold several token
artifacts — know which is which before diagnosing `status-all`:

- **vault item `huggingface.co`** (login.username = `<email>`, token in notes under the
  `User Access Tokens` header) — the source of truth; `Read-ProfileToken` reads ONLY this.
- **`token.txt`** — portable copy written by `token-add` / `import-current` (the write was
  added 2026-10-04 — before that the README promised it but the vault migration never wrote
  it). read directly by `hf-spaces-table.ps1` and carried in the encrypted tool-secrets
  backup.
- **`token`** — huggingface_hub's own file (`HF_TOKEN_PATH`), created when `hf auth login`
  runs inside a profile. `State=missing-token` in `status-all` means NEITHER `token.txt`
  nor `token` exists; `TokenStatus` reflects the vault.
- **`stored_tokens`** — hf's sidecar (`HF_STORED_TOKENS_PATH`): token-name line, then
  `hf_token = hf_...`.

**diagnostic trap**: grepping `hf_[A-Za-z0-9]+` in a `stored_tokens` file matches the
`hf_token` FIELD KEY first, not the value — probing that "token" against whoami returns a
bogus 401 and makes healthy profiles look dead. capture the text after `=`.

**fixed 2026-10-04**: `status-all` showed 4/5 profiles `missing-token` plus one account the
helper could not resolve. two causes: `token.txt` was never written (see above), and one
vault item's `login.username` was a bare handle instead of the profile email, so
`Find-VaultItemByEmail` never matched it — the token itself was valid all along. after the
fix every profile has vault username = `<email>`, a `token.txt` matching the vault token,
and a green `whoami`.

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
- **history is a 50-entry window with no paging (2026-10-11)**: `GET /jobs/<id>/history` returns only the newest 50 executions (≈8 h at a 10-min cadence; top-level shape is `{history, predictions}`), so "when did this last fail / how often" cannot be answered from the API. query-param paging is NOT supported - `?page=2`, `?offset=50`, `?start=50`, `?paginationToken=1` all come back HTTP 404, and the helper has no paging edge (`history-item <identifier>` only fetches a single known entry). use `jobs` for the current verdict (`enabled` + `lastStatus` + `lastExecution` + `nextExecution`) and the web dashboard for anything older than the window. reading rule: cron-job.org sends exactly ONE failure notification and then stays silent until the job succeeds again, so an old failure mail next to a green `lastStatus=1` means it recovered - worked example 2026-10-11, the 2026-09-27 `render keep-alive - oangrybird` 403 mail: job `8255425` was `enabled`/`lastStatus=1` with 50/50 OK in-window, i.e. stale, not a live outage.

### vercel: multi-account deploy BLOCKED workaround (TEAM_ACCESS_REQUIRED)

- Hobby/team deploys without a GitHub login connection: avoid paid team-member upgrades and reconnecting GitHub per account.
- detect: deploy shows `readyState: BLOCKED` with `seatBlock.blockCode: TEAM_ACCESS_REQUIRED` (Git author lacks team access). the CLI hides it (an upload blocked this way just sits at `Building…`/`status UNKNOWN`, no build logs) - read the truth from REST: `vercel-account.ps1 api <owner-email> GET '/v6/deployments?projectId=<prj_...>&limit=8&meta=1'` → `readyState: BLOCKED`, `errorMessage: "commit author doesn't have permission…"`, `seatBlock.blockCode`, `attribution.commitMeta` names the offending author.
- surface ALL blocked projects across accounts at once: `<repo>\..\automata-private\vercel.com\vercel-usage-table.ps1` - its BLOCKED-reason section shows the blockCode + commit author per project.
- fix: create a local deployment-alignment commit authored with the target Vercel account email before deploying: `git -c user.email="<target-vercel-email>" -c user.name="<name>" commit --allow-empty -m "deployment alignment"` (empty commit only when there is no real scoped change to commit).
- then redeploy and verify the live URL/domain.
- verified 2026-09-05 (vubon-virtuals/vubon-ecommerce on fahads-projects-c67183fe): the alignment commit alone does NOT clear the block - git-push-triggered deploys stayed BLOCKED even with identical author email/login as a previous READY deploy (Vercel resolves the push to the GitHub identity, which has no seat). what works: after the alignment commit, deploy via CLI from the local linked clone as the owning account (`vercel-account.ps1 run <owner-email> deploy --prod --yes`) - the deploy is attributed to the owner and aliases the custom domain automatically.
- never pay for team-member seat upgrades or reconnect GitHub per account to work around this.
- helper arg quirk (2026-10-16): never insert a literal `--` before the vercel subcommand when invoking through `powershell -File` - the separator is not stripped, lands in `@VercelArgs` verbatim, and vercel parses it as a positional path → `Error: Can't deploy more than one path.` with no deployment created. correct shape: `run <email> deploy --prod --yes --force`.
- long deploys: launch detached (`Start-Process powershell -ArgumentList '…','-File','…\vercel-account.ps1','run','<email>','deploy','--prod','--yes','--force' -RedirectStandardOutput C:\tmp\deploy.log -PassThru`) and poll log + REST - they can outlive the 15-min shell timeout, and stdout buffering means the log may still read `Building…` while REST already shows READY/BLOCKED.

### vercel: alias/deployment URL hits "Log in to Vercel" wall (SSO protection)

- **symptom**: a freshly-created alias (or even the raw deployment URL `*-ncattys-projects.vercel.app`) redirects to `vercel.com/login` with `sso-api` `next=` param, while the auto-generated alias (e.g. `taskflow-nine-ivory.vercel.app`) works fine.
- **root cause**: project-level **SSO Protection** (Vercel Authentication, `ssoProtection.deploymentType=all_except_custom_domains`). The auto-alias Vercel generates on link is exempt; anything else (manual aliases, raw URLs) is walled.
- **detect**: `GET /v9/projects?teamId=<teamId>` → `ssoProtection.deploymentType`. team id from `GET /v2/teams`.
- **fix** (one API call, no dashboard click needed):
  ```powershell
  $body = @{ ssoProtection = $null } | ConvertTo-Json
  Invoke-WebRequest -Uri "https://api.vercel.com/v9/projects/<projectName>?teamId=<teamId>" -Method Patch -Headers @{Authorization="Bearer <token>"; 'Content-Type'='application/json'} -Body $body
  ```
  (project can be the name or id; `null` removes SSO protection entirely. verified 2026-09-01 on ncattys-projects/taskflow.)
- aliases created via `vercel alias set <deployment-url> <alias>.vercel.app` — check availability first; many short names are taken. probe-and-clean: `vercel alias set` then immediately `vercel alias rm` if just checking.


## supabase: account helper

helper: `<repo>\supabase-account.ps1` (contract PASS). profiles at `%APPDATA%\mainframe\accounts\supabase\<email>\` (token.txt = Personal Access Token `sbp_...`). Management API base `https://api.supabase.com` (v1), Bearer auth. token fingerprint + status via `status`/`status-all`; backup.ps1 already snapshots the accounts dir so supabase profiles travel with every mainframe backup/restore.

### adding an account (vault-first flow)
1. create the token in the dashboard: supabase.com/dashboard/account/tokens -> Generate new token -> "Expires in" dropdown -> **"Never"** (a short-lived token dies and the profile breaks; rotate manually when needed).
2. user saves the token into a password vault, then the agent syncs and reads it back from the vault item, then writes `token.txt` into the profile dir.
3. write `profile.json` (tool/service/profile/apiEndpoint/apiVersion/keyPath/updatedAt) + `current.json` for active state — the helper's `login` does this interactively too.
4. verify with `.\supabase-account.ps1 run <email> GET v1/projects` (and `organizations`).

### bulk scripts (moved to automata-private 2026-10-08)

**both scripts moved to `automata-private\supabase.com\`** (mainframe ->
automata merge) - edit them THERE; neither has module imports, they read the
profile `token.txt` directly. the details below still describe the behavior.
- `<repo>\..\automata-private\supabase.com\supabase-projects-table.ps1` — every project across all supabase profiles (name, ref, org, region, db version, status, created). mirror of `neon-projects-table.ps1`.
- `<repo>\..\automata-private\supabase.com\supabase-usage-table.ps1` — per-project usage vs Free quota (500 MB database) using `config/disk/util` `fs_used_bytes` (byte-identical to the dashboard Database size). `-Json` for scheduled consumers. mirror of `neon-hours-table.ps1`.
- quota/limits: Free plan = 500 MB DB per project (Storage 1 GB + Egress 5 GB have NO public per-project Management API endpoint — not reported). paused projects return HTTP 500 on disk/util (expected → Status `n/a (paused?)`). rate limits: 120 req/min per user per project/org, analytics endpoints 30 req/min.
- env overrides: `SUPABASE_FREE_DB_MB` (default 500), `SUPABASE_LOW_PCT` (default 0.85).

### commands
`login`/`token-add`, `token-clear`, `use`, `run`, `projects`, `project <ref>`, `organizations`, `api-keys <ref>`, `status`, `status-all`, `list`, `current`, `path`, `env`, `logout`.

### gotchas
- **token is write-only in the dashboard after creation** — only the vault copy can be re-read; keep the vault item in sync.
- `/v1/projects` on a brand-new account returns `[]` while `/v1/organizations` already returns the org — an empty project list is NOT a broken token.
- `run` restricts the host to `api.supabase.com` (path can be full URL or bare like `v1/projects`; bare paths get `/v1` prefixed).
- profiles keyed by account email only — never store username/label/project-name fallbacks.

## terabox: web-session cookie helper

helper: `<repo>\terabox-account.ps1` (contract PASS). profiles at
`%APPDATA%\mainframe\accounts\terabox\<email>\` holding `cookie.txt` (raw
`*.terabox.com` browser Cookie-header value, must contain `ndus=`) — that's
session state (like wrangler oauth state / the configstore pattern), the account
PASSWORD lives only in the vault item `terabox.com` (2 items, told apart by
`login.username`; names flattened bare 2026-10 — before that `terabox.com - <user>`,
consolidated 2026-09-13 from `terabox.com` + stale dup `dubox.com` (old pw preserved
in notes) + `terabox.com[2]`).

- auth model: terabox web API = cookies + `jsToken` scraped from `https://dm.terabox.com/main`
  per request + `app_id=250528&web=1&channel=dubox&clienttype=0&version=4`. start at
  `https://dm.terabox.com`; an `errno -6` response with a `Url-Domain-Prefix` header
  means retry against `https://<prefix>.terabox.com` (handled in `Invoke-TeraboxApi`,
  max 4 hops, throws on loop).
- **jsToken scrape source (2026-10-15): `/main`, never bare `/`** — the bare `/` landing page
  stopped carrying the token blob that day and now serves a stripped page (a missing token
  throws loud, never a silent empty). scrape it WITH the session cookie:
  `function%20fn%28a%29%7Bwindow.jsToken%20%3D%20a%7D%3Bfn%28%22([^%"]+)%22%29`. the www
  bare no-cookie token (192 hex) passes READS but every WRITE fails `4000023` — only the
  dm+cookie token (128 hex) is valid for writes.
- quota/plan check: `GET /api/quota?disk_type=0` → `{total, used, extra.init_quota_type}`
  (free promo accounts show `permanent_1024g_temp_0g`). every `import`/`login` runs this
  BEFORE writing anything: an unverifiable cookie never creates a profile.
- commands: `login <email>` (opens agent-browser at terabox.com, polls
  `cookies get --json` for `ndus` for 5 min, then captures the whole terabox cookie
  domain set), `import <email> [-Cookie ..|-CookieFile ..]` (hidden prompt if neither),
  `use/current/list/status/status-all/quota/path/env/logout`, `mkdir <email> </dir>`,
  `delete <email> </path> [...]`, `upload <email> <file> [-RemoteDir /dir]`, and
  `run [email] <GET|POST> </api/path> [params-or-body]` (params = `a=1&b=2` raw on GET,
  form body on POST; helper injects app_id/jsToken/channel + follows the -6 dance).
- gotcha: `run` stdout round-trips through the console — a parent process capturing it can get
  mojibake'd non-ASCII filenames that break `ConvertFrom-Json` (measured 2026-10-16 against a root
  listing; ASCII paths like `/gh-mirror` are unaffected). name-matching consumers over non-ASCII
  trees should parse via an in-process API path instead (that is what `terabox-clean.ps1` does).
- **upload protocol** (ported from imgvault `uploaders.js` `TeraBoxUploader`, the proven
  implementation — do NOT re-derive from the desktop app): `/api/precreate` on
  `dm.terabox.com` with the params as an **x-www-form-urlencoded BODY** (query-string
  params = silent `errno 1 stat server err`); `block_list` = JSON array of per-4MB-chunk
  md5s + `local_mtime` + `file_limit_switch_v34=true`. `return_type=2` = rapid upload
  (already on server) → skip to create. Then `GET
  https://dm-data.terabox.com/rest/2.0/pcs/file?method=locateupload` → the real upload
  host (e.g. `dm1-cdata.terabox.com`; guessing `c-jp`/the uploadid IP fails with
  `user not exists`/timeout). Multipart `file=` POST `https://<host>/rest/2.0/pcs/superfile2
  ?method=upload&path&uploadid&partseq&app_id&web=1&channel=dubox&clienttype=0` per 4MB
  chunk (each returns its md5 — verify). Then `/api/create` (query `isdir=0&rtype=1`, form
  body path/size/uploadid/target_path/block_list/local_mtime) → `fs_id`. `4000023` = stale
  jsToken → rescrape + retry once (NOT a captcha wall; `450016` = token missing/rejected
  entirely — e.g. an empty scrape — both are token causes, not verification walls). verified
  2026-09-13: 12 MB + 100 MB round-trip, ~0.95 MB/s free-tier. AList's 3-cookie set
  (ndus+browserid+lang) is SUFFICIENT for the whole flow incl. upload.
- **delete protocol (fixed 2026-10-15)**: `/api/filemanager` delete only accepts the
  web-client shape — POST
  `https://dm.terabox.com/api/filemanager?async=2&onnest=fail&opera=delete&bdstoken=<bdstoken>&app_id=250528&web=1&channel=dubox&clienttype=0&version=4&jsToken=<jsToken>`
  with an x-www-form-urlencoded body `filelist=<urlencoded JSON array of paths>` and headers
  Cookie + Referer `https://dm.terabox.com/main` + X-Requested-With. needs BOTH tokens scraped
  from `/main`: jsToken (as above) and `bdstoken` via `"bdstoken":"([^"]+)"`. the old shape
  (`async=0`, no bdstoken, `ondup=newcopy`) is the signature of a bare `errno -6` with NO
  `Url-Domain-Prefix` header. delete is async — the response carries a `taskid`, so always
  re-list to confirm. implemented as the self-contained `Remove-TeraboxPaths` (re-scrape +
  retry on 4000023/450016, `-6` hop via `Url-Domain-Prefix`, throws on other errnos); the
  `delete` case calls it. consumer: `automata-private\github.com\to-terabox.ps1` (bundle
  mirror push).
- restore/download side: dlinks from `/api/filemetas?target=["<path>"]&dlink=1&origin=dlna`
  (crack mode) are ~30KB/s CDN-throttled for big files with the session cookie (see imgvault
  AGENTS tsl=30 vs 2000). fast lane = cookie-less redirect. prefer for occasional pulls.
- status-all is the "which terabox accounts do I have / how full" check.
- gotcha: `$home` is a read-only built-in in PowerShell — naming a local variable that
  throws "Cannot overwrite variable Home" at runtime; use `$homeResp`. (hit during dev)

## minimax code: device-code multi-account, keyed by a stated email (helper added 2026-10-31)

`minimax-account.ps1`. MiniMax Code (the desktop app) + its `mcode-tools` CLI
share ONE credential per data dir, in plaintext:
`%USERPROFILE%\.minimax\auth\<buildEnv>\<region>\<clientId>` holds `auth.json`
(records keyed by a hash) and `auth-state.json` (the generation counter + status).
The app re-reads them every 250 ms, so swapping the pair IS the switch -- no
restart, no keychain, no api call. Signed-in means `status === 'authenticated'`
AND a record exists AND `record.generation === state.generation`.

contract verbs as usual (`login harvest use refresh run list current status
status-all path env forget logout`, `-Json` everywhere), validated by
`account-contract.ps1` (PASS), plus `status-all -Json` for `automata-private\monitor`.

- **this is the one helper whose profiles live in `%APPDATA%\mainframe\accounts\<tool>`
  instead of the vault, on purpose.** MiniMax ROTATES the refresh token on every
  renewal, so a vault copy goes stale within minutes -- and installing a stale
  chain does not fail quietly, the app itself takes the `invalid_grant` and deletes
  the credential. The folder is inside the encrypted mainframe secret backup and is
  rewritten after each refresh, so the chain head is never more than one write away.
- **`status-all` is not read-only: it re-banks.** The live app holds the newest
  token for whichever account is signed in, so `status-all` copies that head back
  into the owning profile and reports `rebankedProfile`. Without it every profile
  drifts into `grant-dead` within a day of being switched away from. A `grant-dead`
  row offers only a new sign-in, never "switch".
- **`keepalive` is the other half of "keep the pool forever" (added 2026-10-31).**
  the re-bank above protects only the LIVE account; every other profile is frozen at
  the token it held when it was last banked, and an idle chain that is never rotated
  eventually answers `invalid_grant` and goes `grant-dead`. `keepalive` walks every
  profile and rotates the ones the running app is NOT holding (the live one is
  skipped -- the app owns that chain), one at a time. A spent chain does not stop the
  others: the verb keeps going, names every account that needs a new sign-in, and
  exits **nonzero** so a scheduled task's Last Result and its log both say so. A
  profile whose ~1 h ACCESS token shows `expired-token` is NOT this case -- that is
  normal and `use`/`refresh` renews it from the stored refresh token. run by the
  `Monitor - minimax keepalive` task (every 6 h + logon + wake, windowless via
  pythonw; see `automata-private\monitor`).
- **⚠️ MiniMax reports NO email for a google-bound account.** Verified 2026-10-31:
  `GET /v1/api/user/info` answers `email: ""` (also `phone` opaque; only
  `userID`/`realUserID` are stable ids), `/matrix/api/v1/user/profile` answers
  `"email":""`, `.well-known/openid-configuration` and
  `.well-known/oauth-authorization-server` are both 404 (no oidc, and the
  `agent.default` device scope therefore carries no `id_token`), and nothing is
  cached locally -- `minimax-agent-config.json` `.sharedUser` and the app's Local
  Storage leveldb hold only `{userID, realUserID, userName, subUserName}`.
- **ask for the email BEFORE the device code if you can, name it after if you
  cannot.** `login [email]` takes it up front, which is the better path (the
  profile exists before any grant does). It is OPTIONAL since 2026-10-31: with no
  email the sign-in still installs and goes live, but nothing is banked -- the
  helper writes phase `needs-name`, returns `action: logged-in-unnamed` +
  `needsName: $true` and says which `userName`/`realUserID` it is, because
  `harvest <email>` is the only thing that can name it afterwards. A NON-email
  argument is a typo and throws; it must not be downgraded to an unnamed sign-in,
  and `login` with a stray label must not burn a device code on a silent fallback.
  The identity that DOES come back is `userName`/`subUserName` -- a nickname the
  user types, which for exactly this reason once looked like an email and banked a
  real account under the wrong address. Do not scrape addresses out of display
  names: two accounts merge the first time someone names them alike, and the pool
  then switches to a different person than the label promises. The stated address
  is stored as `emailSource: stated` (`minimax` when the api itself names an
  account, `matched-credential` when the live token matched a folder the pool
  already had) and a re-bank never downgrades it, because who named the key is an
  origin fact. If MiniMax DOES name the account (a non-google sign-in) and it is
  not the stated one, nothing is saved and the mismatch is printed -- the approval
  went to a different person than the label.
- **`realUserID` is the anchor.** `Test-IdentityAnchorTaken` refuses to bank an
  account whose `realUserID` already lives under another email and says which one,
  so a stated typo cannot quietly create a second profile for one quota bucket.
- **the pre-login bank failure must reach the human before they approve.** `login`
  banks the outgoing sign-in first; when that cannot be named (an account the pool
  does not know), the `waiting` phase message and the result's `bankError` say so
  loudly, because approving replaces that account's chain and only a fresh sign-in
  brings it back.
- **`use` refuses to switch away from a sign-in nobody owns.** banking the
  outgoing account is the first thing `use` does; when the live sign-in matches no
  profile, that bank throws, and `use` rethrows instead of warn-and-proceed -- the
  unnamed chain has no second copy, so switching spends it permanently. It names
  both fixes: `harvest <email>` (the monitor's "name this sign-in" does exactly
  that), or `logout` to discard it on purpose. `login` keeps warn-and-proceed with
  `bankError`, because there the human sees the warning BEFORE approving and can
  abort. The guard is read in code, not yet pressed against a live unnamed
  sign-in -- the first real refusal is the proof.
- **`status-all` answers "who is live" only when the live sign-in has no owner.**
  for an unmatched, unexpired sign-in it calls `/v1/api/user/info` and reports
  `displayName` + `realUserID` (and `identityError` when that call fails); for a
  sign-in a profile already owns, or an expired token, those three are null and the
  email is the answer. That is what lets the monitor name a sign-in the pool has
  never seen, without asking MiniMax on every 10 s poll for an account it already
  knows.
- identity signing for `/v1/api/user/info` (the only way to ask whose token this
  is): `yy = md5(encodedPath + '_{}' + md5(nowMs) + 'ooui')`,
  `x-signature = md5(yy + '<the app ships this salt in its renderer bundle>')`,
  sent with the app's own client `mcode-public`, audience `agent-backend`,
  region `en`, buildEnv `prod`.
- every write goes through the app's own lock (`auth.lock` as a DIRECTORY with an
  `update` marker inside, proper-lockfile semantics: stale 30 s, 5-250 ms backoff
  factor 1.15) and is re-read afterwards to prove the switch landed, with the
  credential written BEFORE the state file. a switch either happened or says why
  not; `appPickedUp: false` is a fault the caller shows.
- `Start-Process $url` from the helper does not reliably surface a tab when the
  process was spawned by another service, so the approval url and user code are
  also printed and handed to the caller (the monitor panel renders the code and an
  explicit link) rather than assuming a browser opened.
- consumer: `automata-private\monitor`, the `accounts pool > minimax code` sub tab
  (`apps/api/src/minimax.ts` +
  `MinimaxAccounts.tsx`), which shells here for everything and keeps no token
  logic of its own.

## adcode: one Firebase identity per data dir, restart-is-the-switch (helper added 2026-10-31)

`adcode-account.ps1`. ADCode (the Electron IDE, v2.4.0) keeps ONE Firebase
identity per data dir at
`%APPDATA%\@adcode\desktop\ads\ads\identity.json` = `{uid, refreshToken}`, and it
reads that file ONCE per launch -- the idToken is minted in memory and the file
is rewritten only when the app itself refreshes. So unlike minimax, swapping the
file under a running app does nothing: `use` closes ADCode, banks the outgoing
account, installs the target's files and relaunches it. The restart IS the
switch.

contract verbs as usual (`login harvest use refresh open run list current status
status-all path env forget logout`, `-Json` everywhere), validated by
`account-contract.ps1` (PASS).

- **the account is SIX files, not one.** each profile mirrors the live data dir's
  account-scoped set: `ads\ads\identity.json`, `ads\ads\receipts.json`,
  `referrals.json`, `milestones.json`, `activity-queue.json`, `ai-usage.json`.
  receipts/referrals/credits are per-account state, so copying only the identity
  would hand the next account the previous one's usage. editor state
  (`storage.json`, window layout, recent files) is machine-level and stays
  shared. profile folders live at `%APPDATA%\mainframe\accounts\adcode\<email>\`.
- **email comes from Firebase, never from the app bundle.** the helper refreshes
  the stored token at `https://securetoken.googleapis.com/v1/token` (snake_case
  `id_token` / `refresh_token` / `user_id` / `expires_in`) and then calls
  `https://identitytoolkit.googleapis.com/v1/accounts:lookup` (camelCase
  `email` / `displayName` / `providerUserInfo`) with the public client API key the
  app itself ships (`$defaultFirebaseApiKey`). `TOKEN_EXPIRED`,
  `INVALID_REFRESH_TOKEN`, `USER_NOT_FOUND` and `INVALID_GRANT` mark the chain
  `grant-dead`; the row then only offers a new sign-in.
- **⚠️ a fresh ADCode install is ANONYMOUS.** verified 2026-10-31: lookup returns
  no email, no displayName and no providers -- it is a Firebase anonymous
  account. `harvest` refuses to bank it (no address to key a profile by) and
  `use` refuses to switch away from it (the chain has no second copy, so the
  swap would destroy it). Both refusals name the fix: link Google/GitHub/email
  inside ADCode's account menu first. This is global rule 16 enforced end to
  end -- no uid, nickname, or provider label is ever promoted to a profile key.
- **there is no device-code flow in ADCode's bundle**, so `login`/`harvest` only
  bank an identity the app already holds. The add/switch flow is `open` (start
  the IDE with the data dir) -> the human signs in inside it -> `harvest`. The
  monitor's `POST /api/adcode/open` and `harvest` are exactly those two verbs.
- **`status-all` re-banks the live head on every read** (`rebankedProfile`):
  the app refreshes the token itself while it runs, so the stored copy in the
  owning profile would otherwise lag. A profile whose token Firebase refuses is
  `grant-dead`, never offered for switching.
- **`refresh` refuses the live chain while the app is running** -- the app owns
  it and renews on demand; closing ADCode first is the documented way to renew
  from the helper. A successful refresh that receives a new refresh token writes
  it into the live identity only when the file still holds the spent one.
- **`use` proves the target before it breaks the source.** it verifies the
  target profile's uid anchor (`profile.json` vs `identity.json`) and refreshes
  the target chain BEFORE closing the IDE; a dead target is a refusal with the
  app still open. Then close -> bank outgoing -> install six files -> relaunch,
  and `launchError` is reported separately so "files swapped but the IDE did not
  come back" is visible, not a green row.
- **never assign an array field through an `if` expression.** powershell unrolls
  a one-element array on statement output, so `$row['providers'] = if (...) { @(...) } else { @() }`
  stored `"google.com"` instead of `["google.com"]` -- and the api (rightly) refused
  the whole report: *"the helper reported profiles[].providers as "google.com";
  adcode-account.ps1 changed its payload shape; this api expects an array of
  strings"* (hit on the first real bank, 2026-10-31). assign `@()` first and fill
  it with a direct `@(... | Where-Object { $_ })` statement instead. same trap was
  latent in `Get-StatusReport` (`liveProviders`) and both harvest payloads; all four
  are fixed. the api stays strict on purpose -- a scalar is shape drift, not a
  value to coerce.
- **switching is announced, not silent.** `use` reports `appRunning`,
  `appLaunched`, `launchError` and `liveUpdated`; `started` process is tracked by
  command line (`--user-data-dir=`), not by image name, because the user may run
  more than one copy.
- consumer: `automata-private\monitor`, the `accounts pool > adcode` sub tab
  (`apps/api/src/adcode.ts` + `AdcodeAccounts.tsx`), which shells here for every
  verdict and keeps no Firebase logic of its own. no `SECTION_ADCODE_STATE`:
  there is no device phase to share.
- live 2026-10-31: helper on PATH-checked status-all -- 0 profiles, app running
  (1 window), live identity anonymous (key `ea804765d86d`), and a harvest probe
  refused without mutating the live token (fingerprint unchanged afterwards).

## edge: cross-machine extension restore (forcelist + registry external loader)

**the problem**: Edge 151+ validates store-extension install signatures against the machine ID (`install_signer.cc` `HashWithMachineId` via RLZ). a profile restored on a DIFFERENT pc fails that check, and Edge silently removes every `location=1` store extension from `Secure Preferences` on first launch (measured 53 enabled -> 24, same on every attempt). extension FILES on disk survive (`Default\Extensions` still has 29 dirs) but the settings entries are wiped, so the extensions are gone. file-level fixes that do NOT work (all verified on the desktop): stripping `install_signature`/`microsoft_install_signature` from `Preferences`, stripping per-extension `installation_signature` from `Secure Preferences`, wiping `extensions.settings` entirely, setting `location=4`, deleting `Local State`, deleting `_metadata/verified_contents.json`, `icacls /reset`. the stored signature can never verify on another machine because the RLZ machine id differs.

**cut B (2026-10-04): the store package files themselves are no longer shipped.** `backup.ps1` robocopies the Edge profile with `/XD Extensions` (both the VSS and fallback paths), so `Default\Extensions` (202 MB on disk → ~40 MB in the zip) stays out of the backup. the packages come back over the network: enabled ones via the forcelist, disabled ones via the registry loader (both below), and same-machine restores are simply re-fetched by Edge. this does NOT touch extension user data — `Local Extension Settings` (uBlock rules/whitelists), `Extension State`/`Extension Rules`/`Extension Scripts`, extension IndexedDB, and `Secure Preferences` (enabled/disabled state) are all still copied — nor unpacked dev-mode extensions, which travel separately from their source folders into `edge-profile\unpacked-extensions\` (they have no store copy and cannot redownload, so they are never excluded). like the pip restore, extension reinstall now requires network on first boot.

**the fix**: TWO mechanisms depending on enable/disable state:

### ENABLED store extensions — ExtensionInstallForcelist (same as before)

policy reinstall from the Edge store. backup.ps1 extracts the `location=1` extension list (id, name, update_url, version, disable_reason) into `edge-profile\extensions-list.json`. restore.ps1 `Restore-EdgeExtensions` writes each enabled id to `HKLM:\SOFTWARE\Policies\Microsoft\Edge\ExtensionInstallForcelist` with the Edge store URL. Edge force-installs them on the target pc.

**CAVEAT**: the Edge store URL ONLY works for extensions the Edge Add-ons store hosts. Chrome-Web-Store-only extensions return `error-unknownApplication` from the Edge store and silently never install (verified with `Invoke-WebRequest` against the Edge store update URL — CWS-only extensions get `status="error-unknownApplication"` in the Omaha gupdate response). The older claim that "all 23 store extensions returned via the Edge URL" is WRONG. **CWS-only extensions (both enabled and disabled) are NOT installable via the Edge store URL.** The workaround is the registry external loader (see below).

**Why the forcelist can't preserve disabled state**: force-installed (policy) extensions are re-enabled on every startup. The root cause is `ExtensionRegistrar::GetDisableReasonsOnInstalled` in `extension_registrar.cc` — when `MustRemainEnabled` returns true (which it always does for policy-installed extensions), it returns `{}` (empty reasons), wiping any existing `disable_reasons` from prefs. Writing `disable_reasons` back into Secure Preferences does NOT help — the external provider re-triggers this install/update path every startup (`CheckForExternalUpdates` → `OnExternalExtensionUpdateUrlFound` → `AddNewOrUpdatedExtension` → `GetDisableReasonsOnInstalled` → `{}`). Verified empirically on the desktop: dr=[1] written to a force-installed extension gets wiped on the next relaunch.

**The solution**: use Edge's Windows registry external loader (`ExternalRegistryLoaderWin`). The loader reads `HKLM\SOFTWARE\WOW6432Node\Microsoft\Edge\Extensions\<id>` (with `KEY_WOW64_32KEY` — the 32-bit registry view). The `update_url` value must be the extension's OWN store URL (from the backup's `update_url` field):

- Edge-store extensions: `https://edge.microsoft.com/extensionwebstorebase/v1/crx`
- CWS-only extensions: `https://clients2.google.com/service/update2/crx`

The registry loader installs the extension as `location=6` (kExternalPrefDownload), which is NOT a policy location (`IsPolicyLocation` returns false). Therefore `AdminPolicyIsModifiable` returns true → `MustRemainEnabled` returns false → `GetDisableReasonsOnInstalled` inherits existing reasons. The extension loads as disabled with `disable_reasons=[8192]` (DISABLE_EXTERNAL_EXTENSION, pending user acknowledgment) and STAYS disabled across relaunches. Verified on the desktop: 8/8 disabled extensions installed this way remained disabled through 5+ relaunches.

**Restore flow**:
- For each extension in `extensions-list.json`:
  - If `disable_reason` is empty → add to `ExtensionInstallForcelist` (Edge store URL).
  - If `disable_reason` is non-empty → write registry key `HKLM:\SOFTWARE\WOW6432Node\Microsoft\Edge\Extensions\<id>` with `update_url` = the extension's own `update_url`.

**caveats**:
- registry keys + forcelist must STAY installed for the extensions to persist. removing the forcelist uninstalls the enabled ones; removing the registry keys uninstalls the disabled ones (Edge treats them as orphaned external extensions).
- requires admin (HKLM write) and network (store download). fully offline restore cannot reinstall extensions.
- **enabled CWS-only extensions**: the registry loader installs them as DISABLED (dr=8192, awaiting ack). Setting ack_external=true via prefs edit triggers Edge to re-download the extension (rewriting the entry resets ack). The user must enable them once in edge://extensions (one click per extension). This is a one-time action after restore.
- count grows across launches (first launch installs a batch, next ones finish the rest) — verify with `edge://extensions` or the Secure Preferences enabled count after 2-3 launches.
- `--load-extension` (loc=8) does NOT persist across plain relaunches — `InstalledLoader::LoadAllExtensions` explicitly skips `kCommandLine` extensions (`if (info.extension_location == mojom::ManifestLocation::kCommandLine) continue;`). The mainframe notes claiming it persisted were WRONG. Verified on the desktop: loc=8 entries vanished on the next relaunch without the flag.
- this does NOT apply to agent-browser's profile sync (different mechanism, see agent-browser section); that one prunes in a throwaway copy which is re-synced from real Edge each run.

### unpacked (dev-mode, loc=4) extensions — the --load-extension bypass

Edge 151+ prunes unpacked developer-mode extensions (loc=4) from a cross-machine profile exactly like store ones: the loc=4 entry in `Secure Preferences` is deleted on first launch, even with `extensions.ui.developer_mode=true` pre-set (which Edge also wipes). there is NO policy that force-loads a local folder, so the forcelist trick doesn't apply to them.

**the bypass (verified on the desktop)**: launch Edge once with `--load-extension=<path1>,<path2>,...`. Edge registers each as **loc=8 (command-line loaded)**. NOTE: loc=8 does NOT survive plain relaunches — `InstalledLoader` skips `kCommandLine` entries (`installed_loader.cc`), so the extensions only exist while the flag is passed. the older note claiming it "persists" was wrong; treat this as best-effort for dev-mode folders that must exist on the target, and expect to pass `--load-extension` each session.

**how backup/restore handle it**:
- backup.ps1: reads loc=4 AND loc=8 entries from the backed-up `Secure Preferences`, unions them with the machine-local breadcrumb (below), copies each source folder into `edge-profile\unpacked-extensions\<id>-<foldername>\`, and writes `edge-profile\unpacked-extensions.json` (id, name, original path, relative_path).
- restore.ps1 `Restore-EdgeExtensions`: copies each folder back to its original path, then launches Edge once with `--load-extension=` for all restored paths (backup list UNION breadcrumb).
- extension IDs for loc=4 come from the manifest `key` when present; without a `key`, the ID is path-derived (case-sensitive), so the target user dir case must match the source (e.g. `Admin` vs `admin`) to keep the SAME id - otherwise the extension works but under a different id.

### unpacked extensions 2nd-run drop — the breadcrumb (fixed 2026-09-04)

symptom: edge restore keeps local (unpacked) extensions on the 1st run, drops them on the 2nd. root cause chain: run1 re-registers them as volatile loc=8; a later backup finds no loc=4 (pruned cross-machine) and no loc=8 (dropped on plain relaunch) so it writes NO unpacked list (each backup rebuilds `mainframe-backup.zip` from a fresh temp dir, replacing the old one); run2 then has nothing to restore. backup's old loc=4-only scan + "only write when >0" gate + the stale "loc=8 persists" comment were the three contributors. related single-item trap fixed at the same time: `ConvertFrom-Json` returns a bare object (no `.Count`) for a 1-entry `unpacked-extensions.json`, and the old `if ($unpacked -and $unpacked.Count -gt 0)` gate skipped it — always wrap parsed lists in `@(... | Where-Object { $_ })`.
- the breadcrumb: `%LOCALAPPDATA%\Microsoft\Edge\unpacked-extensions.local.json` (id, name, path), written by restore with what it actually registered (manifest-guarded), living OUTSIDE `User Data` so profile wipes don't kill it. restore registers backup-list UNION breadcrumb; backup unions fresh prefs (loc=4+loc=8) with the breadcrumb.
- prune rule (backup only): a carried entry is dropped solely when its folder is gone from disk AND it is absent from fresh prefs (folder present = keep, covers the Edge-pruned case; Edge keeps prefs entries for merely-missing folders, so gone+gone = user-removed). to fully remove an unpacked extension, delete its source folder (and unload it in Edge); the next backup drops it and restore stops re-adding it.
### wintun.sys deletion + PnP enum surgery = BSOD (incident 2026-09-04, laptop)

what happened: while fixing "tailscale adapter won't start" (0x1F / 0xC00002F0 loop),
an earlier cleanup pass had deleted `C:\Windows\System32\drivers\wintun.sys` while the
wintun service entry stayed. restoring the file alone was NOT enough - tailscaled kept
reopening the stale half-dead adapter node `SWD\WINTUN\{37217669-...}` from Enum.
attempting registry deletion of that Enum key (reg delete as SYSTEM) while the PnP
stack was mid-start on the device caused a hard bugcheck (Kernel-Power 41, no dump
captured). the reboot completed the PnP cleanup deterministically and tailscale came
back fully healthy (adapter OK, login intact, desktop ping 2ms) with zero re-auth.

rules from this:
1. NEVER delete Enum/PnP registry keys for a device whose driver is loaded or
   starting - use `pnputil /remove-device` on a PHANTOM node only, and if that
   doesn't stick, the answer is a reboot, not registry surgery.
2. missing `.sys` file + still-present service = driver is half-uninstalled.
   fix order: restore file -> `sc start` test -> if adapter node is stale,
   reboot INSTEAD of Enum editing.
3. tailscaled adapter failure signature: log2/log1 "Timed out waiting for device
   query" + "Failed to setup adapter (0xC00002F0)" repeating in
   C:\ProgramData\Tailscale\Logs\tailscale-service-*.txt = adapter-level, not
   network-level. check System32\drivers\wintun.sys FIRST (size ~29592 bytes is
   correct - it is tiny; don't mistake it for a broken zip copy).
4. tailscaled.state (2 bytes) at %LOCALAPPDATA%\Tailscale is a red herring for
   adapter failures - it is NOT the login store for this scoop install; login
   survives reboots without it.

### edge 2-cycle integration test - VERDICT PASS (desktop-main, 2026-09-04)

ran the full 2-cycle test on the real desktop (real Edge 152, real backup zip 425MB,
S4U scheduled task for elevation - see note below):
- run1-register PASS 6/6 (restore registers loc=8 via --load-extension)
- breadcrumb written PASS
- backup-keeps-list PASS 6/6 (backup captures loc=4+loc=8 AND unions breadcrumb)
- run2-register PASS 6/6 from the NEW backup (2nd-run drop is fixed)
- verdict: all stages green, fix verified end-to-end

test-harness gotchas (the test failed once on these, not the product):
1. backup.ps1 contract: `-OutputDir X` produces `X\mainframe-backup.zip` (zipped
   staging), NOT an extracted tree - extract it before reading
   `edge-profile\unpacked-extensions.json` from it.
2. schtasks quirk: a task action with a scoop SHIM path (pwsh shim) silently never
   runs (Last Result 267011 = "has not yet run"). use the real exe
   `scoop\apps\pwsh\current\pwsh.exe` + S4U principal
   (`New-ScheduledTaskPrincipal -LogonType S4U -RunLevel Highest`) to run elevated
   headless over ssh with no UAC. `Start-Process -Verb RunAs` over ssh just waits
   on a UAC prompt nobody can click.
3. observed Edge behavior: after a PLAIN relaunch all 6 loc=8 extensions SURVIVED
   (volatility premise did not reproduce on Edge 152.0.4191.62) - loc=8 cleanup is
   nondeterministic; the breadcrumb union stays mandatory because loc=8 survival
   cannot be relied on either way.


### unpacked extensions TRUE persistence - loc=4 MAC patch (fixed 2026-09-04, the real fix)

the breadcrumb fix (above) only made restore+backup REMEMBER the unpacked list; the
extensions were still volatile loc=8 (or skeletal prefs entries Edge never imported),
so on a plain 2nd launch the user saw NO local extensions. that was the actual bug.

**the real fix in restore.ps1** (after the --load-extension registration): rewrite
`Secure Preferences` converting the 6 entries loc=8 -> loc=4 (true "Load unpacked",
persistent by design) with VALID protection MACs so Edge accepts the edit:

- MAC scheme (verified 53/53 + super_mac on Edge 152.0.4191.62, both machines):
  `HMAC-SHA256(key = empty seed, msg = device_id + path + canonical_json(value))`
  - seed: EMPTY on Edge (no GOOGLE_CHROME_BRANDING resource); chrome's is the
    64-byte IDR_PREF_HASH_SEED_BIN blob
  - device_id: machine account SID WITHOUT the RID
    (`user SID -replace '-\d+$',''` == LookupAccountNameW(computername) on
    standalone machines; NOT the full user SID, NOT hashed)
  - path: `extensions.settings.<id>`; super_mac path: `""` over the whole
    `protection.macs` dict
  - canonical json: sorted keys (base::Value::Dict flat_map order), recursive
    pruning of empty dict/list children, compact separators, `<` -> `\u003C`
    (capital C), control chars `\u%04X` uppercase, no ascii-folding
- Edge 152 gotcha: `protection.macs.extensions.settings_encrypted_hash.<id>`
  (DPAPI/os-crypt v20 AES-GCM) is AUTHORITATIVE when present - the patched entry
  must have its encrypted_hash DELETED or the fix silently won't apply
- super_mac must be recomputed after any macs change
- embedded python (stdlib only) in restore.ps1 does the patch; failures fall back
  LOUD (warning, extensions stay volatile loc=8) - no silent degradation

verified end-to-end on desktop (edge-2cycle-desktop-test-v2, S4U task):
run1 loc=4 6/6 -> plain launch1 active (10 ext-procs) -> plain launch2 STILL active
+ prefs survive 6/6 -> plain launch3 still active. VERDICT PASS.

test v2 lesson: the v1 test asserted prefs REGISTRATION (loc=8 entries), which
passed while the user-facing bug was still live - "volatility premise holds
(expect 0)" even CODIFIED the broken behavior. v2 asserts ext-procs + loc=4
survival across 3 plain launches. always assert user-visible behavior.

## daily mainframe backup: release cap + visible run

### backup publish vault lookup gotcha (fixed 2026-09-27)

`publish-backup.ps1` must read the active GitHub profile from
`%APPDATA%\mainframe\accounts\github\current.json` and pass that email to the
vault helper. It must search `github.com*`, not only `github.com - *`: both the
handle-suffixed item and the legacy exact item named `github.com` are valid. The
shared GitHub account helper uses the same pattern. Never select the first
profile directory or print token/notes contents while diagnosing this path.

### prune deleted the release it had just uploaded (fixed 2026-10-03)

`gh release list` returns **newest-first**, but the prune did
`$mine | Select-Object -First ($mine.Count - $Keep)` as if the head were the oldest —
so every run deleted the release it had just created. the giveaway: the repo sat at
**exactly** `$Keep` (10) releases forever, all tagged `<= 2026-09-21`, while
`daily-backup.log` showed a successful publish every single day. a count pinned at
exactly `$Keep` is the signature (create -> prune eats it -> back to `$Keep`), and
`done: ... holds 10` printed anyway, so nothing looked broken. **12 days of backups
(2026-09-22..2026-10-03) were uploaded and immediately destroyed**; the local zips are
overwritten daily, so those snapshots are gone for good.

fix: `Sort-Object tagName` before the slice (tags are `yyyy-MM-dd-HHmm-<host>`, so
lexicographic == chronological), plus a post-prune assertion that the new tag still
exists — if it doesn't the script throws instead of printing `done`.

diagnostic to reuse: release count == `$Keep` exactly AND the newest tag stops moving
while the log keeps saying DONE = prune is eating the new releases.

### Python tooling retained; automatic frozen snapshot retired
- `backup.ps1` still excludes installed `site-packages` from Python persistence
  and retains `Scripts` and Python/pip tooling for explicit future installs.
- Backup no longer runs `pip list --format=freeze` or creates `pip-freeze.txt`.
  Windows Full no longer requires or installs that automatic frozen snapshot.
- Existing archives stay untouched. Legacy `pip-freeze.txt` remains inert restore
  control metadata, never a user-data staging target or a Linux action/blocker.
- Linux retains planning of explicit repository `requirements.txt` and
  `requirements-linux.txt`, including when `--backup-root` is supplied. It never
  consumes requirements from the backup root. Generic execution remains blocked
  pending interpreter/dependency/integrity and isolated-destination preflight.
### compression level + why daily size jumps around (measured 2026-10-03)

- **`-mx=9` (was `-mx=5`)** on both 7z calls. controlled A/B on identical content:
  276.5 MB (mx=5) vs 273.7 MB (mx=9) = **+1.0%, 2.8 MB** — not the 3-8% you'd hope for,
  because the payload is mostly already-compressed binaries (`.dll/.exe/.pyd`) and
  leveldb. kept since it costs nothing, but **do not expect `-mx` to cut size here**;
  the only real remaining compression lever is a different container (`-t7z -ms=on`
  solid), which changes the restore/unzip path.
- **core size swings ~40 MB between runs with zero code changes** — uBlock Origin's
  filter-list cache (`Default\Local Extension Settings\odfafepnkmbhccpbejgmiehpchacaeak`)
  re-downloads and rewrites its leveldb: 66.8 MB one run, 100.4 MB the next. that is
  userdata churn, not a backup regression; judge the backup by `persist` and by the
  zip entries, not by a single core reading.

chain: Task Scheduler `MainframeDailyBackup` (S4U + Highest, 09:00 Asia/Dhaka,
DisallowStartIfOnBatteries) -> `mainframe\daily-backup-publish.ps1` ->
`backup.ps1 -ExcludeSecrets -Publish` -> `publish-backup.ps1`.

- **where it goes**: `publish-backup.ps1` uploads TWO zips to a **private GitHub release**
  on `FahadBinHussain/mainframe-production`, tag
  `yyyy-MM-dd-HHmm-<hostname>` (hostname-tagged so laptop + desktop can both publish
  into the same repo): `mainframe-quick.zip` (everything quick mode needs, with the
  AES-256-encrypted secrets archive tucked INSIDE it as the entry `mainframe-secrets.zip`)
  + `mainframe-persist.zip`. auth: vault `session.key` -> vault github token ->
  `gh release create`. it lists quick's entries and throws unless the encrypted blob is in
  there exactly once, then re-reads the release asset list and throws if either zip is missing.
- **capped, not infinite**: `-Keep 5` (default, cut from 10 on 2026-10-04 — GitHub
  does not quota release assets, so this is repo housekeeping only) per hostname. after
  each publish it prunes to the newest 5 for that host with `gh release delete --cleanup-tag`.
- **idempotent**: skips if `C:\tmp\daily-backup-lastdate.txt` already holds today's date
  (task retriggers won't double-publish).
- **vault preflight happens BEFORE any backup work (2026-10-29)**: the old code only checked that
  `session.key` EXISTS. an expired 1-hour-TTL key passes that check and only reads as `locked`
  when the secrets step touches the vault near the END of the run — the 2026-10-29 task died at
  09:05 with `vault is locked or approval was not completed` after a 120s mobile-approval timeout,
  throwing away 1.9 GB of just-built zips (release missing, marker stuck at the previous day).
  `daily-backup-publish.ps1` now imports `vault-secret.psm1` and calls
  `Ensure-VaultSession -TimeoutSeconds 600` right after the marker check, so the 1-tap push goes
  out while nothing has been zipped yet and a missed approval fails fast with
  `vault locked - 1-tap mobile approval not completed within 600s; backup not started`.
  a valid session returns in ~4s with no prompt. a stale-but-present key is NOT a skip reason.
- **a missed approval is recoverable, keep the marker honest**: the daily marker is only written
  after a successful publish, so a manual rerun (`unlock.ps1` or another 1-tap approval, then
  `pwsh -File daily-backup-publish.ps1`) picks the day back up. do NOT "fix" a failed run by
  deleting WhatsApp state, skipping the secrets step, or writing the marker by hand.
- **what's zipped**: scoop persist dirs (VSS + robocopy, skips `Cache`/`logs`) + core config + edge profile + skills. `persist\python312\Lib\site-packages` is **NOT** shipped (see below) — everything else in `python312` (incl. `Scripts`, which carries `pip.exe`) is. Edge `Default\Extensions` store packages are **NOT** shipped either (cut B, 2026-10-04) — Edge re-downloads them via the forcelist/registry loader (see edge section); unpacked dev-mode extensions ARE still copied via `edge-profile\unpacked-extensions\`. it does NOT snapshot free disk space, `Temp`, `~\.cache`,
  or `C:\tmp` — cleaning those does not change what a backup captures.
- **GitHub's 2 GiB per-asset cap, the `gradle` exclusion and the pre-upload guard (2026-10-27)**:
  `mainframe-persist.zip` hovered at 2.093–2.098 GB from 2026-10-15 (65.9 MB on 2026-10-10) and the
  2026-10-27 run finally crossed GitHub's HARD per-asset limit (2,147,483,648 B — a platform cap,
  not a plan cap, reported only as `HTTP 422 ... size must be less than 2147483648` AFTER the
  release row already existed, so the tag had to be cleaned up). the overwhelming contributor among
  non-excluded dirs was `scoop\persist\gradle\.gradle\caches` (3.55 GB live, pure build cache), so
  `gradle` joined `backup.ps1`'s persist `$excludeDirs` — measured effect: persist dropped to
  205–215 MB. `publish-backup.ps1` now asserts every asset's size before `gh release create` and
  throws naming the asset, its MB and the exact limit, so an oversized zip fails BEFORE any release
  exists. when persist grows again, read the biggest `persist\*` dirs first and exclude a rebuildable
  cache — never trim user data to fit.
- **vault is never backed up** (decided 2026-09-12). the bitwarden vault lives server-side; we do not ship it:
  - `backup.ps1` persist `$excludeDirs` includes `bitwarden-cli` → the encrypted `bw-data\data.json` cache is not captured on any run (daily or full).
  - `tool-secrets.manifest.json` `mainframe tool auth profiles and tokens` item has `excludeDirs: ["bitwarden"]` → the full-run `secrets\` archive skips `accounts\bitwarden\` (`session.key` + profile).
  - a restore therefore has no vault session; run `automata-private\bitwarden.com\unlock.ps1` to re-login (rebuilds `data.json` from the server) before anything needs a token.
  - other `accounts\<tool>\` profile dirs still travel — since 2026-08-22 they hold only `profile.json`/`current.json` metadata + CLI state, not raw secrets (those are vault-native).


### secrets ship inside quick (2-asset release, reshaped 2026-10-07)

the one-liner goal ("run `irm da.gd/f85Bj | iex` on any pc, quick or full, get the whole
machine back") was NOT met by core+persist: the daily chain passes `-ExcludeSecrets`, so
nothing shipped `.ssh`, `.opencode\*`, `.config\opencode`, `.wakatime.cfg` or
`AppData\mainframe\accounts\*`. a remote restore came back with no ssh keys, no opencode
providers/models config, and every account helper pointing at empty profiles — while boot's
quick prompt literally promised "edge profile, opencode, **secrets**". it claimed work it
did not do.

every release now carries TWO assets, and boot dies loudly when one is missing:

| asset | contents | built by |
|---|---|---|
| `mainframe-quick.zip` | edge profile, config, skills, restore scripts, `scoopfile.json`, `quick-persist\ditto` (Ditto settings + starred-only `Ditto.db` so a quick restore installs/links Ditto like a full one — added 2026-10-13) + the encrypted `mainframe-secrets.zip` entry | `backup.ps1`, blob appended by `publish-backup.ps1` |
| `mainframe-persist.zip` | scoop persist dirs (incl. the same starred-only `Ditto.db` under `persist\ditto`) | `backup.ps1` |

the encrypted blob rides INSIDE quick on purpose: quick mode = 1 download, full mode = 2,
and neither mode can end up on a box with no `.ssh`/opencode/account profiles. an earlier
same-day shape shipped it as a third asset — `mainframe-quick.zip` + `mainframe-persist.zip`
+ `mainframe-secrets.zip` — which worked but forced every restore to make a third request.

**ditto parity in quick mode (2026-10-13)**: ditto was full-mode-only — its settings
(`persist\ditto`, `Ditto.db` excluded), the allowlist-loop install and the fork rebuild all sat
past quick's `return`, so a quick restore ended with no clipboard manager. quick now ends with
the same Ditto: `backup.ps1` copies `persist\ditto` into quick staging as `quick-persist\ditto`
(settings plus the starred-only `Ditto.db`, see the next block — the full 2 GB+ clip DB still
stays out of BOTH zips), and `restore.ps1`'s quick route runs `Install-DittoQuick` (restore
settings -> ensure the `extras` bucket -> pinned install from scoopfile, loud warning when the
backup carries no `quick-persist\ditto`) followed by the shared `Rebuild-DittoFork`, the same
patcher the full route uses — so a missing `automata-private` warns identically in both. full
mode is deliberately unchanged: persist restore + allowlist loop + patcher step already produce
that state, and routing it through `Install-DittoQuick` would have skipped the loop's `hold`
handling.
(the `quick-persist` name is load-bearing: 7z's `-x!persist` filter is name-exact, so it drops
`persist\` from `mainframe-quick.zip` while `quick-persist\` rides along — verified with a local
`7z l` listing. the settings robocopies re-apply `/XF Ditto.db` so a future
`persist-include.json` list mode cannot smuggle the FULL clip DB into the quick zip; the only
Ditto.db that ships is the stripped one placed by the starred-db block below.)

**starred-only Ditto.db in both modes (2026-10-13)**: both zips now carry a stripped clip DB
so a restore lands the user's STARRED clips while full history stays local-only. starred =
`Main.lDontAutoDelete > 0` — the exact flag the fork's starred-clips filter PRs #1098/#1107
read (there is NO `bFavorite` column; verified against the live db). `strip-ditto-favorites.py`
(repo root, python stdlib sqlite3) builds it at BACKUP time into BOTH `persist\ditto` and
`quick-persist\ditto` staging, so the restore target needs no python. kept: starred clips +
ancestor groups (recursive `lParentID` walk) + their `Data` blobs + `Types` rows;
`MainDeletes`/`CopyBuffers` ride as EMPTY tables (old-deletion tombstones must never
propagate to a restored box via sync); `sqlite_sequence` copied as-is so future autoincrement
lIDs never collide with kept rows. guards: source opened READ-ONLY (`mode=ro`,
`immutable=1` retry announced loud) — safe while Ditto is running; 0 starred clips = refuse to
ship (an empty favorites db would wipe clips on restore); schema drift (missing
`lDontAutoDelete`) = loud fail, no db shipped. restore side, BOTH routes: settings/persist
robocopies carry `/XF Ditto.db` and the db is placed only when the target has none —
fresh-box only, an existing/live clip DB is never overwritten (warned loud). measured on the
laptop: 121 starred of 66,267 clips, 132.7 MB live db -> a few MB stripped. tested ONLY on
synthetic dbs (`C:\tmp\ditto-fav-test\run-tests.py`, 16 checks incl. 2 loud-failure paths);
the live db was never written. sqlite traps hit + fixed: `sqlite_sequence` is a reserved name
(it auto-exists via AUTOINCREMENT, never CREATE it), and VACUUM cannot run inside python's
implicit transaction (`isolation_level=None`).

**flameshot in quick mode + settings shipped (2026-10-13)**: quick route gained a 7th step —
`Install-FlameshotQuick` (pinned from scoopfile, `extras/flameshot` at bucket head as the loud
second method, skip when installed) + `Restore-FlameshotSettings`. the scoop manifest has NO
`persist` entry (unlike ditto), so `%APPDATA%\Flameshot\flameshot.ini` was captured by NOTHING
in the chain — backup.ps1 now ships it as `quick-persist\flameshot\flameshot.ini` (the quick
zip always downloads, in both modes; the full route calls `Restore-FlameshotSettings` right
after the persist restore since its install comes from the allowlist loop —
`scoop-allowed.json` already lists flameshot). same fresh-box-only rule as the starred db: an
existing `%APPDATA%\Flameshot\flameshot.ini` is never overwritten, warned loud.

chain: `backup.ps1 -Publish` runs `backup-secrets.ps1` FIRST (so the 09:00 task and a manual
publish both build `tool-secrets.zip`), zips core staging into `mainframe-quick.zip`, then
`publish-backup.ps1` encrypts the archive, appends it into quick as `mainframe-secrets.zip`
(`7z a` adds one entry without recompressing the other ~220 MB), asserts by **listing the
entries** that the blob landed exactly once, and uploads quick + persist. `-ExcludeSecrets`
keeps its meaning: it stops PLAINTEXT secrets being embedded in quick/persist — the
encrypted copy is what ships either way.

- **password lives in the vault only**: Bitwarden item `mainframe-production`, notes header
  `[secrets archive password]` + one `[A-Za-z0-9]{40}` line. both sides run the byte-identical
  lookup — `bw list items --search 'mainframe-production'` then
  `(?m)^\[secrets archive password\]\s*\r?\n\s*(\S+)` — in `publish-backup.ps1` and `boot.ps1`;
  keep them in sync or boot cannot decrypt. item name = the repo it protects (bare identifier,
  no suffix, same naming rule as the domain-named items).
- **encryption**: `7z a -tzip -mem=AES256 -p<pw>` run from inside the mainframe dir so the
  stored entry name is exactly `mainframe-secrets.zip` at quick's root; boot extracts quick,
  asserts `$extract\mainframe-secrets.zip` exists, runs
  `7z x <blob> -o<extract> -p<pw>` and `restore.ps1` finds `$BackupRoot\tool-secrets.zip`
  where it always looked (no restore.ps1 path change needed). plaintext never touches github:
  private repo AND encrypted bytes.
- a release published before 2026-10-07 carries `mainframe-core.zip` and (that day only) a
  separate `*-secrets.zip`; boot refuses either layout with the fix
  (`.\backup.ps1 -Publish` on the source machine) rather than silently producing a partial box.

#### gotchas fixed while wiring this up (read before touching this chain)

1. **staging needed 5.6 GB on a disk with 2.3 GB free (7z exit 2, no message).** the accounts
   item stages `accounts\*`, and `accounts\browser-use\` is a **1.68 GB orphan copy of an
   agent-browser profile** — its own `mainframe-profile.json` says `tool: agent-browser`, no
   script references it, and `agent-browser` was already excluded while `browser-use` was not.
   added to `ExcludeDirNames`. `C:\` sits at ~0.5% free (2.3 of 476 GB), so ANY staging over
   ~1 GB dies: read free space first when 7z says *"There is not enough space on the disk"*.
2. **the 7z failure printed no reason at all.** both 7z calls used `-bso0 -bsp0 -bse2`, and
   `-bse2` routes stderr INTO stdout, which `-bso0` had disabled — a fatal run yielded only
   "7z failed with exit code 2". both calls now capture `2>&1` and put the message in the throw.
3. **boot took the FIRST github token in the vault** (`foreach ... break` over
   `bw list items --search 'github.com'`). the vault holds tokens for six accounts, the first
   alphabetically is `github.com - algojectt`, and that account cannot see the private repo —
   gh answered `release not found` on a machine that had done nothing wrong. boot now selects
   `github.com - <owner of $BackupRepo>` and dies listing the github items it did find. the old
   code also gated on `%APPDATA%\mainframe\accounts\github` existing — on a FRESH pc that dir
   only arrives with the secrets archive it was needed to download, so step 3 could never pass
   on the exact machine boot exists for.
4. **`restore.ps1` checked `$LASTEXITCODE` after calling `restore-secrets.ps1`** — that script
   runs no native commands, so the variable still held robocopy's code from the Edge restore
   (1 = "files copied OK") and a successful restore reported failure. removed: restore-secrets
   throws on real failures and `$ErrorActionPreference='Stop'` propagates. `restore.ps1` now ends
   with `exit 0` so boot's own `$LASTEXITCODE -ne 0` check is honest for the same reason.
5. **the standalone-zip branch ignored `-ItemNames`/`-SkipNames`**, so quick mode's
   "Restoring opencode config" step restored EVERYTHING and the following step redid all of it.
   `restore-secrets.ps1` now takes the same two filters as the embedded branch and restore passes
   them; a filter matching nothing prints `No secret items match this filter ...` instead of
   silently doing nothing.
6. **restore's clone step pointed at placeholders and the outdated public repo (2026-10-07).**
   `-CloneRepos` defaults were `https://github.com/<owner>/mainframe.git` +
   `https://github.com/<owner>/automata.git`: nothing ever substitutes `<owner>` (boot passes
   only `-Mode`/`-BackupRoot`, so the defaults are what actually run), and the checkout on disk
   is `Downloads\automata-private` — the public `automata` repo is outdated and `Downloads\automata`
   does not exist. quick mode returns BEFORE the clone step, which is why the download/decrypt
   boot simulations never exercised it — only a full-mode restore does. fixed: real owner in both
   clone URLs, key/dest/patcher root renamed to `automata-private`, and every doc/error-message
   path renamed with them (verified: `automata(?![A-Za-z\-])` returns 0 hits repo-wide).
   **2026-10-31**: quick mode now syncs automata-private too, before the Ditto fork rebuild so
   the patcher exists. both modes share `Sync-AutomataPrivateRepo`, which THROWS on clone/pull
   failure - the old inline full-mode clone ignored `$LASTEXITCODE`, so a missing private repo
   only showed up later as "patcher not found" warnings while restore still reported success.
   git auth for that private repo is named, not inherited: `Get-GhCredentialAuthArgs` passes
   `-c credential.helper= -c credential.helper=!gh auth git-credential` (the same line
   `gh auth setup-git` writes, scoped to the one command, no global config touched). boot
   exports the vault token as `GH_TOKEN` before calling restore, so a fresh box clones the
   private repo with no gh login and no ambient credential can silently take over. measured
   against the real repo 2026-10-31: valid `GH_TOKEN` -> `ls-remote` ok and `gh` returns that
   token verbatim as the password with `username=x-access-token`; bogus `GH_TOKEN` -> exit 128
   `Invalid username or token` (this is also the proof the `credential.helper=` reset works —
   ambient creds did not rescue it); no `GH_TOKEN` -> gh's stored login; `gh` absent -> the
   machine's own git auth, said out loud on screen.

**visible run** (added 2026-09-12). the job is S4U = session 0 = no desktop, so on its own it
runs silent. it now hands visibility to an on-demand interactive task:

- `backup-notify.ps1` draws a borderless topmost banner bottom-right + plays a system sound,
  auto-dismiss: blue `start`, green `done`, gray `skip`, red `MAINFRAME BACKUP FAILED` (stays ~45s).
- scheduled task `MainframeBackupNotify` (LogonType **Interactive**, no trigger, Parallel) runs
  `pwsh -File backup-notify.ps1` with **no args** — it reads one line `state|message` from
  `C:\tmp\backup-notify.txt`, which the backup writes right before `Start-ScheduledTask`.
  state goes via a file because `Start-ScheduledTask` can't pass arguments to the target.
- `daily-backup-publish.ps1` calls `Notify start|done|skip|fail` at those points.
- manual test: `.\backup-notify.ps1 -State done -Message "tag 2026-...-DESKTOP"`.
- **`-Prefix` (added 2026-10-06)** retitles the banner for a non-backup caller;
  the default `'Mainframe backup'` keeps every title byte-identical to before
  (`done` → `<Prefix> done`, `fail` → `<PREFIX> FAILED`). Other jobs pair it
  with their own state file so they never borrow the backup's wording — e.g.
  the `DiitChatbotRecrawlNotify` task runs
  `-StateFile C:\tmp\diit-recrawl-notify.txt -Prefix 'DIIT recrawl'`, which
  renders `DIIT RECRAWL FAILED`. The state file stays `state|message`; only
  the title differs.
- caveat: the banner only renders when a user is actually logged on and unlocked; on a locked
  / headless run there is no desktop to draw on, so the only record is `C:\tmp\daily-backup.log`.



### metered-connection skip (added 2026-10-18)

`daily-backup-publish.ps1` now checks the upload link BEFORE any backup work: if the
active internet connection is metered (or there is no internet at all), the whole run
is skipped - no point burning metered data on a backup that could not be uploaded
anyway. skip = log line + gray `skip` banner (now shows the reason, e.g. "metered
connection - backup skipped") + `exit 0` (task shows success, no retry); the daily
marker is NOT set, so the next run still happens once the link is usable again.

- the check is `network-cost-check.ps1` (repo root): prints one JSON object
  (`connected`, `interface`, `costType`, `roaming`, `overDataLimit`,
  `approachingDataLimit`, `skip`, `reasons[]`) and exits 0 when the check completed.
  `skip=true` for: cost type Fixed/Variable, roaming, over data limit, approaching
  data limit, or no internet profile.
- **it must run under Windows PowerShell 5.1, invoked as
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File`** - it uses the WinRT
  `Windows.Networking.Connectivity.NetworkInformation` API (the exact source the
  Settings "metered connection" toggle writes to). pwsh 7 cannot load WinRT
  projections at all (verified 2026-10-18: *Unable to find type
  [Windows.Networking.Connectivity.NetworkInformation,...]*), so the helper has a
  loud guard that throws when run under pwsh instead of silently degrading. the
  daily script (which runs under pwsh) shells out to 5.1 for this one check.
- **a failed check is fatal, not a skip** - non-zero exit or unparseable JSON throws
  `network-cost-check failed`, the task fails loudly, and no backup is silently
  cancelled.
- registry `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\NetworkList\DefaultMediaCost`
  is NOT a substitute: it holds the per-media-type DEFAULTS only; a per-network
  metered flag (i.e. a Wi-Fi profile toggled metered in Settings) lives in the WLAN
  profile and only NLM/WinRT reports it. measured 2026-10-18: `DefaultMediaCost\WiFi=1`
  while the active connection was metered - a registry-only check would have said
  "not metered".
- `backup-notify.ps1` `skip` state now renders its message when one is passed
  (`already ran today - skipped` stays the default for the marker-skip call, which
  passes none - banner text for that path is byte-identical to before).
- testing: `-Simulate unrestricted|metered|offline` runs synthetic values through the
  same classifier (JSON carries `"simulated": true`); a real two-way test toggles the
  active profile (`netsh wlan set profileparameter name=<ssid> cost=unrestricted`,
  then `cost=fixed` to restore) and re-runs the helper (verified live 2026-10-18:
  Fixed -> skip, Unrestricted -> proceed, revert -> skip again).
- only the daily chain is gated; manual `backup.ps1 -Publish` runs are not.

### artifact autoclean (added 2026-10-18)

`daily-backup-publish.ps1` now sweeps its own artifacts from a `finally` block:
EVERY exit path runs it (published / metered skip / already-ran-today skip / fatal),
so a box that was once at 2.3 GB free never accumulates backup debris.
`Remove-BackupArtifacts`:

- deletes the six zip names in the repo root - `mainframe-quick.zip`,
  `mainframe-persist.zip`, `mainframe-secrets.zip`, `tool-secrets.zip` (the PLAINTEXT
  secrets archive - publish encrypts it into the blob that rides inside quick and the
  next run rebuilds it, so it must never linger) + retired `mainframe-core.zip` /
  `mainframe-backup.zip` (sweeps pre-2026-10-07 strays). the release store is the
  durable copy; a failed publish's zips are rebuilt from live state by the next run.
- deletes crash leftovers in `%TEMP%`: `mainframe-backup-*` staging trees,
  `mainframe-zip-stage-*`, `mainframe-tool-secrets-*`, `ditto-favorites-*.db`, a stray
  `mainframe-secrets.zip`, `robocopy-log-*.txt`. age-guarded to older-than-2h so a live
  manual run's files are never touched. this covers the gap where a run dies before its
  own self-cleanup (the oct 13 crash left 4.1 GB `mainframe-backup-*` + 4.1 GB
  `mainframe-zip-stage-*`; backup-secrets.ps1's own staging is finally-guarded but a
  hard kill can still strand it).
- logs `cleanup: removed N artifact(s), freed X MB` on every run (0/0 included - a
  missing line means the cleanup step itself died, reported as `cleanup WARNING: ...`).
  cleanup catches everything and never changes the run's exit code.
- a manual `backup.ps1` run is not cleaned by its own invocation (cleanup lives only in
  the daily chain), but its zips land at the same repo-root paths and the next daily run
  sweeps them - use `-OutputDir <dir>` when you want to keep one. same window applies to
  a manual `backup.ps1 -Publish`'s `tool-secrets.zip`: the plaintext archive sits there
  until the next daily sweep.

measured 2026-10-18 (first live sweep, on a metered skip): removed 7 artifacts, freed
10714.1 MB = 10.5 GB (2.4 GB of zips incl. the 2 GB persist from the failed 07:32
publish + the two 4.1 GB oct 13 temp trees + a 3.4 MB stray temp blob). a follow-up
sweep the same day caught the one class the first list missed - `tool-secrets.zip`
(the 3.5 MB PLAINTEXT secrets archive from the failed run), verified live and added.

## doc-surgery gotcha: Set-Content roundtrip flipped line endings (2026-10-08)

while moving eight scripts to automata-private I rewrote this file with `Get-Content -Raw`,
`-replace` note blocks (here-strings) and `Set-Content -NoNewline -Encoding utf8`, and the
result came out mostly CRLF against an LF HEAD. git then showed the whole 1243-line file as
changed and the secret scan tripped on untouched doc paragraphs reappearing as `+`.
catch it by comparing `git diff --cached --stat` with `git diff --cached --ignore-cr-at-eol --stat`
(45 real lines vs 2471 here). fix: normalize back to HEAD's style before staging -
`while ($c.Contains("`r`n")) { $c = $c.Replace("`r`n","`n") }` (the loop also eats a leftover
CR CR LF), re-`git add`, re-scan (32480be). append with `[IO.File]::AppendAllText` rather
than `Add-Content`, which writes platform CRLF.

## native-platform bootstrap entry points

- `bootstrap.ps1` is Windows-only; `bootstrap.sh` is Linux-only Bash. Each prints `mainframe: selected <platform> -> <child>` before child download/execution, supports a route-only preview (`-DryRun` / `--dry-run`), and rejects wrong-platform invocation without fallback. Linux needs no PowerShell.
- Windows delegates to existing `boot.ps1` unchanged, so PowerShell 7 remains a Windows prerequisite (not Windows PowerShell 5.1). Do not remove that requirement merely to make the launchers look symmetric. Linux delegates to `boot.sh`: explicit `--setup-tools` installs git/curl/ca-certificates/python3 and clones into `~/Downloads/mainframe`; `--restore` routes to offline recovery and `--packages` to the dry-by-default package planner. Omitting the mode fails without changes. An existing setup destination is rejected before package changes.
- Linux recovery preserves Windows archives and offers candidate exports, NOT an operational Windows machine-state restore. Never imply that Windows account helpers, browser profiles, tasks, or services have been ported. Unsupported distributions fail in the child, not in route preview. See `docs/linux-restore-coverage.md` and root `plan.md` for exact boundaries.
- `linux_real.py --restore-global-agents` is the only explicit global-instructions restore path: it restores the exact root `AGENTS.md` from `mainframe-quick.zip` to `$HOME/AGENTS.md`, byte-verifies it, and backs up an existing target. Without `--yes`, it activates only that file; nested instruction files and `.agents/skills` remain blocked. Offline staging uses `linux_restore.py --include-global-agents` and never writes live HOME.
- **the linux live flow syncs the private repo too (2026-10-31)**: `linux_real.py` clones or fast-forward-pulls `automata-private` into `~/Downloads/automata-private` - the same Downloads root `boot.sh` uses for the public checkout - before the restore leg. it is the linux counterpart of the windows `Sync-AutomataPrivateRepo`, and the credential source is NAMED, never inherited: gh's own helper when `gh` is installed (the same `-c credential.helper= -c credential.helper=!gh auth git-credential` pair the windows restore uses, with `GH_TOKEN` set from the vault token the release download already fetched), otherwise a private python credential helper that reads the token from `MF_GH_TOKEN` in the child's environment - never from argv, never from a git config file, never from disk. `credential.helper=` comes first so no ambient helper can answer as another account, and `GIT_TERMINAL_PROMPT=0` makes a headless restore fail fast instead of waiting for a username nobody is there to type. a failed sync ABORTS the restore leg (the same fix the windows side made: a restore must not report success while shipping a machine without the private checkout), and `--skip-private-repo` is the explicit opt-out that says so out loud. offline recovery (`restore.sh` / `linux_restore.py`) still clones nothing. measured 2026-10-31 against real git and gh 2.102: `git credential fill` with the private helper answers `username=x-access-token` + `password=<token>` straight from `MF_GH_TOKEN`, and `gh auth git-credential` with `GH_TOKEN` answers the same. note how git calls a `!`-style helper: it runs the command through the shell and appends the operation (`get`/`store`/`erase`) as the only argument - only `get` answers, so nothing is persisted. covered by `tests/test_linux_private_repo.py`.
- `--convert-portable` requires recovery and is independent of `--apply-portable`. Validated conversions are the six-enum root Git config subset and the exact `persist/mpv/portable_config/mpv.conf` five-boolean subset in `linux_migrations.py`; mpv profiles, paths/devices, scripts, unknown fields, other files, and runtime/version compatibility remain unverified. Extend adapters only with understood source/target semantics and deterministic fixtures. Unknown/sensitive fields stay explicitly blocked without echoing values or private subsection names. Preserve original bytes and report conversion separately from installation/activation. No real restore/bootstrap or production payload inspection in development tests; no global instruction edits.
- Local execution requires a sibling child and refuses network fallback. Remote scriptblock / Bash `-c` execution downloads only its platform child and cleans temporary files. Fetching the launcher itself is outside preview's no-download guarantee; preserve fetch failure with `&&` in the Bash command instead of piping unchecked downloads into a shell. The old short link remains Windows-only.
- Validate with `pwsh -NoProfile -File tests/bootstrap.Tests.ps1`, `bash tests/bootstrap.Tests.sh`, and `bash -n` separately on `bootstrap.sh`, `boot.sh`, and `tests/bootstrap.Tests.sh`. Tests use inert HTTP/dispatch fixtures; mocked Windows tests on Linux are not live Windows validation. Never execute real bootstraps on a working machine just to test dispatch.
- Also run `bash tests/bootstrap-forward.Tests.sh`, `bash tests/boot.Tests.sh`, `python3 -m unittest discover -s tests -p 'test_linux_*.py'`, and syntax-check `restore.sh`. These fixtures must not install packages, clone production repos, or alter the live home.
- Before publishing, inspect the complete diff for secrets, real account identifiers, machine-specific data, and disallowed adult content. Keep project notes generic and preserve existing LF formatting.

## Android Command-Line Tools cross-platform restoration

- Scoop `android-clt` is Google's Android SDK Command-Line Tools suite; `sdkmanager` is bundled inside it. Neither `adb` alone nor the separately promoted Android CLI is a same-product substitute.
- Linux resolves the current Scoop manifest build, validates its Windows ZIP version, and requires the matching official Linux ZIP/checksum on Google's download page. Do not hardcode a user's backup release, borrow the Windows hash, guess a missing checksum, or silently follow a different latest build. Source drift must block explicitly.
- Package planning is dry by default but may fetch public release metadata. Archive download/use requires a distinct user terms attestation and explicit new SDK directory; `--execute` alone is not consent. Do not infer acceptance from an old machine's license files. Never pipe `yes` into `sdkmanager --licenses` or manufacture acceptance files. A user's explicit authorization applies only to their scoped run, not future users.
- Install layout is `<SDK>/cmdline-tools/latest/{bin,lib,...}`, not an extra nested `cmdline-tools`. Preserve launcher executable bits, verify SHA-256 before extraction, reject unsafe ZIP paths/symlinks and existing destinations, and never change shell profiles implicitly. Java compatibility must be tested separately; metadata/build matching is not runtime validation.
- Keep tests synthetic and offline. Only a separately authorized isolated smoke test may download/run the real SDK, with temporary HOME/Android state and no live-home or backup mutation.

## AnyDesk Linux package versus Windows state

- Use the official HTTPS DEB index to resolve AnyDesk's current Linux amd64 version, filename, size and SHA-256 dynamically. Linux and Windows versions are separate release lines; never borrow the Windows checksum or claim matching version numbers. Missing/ambiguous metadata, unsafe URLs and unsupported architectures must block before installation.
- `anydesk` and WinGet `AnyDesk.AnyDesk` are duplicate package intent covered by one Linux action, NOT permission to import Windows AnyDesk identity, unattended passwords, credentials or service configuration. Keep backed-up state preserved and inactive.
- Vendor DEB/RPM packages include the AnyDesk service and may start it during installation. Require separate AnyDesk terms attestation and explicit service permission before any selected change. A user's scoped personal-use authorization is not blanket acceptance for future users or other products. Never install during a dry review, start the service just to test, or purchase a license implicitly.
- Official portable TAR archives lack unattended access, reboot reconnect and login-screen access; do not silently substitute one for the DEB. Incoming Linux sessions require Xorg; Wayland supports outgoing sessions only. Metadata validation and offline fixture tests are not GUI/network/runtime validation.
- Verify DEB size and SHA-256 before APT, constrain network redirects to the approved vendor, use private temporary files and clean them on failure. Add no global APT source/key or live-home configuration. Keep tests synthetic/offline; system execution remains a separate reviewed action.

## Bitwarden CLI Linux: match OSS variant before bootstrap

- Scoop's `bitwarden-cli` manifest selects `bw-oss-windows-<version>.zip`, not Bitwarden's default non-OSS distribution. Resolve the manifest dynamically and require the corresponding official `bw-oss-linux-<version>.zip` in the exact published CLI release. Never silently switch variant, version, npm distribution, or Windows/Linux hashes. Missing/ambiguous version, asset size or GitHub SHA-256 digest must block. GitHub's asset digest is the comparison source documented by Bitwarden's security FAQ; it is not an independent signature.
- Use the native Linux binary without a Node/npm bootstrap. This conservative adapter targets Debian/Ubuntu glibc x86_64; other architectures stay explicit blockers rather than falling back to npm. A packaged Node runtime does not imply that host runtime compatibility has been validated.
- Dry planning may read public metadata only. Future execution requires an explicit new `--bitwarden-cli-root`; reject existing/symlink destinations and unsafe parents before any selected change, verify size/SHA-256 before archive use, and refuse unsafe ZIP entries. Never add PATH/profile entries, read or inherit vault credentials for probes, log in, unlock, or import Windows Bitwarden state as an installation test. Source/version integrity tests and ELF checks are not real runtime validation; keep development tests synthetic and offline.

## Bun Linux baseline: exact official product and opt-in root

- Bun has official native Linux builds; never replace Scoop `bun` with another runtime or an unrelated package. Read Scoop Main's current Bun version/Windows asset URLs and match the exact published stable `oven-sh/bun` release dynamically. Require the Linux x64 baseline ZIP, official asset SHA-256 and `SHASUMS256.txt`; verify that checksum text's own size/digest before cross-checking Linux and Windows assets. Unknown/missing/ambiguous metadata remains blocked, not a guessed latest version. No user-specific or current-release data belongs in production code.
- Baseline is not CPU-independent: installation requires glibc x86_64 and SSE4.2. Other architectures remain explicit blockers in this conservative adapter even when upstream supports them. Source checks, ELF checks and synthetic fixtures are not real runtime or Windows-state validation.
- Planning is dry by default and reads only public manifests/release metadata/checksum text. Future installation needs explicit `--execute --select bun --bun-root /absolute/new/directory`; a root flag alone never executes. Reuse Bitwarden's descriptor-relative parent/no-replace publication helpers, verify archive size/SHA before extraction, accept only the exact baseline ZIP layout, and never run Bun, edit PATH/profiles, import credentials/state or bootstrap package dependencies. Mixed Bun/global-manager selections without isolated runtime/destination preflight must fail before mutation. Keep BCU and all other package declarations/blockers unchanged in a Bun-only step.

## Full native package inventory: exact variants and safe publication

- Linux availability is not permission to substitute products, remove declarations, accept new vendor terms or activate Windows state. Preserve explicit Windows-only blockers (including BCU) and report all remaining names/reasons together. Never modify a private removed-packages list without an explicit removal request. See `docs/linux-native-package-review.md` for source contracts and unresolved cases.
- Match current authoritative Windows manifests dynamically to exact official Linux releases. Scoop `nodejs-lts` needs an actual LTS entry in Node's index, not distro `nodejs`; Windows archives can be `.7z` rather than `.zip`. Scoop **Versions** `opencode2` uses native `@opencode/cli-*` npm artifacts with SHA-512 integrity, not the default v1 GitHub release. `herdr`'s repo-local preview channel is not upstream stable. Mike Farah `yq` is not the unrelated Python package. Never hardcode a user's version, checksum, source identity or destination.
- Current native adapters conservatively support Debian/Ubuntu glibc x86_64. Resolve official asset hashes, require exact provenance and fail closed on unknown metadata/variants. A checksum source is not an independently verified signature. Bun baseline still needs CPU/glibc checks; Node includes controlled internal symlinks and needs stricter archive traversal rules than a one-binary ZIP.
- Default planning may fetch public metadata/checksum text only. Native installation is a separate opt-in with explicit new per-product `--native-root NAME=PATH`; validate every selected root before any changes. No default live-home destination, PATH/profile changes, native execution, npm postinstall, service setup, credential import or account probes. Keep downloads/decompressed archives bounded; reject traversal, duplicate/special members and escaping links before atomic descriptor-relative no-replace publication. Native adapters reuse Bitwarden's safe parent/publication helpers: retain cross-adapter regression coverage when changing those helpers.
- Synthetic offline tests are installation-logic evidence, not a real product smoke test. No production payload inspection or actual product installation belongs in development tests. After merging safe changes, only rerun the dry package planner against recovered offline manifests; source/checksum drift must remain an explicit blocker. Planned package-manager commands still need separate interpreter, PATH, build-dependency and destination validation.
- Independent review found inherited pnpm/uv/Go/global and Python rebuild commands lacked complete runtime/build/prefix preflight. They now remain explicit blocked actions with original declarations/commands preserved for review; even a hand-built planned action of those kinds must fail before any selected mutation. Do not re-enable them merely because pnpm/uv/Node binaries can be downloaded. First implement reviewed isolated tool/cache/venv destinations, interpreter/build checks and install-script policy, with offline tests. APT executable availability and all candidates are preflighted before installation.

## Google Workspace CLI: official native archive instead of npm downloader

- Preserve the `@googleworkspace/cli` declaration. Its Linux-only `gws-archive` route resolves the exact stable registry version/integrity to the same official GitHub tag and GNU x86_64 archive, with asset size/SHA-256 and a digest-verified companion checksum. Never infer safety from skipped npm scripts: upstream `run.js` starts the downloader again when its binary is absent. The native route does not install the wrapper or require/discover/invoke Node/pnpm.
- Future native installation needs explicit `--execute --select @googleworkspace/cli --gws-root /absolute/new/root`. A root alone is dry metadata. Reject live-home/system/source/backup/other selected root overlap, existing destinations and unsafe ancestors before changes; bound archive decompression, require exact upstream regular-file layout and ELF64 x86_64, publish descriptor-relative no-replace. No CLI probes, credentials, PATH/profile/config activation, login or Windows-state import. Proposed HOME/config/cache/temp/work paths are not an OS sandbox or runtime validation; upstream dotenv ancestor loading still needs separate runtime review. See `docs/linux-google-workspace-cli.md`. Vercel/Graphifyy/WACLI and every generic global-command execution gate remain unchanged.

## WACLI: Windows client VSS is not Diskshadow
- `Diskshadow.exe` is documented for Windows Server, not Windows client. Do not use it as the Windows 10/11 requester or silently substitute sequential per-volume snapshots. Use the native VSS requester APIs with one `StartSnapshotSet`, `AddToSnapshotSet` for every required unique local volume, then one `DoSnapshotSet`; membership is fixed when snapshot creation begins.
- Explicitly enumerate every approved source root and required volume; unsupported, missing, network, reparse/mount or otherwise unprovable membership must fail closed. Never discover a real account or live HOME as a development fixture. The generic existing per-volume VSS helpers are not a WACLI boundary backend.
- Writerless VSS supplies crash consistency only; it is not WACLI application consistency, a guarantee of usable state, or restore activation. Restore scripts intentionally do not activate or remap WACLI payloads.
- Root discovery is metadata-only: include the profile tree (including its `store` and config), metadata `storePath`, legacy `%USERPROFILE%\.wacli`, and explicitly referenced config/media roots. Never read a live SQLite database to discover media paths. A referenced external root that is missing or unavailable must fail the backup.
- **Media coverage is proved after the copy, not before (2026-10-27).** The blanket "external-media completeness is unproven, fail closed" gate is gone — it blocked every daily backup from 2026-10-26 onward. `Get-WacliMediaReferences` now scans the held-VSS payload: for every SQLite database in the payload it enumerates non-virtual tables, reads each table's `PRAGMA table_info`, and queries `SELECT DISTINCT local_path` wherever that column exists. Each reference is then classified as inside an enumerated root (already in payload), outside every root (copied into `media\` with SHA-256 verification), or absent from disk (recorded as `missing-at-backup-time` with a loud warning). `media-map.json` + `root-map.json` v2 record `mediaReferenceCoverage = proven-complete`.
- Path-column contract: `local_path` is the only supported local column; `direct_path` is a WhatsApp CDN route and is ignored. Any other path-like column throws — schema drift fails closed instead of silently dropping coverage, and a payload with no `local_path` table at all also throws.
- The existing Windows source guard remains strict for every live/non-VSS path. Only the exact WACLI profile root may be excluded from the later generic live copy after the native helper has successfully verified and exported its held-VSS payload. Every other WhatsApp subtree remains blocked. CMake plus `g++`/`make` and `sqlite3` on PATH are required; missing build tools, unreadable databases or native VSS failures are fatal, never a live-copy fallback.
- Linux fake-backend tests and Windows cross-compilation are source/API evidence only, never Windows runtime validation or a successful account backup. No direct-copy fallback, source checkpoint, `immutable` retry, sidecar deletion, or plaintext publication may bypass these gates.
- The held-copy transaction must resolve every explicit root and required volume before one `DoSnapshotSet`, inventory every root from verified shadow devices, copy and verify bytes while the same set is held, close shadow file handles, then release the whole set. After snapshot creation never read source contents from live drive paths. Fail on unsupported/missing roots or members, or any copy, inventory, verification or cleanup error; do not omit WAL/SHM/journal/media files. The private shadow-stage tree is ACL-protected and discarded on failure; export to the backup payload is separately byte-verified. None of this certifies app consistency or restore readiness.

### ⚠️ two traps in that flow (both cost a debugging round on 2026-10-27)

1. **never join `pragma_table_info` over `sqlite_master`** to find path columns. The join walks every table including FTS5 virtual tables, and the `sqlite3` bundled with scoop's `android-clt` (`scoop\apps\android-clt\current\platform-tools\sqlite3.exe`, the one on PATH here) is built WITHOUT the fts5 module: it dies `Error: stepping, no such module: fts5` with exit 1 for the whole query even though the ordinary tables read fine. `sqlite_compileoption_used('ENABLE_FTS5')` is missing too (`no such function`), so you cannot even probe for it. **enumerate first, then inspect**: `SELECT name FROM sqlite_master WHERE type='table' AND (sql IS NULL OR sql NOT LIKE 'CREATE VIRTUAL TABLE%')`, then one `PRAGMA table_info('<table>')` per table. The legacy `%USERPROFILE%\.wacli` database is exactly the schema that triggers this (it has `messages_fts*`); the current `%APPDATA%\mainframe\accounts\whatsapp\...\wacli.db` does not.
2. **pin `-G 'MinGW Makefiles'` when building the helper.** This box has no MSVC; a bare `cmake -S ... -B ...` picks the Visual Studio generator and fails. `Get-WacliVssBackupExecutable` passes `-G 'MinGW Makefiles' -DCMAKE_MAKE_PROGRAM=<make>` and throws loudly when `make` or `g++` is missing. It also reads `CMakeCache.txt` and recreates the build dir when a cached `CMAKE_GENERATOR` differs, otherwise the stale cache wins and configuration fails confusingly. Cold build ~8.6s, incremental 0.1–0.3s — the rebuild on every backup run is expected, not a bug.

## Headless vault unlock: mobile approval via ntfy relay (2026-10-26)

- Headless restores on remote Linux boxes/containers without interactive tty cannot prompt via `getpass`.
- `linux_real.py` uses mobile approval push: configured via `ntfyTopic` in `mainframe.config.json`, `MAINFRAME_NTFY_TOPIC` environment variable, or `--ntfy-topic <topic>`. since 2026-10-31 the topic is **required** -- there is no public default.
- Remote runner generates an ephemeral RSA-2048 keypair (`vault-tab.key`) and single-use session topic (`mf-vault-<token>`).
- Runner dispatches an urgent push notification via `ntfy.sh` with actionable click link to `https://fahadbinhussain.github.io/mainframe/docs/vault-tab.html#k=<pubkey>&sid=<session_topic>`.
- Client-side zero-knowledge encryption & 1-tap biometric approval: public key and session ID stay in the URL fragment (`#`), never sent to GitHub Pages servers.
- `docs/vault-tab.html` supports WebAuthn platform biometrics (fingerprint/face): users enroll once by saving their master password to local device keystore (AES-256-GCM derived via PBKDF2), after which future headless restore requests present a 1-tap "Approve with Fingerprint" button.
- Tapping approve verifies biometrics via `navigator.credentials.get()`, decrypts the local credential, encrypts with the runner's ephemeral RSA-OAEP (SHA-256) public key, and transmits ciphertext to `https://ntfy.sh/<session_topic>`. No typing master passwords on every restore.
- Relay server (`ntfy.sh`) sees only ciphertext; without the private key on the remote runner, the relay cannot decrypt secrets.
- Remote runner polls `https://ntfy.sh/<session_topic>/raw?poll=1` (and `~/Downloads/mainframe-vault-pass.enc` fallback for local runs), decrypts using openssl `pkeyutl -decrypt`, unlinks the private key immediately, and unseals vault secrets unattended.
- If no ntfy topic is configured or push fails, logs visible warning and keeps the manual tab URL + local Downloads polling active. Zero silent degradation per fail-loud contract.
- **bitwarden cli non-interactive contract (2026-10-27)**: `bw login <email>` and `bw unlock` require `--passwordenv <VAR_NAME>` to read credentials from the environment. Without `--passwordenv`, `bw` attempts interactive tty input and fails immediately when headless with `You are not logged in.`.
- **bitwarden config server requires logout (2026-10-27)**: `bw config server <url>` fails with `Logout required` if bw is already authenticated. Always check `bw status` first; only reconfigure server when `serverUrl` differs, logging out first if authenticated.
- **select repo owner github token from vault for private release download (2026-10-27)**: when multiple GitHub accounts exist in Bitwarden, taking the first token alphabetically matches an unrelated account (`algojectt` etc.) which gets 404 from GitHub on private backup repos like `FahadBinHussain/mainframe-production/releases/latest`. `linux_real.py` must match `repo_owner` first, matching `boot.ps1`. In addition, `github_json` must pass `User-Agent: mainframe-real/1.0`, and asset downloads for private releases must use `asset.get('url')` with `Accept: application/octet-stream` rather than `browser_download_url`.

## Universal 1-tap mobile vault approval for all restores (2026-10-27)

- **Platform-agnostic standard**: 1-tap biometric approval on the user's phone is the universal standard for ALL restore flows — Windows (`boot.ps1`), Linux (`linux_real.py`), and future platforms.
- **Single-unlock lifecycle**: A single 1-tap biometric approval provides the Bitwarden master password, unsealing `bw-email.enc.json` (resolving account email without typing), authenticating `bw login` via `--passwordenv`, and minting the session key via `bw unlock --raw --passwordenv`. The user never has to unlock multiple times.
- **Google-prompt full-screen approval via ADB**: When an Android device is attached via USB or Wi-Fi (`adb devices`), the runner automatically wakes the display (`adb shell input keyevent KEYCODE_WAKEUP`) and immediately launches the approval prompt full-screen (`adb shell "am start -a android.intent.action.VIEW -d '<url>'"`). This eliminates having to swipe down or interact with the notification shade.
- **Stale hash fragment / tab reuse gotcha**: Android Chrome reuses existing activity tabs on intent delivery. Because the session public key and relay ID live in the URL fragment (`#k=...&sid=...`), `docs/vault-tab.html` listens to `hashchange` and triggers `location.reload()`, ensuring fresh sessions instantly update instead of showing "Missing public key".
- **PowerShell shared module (`vault-approval.psm1`)**: Provides .NET native RSA-2048 keypair generation (`ExportSubjectPublicKeyInfo`), RSA-OAEP SHA-256 decryption, ntfy push dispatch, ADB auto-popup, and relay long-polling with zero external dependencies.
- **Fail-loud manual fallback (Rule 8)**: If 1-tap mobile approval times out or fails, runners display a visible warning naming the failure and fallback mechanism loudly before prompting for manual password entry.
- **1-hour session TTL & on-demand 1-tap re-approval (2026-10-27)**: Bitwarden CLI has no default auto-lock TTL for CLI sessions, which previously allowed `session.key` to remain valid on disk indefinitely. `vault-secret.psm1` now enforces a 60-minute TTL (configurable via `MAINFRAME_VAULT_TTL_MINUTES` or `vaultTtlMinutes` in `mainframe.config.json`). When `session.key` is older than 60 minutes, `Get-VaultSession` purges `session.key` and runs `bw lock`. `Ensure-VaultSession` triggers 1-tap mobile approval on demand (`Get-VaultMasterPassword`), auto-launching the prompt on the attached phone or sending ntfy push, obtaining a fresh 1-hour session token seamlessly without typing passwords. `vault-lock.ps1` locks the vault immediately on demand.
- **Number matching & host provenance (2026-10-27)**: To protect against MFA fatigue, prompt bombing, and distinguishing legitimate agent requests from unauthorized triggers during the day, approval requests generate a cryptographic 2-digit verification code (`code`), requesting hostname (`host`), and context (`ctx`). The runner terminal outputs `VERIFICATION CODE: [ XX ]`, and `docs/vault-tab.html` renders a prominent glowing verification card showing that code, hostname, and action. Users only approve if the code on their phone screen matches the number printed on their terminal monitor.
- **Agent, harness & model provenance (2026-10-27)**: Approval requests include full caller identity (`agent` and `model`) across terminal banners, ntfy push notifications, and the mobile approval card. Runners resolve identity via explicit `-Agent`/`-Model` args, environment overrides (`MAINFRAME_AGENT_NAME`, `MAINFRAME_MODEL_NAME`, `AGENT_NAME`, `MODEL_NAME`), or automatic ground-truth detection: for Antigravity, runners inspect the active thread's conversation transcript on disk (`<appDataDir>/brain/<convoId>/.system_generated/logs/transcript.jsonl`) for system-injected `Model Selection` settings changes (tail and head), extracting the exact active model (e.g. `Gemini 3.8 Flash (High)`) without hallucination or hardcoding; for OpenCode/Claude/Codex/Aider, runners inspect harness env vars or process ancestry, falling back to `terminal` for interactive human shells. `docs/vault-tab.html` renders animated tags (Rule 10) for host (`💻`), agent (`🤖`), model (`🧠`), and action context (`⚡`), and updates the header badge and description to clearly identify who is requesting vault access.
- **cross-agent 1-hour session reuse & stampede mitigation (2026-10-28)**: vault unlock is shared across all agents on the box via `%APPDATA%\mainframe\accounts\bitwarden\session.key`. 1-tap mobile approval unlocks the vault once for 60 minutes for ALL agents (Antigravity, OpenCode, Claude Code, terminal). Previously, transient Node/Bitwarden CLI failures (concurrent execution locking `data.json`, stderr output breaking JSON parse) caused `Test-VaultSession` and external scripts (`get-session.ps1`, `unlock.ps1`) to mistakenly conclude the vault was locked or delete `session.key`, triggering duplicate approval prompts on phone within the same hour. `Test-VaultSession` now passes `--session` explicitly and retries once before declaring locked. `Wait-VaultApprovalCiphertext` in `vault-approval.psm1` polls disk for fresh `session.key` writes while waiting for approval, instantly unblocking concurrent agent runs without asking for duplicate approvals.

### stale requests must say stale, not "approved" (2026-10-30)

a notification that outlived its runner used to keep its Approve button and even
report success after a tap nobody was listening for. the card now knows the
runner's deadline, so an old request reads "Stale request" and refuses to send.

- **the link carries the deadline.** both runners append `&exp=<unix seconds>`
  to the fragment, derived from their own wait window: `TAB_WAIT_SECONDS` (600)
  in `linux_real.py`, `-TimeoutSeconds` (300 default, 600 from
  `Ensure-VaultSession`) in `vault-approval.psm1` via
  `Get-VaultApprovalUrl -ExpiresInSeconds`. do not hardcode a separate number --
  if the wait grows, `exp` grows with it.
- **the runner also publishes a marker when it gives up.** `Send-VaultRequestExpired`
  (PowerShell) and `publish_request_expired` (Python) post
  `{"mf":"expired","at":<epoch>,"host":..,"code":..}` to the same session topic
  before returning timeout (and when another agent unlocked first). the card
  polls `https://ntfy.sh/<sid>/json?poll=1` every 5s and flips an already-open
  tab to stale, which covers clock skew.
- **the page fails closed.** on stale it drops the countdown, hides the code,
  the form and the fingerprint button, and `transmitCiphertext` refuses with
  "stale request — nothing was sent". success text says "it unlocks within a few
  seconds", never a bare "approved".
- **poll loops must skip marker bodies.** `raw?poll=1` returns every message on
  the topic, so both runners filter lines matching `^\{\s*"mf"\s*:` before
  treating a line as ciphertext. use `Invoke-WebRequest` and read `.Content`
  here: `Invoke-RestMethod` parses a JSON body into an object, so a marker stops
  looking like text and the filter silently misses it (found 2026-10-30).
  superseded 2026-10-31: `Test-VaultApprovalCiphertext` is stricter than the
  marker regex -- a line is ciphertext only if it is 344 base64 chars decoding
  to a 256-byte block that decrypts with the request's own key, so markers,
  garbage, and another session's ciphertext are all skipped.
- legacy links without `exp` still work but the card says it cannot tell when
  they expired -- honest, not a silent pass.

### the approval channel is only as private as its topic (2026-10-31)

`fahad-vault-restore` was a hardcoded public ntfy topic: anyone could read every
request (host, agent, code, pubkey, sid), push fake approval cards to the phone,
and post garbage that killed a live approval.

- **no default topic.** `Get-VaultNtfyTopic` (exported by `vault-approval.psm1`)
  resolves `-Topic` -> `MAINFRAME_NTFY_TOPIC` -> `ntfyTopic` in
  `mainframe.config.json` (script dir, cwd, `~/.config/mainframe/`), and throws
  with the searched paths when nothing is set. never reintroduce a literal topic
  in code -- it runs on a public server.
- **one resolver, both runners.** `monitor/apps/api/vault-unlock.ps1` calls the
  module resolver instead of duplicating env->hardcode. it also passes
  `-Agent`/`-Model` from the session to `Send-VaultApprovalNotification`; without
  them the push title dropped the caller and read like an attacker's.
- **qoder is detected before opencode.** qoder sets
  `OPENCODE_DISABLE_CHANNEL_DB=1` for compatibility, so an opencode-first check
  reported `opencode` with an empty model. `Get-CallerIdentity` tests
  `QODER_CLI`/`QODER_PRODUCT_ID`/`QODER_SESSION_TYPE` first; qoder has no model
  env var, so the model stays blank there and `MAINFRAME_MODEL_NAME` fills it.
- **no passwords on argv.** `bw unlock $password --raw` put the master password
  in the process command line, readable by any same-user process. both
  `bitwarden.com/unlock.ps1` and `monitor/apps/api/vault-unlock.ps1` now set
  `BW_PASSWORD` for the call and drop it in `finally`.
- **human step, once per machine.** the phone must be subscribed to the topic in
  `mainframe.config.json`; ntfy returns 200 with zero subscribers, so a wrong
  topic looks like success locally and only fails at the phone.
- **verifying the phone path.** `adb shell am start -a
  android.intent.action.VIEW -d "ntfy://ntfy.sh/<topic>"` subscribes the app
  directly, no taps needed. send a real push and press HOME first: while the
  app is foregrounded on that topic it posts no system notification at all, so
  only a backgrounded push proves the subscription (`dumpsys notification`
  shows `pkg=io.heckel.ntfy importance=4 actions=1`). `Open-VaultApprovalOnPhone`
  opens the card in the default browser; the first screenshot right after
  `am start` catches a blank page -- it paints ~5 s later (checked 2026-10-31,
  android 13, 1080x2400).
- **live relay test.** `MAINFRAME_LIVE_RELAY=1 python -m unittest
  tests.test_linux_real_vault_relay_live -v` drives the python runner against
  real ntfy and real openssl: junk and other-key ciphertext must be skipped,
  ours must decrypt, and a timeout must publish the expired marker. it runs on
  windows too -- this path is only the openssl cli + urllib, the linux-only
  parts (`/proc` ancestry, `bw`) are not in it. `raw?poll=1` can come back
  empty for a moment right after a post, so the marker check polls instead of
  reading once (found 2026-10-31).

