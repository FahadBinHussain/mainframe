"""WACLI's exact standard Linux install proposal; no probes or executor."""
from __future__ import annotations
from wacli_restore_contract import restoration_status


def build_dry_plan(architecture: str) -> dict:
    """Return symbolic Go defaults, not observed paths or an installation lock."""
    artifacts = {
        "x86_64": ("amd64", 59856753, "234828b7a89e0e303d2556310ee549fbcf253d28de937bac3da13d6294262ac1"),
        "aarch64": ("arm64", 57351753, "8b5884aef89600aef5b0b051fb971f11f49bb996521e911f30f02a66884f7bd2"),
    }
    arch, size, checksum = artifacts[architecture]
    return {
        "route": "standard-linux-go-install",
        "dry_only": True,
        "execution_supported": False,
        "build_tested": False,
        "runtime_tested": False,
        "restoration": restoration_status(),
        "paths": {
            "kind": "symbolic Go defaults; not effective-path observations",
            "GOBIN": "explicit absolute GOBIN, otherwise first GOPATH entry/bin (normally ~/go/bin)",
            "binary": "<effective GOBIN>/wacli",
            "GOPATH": "configured GOPATH, otherwise ~/go",
            "GOMODCACHE": "configured GOMODCACHE, otherwise first GOPATH entry/pkg/mod",
            "GOCACHE": "configured GOCACHE, otherwise $XDG_CACHE_HOME/go-build or ~/.cache/go-build",
            "temporary": "configured GOTMPDIR, otherwise normal OS temporary directory",
            "policy": "normal Go module/build caches; no portable bundle or isolated HOME required; no paths created or changed",
        },
        "prerequisites": {
            "minimum_go": "1.25.12",
            "native_target": "linux/" + arch,
            "compiler": "native C compiler/linker, libc development headers and libm; Debian/Ubuntu build-essential is upstream guidance, not a host check",
            "sqlite": "bundled github.com/mattn/go-sqlite3 v1.14.48; sqlite_fts5 tag; no external libsqlite3/FTS5 package needed",
            "environment": {
                "CGO_ENABLED": "1",
                "CGO_CFLAGS": "-Wno-error=missing-braces",
                "GOTOOLCHAIN": "local",
                "GOPROXY": "https://proxy.golang.org",
                "GOSUMDB": "sum.golang.org",
                "GOVCS": "*:off",
                "GOPRIVATE": "",
                "GONOPROXY": "",
                "GONOSUMDB": "",
                "GOINSECURE": "",
            },
            "environment_scope": "proposal for a future child process only; no go env -w, HOME/PATH/profile changes or current environment mutation",
            "preflight": "future executor must inspect effective paths, existing binary overwrite, Go version/provenance, native compiler suitability and ambient GOENV/GOFLAGS/GOWORK/CGO/compiler overrides; do not infer these from distro package names",
        },
        "integrity": {
            "module": "github.com/openclaw/wacli",
            "version": "v0.15.0",
            "source_commit": "a020de724180d31eccfa5241d45443402d62fb06",
            "module_sum": "h1:7FAcz3o4zSlMvgDcWlhjpmwpkLwLKMY4bWnOopv2FXA=",
            "go_mod_sum": "h1:D5vWmRbYq/RK9ZPLyfdirrkAJVX/noLioSasjliT1MM=",
            "lookup_url": "https://sum.golang.org/lookup/github.com/openclaw/wacli@v0.15.0",
            "evidence": "docs/linux-wacli-integrity-observation.json",
            "declared_checksum_pairs": 31,
            "go_sum_records": 89,
            "verification_scope": "recorded upstream go.mod/go.sum and sumdb text equality only; not verified archive bytes, signed-log proofs or a resolved Linux build closure",
            "install_semantics": "version-suffixed go install ignores caller go.mod/go.sum; upstream go.sum is evidence, not an enforced install lock; future trusted Go must authenticate downloaded root/dependency content using sum.golang.org and fail on mismatch",
            "go_candidate": {
                "version": "go1.25.12",
                "url": "https://go.dev/dl/go1.25.12.linux-" + arch + ".tar.gz",
                "size": size,
                "sha256": checksum,
                "metadata_url": "https://go.dev/dl/?mode=json&include=all",
                "scope": "official minimum-version archive metadata, not downloaded/verified bytes or a supported/security-preferred release claim; no toolchain selected on this host",
            },
        },
        "state": {
            "separate_from_binary": True,
            "default": "~/.local/state/wacli",
            "legacy": "~/.wacli",
            "custom": "--store DIR / WACLI_STORE_DIR; externally referenced account stores need their own explicit capture",
            "preservation": "PR #28: explicit caller-selected stopped, clean state directory; encrypted capture and new offline export restore only",
            "not_supported": ["live WAL capture", "automatic full-backup integration", "Windows-to-Linux migration", "config relinking", "live account activation"],
            "documentation": "docs/linux-wacli-state.md",
        },
        "execution_blockers": [
            "No Go install executor; every selected Go action is rejected before package preflight or mutation.",
            "Host Go/compiler provenance, effective paths and existing binary overwrite checks have not been performed.",
            "Module bytes, signed checksum proofs and resolved build closure have not been verified here; build/runtime not tested.",
        ],
    }
