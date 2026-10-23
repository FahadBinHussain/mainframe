#!/usr/bin/env python3
"""OpenCode v2 Linux x86_64 baseline native package adapter."""
from __future__ import annotations
import base64, binascii, gzip, hashlib, io, json, os, platform, re, shutil, stat, tarfile, tempfile
import urllib.error, urllib.parse, urllib.request
from pathlib import Path, PurePosixPath
from typing import Any, Mapping
import bitwarden_cli_linux as _bw

SCOOP_MANIFEST_URL = "https://raw.githubusercontent.com/ScoopInstaller/Versions/master/bucket/opencode2.json"
NPM_REGISTRY = "https://registry.npmjs.org"
PACKAGE = "@opencode/cli"
WINDOWS_PACKAGE = "@opencode/cli-windows-x64"
LINUX_PACKAGE = "@opencode/cli-linux-x64-baseline"
METADATA_LIMIT = 4 * 1024 * 1024
DOWNLOAD_LIMIT = 512 * 1024 * 1024
UNPACKED_LIMIT = 1024 * 1024 * 1024
MEMBER_LIMIT = 32
PACKAGE_JSON_LIMIT = 64 * 1024
TIMEOUT = 30
_VERSION = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$")
_HEX = re.compile(r"^[0-9a-fA-F]{128}$")
_REPO = "git+https://github.com/anomalyco/opencode.git"


def _url(url: str) -> bool:
    try:
        p = urllib.parse.urlsplit(url)
        return p.scheme == "https" and p.netloc == "registry.npmjs.org" and p.port is None and not p.username and not p.password and not p.query and not p.fragment and p.path.startswith("/")
    except (TypeError, ValueError):
        return False

class _Redirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        p = urllib.parse.urlsplit(newurl)
        old = urllib.parse.urlsplit(req.full_url)
        if req.full_url == SCOOP_MANIFEST_URL:
            allowed = newurl == SCOOP_MANIFEST_URL
        else:
            allowed = _url(newurl) and p.path == old.path
        if not allowed:
            raise RuntimeError(f"Refusing non-exact redirect: {newurl!r}")
        return super().redirect_request(req, fp, code, msg, headers, newurl)

def _open(url: str, *, limit: int):
    if url != SCOOP_MANIFEST_URL and not _url(url):
        raise RuntimeError(f"Refusing non-registry URL: {url!r}")
    try:
        r = urllib.request.build_opener(_Redirects()).open(urllib.request.Request(url, headers={"User-Agent":"mainframe-native-shells/1.0 (OpenCode v2 resolver)", "Accept":"application/json"}), timeout=TIMEOUT)
    except (urllib.error.URLError, OSError) as e:
        raise RuntimeError(f"Official metadata request failed: {e}") from e
    n = r.headers.get("Content-Length")
    if n is not None:
        try:
            if int(n) > limit: r.close(); raise RuntimeError("Response exceeds metadata limit")
        except ValueError: r.close(); raise RuntimeError("Invalid Content-Length") from None
    return r

def _read(r: Any, limit: int) -> bytes:
    parts=[]; total=0
    try:
        while True:
            b=r.read(min(1024*1024, limit-total+1))
            if not b: return b''.join(parts)
            total += len(b)
            if total > limit: raise RuntimeError("Response exceeds limit")
            parts.append(b)
    finally: r.close()

def _json(url: str) -> Mapping[str, Any]:
    try:
        x=json.loads(_read(_open(url, limit=METADATA_LIMIT), METADATA_LIMIT).decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError, TypeError, ValueError) as e:
        raise RuntimeError("Invalid public metadata JSON") from e
    if not isinstance(x, Mapping): raise RuntimeError("Public metadata is not an object")
    return x

def _pkg_url(name: str, version: str) -> str: return f"{NPM_REGISTRY}/{name}/{version}"
def _tarball(name: str, version: str) -> str: return f"{NPM_REGISTRY}/{name}/-/{name.rsplit('/',1)[-1]}-{version}.tgz"

def _integrity(v: Any) -> str:
    if not isinstance(v, str) or not v.startswith("sha512-"): raise RuntimeError("Missing or invalid npm SHA512 integrity")
    raw=v[7:]
    try: decoded=base64.b64decode(raw, validate=True)
    except (ValueError, binascii.Error): raise RuntimeError("Missing or invalid npm SHA512 integrity") from None
    if len(decoded) != 64 or base64.b64encode(decoded).decode() != raw: raise RuntimeError("Non-canonical npm SHA512 integrity")
    return v

def _digest(integrity: str) -> str:
    return base64.b64decode(_integrity(integrity)[7:], validate=True).hex()

def _meta_fields(meta: Mapping[str,Any], name: str, version: str) -> tuple[str,str,str,str]:
    if meta.get("name") != name or meta.get("version") != version: raise RuntimeError("npm package identity/version mismatch")
    repo=meta.get("repository")
    if not isinstance(repo, Mapping) or repo.get("url") != _REPO: raise RuntimeError("npm repository metadata is not exact")
    d=meta.get("dist")
    if not isinstance(d,Mapping) or d.get("tarball") != _tarball(name,version): raise RuntimeError("npm tarball URL is not exact")
    integrity=_integrity(d.get("integrity")); count=d.get("fileCount"); unpacked=d.get("unpackedSize")
    if not isinstance(count,int) or isinstance(count,bool) or count <= 0 or count > MEMBER_LIMIT: raise RuntimeError("Invalid npm fileCount")
    if not isinstance(unpacked,int) or isinstance(unpacked,bool) or unpacked <= 0 or unpacked > UNPACKED_LIMIT: raise RuntimeError("Invalid npm unpackedSize")
    return d["tarball"], integrity, str(count), str(unpacked)

def _manifest(m: Mapping[str,Any]) -> tuple[str,str,str]:
    v=m.get("version"); a=m.get("architecture"); x=a.get("64bit") if isinstance(a,Mapping) else None
    u=x.get("url") if isinstance(x,Mapping) else None; h=x.get("hash") if isinstance(x,Mapping) else None
    if not isinstance(v,str) or not _VERSION.fullmatch(v): raise RuntimeError("Invalid Scoop OpenCode v2 version")
    expected=_tarball(WINDOWS_PACKAGE,v)
    if u != expected or not _url(u): raise RuntimeError("Scoop Windows URL is not exact")
    if not isinstance(h,str) or not h.startswith("sha512:") or not _HEX.fullmatch(h[7:]): raise RuntimeError("Invalid Scoop Windows SHA512")
    return v,u,h[7:].lower()

def _platform_metadata(meta: Mapping[str,Any], package: str) -> None:
    if package == LINUX_PACKAGE:
        if "os" in meta and meta["os"] != ["linux"]: raise RuntimeError("Linux npm metadata os is not exact")
        if "cpu" in meta and meta["cpu"] != ["x64"]: raise RuntimeError("Linux npm metadata cpu is not exact")

def resolve_release(architecture: str) -> dict[str,str]:
    if architecture != "x86_64": raise RuntimeError("OpenCode v2 supports x86_64 only")
    version, win_url, win_sha = _manifest(_json(SCOOP_MANIFEST_URL))
    wrapper=_json(_pkg_url(PACKAGE,version)); wtar,wint,wcount,wsize=_meta_fields(wrapper,PACKAGE,version)
    if wrapper.get("repository",{}).get("url") != _REPO if isinstance(wrapper.get("repository"),Mapping) else True: raise RuntimeError("npm wrapper repository metadata missing")
    opt=wrapper.get("optionalDependencies")
    if not isinstance(opt,Mapping) or opt.get(WINDOWS_PACKAGE)!=version or opt.get(LINUX_PACKAGE)!=version: raise RuntimeError("npm wrapper optional dependencies are not exact")
    win=_json(_pkg_url(WINDOWS_PACKAGE,version)); _,win_int,win_count,win_size=_meta_fields(win,WINDOWS_PACKAGE,version)
    if _digest(win_int) != win_sha: raise RuntimeError("Scoop Windows SHA512 disagrees with npm integrity")
    linux=_json(_pkg_url(LINUX_PACKAGE,version)); linux_url,linux_int,linux_count,linux_size=_meta_fields(linux,LINUX_PACKAGE,version); _platform_metadata(linux, LINUX_PACKAGE)
    return _validate_release({"version":version,"url":linux_url,"integrity":linux_int,"sha512":_digest(linux_int),"unpacked_size":linux_size,"file_count":linux_count,"asset_name":f"cli-linux-x64-baseline-{version}.tgz","manifest_source":SCOOP_MANIFEST_URL,"wrapper_source":_pkg_url(PACKAGE,version),"windows_source":_pkg_url(WINDOWS_PACKAGE,version),"linux_source":_pkg_url(LINUX_PACKAGE,version),"windows_url":win_url,"windows_integrity":win_int,"windows_sha512":win_sha,"wrapper_tarball":wtar,"wrapper_integrity":wint,"wrapper_file_count":wcount,"wrapper_unpacked_size":wsize,"windows_file_count":win_count,"windows_unpacked_size":win_size,"linux_file_count":linux_count,"linux_unpacked_size":linux_size,"repository":_REPO,"compatibility":"Linux x86_64 ELF64 baseline binary; requires glibc (runtime not tested)."})

def _validate_release(r: Mapping[str,Any]) -> dict[str,str]:
    required={"version","url","integrity","sha512","unpacked_size","file_count","asset_name","manifest_source","wrapper_source","windows_source","linux_source","windows_url","windows_integrity","windows_sha512","wrapper_tarball","wrapper_integrity","wrapper_file_count","wrapper_unpacked_size","windows_file_count","windows_unpacked_size","linux_file_count","linux_unpacked_size","repository","compatibility"}
    if not isinstance(r,Mapping) or set(r)!=required or any(not isinstance(r[k],str) or not r[k] for k in required): raise ValueError("Invalid OpenCode release metadata")
    v=r["version"]
    if not _VERSION.fullmatch(v): raise ValueError("Invalid OpenCode version")
    if r["url"]!=_tarball(LINUX_PACKAGE,v) or not _url(r["url"]): raise ValueError("Linux npm URL is not exact")
    if r["windows_url"]!=_tarball(WINDOWS_PACKAGE,v) or not _url(r["windows_url"]): raise ValueError("Windows npm URL is not exact")
    if r["wrapper_tarball"]!=_tarball(PACKAGE,v) or not _url(r["wrapper_tarball"]): raise ValueError("Wrapper tarball URL is not exact")
    if r["asset_name"] != f"cli-linux-x64-baseline-{v}.tgz": raise ValueError("Invalid Linux asset name")
    if r["manifest_source"]!=SCOOP_MANIFEST_URL or r["wrapper_source"]!=_pkg_url(PACKAGE,v) or r["windows_source"]!=_pkg_url(WINDOWS_PACKAGE,v) or r["linux_source"]!=_pkg_url(LINUX_PACKAGE,v): raise ValueError("Invalid OpenCode provenance")
    for k in ("integrity","windows_integrity","wrapper_integrity"): _integrity(r[k])
    for k in ("sha512","windows_sha512"):
        if not _HEX.fullmatch(r[k]): raise ValueError("Invalid SHA512")
    if r["sha512"] != _digest(r["integrity"]) or r["windows_sha512"] != _digest(r["windows_integrity"]): raise ValueError("Integrity digest mismatch")
    for k in ("unpacked_size","file_count","wrapper_file_count","wrapper_unpacked_size","windows_file_count","windows_unpacked_size","linux_file_count","linux_unpacked_size"):
        if not r[k].isdigit() or int(r[k])<=0: raise ValueError("Invalid npm package size metadata")
    for k in ("file_count","wrapper_file_count","windows_file_count","linux_file_count"):
        if int(r[k])>MEMBER_LIMIT: raise ValueError("Package fileCount exceeds limit")
    for k in ("unpacked_size","wrapper_unpacked_size","windows_unpacked_size","linux_unpacked_size"):
        if int(r[k])>UNPACKED_LIMIT: raise ValueError("Package unpackedSize exceeds limit")
    if r["unpacked_size"] != r["linux_unpacked_size"] or r["file_count"] != r["linux_file_count"]: raise ValueError("Linux metadata aliases disagree")
    if r["repository"] != _REPO: raise ValueError("Invalid repository metadata")
    return dict(r)

def _cpu_compatible():
    if platform.system()!="Linux" or platform.machine().lower() not in {"x86_64","amd64"} or platform.libc_ver()[0].lower()!="glibc": raise RuntimeError("OpenCode baseline requires Linux x86_64 with glibc")
    try: glibc=tuple(int(x) for x in platform.libc_ver()[1].split('.')[:2])
    except (ValueError,TypeError): raise RuntimeError("Unable to determine glibc version") from None
    if glibc < (2,17): raise RuntimeError("OpenCode baseline requires glibc >= 2.17")

def validate_install(release: Mapping[str,Any], destination: Path) -> None:
    _validate_release(release); _cpu_compatible(); _bw._safe_destination(Path(destination))
    if getattr(_bw.ctypes.CDLL(None),"renameat2",None) is None: raise RuntimeError("Linux renameat2 is required for race-safe publication")

class _CapReader:
    def __init__(self, raw, cap): self.raw,self.cap,self.total=raw,cap,0
    def read(self,n=-1):
        if n < 0: n=self.cap-self.total+1
        b=self.raw.read(min(n,self.cap-self.total+1)); self.total += len(b)
        if self.total > self.cap: raise ValueError("OpenCode archive decompressed data exceeds limit")
        return b
    def close(self): return self.raw.close()

def _extract_members(archive: Path, stage: Path, release: Mapping[str,str]) -> None:
    total=0; count=0; seen=set(); package_data=None
    with archive.open("rb") as raw, gzip.GzipFile(fileobj=raw, mode="rb") as gz, tarfile.open(fileobj=_CapReader(gz, UNPACKED_LIMIT), mode="r|") as tar:
        for m in tar:
            count += 1
            if count > MEMBER_LIMIT: raise ValueError("OpenCode archive has too many members")
            if m.name not in {"package/package.json","package/bin/opencode"} or m.name in seen or not m.isreg() or m.size<=0 or m.size>UNPACKED_LIMIT: raise ValueError("Unsafe OpenCode archive layout")
            seen.add(m.name); total += m.size
            if total > int(release["linux_unpacked_size"]): raise ValueError("OpenCode archive exceeds npm unpackedSize")
            src=tar.extractfile(m)
            if src is None: raise RuntimeError("Truncated OpenCode member")
            data=src.read(PACKAGE_JSON_LIMIT+1) if m.name.endswith("package.json") else None
            if m.name.endswith("package.json"):
                if m.size > PACKAGE_JSON_LIMIT or len(data) != m.size: raise ValueError("package.json exceeds limit")
                package_data=data
            else:
                target=stage/"bin"/"opencode"; target.parent.mkdir(parents=True,exist_ok=True)
                with target.open("wb") as out:
                    remaining = m.size
                    while remaining:
                        chunk = src.read(min(1024 * 1024, remaining))
                        if not chunk:
                            raise ValueError("Truncated OpenCode binary member")
                        out.write(chunk)
                        remaining -= len(chunk)
        if seen != {"package/package.json","package/bin/opencode"} or count != 2 or total != int(release["linux_unpacked_size"]): raise ValueError("OpenCode archive metadata/layout mismatch")
    if package_data is None: raise ValueError("Missing package.json")
    try: meta=json.loads(package_data.decode("utf-8"))
    except (UnicodeDecodeError,json.JSONDecodeError,TypeError) as e: raise ValueError("Invalid package.json") from e
    if not isinstance(meta,Mapping) or meta.get("name") != LINUX_PACKAGE or meta.get("version") != release["version"]: raise ValueError("package identity mismatch")

def _elf(path: Path):
    with path.open("rb") as f: data=f.read(64)
    if len(data)<64 or data[:4]!=b"\x7fELF" or data[4:7]!=bytes((2,1,1)) or int.from_bytes(data[18:20],"little")!=62 or int.from_bytes(data[20:24],"little")!=1: raise ValueError("OpenCode binary is not ELF64 x86_64")

def install_release(release: Mapping[str,Any], destination: Path) -> None:
    v=_validate_release(release); validate_install(v,destination); destination=Path(os.path.normpath(str(Path(destination).expanduser())))
    parent_fd,_=_bw._open_destination_parent(destination); stage=None
    try:
        stage=Path(tempfile.mkdtemp(prefix=".opencode2-",dir=f"/proc/self/fd/{parent_fd}")); os.chmod(stage,0o700)
        with tempfile.TemporaryDirectory(prefix=".opencode2-download-",dir=f"/proc/self/fd/{parent_fd}") as td:
            archive=Path(td)/"opencode.tgz"; digest=hashlib.sha512(); total=0; r=_open(v["url"],limit=DOWNLOAD_LIMIT)
            try:
                with archive.open("wb") as out:
                    while True:
                        b=r.read(min(1024*1024,DOWNLOAD_LIMIT-total+1))
                        if not b: break
                        total+=len(b)
                        if total>DOWNLOAD_LIMIT: raise RuntimeError("OpenCode download exceeds limit")
                        digest.update(b); out.write(b)
            finally: r.close()
            if digest.hexdigest()!=v["sha512"]: raise RuntimeError("OpenCode download SHA512 mismatch")
            _extract_members(archive, stage, v)
            binary=stage/"bin"/"opencode"; _elf(binary); os.chmod(binary,0o755)
            canonical = stage / "opencode"; os.replace(binary, canonical); (stage/"opencode2").hardlink_to(canonical)
            _bw._publish_noreplace(stage,destination,parent_fd=parent_fd); stage=None
    finally:
        if stage is not None: shutil.rmtree(stage,ignore_errors=True)
        os.close(parent_fd)
