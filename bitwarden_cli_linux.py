#!/usr/bin/env python3
"""Official Bitwarden CLI Linux x86_64 archive adapter.

Metadata resolution is public and read-only.  Installation is deliberately
opt-in and never modifies profiles, PATH, or credentials.
"""
from __future__ import annotations

import hashlib
import ctypes
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

SCOOP_MANIFEST_URL = "https://raw.githubusercontent.com/ScoopInstaller/Main/master/bucket/bitwarden-cli.json"
GITHUB_API_BASE = "https://api.github.com/repos/bitwarden/clients/releases/tags/"
GITHUB_REPO = "bitwarden/clients"
DOWNLOAD_LIMIT = 256 * 1024 * 1024
METADATA_LIMIT = 2 * 1024 * 1024
ZIP_ENTRY_LIMIT = 512 * 1024 * 1024
TIMEOUT = 30
USER_AGENT = "mainframe-native-shells/1.0 (Bitwarden Linux resolver)"
_SHA256 = re.compile(r"^[0-9a-fA-F]{64}$")
_VERSION = re.compile(r"^[0-9A-Za-z][0-9A-Za-z.+_-]*$")


def _official_url(url: str, *, api: bool = False, redirect: bool = False) -> bool:
    try:
        p = urllib.parse.urlsplit(url)
        port = p.port
    except (TypeError, ValueError):
        return False
    hosts = {"api.github.com", "raw.githubusercontent.com"} if api else {"github.com", "release-assets.githubusercontent.com"}
    query_ok = redirect and p.netloc == "release-assets.githubusercontent.com" and bool(p.query)
    return (p.scheme == "https" and p.netloc in hosts and port is None and
            not p.username and not p.password and (not p.query or query_ok) and
            not p.fragment and p.path.startswith("/") and
            (p.netloc != "release-assets.githubusercontent.com" or
             re.fullmatch(r"/github-production-release-asset/[0-9]+/[A-Za-z0-9._-]+", p.path) is not None))


class _Redirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        source = urllib.parse.urlsplit(req.full_url)
        is_download = source.netloc == "github.com" and source.path.startswith("/bitwarden/clients/releases/download/")
        target = urllib.parse.urlsplit(newurl)
        if is_download:
            allowed = ((_official_url(newurl, redirect=True) and target.netloc == "release-assets.githubusercontent.com") or
                       (_official_url(newurl) and target.netloc == "github.com" and target.path == source.path))
        else:
            allowed = (target.netloc == source.netloc and
                       (_official_url(newurl, api=True) if source.netloc in {"api.github.com", "raw.githubusercontent.com"}
                        else _official_url(newurl)))
        if not allowed:
            safe = urllib.parse.urlunsplit((target.scheme, target.netloc, target.path, "", ""))
            raise RuntimeError(f"Refusing non-official redirect: {safe!r}")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def _open(url: str, *, limit: int, api: bool = False) -> Any:
    if not (_official_url(url, api=api) if api else _official_url(url)):
        raise RuntimeError(f"Refusing non-official URL: {url!r}")
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept": "application/vnd.github+json"})
    try:
        response = urllib.request.build_opener(_Redirects()).open(request, timeout=TIMEOUT)
    except (urllib.error.URLError, OSError) as exc:
        raise RuntimeError(f"Official Bitwarden metadata request failed: {exc}") from exc
    length = response.headers.get("Content-Length")
    if length is not None:
        try:
            if int(length) > limit:
                response.close(); raise RuntimeError(f"Response exceeds limit of {limit} bytes")
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
    except (UnicodeDecodeError, json.JSONDecodeError, TypeError) as exc:
        raise RuntimeError("Invalid official Bitwarden metadata JSON") from exc
    if not isinstance(value, Mapping): raise RuntimeError("Official metadata is not an object")
    return value


def _manifest_version(manifest: Mapping[str, Any]) -> tuple[str, str]:
    version = manifest.get("version")
    arch = manifest.get("architecture")
    item = arch.get("64bit") if isinstance(arch, Mapping) else None
    url = item.get("url") if isinstance(item, Mapping) else None
    if not isinstance(version, str) or not _VERSION.fullmatch(version): raise RuntimeError("Scoop Bitwarden manifest has invalid version")
    expected = f"https://github.com/bitwarden/clients/releases/download/cli-v{version}/bw-oss-windows-{version}.zip"
    if url != expected: raise RuntimeError("Scoop Bitwarden manifest is not the official Windows OSS URL")
    return version, expected


def _asset(release: Mapping[str, Any], name: str) -> Mapping[str, Any]:
    assets = release.get("assets")
    if not isinstance(assets, list): raise RuntimeError("GitHub release has no asset list")
    matches = [x for x in assets if isinstance(x, Mapping) and x.get("name") == name]
    if len(matches) != 1: raise RuntimeError(f"GitHub release asset is missing or ambiguous: {name}")
    return matches[0]


def _asset_info(asset: Mapping[str, Any], expected_name: str) -> tuple[str, str, str]:
    url, size, digest = asset.get("browser_download_url"), asset.get("size"), asset.get("digest")
    if asset.get("name") != expected_name or not isinstance(url, str) or not _official_url(url): raise RuntimeError("GitHub release asset URL/name is not official")
    if not isinstance(size, int) or size <= 0 or size > DOWNLOAD_LIMIT: raise RuntimeError("GitHub release asset has invalid size")
    if not isinstance(digest, str) or not digest.startswith("sha256:") or not _SHA256.fullmatch(digest[7:]): raise RuntimeError("GitHub release asset is missing a required SHA256 digest")
    return url, str(size), digest[7:].lower()


def resolve_release(architecture: str) -> dict[str, str]:
    if architecture != "x86_64": raise RuntimeError(f"Unsupported architecture: {architecture}")
    manifest = _json(SCOOP_MANIFEST_URL, METADATA_LIMIT, api=True)
    version, windows_url = _manifest_version(manifest)
    api_url = GITHUB_API_BASE + urllib.parse.quote("cli-v" + version, safe="")
    release = _json(api_url, METADATA_LIMIT, api=True)
    if (release.get("tag_name") != f"cli-v{version}" or release.get("prerelease") is not False or release.get("draft") is not False or not isinstance(release.get("published_at"), str) or not release.get("published_at")):
        raise RuntimeError("GitHub release tag is wrong, draft, or prerelease")
    linux_name = f"bw-oss-linux-{version}.zip"
    linux = _asset(release, linux_name); windows = _asset(release, f"bw-oss-windows-{version}.zip")
    linux_url, size, digest = _asset_info(linux, linux_name); win_url, _, _ = _asset_info(windows, windows["name"])
    if win_url != windows_url: raise RuntimeError("GitHub Windows asset does not exactly match Scoop manifest")
    return _validate_release({"version": version, "url": linux_url, "sha256": digest, "size": size, "asset_name": linux_name, "manifest_source": SCOOP_MANIFEST_URL, "release_source": api_url})


def _validate_release(release: Mapping[str, Any]) -> dict[str, str]:
    required = {"version", "url", "sha256", "size", "asset_name", "manifest_source", "release_source"}
    if not isinstance(release, Mapping) or set(release) != required or any(not isinstance(release[k], str) or not release[k] for k in required): raise ValueError("Invalid Bitwarden release metadata")
    version = release["version"]
    if not _VERSION.fullmatch(version) or release["asset_name"] != f"bw-oss-linux-{version}.zip": raise ValueError("Invalid Bitwarden release version or asset")
    if not _official_url(release["url"]): raise ValueError("Bitwarden download URL is not official")
    p = urllib.parse.urlsplit(release["url"])
    if (p.netloc != "github.com" or p.path != f"/bitwarden/clients/releases/download/cli-v{version}/{release['asset_name']}"): raise ValueError("Bitwarden download path is not exact")
    if release["manifest_source"] != SCOOP_MANIFEST_URL or release["release_source"] != GITHUB_API_BASE + "cli-v" + version: raise ValueError("Invalid Bitwarden provenance")
    if not _SHA256.fullmatch(release["sha256"]): raise ValueError("Invalid Bitwarden SHA256")
    try: size = int(release["size"])
    except ValueError: raise ValueError("Invalid Bitwarden size") from None
    if size <= 0 or size > DOWNLOAD_LIMIT or str(size) != release["size"]: raise ValueError("Invalid Bitwarden size")
    return dict(release)


def _check_ancestor(st: os.stat_result) -> None:
    """Reject ancestors that are not directories owned by root or this user."""
    if (not stat.S_ISDIR(st.st_mode) or st.st_uid not in {0, os.geteuid()} or
            (st.st_mode & 0o022 and not (st.st_mode & stat.S_ISVTX))):
        raise ValueError("Unsafe Bitwarden CLI root ancestor")


def _open_destination_parent(destination: Path, *, require_new: bool = True) -> tuple[int, str]:
    """Open and validate every destination ancestor using descriptor-relative traversal."""
    destination = Path(os.path.normpath(str(destination.expanduser())))
    if not destination.is_absolute() or destination == Path("/"):
        raise ValueError("Bitwarden CLI root must be an explicit absolute directory")
    parts = destination.parts
    fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        _check_ancestor(os.fstat(fd))
        for component in parts[1:-1]:
            if component in {"", ".", ".."}: raise ValueError("Unsafe Bitwarden CLI root ancestor")
            child = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=fd)
            os.close(fd); fd = child
            _check_ancestor(os.fstat(fd))
        name = parts[-1]
        if not name or name in {".", ".."}: raise ValueError("Invalid Bitwarden CLI root")
        if require_new:
            try:
                os.stat(name, dir_fd=fd, follow_symlinks=False)
            except FileNotFoundError:
                pass
            else:
                raise ValueError("Refusing existing or symlink Bitwarden CLI root")
        return fd, name
    except Exception:
        os.close(fd)
        raise


def _safe_destination(destination: Path) -> Path:
    """Validate a new root without resolving its parent through a later path lookup."""
    fd, _ = _open_destination_parent(destination)
    os.close(fd)
    return Path(os.path.normpath(str(Path(destination).expanduser())))


def _zip_entry(z: zipfile.ZipFile) -> zipfile.ZipInfo:
    infos = z.infolist()
    if len(infos) != 1: raise ValueError("Bitwarden ZIP must contain exactly one entry")
    info = infos[0]
    if info.filename != "bw" or info.is_dir() or info.file_size <= 0 or info.file_size > ZIP_ENTRY_LIMIT: raise ValueError("Bitwarden ZIP must contain one regular bw entry")
    mode = (info.external_attr >> 16) & 0o170000
    if mode and mode != stat.S_IFREG: raise ValueError("Bitwarden ZIP entry must not be a symlink or special file")
    if info.compress_size and info.file_size > info.compress_size * 1000: raise ValueError("Bitwarden ZIP compression ratio is unsafe")
    return info


def _publish_noreplace(stage: Path, destination: Path, parent_fd: int | None = None) -> None:
    """Atomically publish a staged directory relative to a validated parent FD."""
    owned_fd = None
    if parent_fd is None:
        parent_fd, _ = _open_destination_parent(destination, require_new=False)
        owned_fd = parent_fd
    try:
        stage_name = Path(stage).name
        destination_name = Path(destination).name
        if not stage_name or not destination_name or "/" in stage_name or "/" in destination_name:
            raise ValueError("Invalid publication name")
        try:
            stage_parent = os.stat(Path(stage).parent)
        except OSError as exc:
            raise ValueError("Staging directory is unavailable") from exc
        parent_stat = os.fstat(parent_fd)
        if (stage_parent.st_dev, stage_parent.st_ino) != (parent_stat.st_dev, parent_stat.st_ino):
            raise ValueError("Staging directory is not anchored to destination parent")
        libc = ctypes.CDLL(None, use_errno=True)
        renameat2 = getattr(libc, "renameat2", None)
        if renameat2 is None: raise RuntimeError("Linux renameat2 is required for race-safe publication")
        renameat2.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
        renameat2.restype = ctypes.c_int
        result = renameat2(parent_fd, os.fsencode(stage_name), parent_fd, os.fsencode(destination_name), 1)
        if result != 0:
            err = ctypes.get_errno()
            if err == 17: raise RuntimeError("Refusing destination created concurrently")
            raise OSError(err, os.strerror(err), destination)
    finally:
        if owned_fd is not None: os.close(owned_fd)


def validate_install(release: Mapping[str, Any], destination: Path) -> None:
    _validate_release(release)
    if (platform.system() != "Linux" or platform.machine().lower() not in {"x86_64", "amd64"} or platform.libc_ver()[0].lower() != "glibc"):
        raise RuntimeError("Bitwarden CLI requires Linux x86_64 with glibc")
    _safe_destination(Path(destination))
    if getattr(ctypes.CDLL(None), "renameat2", None) is None:
        raise RuntimeError("Linux renameat2 is required for race-safe publication")
    fd, _ = _open_destination_parent(Path(destination))
    try:
        if not Path(f"/proc/self/fd/{fd}").is_dir():
            raise RuntimeError("Bitwarden CLI installation requires /proc/self/fd")
    finally:
        os.close(fd)


def install_release(release: Mapping[str, Any], destination: Path) -> None:
    validated = _validate_release(release)
    validate_install(validated, destination)
    destination = Path(os.path.normpath(str(Path(destination).expanduser())))
    parent_fd, destination_name = _open_destination_parent(destination)
    stage_path = None
    try:
        stage_path = Path(tempfile.mkdtemp(prefix=".bitwarden-cli-", dir=f"/proc/self/fd/{parent_fd}"))
        os.chmod(stage_path, 0o700)
        with tempfile.TemporaryDirectory(prefix=".bitwarden-download-", dir=f"/proc/self/fd/{parent_fd}") as td:
            archive = Path(td) / "bw.zip"; digest = hashlib.sha256(); total = 0
            response = _open(validated["url"], limit=DOWNLOAD_LIMIT)
            try:
                with archive.open("wb") as out:
                    while True:
                        chunk = response.read(min(1024 * 1024, DOWNLOAD_LIMIT - total + 1))
                        if not chunk: break
                        total += len(chunk)
                        if total > DOWNLOAD_LIMIT: raise RuntimeError("Bitwarden download exceeds limit")
                        digest.update(chunk); out.write(chunk)
            finally: response.close()
            if total != int(validated["size"]): raise RuntimeError("Bitwarden download size mismatch")
            if digest.hexdigest() != validated["sha256"]: raise RuntimeError("Bitwarden download SHA256 mismatch")
            stage = stage_path
            with zipfile.ZipFile(archive) as z:
                info = _zip_entry(z)
                with z.open(info) as src, (stage / "bw").open("wb") as out:
                    remaining = info.file_size
                    while remaining:
                        chunk = src.read(min(1024 * 1024, remaining))
                        if not chunk: raise RuntimeError("Truncated Bitwarden ZIP entry")
                        out.write(chunk); remaining -= len(chunk)
            with (stage / "bw").open("rb") as binary_file: header = binary_file.read(64)
            if (len(header) < 64 or header[:4] != b"\x7fELF" or header[4] != 2 or header[5] != 1 or header[6] != 1 or int.from_bytes(header[16:18], "little") not in {2, 3} or int.from_bytes(header[18:20], "little") != 62 or int.from_bytes(header[20:24], "little") != 1 or int.from_bytes(header[52:54], "little") != 64):
                raise RuntimeError("Bitwarden binary is not a complete x86_64 ELF64 binary")
            os.chmod(stage / "bw", 0o755)
            _publish_noreplace(stage, destination, parent_fd=parent_fd)
    finally:
        if stage_path is not None:
            shutil.rmtree(stage_path, ignore_errors=True)
        os.close(parent_fd)
