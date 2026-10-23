#!/usr/bin/env python3
"""Official Bun Linux x86_64 baseline archive adapter.

This module is deliberately independent of the package planner.  It resolves
public release metadata only, and installs only when the caller supplies a new
explicit root.  It never migrates Bun state, edits PATH, or executes Bun.
"""
from __future__ import annotations

import hashlib
import json
import os
import platform
import re
import shutil
import stat
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path
from typing import Any, Mapping

import bitwarden_cli_linux as _bw

SCOOP_MANIFEST_URL = "https://raw.githubusercontent.com/ScoopInstaller/Main/master/bucket/bun.json"
GITHUB_API_BASE = "https://api.github.com/repos/oven-sh/bun/releases/tags/"
GITHUB_REPO = "oven-sh/bun"
DOWNLOAD_LIMIT = 256 * 1024 * 1024
METADATA_LIMIT = 2 * 1024 * 1024
ZIP_ENTRY_LIMIT = 512 * 1024 * 1024
TIMEOUT = 30
USER_AGENT = "mainframe-native-shells/1.0 (Bun Linux resolver)"
_SHA256 = re.compile(r"^[0-9a-fA-F]{64}$")
_VERSION = re.compile(r"^[0-9A-Za-z][0-9A-Za-z.+_-]*$")


def _official_url(url: str, *, api: bool = False, redirect: bool = False) -> bool:
    try:
        p = urllib.parse.urlsplit(url); port = p.port
    except (TypeError, ValueError):
        return False
    hosts = {"api.github.com", "raw.githubusercontent.com"} if api else {"github.com", "release-assets.githubusercontent.com"}
    query_ok = redirect and p.netloc == "release-assets.githubusercontent.com" and bool(p.query)
    return (p.scheme == "https" and p.netloc in hosts and port is None and not p.username and not p.password
            and (not p.query or query_ok) and not p.fragment and p.path.startswith("/")
            and (p.netloc != "release-assets.githubusercontent.com" or
                 re.fullmatch(r"/github-production-release-asset/[0-9]+/[A-Za-z0-9._-]+", p.path) is not None))


class _Redirects(urllib.request.HTTPRedirectHandler):
    max_redirections = 5

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        count = int(req.headers.get("X-Bun-Redirects", "0"))
        if count >= self.max_redirections:
            raise RuntimeError("Too many official Bun redirects")
        source = urllib.parse.urlsplit(req.full_url); target = urllib.parse.urlsplit(newurl)
        is_download = source.netloc == "github.com" and source.path.startswith("/oven-sh/bun/releases/download/")
        if is_download:
            allowed = ((_official_url(newurl, redirect=True) and target.netloc == "release-assets.githubusercontent.com") or
                       (_official_url(newurl) and target.netloc == "github.com" and target.path == source.path))
        else:
            allowed = (target.netloc == source.netloc and target.path == source.path and
                       (_official_url(newurl, api=True) if source.netloc in {"api.github.com", "raw.githubusercontent.com"} else _official_url(newurl)))
        if not allowed:
            raise RuntimeError(f"Refusing non-official redirect: {urllib.parse.urlunsplit((target.scheme,target.netloc,target.path,'',''))!r}")
        redirected = super().redirect_request(req, fp, code, msg, headers, newurl)
        if redirected is not None:
            redirected.add_header("X-Bun-Redirects", str(count + 1))
        return redirected


def _open(url: str, *, limit: int, api: bool = False) -> Any:
    if not (_official_url(url, api=api) if api else _official_url(url)):
        raise RuntimeError(f"Refusing non-official URL: {url!r}")
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept": "application/vnd.github+json"})
    try:
        response = urllib.request.build_opener(_Redirects()).open(req, timeout=TIMEOUT)
    except (urllib.error.URLError, OSError) as exc:
        raise RuntimeError(f"Official Bun metadata request failed: {exc}") from exc
    length = response.headers.get("Content-Length")
    if length is not None:
        try:
            if int(length) > limit: response.close(); raise RuntimeError(f"Response exceeds limit of {limit} bytes")
        except ValueError:
            response.close(); raise RuntimeError("Invalid Content-Length") from None
    return response


def _read(response: Any, limit: int) -> bytes:
    chunks: list[bytes] = []; total = 0
    try:
        while True:
            chunk = response.read(min(64 * 1024, limit - total + 1))
            if not chunk: return b"".join(chunks)
            total += len(chunk)
            if total > limit: raise RuntimeError(f"Response exceeds limit of {limit} bytes")
            chunks.append(chunk)
    finally: response.close()


def _json(url: str, limit: int, *, api: bool = False) -> Mapping[str, Any]:
    try: value = json.loads(_read(_open(url, limit=limit, api=api), limit).decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError, TypeError) as exc: raise RuntimeError("Invalid official Bun metadata JSON") from exc
    if not isinstance(value, Mapping): raise RuntimeError("Official Bun metadata is not an object")
    return value


def _asset(release: Mapping[str, Any], name: str) -> Mapping[str, Any]:
    assets = release.get("assets")
    if not isinstance(assets, list): raise RuntimeError("GitHub Bun release has no asset list")
    matches = [x for x in assets if isinstance(x, Mapping) and x.get("name") == name]
    if len(matches) != 1: raise RuntimeError(f"GitHub Bun release asset is missing or ambiguous: {name}")
    return matches[0]


def _asset_info(asset: Mapping[str, Any], name: str, version: str) -> tuple[str, str, str]:
    url, size, digest = asset.get("browser_download_url"), asset.get("size"), asset.get("digest")
    if asset.get("name") != name or not isinstance(url, str) or not _official_url(url): raise RuntimeError("GitHub Bun asset URL/name is not official")
    if not isinstance(size, int) or size <= 0 or size > DOWNLOAD_LIMIT: raise RuntimeError("GitHub Bun asset has invalid size")
    if not isinstance(digest, str) or not digest.startswith("sha256:") or not _SHA256.fullmatch(digest[7:]): raise RuntimeError("GitHub Bun asset is missing a required SHA256 digest")
    expected = f"https://github.com/oven-sh/bun/releases/download/bun-v{version}/{name}"
    if url != expected: raise RuntimeError("GitHub Bun asset URL is not exact")
    return url, str(size), digest[7:].lower()


def _manifest(version: str, manifest: Mapping[str, Any]) -> tuple[str, str, str]:
    arch = manifest.get("architecture")
    if not isinstance(arch, Mapping): raise RuntimeError("Scoop Bun manifest has no architecture map")
    x = arch.get("64bit"); arm = arch.get("arm64")
    xurls = x.get("url") if isinstance(x, Mapping) else None
    if (not isinstance(xurls, list) or len(xurls) != 2 or
            any(not isinstance(url, str) for url in xurls) or
            set(xurls) != {f"https://github.com/oven-sh/bun/releases/download/bun-v{version}/bun-windows-x64.zip", f"https://github.com/oven-sh/bun/releases/download/bun-v{version}/bun-windows-x64-baseline.zip"}):
        raise RuntimeError("Scoop Bun 64bit manifest Windows URLs are not the official standard/baseline pair")
    aurl = arm.get("url") if isinstance(arm, Mapping) else None
    expected_arm = f"https://github.com/oven-sh/bun/releases/download/bun-v{version}/bun-windows-aarch64.zip"
    if aurl != expected_arm: raise RuntimeError("Scoop Bun arm64 manifest Windows URL is not official")
    return xurls[0], xurls[1], aurl


def _checksums(data: bytes, filename: str) -> str:
    found = []
    for line in data.decode("utf-8").splitlines():
        fields = line.split()
        if len(fields) == 2 and fields[1] == filename and _SHA256.fullmatch(fields[0]): found.append(fields[0].lower())
    if len(found) != 1: raise RuntimeError(f"Bun SHASUMS256.txt has missing or ambiguous checksum for {filename}")
    return found[0]


def resolve_release(architecture: str) -> dict[str, str]:
    if architecture != "x86_64": raise RuntimeError(f"Unsupported architecture: {architecture}; Bun adapter conservatively supports x86_64 only")
    manifest = _json(SCOOP_MANIFEST_URL, METADATA_LIMIT, api=True)
    version = manifest.get("version")
    if not isinstance(version, str) or not _VERSION.fullmatch(version): raise RuntimeError("Scoop Bun manifest has invalid version")
    standard, baseline, arm = _manifest(version, manifest)
    api_url = GITHUB_API_BASE + urllib.parse.quote("bun-v" + version, safe="")
    release = _json(api_url, METADATA_LIMIT, api=True)
    if release.get("tag_name") != f"bun-v{version}" or release.get("prerelease") is not False or release.get("draft") is not False or not isinstance(release.get("published_at"), str) or not release.get("published_at"):
        raise RuntimeError("GitHub Bun release tag is wrong, draft, or prerelease")
    name = f"bun-linux-x64-baseline.zip"; win_std = f"bun-windows-x64.zip"; win_base = f"bun-windows-x64-baseline.zip"; win_arm = f"bun-windows-aarch64.zip"
    linux = _asset(release, name); ws = _asset(release, win_std); wb = _asset(release, win_base); wa = _asset(release, win_arm)
    url, size, digest = _asset_info(linux, name, version)
    _, _, ds = _asset_info(ws, win_std, version); _, _, db = _asset_info(wb, win_base, version); _, _, da = _asset_info(wa, win_arm, version)
    if (ws.get("browser_download_url") != standard or wb.get("browser_download_url") != baseline or wa.get("browser_download_url") != arm): raise RuntimeError("GitHub Bun Windows assets do not exactly match Scoop manifest")
    sums_url = f"https://github.com/oven-sh/bun/releases/download/bun-v{version}/SHASUMS256.txt"
    sums_asset = _asset(release, "SHASUMS256.txt"); sum_url, sum_size, sum_digest = _asset_info(sums_asset, "SHASUMS256.txt", version)
    if sum_url != sums_url: raise RuntimeError("Bun checksum URL is not exact")
    sums = _read(_open(sum_url, limit=METADATA_LIMIT), METADATA_LIMIT)
    if len(sums) != int(sum_size) or hashlib.sha256(sums).hexdigest() != sum_digest:
        raise RuntimeError("Bun SHASUMS256.txt bytes disagree with GitHub asset metadata")
    if _checksums(sums, name) != digest: raise RuntimeError("Bun Linux checksum disagrees with GitHub asset digest")
    for fname, dg in ((win_std, ds), (win_base, db), (win_arm, da)):
        if _checksums(sums, fname) != dg: raise RuntimeError(f"Bun Windows checksum disagrees with GitHub asset digest: {fname}")
    return _validate_release({"version": version, "url": url, "sha256": digest, "size": size, "asset_name": name, "manifest_source": SCOOP_MANIFEST_URL, "release_source": api_url, "checksums_source": sums_url, "checksums_sha256": sum_digest, "layout": "bun-linux-x64-baseline/bun"})


def _validate_release(release: Mapping[str, Any]) -> dict[str, str]:
    required = {"version","url","sha256","size","asset_name","manifest_source","release_source","checksums_source","checksums_sha256","layout"}
    if not isinstance(release, Mapping) or set(release) != required or any(not isinstance(release[k], str) or not release[k] for k in required): raise ValueError("Invalid Bun release metadata")
    v = release["version"]
    if not _VERSION.fullmatch(v) or release["asset_name"] != "bun-linux-x64-baseline.zip" or release["layout"] != "bun-linux-x64-baseline/bun": raise ValueError("Invalid Bun release version or asset")
    expected = f"https://github.com/oven-sh/bun/releases/download/bun-v{v}/bun-linux-x64-baseline.zip"
    if not _official_url(release["url"]) or release["url"] != expected: raise ValueError("Bun download URL is not exact")
    if release["manifest_source"] != SCOOP_MANIFEST_URL or release["release_source"] != GITHUB_API_BASE + "bun-v" + v: raise ValueError("Invalid Bun provenance")
    if release["checksums_source"] != f"https://github.com/oven-sh/bun/releases/download/bun-v{v}/SHASUMS256.txt" or not _SHA256.fullmatch(release["sha256"]) or not _SHA256.fullmatch(release["checksums_sha256"]): raise ValueError("Invalid Bun checksum metadata")
    try: size = int(release["size"])
    except ValueError: raise ValueError("Invalid Bun size") from None
    if size <= 0 or size > DOWNLOAD_LIMIT or str(size) != release["size"]: raise ValueError("Invalid Bun size")
    return dict(release)


def _cpu_compatible() -> None:
    if platform.system() != "Linux" or platform.machine().lower() not in {"x86_64", "amd64"} or platform.libc_ver()[0].lower() != "glibc": raise RuntimeError("Bun baseline requires Linux x86_64 with glibc")
    try: glibc = tuple(int(x) for x in platform.libc_ver()[1].split(".")[:2])
    except (ValueError, TypeError): raise RuntimeError("Unable to determine glibc version") from None
    if glibc < (2, 17): raise RuntimeError("Bun baseline requires glibc >= 2.17")
    try: flags = Path("/proc/cpuinfo").read_text(encoding="ascii", errors="ignore").lower()
    except OSError: flags = ""
    if not flags or not re.search(r"\bsse4_2\b", flags): raise RuntimeError("Bun baseline requires SSE4.2")


def validate_install(release: Mapping[str, Any], destination: Path) -> None:
    _validate_release(release); _cpu_compatible(); _bw._safe_destination(Path(destination))
    if getattr(_bw.ctypes.CDLL(None), "renameat2", None) is None: raise RuntimeError("Linux renameat2 is required for race-safe publication")


def _zip_entry(z: zipfile.ZipFile) -> zipfile.ZipInfo:
    infos = z.infolist(); binary_name = "bun-linux-x64-baseline/bun"; root_name = "bun-linux-x64-baseline/"
    names = [i.filename for i in infos]
    if len(names) != len(set(names)) or any(name not in {binary_name, root_name} for name in names):
        raise ValueError("Bun ZIP must contain exactly the expected baseline layout")
    binaries = [i for i in infos if i.filename == binary_name]
    roots = [i for i in infos if i.filename == root_name]
    if len(binaries) != 1 or len(roots) > 1:
        raise ValueError("Bun ZIP must contain exactly the expected baseline layout")
    root = roots[0] if roots else None
    if root is not None:
        root_mode = (root.external_attr >> 16) & 0o170000
        if not root.is_dir() or (root_mode and root_mode != stat.S_IFDIR):
            raise ValueError("Bun ZIP entry is unsafe")
    i = binaries[0]; mode = (i.external_attr >> 16) & 0o170000
    if i.is_dir() or i.file_size <= 0 or i.file_size > ZIP_ENTRY_LIMIT or (mode and mode != stat.S_IFREG) or (i.compress_size and i.file_size > i.compress_size * 1000):
        raise ValueError("Bun ZIP entry is unsafe")
    return i


def install_release(release: Mapping[str, Any], destination: Path) -> None:
    v = _validate_release(release); validate_install(v, destination); destination = Path(os.path.normpath(str(Path(destination).expanduser())))
    parent_fd, _ = _bw._open_destination_parent(destination); stage_path = None
    try:
        stage_path = Path(tempfile.mkdtemp(prefix=".bun-linux-", dir=f"/proc/self/fd/{parent_fd}")); os.chmod(stage_path, 0o700)
        with tempfile.TemporaryDirectory(prefix=".bun-download-", dir=f"/proc/self/fd/{parent_fd}") as td:
            archive = Path(td) / "bun.zip"; digest = hashlib.sha256(); total = 0; response = _open(v["url"], limit=DOWNLOAD_LIMIT)
            try:
                with archive.open("wb") as out:
                    while True:
                        chunk = response.read(min(1024 * 1024, DOWNLOAD_LIMIT - total + 1))
                        if not chunk: break
                        total += len(chunk)
                        if total > DOWNLOAD_LIMIT: raise RuntimeError("Bun download exceeds limit")
                        digest.update(chunk); out.write(chunk)
            finally: response.close()
            if total != int(v["size"]): raise RuntimeError("Bun download size mismatch")
            if digest.hexdigest() != v["sha256"]: raise RuntimeError("Bun download SHA256 mismatch")
            with zipfile.ZipFile(archive) as z:
                info = _zip_entry(z)
                with z.open(info) as src, (stage_path / "bun").open("wb") as out: shutil.copyfileobj(src, out, 1024 * 1024)
            binary = stage_path / "bun"
            with binary.open("rb") as stream:
                header = stream.read(64)
            if len(header) < 64 or header[:4] != b"\x7fELF" or header[4:7] != bytes((2,1,1)) or int.from_bytes(header[18:20], "little") != 62 or int.from_bytes(header[20:24], "little") != 1: raise RuntimeError("Bun binary is not a complete x86_64 ELF64 binary")
            os.chmod(binary, 0o755); _bw._publish_noreplace(stage_path, destination, parent_fd=parent_fd)
    finally:
        if stage_path is not None: shutil.rmtree(stage_path, ignore_errors=True)
        os.close(parent_fd)
