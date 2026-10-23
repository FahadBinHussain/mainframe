# WACLI: exact Linux build review

## Result: keep the build blocked

The tracked `go-allowed.json` and the external recovery control manifest both select `github.com/openclaw/wacli/cmd/wacli@v0.15.0` with exactly `sqlite_fts5`. The planner preserves that declaration and proposed command. It does not build, run, install, download a toolchain, or substitute a prebuilt release or an existing global binary. No allowlist, backup, secret, PATH or home/cache configuration changes are made.

Linux support and a valid version pin are established. A generic `go install` is still not a safe executable restore action: the current planner has no reviewed Go/compiler/dependency or isolated-destination contract. Explicitly setting GOBIN alone would not isolate module, build, temporary and configuration writes. This review adds precise diagnostics and offline regression tests, not a Go executor or a validated build plan.

## Exact source and module metadata

The official [v0.15.0 release](https://github.com/openclaw/wacli/releases/tag/v0.15.0) publishes Linux amd64 and arm64 artifacts, but the declaration selects source `go`, not those artifacts. The [annotated tag](https://api.github.com/repos/openclaw/wacli/git/tags/51f8c4a41df7eaf6a4342140679679a29b58be18) resolves to commit `a020de724180d31eccfa5241d45443402d62fb06`; GitHub reports the tag signature verified. That is source provenance evidence, not a checksum of a locally built executable.

The pinned [go.mod](https://raw.githubusercontent.com/openclaw/wacli/v0.15.0/go.mod) declares module `github.com/openclaw/wacli`, **Go 1.25.12**, and `github.com/mattn/go-sqlite3 v1.14.48`. There are no replace/exclude directives. The [README](https://raw.githubusercontent.com/openclaw/wacli/v0.15.0/README.md) independently requires Go 1.25.12 or newer. The inspected direct dependency go directives do not exceed that minimum. The pinned whatsmeow module recommends `toolchain go1.26.5`; a dependency's suggested toolchain is not itself a new minimum or a reason to silently select 1.26.5.

The sqlite dependency's [proxy metadata](https://proxy.golang.org/github.com/mattn/go-sqlite3/@v/v1.14.48.info) records origin commit `0cfec603061a73376109c4a6178e38f86b544dd6`; its [module file](https://proxy.golang.org/github.com/mattn/go-sqlite3/@v/v1.14.48.mod) declares Go 1.21. The public [checksum record](https://sum.golang.org/lookup/github.com/mattn/go-sqlite3@v1.14.48) matches the pinned [WACLI go.sum](https://raw.githubusercontent.com/openclaw/wacli/v0.15.0/go.sum):

- Module: `h1:7XHIgl0a8HwOaiK4E47ozLkST78rR9+OtNGx27D/TFs=`.
- go.mod: `h1:6JTjA44L93a0QCyJef5YvlPoKXntQPjzWv5gtm9sB6w=`.

These metadata checks are not verification of downloaded archives, a complete resolved transitive dependency closure, or a local build. Go module h1 sums are not release archive SHA-256 hashes.

## CGO and SQLite FTS5 requirements

The versioned README requires **CGO_ENABLED=1**, a C compiler, and `CGO_CFLAGS=-Wno-error=missing-braces`; it recommends Debian/Ubuntu `build-essential`. Its [non-CGO guard](https://raw.githubusercontent.com/openclaw/wacli/v0.15.0/cmd/wacli/cgo_required.go) deliberately prevents CGO-disabled builds. The [Linux release configuration](https://raw.githubusercontent.com/openclaw/wacli/v0.15.0/.goreleaser-linux-windows.yaml) uses CGO and `sqlite_fts5` for amd64/arm64; arm64 cross-building uses `aarch64-linux-gnu-gcc`. This is platform support evidence, not target-host runtime validation.

The selected go-sqlite3 version uses its [bundled SQLite C amalgamation](https://raw.githubusercontent.com/mattn/go-sqlite3/v1.14.48/sqlite3.go). Its [FTS5 option](https://raw.githubusercontent.com/mattn/go-sqlite3/v1.14.48/sqlite3_opt_fts5.go) adds `SQLITE_ENABLE_FTS5` and links `-lm`. It therefore needs a compatible native compiler/linker, libc development headers and math-library linkage, **not a separate system libsqlite3/FTS5 package**. Selecting the additional `libsqlite3` tag would be a different build and is outside this review. The optional runtime media helper ffmpeg is not a prerequisite for compiling this declaration.

## Missing inputs before a build could be planned safely

A future implementation must supply and validate all of the following before any selected operation changes the machine:

1. An explicit existing absolute Go executable, exact version/provenance and supported native architecture, meeting Go >=1.25.12; an explicit compatible C compiler/linker, libc headers and libm. A distro `golang-go` action or a PATH lookup does not prove those facts. Cross-compilation requires a separate reviewed target/sysroot contract.
2. A full resolved module/dependency integrity policy and checksum verification, not just the root version or sqlite hashes. Fix approved proxy/checksum services; do not inherit private-module bypasses, disabled checksum verification, arbitrary VCS/credential helpers, or direct-network fallbacks. No source-build or generated-code hooks outside the reviewed Go/C compilation path may be inferred.
3. Explicit new, absolute, isolated GOBIN, GOPATH (also checksum-state routing), GOMODCACHE, GOCACHE, GOTMPDIR/TMPDIR and working directories; isolated HOME/XDG configuration/state roots. Reject missing, overlapping, existing or symlink destinations and protected source/recovery/live-home roots before any earlier selected action. No PATH/profile changes.
4. A controlled child environment: `GOTOOLCHAIN=local` prevents automatic toolchain selection/download; `GOENV=off`, `GOWORK=off`, a reviewed GOFLAGS policy, explicit CGO_ENABLED and compiler/C/LD flags, and removal of ambient wrappers/overrides such as GOCACHEPROG. Pin the existing toolchain instead of fetching one. See [Go toolchain selection](https://go.dev/doc/toolchain). A too-old toolchain must fail, not fall back.
5. An exact-version command using only the original tag and build tag, with output confined to the isolated bin root and no invocation of WACLI afterward. Source builds must use verified exact source in an isolated working tree; `go build package@version` is not an equivalent supported replacement. [Version-suffixed go install](https://go.dev/ref/mod#go-install) has no main module and ignores the caller's module; a caller-side lock file must not be assumed to govern it.

No actual root paths, compiler/toolchain provenance or verified complete dependency closure were supplied/validated in this review. No Go install/build adapter, root contract or executor is enabled. The exact declaration remains blocked even if someone constructs a nominally planned Go action manually; tests assert rejection before earlier selected APT preflight or mutation, including explicit-Go build and cached-global-binary proposals.

## Next item (not reviewed here)

The next exact blocker outside Scoop/WinGet is `pip-freeze.txt`, source the recovered control manifest, currently blocked because it includes Windows-only requirements (including pywin32 when present). Python translation/environment work is outside this WACLI-only change.
