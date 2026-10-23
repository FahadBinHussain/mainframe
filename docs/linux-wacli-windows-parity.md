# WACLI: what blocks a complete Windows-to-Linux restore

**The goal is the same data and usable functionality, not the same commands. WACLI is not yet a complete restore.** A normal Linux Go installation, an encrypted archive, or an offline directory must never be reported as a working WhatsApp account. No real backup or account was opened for this work; all tests use synthetic fixtures.

## What the Windows backup actually does

The public [manifest](../tool-secrets.manifest.json) captures `%APPDATA%\mainframe\accounts` under `AppData/Roaming/mainframe/accounts` inside `tool-secrets.zip`. [The Windows helper](../whatsapp-account.ps1) places WhatsApp profiles below `whatsapp/<E.164-phone>/`, with:

| Item | Meaning | Linux conversion state |
| --- | --- | --- |
| `current.txt` at the WhatsApp root | Selected phone/profile | Not mapped to a native default account |
| `<phone>/mainframe-whatsapp.json` | `phone`, `kind`, `ownerEmail`, `storePath`, `binary`, `updatedAt` | Preserve all fields; not upstream WACLI config |
| `<phone>/store/session.db` | WACLI/whatsmeow linked-device identity and protocol state | Compatibility and complete snapshot unproven |
| `<phone>/store/wacli.db` | Local messages, contacts, groups, search and other indexed state | Schema/history and path conversion unproven |
| `<phone>/store/media/` and other store files | Downloaded media and remaining store contents | Preserve all; references can point outside this root |

`login --store` can reference an external directory. `run` prefers a local store containing `session.db`, then metadata `storePath`, then the legacy `%USERPROFILE%\.wacli` store. The broad manifest does **not** follow `storePath` and does **not** independently capture `%USERPROFILE%\.wacli` or its config. It records neither the producing WACLI/whatsmeow version nor a snapshot-consistency receipt. The `go-allowed.json` install pin is the **target** version, not provenance for existing account data.

Current [backup.ps1](../backup.ps1) and [backup-secrets.ps1](../backup-secrets.ps1) explicitly block any WhatsApp subtree containing SQLite databases or sidecars, even a database with no visible WAL. That guard is retained, including the VSS-remapped source check. Therefore current Windows capture does **not** promise that these database bytes were backed up at all. Historical archives might contain them, but their completeness/consistency cannot be inferred. Older broad-copy rules exclude `*.db-wal`, `*.db-shm`, and `*.db-journal`; a base database alone cannot reconstruct omitted committed WAL transactions. Do not delete sidecars or weaken the guard.

Windows restore copies manifest-selected account trees back to Windows locations, backing up existing targets by default. This is not a cross-platform schema/path adapter and does not establish that a login works. `NativeState/wacli/` remains reserved for the separate explicit Linux-state capture; it is never silently remapped into Windows profiles.

## What the official Linux target expects

The reviewed target is [WACLI v0.15.0](https://github.com/openclaw/wacli/tree/v0.15.0), commit `a020de724180d31eccfa5241d45443402d62fb06`. Its Windows and Linux builds use the same application schema and whatsmeow SQL-store library, not an OS credential-vault conversion. That makes a proven, complete compatible store a possible migration source, **not** proof that any file named `session.db` is compatible.

* [Store opening](https://github.com/openclaw/wacli/blob/v0.15.0/internal/app/app.go) uses `wacli.db`, `session.db`, media and a per-store lock. [Local schema](https://github.com/openclaw/wacli/blob/v0.15.0/internal/store/schema.sql) and [migrations](https://github.com/openclaw/wacli/blob/v0.15.0/internal/store/migrations.go) define versions **1–24** in `schema_migrations`, including messages, contacts, groups, tags/aliases, chat state, stars, polls/votes, calls, statuses, tombstones, local-media aliases and app-state recovery intents. A hand-built subset would lose functionality.
* [go.mod](https://github.com/openclaw/wacli/blob/v0.15.0/go.mod) pins `go.mau.fi/whatsmeow v0.0.0-20260718134955-fac667d55293` and `github.com/mattn/go-sqlite3 v1.14.48`. [Session opening](https://github.com/openclaw/wacli/blob/v0.15.0/internal/wa/session.go) delegates to whatsmeow's separate SQL store; WACLI's schema number says nothing about that database.
* The pinned [whatsmeow schema](https://github.com/tulir/whatsmeow/blob/fac667d55293/store/sqlstore/upgrades/00-latest-schema.sql) is **v14**, tracked in [`whatsmeow_version`](https://github.com/tulir/whatsmeow/blob/fac667d55293/store/sqlstore/container.go). It includes device identities, identity/pre/sender/session keys, app-state keys/versions/MACs, contacts/chat settings, message secrets, privacy tokens, LID mappings and event/retry buffers. Version 14 alone cannot prove those records are complete, cryptographically valid or still accepted by WhatsApp. Do not merge or regenerate session keys as a shortcut.
* [Account selection](https://github.com/openclaw/wacli/blob/v0.15.0/docs/accounts.md) uses `config.yaml`, valid account names, and `default_account`. A leading `+` phone directory is not itself a valid native account name. An explicit mapping must preserve the original phone, owner metadata and selection; it must not guess a default or discard unknown metadata.
* [Path selection](https://github.com/openclaw/wacli/blob/v0.15.0/internal/config/config.go) uses absolute `XDG_STATE_HOME/wacli` or `~/.local/state/wacli` on Linux, with legacy `~/.wacli` fallback when applicable; Windows uses `~/.wacli`. `--store`, `WACLI_STORE_DIR` and named account stores can refer elsewhere. Windows drive/UNC paths are not Linux paths.

### Copying media bytes is not enough

[Media output resolution](https://github.com/openclaw/wacli/blob/v0.15.0/internal/app/media.go) makes downloaded paths absolute, including default output paths. [The database writer](https://github.com/openclaw/wacli/blob/v0.15.0/internal/store/media.go) stores that path unchanged. Both `messages.local_path` and `message_local_media_aliases.local_path` require a complete, collision-safe relocation map for Windows-to-Linux restoration. Nonempty paths are treated as already downloaded, so simply copying a database can leave unusable media references. Custom output can be outside `store/media`; a missing external file cannot be recovered from the database alone. App-state recovery intents do not fix filesystem paths.

Unknown or non-native metadata must remain in the encrypted original backup and, in any future authorized adapter, a private lossless preserve-only export with explicit unconverted status. Never call such an export converted or usable. No schema-dropping, table-subset export, secret/key recreation, automatic external-store traversal or path guessing is implemented here.

## What this change implements

`wacli_restore_contract.py` supplies one payload-free status contract to the normal Linux Go plan, generic recovery inventory/report, and explicit offline export (native capture is disabled). It separates **installation**, **preservation**, **Windows migration**, **activation**, and **usability**. `complete` remains `false`; a planned install and byte-preserved store cannot change that.

`wacli_state.py plan-windows-unlocked --archive /approved/unlocked/tool-secrets.zip` is an **optional metadata-only blocker assessment**, not a migration or unlock command. It only examines the standard Windows profile subtree in the ZIP central directory. It reports counts of candidate database pairs/sidecars without profile names, paths or payloads; rejects unsafe/duplicate/conflicting/special/encrypted selected entries and oversized input; never opens ZIP members, SQLite, YAML or profile JSON. No extraction destination exists. Exit **3** means blocked/incomplete, **2** means invalid input. It will not turn green merely because matching filenames or a claimed version are present.

No private archive was used to invoke this command. Generic recovery still preserves original archives without decrypting encrypted secrets. Its WACLI component report says coverage is unverified even after containing raw archive copies are verified. The existing native-only `restore-unlocked` still writes first to a **new offline directory**, rejects sidecars, and never overwrites or activates a live store. Normal Go installation (`GOBIN`/`~/go/bin`, normal caches) remains unchanged and execution remains disabled. No portable binary bundle is introduced.

## Exact work still required for 100%

1. **Capture evidence and all source data.** Establish actual producing versions, both full schemas and migration histories without exposing credential/chat rows. Enumerate explicitly approved external stores and media. Implement a coordinated consistent-capture protocol, preserving every file and secret in the encrypted backup. None of this is implied by a target install declaration.
2. **SQLite-safe adapter.** Use SQLite's backup/snapshot API on a proven consistent, privately staged source, including committed WAL contents; do not copy a live base file alone, discard WAL, run a checkpoint against the source, or assume separate per-database snapshots are cross-store consistent. The original encrypted payload must remain intact. An API snapshot cannot undo a torn historical archive or recover omitted WAL.
3. **Lossless semantics.** Prove compatibility of both stores, preserve all tables/unknown files, rewrite every proven media/config path on the staged copy, map profile selection explicitly, and retain/export unsupported metadata. Add synthetic source-schema fixtures covering FTS5, media aliases, app-state state and session data shapes—not merely dummy filenames or a minimal messages table.
4. **Explicit activation and validation.** After separate authorization for installation/runtime/account access, the normal restore flow must review the staged result, stop concurrent source use, handle existing destinations explicitly, activate without silent overwrite, and validate local data/media/search plus linked-device usability. WhatsApp can invalidate a linked device; retained keys alone do not prove acceptance. Those actions are not authorized or performed in this task.

No generic Windows-to-Linux migration adapter is enabled because requirements 1–3 cannot be proven from the existing capture contract or public code alone. Broader access approval by itself would not repair missing capture evidence. The exact gaps remain machine-readable and blocked rather than claiming 100% restoration.

The focused [Windows capture safety assessment](wacli-windows-capture-safety.md) adds synthetic WAL/mutation and two-database consistency evidence plus a proposed versioned capture contract. It enables no capture path: the source-capture blocker and both Windows guards remain unchanged.
