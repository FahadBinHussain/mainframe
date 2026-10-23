#!/usr/bin/env python3
"""Read-only official GitHub release resolver and safe Linux publisher.

Only Linux x86_64/glibc is supported.  The glibc check is a common platform
floor; package-specific glibc minimums remain unresolved and are not claimed.
"""
from __future__ import annotations
import ctypes, gzip, hashlib, json, os, platform, re, shutil, stat, tarfile, tempfile, urllib.error, urllib.parse, urllib.request, zipfile
from pathlib import Path, PurePath
from typing import Any, Mapping

import bitwarden_cli_linux as _bw

DOWNLOAD_LIMIT = 512 * 1024 * 1024
METADATA_LIMIT = 4 * 1024 * 1024
ARCHIVE_ENTRY_LIMIT = 512 * 1024 * 1024
ARCHIVE_MEMBER_LIMIT = 64
ARCHIVE_TOTAL_LIMIT = 512 * 1024 * 1024
TIMEOUT = 30
USER_AGENT = "mainframe-native-shells/1.0 (official GitHub Linux resolver)"
SCOOP_BASE = "https://raw.githubusercontent.com/ScoopInstaller/Main/master/bucket/"
GITHUB_API = "https://api.github.com/repos/"
_SHA = re.compile(r"[0-9a-fA-F]{64}\Z")
_VER = re.compile(r"[0-9A-Za-z][0-9A-Za-z.+_-]*\Z")

_PRODUCTS = {
    "cloudflared": dict(repo="cloudflare/cloudflared", tag=lambda v: v, win=lambda v: "cloudflared-windows-amd64.exe", win_suffix="#/cloudflared.exe", asset="cloudflared-linux-amd64", install_name="cloudflared", fmt="raw", members=("cloudflared-linux-amd64",)),
    "deno": dict(repo="denoland/deno", tag=lambda v: "v" + v, win=lambda v: f"deno-x86_64-pc-windows-msvc.zip", asset="deno-x86_64-unknown-linux-gnu.zip", install_name="deno", fmt="zip", members=("deno",)),
    "pnpm": dict(repo="pnpm/pnpm", tag=lambda v: "v" + v, win=lambda v: "pnpm-win32-x64.zip", asset="pnpm-linux-x64.tar.gz", install_name="pnpm", fmt="tar.gz", members=("pnpm-linux-x64/pnpm",)),
    "uv": dict(repo="astral-sh/uv", tag=lambda v: v, win=lambda v: "uv-x86_64-pc-windows-msvc.zip", asset="uv-x86_64-unknown-linux-gnu.tar.gz", install_name="uv", fmt="tar.gz", members=("uv-x86_64-unknown-linux-gnu/uv", "uv-x86_64-unknown-linux-gnu/uvx")),
    "yq": dict(repo="mikefarah/yq", tag=lambda v: "v" + v, win=lambda v: "yq_windows_amd64.exe", win_suffix="#/yq.exe", asset="yq_linux_amd64", install_name="yq", fmt="raw", members=("yq_linux_amd64",)),
}


def _url_ok(url: str, *, api=False, redirect=False) -> bool:
    try:
        p = urllib.parse.urlsplit(url)
        port = p.port
    except (TypeError, ValueError):
        return False
    hosts = {"api.github.com", "raw.githubusercontent.com"} if api else {"github.com", "raw.githubusercontent.com", "release-assets.githubusercontent.com"}
    if p.scheme != "https" or p.netloc not in hosts or port is not None or p.username or p.password or p.fragment:
        return False
    if p.netloc == "release-assets.githubusercontent.com":
        return redirect and bool(p.query) and re.fullmatch(r"/github-production-release-asset/[0-9]+/[A-Za-z0-9._-]+", p.path or "") is not None
    return not p.query and p.path.startswith("/")


class _Redirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        source, target = urllib.parse.urlsplit(req.full_url), urllib.parse.urlsplit(newurl)
        download = source.netloc == "github.com" and "/releases/download/" in source.path
        same_path = (target.netloc == source.netloc and target.path == source.path and
                     _url_ok(newurl, api=source.netloc in {"api.github.com", "raw.githubusercontent.com"}))
        allowed = (same_path or (_url_ok(newurl, redirect=True) and
                   target.netloc == "release-assets.githubusercontent.com")) if download else same_path
        if not allowed:
            raise RuntimeError("Refusing non-official redirect")
        return super().redirect_request(req, fp, code, msg, headers, newurl)
def _open(url: str, *, limit: int, api=False):
    if not _url_ok(url, api=api):
        raise RuntimeError(f"Refusing non-official URL: {url!r}")
    try:
        response = urllib.request.build_opener(_Redirects()).open(urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept": "application/vnd.github+json"}), timeout=TIMEOUT)
    except (urllib.error.URLError, OSError) as exc:
        raise RuntimeError(f"Official metadata request failed: {exc}") from exc
    length = response.headers.get("Content-Length")
    if length is not None:
        try:
            too_big = int(length) > limit
        except (TypeError, ValueError):
            response.close(); raise RuntimeError("Invalid Content-Length") from None
        if too_big:
            response.close(); raise RuntimeError("Response exceeds limit")
    return response


def _read(response, limit):
    chunks, total = [], 0
    try:
        while True:
            chunk = response.read(min(65536, limit - total + 1))
            if not chunk:
                return b"".join(chunks)
            total += len(chunk)
            if total > limit:
                raise RuntimeError("Response exceeds limit")
            chunks.append(chunk)
    finally:
        response.close()


def _json(url, *, api=False):
    try:
        value = json.loads(_read(_open(url, limit=METADATA_LIMIT, api=api), METADATA_LIMIT).decode())
    except (UnicodeDecodeError, json.JSONDecodeError, TypeError) as exc:
        raise RuntimeError("Invalid official metadata JSON") from exc
    if not isinstance(value, Mapping):
        raise RuntimeError("Official metadata is not an object")
    return value


def _manifest(name):
    return _json(SCOOP_BASE + name + ".json")


def _manifest_version(name, manifest):
    spec = _PRODUCTS[name]; version = manifest.get("version"); arch = manifest.get("architecture")
    item = arch.get("64bit") if isinstance(arch, Mapping) else None
    url = item.get("url") if isinstance(item, Mapping) else None
    win_hash = item.get("hash") if isinstance(item, Mapping) else None
    if not isinstance(version, str) or not _VER.fullmatch(version) or not isinstance(url, str) or not isinstance(win_hash, str) or not _SHA.fullmatch(win_hash):
        raise RuntimeError("Invalid Scoop manifest version, URL, or Windows SHA256")
    tag = spec["tag"](version); expected = f"https://github.com/{spec['repo']}/releases/download/{tag}/{spec['win'](version)}{spec.get('win_suffix', '')}"
    if url != expected:
        raise RuntimeError("Scoop manifest Windows URL is not the exact official variant")
    return version, tag, expected, win_hash.lower()


def _asset(release, name):
    assets = release.get("assets")
    if not isinstance(assets, list):
        raise RuntimeError("GitHub release has no assets")
    found = [a for a in assets if isinstance(a, Mapping) and a.get("name") == name]
    if len(found) != 1:
        raise RuntimeError(f"Missing or ambiguous release asset: {name}")
    a = found[0]; url, size, digest = a.get("browser_download_url"), a.get("size"), a.get("digest")
    if not isinstance(url, str) or not _url_ok(url) or urllib.parse.urlsplit(url).netloc != "github.com":
        raise RuntimeError("Release asset URL is not official")
    if not isinstance(size, int) or isinstance(size, bool) or size <= 0 or size > DOWNLOAD_LIMIT:
        raise RuntimeError("Release asset size is invalid")
    if not isinstance(digest, str) or not digest.startswith("sha256:") or not _SHA.fullmatch(digest[7:]):
        raise RuntimeError("Release asset requires a SHA256 digest")
    return url, str(size), digest[7:].lower()


def resolve_release(name: str, architecture: str) -> dict[str, str]:
    if architecture != "x86_64":
        raise RuntimeError(f"Unsupported architecture: {architecture}")
    if not isinstance(name, str) or name not in _PRODUCTS:
        raise RuntimeError(f"Unsupported product: {name}")
    spec = _PRODUCTS[name]; version, tag, windows_url, scoop_win_sha = _manifest_version(name, _manifest(name))
    source = GITHUB_API + spec["repo"] + "/releases/tags/" + urllib.parse.quote(tag, safe="")
    release = _json(source, api=True)
    if release.get("tag_name") != tag or release.get("draft") is not False or release.get("prerelease") is not False or not isinstance(release.get("published_at"), str) or not release.get("published_at"):
        raise RuntimeError("Release is not a published stable exact tag")
    win = _asset(release, spec["win"](version))
    if win[0] + spec.get("win_suffix", "") != windows_url or win[2] != scoop_win_sha:
        raise RuntimeError("Scoop Windows hash disagrees with official GitHub asset")
    linux_name = spec["asset"]; url, size, digest = _asset(release, linux_name)
    result = {"name": name, "version": version, "url": url, "sha256": digest, "size": size, "asset_name": linux_name, "manifest_source": SCOOP_BASE + name + ".json", "release_source": source, "format": spec["fmt"], "windows_asset_name": spec["win"](version)}
    return _validate_release(result)


def _validate_release(r: Mapping[str, Any]) -> dict[str, str]:
    if not isinstance(r, Mapping):
        raise ValueError("Invalid product metadata")
    name = r.get("name")
    if not isinstance(name, str) or name not in _PRODUCTS:
        raise ValueError("Invalid product metadata")
    spec = _PRODUCTS[name]; required = {"name", "version", "url", "sha256", "size", "asset_name", "manifest_source", "release_source", "format", "windows_asset_name"}
    try:
        keys = set(r)
    except (TypeError, ValueError):
        raise ValueError("Invalid release metadata") from None
    if keys != required or any(not isinstance(r[k], str) or not r[k] for k in required):
        raise ValueError("Invalid release metadata")
    if not _VER.fullmatch(r["version"]) or r["format"] != spec["fmt"] or r["asset_name"] != spec["asset"] or r["windows_asset_name"] != spec["win"](r["version"]):
        raise ValueError("Wrong release variant")
    tag = spec["tag"](r["version"]); repo = spec["repo"]
    if r["manifest_source"] != SCOOP_BASE + name + ".json" or r["release_source"] != GITHUB_API + repo + "/releases/tags/" + urllib.parse.quote(tag, safe=""):
        raise ValueError("Invalid provenance")
    if not _SHA.fullmatch(r["sha256"]) or not _url_ok(r["url"]):
        raise ValueError("Invalid digest or URL")
    p = urllib.parse.urlsplit(r["url"])
    if p.netloc != "github.com" or p.path != f"/{repo}/releases/download/{tag}/{spec['asset']}":
        raise ValueError("Download URL is not exact")
    try:
        size = int(r["size"])
    except (TypeError, ValueError):
        raise ValueError("Invalid size") from None
    if size <= 0 or size > DOWNLOAD_LIMIT or str(size) != r["size"]:
        raise ValueError("Invalid size")
    return dict(r)


def _elf(data: bytes):
    if (len(data) < 64 or data[:4] != b"\x7fELF" or data[4:7] != bytes((2, 1, 1) or ()) or
            int.from_bytes(data[16:18], "little") not in (2, 3) or int.from_bytes(data[20:24], "little") != 1 or
            int.from_bytes(data[18:20], "little") != 62 or int.from_bytes(data[52:54], "little") != 64):
        raise RuntimeError("Extracted file is not an ELF64 x86_64 binary")


def _safe_member(name: str):
    if not isinstance(name, str):
        raise ValueError("Unsafe archive member")
    p = PurePath(name)
    if not name or p.is_absolute() or ".." in p.parts or "\\" in name or "//" in name:
        raise ValueError("Unsafe archive member")


def _allowed_tar_dirs(members):
    dirs = set()
    for name in members:
        parts = name.split("/")[:-1]
        for i in range(1, len(parts) + 1):
            d = "/".join(parts[:i])
            dirs.add(d)
            dirs.add(d + "/")
    return dirs


def _extract(archive: Path, stage: Path, spec):
    expected = set(spec["members"])
    if spec["fmt"] == "zip":
        with zipfile.ZipFile(archive) as z:
            infos = z.infolist(); names = [i.filename for i in infos]
            if len(infos) > ARCHIVE_MEMBER_LIMIT or len(names) != len(set(names)) or set(names) != expected:
                raise ValueError("Archive members are not exact")
            total = 0
            for i in infos:
                _safe_member(i.filename); mode = (i.external_attr >> 16) & 0o170000
                if i.is_dir() or mode not in (0, stat.S_IFREG) or i.file_size <= 0 or i.file_size > ARCHIVE_ENTRY_LIMIT:
                    raise ValueError("Unsafe ZIP entry")
                total += i.file_size
                if total > ARCHIVE_TOTAL_LIMIT or (i.compress_size and i.file_size > i.compress_size * 1000):
                    raise ValueError("Unsafe ZIP entry")
                data = z.read(i); _elf(data); out = stage / Path(i.filename).name; out.write_bytes(data); os.chmod(out, 0o755)
    elif spec["fmt"] == "tar.gz":
        # Decompress into a bounded spool before tar parsing; getmembers() must
        # never be allowed to consume an unbounded decompressed gzip stream.
        with archive.open("rb") as raw, gzip.GzipFile(fileobj=raw, mode="rb") as gz, tempfile.SpooledTemporaryFile(max_size=8 * 1024 * 1024) as spool:
            total = 0
            while True:
                chunk = gz.read(min(1024 * 1024, ARCHIVE_TOTAL_LIMIT - total + 1))
                if not chunk:
                    break
                total += len(chunk)
                if total > ARCHIVE_TOTAL_LIMIT:
                    raise ValueError("Decompressed TAR exceeds limit")
                spool.write(chunk)
            spool.seek(0)
            with tarfile.open(fileobj=spool, mode="r:") as t:
                allowed_dirs = _allowed_tar_dirs(expected); names = set(); regular_total = 0
                for m in t:
                    if len(names) >= ARCHIVE_MEMBER_LIMIT:
                        raise ValueError("Too many TAR members")
                    _safe_member(m.name)
                    if m.name in names:
                        raise ValueError("Archive members are not exact")
                    names.add(m.name)
                    if m.name in allowed_dirs:
                        if not m.isdir():
                            raise ValueError("Unsafe TAR directory entry")
                        continue
                    if m.name not in expected or not m.isreg() or m.size <= 0 or m.size > ARCHIVE_ENTRY_LIMIT:
                        raise ValueError("Unsafe TAR entry")
                    regular_total += m.size
                    if regular_total > ARCHIVE_TOTAL_LIMIT:
                        raise ValueError("TAR members exceed limit")
                    src = t.extractfile(m); data = src.read(m.size + 1) if src else b""
                    if len(data) != m.size:
                        raise ValueError("Truncated TAR entry")
                    _elf(data); out = stage / Path(m.name).name; out.write_bytes(data); os.chmod(out, 0o755)
                if not expected.issubset(names):
                    raise ValueError("Archive members are not exact")


def validate_install(release: Mapping[str, Any], destination: Path) -> None:
    _validate_release(release)
    if platform.system() != "Linux" or platform.machine().lower() not in {"x86_64", "amd64"} or platform.libc_ver()[0].lower() != "glibc":
        raise RuntimeError("Linux x86_64 with glibc is required")
    _bw._safe_destination(Path(destination))
    if getattr(ctypes.CDLL(None), "renameat2", None) is None:
        raise RuntimeError("Linux renameat2 is required")


def install_release(release: Mapping[str, Any], destination: Path) -> None:
    r = _validate_release(release); validate_install(r, destination); destination = Path(os.path.normpath(str(Path(destination).expanduser())))
    parent_fd, _ = _bw._open_destination_parent(destination); stage = None
    try:
        stage = Path(tempfile.mkdtemp(prefix=".github-native-", dir=f"/proc/self/fd/{parent_fd}")); os.chmod(stage, 0o700)
        with tempfile.TemporaryDirectory(prefix=".github-download-", dir=f"/proc/self/fd/{parent_fd}") as td:
            archive = Path(td) / "release"; response = _open(r["url"], limit=DOWNLOAD_LIMIT); h = hashlib.sha256(); total = 0
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
            spec = _PRODUCTS[r["name"]]
            if spec["fmt"] == "raw":
                data = archive.read_bytes(); _elf(data); out = stage / spec["install_name"]; out.write_bytes(data); os.chmod(out, 0o755)
            else:
                _extract(archive, stage, spec)
        _bw._publish_noreplace(stage, destination, parent_fd=parent_fd); stage = None
    finally:
        if stage is not None: shutil.rmtree(stage, ignore_errors=True)
        os.close(parent_fd)


__all__ = ["resolve_release", "validate_install", "install_release"]
