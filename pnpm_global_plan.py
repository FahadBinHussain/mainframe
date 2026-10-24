#!/usr/bin/env python3
"""Metadata-only global pnpm plans. No executor, subprocess, mkdir or config writes.

This is deliberately not a dependency solver or a process sandbox. Registry
metadata and proposed paths do not prove installed runtimes or contain scripts.
"""
from __future__ import annotations

import concurrent.futures
import hashlib
import json
import re
from pathlib import Path
from typing import Any, Mapping
from urllib.parse import quote

import github_native_linux as native
import node_lts_linux as node
import opencode2_linux as registry

REGISTRY = "https://registry.npmjs.org"
ROOT_KEYS = {"node", "pnpm", "pnpm_home", "global", "bin", "store", "cache",
             "config", "state", "data", "home", "temp", "work"}
VERSION = re.compile(r"(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\Z")
NAME = re.compile(r"(?:@[a-z0-9][a-z0-9._-]*/)?[a-z0-9][a-z0-9._-]*\Z")
HOOKS = {"preinstall", "install", "postinstall"}
MAX_DIRECT = 128


def _version(value: Any) -> tuple[int, int, int]:
    if not isinstance(value, str) or not VERSION.fullmatch(value):
        raise ValueError("Missing or unsafe exact stable version")
    return tuple(int(v) for v in value.split("."))


def satisfies(version: str, requirement: Any) -> bool:
    """Conservative engine evaluator; unknown grammar fails, never guesses."""
    actual = _version(version)
    if not isinstance(requirement, str) or not requirement.strip():
        raise ValueError("Missing Node engine requirement")
    alternatives = []
    for branch in requirement.split("||"):
        parts = re.findall(r"(>=|<=|>|<|=|\^|~)?\s*(\d+(?:\.\d+){0,2})", branch)
        remainder = re.sub(r"(>=|<=|>|<|=|\^|~)?\s*\d+(?:\.\d+){0,2}", "", branch)
        if not parts or remainder.strip():
            raise ValueError(f"Unsupported Node engine requirement: {requirement!r}")
        checks = []
        for op, raw in parts:
            values = tuple(int(v) for v in raw.split("."))
            target = values + (0,) * (3 - len(values))
            if op == ">=": good = actual >= target
            elif op == ">": good = actual > target
            elif op == "<=": good = actual <= target
            elif op == "<": good = actual < target
            elif op in {"^", "~"}:
                if op == "~": upper = (target[0], target[1] + 1, 0)
                elif target[0]: upper = (target[0] + 1, 0, 0)
                elif target[1]: upper = (0, target[1] + 1, 0)
                else: upper = (0, 0, target[2] + 1)
                good = target <= actual < upper
            else: good = actual[:len(values)] == values
            checks.append(good)
        alternatives.append(all(checks))
    return any(alternatives)


def validate_roots(values: Any, protected: tuple[Path, ...] = ()) -> dict[str, str]:
    if not isinstance(values, Mapping) or set(values) != ROOT_KEYS:
        raise ValueError("Explicit isolation roots required: " + ", ".join(sorted(ROOT_KEYS)))
    roots = {}
    for key, raw in values.items():
        if (not isinstance(raw, str) or not raw.startswith("/") or
                any(c in raw for c in "\x00\r\n") or "//" in raw or
                any(p in {".", "..", "~"} for p in raw.split("/"))):
            raise ValueError(f"Unsafe absolute isolation root: {key}")
        path = Path(raw)
        if str(path) != raw or len(path.parts) < 3:
            raise ValueError(f"Unsafe isolation root: {key}")
        # No system directories, live HOME, repo, or backup payload as a root.
        for forbidden in (Path.home(), Path("/etc"), Path("/usr"), Path("/bin"),
                          Path("/sbin"), Path("/lib"), Path("/lib64"), Path("/dev"),
                          Path("/proc"), Path("/sys"), Path("/boot"), *protected):
            forbidden = forbidden.absolute()
            if path == forbidden or path in forbidden.parents or forbidden in path.parents:
                raise ValueError(f"Isolation root overlaps a protected path: {key}")
        if path.exists() or path.is_symlink():
            raise ValueError(f"Isolation root must be new, not existing: {key}")
        for parent in path.parents:
            if parent.is_symlink() or (parent.exists() and not parent.is_dir()):
                raise ValueError(f"Unsafe isolation parent: {key}")
        roots[key] = raw
    paths = list(map(Path, roots.values()))
    for i, path in enumerate(paths):
        if any(path == other or path in other.parents or other in path.parents for other in paths[i + 1:]):
            raise ValueError("Isolation roots must be distinct and non-overlapping")
    return roots


def manifest(name: str, selector: str = "latest") -> dict[str, Any]:
    if not isinstance(name, str) or not NAME.fullmatch(name):
        raise ValueError("Invalid registry package name")
    if selector != "latest": _version(selector)
    source = f"{REGISTRY}/{quote(name, safe='@/')}/{selector}"
    meta = registry._json(source)
    if not isinstance(meta, Mapping) or meta.get("name") != name:
        raise ValueError("Registry source/package identity mismatch")
    version = meta.get("version"); _version(version)
    if selector != "latest" and version != selector:
        raise ValueError("Registry version mismatch")
    dist = meta.get("dist")
    url = f"{REGISTRY}/{name}/-/{name.rsplit('/', 1)[-1]}-{version}.tgz"
    if not isinstance(dist, Mapping) or dist.get("tarball") != url:
        raise ValueError("Missing or unsafe registry tarball source")
    integrity = registry._integrity(dist.get("integrity"))
    for key in ("scripts", "dependencies", "optionalDependencies", "peerDependencies", "peerDependenciesMeta", "engines"):
        if key in meta and not isinstance(meta[key], Mapping):
            raise ValueError(f"Invalid registry {key}")
    scripts = meta.get("scripts", {})
    if any(not isinstance(k, str) or not isinstance(v, str) or not v or
           any(c in v for c in "\x00\r\n") for k, v in scripts.items()):
        raise ValueError("Invalid registry script metadata")
    for key in ("dependencies", "optionalDependencies", "peerDependencies"):
        if any(not isinstance(k, str) or not NAME.fullmatch(k) or
               not isinstance(v, str) or not v or any(c in v for c in "\x00\r\n")
               for k, v in meta.get(key, {}).items()):
            raise ValueError("Invalid registry dependency metadata")
    peers = meta.get("peerDependenciesMeta", {})
    if any(not isinstance(k, str) or not NAME.fullmatch(k) or not isinstance(v, Mapping) or
           ("optional" in v and not isinstance(v["optional"], bool)) for k, v in peers.items()):
        raise ValueError("Invalid registry optional peer metadata")
    bundled = {k: meta[k] for k in ("bundledDependencies", "bundleDependencies") if k in meta}
    for value in bundled.values():
        if not isinstance(value, bool) and (not isinstance(value, list) or
                any(not isinstance(n, str) or not NAME.fullmatch(n) for n in value)):
            raise ValueError("Invalid registry bundled dependency metadata")
    for key in ("os", "cpu", "libc"):
        if key in meta and (not isinstance(meta[key], list) or any(
                not isinstance(v, str) or not v or any(c in v for c in "\x00\r\n") for v in meta[key])):
            raise ValueError("Invalid registry platform metadata")
    if "hasInstallScript" in meta and not isinstance(meta["hasInstallScript"], bool):
        raise ValueError("Invalid registry implicit build metadata")
    return {"name": name, "version": version,
            "source": f"{REGISTRY}/{name}/{version}", "selector_source": source,
            "tarball": url, "integrity": integrity,
            "engines": dict(meta.get("engines", {})),
            "install_scripts": {k: v for k, v in scripts.items() if k in HOOKS},
            "dependencies": dict(meta.get("dependencies", {})),
            "optional_dependencies": dict(meta.get("optionalDependencies", {})),
            "peer_dependencies": dict(meta.get("peerDependencies", {})),
            "peer_dependencies_meta": dict(peers), "bundled_dependencies": bundled,
            "has_install_script": meta.get("hasInstallScript"),
            "platform": {k: meta[k] for k in ("os", "cpu", "libc") if k in meta},
            "implicit_build_review": "binding.gyp and archive-only hooks unknown until verified artifact review",
            "bin": meta.get("bin")}


def pinned_manifest(name: str) -> dict[str, Any]:
    """Resolve latest once, then require the exact endpoint to agree.

    The comparison binds every recorded install-relevant field, not just SRI.
    This detects inconsistent metadata; it is not a tarball signature check.
    """
    selected = manifest(name)
    exact = manifest(name, selected["version"])
    if {k: v for k, v in selected.items() if k != "selector_source"} != {
            k: v for k, v in exact.items() if k != "selector_source"}:
        raise ValueError("Registry latest/exact metadata drift; re-plan before mutation")
    return selected


VERCEL_CLI_DOCS = "https://vercel.com/docs/cli"
VERCEL_NATIVE_PREFIX = "@vercel/vc-native-linux-"


def _vercel_cli_review(package: Mapping[str, Any], direct: list[dict[str, Any]]) -> dict[str, Any]:
    """Summarize Vercel's standard package/native opt-in without selecting or activating it."""
    if package.get("name") != "vercel":
        return {}
    reviewed = {item["name"]: item for item in direct}
    native_packages = []
    for dep_name, spec in sorted(package["optional_dependencies"].items()):
        if not dep_name.startswith(VERCEL_NATIVE_PREFIX):
            continue
        meta = reviewed.get(dep_name)
        exact_spec = isinstance(spec, str) and VERSION.fullmatch(spec) is not None
        if not exact_spec:
            metadata_status = "non-exact-range"
        elif meta is None:
            metadata_status = "exact-metadata-missing"
        elif meta.get("version") != spec:
            metadata_status = "version-mismatch"
        else:
            metadata_status = "exact-registry-metadata"
        exact = metadata_status == "exact-registry-metadata"
        platform = meta.get("platform", {}) if exact else {}
        native_packages.append({
            "name": dep_name,
            "declared_spec": spec,
            "metadata_status": metadata_status,
            "version": meta["version"] if exact else None,
            "integrity": meta["integrity"] if exact else None,
            "platform": platform,
            "platform_linux_confirmed": "linux" in platform.get("os", []),
            "lifecycle_hooks": meta["install_scripts"] if exact else {},
        })
    return {
        "version_selection": "live latest-registry observation; exact endpoint matched; not pinned in pnpm-allowed.json",
        "package_version": package["version"],
        "package_source": package["source"],
        "package_integrity": package["integrity"],
        "node_engine_requirement": package["engines"].get("node"),
        "root_lifecycle_hooks": package["install_scripts"],
        "root_has_install_script": package["has_install_script"],
        "optional_linux_native_packages": native_packages,
        "native_execution": {
            "enabled": False,
            "activation_in_plan": False,
            "explicit_activation": "vercel upgrade --enable-binary",
            "standard_launcher_requires_node": True,
            "source": VERCEL_CLI_DOCS,
        },
        "artifact_review": "Registry metadata only; no tarball downloaded or inspected; SRI is not artifact verification.",
        "platform_selection": "Not inferred or probed; candidate records do not select an install or activate native execution.",
    }


def build_dry_plan(name: str, config: Any, node_release: Any, pnpm_release: Any,
                   *, architecture: str, protected: tuple[Path, ...] = ()) -> dict[str, Any]:
    """Validate proposed future roots/runtime metadata; never inspect credentials.

    Only exact direct/optional dependencies are inspected. Non-exact and transitive
    dependencies are explicit execution prerequisites, not silently resolved.
    """
    if architecture != "x86_64":
        raise ValueError("Runtime adapters only validate Linux glibc x86_64")
    if not isinstance(config, Mapping) or set(config) != {"roots"}:
        raise ValueError("pnpm dry-plan config must contain only explicit roots")
    roots = validate_roots(config["roots"], protected)
    if not node_release or not pnpm_release:
        raise ValueError("Missing pinned Node/pnpm runtime source metadata")
    nr = node._validate_release(node_release)
    pr = native._validate_release(pnpm_release)
    if pr.get("name") != "pnpm":
        raise ValueError("Wrong package-manager runtime identity")
    # Contract reviewed against current pnpm 12, not guessed for future majors.
    if _version(pr["version"])[0] != 12:
        raise ValueError("Unreviewed pnpm major; isolated global/build-policy contract requires pnpm 12")
    pm = manifest("pnpm", pr["version"])
    package = pinned_manifest(name)
    # Optional dependencies override identically named regular dependencies,
    # matching normal package-manager semantics. Never discard platform binaries.
    deps = {**package["dependencies"], **package["optional_dependencies"]}
    if len(deps) > MAX_DIRECT:
        raise ValueError("Direct dependency metadata exceeds review bound")
    exact = [(n, v) for n, v in deps.items() if VERSION.fullmatch(v)]
    pending = {n: v for n, v in deps.items() if not VERSION.fullmatch(v)}
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
        direct = list(pool.map(lambda pair: manifest(*pair), exact))
    checks = []
    for meta in [package, pm, *direct]:
        engine = meta["engines"].get("node")
        # A library without engines makes no Node-version claim.
        if engine is None and meta not in [package, pm]: continue
        if not satisfies(nr["version"], engine):
            raise ValueError(f"Node {nr['version']} does not satisfy {meta['name']} engine {engine!r}")
        checks.append({"package": meta["name"], "requirement": engine, "satisfied_by": nr["version"]})
    scripts = [{"package": m["name"], "version": m["version"], "source": m["source"],
                "hooks": m["install_scripts"]} for m in [package, *direct] if m["install_scripts"]]
    requirements = [{**entry, "integrity": m["integrity"],
                     "approval": "required-not-granted", "matcher": f"{m['name']}@{m['version']}",
                     "metadata_sha256": hashlib.sha256(json.dumps(
                         m, sort_keys=True, separators=(",", ":")).encode()).hexdigest(),
                     "trust_requirement": "Review verified artifact and full build closure before exact-version allowBuilds approval; metadata alone does not approve script code, network or subprocess effects."}
                    for m in [package, *direct] for entry in scripts
                    if (m["name"], m["version"]) == (entry["package"], entry["version"])]
    settings = {"pnpmHomeDir": roots["pnpm_home"], "globalDir": roots["global"],
                "globalBinDir": roots["bin"], "storeDir": roots["store"],
                "cacheDir": roots["cache"], "configDir": roots["config"],
                "stateDir": roots["state"], "strictDepBuilds": True,
                "ignoreScripts": False, "dangerouslyAllowAllBuilds": False,
                "verifyStoreIntegrity": True, "strictStorePkgContentCheck": True,
                "engineStrict": True, "ignorePnpmfile": True,
                "sideEffectsCache": False, "globalShims": False}
    # A draft command, never accepted by linux_packages.execute(). Unknown
    # transitive builds must fail strictDepBuilds, not gain blanket approval.
    # No --allow-build: that flag grants name-wide approval across versions.
    command = [str(Path(roots["pnpm"]) / "pnpm"), "add", "--global",
               *[f"--config.{k}={str(v).lower() if isinstance(v, bool) else v}" for k, v in settings.items()],
               "--", f"{name}@{package['version']}"]
    environment = {"HOME": roots["home"], "PNPM_HOME": roots["pnpm_home"],
                   "PNPM_CONFIG_GLOBAL_DIR": roots["global"],
                   "PNPM_CONFIG_GLOBAL_BIN_DIR": roots["bin"],
                   "XDG_CONFIG_HOME": roots["config"], "XDG_CACHE_HOME": roots["cache"],
                   "XDG_DATA_HOME": roots["data"], "XDG_STATE_HOME": roots["state"],
                   "TMPDIR": roots["temp"], "TMP": roots["temp"], "TEMP": roots["temp"],
                   "NPM_CONFIG_USERCONFIG": str(Path(roots["config"]) / "npmrc"),
                   "NPM_CONFIG_GLOBALCONFIG": str(Path(roots["config"]) / "global-npmrc"),
                   "NPM_CONFIG_CACHE": roots["cache"], "NPM_CONFIG_REGISTRY": REGISTRY,
                   "PATH": ":".join([str(Path(roots["node"]) / "bin"), roots["pnpm"], roots["bin"], "/usr/bin", "/bin"])}
    return {"status": "dry-only", "executable": False, "package": package,
            "roots": roots, "runtime_sources": {"node": nr, "pnpm": pr},
            "runtime_status": "proposed pinned runtimes; binaries not installed, probed or executed",
            "engine_checks": checks, "direct_dependencies_reviewed": direct,
            "unresolved_direct_ranges": pending, "install_scripts": scripts,
            "vercel_cli_review": _vercel_cli_review(package, direct),
            "script_policy": {"allow_builds_proposal": {},
                              "required_version_scoped_policy": {r["matcher"]: "review-required" for r in requirements},
                              "approval_requirements": requirements,
                              "draft_cli_approval_scope": "No --allow-build or name-wide approval; exact-version requirements are not granted approvals",
                              "strict_unknown_builds": True, "runs_scripts_if_later_authorized": True,
                              "inventory": "root and exact direct/optional dependencies only; not exhaustive; implicit node-gyp builds unverified",
                              "strict_failure_is_not_transactional": "pnpm may fetch, write or run approved builds before reporting an unknown build; validate the entire closure before any executor mutation"},
            "effective_paths": {"status": "expected-not-probed",
                                "expected_global_install_base": str(Path(roots["global"]) / "v11"),
                                "layout_contract": {"pnpm_version": pr["version"],
                                                    "source": "https://pnpm.io/global-packages",
                                                    "confirmed_by_probe": False,
                                                    "on_mismatch": "Block before installation; documented v11 layout is an expectation, not proof for an unprobed pnpm patch release"},
                                "global_bin": roots["bin"],
                                "store_root": roots["store"],
                                "node_executable": str(Path(roots["node"]) / "bin/node"),
                                "pnpm_executable": str(Path(roots["pnpm"]) / "pnpm"),
                                "settings": settings,
                                "verification_required": "Compare pinned runtime identity/version and effective pnpm config, bin -g and store path against these roots in a fresh child before package installation; reject ancestor workspace/config discovery and runtime auto-downloads"},
            "integrity_policy": {"metadata_only": True, "full_lockfile_reviewed": False,
                                 "required": "Every resolved registry artifact (including transitive/peer/optional packages) must have pinned identity, official URL and SRI in the reviewed lockfile. pnpm verifies fetched tarballs against resolution integrity; verifyStoreIntegrity checks cached content and strictStorePkgContentCheck checks package identity. Neither approves scripts or makes an untrusted writable store safe.",
                                 "drift_action": "Reject changed graph, integrity, script, runtime or effective path; re-plan and review before any selected action mutates"},
            "optional_policy": "Keep normal optional dependencies; pnpm filters OS/CPU/libc. Do not use --no-optional or enable experimental native Vercel execution.",
            "proposed_command": command, "proposed_environment": environment,
            "environment_policy": "Construct fresh child environment from these entries; never inherit tokens, npm config or VERCEL native-mode flags; do not change parent HOME/PATH/profile.",
            "proposed_cwd": roots["work"],
            "execution_blockers": [
                "No reviewed pnpm-resolved full dependency/build closure: exact-version lifecycle approval cannot safely be finalized from registry metadata alone; generating/verifying that closure requires separately authorized package-manager/artifact validation."],
            "future_executor_gates": [
                "No global-package executor exists; keep every global action non-executable until implemented and separately validated.",
                "Before ANY selected mutation, validate the full transitive/peer/optional lockfile, engine/platform compatibility, integrity and explicit/implicit builds; reject all drift and unapproved exact-version scripts.",
                "Validate pinned runtimes and effective pnpm config/paths in a fresh isolated child; never infer runtime validation from metadata or silently provision another Node.",
                "Review scripts and their network/toolchain/child-process effects; isolated path routing is NOT an OS security sandbox.",
                "Revalidate all new roots with safe no-replace publication before writes; prevent symlink races and source/backup overlap."]}
