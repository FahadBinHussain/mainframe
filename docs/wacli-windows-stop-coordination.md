# Windows stop/copy/restart needs an enforced owner

**Decision: keep capture disabled. A small coordinator around the existing Mainframe entry points cannot establish global writer exclusion or verified clean close.** No stop/restart wrapper is added. This is a source assessment, not a Windows runtime acceptance result.

## Where ownership escapes today

The references below describe merged Mainframe `184272d`.

| Existing path | What it does | Missing guarantee |
| --- | --- | --- |
| [`whatsapp-account.ps1:232–239`](../whatsapp-account.ps1#L232-L239) | `login` creates metadata and launches `pwsh -NoExit -Command "wacli auth ..."` in another window. | No retained WACLI process handle, readiness/close acknowledgment, launch admission gate or service identity. The shell can outlive its child; shell exit is not a clean-close receipt. |
| [`whatsapp-account.ps1:281–288`](../whatsapp-account.ps1#L281-L288) | `run` resolves the store and invokes arbitrary WACLI arguments through PATH. | No distinction between a one-shot command and an approved long-lived service; no durable ownership/restart record or relaunch fence. |
| [`whatsapp-account.ps1:111–132`](../whatsapp-account.ps1#L111-L132) | Store resolution can use configured external state or copy legacy state into the profile. Both `env` and `run` call it. | Coordination only around process launch would miss resolver writes. This legacy copy is skip-tolerant and is not a backup boundary. |
| [`whatsapp-account.ps1:269–278`](../whatsapp-account.ps1#L269-L278) | `env` exposes the selected store and bare binary name. | There is no mediated storage capability; another launcher can access that same store directly. |
| [`go-allowed.json`](../go-allowed.json), [`restore.ps1:1385–1426`](../restore.ps1#L1385-L1426) | Declare WACLI installation and put the ordinary Go binary directory on user PATH. | Installed/direct invocations are not required to pass through the account helper. Neither executable name nor a process-list match is an ownership identity. |
| [`backup.ps1:207–255`](../backup.ps1#L207-L255) | Native persist can stop a manifest-declared service and restart it in `finally`. | No WACLI service is registered by the account helper. This generic path treats every non-`Stopped` status as previously running, uses `Stop-Service -Force`, and suppresses restart errors; it cannot supply WACLI clean-close or complete process ownership. |
| [`backup.ps1:113–141`](../backup.ps1#L113-L141), [`backup-secrets.ps1:103–150`](../backup-secrets.ps1#L103-L150) | Generic copy paths can warn and continue after locked-file skips. | No strict complete-copy transaction, application drain or launch exclusion. Do not reuse their successful return as a WACLI capture receipt. |
| [`backup.ps1:168–187`](../backup.ps1#L168-L187), [`backup-secrets.ps1:43–62`](../backup-secrets.ps1#L43-L62) | Reject detected Windows WhatsApp SQLite state before generic copying, including the guarded VSS-remapped path. | These are refusal guards, not all-writer coordination or proof that every alternate/custom store is protected. Leave them unchanged. |
| [`wacli_state.py:97–103`](../wacli_state.py#L97-L103), [`162–164`](../wacli_state.py#L162-L164), [`wacli_snapshot.py:22–48`](../wacli_snapshot.py#L22-L48) | Public native/coordinated capture refuses before source I/O. | Intentionally no enabled boundary backend. `--quiesced` cannot change that. |

## Exact reason a wrapper is insufficient

A coordinator can serialize calls that voluntarily enter it. It cannot stop a direct WACLI invocation, another executable name, an already-open SQLite/media handle, or a separate process sharing an approved external media root. A process scan is only an observation: a new writer can start between the scan and copy. A Windows named mutex or Job Object around helper children does not impose admission on those nonparticipants.

Stopping every known child still proves neither that every writer was known nor that accepted application work finished. Existing source patches improve selected producer lifetimes, but [both drain APIs deliberately refuse a held capture boundary](wacli-snapshot-held-capture-audit.md#why-no-held-capture-can-be-returned). Error-free close of known work, exit code zero, no sidecars, stable hashes, successful VSS and a caller-supplied receipt cannot substitute for the missing proof. Forced exit and timeout explicitly fail the clean-close requirement.

There is also no trustworthy WACLI-specific list of previously-running long-lived services. The generic native-persist service branch is not such a list: it does not classify the helper's detached authentication or arbitrary foreground commands, and it provides no WACLI acknowledgment or external-launch fence. Replaying stored arbitrary command lines could repeat sends, logout, deletion, authentication or other one-shot effects. This assessment runs none of those commands and stops/restarts nothing.

## Minimum architectural change

The first prerequisite is **an enforced Windows storage/launch owner, not another cooperative mutex**. A possible design is a broker/service under a restricted dedicated identity, with approved store, profile metadata and media roots inaccessible for mutation by ordinary direct/external launchers. Every helper path, including login, legacy import/store resolution and output publication, must use that owner. The broker must control which binaries and child tokens can access the data; merely running a service under the same unrestricted user is insufficient. Administrators and other privileged actors must be an explicit trust boundary, not silently claimed to be fenced.

This requires a separately designed provisioning/migration boundary: resolve aliases and reparse paths, reject shared/uncontrolled roots, and prove that no pre-existing writable handle or other granted identity remains outside ownership. Changing a DACL does not by itself revoke an already-open handle. Unknown ownership or inability to establish that initial boundary must refuse capture. A Job Object can help track broker children and prevent their escape, but is not by itself filesystem isolation. No permissions or service provisioning are changed here.

An enforced owner is necessary but not sufficient. It must also provide:

1. **Atomic admission sealing.** Serialize start versus capture for the complete approved input set before store/config resolution or any effect. Block concurrent starts and automatic relaunch until copy/validation or failed-attempt cleanup finishes. Bind authority to a broker-owned attempt/generation, not caller JSON or a PID alone. Broker crash/recovery must remain fail-closed, with no stale receipt authorizing capture.
2. **A producer-supported clean-close result.** Drain all accepted application work and descendants across both databases, metadata and media, then check persistence/close errors. Bind a structured result to the owned process/build, roots and attempt; observe termination using retained process identity. No generic `Ctrl+C`, exit code, timeout or force-kill can manufacture this result. The present incomplete drain APIs cannot supply it. This still needs a reviewed runtime contract, though a broker can avoid treating every Mainframe caller as a WACLI accessor migration.
3. **Strict copy and restart state.** Record typed, allowlisted long-lived service identities and their running state before sealing. Never infer restartability from a raw argv log or replay a one-shot command. Only services that were running before this attempt may be restarted. Keep exclusion across strict complete copy, private validation and cleanup; copy/archive failure leaves no publishable result and no overwritten prior backup. Recovery must report restart failures separately from capture status and must not turn an unsuccessful attempt into success.

If either storage exclusion or the producer clean-close contract cannot be implemented and verified, stop/copy/restart remains unavailable. A crash-consistent alternative would be a different explicit guarantee and must not be relabeled as clean application capture.

## Acceptance gate for a future implementation

Use disposable synthetic roots, SQL/media fixtures and fake services only. Before enabling any capture, real Windows tests must cover the enforced boundary as well as the controller:

- Concurrent managed starts versus sealing; direct/unmanaged writers denied by the actual storage boundary; pre-existing handles, alternate paths and shared external roots rejected when exclusion cannot be proved.
- Graceful stop timeout, forced exit, close/persistence failure, missing/stale/foreign acknowledgment and an unknown writer all block copy/publication. A positive clean-close result must be tied to the actual owned process and complete input membership, not a forged file.
- Copy, archive and validation failures clean up only this attempt, preserve previous backups, and exercise recovery while exclusion remains held.
- Previously-running long-lived services restart once according to typed policy; initially stopped services remain stopped; one-shot commands are never replayed. Broker/controller crash and restart failures must not reopen an unverified capture path.

Existing synthetic Python/AST-isolated PowerShell tests verify refusal and offline preparation behavior only. They do not certify Windows ACLs, service tokens, process lifetime, global exclusion, clean close or restoration usability. No simulated controller test is offered as proof of an operating-system boundary that does not exist.

The 45-call group patch stays shelved. No upstream PR/contact, global instruction edits, real account access, WACLI activation or capture enablement is part of this decision. [The remaining Windows-to-Linux restoration gates](linux-wacli-windows-parity.md) still apply after any future boundary work.
