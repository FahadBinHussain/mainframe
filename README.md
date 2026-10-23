# mainframe

Windows machine-state backup/restore, with Linux-native offline recovery and package planning.

`mainframe` captures a Scoop app snapshot plus persisted Scoop settings, then restores them on another machine. It defaults to latest bucket versions on restore.

It can also restore native Windows apps that should not be Scoop-owned. These are service-style exceptions for apps where Scoop's portable package loses important behavior.

## Native bootstrap entry points (Windows and Linux)

Use the platform's native shell: **PowerShell on Windows**, **Bash on Linux**.
Both launchers announce their selected path before downloading or running the
child, support a no-change route preview, and fail rather than silently switching
platforms, downloading a missing local child, or ignoring a failed download/child.
They share a launch contract, **not identical restoration features**.

### Windows: PowerShell

The existing Windows restore requires **PowerShell 7 (`pwsh`) already installed**;
this prerequisite is unchanged. Windows PowerShell 5.1 is not supported by
`boot.ps1`, and the launcher does not install or silently substitute a runtime.
Run this in PowerShell 7:

```powershell
& ([scriptblock]::Create((Invoke-RestMethod 'https://raw.githubusercontent.com/FahadBinHussain/mainframe/main/bootstrap.ps1')))
```

It prints `mainframe: selected Windows -> boot.ps1` and delegates to the existing
`boot.ps1` unchanged, including its elevation and vault prompts. The launcher's
fail-loud contract does not change the restore's existing internal policies.
`bootstrap.ps1` rejects Linux and other operating systems with guidance to use
Bash on Linux; it no longer dispatches Bash from PowerShell.

### Linux: Bash (no PowerShell dependency)

**Linux now has a lossless archive-recovery path, explicit native export targets,
and a package planner, not a complete operational Windows-to-Linux restore.**
See the [item-by-item coverage inventory](docs/linux-restore-coverage.md) for every
persist app, Windows restore action, secret boundary, and remaining blocker.
Windows DPAPI/browser logins, Windows-only apps, services, task XML, registry,
private build patchers, and live account-helper activation are not ported. No
global agent instructions are changed. No unqualified “100% working” claim is made.

From a **reviewed checkout**, Bash and Python **3.10+** can inspect existing quick
and persist ZIPs without reading member payloads, decrypting anything, installing
packages, or changing settings:

```bash
bash ./restore.sh /path/to/backup-directory --inventory
# Equivalent launcher route:
bash ./bootstrap.sh -- --restore /path/to/backup-directory --inventory
```

Full mode requires both `mainframe-quick.zip` and `mainframe-persist.zip` (or the
legacy combined `mainframe-backup.zip`). `--mode quick` explicitly excludes the
persist ZIP and is not a full restore. Use an input directory containing ZIPs only;
unexpected loose data fails preflight rather than being silently omitted.

Explicit recovery writes a **new offline directory**, never the live home:

```bash
bash ./restore.sh /path/to/backup-directory --recover \
  --destination /path/to/new-offline-export --apply-portable
```

The export retains verified original ZIPs in `raw-archives/`, materializes safe
members in archive-separated `recovered/` trees, optionally exports native-path
candidates into `home-staging/`, and writes a private `restore-manifest.json`.
Encrypted nested secrets remain opaque; unsafe paths, special entries, and
collisions remain preserved in the raw ZIP rather than being activated. Outputs
use restrictive permissions; existing/symlink destinations are rejected. Recovery
streams and verifies bytes, checks free space, and limits expanded data to 100 GiB
and any one member to 8 GiB by default. Limits can be raised explicitly with
`--max-expanded-bytes` and `--max-member-bytes` after reviewing metadata.

An additional **opt-in conversion**, separate from candidate copying, is available:

```bash
bash ./restore.sh /path/to/backup-directory --recover \
  --destination /path/to/new-converted-export --convert-portable
```

The first explicit adapter generates an offline `.gitconfig` subset from the
root Windows export using installed Git as a parser (includes disabled). Only
`core.autocrlf`, `core.eol`, `core.safecrlf`, `diff.algorithm`,
`merge.conflictstyle`, and `color.ui` have supported enum mappings. Windows
`autocrlf=true` becomes `input`; `eol=crlf/native` becomes `lf`. Unsupported
values, duplicate keys, and all identity/helper/include/path/credential settings
are blocked with value-free decisions in the private manifest. Original bytes
remain intact. No supported settings means no generated file; competing source
configs mean no winner. A missing Git parser or malformed input is a conversion
blocker, not loss of the original archive. No other app is converted yet.

`--convert-portable` requires `--recover`; it can be combined with
`--apply-portable` but neither implies the other. `conversion_counts` records
`converted-subset` versus `blocked` sources in `restore-manifest.json`;
`conversion_status=review-required` is not success for every setting and is not
activation. The [implementation plan](plan.md) separates preservation,
conversion/staging, future native activation, and impossible/excluded state.

Exit **3** means a usable inventory/export exists but operational restore remains
incomplete. Exit **2** means invalid input, preflight, or recovery failure. A
verified raw copy is not an installed app, usable login, or activated setting.
Do not automatically activate `home-staging/`: paths, layouts, plugins, and
identities still need application-specific review. Source ZIPs are never modified.

The package planner is dry by default and supports **Debian/Ubuntu x86_64 or
aarch64** only. It accounts for every allowlisted item; unsupported software,
unvalidated vendor sources, and variant/version drift are explicit blockers.
APT executables and candidates are checked before executing any selected install.
Global pnpm/uv/Go installs and Python rebuilds remain blocked until runtime/build,
install-script policy and isolated-destination preflights are validated. Original
package declarations and `pip-freeze.txt` remain intact.

Scoop's `7zip19.00-helper` is explicitly reported as `covered` by native `7zip`,
with `covered_by: "7zip"` and no separate install command. This maps the extractor
role, not the Windows 19.00 version pin, Scoop hooks, or GUI/registry settings.
The planner emits one native `7zip` action even for a helper-only allowlist;
explicitly selecting the helper selects that native action and its APT candidate
check. Other blockers still prevent an unqualified full execution.

```bash
python3 ./linux_packages.py
# Add --backup-root /path/to/recovered/quick-root to include pip-freeze.txt.
# --execute changes the machine; --select NAME permits only an explicitly
# partial reviewed subset. Neither flag is needed for inspection.
```

**Android: same toolkit on both systems.** Scoop's `android-clt` is the Android
SDK Command-Line Tools package; `sdkmanager` is one tool inside that package.
Linux uses Google's corresponding Linux ZIP, not `adb` or the separate Android
CLI. The planner reads the current Scoop manifest, then matches its build to the
Linux archive and SHA-256 on [Google's official page](https://developer.android.com/studio).
Missing/mismatched metadata blocks the action rather than guessing a release.
Planning reads public metadata only; it never downloads or runs the SDK.
This archive adapter supports x86_64; aarch64 remains explicitly blocked.

After personally reading and accepting the [Google SDK terms](https://developer.android.com/studio/terms.html),
an explicitly selected install into a **new** directory is:

```bash
python3 ./linux_packages.py --execute --select android-clt \
  --android-sdk-root /path/to/new/android-sdk --android-sdk-terms-accepted
```

The installer verifies SHA-256 before extraction and creates
`cmdline-tools/latest/bin/sdkmanager` under that SDK root. It never invokes
`sdkmanager --licenses`, writes license acceptance files, installs Java or extra
SDK packages, or changes shell profiles. Set `ANDROID_HOME` to the SDK root and
add `$ANDROID_HOME/cmdline-tools/latest/bin` and `$ANDROID_HOME/platform-tools`
to `PATH` yourself. `platform-tools` starts empty; this does not install `adb`.
Matching the toolkit build does not prove Java/runtime compatibility or full
Windows SDK-state restoration.

**AnyDesk: official Linux package, not Windows state.** On Debian/Ubuntu x86_64,
the planner resolves the current AnyDesk DEB version, URL, size and SHA-256 from
the [official vendor index](https://deb.anydesk.com/dists/all/main/binary-amd64/Packages).
Planning downloads metadata only. Missing, conflicting or unsafe metadata and
unsupported architectures remain blockers. Linux and Windows versions have
independent release numbering; no Windows-version equivalence is claimed.
`AnyDesk.AnyDesk` WinGet package intent is explicitly covered by the single
native `anydesk` action, even when only the WinGet declaration exists.

Only after accepting the vendor terms and reviewing the service implications,
a future, explicitly authorized system install can use:

```bash
python3 ./linux_packages.py --execute --select anydesk \
  --anydesk-terms-accepted --anydesk-service-allowed
```

Both AnyDesk-specific flags are required before any selected changes. They are
not inferred from `--execute`, another product's consent, or a previous backup.
The installer checks the downloaded DEB's SHA-256 and size before passing it to
APT; it adds no repository or signing key. **The vendor DEB installs its service
and may automatically start it**, which is why service permission is separate.
Do not execute this command during a dry restore review. No Windows AnyDesk ID,
credentials, unattended password or service settings are imported. According to
[vendor requirements](https://support.anydesk.com/docs/supported-operating-systems),
incoming Linux sessions need Xorg; Wayland supports outgoing sessions only.
Package resolution and offline tests do not validate GUI, networking or
unattended-access behavior, and this adapter does not purchase a license.

**Bitwarden CLI: matching official OSS binary, not a vault restore.** Scoop's
`bitwarden-cli` currently selects the OSS build. On Debian/Ubuntu x86_64 the
planner reads that manifest and requires the same version and OSS variant in
the [official Bitwarden release](https://github.com/bitwarden/clients/releases),
including a published SHA-256 digest and archive size. It never substitutes the
default non-OSS build, an npm package, a Windows checksum, or another version.
Missing or ambiguous metadata blocks the action. Other architectures remain
unsupported by this adapter. Planning fetches public metadata only.

For a separately authorized future installation into a **new** directory:

```bash
python3 ./linux_packages.py --execute --select bitwarden-cli \
  --bitwarden-cli-root /path/to/new/bitwarden-cli
```

The native binary needs no Node/npm bootstrap. The adapter verifies the archive
size and SHA-256 before accepting its executable; existing destinations and
unsafe archives are refused. Installation requires glibc, Linux `renameat2`,
`/proc/self/fd`, and ancestors owned by root or the installing user. Staging and
publication are anchored to an opened parent directory, not a later path lookup.
It does not change PATH or shell profiles, log in,
unlock a vault, read credentials, or import Windows Bitwarden state. Invoke
`/path/to/new/bitwarden-cli/bw` manually after reviewing the installation.
[Bitwarden's checksum guidance](https://bitwarden.com/help/security-faqs/)
describes comparing SHA-256 against the GitHub asset digest. Metadata matching
and synthetic tests do not establish runtime compatibility or a usable session;
the real binary has not been run as part of this dry restore review.

**Bun: same official runtime, native Linux baseline.** On glibc x86_64 the
planner reads the current [Scoop Bun manifest](https://raw.githubusercontent.com/ScoopInstaller/Main/master/bucket/bun.json)
and requires the exact stable [official Bun release](https://github.com/oven-sh/bun/releases).
The Linux baseline ZIP's SHA-256 must match both GitHub's asset digest and the
release checksum file; that checksum file is itself verified against its asset
size and digest. Missing or ambiguous metadata stays blocked. No version/hash
is hardcoded, and no alternative runtime or shell installer is substituted.
[Bun's Linux requirements](https://bun.com/docs/installation) still apply:
baseline requires SSE4.2, not arbitrary x64 hardware. This adapter conservatively
supports glibc x86_64 only, not every platform supported by Bun itself.

A separately authorized future partial installation would use `--execute
--select bun --bun-root /absolute/new/bun-directory`. The root must be new;
supplying it alone is still a dry run. The installer validates platform/root
before selected changes, verifies archive size/SHA-256 and exact ZIP/ELF layout,
and publishes without replacing existing state. It never runs Bun, edits PATH
or profiles, imports Windows state or credentials, or installs dependencies.
Mixed global-manager commands without isolated runtime/destination preflight
are rejected before mutation. Checksums are not independent release signatures,
and synthetic tests do not establish actual Bun runtime compatibility.

**Other same-product native tools.** The planner now resolves official Linux
artifacts for `bun`, `cloudflared`, `deno`, `nodejs-lts`, `opencode2`, `pnpm`,
`uv`, and `yq`, conservatively on glibc x86_64. Versions and checksums come
from current authoritative manifests and official release metadata, not a
user-specific backup or a guessed latest download. Source drift stays blocked.
See the [native package review](docs/linux-native-package-review.md) for exact
variant, checksum, platform and remaining-blocker contracts. A separately
authorized future partial install requires `--execute --select NAME` and an
explicit new `--native-root NAME=/absolute/new/directory` for each product.
Supplying roots alone is still a dry run. No PATH/profile, service, account,
Windows-state, npm postinstall or automatic runtime activation is included.

Bun also retains `--bun-root` as a compatible alias for `--native-root bun=PATH`.

Selected package installs are sequential, not transactional. Terms, destination,
and APT metadata checks happen before installs, but a later download or install
can still fail after an earlier package changed the machine. Error JSON includes
the executed actions and failed action; there is no automatic package rollback.

For source preparation only, the remote command requires `curl` and HTTPS CA
certificates. It installs four prerequisites and clones source, **not a backup**:

```bash
bootstrap="$(curl --fail --show-error --silent --location https://raw.githubusercontent.com/FahadBinHussain/mainframe/main/bootstrap.sh)" && bash -c "$bootstrap" -- -- --setup-tools
```

`--setup-tools` supports Debian/Ubuntu-family systems with `apt-get`, requires root
or `sudo`, and rejects an existing `~/Downloads/mainframe` before package changes.
It validates Python 3.10+ after prerequisite installation; an older distribution
Python fails clearly before cloning and requires a separate compatible runtime.
Restore/package modes require their sibling files in a reviewed local checkout;
the single-file remote child does not silently fetch them. A bare Linux bootstrap
now fails without changes instead of misleadingly doing setup as a restore.

### Review and preview

Remote commands trust executable scripts on this repository's `main` branch.
The new Bash launcher URL becomes available there after this change is merged.
Review the scripts first, or use a reviewed checkout. A remote command fetches the
launcher itself even when previewing; the launcher's preview does not download or
execute its child. Local execution uses a sibling child and never falls back to
the network if it is missing. Remote execution downloads only the platform child
into a temporary directory and removes it after success or failure.

From a reviewed checkout, preview the route without downloads or execution:

```powershell
# Windows / PowerShell 7
pwsh -NoProfile -File ./bootstrap.ps1 -DryRun
```

```bash
# Linux / Bash
bash ./bootstrap.sh --dry-run
```

Preview checks platform selection only; it does not validate restore prerequisites,
Linux distribution support, privileges, or the destination. Remove the preview
flag and select an explicit Linux mode to run it. For remote preview, append `-DryRun` to the Windows scriptblock
invocation, or `--dry-run` after `--` in the Linux command above.

Offline tests replace HTTP and child execution with inert fixtures:

```text
pwsh -NoProfile -File ./tests/bootstrap.Tests.ps1
bash ./tests/bootstrap.Tests.sh
bash ./tests/bootstrap-forward.Tests.sh
bash ./tests/boot.Tests.sh
python3 -m unittest discover -s tests -p 'test_linux_*.py'
bash -n bootstrap.sh
bash -n boot.sh
bash -n restore.sh
bash -n tests/bootstrap.Tests.sh
```

The PowerShell test harness can run under PowerShell 7 on Linux for mocked
Windows dispatch and real wrong-platform rejection, but that does not test a live
Windows restore. Bash tests do not install packages or clone the real source.
The existing `da.gd/f85Bj` short link remains Windows-only and unchanged.

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
- `vault-secret.psm1` shared module: vault-native secrets for the account helpers (neon, supabase, vercel, hf, render, cloudflare, cronjob, github, notion, uptimerobot) — reads/writes per-profile tokens in the Bitwarden vault via `Read-VaultSecret` / `Write-VaultSecretToExisting`; requires an unlocked BW session (session.key from `automata-private\bitwarden.com\unlock.ps1` or `$env:BW_SESSION`)
- `account-contract.ps1` checks that every `*-account.ps1` helper keeps the shared mainframe account command contract
- `scoop-allowed.json`, `pnpm-allowed.json`, `uv-allowed.json`, `go-allowed.json`, and `winget-allowed.json` are required desired tool allowlists; backup and restore both require them, restore installs every listed item and fails if an allowed install is missing, and `scoopfile.json` metadata is used only for Scoop apps that were in the backup snapshot. pip has no allowlist: backup writes every installed package pinned to `pip-freeze.txt` (plus the pytorch `+cpu` extra index) and restore runs `pip install -r` on it — `Lib\site-packages` itself is not shipped anymore (it held no user data, 0 editable installs)
- `vercel-account.ps1` manages separate token-only Vercel CLI profiles by email
- `neon-account.ps1` manages separate Neon CLI profiles by email using Neon CLI's per-profile config directory support
- `gws-account.ps1` manages separate Google Workspace CLI profiles by email using `GOOGLE_WORKSPACE_CLI_CONFIG_DIR`; it also reuses those OAuth profiles for Google Search Console API commands
- `gcloud-account.ps1` manages separate Google Cloud CLI profiles by email using `CLOUDSDK_CONFIG`
- `firebase-account.ps1` manages separate Firebase CLI profiles by email using profile-local `XDG_CONFIG_HOME`
- `render-account.ps1` manages separate Render CLI profiles by account email using Render's official `RENDER_CLI_CONFIG_PATH` setting
- `cronjob-account.ps1` manages separate cron-job.org API key profiles by account email for creating, updating, disabling, and inspecting scheduled HTTP jobs
- `cloudflare-account.ps1` manages separate Cloudflare profiles by detected account email, using either API tokens or isolated Wrangler browser auth for Wrangler commands, API calls, zone/DNS inspection, and private state exports (moved to `C:\Users\Admin\Downloads\automata-private\cloudflare.com\cloudflare-account.ps1` in 2026-08-17)
- `github-account.ps1` manages separate GitHub CLI/API token profiles by detected account email for `gh` commands and API calls
- `notion-account.ps1` manages separate Notion API token profiles by account email for API calls, optional `ntn` CLI commands, and page/block inspection
- `microsoft-account.ps1` manages separate Microsoft Graph OAuth profiles by detected account email for delegated Microsoft automation across mail, calendar, contacts, files, tasks, and notes (moved to `C:\Users\Admin\Downloads\automata-private\outlook.com\microsoft-account.ps1` in 2026-08-17)
- `outlook-account.ps1` is a compatibility wrapper around `microsoft-account.ps1` for mail-focused workflows (moved to `C:\Users\Admin\Downloads\automata-private\outlook.com\outlook-account.ps1` in 2026-08-17)
- `hf-account.ps1` manages separate Hugging Face CLI profiles by detected account email using `HF_HOME` and profile-local token paths
- `devvit-account.ps1` manages separate Reddit Devvit CLI profiles by account email, swapping Devvit's official `%USERPROFILE%\.devvit\token` file into per-profile mainframe storage (moved to `C:\Users\Admin\Downloads\automata-private\reddit.com\devvit-account.ps1` in 2026-08-17)
- `reddit-account.ps1` manages separate Reddit API OAuth profiles by account email for posting as your own Reddit account (moved to `C:\Users\Admin\Downloads\automata-private\reddit.com\reddit-account.ps1` in 2026-08-17)
- `reddit-post.ps1` submits Reddit posts/comments through a saved `reddit-account.ps1` profile; it defaults to dry-run unless `-ConfirmPost` is passed (tracked in `C:\Users\Admin\Downloads\automata-private\reddit.com\` alongside reddit-account.ps1 - moved there 2026-10-08)
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

Vercel token-only profiles plus Neon, Google Workspace CLI, Google Cloud CLI, Firebase CLI, Browser UI automation, Render CLI, cron-job.org API, GitHub CLI/API, Notion API/CLI, Hugging Face CLI, and Tailscale profiles are stored under:

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

Moved to `C:\Users\Admin\Downloads\automata-private\outlook.com\microsoft-account.ps1` in 2026-08-17. See that repo's README for usage.

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

Moved to `C:\Users\Admin\Downloads\automata-private\reddit.com\devvit-account.ps1` in 2026-08-17. See that repo's README for usage.

Create and use Reddit API OAuth profiles:

Moved to `C:\Users\Admin\Downloads\automata-private\reddit.com\reddit-account.ps1` (2026-08-17) and `reddit-post.ps1` (2026-10-08). See that repo's docs for usage.

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

The zip is self-contained: it includes `restore.cmd`, `restore.ps1`, `restore-secrets.ps1`, and all backup data. Secrets travel beside it as `secrets/` (a plain `backup.ps1` run) or as a standalone `tool-secrets.zip` — `restore.ps1` restores whichever is present and warns loudly when neither is. For the remote one-liner (`irm https://raw.githubusercontent.com/FahadBinHussain/mainframe/main/boot.ps1 | iex`), secrets ride inside `mainframe-quick.zip` as an AES-256-encrypted entry and are decrypted with the password held in Bitwarden item `mainframe-production`.

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
