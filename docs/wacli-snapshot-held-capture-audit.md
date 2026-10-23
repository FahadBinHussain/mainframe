# Runtime boundary work: capture is still disabled

The source-only runtime patches implement admission and joining for specific WACLI/whatsmeow paths. They do **not** make backed-up state usable on Linux yet. Mainframe does not apply, install or execute these patches automatically. Neither upstream acceptance nor production deployment is claimed.

## What the implementation changes

The delegate listener joins accepted connection handlers before its stop function returns. An application close seals lazy session/resolver creation, runs once even with concurrent callers, and retains close errors. An additive error-returning close interface preserves compatibility with existing WA clients while carrying errors from the patched wrapper.

The dependency patch and WACLI wrapper implement a **narrow app-state key-share boundary**, not a whole-client drain. Accepted key-share persistence runs with its detached context and keeps session SQL plus the synchronous application key-guard continuation available until completion. Persistence errors must remain errors, not become a successful close receipt. The corresponding former SQL-loss counterexample is replaced by a positive before/after-effect regression with injected metadata failures. The independent node-queue counterexample remains: queue closure is still not a join of every SDK child.

Read-only media output participates in the source store lock for both cached and direct-download publication. This closes that specific independent-writer path. It changes the former convenience behavior: a read-only output attempt cannot publish while a different process holds that store's lock. It does **not** grant ownership of the output directory, lock another store, or stop a foreign process.

See the [exact-base patch series and explicit synthetic verifier](../patches/wacli/README.md). All inputs are synthetic; no account, chat, credential or personal media is used.

## Enforced media-root policy: no unproven roots

Capture remains denied **before any source discovery or I/O**, for every root, including apparently private store-local roots. There is no approval label, root allowlist, force flag or caller-supplied receipt that enables it. Unsupported referenced roots cannot be silently omitted because no capture can be published in the first place.

A store lock excludes cooperating writers of that store, not another store using the same external root. Writable/cache/delegated output paths also need a common ownership contract before an all-media frontier can be claimed. A symlink-free path, single link count, mode 0700, stable hash, root lock, or read-only bind view is not proof that an independent writer or existing writable descriptor cannot change the underlying bytes. The runtime patches deliberately do not introduce a misleading per-directory advisory lock or call it exclusive ownership.

A supported platform backend would need an enforceable guarantee that the captured filesystem objects and their namespace cannot be mutated during enumeration and copy: no foreign writer, retained writable handle, alias, mount/path replacement, shared-store publication, rename or deletion. Alternatively, a fully isolated producer-owned environment could enforce that guarantee from process and descriptor creation onward. Existing arbitrary shared output roots do not meet either contract.

## The missing upstream lifecycle API

A whole-client API such as `BeginDrain(ctx) (HeldBoundary, error)` must atomically seal **all** roots, and return a held boundary only after every accepted operation and registered causal descendant completes. The name is illustrative, not an API provided by this change. Required coverage includes socket frame/disconnect callbacks, already-started reconnects, pairing, keepalive, node-handler children, receipts, retries/timers, history, app-state recovery, privacy-token workers and application callback continuations.

Registration must happen before launch and remain legal for descendants of an active accepted scope after root sealing. A finished scope must not register new children. A zero-worker observation must therefore be stable. Cancellation, failed persistence, callback failure or close failure must prevent a successful boundary, with errors retained even when a worker only logged them previously. Stores must remain available to accepted multi-store continuations; waiting only for SQL calls would still split logical operations.

WACLI must use that API behind one admission owner, including CLI/delegate operations, callback-spawned work and media/path publication. Its raw `DB()`/`WA()` accessors and previously borrowed handles are not revoked by the new lazy-open check. Callback removal is also narrower than a causal drain: the pinned SDK's `RemoveEventHandler` takes a write lock and **does wait for synchronous dispatches** holding the read lock, but does not track work those callbacks already launched.

These APIs and ownership guarantees are substantial but implementable. This is **not a claim of technical impossibility**. A narrow worker join, process exit, successful SQLite close or filesystem snapshot cannot substitute for the missing application frontier.

## Validation limits

The runtime series must pass its explicit synthetic verifier, repeated plain/race boundary tests and the WACLI repository gate before publication. Tests use local IPC, fake endpoints, generic synthetic SQL effects, disposable message metadata and synthetic media bytes. Generic SQL effects are not a real WhatsApp session-schema or linked-account acceptance test.

**No Windows runtime was run.** Any standard Windows cross-compilation is only compilation. Even a future verified Linux capture still requires version/schema acceptance, account mapping, media relocation, non-overwriting activation, message/search/media checks and linked-device usability verification. Preserving bytes cannot guarantee the server will continue accepting the credentials.
