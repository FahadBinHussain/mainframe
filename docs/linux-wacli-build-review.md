# WACLI exact Linux build review

## Status: planned, not tested or executable

The exact declaration remains `github.com/openclaw/wacli/cmd/wacli@v0.15.0`
with `sqlite_fts5`. Its planner status is **planned**, with dry-plan metadata
`standard-linux-go-install`. This describes a normal Linux Go installation, not
a portable binary or an isolated-`HOME` contract. Normal explicit `GOBIN`
controls the binary destination; otherwise Go uses the first `GOPATH/bin`
(normally `~/go/bin`). Normal module and build caches are retained. No
portable/isolated HOME requirement is part of this plan.

Execution is categorically disabled before any adapter preflight: no toolchain,
module, compiler, archive, install, build, runtime, or state operation has been
performed. No allowlist, backup, secret, PATH, HOME, cache, or profile changes
are made. **Planned does not mean tested, installed, or executable.**

The old complex isolation contract is superseded for the current WACLI review;
it may be cited as design history, but it is not a mandatory condition of this
normal-install dry plan. The existing observation status `blocked` is a
historical integrity/execution observation, not the status of this dry plan.

## Source, module, and build prerequisites

The [v0.15.0 release](https://github.com/openclaw/wacli/releases/tag/v0.15.0)
publishes Linux amd64 and arm64 artifacts, but this declaration selects source
Go, not a prebuilt release. Its [annotated tag](https://api.github.com/repos/openclaw/wacli/git/tags/51f8c4a41df7eaf6a4342140679679a29b58be18)
resolves to commit `a020de724180d31eccfa5241d45443402d62fb06`; GitHub reports
the tag signature verified. This is source provenance, not a locally built
executable checksum.

The pinned [go.mod](https://raw.githubusercontent.com/openclaw/wacli/v0.15.0/go.mod)
declares module `github.com/openclaw/wacli`, **Go 1.25.12**, and
`github.com/mattn/go-sqlite3 v1.14.48`, with no replace/exclude directives. The
[README](https://raw.githubusercontent.com/openclaw/wacli/v0.15.0/README.md)
also requires Go 1.25.12 or newer. A dependency's suggested `toolchain go1.26.5`
does not silently select 1.26.5.

The README requires `CGO_ENABLED=1`, a C compiler, and
`CGO_CFLAGS=-Wno-error=missing-braces`; Debian/Ubuntu `build-essential` is only
a recommendation. The non-CGO guard blocks CGO-disabled builds. The Linux
release configuration uses CGO and `sqlite_fts5` for amd64/arm64, with
`aarch64-linux-gnu-gcc` for arm64 cross-builds. The selected go-sqlite3 release
bundles the SQLite C amalgamation; its FTS5 option enables `SQLITE_ENABLE_FTS5`
and links `-lm`. A compatible native compiler/linker, libc development
headers, and libm linkage are prerequisites. A separate system libsqlite3 or
FTS5 package is **not** required; adding the `libsqlite3` tag would be a
different build. Optional ffmpeg is not a compile prerequisite.

## Official Go candidate metadata

The official [Go release JSON](https://go.dev/dl/?mode=json&include=all)
contains these exact Go **1.25.12** native Linux candidates:

| Target | Official filename | Bytes | SHA-256 |
| --- | --- | ---: | --- |
| x86_64 / amd64 | `go1.25.12.linux-amd64.tar.gz` | 59856753 | `234828b7a89e0e303d2556310ee549fbcf253d28de937bac3da13d6294262ac1` |
| aarch64 / arm64 | `go1.25.12.linux-arm64.tar.gz` | 57351753 | `8b5884aef89600aef5b0b051fb971f11f49bb996521e911f30f02a66884f7bd2` |

These are official metadata observations of a **candidate**, not downloaded or
locally verified bytes, a selected host toolchain, or a security-preferred
version. Later versions require their own provenance review; `>=1.25.12` is
not a floating pin. No toolchain on PATH is selected.

## Dependency evidence and its limits

The root module's v0.15.0 checksum-database lookup records module
`h1:7FAcz3o4zSlMvgDcWlhjpmwpkLwLKMY4bWnOopv2FXA=` and go.mod
`h1:D5vWmRbYq/RK9ZPLyfdirrkAJVX/noLioSasjliT1MM=`. The root module declares
**31 exact requirements (9 direct, 22 indirect)** and
its [go.sum](https://raw.githubusercontent.com/openclaw/wacli/v0.15.0/go.sum)
contains **89 records (39 module-content h1 and 50 go.mod h1 records)**; every
declared requirement has both records. For go-sqlite3, public checksum lookup
matches the root file: module `h1:7XHIgl0a8HwOaiK4E47ozLkST78rR9+OtNGx27D/TFs=`
and go.mod `h1:6JTjA44L93a0QCyJef5YvlPoKXntQPjzWv5gtm9sB6w=`. The root module's
version/commit and h1 evidence remain separate checks: a working tree is not
authenticated by its own go.sum.

These are text and metadata observations, not signed proof, downloaded-byte
verification, a complete platform/tag-specific build closure, or a local
build. Equality between go.sum h1 strings and checksum-database lookup text is
not a verified signature or Merkle inclusion/consistency proof. A future Go
sumdb verifier must fail closed if authentication, content, or the reviewed
resolved graph cannot be established. `go mod verify` alone does not download
missing content or establish the initial trust chain.

Version-suffixed `go install package@version` ignores the caller's go.mod and
go.sum; the upstream root go.sum is evidence, not an install lock. A future
adapter must therefore review the command's resolved graph and content rather
than claim that the caller's module files govern it. `GOTOOLCHAIN=local` must
be used so Go cannot auto-download another toolchain.

## Adapter and recovery boundary

The dry plan records the normal command shape, including explicit
`GOBIN` when supplied and the original `sqlite_fts5` tag. It does not perform
effective-path checks, download metadata/content, invoke Go or a compiler, or
validate libc/libm/sysroot suitability. Those checks remain preflight work, and
all execution stays disabled before that preflight.

PR28 is explicit and stopped: the caller selects and stops all writers, makes
a clean-state encrypted capture, and may perform a **NEW offline export**.
There is no live-WAL capture, migration, account activation, or automatic
full-backup integration. The state helper preserves raw state only and grants
no installation permission; see [WACLI state](linux-wacli-state.md).

The original declaration and proposed `go install -tags sqlite_fts5
github.com/openclaw/wacli/cmd/wacli@v0.15.0` remain visible for planning, not
execution. No prebuilt release or existing global binary is substituted.
