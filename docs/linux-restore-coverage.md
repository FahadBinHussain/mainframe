# Linux restore coverage: Windows backup inventory

**Status: offline fixture-tested recovery plus Git, mpv, yt-dlp, Flameshot, and qBittorrent subset conversion; live setup and restore have not been executed.** This document describes the checked-in Linux recovery implementation and the Windows backup/restore source it can inspect. It is a preservation, staging, and bounded conversion contract, not a claim that the Windows machine becomes a native Linux machine.

## Scope and safety boundary

The Linux path is deliberately **offline and non-destructive**:

- `linux_restore.py` reads ZIP central-directory metadata for inventory. Recovery copies each original ZIP byte-for-byte into `raw-archives/`, verifies the copy, and materializes safe members under `recovered/`.
- `--apply-portable` may additionally copy explicitly classified files into a **new** `home-staging/` tree. It never writes the live home directory, activates services, changes global agent instructions, imports credentials, or executes Windows files.
- `--convert-portable` separately opts into the exact Git, mpv, yt-dlp, Flameshot, and qBittorrent settings adapters documented below. They read only verified allowlisted source files, emit offline subsets, and never activate them. No production payload was inspected for development or this coverage review; tests use synthetic fixtures. No secret is decrypted or printed. Encrypted members, nested archives, DPAPI material, and opaque account data remain raw-only/opaque.
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
| `7zip` | Blocked | Windows GUI/registry settings have no native 7zip import. Raw bytes remain in `recovered/`; native package coverage does not import these settings. |
| `alist` | Native staging candidate | `.local/share/alist/`; layout, permissions, runtime, and config compatibility are unverified. |
| `archisteamfarm` | Native staging candidate | `.local/share/ArchiSteamFarm/`; layout and Linux runtime compatibility are unverified. |
| `autohotkey` | Blocked | AutoHotkey scripts require a deliberate Linux automation rewrite. |
| `bulk-crap-uninstaller` | Blocked | Windows uninstaller has no equivalent state import. |
| `discordchatexporter` | Blocked | Native runtime and settings adapter have not been validated. |
| `ditto` | Blocked | Ditto is Windows-only; retained starred SQLite data is not imported into another clipboard application. |
| `ffmpeg` | Native staging candidate | `.config/ffmpeg/`; target layout is unverified and binaries are not copied as a Linux runtime. |
| `firefox` | Native staging candidate | `.mozilla/firefox/`; profile encryption, version migration, extensions, and paths remain unverified. |
| `flameshot` (quick-persist only) | Exact config candidate plus bounded converter | Only `quick-persist/flameshot/flameshot.ini` maps to `.config/flameshot/flameshot.ini`; conversion is limited to five documented shared `[General]` preferences. All other settings remain raw with sanitized blocker counts. |
| `ghidra` | Native staging candidate | `.ghidra/`; target layout is unverified; Java/runtime and extensions need review. |
| `git` | Blocked | Scoop Git settings can contain Windows paths/helpers; use separately reviewed `.gitconfig` and native Git setup. |
| `gradle` | Native staging candidate | `.gradle/`; caches and metadata may be staged, but Java/toolchain paths and executability are unverified. |
| `megatools` | Native staging candidate | `.config/megatools/`; layout and credentials/config semantics are unverified. |
| `micmute` | Blocked | Windows audio bindings have no native state import. |
| `mpc-hc` | Blocked | Windows-only player configuration. |
| `mpv` | Native staging candidate plus bounded converter | `--convert-portable` reads only `persist/mpv/portable_config/mpv.conf` and emits an allowlisted subset at `.config/mpv/mpv.conf`; all other files remain candidates/raw and unverified. |
| `mpv-git` | Native staging candidate | `.config/mpv/`; same target as `mpv`; version/fork behavior is unverified. |
| `parsec` | Blocked | Windows host/identity state is not a Linux host restore. |
| `proton-vpn` | Blocked | VPN credentials and network integration must be recreated through a native client. |
| `pwsh` | Blocked | Windows PowerShell modules/profiles need explicit dependency and path review; no Windows runtime is staged as Linux-native. |
| `python312` | Blocked | Windows interpreter/native modules cannot be copied into Linux Python. The retired automatic frozen snapshot is not a Linux planner input; explicit repository-only requirements files are planning-only and remain blocked pending interpreter, dependency, install-script, and isolated-destination preflight. |
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
| `yt-dlp` | Exact config candidate plus bounded config converter | Only `yt-dlp.conf` may be copied under `.config/yt-dlp/` as an unconverted candidate; `--convert-portable` can emit one documented error-policy option to `.config/yt-dlp/config`. Scoop plugin directories and all other unreviewed persist paths remain raw-only; executable/package, JavaScript runtime, plugin, and runtime behavior are unverified. |

Additional quick-archive data has explicit handling: Flameshot is limited to its exact config candidate/converter; qBittorrent reads only `qbittorrent/config/qBittorrent.ini` and emits the six-key subset below. OBS reads only exact `obs-studio/user.ini`: `--apply-portable` alone stages that file as an unconverted `.config/obs-studio/user.ini` candidate, while `--convert-portable` emits four shared UI/exit-confirmation booleans. All other OBS and qBittorrent paths, including OBS profiles/scenes and qBittorrent torrent/fast-resume data, remain raw-only. The candidate targets are default layouts, not confirmed operational. Unknown persist application/path data is retained raw and marked unresolved.

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

## Implemented conversion map: mpv portable options v1

The Windows backup copies a Scoop app's `persist` directory under
`persist/<app>/`. The upstream [Scoop Extras mpv manifest](https://github.com/ScoopInstaller/Extras/blob/master/bucket/mpv.json)
declares `portable_config` as the persistent directory, so the exact supported
source file is `persist/mpv/portable_config/mpv.conf`. The [mpv manual](https://mpv.io/manual/stable/#files)
documents that `portable_config` next to `mpv.exe` is the Windows portable config
directory; the [configuration-files section](https://mpv.io/manual/stable/#configuration-files)
documents `~/.config/mpv/mpv.conf` as the user config file on Linux. Conversion
is enabled only by `--recover --convert-portable` and targets offline
`home-staging/.config/mpv/mpv.conf`.
The archive member must match the migration-map path exactly; case/Unicode
case-fold variants are never passed to an adapter, and a competing variant
blocks an exact source rather than letting either archive path win.

The adapter accepts only simple global boolean forms for these documented
options:

| Option | Accepted form |
|---|---|
| `fullscreen` | `yes` or `no` |
| `force-window` | `yes` or `no` (`immediate` is not migrated) |
| `input-default-bindings` | `yes` or `no` |
| `osc` | `yes` or `no` |
| `save-position-on-quit` | `yes` or `no` |

The mpv config syntax documents a valueless option as enabled, so a bare
allowlisted boolean is normalized to `yes`. The adapter does not flatten
profile-scoped settings (except that `[default]` returns parsing to global
scope), resolve includes, or interpret the full mpv grammar. The [mpv manual]
(https://mpv.io/manual/stable/) documents `--fs` as an alias for `--fullscreen`
and no-flag counterparts for flag options. These alternate spellings are counted
against the canonical option for duplicate detection, but are never accepted on
their own or emitted. Duplicate supported settings, invalid syntax/encoding, and
unsupported values are excluded. Unknown
settings—including Windows paths, device references, scripts, shader paths,
includes, and script-owned options—are counted as blocked without recording
names or values. No accepted option means no generated output; conflicts across
archives or with an existing candidate target never choose a winner.

Only `mpv.conf` is converted. `input.conf` contains command bindings; scripts and
`script-opts/` depend on code-defined semantics; cache and `watch_later/` are
state, often tied to Windows media paths; and shader/font/plugin dependencies
are not inferred. These remain original bytes and, if `--apply-portable` is also
requested, may appear only as inactive staging candidates under the preserved
portable-config layout. The archive does not prove the source executable version
or Linux target version; the supported subset is not a runtime compatibility or
operational-equivalence claim. `mpv-git` keeps its separate version/fork blocker.

The converter never invokes mpv, installs a package, reads a live profile, or
changes the user's home. Generated output is private, deterministic, hash-verified,
review-required; installation and activation remain separate future work.

## Implemented conversion map: yt-dlp config options v1

The official [ScoopInstaller/Main yt-dlp manifest](https://github.com/ScoopInstaller/Main/blob/master/bucket/yt-dlp.json)
persists `yt-dlp.conf`, `ytdlp_plugins`, and `yt-dlp-plugins`. The tracked Windows
backup copies the Scoop persist tree under `persist/`, so the only config file
passed to this adapter is the exact member `persist/yt-dlp/yt-dlp.conf`. The
plugin directories and all other unreviewed yt-dlp persist paths are never
converted or copied into `home-staging/`; their contents, dependencies, and
compatibility remain raw-only blockers.

The current [upstream yt-dlp configuration documentation](https://github.com/yt-dlp/yt-dlp#configuration)
lists `${XDG_CONFIG_HOME}/yt-dlp/config` as a recommended Linux/macOS user-config
location and says a config file uses command-line switches. The adapter therefore
targets the relative offline path `.config/yt-dlp/config`, but it deliberately
does not implement yt-dlp's general option parser. It emits at most one exact,
no-argument option per source file:

| Accepted source option | Output option | Documented behavior |
|---|---|---|
| `--ignore-errors` or `-i` | `--ignore-errors` | Ignore download and post-processing errors and treat the download as successful. |
| `--abort-on-error` or `--no-ignore-errors` | `--abort-on-error` | Abort on error. |
| `--no-abort-on-error` | `--no-abort-on-error` | Continue with the next video after download errors. |

These are general error-handling switches with no filesystem, host, browser,
network, or plugin path value. Only one supported switch may appear in a file;
duplicates, aliases repeated together, mixed policies, any argument-bearing form,
or any other non-comment setting block the entire generated file. Blockers report
reason/count only; arbitrary option names, comments, and values are never copied
to the audit report or generated config. Strict UTF-8 without a BOM is required.
The original config remains byte-preserved under `recovered/`; with the separate
`--apply-portable` option the exact source may also be copied as an unconverted
candidate named `yt-dlp.conf`, distinct from the converted `config` file. No cookie/browser paths,
authentication, proxies, plugin paths, output paths/templates, executable
commands, JavaScript-runtime paths, unknown flags, or personal identifiers are
converted. A target collision or competing quick/full/case-fold source blocks
publication without choosing a winner.

`--convert-portable` is offline-only: no yt-dlp executable is run or installed,
no package is activated, and no home directory is modified. The existing APT
mapping is still only a package-planning route; installed version, executable
behavior, JavaScript runtime, plugins, output behavior, and operational
equivalence remain unverified.

## Implemented conversion map: Flameshot portable preferences v1

The tracked Windows [backup script](../backup.ps1#L501-L512) copies only
`%APPDATA%\Flameshot\flameshot.ini` to the exact archive member
`quick-persist/flameshot/flameshot.ini`; the tracked [restore script](../restore.ps1#L934-L952)
uses that same source only on a fresh Windows box. The current [Scoop Extras
Flameshot manifest](https://raw.githubusercontent.com/ScoopInstaller/Extras/master/bucket/flameshot.json)
has no `persist` declaration, so this adapter is deliberately tied to Mainframe's
quick-persist export rather than a guessed Scoop directory.

Upstream's [configuration guide](https://flameshot.org/docs/advanced/configuration/)
documents Linux's `~/.config/flameshot/flameshot.ini` target. The upstream
[README](https://github.com/flameshot-org/flameshot/blob/master/README.md)
specifically says `savePath` must be corrected when copying config across
operating systems. The current shared
[ConfigHandler option table](https://raw.githubusercontent.com/flameshot-org/flameshot/master/src/utils/confighandler.cpp)
declares the following selected `[General]` keys outside platform-specific
guards; the [CLI documentation](https://flameshot.org/docs/advanced/commandline-options/)
also describes the help and UI-color settings. This evidence supports a small
common subset, not automatic equivalence for the whole Windows configuration.

| Exact `[General]` key | Accepted value | Evidence-backed behavior |
|---|---|---|
| `showHelp` | `true` or `false` | Upstream documents the initial help message in capture mode and its CLI boolean. |
| `uiColor`, `contrastUiColor` | Six-digit `#RRGGBB` only | Shared color settings; the CLI docs identify main and contrast UI colors. |
| `drawColor` | Six-digit `#RRGGBB` only | Shared last-used drawing color in the upstream config definitions. |
| `contrastOpacity` | ASCII decimal integer `0`–`255` | Shared overlay opacity; upstream defines the bounded range. |

The adapter writes only these unique, strictly validated settings to
`home-staging/.config/flameshot/flameshot.ini`. Although upstream accepts other
color encodings, this converter deliberately accepts only `#RRGGBB`; booleans
must be literal `true`/`false`. It handles only simple UTF-8 INI lines in the
exact `[General]` group; it is not a general Qt `QSettings` parser. Unknown or
unsupported settings and sections, invalid values, and duplicate allowlisted
keys remain in the byte-preserved original and produce reason/count-only audit
decisions. Duplicate settings are not resolved by picking a value. The audit
never echoes values, unknown key names, comments, Windows paths, or identifiers.

`savePath`, filename patterns, startup behavior, notification preferences,
upload/auth data, drawing sizes, shortcuts, plugins, desktop/display backends,
OS-conditional options, and all other settings remain unsupported. Upstream
documents Linux global shortcuts as desktop-environment managed, and the source
has OS-specific settings/side effects; no shortcut or startup translation is
attempted. `--apply-portable` alone may stage the exact original as an
**unconverted candidate**. If `--convert-portable` is also requested, that raw
candidate copy is skipped because the candidate and generated config share the
same target; the original bytes still remain under `recovered/`. Existing target
collisions block publication rather than overwrite. Nothing is installed,
launched, or activated, and the upstream `flameshot config --check` command is
not run. Package/runtime version, display-stack behavior, and operational
equivalence therefore remain unverified.

## Implemented conversion map: qBittorrent portable preferences v1

The tracked Windows [backup script](../backup.ps1#L606-L619) copies the Scoop
custom-profile tree `persist/qbittorrent/profile/qBittorrent` to a `qbittorrent/`
directory in the output tree; its [split-ZIP packaging](../backup.ps1#L934-L960)
puts that directory at the quick-ZIP root and excludes the separate `persist/`
tree. The tracked [restore script](../restore.ps1#L1287-L1297) puts it back under
the same Windows profile root. The only recognized source file is therefore the exact quick-ZIP member
`qbittorrent/config/qBittorrent.ini`; other qBittorrent profile paths are raw-only.

The official [FAQ](https://github.com/qbittorrent/qBittorrent/wiki/Frequently-Asked-Questions)
documents Windows preferences under `%APPDATA%\\qBittorrent` and Linux
preferences under `~/.config/qBittorrent/`; Linux torrent data normally lives in
`~/.local/share/qBittorrent/`. Current upstream
[`profile_p.cpp`](https://raw.githubusercontent.com/qbittorrent/qBittorrent/master/src/base/profile_p.cpp)
selects Windows `AppDataLocation` versus Unix `AppConfigLocation`, and uses
`qBittorrent.ini` on Windows versus `qBittorrent.conf` on Unix for a custom
profile while forcing `QSettings::IniFormat`. The official
[portable-mode guide](https://github.com/qbittorrent/qBittorrent/wiki/How-to-use-portable-mode)
supports portable mode from version 4.2.1 but warns that path-specific settings
may not work after moving profiles between machines.

The adapter emits only these six current shared boolean preferences, whose
getters/setters are not behind OS-specific guards in upstream
[`preferences.cpp`](https://raw.githubusercontent.com/qbittorrent/qBittorrent/master/src/base/preferences.cpp):

| QSettings key | Accepted value | Evidence-backed behavior |
|---|---|---|
| `Preferences/General/ExitConfirm` | Literal `true` or `false` | Shared exit-confirmation preference. |
| `Preferences/General/AlternatingRowColors` | Literal `true` or `false` | Shared transfer-list display preference. |
| `Preferences/General/NoSplashScreen` | Literal `true` or `false` | Shared startup-display preference; no startup action is enabled. |
| `Preferences/General/ToolbarDisplayed` | Literal `true` or `false` | Shared UI visibility preference. |
| `Preferences/General/StatusbarDisplayed` | Literal `true` or `false` | Shared UI visibility preference. |
| `GUI/TransferList/UseTorrentStatesColors` | Literal `true` or `false` | Shared transfer-list display preference. |

The output is written offline to
`home-staging/.config/qBittorrent/qBittorrent.conf` using the QSettings INI
group/key form. Only exact section/key spelling and lowercase boolean literals
are accepted. Duplicate or case-fold-equivalent supported keys are blocked
rather than resolved; malformed input blocks the file. Unknown and unsupported
settings stay only in the byte-preserved original and produce reason/count-only
decisions. The audit does not echo values or unknown key names. This strict
subset is not a general QSettings migrator: [Qt's QSettings documentation](https://doc.qt.io/qt-6/qsettings.html)
states that Windows INI keys are case-insensitive while Unix keys are case-sensitive, and qBittorrent's
[`SettingsStorage`](https://raw.githubusercontent.com/qbittorrent/qBittorrent/master/src/base/settingsstorage.cpp)
retains manually inserted and feature-disabled keys when saving.

Download/save/watch paths, incomplete paths, fast-resume paths, torrent data,
WebUI credentials/API keys, proxy and SMTP settings, TLS certificates, external
programs, custom themes, network bindings, OS-specific startup/tray behavior,
unknown keys/sections, and all `data/BT_backup` files remain raw-only. The exact
`.ini` source may be staged as an **unconverted candidate** only when
`--apply-portable` is requested alone; it may contain those unsupported values.
When `--convert-portable` is also requested, the raw candidate is suppressed and
only the allowlisted `.conf` subset may be staged. Source collisions and
pre-existing output targets block conversion without overwriting; no application
is installed, launched, or activated. The source package version, target runtime,
full profile behavior, and operational equivalence remain unverified.

## Implemented conversion map: OBS Studio user preferences v1

The tracked [backup script](../backup.ps1#L591-L601) copies the Scoop OBS config
root to the quick-archive member tree `obs-studio/`; the [restore script](../restore.ps1#L1272-L1285)
puts that tree back under the Windows Scoop persist config root. Only the exact
member `obs-studio/user.ini` is eligible. The [OBS upstream application source](https://github.com/obsproject/obs-studio/blob/master/frontend/OBSApp.cpp#L638-L650)
opens `obs-studio/user.ini` under its user-config location. The platform helpers
use the Windows AppData config root and default Linux `$XDG_CONFIG_HOME` or
`$HOME/.config` root ([Windows](https://github.com/obsproject/obs-studio/blob/master/libobs/util/platform-windows.c#L435-L443),
[Linux](https://github.com/obsproject/obs-studio/blob/master/libobs/util/platform-nix.c#L226-L249)).
The offline target is the default `home-staging/.config/obs-studio/user.ini`;
custom XDG roots and `Locations` overrides from `global.ini` are not translated.

Current upstream [`InitUserConfigDefaults`](https://github.com/obsproject/obs-studio/blob/master/frontend/OBSApp.cpp#L376-L413)
defines the four allowlisted booleans in shared frontend code. The
[main-window implementation](https://github.com/obsproject/obs-studio/blob/master/frontend/widgets/OBSBasic.cpp#L974-L1022)
and [settings implementation](https://github.com/obsproject/obs-studio/blob/master/frontend/settings/OBSBasicSettings.cpp#L1330-L1334)
read or write these UI preferences. The [profile guide](https://obsproject.com/kb/profiles)
shows why OBS profiles are not generic UI settings: they include output-oriented
configuration. The [portable-mode guide](https://obsproject.com/kb/portable-mode)
warns that scene media paths are not portable and need manual relocation.

| Exact `user.ini` key | Accepted value | Evidence-backed behavior |
|---|---|---|
| `[General] ConfirmOnExit` | Literal lowercase `true` or `false` | Shared prompt preference when closing with active output. |
| `[BasicWindow] PreviewEnabled` | Literal lowercase `true` or `false` | Shared preview-pane visibility preference. |
| `[BasicWindow] SnappingEnabled` | Literal lowercase `true` or `false` | Shared canvas-editing snapping preference. |
| `[BasicWindow] ShowStatusBar` | Literal lowercase `true` or `false` | Shared status-bar visibility preference. |

The converter follows the upstream parser's leading ASCII space/tab handling
before section and key records, accepts one leading UTF-8 BOM (Windows OBS writes
one), and emits only exact lowercase boolean literals. It deliberately rejects
trailing/inline whitespace, escaped values, malformed records, and noncanonical
values rather than normalizing them ([parser and escape handling](https://github.com/obsproject/obs-studio/blob/master/libobs/util/config-file.c#L90-L201),
[serializer and Windows BOM writer](https://github.com/obsproject/obs-studio/blob/master/libobs/util/config-file.c#L331-L383),
[boolean writer](https://github.com/obsproject/obs-studio/blob/master/libobs/util/config-file.c#L575-L579),
[UTF-8 reader](https://github.com/obsproject/obs-studio/blob/master/libobs/util/platform.c#L168-L212)).
It writes only these unique exact-case keys as a deterministic Linux `user.ini`.
Duplicate and case-fold-equivalent keys are blocked, as are unknown keys/sections.
Blocker decisions contain fixed reason/status codes and counts, plus canonical
names only for supported keys; they never echo unknown config key names or values.
Successful-conversion audit also records the fixed staged target and output hash/size.
The local `restore-manifest.json` separately retains archive member paths for
traceability; those source filenames are metadata, not converted settings.

`global.ini` and its custom location overrides, profiles, scene collections,
output/streaming/encoder state, device and OS-specific paths, plugins, browser or
WebSocket/auth data, hotkeys, tray/startup behavior, auto-record flags, themes,
and every other OBS member remain raw-only. The [themes guide](https://obsproject.com/kb/themes-guide)
notes that the System theme follows the operating system and custom themes are
separate files, so neither theme IDs nor theme assets are copied. The exact raw
`user.ini` may be staged only as an **unconverted candidate** when
`--apply-portable` is requested alone; that candidate can contain unsupported
fields. With `--convert-portable`, the raw candidate is suppressed and only the
four-setting output is staged; original archive bytes remain preserved under
`recovered/`. Source/target collisions block without overwriting. Nothing is
installed, launched, checked with an OBS executable, or activated. Custom config
locations, version compatibility, full settings behavior, and operational
equivalence remain unverified.

## Source action coverage

This table records the actual source actions, not hypothetical Linux work. Windows actions remain reference evidence; Linux actions are limited to the checked-in planner/recovery behavior.

| Source action | Current behavior and Linux consequence |
|---|---|
| ZIP creation and split archives | Windows backup creates quick and persist ZIPs, using 7-Zip when available or `Compress-Archive`; exclusions and locked-file handling are applied before packaging. The automatic frozen pip snapshot is retired: backup no longer creates `pip-freeze.txt`. Linux retains each supplied ZIP byte-for-byte and verifies SHA-256 of the copy. |
| ZIP metadata inventory | Linux validates ZIP names, traversal, duplicate paths, file/directory collisions, symlinks/special entries, and encrypted members without decrypting payloads. |
| Safe materialization | Safe ordinary members are copied to `recovered/<archive>/<member>` with verification; unsafe/encrypted/special members remain raw-only. Existing destinations, symlinks, and unsafe parent paths are rejected. |
| Explicit native staging | Only classifier-approved targets are copied to a new offline `home-staging/` tree. A collision becomes `staging-conflict`; no overwrite or live-home merge occurs. |
| Git preference conversion | Opt-in six-setting `.gitconfig` adapter above; original preserved, Windows line-ending defaults translated, unknown/identity/command/credential state excluded with explicit decisions. No native activation. |
| yt-dlp configuration | Opt-in exact-source adapter above; one documented platform-neutral error-policy option at most. Unknown/auth/path/proxy/plugin/command settings block conversion with sanitized counts; plugin directories stay raw-only. No package install or activation. |
| Flameshot configuration | Opt-in exact quick-persist adapter above; only `showHelp`, three color settings, and bounded `contrastOpacity` can be emitted. Unsupported fields remain only in the preserved original with sanitized counts; no installation, app validation, or activation occurs. |
| qBittorrent configuration and torrent metadata | Windows exports a custom profile including config and WebUI state but excludes downloads. Linux emits only six shared booleans from the exact config source; the optional raw `.ini` candidate is never labeled converted, and all other profile fields plus `data/BT_backup` remain raw-only. No installation or activation. |
| Scoop allowlist and version metadata | Windows exports Scoop configuration/app/version intent and persist data. Linux preserves manifests and maps only explicit package names in `APT_MAP`; Windows installers, shims, paths, and post-install hooks do not run. |
| WinGet/native persist | AnyDesk and Directory Opus-style native persist is archived/quarantined as Windows state; no Linux identity, service, or file-manager import is performed. Only `AnyDesk.AnyDesk` package intent is covered by native `anydesk`; other WinGet IDs remain unsupported records. |
| APT package mapping | `linux_packages.py` plans Debian/Ubuntu x86_64/aarch64 installs for explicit mappings such as `7zip→7zip`, `ffmpeg→ffmpeg`, `gh→gh`, `git→git`, `go→golang-go`, `python312→python3.12`, `rclone→rclone`, `vlc→vlc`, and `yt-dlp→yt-dlp`. `mpv-git` and `nodejs-lts` are blocked for variant drift rather than silently replaced. APT candidates must exist on the actual host before any selected install. Package planning is dry by default; execution requires `--execute`, and blockers prevent an unqualified full execution. |
| Scoop extractor helper coverage | `7zip19.00-helper` is explicitly `covered` with `covered_by: "7zip"`, a reason, and no separate install command. One native APT `7zip` action covers the extractor role, even when only the helper is declared or declarations are reordered. Selecting the helper selects that native action with candidate preflight. This is not a Linux 19.00 pin, Scoop execution, or Windows settings migration. Execution reports covered helpers separately from skipped actions; unrelated blockers remain intact. |
| Package holds and version mappings | Recorded Windows/Scoop versions are preserved as metadata/provenance, not silently asserted equivalent to APT versions. The Linux planner has no general package-hold or Windows-version-lock implementation; exact versions requiring holds, repositories, or manual pinning remain a scope item. |
| Android Command-Line Tools (`android-clt`) | Same suite as Windows, including `sdkmanager`, via Google's Linux x86_64 ZIP. Current Scoop build and Windows URL must agree; Google's Linux URL and SHA-256 must match that build. Missing/ambiguous metadata or aarch64 blocks explicitly. Dry planning fetches public metadata only. Installation requires `--execute --select android-clt --android-sdk-root <new-directory> --android-sdk-terms-accepted`, verifies SHA-256 before safe extraction to `cmdline-tools/latest`, and refuses existing SDK roots. No Android CLI/adb substitution, automatic license files, SDK invocation, Java install, shell-profile changes, or Windows SDK-state migration. Java/runtime behavior requires separate testing. |
| AnyDesk (`anydesk`, `AnyDesk.AnyDesk`) | Debian/Ubuntu x86_64 resolves the current vendor DEB from the official HTTPS package index, including version, size and SHA-256. Missing/ambiguous metadata and other architectures block. WinGet package intent is covered by the single native action, not silently dropped. Planning reads metadata only; a future system install requires `--execute --select anydesk --anydesk-terms-accepted --anydesk-service-allowed`, verifies the download before APT, and may install/start the vendor service. No repository/key changes or Windows identity/configuration import. Xorg is needed for incoming sessions; Wayland is outgoing-only. Linux and Windows versions are independent; runtime behavior is untested. |
| Bitwarden CLI (`bitwarden-cli`) | Debian/Ubuntu glibc x86_64 resolves the current Scoop manifest's exact OSS version to the matching official `bw-oss-linux` release asset, requiring unique published metadata, size and GitHub SHA-256 digest. No default non-OSS/npm substitution or Windows checksum reuse. Dry planning reads public metadata only; a future install requires `--execute --select bitwarden-cli --bitwarden-cli-root <new-directory>`, validates integrity and rejects unsafe archives/destinations. No Node/npm bootstrap, PATH/profile modification, vault login/unlock, credential access or Windows account-state import. Other architectures block; actual binary/runtime behavior remains untested. |
| pnpm globals/config | Windows records `@googleworkspace/cli`, `vercel`, and the global bin directory. Linux plans `pnpm add --global` per allowlist and must normalize the bin directory; native dependencies and authentication remain review items. |
| uv tools | Windows records `graphifyy`; Linux plans `uv tool install graphifyy` without assuming Windows entry points or indexes. |
| Go global | Linux plans the normal `go install github.com/openclaw/wacli/cmd/wacli@v0.15.0` with `sqlite_fts5` as dry-plan metadata `standard-linux-go-install`; normal explicit `GOBIN` or first `GOPATH/bin` (normally `~/go/bin`) and normal module/build caches apply. No portable/isolated HOME requirement. Execution is disabled before adapter preflight; compiler/CGO dependencies and resulting binary behavior remain untested. |
| pip environment | **Superseded historical review:** older Windows backups may contain `pip-freeze.txt` as restore control metadata, but it is excluded from user data and ignored by the Linux planner with no action or blocker. Windows Full no longer installs it. Explicit repository-only `requirements.txt`/`requirements-linux.txt` files may be inspected for planning; generic Python execution remains blocked pending interpreter, dependency, install-script, and isolated-destination preflight. |
| Private source clone/fork patchers | Windows full restore clones or fast-forward-pulls the mainframe and private automation repositories. Its alist/Ditto/opencode patch-build actions require the relevant private patcher source; the opencode fork patcher is version-guarded. Linux recovery does not clone private repositories, run private patchers, or fabricate credentials. These are blocked/unimplemented native actions. |
| Pinned opencode v2 | Windows restore recognizes `opencode2` as the pinned v2 install and refuses to run the v1 fork patcher against it because that would overwrite v2; it only runs the v1 patcher when v1 is installed and v2 is absent. Linux stages opencode config/skills/plugins only, excludes `node_modules`, and does not install or activate the v2 runtime. |
| Shortcuts and running processes | Windows package-manager hooks may create shell integration. The restore explicitly launches Edge during extension recovery, stops AnyDesk/Directory Opus processes for persist copying, and restarts processes that were previously running. Linux recovery does not activate `.lnk`, launch browsers, stop/restart apps, or infer startup services. A separately authorized AnyDesk DEB installation may start its vendor service; no Windows service-state migration is implied. |
| Scheduled tasks | Windows exports only explicitly selected task XML (the default selection is empty). Linux preserves selected XML as documentation; no trigger, credential, SID, timezone, or action is converted to systemd/cron. |
| Registry and associations | Windows exports user environment/PATH, mpv context-menu, qBittorrent, VLC, and 7-Zip association `.reg` files. The number and contents of association exports are determined from each supplied archive, not a release-specific baseline. Linux retains them as text/reference only; it does not import registry keys or shell verbs. |
| OBS | Windows copies the OBS config root while excluding caches, logs, and crashes. Linux recognizes only exact `obs-studio/user.ini`: an unconverted candidate or a four-boolean offline subset. Profiles, scenes, `global.ini`, output/auth, paths, devices, plugins, and all other members remain raw-only; custom XDG/`Locations` paths, version behavior, and operational equivalence are unverified. |
| qBittorrent | Windows exports a custom profile. Linux converts only the six shared booleans above; the raw config candidate is explicit and unconverted, while paths, WebUI/auth, proxy/SMTP, scripts, OS-specific settings, torrent files, and fast-resume data remain raw-only. Package/runtime version and operational equivalence are unverified. |
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

Linux cannot reconstruct data omitted before ZIP creation. The source policy excludes the opencode session database, Bitwarden session/profile, WakaTime desktop tree, opencode `node_modules`, Python `site-packages`, agent-skill Git history, full Ditto clipboard history (only a stripped starred subset may be shipped), qBittorrent downloads, OBS logs/crashes/caches, and numerous regenerable app/browser caches. Agent-browser/browser-use throwaway profiles are excluded. Browser extension bundles may be reinstalled by the Windows route, not recovered as original installed binaries. Scheduled tasks are exported only when explicitly selected. Locked-file skip behavior can also mean a source file never reached the ZIP. Legacy `pip-freeze.txt` is restore control metadata, not user data; its presence in an older archive does not make it a Linux package input. These are backup-coverage limits, distinct from Linux conversion limits; no recovery tool can invent the absent bytes.

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

## WACLI normal-install user data

Normal installation does not require a portable binary to preserve state. The
planned WACLI install is not tested or executable, and does not grant runtime
or state activation permission.
[The explicit WACLI state helper](linux-wacli-state.md) captures a caller-selected,
quiesced Linux state root into the established AES-256 secret-envelope layout,
or blocks if sidecars/locks/dependencies make that unsafe. Restoration is an
explicit unlocked-archive export to a **NEW** offline destination after PR28's
caller-selected clean-state encrypted capture. There is no live-WAL capture,
migration, activation, or automatic full-backup integration. Ordinary recovery
keeps that envelope opaque and does not automatically stage native state or map
Windows WhatsApp profiles into a Linux account. Go build/install stays guarded.
