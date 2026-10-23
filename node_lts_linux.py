#!/usr/bin/env python3
"""Official Node.js LTS Linux x86_64 archive adapter."""
from __future__ import annotations
import hashlib, json, lzma, os, platform, posixpath, re, shutil, stat, tarfile, tempfile
import urllib.error, urllib.parse, urllib.request
from pathlib import Path, PurePath
from typing import Any, Mapping
import bitwarden_cli_linux as _bw

SCOOP_MANIFEST_URL = "https://raw.githubusercontent.com/ScoopInstaller/Main/master/bucket/nodejs-lts.json"
NODE_INDEX_URL = "https://nodejs.org/dist/index.json"
NODE_DIST_BASE = "https://nodejs.org/dist/"
COMPATIBILITY_SOURCE = "https://github.com/nodejs/node/blob/main/BUILDING.md"
DOWNLOAD_LIMIT = 512 * 1024 * 1024
UNCOMPRESSED_LIMIT = 2 * 1024 * 1024 * 1024
METADATA_LIMIT = 8 * 1024 * 1024
TIMEOUT = 30
USER_AGENT = "mainframe-native-shells/1.0 (Node.js LTS resolver)"
SCOOP_MAX_REDIRECTIONS = 3
_SHA256 = re.compile(r"^[0-9a-fA-F]{64}$")
_VERSION = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$")


def _official_url(url: str) -> bool:
    try:
        p = urllib.parse.urlsplit(url)
        return p.scheme == "https" and p.netloc == "nodejs.org" and p.port is None and not p.username and not p.password and not p.query and not p.fragment and p.path.startswith("/")
    except (TypeError, ValueError): return False


def _scoop_url(url: str) -> bool:
    return url == SCOOP_MANIFEST_URL


def _exact_scoop_redirect(url: str) -> bool:
    try:
        p = urllib.parse.urlsplit(url)
        return (p.scheme == "https" and p.netloc == "raw.githubusercontent.com" and
                p.path == urllib.parse.urlsplit(SCOOP_MANIFEST_URL).path and
                p.port is None and not p.username and not p.password and
                not p.query and not p.fragment)
    except (TypeError, ValueError): return False


class _Redirects(urllib.request.HTTPRedirectHandler):
    def __init__(self, expected_path: str | None = None): self.expected_path = expected_path
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        expected = self.expected_path or urllib.parse.urlsplit(req.full_url).path
        if not _official_url(newurl) or urllib.parse.urlsplit(newurl).path != expected:
            p = urllib.parse.urlsplit(newurl)
            safe = urllib.parse.urlunsplit((p.scheme, p.netloc, p.path, "", ""))
            raise RuntimeError(f"Refusing non-exact official Node.js redirect: {safe!r}")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


class _ScoopRedirects(urllib.request.HTTPRedirectHandler):
    max_redirections = SCOOP_MAX_REDIRECTIONS

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if not _exact_scoop_redirect(newurl):
            p = urllib.parse.urlsplit(newurl)
            safe = urllib.parse.urlunsplit((p.scheme, p.netloc, p.path, "", ""))
            raise RuntimeError(f"Refusing non-exact Scoop manifest redirect: {safe!r}")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def _open(url: str, *, limit: int):
    if not _official_url(url): raise RuntimeError(f"Refusing non-official Node.js URL: {url!r}")
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept": "application/json, text/plain"})
    try: response = urllib.request.build_opener(_Redirects(urllib.parse.urlsplit(url).path)).open(req, timeout=TIMEOUT)
    except (urllib.error.URLError, OSError) as exc: raise RuntimeError(f"Official Node.js metadata request failed: {exc}") from exc
    length = response.headers.get("Content-Length")
    if length is not None:
        try:
            if int(length) > limit: response.close(); raise RuntimeError(f"Response exceeds limit of {limit} bytes")
        except ValueError: response.close(); raise RuntimeError("Invalid Content-Length") from None
    return response


def _open_scoop(url: str, *, limit: int):
    if not _scoop_url(url): raise RuntimeError("Refusing non-exact Scoop manifest URL")
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept": "application/json"})
    try: response = urllib.request.build_opener(_ScoopRedirects()).open(req, timeout=TIMEOUT)
    except (urllib.error.URLError, OSError) as exc: raise RuntimeError(f"Scoop manifest request failed: {exc}") from exc
    length = response.headers.get("Content-Length")
    if length is not None:
        try:
            if int(length) > limit: response.close(); raise RuntimeError(f"Response exceeds limit of {limit} bytes")
        except ValueError: response.close(); raise RuntimeError("Invalid Content-Length") from None
    return response


def _read(response: Any, limit: int) -> bytes:
    chunks, total = [], 0
    try:
        while True:
            chunk = response.read(min(1024 * 1024, limit - total + 1))
            if not chunk: return b"".join(chunks)
            total += len(chunk)
            if total > limit: raise RuntimeError(f"Response exceeds limit of {limit} bytes")
            chunks.append(chunk)
    finally: response.close()


def _json(url: str, limit: int = METADATA_LIMIT) -> Any:
    opener = _open_scoop if _scoop_url(url) else _open
    try: return json.loads(_read(opener(url, limit=limit), limit).decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError, TypeError) as exc: raise RuntimeError("Invalid official metadata JSON") from exc


def _manifest_version(manifest: Mapping[str, Any]) -> tuple[str, str, str]:
    version = manifest.get("version"); arch = manifest.get("architecture"); item = arch.get("64bit") if isinstance(arch, Mapping) else None
    url = item.get("url") if isinstance(item, Mapping) else None; digest = item.get("hash") if isinstance(item, Mapping) else None
    if not isinstance(version, str) or not _VERSION.fullmatch(version): raise RuntimeError("Scoop Node.js LTS manifest has invalid version")
    if not isinstance(url, str) or not isinstance(digest, str) or not _SHA256.fullmatch(digest): raise RuntimeError("Scoop manifest has invalid Windows SHA256")
    m = re.fullmatch(r"https://nodejs\.org/dist/v([^/]+)/node-v\1-win-x64\.(7z|zip)", url)
    if not m or m.group(1) != version or not _official_url(url): raise RuntimeError("Scoop manifest is not the exact official Windows x64 URL")
    return version, url, digest.lower()


def _checksums(data: bytes, filename: str) -> str:
    try: lines = data.decode("utf-8").splitlines()
    except UnicodeDecodeError as exc: raise RuntimeError("Node.js checksum file is not UTF-8") from exc
    found = [f[0].lower() for line in lines if len(f := line.split()) == 2 and f[1].lstrip("* ") == filename and _SHA256.fullmatch(f[0])]
    if len(found) != 1: raise RuntimeError(f"Node.js SHASUMS256.txt has missing or ambiguous checksum for {filename}")
    return found[0]


def _index_entry(index: Any, version: str) -> Mapping[str, Any]:
    if not isinstance(index, list): raise RuntimeError("Node.js index metadata is not a list")
    matches = [x for x in index if isinstance(x, Mapping) and x.get("version") == "v" + version]
    if len(matches) != 1: raise RuntimeError("Node.js index has missing or ambiguous version metadata")
    entry = matches[0]; lts = entry.get("lts")
    if not isinstance(lts, str) or not lts.strip(): raise RuntimeError("Node.js release is not an official named LTS release")
    return entry


def resolve_release(architecture: str) -> dict[str, str]:
    if architecture != "x86_64": raise RuntimeError(f"Unsupported architecture: {architecture}")
    version, windows_url, windows_manifest_hash = _manifest_version(_json(SCOOP_MANIFEST_URL))
    _index_entry(_json(NODE_INDEX_URL), version)
    linux_name = f"node-v{version}-linux-x64.tar.xz"; linux_url = f"{NODE_DIST_BASE}v{version}/{linux_name}"; sums_url = f"{NODE_DIST_BASE}v{version}/SHASUMS256.txt"
    sums = _read(_open(sums_url, limit=METADATA_LIMIT), METADATA_LIMIT)
    linux_hash = _checksums(sums, linux_name); windows_hash = _checksums(sums, windows_url.rsplit("/", 1)[1])
    if windows_hash != windows_manifest_hash: raise RuntimeError("Scoop Windows SHA256 disagrees with official SHASUMS256.txt")
    return _validate_release({"version": version, "url": linux_url, "sha256": linux_hash, "size": "unknown", "asset_name": linux_name, "manifest_source": SCOOP_MANIFEST_URL, "index_source": NODE_INDEX_URL, "checksums_source": sums_url, "windows_url": windows_url, "windows_sha256": windows_hash, "compatibility_source": COMPATIBILITY_SOURCE, "compatibility": "Linux x86_64; Node.js current Linux binaries require glibc >= 2.28 and compatible libstdc++ (runtime not tested)."})


def _validate_release(release: Mapping[str, Any]) -> dict[str, str]:
    required = {"version","url","sha256","size","asset_name","manifest_source","index_source","checksums_source","windows_url","windows_sha256","compatibility_source","compatibility"}
    if not isinstance(release, Mapping) or set(release) != required or any(not isinstance(release[k], str) or not release[k] for k in required): raise ValueError("Invalid Node.js LTS release metadata")
    v = release["version"]
    if not _VERSION.fullmatch(v) or release["asset_name"] != f"node-v{v}-linux-x64.tar.xz": raise ValueError("Invalid Node.js release asset")
    if release["url"] != f"{NODE_DIST_BASE}v{v}/{release['asset_name']}" or not _official_url(release["url"]): raise ValueError("Node.js Linux URL is not exact")
    if not re.fullmatch(rf"https://nodejs\.org/dist/v{re.escape(v)}/node-v{re.escape(v)}-win-x64\.(?:7z|zip)", release["windows_url"]): raise ValueError("Node.js Windows URL is not exact")
    if release["manifest_source"] != SCOOP_MANIFEST_URL or release["index_source"] != NODE_INDEX_URL or release["checksums_source"] != f"{NODE_DIST_BASE}v{v}/SHASUMS256.txt": raise ValueError("Invalid Node.js provenance")
    if not _SHA256.fullmatch(release["sha256"]) or not _SHA256.fullmatch(release["windows_sha256"]): raise ValueError("Invalid Node.js SHA256")
    if release["size"] != "unknown" and (not release["size"].isdigit() or int(release["size"]) > DOWNLOAD_LIMIT): raise ValueError("Invalid Node.js archive size")
    return dict(release)


def _cpu_compatible() -> None:
    if platform.system() != "Linux" or platform.machine().lower() not in {"x86_64","amd64"} or platform.libc_ver()[0].lower() != "glibc": raise RuntimeError("Node.js LTS requires Linux x86_64 with glibc")
    try: glibc = tuple(int(x) for x in platform.libc_ver()[1].split(".")[:2])
    except (ValueError, TypeError): raise RuntimeError("Unable to determine glibc version") from None
    if glibc < (2, 28): raise RuntimeError("Node.js current Linux x64 requires glibc >= 2.28")


def validate_install(release: Mapping[str, Any], destination: Path) -> None:
    _validate_release(release); _cpu_compatible(); _bw._safe_destination(Path(destination))
    if getattr(_bw.ctypes.CDLL(None), "renameat2", None) is None: raise RuntimeError("Linux renameat2 is required for race-safe publication")


def _safe_member(name: str, root: str) -> str:
    if not isinstance(name, str) or not name or name.endswith("/") or "\\" in name or any(ord(c) < 32 or ord(c) == 127 for c in name): raise ValueError("Node.js archive contains non-canonical filename")
    parts = name.split("/")
    if any(p in {"", ".", ".."} for p in parts) or parts[0] != root or posixpath.normpath(name) != name: raise ValueError("Node.js archive contains unsafe path")
    return name


def _tar_members(tar: tarfile.TarFile, version: str) -> list[tarfile.TarInfo]:
    root = f"node-v{version}-linux-x64"; members=[]; names=set(); total=0
    while True:
        m = tar.next()
        if m is None: break
        if len(members) >= 100000: raise ValueError("Node.js archive has too many members")
        normalized = _safe_member(m.name.rstrip("/"), root)
        if normalized in names: raise ValueError("Node.js archive contains duplicate members")
        names.add(normalized); members.append(m)
        if m.mode & 0o022: raise ValueError("Node.js archive contains group/world-writable entry")
        if m.isreg():
            if m.size < 0 or m.size > UNCOMPRESSED_LIMIT: raise ValueError("Node.js archive file is too large")
            total += m.size
            if total > UNCOMPRESSED_LIMIT: raise ValueError("Node.js archive uncompressed size exceeds limit")
        elif not (m.isdir() or m.issym()): raise ValueError("Node.js archive contains special file")
    if not members or not any(m.name.rstrip("/") == root and m.isdir() for m in members): raise ValueError("Node.js archive has no exact root directory")
    return members


def install_release(release: Mapping[str, Any], destination: Path) -> None:
    v = _validate_release(release); validate_install(v, destination); destination = Path(os.path.normpath(str(Path(destination).expanduser())))
    parent_fd, _ = _bw._open_destination_parent(destination); stage_path = None
    try:
        stage_path = Path(tempfile.mkdtemp(prefix=".nodejs-lts-", dir=f"/proc/self/fd/{parent_fd}")); os.chmod(stage_path, 0o700)
        with tempfile.TemporaryDirectory(prefix=".nodejs-download-", dir=f"/proc/self/fd/{parent_fd}") as td:
            archive = Path(td) / v["asset_name"]; digest=hashlib.sha256(); total=0; response=_open(v["url"], limit=DOWNLOAD_LIMIT)
            try:
                with archive.open("wb") as out:
                    while True:
                        chunk=response.read(min(1024*1024, DOWNLOAD_LIMIT-total+1))
                        if not chunk: break
                        total += len(chunk)
                        if total > DOWNLOAD_LIMIT: raise RuntimeError("Node.js download exceeds limit")
                        digest.update(chunk); out.write(chunk)
            finally: response.close()
            if digest.hexdigest() != v["sha256"]: raise RuntimeError("Node.js download SHA256 mismatch")
            if v["size"] != "unknown" and total != int(v["size"]): raise RuntimeError("Node.js download size mismatch")
            tar_path = Path(td) / "archive.tar"; dec_total=0
            with lzma.open(archive, "rb") as src, tar_path.open("wb") as out:
                while chunk := src.read(1024*1024):
                    dec_total += len(chunk)
                    if dec_total > UNCOMPRESSED_LIMIT: raise RuntimeError("Node.js decompressed archive exceeds limit")
                    out.write(chunk)
            with tarfile.open(tar_path, mode="r:") as tar:
                members=_tar_members(tar, v["version"])
            root=f"node-v{v['version']}-linux-x64"; by_name={m.name.rstrip("/"):m for m in members}; symlinks=[m for m in members if m.issym()]
            dirs={n for n,m in by_name.items() if m.isdir()}; regs={n for n,m in by_name.items() if m.isreg()}
            symlink_names={m.name.rstrip("/") for m in symlinks}
            for name in by_name:
                parts=name.split("/")
                if any("/".join(parts[:i]) in symlink_names for i in range(1, len(parts))):
                    raise ValueError("Node.js archive path traverses a symlink member")
            for m in symlinks:
                rel=m.name[len(root):].lstrip("/"); link=m.linkname
                if not link or "\\" in link or any(ord(c)<32 or ord(c)==127 for c in link) or PurePath(link).is_absolute(): raise ValueError("Node.js symlink escapes archive root")
                resolved=posixpath.normpath(posixpath.join(posixpath.dirname(rel), link))
                if resolved in {".", ".."} or resolved.startswith("../") or (root+"/"+resolved not in by_name): raise ValueError("Node.js symlink target is missing or escapes archive root")
                if any(root+"/"+p in symlink_names for p in resolved.split("/")[:-1]): raise ValueError("Node.js symlink traverses a symlink directory")
                cursor = root+"/"+resolved; seen=set()
                while cursor in symlink_names:
                    if cursor in seen: raise ValueError("Node.js archive contains a symlink cycle")
                    seen.add(cursor); child=by_name[cursor]; child_rel=child.name[len(root):].lstrip("/")
                    cursor = root+"/"+posixpath.normpath(posixpath.join(posixpath.dirname(child_rel), child.linkname))
                if cursor not in by_name or cursor in symlink_names: raise ValueError("Node.js symlink does not resolve to a real archive member")
            with tarfile.open(tar_path, mode="r:") as tar:
                for m in members:
                    rel=_safe_member(m.name.rstrip("/"),root)[len(root):].lstrip("/"); target=stage_path/rel
                    if m.isdir() and rel: target.mkdir(parents=False, exist_ok=False); os.chmod(target, stat.S_IMODE(m.mode)&0o755)
                    elif m.isreg():
                        target.parent.mkdir(parents=True, exist_ok=True); src=tar.extractfile(m)
                        if src is None: raise RuntimeError("Truncated Node.js archive member")
                        with src, target.open("wb") as out: shutil.copyfileobj(src,out,1024*1024)
                        os.chmod(target, stat.S_IMODE(m.mode)&0o755)
                for m in symlinks:
                    rel=m.name[len(root):].lstrip("/"); target=stage_path/rel; target.parent.mkdir(parents=True,exist_ok=True); os.symlink(m.linkname,target)
            node=stage_path/"bin"/"node"
            if not node.is_file() or node.is_symlink(): raise RuntimeError("Node.js archive has no regular bin/node")
            with node.open("rb") as f: header=f.read(64)
            if len(header)<64 or header[:4]!=b"\x7fELF" or header[4:7]!=bytes((2,1,1)) or int.from_bytes(header[18:20],"little")!=62 or int.from_bytes(header[20:24],"little")!=1: raise RuntimeError("Node.js binary is not a complete x86_64 ELF64 binary")
            _bw._publish_noreplace(stage_path,destination,parent_fd=parent_fd); stage_path=None
    finally:
        if stage_path is not None: shutil.rmtree(stage_path,ignore_errors=True)
        os.close(parent_fd)
