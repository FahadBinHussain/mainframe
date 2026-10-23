# Producer admission is extended; capture is still disabled

The exact-base series now extends **production source and synthetic tests**, not just this audit. The new WACLI `0007` and SDK `0003` patches are **unsubmitted and unaccepted upstream**. They do not create a usable account restore, enable capture, install code, or authorize source-account access. Mainframe does not apply or run them automatically. **Linux restore and capture remain incomplete.**

## What is now registered and joined

The SDK uses one root-admission mutex for explicit operations, node-loop/handler scopes and key-share roots. `BeginDrain` seals that common gate before waiting on any sub-registry. An accepted scope can register a causal child after sealing; each child has its own token and can register grandchildren after an ancestor finishes. A finished token cannot register work. Registration is before launch, and errors and recovered worker panics are retained.

The source extensions cover the visible socket connection/read/write/disconnect workers, queued-node callbacks and overflow enqueue, reconnect and keepalive callbacks, pairing completion, receipts/acknowledgments, retries, history workers, app-state/key-share/missing-key descendants, protocol notifications, privacy-token workers and event dispatch continuations. Socket connection setup is itself admitted before side effects; failed connection setup releases its scope and lock. A Noise write that outlives its caller's cancellation remains registered until the actual write returns, with its error retained. QR cancellation, emitters and handler cleanup are joined rather than detached.

WACLI adds distinct causal operation tokens and cancellation ownership that survives a command returning while its accepted child still runs. All production bounded-send callers use an owner-aware adapter; the attempt's actual goroutine has a child lease, so its timeout is not its lifetime. Bounded presence attempts use the same pattern. Context-aware application callbacks are admitted before effects and can pass application plus SDK lineage onward. The delegate listener joins accepted handlers, and a media handler now closes and joins its disconnect-reader child before returning. Application close stays unbounded while accepted effects still run; a timeout is not permission to close their stores.

Review hardening removes the send adapter's unscoped compatibility fallback. Missing owners or operation scopes refuse before worker launch; already-canceled attempts finish registration without starting send effects. Synthetic doubles now supply genuine test-only application scopes instead of relying on a production bypass. Regressions verify both refusals and canceled-attempt behavior.

External review also hardens history-consumer startup/rejection and carries accepted lineage through the remaining audited undecryptable-message and offline-preview dispatches. Media panics retain immediate structured/stderr stack diagnostics as well as a drain failure. Successful terminal logout is distinct from unexpected reconnect failure; cancellation of its joined reconnect child is normalized only when that logout requested it.

SDK legacy void producers cannot return every launch rejection to their caller. Rejections are retained as drain failures, not evidence that work was accepted. A regression discards a launch result deliberately and verifies that the callback never executes and the later drain retains both admission and coverage errors. Causal child registration after sealing preserves ownership of accepted work; it is not permission to ignore cancellation or begin arbitrary new effects. Callback cooperation and complete error propagation remain unproven.

The source inventory gates enumerate raw goroutine sites and reject newly unreviewed worker classes. They are review guards, **not proof that arbitrary callback-created work, driver activity, filesystem writers or public handles are owned**. Timer waits inside a registered worker are included in that worker's lifetime; timers and callbacks are also listed by the source inventory for review. No timer count is treated as a capture receipt.

## Why no held capture can be returned

Both production `BeginDrain` APIs still return a nil held boundary and an explicit coverage error, even after all registered work has finished. The SDK's `LifecycleCoverageGaps()` returns a fresh, fixed gap list; a caller cannot approve, remove or override it. Known operational errors remain distinguishable from coverage refusal. Ordinary error-free close means only that the known joined operations did not fail.

Failure retention is deliberately conservative: a later successful retry does not prove an earlier attempt had no partial persistence effects, so it does not clear that attempt's drain failure. A regression preserves this distinction between command success and lifecycle evidence. Each registry retains its first operational cause, not an exhaustive error history; later failures can be masked diagnostically, but cannot turn a failed drain into success. Broader bounded multi-cause diagnostics remain follow-up work, not a capture prerequisite satisfied by this series.

Remaining gaps are concrete:

- Public synchronous SDK methods, `Store`, `DangerousInternals`, application `DB()`/`WA()` and previously borrowed handles are not a revocable admission facade. A source audit of goroutine creation cannot fence every direct synchronous call.
- Legacy/void handlers and arbitrary user callbacks can start unregistered work or discard lineage. The additive context API helps cooperative code; it cannot force an external callback to use it. Some existing callback continuations still capture their outer context, and void callbacks cannot return all persistence errors.
- Standalone socket callers can omit the additive hooks. Foreign HTTP transports, SQL drivers, already-open writable descriptors, shared stores and independent processes remain outside the client owner.
- Queued frame/node membership and every previously log-only persistence continuation have not been verified as a whole-client logical frontier. A narrow join is not an exhaustive cross-database transaction boundary.
- Media still needs an immutable retained membership set tied to that complete producer frontier, plus restored-reference mapping and platform-enforced ownership or isolation.

These are implementable missing guarantees, not a claim of technical impossibility. If any class cannot be comprehensively registered, its gap stays explicit. No force flag, caller-supplied receipt, approval label or root allowlist turns this series into capture authority. Snapshot create remains denied before source discovery or I/O; unsupported roots cannot be silently omitted from a successful archive because no archive can be published.

## Immutable media remains a separate diagnostic

The existing Linux media code enumerates the pinned schema's nonempty `messages.local_path` and `message_local_media_aliases.local_path` references, retaining duplicate and orphan references. It stages separate content objects in kernel-sealed `memfd` files and hashes their actual bytes after write/grow/shrink/seal locks are installed. Originals are not modified or deleted. Known lengths are checked; zero/NULL lengths remain unspecified.

Missing objects or fingerprints, malformed/orphan metadata, changed bytes, unsupported platforms/kernels, cancellation, special files or resource limits fail the entire set. Limits remain 1,024 references/descriptors and 256 MiB of staged bytes; there is no successful truncated set. A pre-existing writable descriptor cannot change a successfully verified sealed object's recorded bytes, but this does not own the original namespace or database membership.

`store verify-media` still reports only `verified-byte-objects-only`, `boundary: UNVERIFIED`, `complete: false`, `capture_enabled: false` and `publishable: false`, then closes its descriptors. It is not an archive, relocation or activation operation. A store lock excludes cooperating writers of that store only; a stable hash, mode 0700, a symlink-free path or a read-only bind view does not exclude independent writers or retained writable handles.

## Reproducible checks and limits

The [SHA-256-pinned exact-base series and disposable verifier](../patches/wacli/README.md) apply seven WACLI and three SDK patches to pristine pinned source, never to the working source or an installed account. Focused admission, descendant, callback, socket, timeout-surviving worker, membership and refusal tests run repeatedly both plain and with the race detector. The full gate additionally checks the SDK suite/vet and the WACLI repository's format, lint, dead-code, tests, build and documentation commands. Any failed gate remains a failed gate; source inventory and synthetic tests are not account acceptance.

The extended series passed that complete disposable `--full-gate` run, including ten plain and ten race repetitions of the focused tests, unchanged blocked capability output, and create refusal with synthetic source bytes left untouched. Mainframe's synthetic test suite and artifact/digest contract tests also passed. Application media, backfill, webhook and reconnect workers are registered before launch; media/webhook regressions verify that recovered panics and previously log-only job failures remain drain failures.

Fixtures use fake transports, local IPC, disposable synthetic SQL/metadata and synthetic media bytes. No real account, secret, chat, database or personal media is used. A positive held-boundary timing test exercises only an internal synthetic fully enumerated owner; there is no production opt-in or exported coverage-approval switch.

**No Windows runtime was run.** Any Windows cross-compilation is compilation only. A future usable restore still requires version/schema acceptance, account mapping, media relocation, non-overwriting activation, message/search/media checks and linked-device usability verification. Preserving bytes does not guarantee server acceptance of credentials.

## Upstream status is unchanged

The SDK contribution policy requires [prior maintainer discussion and human-written proposal text](https://docs.mau.fi/bridges/general/contributing.html). No upstream WACLI or SDK PR or maintainer message accompanies this extension. The new lifecycle/source patches are stored for separate Mainframe review only; they remain unsubmitted and unaccepted upstream. Mainframe integration is not upstream acceptance or runtime installation.

The separate media-only proposal remains on [the user's WACLI fork branch](https://github.com/FahadBinHussain/wacli/tree/feat-sealed-media-membership), previously recorded at `4db74bd4a3a42af3ac453d3d53bf72bd58d9ed50`. The integration previously refused upstream PR creation with `Resource not accessible by integration (createPullRequest)`. That branch was not changed by this extension; it does not imply SDK acceptance or a usable restore.
