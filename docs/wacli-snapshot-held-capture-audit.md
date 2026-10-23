# Lifecycle API and immutable media work: capture is still disabled

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

## A separate immutable-content policy now has code

The new Linux media implementation does not claim ownership of arbitrary external roots. It enumerates the pinned schema's nonempty `messages.local_path` and `message_local_media_aliases.local_path` references, including duplicate and orphan references, and stages **separate content objects** in kernel-sealed `memfd` files. Every object's actual bytes are hashed again after write/grow/shrink/seal locks are installed, so a writable descriptor obtained before sealing cannot make the returned object's contents differ from its recorded plaintext fingerprint. Originals are never modified or deleted. A known length is checked; zero/NULL lengths remain unspecified, matching WACLI's existing metadata semantics.

Missing objects, absent or malformed fingerprints, orphan metadata, changed bytes, unsupported platforms/kernels, cancellation or resource limits fail the entire set. Neither enumeration nor staging returns a successful truncated set. The current limits are 1,024 references/descriptors and 256 MiB of staged bytes; exceeding them refuses the operation instead of discarding referenced user data. Nonblocking opens reject FIFOs and other special files. Original aliases and namespaces remain unowned, but cannot mutate successfully verified sealed objects.

The independent `wacli store verify-media` diagnostic reports only `verified-byte-objects-only`, `boundary: UNVERIFIED`, `complete: false`, `capture_enabled: false` and `publishable: false`, and closes the temporary objects after reporting. Database membership is not held across producer activity, blank local paths do not prove remote attachments are downloaded, and no capture/relocation/activation path consumes this diagnostic as authority. A future producer still needs a complete lifecycle hold, a complete pinned-schema membership definition, a retained sealed-object manifest and explicit restored-reference mapping before this policy can support an archive.

## The proposed upstream lifecycle API is deliberately incomplete

The coupled SDK source proposal now provides `BeginDrain(ctx) (*HeldBoundary, error)` and operation scopes with registration-before-launch, child registration, idempotent finish, sticky worker errors and cancel/retry behavior. WACLI calls it before closing stores and adds explicit application-owned delegate admission. **The SDK and application APIs never return a successful held boundary in this series.** Ordinary error-free close still means only that known close/drain operations did not fail; it is never a capture receipt.

The production handler-loop scope is admitted before launch; its handler callback scopes are admitted before their goroutines and remain live after the queue's `closeWait` notification if a callback is still running. Empty expected disconnect is distinct from dropping queued/dequeued work, whose cancellation is retained. The new API joins those registered callbacks, unlike queue-close notification alone. It does not own frames, overflow-enqueue goroutines or arbitrary new work spawned by callbacks, and it does not turn callback context propagation into automatic descendant registration.

Review hardening adds owner-requested cancellation of admitted delegate contexts before ordinary close joins them. The join remains unbounded and stores stay open until the real operation returns; an operation that ignores cancellation cannot be made safe by a close timeout. Generic explicit operations and public `BeginDrain` retain their join-without-cancel behavior. SDK coverage errors are distinguishable from operational causes without dropping either; recovered node-handler panics are logged immediately with a stack and retained as drain failures. Dropped queued work still fails closed rather than being relabeled as benign disconnect.

A whole-client implementation must atomically seal **all** roots and return a held boundary only after every accepted operation and registered causal descendant completes. Required coverage still includes socket frame/disconnect callbacks, already-started reconnects, pairing, keepalive, unregistered descendants of node handlers, receipts, retries/timers, history, app-state recovery, privacy-token workers and application callback continuations.

Registration must happen before launch and remain legal for descendants of an active accepted scope after root sealing. A finished scope must not register new children. A zero-worker observation must therefore be stable. Cancellation, failed persistence, callback failure or close failure must prevent a successful boundary, with errors retained even when a worker only logged them previously. Stores must remain available to accepted multi-store continuations; waiting only for SQL calls would still split logical operations.

WACLI must use that API behind one admission owner, including CLI/delegate operations, callback-spawned work and media/path publication. Its raw `DB()`/`WA()` accessors and previously borrowed handles are not revoked by the new lazy-open check. Callback removal is also narrower than a causal drain: the pinned SDK's `RemoveEventHandler` takes a write lock and **does wait for synchronous dispatches** holding the read lock, but does not track work those callbacks already launched.

These APIs and ownership guarantees are substantial but implementable. This is **not a claim of technical impossibility**. A narrow worker join, process exit, successful SQLite close or filesystem snapshot cannot substitute for the missing application frontier.

## Upstream status

The SDK implementation is unsubmitted and unaccepted. Its [contribution policy](https://docs.mau.fi/bridges/general/contributing.html) requires a prior maintainer discussion in Matrix for nontrivial changes and says human-facing proposal text must not be AI-written. No automated SDK PR or maintainer message was sent. The code remains an exact-base, synthetic-tested source proposal; a human discussion and author-written submission are still needed. A separate WACLI media-only proposal does not imply SDK lifecycle acceptance or a usable restore.

The independently buildable media-only change is pushed to [the WACLI fork branch](https://github.com/FahadBinHussain/wacli/tree/feat-sealed-media-membership), at commit `4db74bd4a3a42af3ac453d3d53bf72bd58d9ed50`. Its full repository gate and repeated plain/race synthetic tests pass. Upstream PR creation was refused with `Resource not accessible by integration (createPullRequest)`. No upstream WACLI PR was created, merged or accepted; a human with the required GitHub permission would need to submit it. The ready proposal text is not itself an upstream review.

## Validation limits

The runtime series must pass its explicit synthetic verifier, repeated plain/race boundary tests and the WACLI repository gate before publication. Tests use local IPC, fake endpoints, generic synthetic SQL effects, disposable message metadata and synthetic media bytes. Generic SQL effects are not a real WhatsApp session-schema or linked-account acceptance test.

**No Windows runtime was run.** Any standard Windows cross-compilation is only compilation. Even a future verified Linux capture still requires version/schema acceptance, account mapping, media relocation, non-overwriting activation, message/search/media checks and linked-device usability verification. Preserving bytes cannot guarantee the server will continue accepting the credentials.
