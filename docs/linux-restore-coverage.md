# Linux restore coverage: Windows backup inventory

**Status: offline fixture-tested recovery and Git subset conversion; live setup and restore have not been executed.** This document describes the checked-in Linux recovery implementation and the Windows backup/restore source it can inspect. It is a preservation, staging, and bounded conversion contract, not a claim that the Windows machine becomes a native Linux machine.

## Scope and safety boundary

The Linux path is deliberately **offline and non-destructive**:

- `linux_restore.py` reads ZIP central-directory metadata for inventory. Recovery copies each original ZIP byte-for-byte into `raw-archives/`, verifies the copy, and materializes safe members under `recovered/`.
- `--apply-portable` may additionally copy explicitly classified files into a **new** `home-staging/` tree. It never writes the live home directory, activates services, changes global agent instructions, imports credentials, or executes Windows files.
- `--convert-portable` separately opts into the exact Git settings adapter documented below. It reads only the verified root `.gitconfig` for conversion, emits an offline allowlisted subset, and never activates it. No production payload was inspected for development or this coverage review; tests use synthetic fixtures. No secret is decrypted or printed. Encrypted members, nested archives, DPAPI material, and opaque account data remain raw-only/opaque.
- Every native target below is a **staging candidate layout, not confirmed operational**. A staged byte is not proof that its application, plugins, identity, paths, permissions, or behavior work on Linux.
- This is **not the user's requested 100% Linux runtime**. It is a lossless-byte-preservation and selective-native-staging tool with explicit blockers.

## Baseline entry point

`boot.sh` is no longer setup-only in the sense of having one implicit mode; it has explicit modes:

| Invocation | Actual behavior |
|---|---|
| `boot.sh --restore [args]` | Forwards all remaining arguments verbatim to the checked-out `restore.sh`, which invokes `linux_restore.py`. |
| `boot.sh --packages [args]` | Requires `python3` and forwards all remaining arguments verbatim to `linux_packages.py`. |
| `boot.sh --setup-tools` | The only setup mode: validates Linux and Debian/Ubuntu-family support, requires `apt-get`, installs exactly four prerequisites (`git`, `curl`, `ca-certificates`, `python3`), validates that the installed Python is 3.10+, then clones source to `$HOME/Downloads/mainframe` if that target does not exist. An older distribution Python is an explicit setup failure requiring a separate compatible runtime. It does not restore a backup. |
| no arguments or an unknown mode | Fails without changing the system. |

The setup clone is source preparation only. It is not package restoration, account restoration, browser restoration, service activation, or a 100% runtime conversion.

## Persisted application inventory

The following describes application schemas recognized by the classifier, not a required set of installed applications or a particular user’s configuration. Each row states the exact current implementation: either the relative offline staging target in `home-staging/` or the current blocker. **“Candidate” always means layout only; operational compatibility is unconfirmed.** There is no blanket `%APPDATA%`/`%LOCALAPPDATA%` to XDG mapping.

| Persist app | Current implementation | Staging candidate or blocker |
|---|---|---|
| `7zip` | Blocked | Windows GUI/registry settings have no native p7zip import. Raw bytes remain in `recovered/`. |
| `alist` | Native staging candidate | `.local/share/alist/`; layout, permissions, runtime, and config compatibility are unverified. |
| `archisteamfarm` | Native staging candidate | `.local/share/ArchiSteamFarm/`; layout and Linux runtime compatibility are unverified. |
| `autohotkey` | Blocked | AutoHotkey scripts require a deliberate Linux automation rewrite. |
| `bulk-crap-uninstaller` | Blocked | Windows uninstaller has no equivalent state import. |
| `discordchatexporter` | Blocked | Native runtime and settings adapter have not been validated. |
| `ditto` | Blocked | Ditto is Windows-only; retained starred SQLite data is not imported into another clipboard application. |
| `ffmpeg` | Native staging candidate | `.config/ffmpeg/`; target layout is unverified and binaries are not copied as a Linux runtime. |
| `firefox` | Native staging candidate | `.mozilla/firefox/`; profile encryption, version migration, extensions, and paths remain unverified. |
| `ghidra` | Native staging candidate | `.ghidra/`; target layout is unverified; Java/runtime and extensions need review. |
| `git` | Blocked | Scoop Git settings can contain Windows paths/helpers; use separately reviewed `.gitconfig` and native Git setup. |
| `gradle` | Native staging candidate | `.gradle/`; caches and metadata may be staged, but Java/toolchain paths and executability are unverified. |
| `megatools` | Native staging candidate | `.config/megatools/`; layout and credentials/config semantics are unverified. |
| `micmute` | Blocked | Windows audio bindings have no native state import. |
| `mpc-hc` | Blocked | Windows-only player configuration. |
| `mpv` | Native staging candidate | `.config/mpv/`; config/scripts are staged as candidates, but paths, shaders, fonts, and plugins need review. |
| `mpv-git` | Native staging candidate | `.config/mpv/`; same target as `mpv`; version/fork behavior is unverified. |
| `parsec` | Blocked | Windows host/identity state is not a Linux host restore. |
| `proton-vpn` | Blocked | VPN credentials and network integration must be recreated through a native client. |
| `pwsh` | Blocked | Windows PowerShell modules/profiles need explicit dependency and path review; no Windows runtime is staged as Linux-native. |
| `python312` | Blocked | Windows interpreter/native modules cannot be copied into Linux Python. The package planner may rebuild from the recorded pip manifest where compatible. |
| `rclone` | Native staging candidate | `.config/rclone/`; config is sensitive and runtime/remote compatibility remain unverified. |
| `rufus` | Blocked | Windows-only disk utility configuration. |
| `syncplay` | Native staging candidate | `.config/syncplay/`; original Windows layout and player paths remain unverified. |
| `tesseract` | Native staging candidate | `.local/share/tessdata/`; data layout is a candidate only; package/runtime and language compatibility need review. |
| `tor-browser` | Blocked | Browser encryption, profile layout, and version migration are not validated. |
| `v2rayn` | Blocked | Windows frontend profiles need an explicit native client adapter. |
| `vlc` | Native staging candidate | `.config/vlc/`; configuration layout is a candidate only; plugins, paths, and version behavior are unverified. |
| `windhawk` | Blocked | Windows injection/modification framework has no Linux equivalent. |
| `windows-terminal` | Blocked | Windows Terminal has no Linux runtime; preferences need a deliberate terminal port. |
| `x64dbg` | Blocked | Windows debugger state/plugins have no native Linux runtime. |
| `yt-dlp` | Native staging candidate | `.config/yt-dlp/`; config is staged as a candidate; executable/package and plugin behavior are unverified. |

Additional persist data has explicit handling: `flameshot` settings are candidates under `.config/flameshot/`; OBS exports are candidates under `.config/obs-studio/`; qBittorrent exports are candidates under `.config/qBittorrent/` and torrent metadata under `.local/share/qBittorrent/`. These are also staging candidates, not confirmed operational. Unknown persist application/path data is retained raw and marked unresolved.

## Implemented conversion map: Git portable settings v1

`linux_migrations.py` contains a versioned explicit map for root `.gitconfig` to
offline `home-staging/.gitconfig`. It is enabled **only** by `--recover
--convert-portable`; default inventory, ordinary recovery, and
`--apply-portable` alone do not run it. Git must already be installed; nothing
is downloaded. Git parses stdin with `--no-includes`, an isolated environment,
and a timeout. Configured commands and includes are never executed/read.

| Setting | Accepted source values and target semantics |
|---|---|
| `core.autocrlf` | `true` → `input` (LF checkout, normalize CRLF on add); `input` and `false` retained. |
| `core.eol` | `crlf` or `native` → `lf`; `lf` retained. Does not rewrite working files. |
| `core.safecrlf` | `true`, `false`, `warn` retained. |
| `diff.algorithm` | `myers`, `minimal`, `patience`, `histogram` retained. |
| `merge.conflictstyle` | `merge`, `diff3`, `zdiff3` retained; destination Git version still needs review. |
| `color.ui` | `auto`, `always`, `never`, `true`, `false` retained. Other aliases are explicitly unsupported. |

Duplicate supported keys and unsupported values are excluded, with sanitized
decisions. All other settings (including identity, helpers, includes, paths,
signing, URL rewrites, aliases, and default branch) remain blocked/raw-only.
Unknown decisions report counts, not arbitrary key/subsection names that could
contain private identifiers. Values and parser stderr are never reported.
Quoted/multiline input uses Git's grammar; generated output is deterministic,
LF-only and mode 0600. A generated subset is not an equivalent full Git config.

Competing configs across quick/full archives, unsafe members, malformed config,
missing Git, oversized inputs (>256 KiB), and target conflicts cannot silently
pick a winner. No accepted setting means no output file. Output is verified
before publication without overwrite. Original archive/member hashes and
preservation outcomes are independent of conversion blockers.

The manifest now uses schema version 3 with `conversion_status`,
`activation_status`, and (when requested) `conversion_counts` and per-entry
`migration` decisions/output hashes. `review-required` means inspect decisions,
not all settings converted. Runtime status remains `incomplete`, and the CLI
retains exit 3 for incomplete operational restoration, even for a blocked
conversion with successfully preserved originals. No package/setting activation
is performed. See [the phased plan](../plan.md) for the remaining work.

## Source action coverage

This table records the actual source actions, not hypothetical Linux work. Windows actions remain reference evidence; Linux actions are limited to the checked-in planner/recovery behavior.

| Source action | Current behavior and Linux consequence |
|---|---|
| ZIP creation and split archives | Windows backup creates quick and persist ZIPs, using 7-Zip when available or `Compress-Archive`; exclusions and locked-file handling are applied before packaging. Linux retains each supplied ZIP byte-for-byte and verifies SHA-256 of the copy. |
| ZIP metadata inventory | Linux validates ZIP names, traversal, duplicate paths, file/directory collisions, symlinks/special entries, and encrypted members without decrypting payloads. |
| Safe materialization | Safe ordinary members are copied to `recovered/<archive>/<member>` with verification; unsafe/encrypted/special members remain raw-only. Existing destinations, symlinks, and unsafe parent paths are rejected. |
| Explicit native staging | Only classifier-approved targets are copied to a new offline `home-staging/` tree. A collision becomes `staging-conflict`; no overwrite or live-home merge occurs. |
| Git preference conversion | Opt-in six-setting `.gitconfig` adapter above; original preserved, Windows line-ending defaults translated, unknown/identity/command/credential state excluded with explicit decisions. No native activation. |
| Scoop allowlist and version metadata | Windows exports Scoop configuration/app/version intent and persist data. Linux preserves manifests and maps only explicit package names in `APT_MAP`; Windows installers, shims, paths, and post-install hooks do not run. |
| WinGet/native persist | AnyDesk and Directory Opus-style native persist is archived/quarantined as Windows state; no Linux identity, service, or file-manager import is performed. Winget IDs remain unsupported records. |
| APT package mapping | `linux_packages.py` plans Debian/Ubuntu x86_64/aarch64 installs for explicit mappings such as `7zip→7zip`, `ffmpeg→ffmpeg`, `gh→gh`, `git→git`, `go→golang-go`, `python312→python3.12`, `rclone→rclone`, `vlc→vlc`, and `yt-dlp→yt-dlp`. `mpv-git` and `nodejs-lts` are blocked for variant drift rather than silently replaced. APT candidates must exist on the actual host before any selected install. Package planning is dry by default; execution requires `--execute`, and blockers prevent an unqualified full execution. |
| Package holds and version mappings | Recorded Windows/Scoop versions are preserved as metadata/provenance, not silently asserted equivalent to APT versions. The Linux planner has no general package-hold or Windows-version-lock implementation; exact versions requiring holds, repositories, or manual pinning remain a scope item. |
| pnpm globals/config | Windows records `@googleworkspace/cli`, `vercel`, and the global bin directory. Linux plans `pnpm add --global` per allowlist and must normalize the bin directory; native dependencies and authentication remain review items. |
| uv tools | Windows records `graphifyy`; Linux plans `uv tool install graphifyy` without assuming Windows entry points or indexes. |
| Go global | Linux plans `go install github.com/openclaw/wacli/cmd/wacli@v0.15.0` with `sqlite_fts5`; compiler/CGO dependencies and resulting binary behavior require review. |
| pip environment | Windows writes `pip-freeze.txt` with the PyTorch CPU extra index and excludes `site-packages`. Linux may create `.linux-restore-venv` and install the requirements when not blocked; wheels, ABI, native extensions, and index availability can differ. |
| Private source clone/fork patchers | Windows full restore clones or fast-forward-pulls the mainframe and private automation repositories. Its alist/Ditto/opencode patch-build actions require the relevant private patcher source; the opencode fork patcher is version-guarded. Linux recovery does not clone private repositories, run private patchers, or fabricate credentials. These are blocked/unimplemented native actions. |
| Pinned opencode v2 | Windows restore recognizes `opencode2` as the pinned v2 install and refuses to run the v1 fork patcher against it because that would overwrite v2; it only runs the v1 patcher when v1 is installed and v2 is absent. Linux stages opencode config/skills/plugins only, excludes `node_modules`, and does not install or activate the v2 runtime. |
| Shortcuts and running processes | Windows package-manager hooks may create shell integration. The restore explicitly launches Edge during extension recovery, stops AnyDesk/Directory Opus processes for persist copying, and restarts processes that were previously running. Linux does not activate `.lnk`, launch browsers, stop/restart apps, or infer startup services; deliberate desktop/service integration remains unimplemented. |
| Scheduled tasks | Windows exports only explicitly selected task XML (the default selection is empty). Linux preserves selected XML as documentation; no trigger, credential, SID, timezone, or action is converted to systemd/cron. |
| Registry and associations | Windows exports user environment/PATH, mpv context-menu, qBittorrent, VLC, and 7-Zip association `.reg` files. The number and contents of association exports are determined from each supplied archive, not a release-specific baseline. Linux retains them as text/reference only; it does not import registry keys or shell verbs. |
| OBS and qBittorrent | Windows copies scenes/profiles/config while excluding caches/logs/crashes and qBittorrent downloads/cache/logs. Linux exposes only the explicit candidate targets above; source paths, devices, encoders, WebUI credentials, and client versions need review. |
| Browser and account state | Edge/profile and account material may be preserved as opaque bytes or metadata, but DPAPI/app-bound encryption, Secure Preferences, credentials, and Windows identity are not activated. SSH gets a candidate `.ssh` relative export with permission remediation; auth still requires review/re-authentication. |
| Short-lived setup | `boot.sh --setup-tools` installs only the four prerequisites and clones the public source checkout. It does not run any restore action. |

## Dynamic inventory and validation

Archive sizes, member counts, application presence, user preferences, account names,
and host paths are input data, never migration constants. Inventory derives archive
metadata from the supplied ZIP central directories. No production payload is needed
to develop or test the rules; the offline suites construct synthetic archives.
Application names and relative staging paths above describe app/platform schemas,
not user-specific values. Unknown applications and settings remain preserved with
explicit blockers rather than being replaced by a known user's preferences.

Package action counts are derived from the checked-in public allowlists, not a
private release. A planned action is not a successful installation. Supplied backup
metadata, host package availability, runtime versions, build dependencies, and
authentication require separate destination validation.

Run the complete offline Python, Bash, and mocked PowerShell suites listed in the
README. They cover original-byte hashes, arbitrary synthetic values, private-value
exclusion, disabled includes, unknown/duplicate settings, parser failures, size
limits, conflicts, private permissions, staging failure cleanup, package guards,
subprocess timeouts, cancellation, and caller-trap preservation. Mocked Windows
fixtures do not constitute live Windows validation. No production restore,
installation, secret decryption, or live settings change is part of these checks.

## Secret and credential boundaries

The enabled secret manifest covers mainframe account profiles (excluding Bitwarden), the SSH directory, opencode v1 config/plugins, opencode v2 config (excluding `node_modules`), and WakaTime CLI config. Disabled categories include the opencode session database and WakaTime desktop config. The nested secret archive is treated as private and opaque. Linux recovery must not print, decrypt, parse for display, upload, or activate its contents.

DPAPI-protected Chromium/Edge cookies, Local State keys, encrypted OAuth/client material, Windows Credential Manager data, and DPAPI-wrapped files may be byte-preserved but are not made decryptable by copying. Re-authentication or a documented portable export is required.

## Data the Windows backup deliberately does not include

Linux cannot reconstruct data omitted before ZIP creation. The source policy excludes the opencode session database, Bitwarden session/profile, WakaTime desktop tree, opencode `node_modules`, Python `site-packages`, agent-skill Git history, full Ditto clipboard history (only a stripped starred subset may be shipped), qBittorrent downloads, OBS logs/crashes/caches, and numerous regenerable app/browser caches. Agent-browser/browser-use throwaway profiles are excluded. Browser extension bundles may be reinstalled by the Windows route, not recovered as original installed binaries. Scheduled tasks are exported only when explicitly selected. Locked-file skip behavior can also mean a source file never reached the ZIP. These are backup-coverage limits, distinct from Linux conversion limits; no recovery tool can invent the absent bytes.

## Remaining unimplemented scope

1. A complete native Linux runtime, including Windows executables, services, scheduled tasks, registry semantics, shell integration, drivers, and Windows-only applications.
2. Verified adapters for every blocked persist app and for unknown persist paths; in particular no blanket AppData/XDG conversion.
3. Private repository authentication, private source cloning, fork rebuilds, patch application, and reproducible Linux builds for the Windows patchers.
4. Exact package version locks/holds, repository configuration, architecture-specific wheels, native build dependencies, and behavior-equivalent package installation.
5. Linux translation of shortcuts, startup processes, scheduled-task triggers, desktop entries, systemd user services, file associations, and environment semantics.
6. Browser profile migration with usable cookies/passwords/tokens, DPAPI recovery, Edge policy/signature migration, or automatic re-authentication.
7. Live-home merge/overwrite, service activation, credential import, and global instruction activation. These are intentionally absent.

## Correct interpretation of results

Separate reporting must distinguish **raw bytes preserved**, **metadata preserved**, **candidate configs staged**, **packages rebuilt**, **items blocked by Windows-only/DPAPI/registry/task semantics**, and **items absent by deliberate backup exclusion**. Raw ZIP preservation can be complete while native restoration remains incomplete. A successful candidate copy or package command does not prove identical behavior. This release is therefore **data-preserving where listed and explicitly incomplete**, not a 100% Linux runtime and not an operationally identical Windows-machine restore.
