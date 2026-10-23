# Windows-client VSS: a disabled requester experiment

**Coordinated WACLI capture is still disabled.** The isolated [`wacli-vss-client`](../wacli-vss-client/) library is development source, not a backup command, a held application boundary, or an accepted capture backend. No Windows runtime is available for this milestone. No real account, private archive, or source data is used.

## One set, not a sequence of snapshots

Windows client has native VSS requester APIs. [`Diskshadow`](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/diskshadow) is documented for Windows Server; it is not the Windows 10/11 requester implementation.

The experimental writerless flow follows Microsoft's [shadow-copy creation sequence](https://learn.microsoft.com/en-us/windows/win32/vss/shadow-copy-creation-details): initialize the requester, select `VSS_CTX_FILE_SHARE_BACKUP`, start one set, add every required unique local volume, then call `DoSnapshotSet` once. This [context](https://learn.microsoft.com/en-us/windows/win32/api/vss/ne-vss-vss_snapshot_context) is writerless, nonpersistent and auto-release. It does not use writer metadata, `PrepareForBackup`, or `BackupComplete`.

Membership must be complete before [`DoSnapshotSet`](https://learn.microsoft.com/en-us/windows/win32/api/vsbackup/nf-vsbackup-ivssbackupcomponents-dosnapshotset). Neither unsupported roots nor failed additions may be replaced by a direct copy or sequential per-volume snapshot. Every explicitly supplied root must resolve or the operation fails. A root inventory is not proof that the caller supplied all WACLI inputs or that source ownership is held against concurrent changes.

[`IVssAsync::QueryStatus`](https://learn.microsoft.com/en-us/windows/win32/api/vss/nf-vss-ivssasync-querystatus) determines the operation outcome: obtaining an async object, completing a wait, or receiving a nonnegative cancellation status is not snapshot success. Snapshot properties and set membership need validation, and cleanup must handle partial failures. [`DeleteSnapshots`](https://learn.microsoft.com/en-us/windows/win32/api/vsbackup/nf-vsbackup-ivssbackupcomponents-deletesnapshots) may itself fail partway through deleting a set.

## Crash consistency is not WACLI application consistency

Writerless VSS does not freeze WACLI producers or coordinate its two databases, metadata and media through an application protocol. At most it supplies a crash-consistent volume boundary. Pairing it with the proposed full WACLI causal drain still requires complete lifecycle coverage and separately verified media membership/ownership. Those gates remain incomplete; see the [held-capture audit](wacli-snapshot-held-capture-audit.md).

The development transaction creates no archive, copies no source files and returns no usable held shadows. It must release any temporary snapshots before completion; successful probe cleanup would still not mean a WACLI backup succeeded. Both Windows backup guards, public no-I/O capture refusal, existing archive formats and restore gates remain unchanged.

## What the tests can establish

Synthetic fake-backend tests can review fixed membership, API order, deduplication and failure cleanup. Cross-compiling against Windows API declarations can catch signature and type errors. Neither executes COM, VSS, Windows path handling, ACL/share modes, provider cancellation, multi-volume freezing or shadow deletion on Windows.

Before enabling capture, run the [Windows acceptance contract](wacli-windows-capture-safety.md) on synthetic real-Windows fixtures, including unsupported roots, descendant mounts/reparse points, namespace changes, multi-volume mutation, failed/partial snapshot creation, timeout and cancellation, cleanup failure, WAL/journal recovery, and authenticated encrypted byte-for-byte round trips. Resolve the full producer drain and historical-provenance policy as well. A Linux unit-test pass or Windows object file cannot satisfy those gates.
