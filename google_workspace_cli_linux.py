#!/usr/bin/env python3
"""Official Google Workspace CLI native Linux archive adapter.

Planning is metadata-only. Installation is opt-in and never executes Node,
pnpm, lifecycle scripts, or the extracted binary.
"""
from __future__ import annotations

import gzip
import hashlib
import os
import platform
import re
import shutil
import tarfile
import tempfile
import urllib.parse
from pathlib import Path, PurePath
from typing import Any, Mapping

import bitwarden_cli_linux as _bw
import github_native_linux as _gh
import pnpm_global_plan as _pnpm
import opencode2_linux as _registry

PACKAGE = "@googleworkspace/cli"
REPOSITORY = "https://github.com/googleworkspace/cli"
REPO_PATH = "googleworkspace/cli"
GITHUB_API = "https://api.github.com/repos/" + REPO_PATH + "/releases/tags/"
ASSET = "google-workspace-cli-x86_64-unknown-linux-gnu.tar.gz"
CHECKSUM_ASSET = ASSET + ".sha256"
DOWNLOAD_LIMIT = 256 * 1024 * 1024
METADATA_LIMIT = 4 * 1024 * 1024
ARCHIVE_TOTAL_LIMIT = 64 * 1024 * 1024
ARCHIVE_ENTRY_LIMIT = 32 * 1024 * 1024
ARCHIVE_MEMBER_LIMIT = 16
_VERSION = re.compile(r"(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\Z")
_SHA = re.compile(r"[0-9a-fA-F]{64}\Z")


def _asset(release: Mapping[str, Any], name: str) -> tuple[str, str, str]:
    assets = release.get("assets")
    if not isinstance(assets, list):
        raise RuntimeError("GitHub release has no asset list")
    found = [a for a in assets if isinstance(a, Mapping) and a.get("name") == name]
    if len(found) != 1:
        raise RuntimeError(f"Missing or ambiguous release asset: {name}")
    a = found[0]
    url, size, digest = a.get("browser_download_url"), a.get("size"), a.get("digest")
    if (not isinstance(url, str) or not _gh._url_ok(url) or
            urllib.parse.urlsplit(url).netloc != "github.com"):
        raise RuntimeError("Release asset URL is not official")
    if url != f"{REPOSITORY}/releases/download/{release.get('tag_name')}/{name}":
        raise RuntimeError("Release asset URL is not the exact official tag and filename")
    if not isinstance(size, int) or isinstance(size, bool) or not 0 < size <= DOWNLOAD_LIMIT:
        raise RuntimeError("Release asset size is invalid")
    if not isinstance(digest, str) or not digest.startswith("sha256:") or not _SHA.fullmatch(digest[7:]):
        raise RuntimeError("Release asset requires SHA256 digest")
    return url, str(size), digest[7:].lower()


def _package(meta: Mapping[str, Any]) -> dict[str, Any]:
    if not isinstance(meta, Mapping) or meta.get("name") != PACKAGE:
        raise RuntimeError("npm package identity mismatch")
    version = meta.get("version")
    if not isinstance(version, str) or not _VERSION.fullmatch(version):
        raise RuntimeError("npm package version is not exact stable")
    repo = meta.get("repository")
    repo_url = repo.get("url") if isinstance(repo, Mapping) else repo
    if repo_url not in {REPOSITORY, "git+" + REPOSITORY + ".git", REPOSITORY + ".git"}:
        raise RuntimeError("npm repository metadata is not canonical")
    if meta.get("bin") != {"gws": "run.js"}:
        raise RuntimeError("npm gws bin identity is not exact")
    if meta.get("dependencies", {}) != {} or meta.get("optionalDependencies", {}) != {}:
        raise RuntimeError("npm dependencies are not empty")
    engines = meta.get("engines")
    if not isinstance(engines, Mapping) or engines.get("node") != ">=18":
        raise RuntimeError("npm Node engine must be reviewed as >=18")
    scripts = meta.get("scripts", {})
    if not isinstance(scripts, Mapping):
        raise RuntimeError("Invalid npm scripts metadata")
    if scripts != {"postinstall": "node install.js"}:
        raise RuntimeError("Unexpected npm lifecycle contract")
    hooks = {"postinstall": "node install.js"}
    dist = meta.get("dist")
    integrity = _registry._integrity(dist.get("integrity") if isinstance(dist, Mapping) else None)
    source = f"https://registry.npmjs.org/{PACKAGE}/{version}"
    return {"name": PACKAGE, "version": version, "source": source,
            "repository": REPOSITORY, "integrity": integrity,
            "engines": {"node": ">=18"}, "bin": {"gws": "run.js"},
            "install_scripts": hooks, "dependencies": {}, "optional_dependencies": {}}


def _checksum(raw: bytes, expected_size: str, expected_sha256: str, archive_sha256: str) -> None:
    if len(raw) != int(expected_size) or hashlib.sha256(raw).hexdigest() != expected_sha256:
        raise RuntimeError("Checksum metadata size or SHA256 mismatch")
    # A checksum file is exactly one UTF-8 line, with no BOM, junk, or extra lines.
    try:
        text = raw.decode("ascii")
    except UnicodeDecodeError as exc:
        raise RuntimeError("Invalid checksum metadata") from exc
    m = re.fullmatch(r"([0-9a-fA-F]{64})  \*?" + re.escape(ASSET) + r"\n", text)
    if not m or m.group(1).lower() != archive_sha256.lower():
        raise RuntimeError("Checksum text disagrees with GitHub asset digest")


def resolve_release(architecture: str) -> dict[str, Any]:
    if architecture != "x86_64":
        raise RuntimeError("Google Workspace CLI supports x86_64 only")
    planned = _pnpm.manifest(PACKAGE)
    if not isinstance(planned, Mapping) or planned.get("name") != PACKAGE:
        raise RuntimeError("pnpm registry plan identity mismatch")
    raw = _registry._json(planned["source"])
    package = _package(raw)
    if (package["version"] != planned.get("version") or package["source"] != planned.get("source") or
            package["integrity"] != planned.get("integrity")):
        raise RuntimeError("pnpm registry plan disagrees with canonical registry metadata")
    version = package["version"]; tag = "v" + version; source = GITHUB_API + tag
    release = _gh._json(source, api=True)
    if (release.get("tag_name") != tag or release.get("draft") is not False or
            release.get("prerelease") is not False or not isinstance(release.get("published_at"), str) or
            not release.get("published_at")):
        raise RuntimeError("GitHub release is not the exact published stable tag")
    url, size, digest = _asset(release, ASSET)
    c_url, c_size, c_digest = _asset(release, CHECKSUM_ASSET)
    response = _gh._open(c_url, limit=METADATA_LIMIT)
    try:
        checksum = _gh._read(response, METADATA_LIMIT)
    except RuntimeError as exc:
        raise RuntimeError("Invalid checksum metadata") from exc
    _checksum(checksum, c_size, c_digest, digest)
    return _validate_release({"package": package, "version": version, "tag": tag, "url": url,
        "sha256": digest, "size": size, "asset_name": ASSET, "checksum_url": c_url,
        "checksum_sha256": c_digest, "checksum_size": c_size, "manifest_source": package["source"],
        "release_source": source, "repository": REPOSITORY})


def _validate_release(r: Mapping[str, Any]) -> dict[str, Any]:
    required = {"package", "version", "tag", "url", "sha256", "size", "asset_name", "checksum_url",
                "checksum_sha256", "checksum_size", "manifest_source", "release_source", "repository"}
    if not isinstance(r, Mapping) or set(r) != required:
        raise ValueError("Invalid Google Workspace CLI release metadata")
    p = r["package"]
    if not isinstance(p, Mapping) or set(p) != {"name", "version", "source", "repository", "integrity", "engines", "bin", "install_scripts", "dependencies", "optional_dependencies"}:
        raise ValueError("Invalid npm package provenance")
    if (p.get("name") != PACKAGE or p.get("version") != r.get("version") or
            p.get("source") != f"https://registry.npmjs.org/{PACKAGE}/{r.get('version')}"):
        raise ValueError("Invalid embedded package identity/source")
    if p.get("repository") != REPOSITORY or p.get("bin") != {"gws": "run.js"}:
        raise ValueError("Invalid embedded package repository/bin")
    if p.get("engines") != {"node": ">=18"} or p.get("install_scripts") != {"postinstall": "node install.js"}:
        raise ValueError("Invalid embedded package engine/lifecycle schema")
    if p.get("dependencies") != {} or p.get("optional_dependencies") != {}:
        raise ValueError("Invalid embedded dependency schema")
    try:
        if _registry._integrity(p.get("integrity")) != p.get("integrity"):
            raise ValueError("Non-canonical npm integrity")
    except (RuntimeError, TypeError) as exc:
        raise ValueError("Invalid npm integrity") from exc
    if not isinstance(r["version"], str) or not _VERSION.fullmatch(r["version"]) or r["tag"] != "v" + r["version"]:
        raise ValueError("Invalid exact stable version")
    if r["asset_name"] != ASSET or r["repository"] != REPOSITORY or r["manifest_source"] != p["source"] or r["release_source"] != GITHUB_API + r["tag"]:
        raise ValueError("Invalid provenance")
    for key, name in (("url", ASSET), ("checksum_url", CHECKSUM_ASSET)):
        if not isinstance(r[key], str) or not _gh._url_ok(r[key]):
            raise ValueError("Invalid GitHub URL")
        u = urllib.parse.urlsplit(r[key])
        if u.netloc != "github.com" or u.path != f"/{REPO_PATH}/releases/download/{r['tag']}/{name}":
            raise ValueError("GitHub asset URL is not exact")
    for key in ("sha256", "checksum_sha256"):
        if not isinstance(r[key], str) or not _SHA.fullmatch(r[key]):
            raise ValueError("Invalid SHA256")
    for key in ("size", "checksum_size"):
        if not isinstance(r[key], str) or not r[key].isdigit() or str(int(r[key])) != r[key] or not 0 < int(r[key]) <= DOWNLOAD_LIMIT:
            raise ValueError("Invalid canonical asset size")
    return dict(r)


def _elf(data: bytes) -> None:
    if (len(data) < 64 or data[:7] != b"\x7fELF" + bytes((2, 1, 1)) or
            int.from_bytes(data[16:18], "little") not in (2, 3) or
            int.from_bytes(data[18:20], "little") != 62 or int.from_bytes(data[20:24], "little") != 1 or
            int.from_bytes(data[52:54], "little") != 64):
        raise RuntimeError("gws is not an ELF64 x86_64 ET_EXEC/ET_DYN binary")


def _safe_member(name: str) -> str:
    if not isinstance(name, str) or not name or "\\" in name or "//" in name or name.startswith("/"):
        raise ValueError("Unsafe archive member")
    p = PurePath(name)
    if ".." in p.parts or (name != "." and not (name.startswith("./") and name[2:] in {"gws", "LICENSE", "README.md", "CHANGELOG.md"}) and str(p) != name):
        raise ValueError("Unsafe archive member")
    return name


def _extract(archive: Path, stage: Path) -> None:
    expected = {"gws", "LICENSE", "README.md", "CHANGELOG.md"}; seen: set[str] = set(); total = 0; saw_root = False
    with archive.open("rb") as raw, gzip.GzipFile(fileobj=raw) as gz, tempfile.SpooledTemporaryFile(max_size=8 * 1024 * 1024) as spool:
        while True:
            chunk = gz.read(min(1024 * 1024, ARCHIVE_TOTAL_LIMIT - spool.tell() + 1))
            if not chunk: break
            spool.write(chunk)
            if spool.tell() > ARCHIVE_TOTAL_LIMIT: raise ValueError("Decompressed TAR exceeds limit")
        if raw.read(1): raise ValueError("Trailing gzip data")
        spool.seek(0)
        with tarfile.open(fileobj=spool, mode="r:") as tar:
            for m in tar:
                if len(seen) + (1 if saw_root else 0) >= ARCHIVE_MEMBER_LIMIT: raise ValueError("Too many archive members")
                name = _safe_member(m.name)
                if name == ".":
                    if saw_root or not m.isdir(): raise ValueError("Invalid archive root")
                    saw_root = True; continue
                normalized = name[2:] if name.startswith("./") and name[2:] in expected else name
                if normalized not in expected or normalized in seen or not m.isreg() or m.size <= 0 or m.size > ARCHIVE_ENTRY_LIMIT:
                    raise ValueError("Archive members are not exact regular files")
                seen.add(normalized); total += m.size
                if total > ARCHIVE_TOTAL_LIMIT: raise ValueError("Archive exceeds size limit")
                src = tar.extractfile(m); data = src.read(m.size + 1) if src else b""
                if len(data) != m.size: raise ValueError("Truncated archive member")
                out = stage / ("bin/gws" if normalized == "gws" else normalized); out.parent.mkdir(parents=True, exist_ok=True); out.write_bytes(data)
                if normalized == "gws": _elf(data); os.chmod(out, 0o755)
            # tarfile stops at the first end marker; hidden concatenated TARs
            # or other non-padding payload must not bypass the exact layout.
            spool.seek(tar.offset)
            while True:
                padding = spool.read(65536)
                if not padding: break
                if any(padding): raise ValueError("Non-padding data after TAR entries")
    if not saw_root or seen != expected: raise ValueError("Archive layout is not exact")


def _root(destination: Path) -> Path:
    if not isinstance(destination, Path): destination = Path(destination)
    raw = str(destination)
    if not raw or any(c in raw for c in "\x00\r\n:") or not destination.is_absolute() or raw != os.path.normpath(raw):
        raise ValueError("Destination must be a normalized absolute path")
    path = destination
    protected = [Path.home(), Path("/etc"), Path("/usr"), Path("/bin"), Path("/sbin"), Path("/lib"), Path("/lib64"), Path("/dev"), Path("/proc"), Path("/sys"), Path("/boot"), Path("/root"), Path(__file__).resolve().parent]
    for guard in protected:
        if path == guard or guard in path.parents or path in guard.parents: raise ValueError("Destination overlaps protected path")
    return path


def _paths(root: Path) -> dict[str, str]:
    return {k: str(root / v) for k, v in {"binary": "bin/gws", "home": "home", "config": "config/gws", "cache": "cache", "discovery_cache": "config/gws/cache", "temp": "temp", "work": "work", "data": "data", "state": "state"}.items()}


def layout_plan(release: Mapping[str, Any], destination: Path) -> dict[str, Any]:
    r = _validate_release(release); root = _root(destination); _bw._safe_destination(root)
    paths = _paths(root)
    return {"status": "metadata-only", "release": r, "root": str(root), "paths": paths,
            "runtime": {"node": {"required": False, "path": None}, "pnpm": {"required": False, "path": None}},
            "proposed_environment": {"HOME": paths["home"], "XDG_CONFIG_HOME": str(root / "config"), "XDG_CACHE_HOME": paths["cache"], "XDG_DATA_HOME": paths["data"], "XDG_STATE_HOME": paths["state"], "TMPDIR": paths["temp"], "TMP": paths["temp"], "TEMP": paths["temp"], "PATH": str(root / "bin"), "GOOGLE_WORKSPACE_CLI_CONFIG_DIR": paths["config"]},
            "proposed_cwd": paths["work"], "runtime_status": "Node and pnpm are not required, installed, used, probed, or executed", "state_routing": "not an OS sandbox; runtime untested and not authorized by installing"}


def validate_install(release: Mapping[str, Any], destination: Path) -> None:
    _validate_release(release)
    if platform.system() != "Linux" or platform.machine().lower() not in {"x86_64", "amd64"} or platform.libc_ver()[0].lower() != "glibc": raise RuntimeError("Google Workspace CLI requires Linux x86_64 with glibc")
    root = _root(destination); _bw._safe_destination(root)
    if not os.path.isdir("/proc/self/fd") or not os.access("/proc/self/fd", os.R_OK | os.X_OK): raise RuntimeError("/proc/self/fd is required")
    if getattr(_bw.ctypes.CDLL(None), "renameat2", None) is None: raise RuntimeError("Linux renameat2 is required")


def install_release(release: Mapping[str, Any], destination: Path) -> dict[str, Any]:
    r = _validate_release(release); validate_install(r, destination); root = _root(destination)
    parent_fd, _ = _bw._open_destination_parent(root); stage = None
    try:
        stage = Path(tempfile.mkdtemp(prefix=".google-workspace-cli-", dir=f"/proc/self/fd/{parent_fd}")); os.chmod(stage, 0o700)
        with tempfile.TemporaryDirectory(prefix=".google-workspace-download-", dir=f"/proc/self/fd/{parent_fd}") as td:
            archive = Path(td) / "release.tar.gz"; response = _gh._open(r["url"], limit=DOWNLOAD_LIMIT); h = hashlib.sha256(); total = 0
            try:
                with archive.open("wb") as out:
                    while True:
                        chunk = response.read(min(1024 * 1024, DOWNLOAD_LIMIT - total + 1))
                        if not chunk: break
                        total += len(chunk)
                        if total > DOWNLOAD_LIMIT: raise RuntimeError("Download exceeds limit")
                        h.update(chunk); out.write(chunk)
            finally: response.close()
            if total != int(r["size"]): raise RuntimeError("Download size mismatch")
            if h.hexdigest() != r["sha256"]: raise RuntimeError("Download SHA256 mismatch")
            _extract(archive, stage)
        for rel in ("home", "config/gws/cache", "cache", "temp", "work", "data", "state"):
            (stage / rel).mkdir(parents=True, exist_ok=True)
        for directory in stage.rglob("*"):
            if directory.is_dir(): os.chmod(directory, 0o700)
        _bw._publish_noreplace(stage, root, parent_fd=parent_fd); stage = None
        return {"status": "installed", "root": str(root), "binary": str(root / "bin/gws"), "runtime": {"node": {"required": False, "path": None}, "pnpm": {"required": False, "path": None}}}
    finally:
        if stage is not None: shutil.rmtree(stage, ignore_errors=True)
        os.close(parent_fd)


__all__ = ["resolve_release", "validate_install", "install_release", "layout_plan"]
