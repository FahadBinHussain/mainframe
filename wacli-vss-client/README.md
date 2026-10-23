# Development-only Windows VSS transaction library

**Not a capture backend.** This library is not connected to public capture. `probe_volumes` is a development transaction: it resolves only explicitly supplied roots, creates one writerless fixed-membership VSS set, verifies it, and deletes every shadow before returning. Results keep `capture_enabled=false` and `windows_validated=false`. `ok` means only the probe transaction and cleanup completed; it never means a usable WACLI backup, application consistency or a held snapshot boundary. Snapshot IDs/root mappings are private diagnostic metadata, not log output or usable shadow handles.

## API sequence

The native adapter uses balanced multithreaded COM initialization and a strict process COM security setup, `InitializeForBackup`, `SetContext(VSS_CTX_FILE_SHARE_BACKUP)`, one `StartSnapshotSet`, `IsVolumeSupported`/`AddToSnapshotSet` per unique canonical local volume, one `DoSnapshotSet`, bounded async status observations, exact `VSS_S_ASYNC_FINISHED` success, `GetSnapshotProperties`, and whole-set deletion. No writer preparation or `SetBackupState` is used. Cancellation, unknown terminal codes, provider errors and partial cleanup fail. Cleanup diagnostics are retained separately from the original operation failure.

The backend is single-use and must be created, used and destroyed on the same thread. Its process security initialization deliberately rejects `RPC_E_TOO_LATE` rather than assuming an embedding host's COM policy. It is intended for a future reviewed dedicated requester process, not general embedding in a process that has already initialized COM security. Poll limits bound the polling loop (about 60 seconds plus up to 10 seconds cancellation observation); individual COM/provider calls can still block. Provider cancellation/deletion behavior is **not Windows-validated**. Auto-release on component release is a backstop, not evidence that failed cleanup completed.

## Explicit source roots only

The native resolver accepts a deliberately narrow subset: strict UTF-8, uppercase drive-absolute existing directory roots with exact long-path spelling, local fixed drives, at most 240 UTF-16 code units per path, no device/UNC/ADS/dot/ambiguous/reserved components. It checks each ancestor and enumerates every descendant, rejecting all reparse points (including junctions, mounted folders and cloud placeholders), inaccessible entries and incomplete enumeration. It does not follow or silently skip mounted volumes. Supply separate supported roots on separate drives. Files are inventoried for type/reparse metadata only; content is not read or copied. Trees exceeding the conservative 100,000-entry accounting bound or depth 128 fail.

Volume GUID paths are normalized to lowercase internal identities. All root-to-volume mappings are retained; volume additions are deduplicated. Preflight rejects invalid identities and more than 64 volumes before requester side effects. Unsupported VSS volumes fail before `DoSnapshotSet`; no fallback exists.

**This scan does not hold the namespace or writers stable.** A path/reparse/mount can change between observations; new entries can appear. The caller supplying every WACLI store/media/config root and holding exclusive membership/ownership remain unimplemented capture gates. A scan pass is not source-wide capture approval. There is no live account or HOME discovery, copy callback, archive, receipt import, force flag or capture executable.

## Synthetic and compile-only checks

From the repository root:

```sh
g++ -std=c++17 -Wall -Wextra -Werror -pedantic \
  -I wacli-vss-client/include wacli-vss-client/src/orchestrator.cpp \
  wacli-vss-client/tests/fake_tests.cpp -o /tmp/vss-fake-tests
/tmp/vss-fake-tests

x86_64-w64-mingw32-g++ -std=c++17 -Wall -Wextra -Werror \
  -I wacli-vss-client/include wacli-vss-client/src/orchestrator.cpp \
  wacli-vss-client/src/native_vss_backend.cpp \
  wacli-vss-client/tests/link_only.cpp -lole32 -lvssapi -luuid \
  -o /tmp/vss-link-only.exe

python3 -m unittest discover -s tests -p 'test_wacli_vss_client.py' -v
```

The fake tests cover ordering, deduplication, all-root mappings, 64/65-volume boundaries, invalid identities, unsupported roots, errors at every stage, exceptions after set ownership, bounded pending/cancelled/failed statuses and cleanup failure retention. They do not execute Windows path handling, COM or VSS. The Windows fixture forces the real adapter to link but has no code to initialize COM, resolve roots or create snapshots. Cross-compilation/linking is not Windows runtime validation. Real-Windows synthetic namespace, provider failure/cancellation, ACL/share-mode, multi-volume mutation and full WACLI lifecycle/encrypted round-trip acceptance remain required; see [the milestone](../docs/wacli-windows-client-vss.md).
