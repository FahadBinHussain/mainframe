# WACLI snapshot capability proposal

`0001-blocked-snapshot-protocol.patch` is a source-only proposal for [openclaw/wacli](https://github.com/openclaw/wacli). Mainframe does not apply, build, install or execute it automatically. It is not accepted upstream or released. Both WACLI `create` and Mainframe capture remain blocked; this patch cannot produce or certify an account snapshot.

Base: `5578d1b6892f50a8f2329b11a6b6e27a1a81f88b`.

Proposal commit: `a46c1511744a943ffb8da700f954093de5b6c1b9`.

The patch uses zero context and no mail signature to keep the stored artifact whitespace-clean. It was checked with `git apply --check --unidiff-zero` against a clean detached checkout of the exact base. A maintainer reviewing it may use the following only inside a separate disposable source checkout at that exact base:

```sh
git apply --check --unidiff-zero /path/to/0001-blocked-snapshot-protocol.patch
git apply --unidiff-zero /path/to/0001-blocked-snapshot-protocol.patch
```

Do not apply a zero-context patch to another base or an installed/production tree. Never treat patch application as permission to access an account, run capture, publish a backup or activate restored state.

The proposed `wacli store snapshot plan` emits one plain JSON object with the eight required blocked fields. Its exit 0 means the capability report was printed, not that capture succeeded. `create` refuses with a nonzero error before store/config resolution, lock acquisition, app construction or source I/O. No source/destination/receipt override is offered. Mainframe's independent `check-producer` exits 3 even for this recognized blocked report.

The producer changes passed the complete repository gate using the already-present Go 1.27.3 compiler first in PATH: `pnpm format:check && pnpm lint && pnpm lint:deadcode && pnpm test && pnpm build && pnpm docs:site && git diff --check`. This includes plain and FTS Go tests, Windows lock/store cross-compilation, the CGO-required guard, and all 32 documentation/release-script tests. The initial package-script lint attempt selected the older system Go and failed the repository's Go version requirement; no version requirement, dependency declaration or build tooling was changed. Existing declared Go tool dependencies were downloaded by the normal gate.

A compiled CLI was also exercised against a temporary synthetic HOME and source containing only dummy files. Its plan bytes were consumed by Mainframe's inspector, which returned blocked exit 3 with no authority enabled. Create and override flags refused; synthetic file metadata and the empty temporary HOME remained unchanged. This tests command/consumer interoperability and refusal, not capture-boundary correctness or a usable account restoration.

All tests use synthetic/offline fixtures. Windows lock cross-compilation, if performed by the repository test script, is not a Windows runtime test. No account backup/restore or Windows validation is implied. See [the matched protocol and remaining restoration gates](../../docs/wacli-snapshot-producer-protocol.md).

## Synthetic writer-boundary diagnostic

`0002-synthetic-writer-boundary-probe.patch` adds only a diagnostic Go test. Apply it after `0001` in a disposable checkout of the exact base above, never an installed tree:

```sh
git apply --check /path/to/0002-synthetic-writer-boundary-probe.patch
git apply /path/to/0002-synthetic-writer-boundary-probe.patch
go test ./cmd/wacli -run '^TestSnapshotBoundaryProbe' -count=10 -v -timeout 60s
go test -race ./cmd/wacli -run '^TestSnapshotBoundaryProbe' -count=10 -v -timeout 60s
```

Use the repository-required Go toolchain, without weakening its version declaration. The test uses a temporary local IPC endpoint and an inert channel-gated executor; it does not construct an account app or open databases. It demonstrates that the current delegate stop returns while an accepted executor is still running. A passing probe confirms a missing handler join, **not** a safe snapshot boundary. If shutdown semantics are fixed, this counterexample should fail and be replaced by a proper drain regression as part of that fix. Windows runtime behavior is not covered.

See [the precise source audit and Mainframe counterexamples](../../docs/wacli-snapshot-writer-boundary.md). Neither patch enables capture, and Mainframe never applies or runs either one automatically.

## Dependency admission/drain counterexamples

`0003-synthetic-dependency-boundary-probes.patch` adds two diagnostic tests under `internal/wa`. Apply it after `0001` (and optionally `0002`) to the same disposable checkout of base `5578d1b6892f50a8f2329b11a6b6e27a1a81f88b`; it changes no production code or dependency versions:

```sh
git apply --check /path/to/0003-synthetic-dependency-boundary-probes.patch
git apply /path/to/0003-synthetic-dependency-boundary-probes.patch
go test ./internal/wa -run '^TestSnapshotDependencyProbe' -count=10 -v -timeout 90s
go test -race ./internal/wa -run '^TestSnapshotDependencyProbe' -count=10 -v -timeout 90s
```

Use the repository-required Go 1.27.3 toolchain, without changing `go.mod`. The tests use pinned whatsmeow `v0.0.0-20261017175727-b2b1e71d45e2` and in-memory fake persistence endpoints. No SQL database, network connection, account, credential or personal media is opened. Test-only `DangerousInternals` injects synthetic input into the real protocol handler/queue. The first fixture requires no identity; the second has a dummy in-memory JID solely to pass the node parser, with no paired session or authentication.

One test holds a dependency key-store call across actual WACLI wrapper close, then observes its in-memory session write and the real key guard's fake app-metadata write. It has no SQL container, so it demonstrates missing producer joining, not successful SQL writes after real database closure. The other closes the real dependency queue while a child node handler is blocked. It tests queue-close semantics directly, not a connected websocket. Both are counterexamples: passing tests confirm an unresolved boundary, **not** capture success. Future lifecycle fixes should replace them with positive drain regression tests rather than silently weakening their assertions.

See the [complete producer lifecycle and exact remaining boundary](../../docs/wacli-snapshot-producer-lifecycle.md). Neither these diagnostics nor Mainframe's synthetic media-reference preservation test implements producer admission, dependency draining, media discovery/relocation, capture, or usable account restoration. No Windows run is implied.

## Shutdown and approved-root counterexamples

`0004-synthetic-shutdown-boundary-probes.patch` adds only diagnostic Go tests. Apply it after `0001` and `0003` (with `0002` optional) in a disposable checkout of the exact base above. It reuses `0003`'s fake version-store and bounded channel-wait helper; no runtime code, dependency or build tooling changes:

```sh
git apply --check /path/to/0004-synthetic-shutdown-boundary-probes.patch
git apply /path/to/0004-synthetic-shutdown-boundary-probes.patch
go test ./internal/wa ./cmd/wacli -run '^TestSnapshotShutdownProbe' -count=10 -v -timeout 90s
go test -race ./internal/wa ./cmd/wacli -run '^TestSnapshotShutdownProbe' -count=10 -v -timeout 90s
```

Use Go 1.27.3, without editing `go.mod`. The key-share fixture runs the real detached dependency worker and WACLI key guard, then actual wrapper/container close followed by app-database close. A generic synthetic session SQL adapter pauses before or after its SQL effect; it stores no actual session keys and is not a real WhatsApp session schema. The accepted worker subsequently loses its SQL effect or fails its app-metadata continuation. Both disposable databases still pass integrity checks. This models the relative store-close ordering, not a full `App.Close` or connected-client integration test.

The media fixture uses the real CLI path in a separate helper process against disposable synthetic metadata and verified cache bytes. It proves `--read-only media download --output` publishes outside the store despite a held store lock, verified by competing lock acquisition before and after. It opens no WhatsApp connection or session database. No real account, database, credentials, chats or personal media is accessed.

Passing counterexamples mean the audited shutdown/root boundary remains unsafe; they do not certify capture or restore. Replace them with positive contract tests when the corresponding semantics are actually fixed. See [the shutdown feasibility result and complete required contract](../../docs/wacli-snapshot-shutdown-boundary.md). Capture remains disabled and no Windows runtime validation is claimed.

## Runtime admission and narrow dependency drain

`0005-runtime-admission-and-keyshare-drain.patch` is **production-code source**, not another diagnostics-only patch. Apply it after all of `0001`–`0004` to the exact WACLI base above. It requires the coupled `whatsmeow/0001-scoped-keyshare-drain.patch` against the exact declared dependency `go.mau.fi/whatsmeow@v0.0.0-20261017175727-b2b1e71d45e2`. Neither patch is installed, released or accepted upstream by this repository. Mainframe does not run them automatically.

The WACLI changes join accepted delegate handlers, seal lazy application opens during an idempotent close, retain errors through an additive `CloseWithError`, join the SDK's narrow key-share boundary before session SQL closure, and make explicit read-only media publication participate in its store lock. Compatibility `Close()` APIs still discard their returned error; they must not be used as a capture receipt. The SDK changes register protocol key-share work before launch, preserve accepted detached contexts, join explicitly scoped missing-key request children, reject late admission, and retain the first worker failure. The first retained failure is enough to deny a successful frontier without an unbounded lifetime error list.

The former delegate and key-share SQL-loss tests become positive regressions rather than being skipped. Coverage includes both sides of the first synthetic SQL effect, application metadata failures, concurrent/idempotent close, idle drains, repeated batches, cancel/retry, child registration after sealing, grandchildren and rejection after parent completion. The node-queue counterexample remains. The media diagnostic now verifies **both** the fixed read-only path and the still-independent writable cache-output path, so it does not pretend that all media writers are fenced.

## Lifecycle API and sealed-content membership

`0006-lifecycle-api-and-sealed-media-membership.patch` and the coupled `whatsmeow/0002-lifecycle-scopes-and-handler-drain.patch` add production source and synthetic tests, not just documentation. Apply them after the existing series. WACLI now seals explicit delegated-operation admission and calls an additive SDK `BeginDrain` before stores close. The SDK registers a handler-loop scope before production launch and child scopes before handler goroutines, so the new drain waits for actual handler return even when `closeWait` has already closed. Cancellation of queued or dequeued-but-not-started work remains an error. Generic operation scopes support descendants after root sealing, idempotent finish and sticky errors. Contexts are caller-selected bookkeeping, not an exhaustive cancellation/ownership façade.

This is deliberately **not** admission of every queued frame, overflow-enqueue goroutine, socket/disconnect callback, timer, reconnect, history worker or arbitrary callback descendant. Raw public handles and DangerousInternals remain escapes. Both WACLI and SDK APIs always refuse a whole-client held boundary; ordinary close and queue-close notifications are not receipts. A proposed enqueue-map approach with a shutdown race was removed before publication rather than being described as a safe queue boundary.

The Linux media code implements an alternative immutable **content-object** policy: enumerate every persisted local path/alias in the pinned schema, retain duplicates and orphan references, stage bytes in `memfd` files, install kernel write/grow/shrink/seal locks, then hash the actual sealed bytes again against the stored plaintext fingerprint. Missing or malformed metadata, missing/changed data, cancellation, unsupported kernels/platforms or the 1,024-reference/descriptor and 256 MiB limits refuse the entire set. No successful truncated set is returned and originals are never deleted. The `store verify-media` diagnostic reports `complete: false`, `publishable: false` and `boundary: UNVERIFIED`; its descriptors close after reporting, so it is not an archive or a whole-store membership hold.

The independent media-only WACLI branch is [pushed but not accepted upstream](https://github.com/FahadBinHussain/wacli/tree/feat-sealed-media-membership). The GitHub integration was not permitted to open its upstream PR. No SDK PR was submitted: its contribution policy requires a prior maintainer discussion and human-written proposal. Mainframe's patches remain source-only, and no Linux account restoration or Windows runtime validation is claimed. See [the updated implementation/ownership audit](../../docs/wacli-snapshot-held-capture-audit.md).

### Explicit disposable verifier

With the repository-required Go 1.27.3 toolchain first in `PATH`, run:

```sh
python3 patches/wacli/verify_runtime.py --wacli-source /path/to/existing/wacli-source
# Optional complete WACLI repository gate in the same disposable source tree:
python3 patches/wacli/verify_runtime.py --wacli-source /path/to/existing/wacli-source --full-gate
```

The source repository only needs to contain the exact pinned base object; its current branch and uncommitted files are not used. The verifier checks the SHA-256 manifest, archives the exact base into a temporary directory, applies the six WACLI patches, obtains the pinned dependency through Go's normal checksum-verified module download, copies it without editing the module cache, applies the two SDK patches, and sets a local `replace` **only inside the disposable tree**. It runs ten repetitions of the focused WACLI/SDK tests both plain and with `-race`, including SQL membership, immutable objects and real handler-child regressions, checks the unchanged blocked plan, and tests create refusal against disposable dummy bytes. Temporary HOME/XDG paths are used; no account source is discovered. Public Go/tool dependencies may be downloaded. The optional full gate additionally needs the existing pnpm/Node prerequisites and performs the standard Windows cross-compilation, not a Windows runtime run.

### What this does not authorize

Capture remains disabled, with a deny-all policy for unproven media-root ownership before source I/O and no approval/force override. `DrainAppStateKeyShares` does **not** join all SDK roots or arbitrary work spawned by event callbacks; the public/raw SDK and application handles are not an exhaustive admission façade. Read-only publication now blocks behind a held source-store lock, but writable/delegated cache output, other stores, aliases and foreign open handles are not thereby fenced. No held capture, media relocation, activation or Linux account-usability claim is made.

See [the exact remaining lifecycle API and platform ownership contract](../../docs/wacli-snapshot-held-capture-audit.md). These are implementable missing guarantees, not a claim of technical impossibility. Windows runtime validation has not been performed.
