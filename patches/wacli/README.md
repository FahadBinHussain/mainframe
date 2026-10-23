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

The producer changes passed focused snapshot tests, the complete plain Go test suite and `go vet` using the already-present compatible compiler at `/usr/local/go/bin/go`. The initial package-script lint attempt selected the older system Go and failed the repository's Go version requirement; no version requirement, dependency or tooling was changed. The full package-script gate is being rerun with the existing compatible compiler first in PATH; its final result is recorded in the Mainframe pull request.

All tests use synthetic/offline fixtures. Windows lock cross-compilation, if performed by the repository test script, is not a Windows runtime test. No account backup/restore or Windows validation is implied. See [the matched protocol and remaining restoration gates](../../docs/wacli-snapshot-producer-protocol.md).
