# Why coordinated WACLI capture is still blocked

**There is no working coordinated snapshot backend yet.** Mainframe PR #33 and the paired WACLI patch describe a blocked capability, not a snapshot. This follow-up adds reproducible counterexamples and a source audit; it does not enable capture, certify media membership, or make a Linux account restore usable.

## The concrete shutdown gap

At WACLI proposal commit `a46c1511744a943ffb8da700f954093de5b6c1b9`, based on upstream `5578d1b6892f50a8f2329b11a6b6e27a1a81f88b`, the delegate server starts a goroutine for each accepted request. Its stop function closes the listener and waits for the accept loop only. It does not join the accepted handlers or their executors: [upstream send_ipc.go, lines 184–219](https://github.com/openclaw/wacli/blob/5578d1b6892f50a8f2329b11a6b6e27a1a81f88b/cmd/wacli/send_ipc.go#L184-L219).

The accompanying diagnostic WACLI test holds an accepted synthetic executor behind a channel, calls stop, and observes stop returning before releasing that executor. No account, database, network service, credential or personal media is used. The test intentionally demonstrates unsafe shutdown semantics; a passing counterexample is **not** successful snapshot capture. It is not wired into Mainframe runtime behavior.

Fixing that one handler join would be necessary for a shutdown-based boundary, but would not establish the full boundary by itself.

## Other writers and media remain outside a proven fence

WACLI acquires its cooperative `LOCK` when constructing a writing app: [root.go, lines 120–149](https://github.com/openclaw/wacli/blob/5578d1b6892f50a8f2329b11a6b6e27a1a81f88b/cmd/wacli/root.go#L120-L149). That excludes cooperating commands, not unrelated SQLite connections or filesystem writers. A running follow daemon can also execute delegated operations while owning that lock.

`App.Close()` does drain selected app-state recovery and persistence work; it must not be described as doing no draining. It then closes the resolver, WhatsApp wrapper and app database separately: [app.go, lines 222–254](https://github.com/openclaw/wacli/blob/5578d1b6892f50a8f2329b11a6b6e27a1a81f88b/internal/app/app.go#L222-L254). Those waits do not join the delegated request handlers or prove a shared admission barrier across every writer.

The pinned whatsmeow dependency, `v0.0.0-20261017175727-b2b1e71d45e2`, dispatches app-state key-share processing in a goroutine with `context.WithoutCancel`: [message.go, lines 923–925](https://github.com/tulir/whatsmeow/blob/b2b1e71d45e2/message.go#L923-L925). Its disconnect path waits for the handler queue with a five-second timeout: [client.go, lines 721–735](https://github.com/tulir/whatsmeow/blob/b2b1e71d45e2/client.go#L721-L735). Neither is a demonstrated exhaustive dependency-level writer join. The wrapper disconnects and closes the session container: [client.go, lines 64–84](https://github.com/openclaw/wacli/blob/5578d1b6892f50a8f2329b11a6b6e27a1a81f88b/internal/wa/client.go#L64-L84).

Media can be written to a caller-selected path outside the store: [media.go, lines 113–139](https://github.com/openclaw/wacli/blob/5578d1b6892f50a8f2329b11a6b6e27a1a81f88b/internal/app/media.go#L113-L139). Copying only the store tree cannot establish complete referenced-media membership. An eventual backend must define missing/remote-only media semantics, approve external roots, fence file creation/rename/deletion, and preserve relocation information without silently dropping references.

## Valid SQLite files can still be an impossible pair

The new [Mainframe tests](../tests/test_wacli_snapshot_boundary.py) use only temporary generic schemas and deterministic ordering, not production WACLI schemas:

1. Start both database epochs at `(0, 0)` and back up `session.db` at epoch zero.
2. Commit the session epoch to one, then commit the app epoch to one. The live states are `(0, 0)`, `(1, 0)`, `(1, 1)`.
3. Back up `wacli.db` at epoch one. The collected pair is `(0, 1)`, a state that never existed together.

Both individual backups pass SQLite integrity checks. Both DELETE-journal and WAL fixtures reproduce the result. Mainframe preparation preserves the torn pair but correctly leaves `boundary=UNVERIFIED`, `cross_database_consistency=NOT_CERTIFIED`, `complete=false` and `publishable=false`. It does not repair or certify source history.

Further fixtures show a valid database paired with a later media epoch, and a preserved opaque external-media reference whose file is outside the supplied stage. The latter is not a WACLI schema migration test and does not exercise external file discovery. These examples protect against mistaking stable hashes, successful staging, or encryption for a common source boundary.

## What must change before capture can be enabled

A supported backend needs one reviewed admission-and-drain protocol covering command writers, accepted/queued delegate requests, sync/media work, app-state/contact/recovery continuations, and dependency-owned session writers. It must establish a coherent cross-database application frontier, not simply freeze two individually valid files. The boundary must remain held while approved complete input membership is captured and validated; aborts must never publish partial output.

For a shutdown-based implementation, this includes joining every accepted delegate handler, verifying dependency-level draining, and preventing source reopening until capture ends. Unrelated writers require an enforceable deployment/isolation model or a supported stronger backend; advisory `LOCK` alone is not sufficient. A coordinated filesystem snapshot can offer crash consistency but does not automatically establish the application frontier above.

After that, Linux restoration still needs version/schema compatibility, account/config mapping, media relocation, non-overwriting activation and local-data/search checks. Server-side linked-device credentials can be revoked independently; a byte-preserving restore cannot promise permanent authentication. See [Linux restoration requirements](linux-wacli-windows-parity.md).

**Windows was not run.** Windows-origin capture remains unvalidated while the user's computer is offline. Linux fixture tests, a race detector, and Windows cross-compilation are not Windows validation. Mainframe public capture still refuses before source I/O, with no force/quiescence/receipt override.
