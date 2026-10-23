# WACLI: normal installation, recoverable user data

The WACLI declaration is **planned** with dry-plan metadata
`standard-linux-go-install`; planned does not mean tested, installed, or
executable. Portability is not required to preserve user data. Keep the normal
Go-installed binary (normally `~/go/bin/wacli`) separate from the state backup.
With normal explicit `GOBIN`, Go uses that destination; otherwise it uses the
first `GOPATH/bin` (normally `~/go/bin`) and normal module/build caches. No
portable or isolated-`HOME` requirement applies to this plan. All execution is
disabled before adapter preflight: this feature never installs, builds, runs,
or activates WACLI.

## What is covered

`wacli_state.py` captures raw file bytes, including hidden config, account
subdirectories, media and clean closed databases. It never parses config,
messages, SQL rows, session credentials or tokens. It reports counts/status only.
It never installs, builds, runs or authenticates WACLI, modifies HOME/PATH, or
opens a production backup during development.

The [official v0.15.0 account documentation](https://github.com/openclaw/wacli/blob/v0.15.0/docs/accounts.md)
places Linux state at `~/.local/state/wacli`, with existing legacy installs using
`~/.wacli`. Config is `<base>/config.yaml`. `--store DIR` and
`WACLI_STORE_DIR` select a custom store. Named accounts can refer to relative
or **absolute** external stores. This helper intentionally does not discover
HOME, parse the YAML, follow symlinks, or chase external stores: the caller must
supply each root to capture. One capture covers only that root. Absolute config
paths are preserved verbatim and may need deliberate relinking later; copying
config alone does not recover an external account store.

## Capture safely

Stop all WACLI processes **and any other writer** first. The helper requires
`--quiesced`, acquires nonblocking exclusive locks on every existing store
`LOCK`, and rejects a database without an existing sibling `LOCK`. It does not
create, truncate or read the lock's contents. This matches the upstream
[Unix flock implementation](https://github.com/openclaw/wacli/blob/v0.15.0/internal/lock/lock_unix.go)
and [LOCK naming](https://github.com/openclaw/wacli/blob/v0.15.0/internal/lock/lock.go).
Advisory locking is not protection against a non-cooperating writer; stopping
all writers remains a required attestation.

[WACLI uses WAL SQLite](https://github.com/openclaw/wacli/blob/v0.15.0/internal/store/db.go),
with `wacli.db` and `session.db` in each store
([official app source](https://github.com/openclaw/wacli/blob/v0.15.0/internal/app/app.go)).
**Any `-wal`, `-shm` or `-journal` file blocks capture.** None is excluded or
silently ignored, even if empty. Obtain a clean closed store through the
application's normal shutdown/recovery process; do not delete sidecars to
bypass the guard. There is no live online-backup adapter yet. Metadata before,
during and after copying must agree, or the snapshot is discarded. No SQLite
connection or checkpoint is made, preserving original database bytes.

Illustrative commands (use absolute caller-approved paths):

```sh
python3 wacli_state.py plan --state-root /approved/state-root
python3 wacli_state.py capture --state-root /approved/state-root \
  --quiesced --destination /approved/new-backup-directory
```

Planning reads filenames/metadata only. Capture requires Python 3.10+ and the
optional AES ZIP provider `pyzipper` (fixture-tested with 0.3.6 and
`pycryptodomex` 3.23.0). The helper does not install dependencies. Missing AES
support blocks capture before any state payload is read, with **no plaintext
fallback**. The password is requested interactively without terminal echo; it
is not accepted in command arguments or recorded in a manifest.

The new directory contains only `mainframe-secrets.zip`. It is a WinZip AES-256
envelope containing `tool-secrets.zip`, matching the existing release encryption
layout. Inside that ZIP the exact root bytes are under `NativeState/wacli/`.
The complete decrypted inner ZIP is hash-verified before publication. Sensitive
plaintext staging uses a private temporary directory and is cleaned on success
or exception (not a secure erase guarantee after process kill or host failure).
Destinations must be new, with existing real parents; symlink ancestry,
source overlap and live default WACLI state targets are rejected. Publication
never overwrites an existing directory/file; a failed publication may leave a
new partial destination, which must be reviewed rather than reused.

This standalone envelope is **not automatically appended** to an existing
machine backup or published. Existing backup/archive bytes are never modified.
Use the existing authorized archive/publication workflow deliberately if a
combined release is required; never replace a machine's existing secret envelope
with this single-root envelope (that would lose other secret items).

## PR28: explicit stopped capture and NEW offline export

PR28 remains caller-selected and stopped: the caller stops WACLI and every
other writer, captures a clean closed state into the encrypted envelope, and
explicitly requests a **NEW offline export**. It adds no live-WAL capture,
SQLite migration, account activation, or automatic full-backup integration.
The envelope is not silently merged into a machine backup.

## Explicit offline restoration

Normal `linux_restore.py` recovery preserves the encrypted envelope opaque and
never decrypts it. Even if native state is already present as loose ZIP members,
`--apply-portable` does not activate or automatically home-stage it.

After the owner explicitly authorizes and performs the normal secret-archive
unlock flow, restore from its resulting `tool-secrets.zip`:

```sh
python3 wacli_state.py restore-unlocked \
  --archive /approved/unlocked/tool-secrets.zip \
  --destination /approved/new-offline-wacli-state
```

Only `NativeState/wacli/` is restored. Raw bytes are retained, output directories
are 0700 and files 0600. Traversal, links, encrypted members, duplicates,
case/Unicode collisions, conflicting paths, SQLite sidecars and oversized data
block the export. There is no default destination, live-home merge, schema
conversion, automatic config editing or account activation. The final files
are verified after publication. An offline export is not a validated working
WhatsApp login; linked-device validity is controlled by WhatsApp.

The existing Windows `%APPDATA%/mainframe/accounts/whatsapp` layout stays a
Windows profile. It is never mapped to Linux WACLI state without a separately
proven schema migration. Windows restore preserves native payloads in its source
archive and reports them as not activated.

The [Windows parity review](linux-wacli-windows-parity.md) now records the
exact capture gaps, both upstream schemas, absolute media-path semantics and
profile-selection mismatch. A new `plan-windows-unlocked --archive /approved/unlocked/tool-secrets.zip`
assessment reads ZIP metadata only and always remains blocked/incomplete; it
does not supply missing provenance or snapshot consistency. Generic plans and
native capture/export reports separate installation, preservation, migration,
activation and usability, with `complete: false`.

## What still needs a separate action

Normal install plus **explicit clean-store encrypted capture/offline restore**
is covered. Automatic Linux scheduled capture, merging this state into a full
machine release, live-WAL capture, Windows-profile migration, config path
relinking and live account activation are not implemented. The Go build/install
executor remains blocked for the independent reasons in
[the build review](linux-wacli-build-review.md); this state feature grants no
installation permission. No portable binary package is needed or created.

Tests use synthetic state and dummy SQLite only, including an uncheckpointed WAL
that must block. AES round-trip tests need the optional provider and otherwise
skip explicitly; missing-provider blocking is always tested. Tests do not imply
a real account/runtime restore or cross-tool 7-Zip interoperability test.

## Coordinated snapshot preparation remains separate

`python3 wacli_state.py plan-coordinated-capture` exposes the new [preparation-only
snapshot milestone](wacli-snapshot-preparation.md). It reads no source and exits
3 with capture disabled. The private staged SQLite/candidate-encryption helpers
are not a live-WAL capture backend or an accepted Windows restore format. The
clean-store commands and all existing capture/activation restrictions above are
unchanged; no Windows capture run has been validated.
