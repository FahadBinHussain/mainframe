# Internal Windows VSS WACLI backup-copy helper

The native `wacli_vss_backup` helper implements a writerless, crash-consistent copy for explicitly supplied roots. The normal Windows backup integration invokes it whenever WACLI state exists and then proves external-media coverage from the held-VSS payload itself: every SQLite database in the copied tree is opened read-only, every table exposing a `local_path` column is enumerated, and each referenced file is classified as inside an enumerated root, copied into the payload under `media\` with SHA-256 verification, or recorded as missing on this machine. The resulting `media-map.json` and `root-map.json` (`mediaReferenceCoverage = proven-complete`) ship with the payload. This helper is not a coordinated WACLI application-capture protocol, a guarantee of usable state, or restore activation. No WACLI process is stopped or killed. `capture_enabled=false` and `windows_validated=false` continue to describe unsupported stronger claims.

## One set, all required roots

The PowerShell wrapper reads supported profile/store JSON metadata to enumerate roots: the profile tree (including profile `store` and config), metadata `storePath`, legacy `.wacli`, and explicit config/media roots represented in supported metadata. Missing or unavailable required roots fail the backup. The live databases are never opened for root discovery; media references are read only after the VSS copy, from the copied payload.

The native helper passes every enumerated root together to one `stage_snapshot_roots` transaction. The requester initializes `VSS_CTX_FILE_SHARE_BACKUP`, starts one fixed-membership set, adds every unique local volume, calls `DoSnapshotSet` once, then inventories and copies every supported member from verified shadow devices while retaining the set. It checks byte contents and inventories, rechecks set membership, closes shadow handles and releases the whole set. It then exports the verified staging tree to the backup payload and checks the exported inventory and bytes again. Nothing reads source contents from live drive paths after snapshot creation. WAL/SHM/journal files and media have no filename exclusions.

Writerless VSS does not freeze WACLI producers or coordinate databases, metadata and media through an application protocol. SQLite files may therefore be mutually inconsistent despite exact byte copying and successful integrity checks. External media is resolved after the copy: a referenced path inside an enumerated root is already in the payload, a referenced path outside every root is copied from the live filesystem with SHA-256 verification, and a referenced path that no longer exists is recorded as `missing-at-backup-time` (a loud warning, not a silent gap). The enumerator scans tables that expose a `local_path` column and refuses to export when it meets a different path-like column, so a schema change fails closed instead of silently dropping coverage. Do not claim app consistency, complete producer ownership, guaranteed usability, provenance or a common logical instant across volumes.

## Backup and restore boundaries

The existing Windows source guard remains in force for ordinary live copies. Only the exact profile root is excluded from a later generic account-tree copy after the native helper successfully verifies and exports its VSS payload. Other WhatsApp trees remain blocked. The payload retains its root map, media map and `crash-consistent` label; restore scripts do not activate or remap it.

When WACLI roots exist, CMake plus a native C++ toolchain (MinGW `make` and `g++` on this machine, since no MSVC is installed) and `sqlite3` on PATH are required to build the helper and enumerate media references. Build, toolchain, database or VSS failure is fatal; there is no live-copy or sequential-per-volume fallback. The helper is single-use on one COM-initialized thread and fails on unsupported roots, reparse/mounted paths, inaccessible members, alternate streams, incomplete enumeration, copy/verification errors, or uncertain cleanup.

## Synthetic and compile-only checks

From the repository root:

```sh
# Windows client host with MinGW (no MSVC): pin the generator, otherwise CMake
# picks Visual Studio and configuration fails.
cmake -S wacli-vss-client -B /tmp/vss-build -G 'MinGW Makefiles' -DCMAKE_MAKE_PROGRAM=make
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
