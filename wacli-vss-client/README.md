# Development-only Windows VSS transaction library

**Not an enabled WACLI capture backend.** This isolated library has no public capture command, receipt importer, archive writer or override. All results retain `capture_enabled=false` and `windows_validated=false`. Caller-supplied roots are not proof of complete WACLI membership or a complete producer drain.

`probe_volumes` resolves explicitly supplied roots, creates one writerless fixed-membership VSS set, verifies it and deletes the shadows before returning. `stage_snapshot_roots` extends that same transaction: while the **same set remains owned**, inventory every explicit root from its verified shadow volume, copy every supported file into new private staging, compare bytes and inventories, recheck set membership, then release the whole set. There is no live-source copy after snapshot creation, no sequential per-volume fallback, and no partial-set success.

`ok` means only the requested development transaction and cleanup succeeded. For the copy transaction, `staged_verified=true` additionally means the internal staged tree passed verification before shadow release. It does not mean WACLI application consistency, accepted backup provenance or publishability. Snapshot IDs, root mappings and staging paths are private metadata, not log output.

## Ownership and failure rules

The backend is single-use on one COM-initialized thread. The native adapter uses balanced multithreaded COM initialization and strict process security, `InitializeForBackup`, `VSS_CTX_FILE_SHARE_BACKUP`, one `StartSnapshotSet`, all unique canonical local volumes, one `DoSnapshotSet`, bounded status observations, exact `VSS_S_ASYNC_FINISHED`, snapshot properties and whole-set deletion. No writer preparation or `SetBackupState` is used. Existing process COM security is not assumed safe: `RPC_E_TOO_LATE` fails. Individual provider calls may still block despite bounded polling.

The copy seam is internal development code. It first builds the complete inventory for **all explicit shadow roots**, before copying file contents. Missing roots, unsupported entries, incomplete enumeration, read/write/flush failures, byte or inventory mismatches, exceptions, and uncertain shadow cleanup fail the entire transaction and request staging removal. A failed staging removal remains an explicit failure, never a publishable partial result. `staging_directory` is exposed only on successful verified copy and confirmed shadow cleanup.

Native staging is temporary, not an archive: the caller must keep the copier alive while using its successful result and explicitly discard it afterward; the copier destructor is a cleanup backstop. No manifests containing source paths are published. Root ordinals correspond to the private `Result.mappings` order.

## Conservative source support

The live resolver accepts only explicitly supplied uppercase drive-absolute existing directory roots with exact long-path spelling on fixed local drives. It checks ancestors and descendants and rejects reparse points, junctions, mounted folders, inaccessible entries and incomplete enumeration. It does not follow or silently skip unsupported roots. Preflight has conservative path, entry and depth limits. Unique canonical volume GUID paths are deduplicated; more than 64 required volumes fail before requester side effects.

Preflight only validates eligibility; it does not freeze the live namespace. The copier must revalidate every source ancestor and recursively inventory roots **inside the verified shadow devices**. No live source content is reopened. Unsupported features must fail rather than lose source bytes: named alternate streams, reparse points, EFS, offline placeholders and other unsupported modes are not silently omitted or transformed. Ordinary binary files, empty files and directories are copied without database recovery, checkpointing, text conversion or media rewriting. SQLite WAL/journal/SHM files are not excluded. Original ACLs, timestamps, sparse layout and hardlink topology are not a claimed restore format.

Staging is newly created atomically with a protected inheritable DACL for SYSTEM and the requester process's token user, on a fixed local volume that reports persistent ACL support. This is a dedicated-process development contract, not an impersonating service API or a security boundary against another process of the same owner. The parent must be canonical and outside every source tree, including whole-drive roots. No existing output entry is reused or overwritten. Parent/directory/file pins protect the copy and verification phase; source handles close before whole-set deletion, and staging pins close before staging removal. Output namespaces and entries are verified separately from source inventories. No account/HOME discovery or real account access is present.

## Synthetic and compile-only checks

From the repository root:

```sh
cmake -S wacli-vss-client -B /tmp/vss-build
cmake --build /tmp/vss-build
ctest --test-dir /tmp/vss-build --output-on-failure

x86_64-w64-mingw32-g++ -std=c++17 -Wall -Wextra -Werror \
  -I wacli-vss-client/include wacli-vss-client/src/orchestrator.cpp \
  wacli-vss-client/src/native_vss_backend.cpp \
  wacli-vss-client/src/native_snapshot_copy.cpp \
  wacli-vss-client/tests/link_only.cpp -lole32 -lvssapi -luuid -ladvapi32 \
  -o /tmp/vss-link-only.exe

python3 -m unittest discover -s tests -p 'test_wacli_vss_client.py' -v
```

The portable backend and copier doubles test one-set ordering, all-root membership, binary/empty/WAL/SHM bytes, live mutations after freezing, verification before release, errors and exceptions, rollback and cleanup failures. The native copier's API-double fixture additionally copies a synthetic WACLI tree containing `session.db`, `wacli.db`, their WAL/SHM/journal sidecars, profile configuration and a media file byte-for-byte; no filename filter may silently omit those members. Existing probe tests retain volume-limit, async timeout/cancellation and exception coverage. Additional test-only Win32/VSS headers run the actual native adapter sources against in-memory API doubles, including private ACL setup, delete-sharing semantics, unsupported streams/reparse points, incomplete inventories and I/O failures. These doubles model selected API contracts, not the operating system. They are never included in the production library or real-Windows cross-compilation. The Windows fixture forces adapter linkage but does not initialize COM, resolve a root, create a snapshot or copy anything. **Cross-compilation and API doubles are not Windows runtime validation.**

Windows synthetic namespace/ACL/share-mode/provider/multi-volume mutation acceptance, complete WACLI/SDK causal-drain coverage, historical provenance and authenticated encrypted restore round trips remain required; see [the milestone](../docs/wacli-windows-client-vss.md). Neither this library nor its tests enable public capture or remove either Windows backup guard.
