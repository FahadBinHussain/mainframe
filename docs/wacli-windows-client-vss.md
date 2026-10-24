# Windows-client VSS: crash-consistent WACLI backup copy

The normal Windows backup scripts now route WACLI state through the internal [`wacli-vss-client`](../wacli-vss-client/) helper when supported profile roots exist. This is a writerless VSS byte copy, not an application-consistent capture or proof that the databases can be used after restore. No WACLI process is stopped or killed, and restore activation remains separate. The test environment cannot validate a real Windows VSS run; no real account, private archive, or source data is used for development tests.

## One set, not a sequence of snapshots

Windows client has native VSS requester APIs. [`Diskshadow`](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/diskshadow) is documented for Windows Server; it is not the Windows 10/11 requester implementation.

The backup helper follows Microsoft's [shadow-copy creation sequence](https://learn.microsoft.com/en-us/windows/win32/vss/shadow-copy-creation-details): initialize the requester, select `VSS_CTX_FILE_SHARE_BACKUP`, start one set, add every required unique local volume, then call `DoSnapshotSet` once. This [context](https://learn.microsoft.com/en-us/windows/win32/api/vss/ne-vss-vss_snapshot_context) is writerless, nonpersistent and auto-release. It does not use writer metadata, `PrepareForBackup`, or `BackupComplete`.

Membership must be complete before [`DoSnapshotSet`](https://learn.microsoft.com/en-us/windows/win32/api/vsbackup/nf-vsbackup-ivssbackupcomponents-dosnapshotset). Neither unsupported roots nor failed additions may be replaced by a direct copy or sequential per-volume snapshot. Every explicitly supplied root must resolve or the operation fails. A root inventory is not proof that the caller supplied all WACLI inputs or that source ownership is held against concurrent changes.

[`IVssAsync::QueryStatus`](https://learn.microsoft.com/en-us/windows/win32/api/vss/nf-vss-ivssasync-querystatus) determines the operation outcome: obtaining an async object, completing a wait, or receiving a nonnegative cancellation status is not snapshot success. Snapshot properties and set membership need validation, and cleanup must handle partial failures. [`DeleteSnapshots`](https://learn.microsoft.com/en-us/windows/win32/api/vsbackup/nf-vsbackup-ivssbackupcomponents-deletesnapshots) may itself fail partway through deleting a set.

## Crash consistency is not WACLI application consistency

Writerless VSS does not freeze WACLI producers or coordinate its databases, metadata and media through an application protocol. It supplies a crash-consistent volume boundary only. It does not establish application consistency, 100% usability, producer ownership or a common logical instant across files. The separate full WACLI causal drain and lifecycle audit remain incomplete; see the [held-capture audit](wacli-snapshot-held-capture-audit.md).

Root discovery reads supported profile/store JSON metadata only; it does not open or decrypt SQLite databases. The roots include the profile tree (and profile `store` and config), metadata `storePath`, legacy `.wacli`, and explicit config/media roots represented in supported metadata. Missing required roots stop the backup. All files under those roots, including WAL/SHM/journal sidecars and media, are copied without filename exclusions; media references that exist only inside a database are deliberately not inspected.

The helper sends every root through one `StartSnapshotSet`/`DoSnapshotSet` transaction, copies and verifies members from the verified shadows, then releases the set. It exports the private staged roots into `WacliWindowsVss/` and verifies each exported member again. Any missing/unavailable root, unsupported member, VSS failure, or copy/verification/cleanup error aborts; there is no live-copy or sequential-volume fallback. The existing source guard remains strict for non-VSS paths; only the exact profile root may be excluded from a later generic live copy, after the VSS export succeeds. CMake and a Windows C++ build toolchain are required when WACLI roots exist.

The archive payload does not activate restore and does not establish producer drain, provenance, complete media ownership or WACLI application consistency. `capture_enabled=false` and `windows_validated=false` continue to describe those unsupported claims. Linux fake-backend tests and Windows cross-compilation do not execute COM/VSS, Windows path handling, ACL/share modes, multi-volume freezing or shadow deletion on Windows.

## What the tests can establish

Synthetic backend/copier tests review fixed membership, API order, deduplication, binary and empty files, WAL/SHM retention, live mutations after freezing, held verification and failure cleanup. The actual native adapter sources also run against in-memory Win32/VSS API doubles for selected namespace, permission, stream, I/O and cleanup failures. Cross-compiling separately against real Windows API declarations catches signature and type errors. These checks do not execute COM, VSS, Windows path handling, ACL/share modes, provider cancellation, multi-volume freezing or shadow deletion on Windows.

For real-Windows runtime acceptance, run the [Windows acceptance contract](wacli-windows-capture-safety.md) on synthetic fixtures, including unsupported roots, descendant mounts/reparse points, namespace changes, multi-volume mutation, failed/partial snapshot creation, timeout and cancellation, cleanup failure, WAL/journal recovery, and authenticated encrypted byte-for-byte round trips. Resolve full producer drain and historical-provenance policy before making any application-consistency or restore-readiness claim. A Linux unit-test pass or Windows object file cannot satisfy those gates.
