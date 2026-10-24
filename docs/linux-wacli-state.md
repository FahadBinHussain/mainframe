# WACLI: capture blocked, explicit offline export only

**No source capture is enabled.** `--quiesced` is legacy syntax, not proof that all writers have stopped or cannot restart. Both native capture APIs refuse before inspecting paths, loading encryption providers, asking for passwords, or creating output. The coordinated capture command remains blocked too. A complete Windows-to-Linux WhatsApp restore is not implemented or validated.

## What is available

`wacli_state.py plan --state-root /approved/state-root` inspects filenames and metadata only. It does not parse config, messages, SQL rows, session credentials or tokens. It reports `capture_enabled: false`. SQLite WAL/SHM/journal files, links, special files and unsafe names still block this inspection; nothing is deleted or checkpointed.

`python3 wacli_state.py plan-coordinated-capture` reads no source and exits 3 with fixed blocked diagnostics. The legacy capture syntax also exits 3 without source or destination access:

```sh
python3 wacli_state.py capture --state-root /approved/state-root \
  --quiesced --destination /approved/new-backup-directory
```

Neither that flag nor an absent sidecar, an advisory `LOCK`, stable metadata, process exit, a supplied receipt or successful VSS creation authorizes capture. `snapshot()` and `capture()` raise `StateError` unconditionally, including when `quiesced=True`; no private lock-only copying backend remains.

Normal Linux installation is still a separate dry plan, not a tested installation or runtime. This helper never installs, builds, runs or authenticates WACLI, changes HOME/PATH, or opens a production backup during development. See [the build review](linux-wacli-build-review.md).

## Why stop/copy/restart is not yet sound

The current [Windows account helper](../whatsapp-account.ps1) launches authentication in a detached PowerShell window and invokes arbitrary WACLI commands directly. It does not register process identities or long-running service ownership, prove clean application shutdown, or hold an admission gate that excludes new launches. Mainframe has no reliable inventory of independent SQLite/media writers or retained writable handles. A process-name scan or forced kill cannot supply that missing proof.

A future backend must establish all of the following before copying:

1. Explicit complete membership of every approved database, config and media root, and an enforceable all-writer ownership/admission boundary held through the entire copy.
2. A bounded, verified clean stop and close for every writer. Unknown writers, forced termination, timeout, failed close, unproven clean shutdown, or **any** SQLite `-wal`, `-shm` or `-journal` must fail closed. No sidecar deletion, source checkpoint, direct-copy fallback or `immutable` retry.
3. Identity-based records of which long-running services were actually running before capture. Restart only those services; never replay authentication, send, import or other one-shot commands, and never start an initially stopped service. Restart failure must be reported honestly.
4. Synthetic Windows acceptance evidence for launch races, uncontrolled writers, held handles, clean-close failure, timeout, sidecars, interrupted/failed copy and safe restart. Linux mocks or cross-compilation alone are not Windows validation.

No stop/restart wrapper is added while these primitives are absent: it could interrupt legitimate work without establishing a safe snapshot. The native Windows helper retains a writerless VSS byte-copy implementation, but the integrated backup now fails closed before export when WACLI state exists because metadata cannot prove coverage of media paths referenced only inside SQLite. Its source guards remain strict for live/non-VSS paths; any future verified VSS export would remain crash-consistent only, not application-consistent or restore activation. See [the Windows safety audit](wacli-windows-capture-safety.md) and [the shutdown boundary evidence](wacli-snapshot-shutdown-boundary.md).

## Explicit offline export remains available

Normal `linux_restore.py` recovery keeps the encrypted envelope opaque and never decrypts it. Native ZIP members are not automatically activated or home-staged by `--apply-portable`.

After the owner separately authorizes and performs the normal secret-archive unlock flow, an existing compatible `tool-secrets.zip` can be exported to a **new offline directory**:

```sh
python3 wacli_state.py restore-unlocked \
  --archive /approved/unlocked/tool-secrets.zip \
  --destination /approved/new-offline-wacli-state
```

Only `NativeState/wacli/` is exported. Raw bytes are retained, directories are 0700 and files 0600. Traversal, links, encrypted members, duplicates, case/Unicode collisions, conflicting paths, SQLite sidecars and oversized data block export. There is no live-home merge, schema conversion, config editing, implicit destination or account activation. Publication never overwrites an existing destination; a failed publication may leave a new partial directory that must not be reused blindly.

An offline export is not a validated WhatsApp login or evidence that an older archive was captured consistently. Windows `%APPDATA%/mainframe/accounts/whatsapp` profiles are not remapped to Linux state. External stores, absolute media paths, account selection, schema compatibility, producer provenance and linked-device usability remain separate gaps in [the Windows parity review](linux-wacli-windows-parity.md). `complete` remains false.

## Synthetic tests, not account validation

Tests construct temporary SQLite databases and offline ZIP fixtures directly; disabled capture is never used to manufacture fixtures. API tests assert refusal before path inspection, reads, provider loading or publication. CLI tests cover both legacy flag states and require blocked, non-publishable, incomplete, no-source-read diagnostics. Metadata/sidecar rejection and offline export tests remain in place.

Private [snapshot preparation](wacli-snapshot-preparation.md) encryption tests exercise only `WacliPreparation/v1/` candidates with an explicitly unverified receipt, never publishable native state. Optional AES tests skip when their provider is unavailable; a skip is not a pass. No real account, secret archive, WACLI execution or real Windows capture is used or claimed.
