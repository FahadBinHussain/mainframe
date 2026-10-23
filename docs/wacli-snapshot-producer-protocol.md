# WACLI snapshot command proposal and Mainframe integration

**This is a matched command/consumer proposal, not a working account backup.** Mainframe capture stays blocked. No source databases, credentials, chats or personal media were read; development uses synthetic fixtures only. No Windows validation or complete Linux restoration is claimed.

The [producer lifecycle follow-up](wacli-snapshot-producer-lifecycle.md) documents dependency-owned work that outlives queue/wrapper shutdown, WACLI's existing partial drains, and unresolved media membership. It adds offline counterexamples, not an enabled backend or a new trusted receipt format.

## What is ready

The [WACLI patch](../patches/wacli/0001-blocked-snapshot-protocol.patch) proposes `wacli store snapshot plan` and a fail-closed `create` command. It is based on upstream commit `5578d1b6892f50a8f2329b11a6b6e27a1a81f88b`, not Mainframe's older Linux target pin. It is a reviewable source proposal: it has not been accepted upstream, released, installed or activated. Applying it does not unlock capture.

The Mainframe command below accepts a bounded capability document on standard input. It never starts a WACLI executable, resolves an account/store, reads a snapshot, requests a password, encrypts an artifact or publishes a backup:

```sh
python3 wacli_snapshot.py check-producer < synthetic-blocked-plan.json
```

A recognized blocked plan returns exit **3**, not success. Invalid or unsupported input returns exit **2** with a fixed diagnostic. Existing `plan`, `capture` and `wacli_state.py plan-coordinated-capture` behavior is unchanged. No production backup or restore path calls the new inspector automatically.

Do not probe an arbitrary executable just to obtain this document. Runtime binary trust and provenance are separate prerequisites; a matching JSON document is not proof of either. In particular, `producer_verified`, `snapshot_consumed`, `capture_enabled`, `publishable` and `complete` remain false.

## The exact information contract

The proposed producer emits one plain JSON object, without a generic `success`/`data` wrapper. The required fields are:

```json
{
  "protocol": "wacli-coordinated-snapshot-v1",
  "status": "blocked",
  "capture_enabled": false,
  "complete": false,
  "publishable": false,
  "boundary": "UNVERIFIED",
  "cross_database_consistency": "NOT_CERTIFIED",
  "windows_validated": false
}
```

Mainframe's [pure-bytes inspector](../wacli_snapshot_protocol.py) bounds input at 16 KiB, checks exact JSON types and rejects duplicate keys, non-standard constants, unsupported versions and any required field claiming successful capture. Unknown optional fields are ignored and never reflected in output. Even a receipt, artifact hash or `VERIFIED` claim in an optional field cannot enable capture. The parser recognizes only a blocked plan; it does not implement or accept a capture receipt.

The stdin command expects a finite input document. It does not provide process sandboxing, producer execution, an execution timeout, artifact discovery or receipt verification. Those capabilities are deliberately absent, not inferred from parsing success.

## Why a lock plus two SQLite backups is not enough

`session.db`, `wacli.db`, app-state/contact work, metadata and media do not share a single transaction. WACLI's cooperative `LOCK` excludes cooperating commands, not arbitrary SQLite or media writers. Event idleness and `App.Close()` are not evidence of a source-wide fence. Sequentially valid SQLite backups can still describe incompatible account states. Raw byte preservation and SQLite integrity checks are useful but cannot repair a torn source boundary.

A [source-level writer audit and deterministic counterexamples](wacli-snapshot-writer-boundary.md) identify an unjoined delegated-handler shutdown path, dependency-owned asynchronous work, and external-media membership gaps. The diagnostic tests demonstrate why capture must remain blocked; they do not implement a backend.

A useful future producer must establish and hold a reviewed boundary across all approved inputs, drain in-flight work, preserve originals including sidecars, and create derived databases separately. Membership, source/build evidence and consistency guarantees must be validated independently; a producer's own success string is not authority. The detailed [capture safety requirements](wacli-windows-capture-safety.md) and [non-publishable preparation implementation](wacli-snapshot-preparation.md) remain in force.

## Linux can use a different supported method

A Linux-native backend does not inherently require a Windows run. It does require real Linux acceptance tests for its own writer boundary, complete media/input membership, failure behavior and authenticated byte-preserving round trip. A single coordinated filesystem snapshot may establish a crash-consistent boundary, but that is not automatically application/account-consistent; unsupported guarantees must still fail closed.

Windows-origin capture remains a separate route: the Windows computer is offline, so Windows ACL/share modes, `LockFileEx`, coordinated VSS and Windows publication tests remain unvalidated. Linux fixtures do not validate them. This change adds no enabled backend on either platform.

After capture, [schema compatibility, account/config mapping, external-media relocation, non-overwriting activation and actual usability](linux-wacli-windows-parity.md) still need separate implementation and validation. A linked-device credential can also be revoked externally; preservation of all backed-up bytes cannot promise perpetual server-side login validity. The user's goal of fully usable Linux restoration is therefore still unmet, not silently redefined as a file-copy success.

## Validation boundaries

Synthetic tests cover strict parsing, private-value non-disclosure, forged success/receipt claims, input limits and no-I/O refusal. Existing staged SQLite/WAL/hot-journal and AES candidate tests remain separate from producer-boundary acceptance. Optional AES skips must be reported as skips; they are not encryption passes. WACLI patch validation and toolchain limitations are recorded in the patch directory README and the Mainframe pull request.
