# Internal Windows VSS WACLI backup-copy helper

The normal Windows backup scripts invoke `wacli_vss_backup` when supported WACLI profile roots exist. It produces a writerless, crash-consistent copy for the backup archive. It is not a coordinated WACLI application-capture protocol, a guarantee of 100% usable state, or restore activation. No WACLI process is stopped or killed. Results keep `capture_enabled=false` and `windows_validated=false` for those stronger claims.

## One set, all required roots

The PowerShell wrapper reads supported profile/store JSON metadata only; it never opens or decrypts real SQLite databases. It enumerates the profile tree (including profile `store` and config), metadata `storePath`, legacy `.wacli`, and explicit config/media roots represented in supported metadata. Missing or unavailable required roots fail the backup before any live-copy fallback could occur.

The native helper passes every enumerated root together to one `stage_snapshot_roots` transaction. The requester initializes `VSS_CTX_FILE_SHARE_BACKUP`, starts one fixed-membership set, adds every unique local volume, calls `DoSnapshotSet` once, then inventories and copies every supported member from verified shadow devices while retaining the set. It checks byte contents and inventories, rechecks set membership, closes shadow handles and releases the whole set. It then exports the verified staging tree to the backup payload and checks the exported inventory and bytes again. Nothing reads source contents from live drive paths after snapshot creation. WAL/SHM/journal files and media have no filename exclusions.

Writerless VSS does not freeze WACLI producers or coordinate databases, metadata and media through an application protocol. SQLite files may therefore be mutually inconsistent despite exact byte copying and successful integrity checks. External media paths that exist only inside a database are not inspected; external roots must be represented in supported profile metadata. Do not claim app consistency, complete producer ownership, guaranteed usability, provenance or a common logical instant across volumes.

## Backup and restore boundaries

The existing Windows source guard remains in force for ordinary live copies. Only the exact profile root can be excluded from a later generic account-tree copy, and only after the native helper successfully verifies and exports its VSS payload. Other WhatsApp trees remain blocked. The payload is stored under `WacliWindowsVss/` with a root map and a crash-consistency label; the restore scripts do not activate or remap it.

When WACLI roots exist, CMake and a Windows C++ build toolchain are required to build the helper. Build or VSS failure is fatal; there is no live-copy or sequential-per-volume fallback. The helper is single-use on one COM-initialized thread and fails on unsupported roots, reparse/mounted paths, inaccessible members, alternate streams, incomplete enumeration, copy/verification errors, or uncertain cleanup.

## Synthetic and compile-only checks

From the repository root:

```sh
cmake -S wacli-vss-client -B /tmp/vss-build
cmake --build /tmp/vss-build
ctest --test-dir /tmp/vss-build --output-on-failure

cmake -S wacli-vss-client -B /tmp/vss-win-build \
  -DCMAKE_SYSTEM_NAME=Windows \
  -DCMAKE_CXX_COMPILER=x86_64-w64-mingw32-g++ -DBUILD_TESTING=OFF
cmake --build /tmp/vss-win-build --target wacli_vss_backup

x86_64-w64-mingw32-g++ -std=c++17 -Wall -Wextra -Werror \
  -I wacli-vss-client/include wacli-vss-client/src/orchestrator.cpp \
  wacli-vss-client/src/native_vss_backend.cpp \
  wacli-vss-client/src/native_snapshot_copy.cpp \
  wacli-vss-client/tests/link_only.cpp -lole32 -lvssapi -luuid -ladvapi32 \
  -o /tmp/vss-link-only.exe

python3 -m unittest discover -s tests -p 'test_wacli_vss_client.py' -v
python3 -m unittest tests.test_wacli_windows_vss_backup -v
python3 -m unittest tests.test_wacli_windows_contract -v
```

The portable backend and copier doubles test one-set ordering, all-root membership, binary/empty/WAL/SHM bytes, live mutations after freezing, verification before release, errors and exceptions, rollback and cleanup failures. The native copier API-double fixture includes `session.db`, `wacli.db`, WAL/SHM/journal sidecars, profile configuration and media; it also checks the separately exported payload byte-for-byte and fails on export errors. PowerShell tests use only synthetic profile metadata, missing roots and temporary directories. These doubles model selected APIs, not the operating system. They do not execute COM/VSS, Windows path handling, ACL/share modes, provider cancellation, multi-volume freezing or shadow deletion on Windows. **Cross-compilation and API doubles are not Windows runtime validation.**

Synthetic real-Windows namespace/ACL/share-mode/provider/multi-volume mutation acceptance, complete WACLI/SDK causal-drain coverage, historical provenance and authenticated encrypted restore round trips remain separate requirements for any application-consistency or restore-readiness claim; see [the milestone](../docs/wacli-windows-client-vss.md).
