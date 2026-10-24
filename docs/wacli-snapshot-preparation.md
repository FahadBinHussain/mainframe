# WACLI snapshot preparation: useful building blocks, not source capture

**Coordinated live/Windows capture is still blocked.** This change prepares the SQLite-and-encryption part of a future snapshot operation. It does not establish a shared capture boundary, recover missing historical WAL, migrate a Windows account, or make a linked device usable on Linux. No real account or backup is used in development.

## What can be exercised now

The private engine in [`wacli_snapshot_stage.py`](../wacli_snapshot_stage.py) works only on an explicitly supplied, already-private staged store. It preserves raw staged files separately from derived `wacli.db` and `session.db` snapshots. SQLite recovery and online backup happen on a separate scratch copy, never on the supplied input or preserved originals. Unknown files, sidecars and schema objects are not silently filtered out.

This is **preparation**, not a capture attestation. Its versioned preparation receipt records file hashes, SQLite observations and schema metadata, but keeps the capture boundary and historical producer unverified and the result non-publishable. A staged tree may already be torn across its two databases or media. An integrity check, matching version numbers, or a caller-written receipt cannot fix or certify that.

The private engine requires Python 3.11+ with the SQLite backup API and supported POSIX descriptor-relative/no-follow filesystem operations. Other platforms fail before staging. Its source and output parents must be caller-controlled private working directories, not attacker-controlled trees. Input reads traverse every ancestor without following links; this still does not certify a source-wide writer boundary. Windows preparation/capture is not enabled by this implementation.

Full schema definitions can themselves contain sensitive literals, names and trigger/view SQL. The receipt is therefore **sensitive private data**, not a safe log or public provenance document. Only recognized version-table columns are read; arbitrary table/view shapes fail. Schema definitions remain intact in private staging and the encrypted candidate to satisfy lossless preservation, never in public CLI output.

The private integration in [`wacli_snapshot.py`](../wacli_snapshot.py) tests the existing container layout: `mainframe-secrets.zip`, WinZip AES-256, containing `tool-secrets.zip`. It verifies authenticated decryption and exact byte hashes before returning a candidate inside a caller-owned private workspace. It is not connected to a release publisher. Sensitive staging is temporary; cleanup is not secure erasure after a crash or process kill.

The low-level preparation destination is reserved exclusively and its completion receipt is written last. It is not an atomic durable backup publication. A killed process or failed cleanup can leave private plaintext staging; an existing/partial destination must be reviewed and cannot be reused or considered complete. Normal integration scopes all preparation and encryption inside a private temporary context and removes that context on normal exit or exceptions. Cleanup failures return fixed diagnostics, not private filesystem errors. No startup process scans or deletes a user's directories automatically.

The candidate's inner members use **`WacliPreparation/v1/`**, not either existing restore prefix. That is deliberately a non-restorable development candidate, not a new accepted Windows capture receipt or an alternative plaintext export. Existing `restore-unlocked` cannot activate it. It must never replace an existing machine secret envelope.

## Mainframe integration stays fail-closed

These public preflights return a fixed JSON report and exit **3** for blocked:

```sh
python3 wacli_snapshot.py plan
python3 wacli_state.py plan-coordinated-capture
python3 wacli_snapshot.py capture \
  --source-root /approved/source \
  --destination /approved/new-output
```

Even the `capture` operation reads neither path, asks for no password, loads no encryption provider, and creates no artifact. There is no `--force`, `--quiesced`, receipt-import, or lock-only override. The legacy native `wacli_state.py capture --quiesced` path is now also unconditionally disabled: caller attestation cannot substitute for writer ownership and launch exclusion. Its `snapshot()` API refuses too; offline export and metadata sidecar checks remain available. The Windows native helper retains a writerless VSS copy implementation, but the integrated backup now fails closed before export for WACLI state because supported metadata cannot prove coverage of media paths stored only in SQLite. Any future permitted payload remains crash-consistent only and does not enable the no-I/O or coordinated capture APIs.

## Upstream command proposal, not a snapshot backend

The earlier reviewed [WACLI v0.15.0 source](https://github.com/openclaw/wacli/tree/a020de724180d31eccfa5241d45443402d62fb06) has no coordinated snapshot command. Its `sync --once` waits for event idleness, not a global writer fence. `App.Close` closes separate stores, and the cooperative `LOCK` cannot fence unrelated SQLite or media writers. Adding an offline wrapper around those behaviors would give a misleading success signal, not the required guarantee.

A subsequent [paired producer proposal and Mainframe inspector](wacli-snapshot-producer-protocol.md) adds a reviewable patch against newer upstream source. Its plan is informational and its create command remains no-I/O blocked. The patch is not an upstream release or an accepted snapshot backend, and a matching capability document cannot authorize capture.

A future application-consistent backend would need a defined writer-fencing/draining protocol covering both DBs, app-state work, metadata, and all approved media inputs. A coordinated crash-consistent VSS backend is another possible route for Windows, but must cover every approved input volume and pass actual Windows tests. A separately supported Linux-native route may use different methods and needs its own Linux boundary/round-trip acceptance, not a Windows run. No backend is implemented here.

## Tests and the next gate

Synthetic fixtures cover WAL-derived complete databases alongside unchanged raw bytes, unknown files/schema, schema observations, path/input rejection, failure cleanup, no-I/O public capture refusal, and the AES candidate integration. Wrong passwords, changed authentication data, truncation and missing encryption support must fail. Optional encryption tests explicitly skip if the provider is absent; a skip is not a pass.

**No Windows run has occurred.** Windows ACL/share modes, `LockFileEx`, VSS coordination, actual multi-writer boundaries, disk exhaustion and Windows end-to-end publication still require the acceptance tests in [the capture safety contract](wacli-windows-capture-safety.md). The preparation receipt is not evidence that those tests or a source boundary have passed.

After safe capture exists, full Windows-to-Linux restoration still needs the [separate schema, profile-selection, external-media relocation, activation and usability work](linux-wacli-windows-parity.md). `complete` remains false.

The isolated [Windows-client VSS requester experiment](wacli-windows-client-vss.md) prepares a native single-set API path for review. It is not connected to capture, does not provide a held WACLI boundary, and does not satisfy any real-Windows acceptance gate. Writerless VSS remains crash-consistent only; the full producer drain is still required for an application-consistency claim.
