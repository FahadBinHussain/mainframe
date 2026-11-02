#!/usr/bin/env python3
"""Metadata-only PowerShell Linux candidate review; no archive fetcher or installer."""
from __future__ import annotations

import ctypes
import hashlib
import http.client
import json
import os
import platform
import re
import shutil
import stat
import subprocess
import tarfile
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Mapping

SCOOP_MANIFEST = "https://raw.githubusercontent.com/ScoopInstaller/Main/master/bucket/pwsh.json"
RELEASE_API_PREFIX = "https://api.github.com/repos/PowerShell/PowerShell/releases/tags/v"
RELEASE_DOWNLOAD_PREFIX = "https://github.com/PowerShell/PowerShell/releases/download/v"
SCOOP_LIMIT = 1024 * 1024
RELEASE_LIMIT = 2 * 1024 * 1024
TIMEOUT = 20
VERSION = re.compile(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\Z")
SHA256 = re.compile(r"[0-9a-fA-F]{64}\Z")


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise RuntimeError("Official PowerShell metadata redirect refused")


def _release_api_url(version: str) -> str:
    if not isinstance(version, str) or not VERSION.fullmatch(version):
        raise ValueError("Invalid PowerShell release version")
    return RELEASE_API_PREFIX + version


def _fetch_metadata(url: str) -> bytes:
    """Read bounded bytes from only the fixed Scoop manifest or versioned GitHub API."""
    if not isinstance(url, str):
        raise ValueError("Refusing non-metadata PowerShell URL")
    if url == SCOOP_MANIFEST:
        limit = SCOOP_LIMIT
    elif re.fullmatch(re.escape(RELEASE_API_PREFIX) + r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)", url):
        limit = RELEASE_LIMIT
    else:
        raise ValueError("Refusing non-metadata PowerShell URL")
    request = urllib.request.Request(
        url,
        headers={
            "User-Agent": "mainframe-pwsh-metadata/1.0",
            "Accept": "application/vnd.github+json, application/json",
        },
    )
    try:
        response = urllib.request.build_opener(_NoRedirect()).open(request, timeout=TIMEOUT)
    except RuntimeError:
        raise
    except (urllib.error.URLError, http.client.HTTPException, OSError, ValueError):
        raise RuntimeError("Official PowerShell metadata request failed") from None
    with response:
        if response.geturl() != url:
            raise RuntimeError("Official PowerShell metadata source changed")
        length = response.headers.get("Content-Length")
        if length is not None:
            try:
                parsed_length = int(length)
            except (TypeError, ValueError):
                raise RuntimeError("Official PowerShell metadata has invalid size") from None
            if parsed_length < 0 or parsed_length > limit:
                raise RuntimeError("Official PowerShell metadata exceeds its size limit")
        chunks: list[bytes] = []
        total = 0
        while True:
            try:
                chunk = response.read(min(65536, limit - total + 1))
            except (urllib.error.URLError, http.client.HTTPException, OSError, ValueError):
                raise RuntimeError("Official PowerShell metadata request failed") from None
            if not chunk:
                break
            total += len(chunk)
            if total > limit:
                raise RuntimeError("Official PowerShell metadata exceeds its size limit")
            chunks.append(chunk)
        return b"".join(chunks)

def _unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("Duplicate JSON key")
        result[key] = value
    return result


def _json_object(raw: bytes, label: str) -> Mapping[str, Any]:
    try:
        value = json.loads(raw.decode("utf-8"), object_pairs_hook=_unique_object)
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError, RecursionError):
        raise ValueError(f"Invalid official PowerShell {label} metadata") from None
    if not isinstance(value, Mapping):
        raise ValueError(f"Invalid official PowerShell {label} metadata")
    return value


def _asset_url(version: str, filename: str) -> str:
    return f"{RELEASE_DOWNLOAD_PREFIX}{version}/{filename}"


def _manifest_metadata(raw: bytes) -> tuple[str, str, str]:
    manifest = _json_object(raw, "Scoop")
    version = manifest.get("version")
    architecture = manifest.get("architecture")
    win64 = architecture.get("64bit") if isinstance(architecture, Mapping) else None
    if not isinstance(version, str) or not VERSION.fullmatch(version) or not isinstance(win64, Mapping):
        raise ValueError("Scoop PowerShell manifest lacks an exact stable Windows x64 declaration")
    windows_name = f"PowerShell-{version}-win-x64.zip"
    windows_url, digest = win64.get("url"), win64.get("hash")
    if windows_url != _asset_url(version, windows_name) or not isinstance(digest, str) or not SHA256.fullmatch(digest):
        raise ValueError("Scoop PowerShell manifest lacks a valid Windows x64 URL or SHA-256")
    return version, windows_url, digest.lower()


def _published_sha256(body: str, asset_name: str) -> str:
    pattern = re.compile(
        rf"(?m)^-[ \t]+{re.escape(asset_name)}[ \t]*\r?\n[ \t]*-[ \t]+([^\r\n]+)[ \t]*$"
    )
    matches = pattern.findall(body)
    if len(matches) != 1:
        raise ValueError("PowerShell release checksum metadata is missing or ambiguous")
    digest = matches[0].strip()
    if not SHA256.fullmatch(digest):
        raise ValueError("PowerShell release checksum metadata is invalid")
    return digest.lower()


def _release_asset(release: Mapping[str, Any], asset_name: str, expected_url: str) -> None:
    assets = release.get("assets")
    if not isinstance(assets, list):
        raise ValueError("PowerShell release asset metadata is invalid")
    matches = [asset for asset in assets if isinstance(asset, Mapping) and asset.get("name") == asset_name]
    if len(matches) != 1 or matches[0].get("browser_download_url") != expected_url:
        raise ValueError("PowerShell release asset URL is missing, duplicated, or unexpected")


def _release_metadata(raw: bytes, version: str) -> dict[str, str]:
    release = _json_object(raw, "GitHub release")
    if (release.get("tag_name") != f"v{version}" or release.get("draft") is not False or
            release.get("prerelease") is not False):
        raise ValueError("PowerShell GitHub release tag or stable-release status does not match Scoop")
    body = release.get("body")
    if not isinstance(body, str):
        raise ValueError("PowerShell release checksum metadata is missing")
    windows_name = f"PowerShell-{version}-win-x64.zip"
    linux_name = f"powershell-{version}-linux-x64.tar.gz"
    windows_url = _asset_url(version, windows_name)
    linux_url = _asset_url(version, linux_name)
    _release_asset(release, windows_name, windows_url)
    _release_asset(release, linux_name, linux_url)
    return {
        "tag": f"v{version}",
        "windows_url": windows_url,
        "windows_sha256": _published_sha256(body, windows_name),
        "linux_url": linux_url,
        "linux_sha256": _published_sha256(body, linux_name),
    }


def build_dry_plan(architecture: str) -> dict[str, Any]:
    """Match public release metadata only; never fetch an archive or execute scripts."""
    if architecture != "x86_64":
        raise ValueError("PowerShell metadata review is limited to Linux x86_64")
    version, windows_url, windows_sha = _manifest_metadata(_fetch_metadata(SCOOP_MANIFEST))
    release_url = _release_api_url(version)
    release = _release_metadata(_fetch_metadata(release_url), version)
    if release["windows_url"] != windows_url or release["windows_sha256"] != windows_sha:
        raise ValueError("Scoop Windows x64 checksum does not match the official PowerShell release")
    return {
        "status": "metadata-only-blocked",
        "package": {"name": "pwsh", "version": version, "version_is_restore_pin": False},
        "scoop_observation": {"url": windows_url, "sha256": windows_sha},
        "release": {"tag": release["tag"], "metadata_url": release_url},
        "linux_archive_candidate": {
            "name": f"powershell-{version}-linux-x64.tar.gz",
            "url": release["linux_url"],
            "sha256": release["linux_sha256"],
        },
        "metadata_sources": [SCOOP_MANIFEST, release_url],
        "scripts_or_archives_executed": False,
        "package_archive_downloaded": False,
        "manifest_script_fields_used": False,
        "windows_profiles_or_modules_read": False,
        "executable": False,
        "proposed_command": [],
        "execution_blockers": [
            "The observed Scoop version is not a user-selected restore pin.",
            "The Linux archive bytes and member/layout contract have not been inspected.",
            "PowerShell and .NET runtime dependencies vary by distribution and remain unvalidated.",
            "No isolated install destination or activation contract is approved.",
            "Windows profiles and modules are separate state and are not imported.",
        ],
    }


# ---------------------------------------------------------------- installer
#
# The metadata plan above is read-only.  The installer below is the same
# shape as bitwarden_cli_linux: the archive is bounded, pinned to two
# independently published digests, extracted into an isolated staging tree
# that refuses links and traversal, and published atomically into a
# destination that must not exist yet.  It never touches PATH, profiles, or
# credentials.

DOWNLOAD_LIMIT = 256 * 1024 * 1024
ARCHIVE_MEMBER_LIMIT = 4096
EXTRACTED_LIMIT = 512 * 1024 * 1024
DOWNLOAD_TIMEOUT = 300
RUNTIME_TIMEOUT = 120
# .NET (the runtime PowerShell embeds) needs glibc 2.28 or newer; the exact
# floor is enforced by running the binary after install.
MIN_GLIBC = (2, 28)
INSTALLER_USER_AGENT = "mainframe-native-shells/1.0 (PowerShell Linux installer)"
_VERSION_BODY = r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)"
_ARCHIVE_PATH = re.compile(r"/PowerShell/PowerShell/releases/download/v" + _VERSION_BODY + r"/[A-Za-z0-9._-]+")
_ASSET_PATH = re.compile(r"/github-production-release-asset/[0-9]+/[A-Za-z0-9._-]+")
_HEX64 = re.compile(r"[0-9a-f]{64}")
_NOFOLLOW = getattr(os, "O_NOFOLLOW", 0)


class _ArchiveRedirects(urllib.request.HTTPRedirectHandler):
    """Allow only the official github.com -> release-assets host redirect."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        target = urllib.parse.urlsplit(newurl)
        if not (target.scheme == "https" and target.netloc == "release-assets.githubusercontent.com" and
                target.port is None and not target.username and not target.password and
                bool(target.query) and not target.fragment and
                _ASSET_PATH.fullmatch(target.path) is not None):
            raise RuntimeError("Refusing non-official PowerShell archive redirect")
        source = urllib.parse.urlsplit(req.full_url)
        if source.netloc != "github.com":
            raise RuntimeError("Refusing non-official PowerShell archive redirect")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def _official_archive_url(url: str) -> bool:
    try:
        p = urllib.parse.urlsplit(url)
        port = p.port
    except (TypeError, ValueError):
        return False
    return (p.scheme == "https" and p.netloc == "github.com" and port is None and
            not p.username and not p.password and not p.query and not p.fragment and
            _ARCHIVE_PATH.fullmatch(p.path) is not None)


def _release_asset_entry(release: Mapping[str, Any], name: str) -> Mapping[str, Any]:
    assets = release.get("assets")
    if not isinstance(assets, list):
        raise ValueError("PowerShell release has no asset list")
    matches = [a for a in assets if isinstance(a, Mapping) and a.get("name") == name]
    if len(matches) != 1:
        raise ValueError(f"PowerShell release asset is missing or ambiguous: {name}")
    return matches[0]


def resolve_release(architecture: str) -> dict[str, str]:
    """Pin the Linux x64 archive to the Windows version and two published digests."""
    if architecture != "x86_64":
        raise RuntimeError(f"Unsupported architecture: {architecture}")
    version, windows_url, windows_sha = _manifest_metadata(_fetch_metadata(SCOOP_MANIFEST))
    release_url = _release_api_url(version)
    release = _json_object(_fetch_metadata(release_url), "GitHub release")
    if (release.get("tag_name") != f"v{version}" or release.get("draft") is not False or
            release.get("prerelease") is not False):
        raise ValueError("PowerShell GitHub release tag or stable-release status does not match Scoop")
    linux_name = f"powershell-{version}-linux-x64.tar.gz"
    asset = _release_asset_entry(release, linux_name)
    url, size, digest = asset.get("browser_download_url"), asset.get("size"), asset.get("digest")
    if not isinstance(url, str) or not _official_archive_url(url):
        raise ValueError("PowerShell Linux archive URL is not official")
    if not isinstance(size, int) or size <= 0 or size > DOWNLOAD_LIMIT:
        raise ValueError("PowerShell Linux archive has an invalid size")
    if not isinstance(digest, str) or not digest.startswith("sha256:") or not _HEX64.fullmatch(digest[7:]):
        raise ValueError("PowerShell Linux archive is missing a required SHA256 digest")
    body = release.get("body")
    if not isinstance(body, str):
        raise ValueError("PowerShell release checksum metadata is missing")
    if _published_sha256(body, linux_name) != digest[7:].lower():
        raise ValueError("PowerShell Linux archive digests disagree between the release asset and the release notes")
    if _published_sha256(body, f"PowerShell-{version}-win-x64.zip") != windows_sha:
        raise ValueError("PowerShell Windows checksum does not match the official release")
    return {
        "version": version,
        "url": url,
        "sha256": digest[7:].lower(),
        "size": str(size),
        "asset_name": linux_name,
        "manifest_source": SCOOP_MANIFEST,
        "release_source": release_url,
        "windows_url": windows_url,
        "windows_sha256": windows_sha,
    }


def _validate_release(release: Mapping[str, Any]) -> dict[str, str]:
    required = {"version", "url", "sha256", "size", "asset_name", "manifest_source", "release_source",
                "windows_url", "windows_sha256"}
    if (not isinstance(release, Mapping) or set(release) != required or
            any(not isinstance(release[k], str) or not release[k] for k in required)):
        raise ValueError("Invalid PowerShell release metadata")
    version = release["version"]
    if not VERSION.fullmatch(version) or release["asset_name"] != f"powershell-{version}-linux-x64.tar.gz":
        raise ValueError("Invalid PowerShell release version or asset")
    if not _official_archive_url(release["url"]):
        raise ValueError("PowerShell download URL is not official")
    if urllib.parse.urlsplit(release["url"]).path != f"/PowerShell/PowerShell/releases/download/v{version}/{release['asset_name']}":
        raise ValueError("PowerShell download path is not exact")
    if release["manifest_source"] != SCOOP_MANIFEST or release["release_source"] != RELEASE_API_PREFIX + version:
        raise ValueError("Invalid PowerShell provenance")
    if not _HEX64.fullmatch(release["sha256"]) or not _HEX64.fullmatch(release["windows_sha256"]):
        raise ValueError("Invalid PowerShell SHA256")
    try:
        size = int(release["size"])
    except ValueError:
        raise ValueError("Invalid PowerShell size") from None
    if size <= 0 or size > DOWNLOAD_LIMIT or str(size) != release["size"]:
        raise ValueError("Invalid PowerShell size")
    return dict(release)


def _check_ancestor(st: os.stat_result) -> None:
    """Reject ancestors that are not directories owned by root or this user."""
    if (not stat.S_ISDIR(st.st_mode) or st.st_uid not in {0, os.geteuid()} or
            (st.st_mode & 0o022 and not (st.st_mode & stat.S_ISVTX))):
        raise ValueError("Unsafe PowerShell install root ancestor")


def _open_destination_parent(destination: Path, *, require_new: bool = True) -> tuple[int, str]:
    """Open and validate every destination ancestor using descriptor-relative traversal."""
    destination = Path(os.path.normpath(str(destination.expanduser())))
    if not destination.is_absolute() or destination == Path("/"):
        raise ValueError("PowerShell install root must be an explicit absolute directory")
    parts = destination.parts
    fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        _check_ancestor(os.fstat(fd))
        for component in parts[1:-1]:
            if component in {"", ".", ".."}:
                raise ValueError("Unsafe PowerShell install root ancestor")
            child = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=fd)
            os.close(fd)
            fd = child
            _check_ancestor(os.fstat(fd))
        name = parts[-1]
        if not name or name in {".", ".."}:
            raise ValueError("Invalid PowerShell install root")
        if require_new:
            try:
                os.stat(name, dir_fd=fd, follow_symlinks=False)
            except FileNotFoundError:
                pass
            else:
                raise ValueError("Refusing existing or symlink PowerShell install root")
        return fd, name
    except Exception:
        os.close(fd)
        raise


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
        if renameat2 is None:
            raise RuntimeError("Linux renameat2 is required for race-safe publication")
        renameat2.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
        renameat2.restype = ctypes.c_int
        result = renameat2(parent_fd, os.fsencode(stage_name), parent_fd, os.fsencode(destination_name), 1)
        if result != 0:
            err = ctypes.get_errno()
            if err == 17:
                raise RuntimeError("Refusing destination created concurrently")
            raise OSError(err, os.strerror(err), destination)
    finally:
        if owned_fd is not None:
            os.close(owned_fd)


def _member_parts(name: str) -> list[str]:
    """Split a tar member name into safe path components."""
    if not isinstance(name, str) or not name:
        raise ValueError("PowerShell archive member has no name")
    if "\\" in name or name.startswith("/"):
        raise ValueError("Unsafe PowerShell archive member name")
    trimmed = name[:-1] if name.endswith("/") else name
    parts = trimmed.split("/")
    if not parts or any(part in {"", ".", ".."} for part in parts):
        raise ValueError("Unsafe PowerShell archive member name")
    return parts


def _extract_archive(archive: Path, stage: Path) -> None:
    """Extract the archive into a fresh staging tree, refusing links and traversal."""
    total = 0
    seen: set[str] = set()
    with tarfile.open(archive, "r:gz") as tf:
        members = tf.getmembers()
        if len(members) > ARCHIVE_MEMBER_LIMIT:
            raise ValueError("PowerShell archive has too many members")
        for member in members:
            parts = _member_parts(member.name)
            key = "/".join(parts)
            if key in seen:
                raise ValueError("PowerShell archive repeats a member path")
            seen.add(key)
            if member.issym() or member.islnk():
                raise ValueError("PowerShell archive member must not be a link")
            target = stage.joinpath(*parts)
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
                continue
            if not member.isreg():
                raise ValueError("PowerShell archive member must be a regular file or directory")
            total += member.size
            if total > EXTRACTED_LIMIT:
                raise ValueError("PowerShell archive expands beyond the extraction limit")
            target.parent.mkdir(parents=True, exist_ok=True)
            source = tf.extractfile(member)
            if source is None:
                raise ValueError("PowerShell archive member has no readable content")
            mode = 0o755 if member.mode & 0o111 else 0o644
            fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL | _NOFOLLOW, 0o600)
            try:
                os.fchmod(fd, mode)
                with os.fdopen(fd, "wb") as out:
                    fd = None
                    shutil.copyfileobj(source, out, 1 << 20)
            finally:
                if fd is not None:
                    os.close(fd)
            source.close()


def _check_elf(path: Path) -> None:
    """Refuse anything that is not a complete x86_64 ELF64 executable."""
    with path.open("rb") as handle:
        header = handle.read(64)
    if (len(header) < 64 or header[:4] != b"\x7fELF" or header[4] != 2 or header[5] != 1 or
            header[6] != 1 or int.from_bytes(header[16:18], "little") not in {2, 3} or
            int.from_bytes(header[18:20], "little") != 62 or int.from_bytes(header[20:24], "little") != 1 or
            int.from_bytes(header[52:54], "little") != 64):
        raise RuntimeError("PowerShell binary is not a complete x86_64 ELF64 executable")


def _require_linux_x86_64() -> None:
    if platform.system() != "Linux" or platform.machine().lower() not in {"x86_64", "amd64"}:
        raise RuntimeError("PowerShell requires Linux x86_64")
    libc, version = platform.libc_ver()
    if libc.lower() != "glibc":
        raise RuntimeError("PowerShell requires a glibc Linux host")
    parts = version.split(".")
    try:
        current = (int(parts[0]), int(parts[1]))
    except (IndexError, ValueError):
        raise RuntimeError(f"Cannot determine the host glibc version: {version!r}") from None
    if current < MIN_GLIBC:
        raise RuntimeError(f"PowerShell requires glibc >= {MIN_GLIBC[0]}.{MIN_GLIBC[1]}; this host has {version}")


def _download_archive(url: str, destination: Path) -> tuple[int, str]:
    """Download the official archive with a hard byte ceiling; return (size, sha256)."""
    if not _official_archive_url(url):
        raise RuntimeError(f"Refusing non-official PowerShell archive URL: {url!r}")
    request = urllib.request.Request(url, headers={"User-Agent": INSTALLER_USER_AGENT,
                                                   "Accept": "application/octet-stream"})
    try:
        response = urllib.request.build_opener(_ArchiveRedirects()).open(request, timeout=DOWNLOAD_TIMEOUT)
    except (urllib.error.URLError, OSError) as exc:
        raise RuntimeError(f"Official PowerShell archive download failed: {exc}") from exc
    digest = hashlib.sha256()
    total = 0
    try:
        length = response.headers.get("Content-Length")
        if length is not None:
            try:
                declared = int(length)
            except ValueError:
                raise RuntimeError("Invalid PowerShell archive Content-Length") from None
            if declared < 0 or declared > DOWNLOAD_LIMIT:
                raise RuntimeError("PowerShell archive exceeds the download limit")
        with destination.open("wb") as out:
            while True:
                chunk = response.read(min(1 << 20, DOWNLOAD_LIMIT - total + 1))
                if not chunk:
                    break
                total += len(chunk)
                if total > DOWNLOAD_LIMIT:
                    raise RuntimeError("PowerShell archive exceeds the download limit")
                digest.update(chunk)
                out.write(chunk)
    except RuntimeError:
        raise
    except Exception as exc:
        raise RuntimeError(f"Official PowerShell archive download failed: {exc}") from exc
    finally:
        response.close()
    return total, digest.hexdigest()


def is_installed(destination: Path) -> bool:
    """True when a usable pwsh is already published at the destination."""
    return (Path(destination) / "pwsh").is_file()


def runtime_check(destination: Path, *, env: Mapping[str, str] | None = None) -> str:
    """Start the installed pwsh once and return its version; fail loudly if it cannot start."""
    executable = Path(destination) / "pwsh"
    if not executable.is_file():
        raise RuntimeError(f"PowerShell is not installed at {executable}")
    try:
        completed = subprocess.run(
            [str(executable), "-NoLogo", "-NoProfile", "-NonInteractive", "-Command",
             "$PSVersionTable.PSVersion.ToString()"],
            capture_output=True, text=True, timeout=RUNTIME_TIMEOUT, env=env)
    except (OSError, subprocess.SubprocessError) as exc:
        raise RuntimeError(f"PowerShell could not be started: {exc}") from exc
    if completed.returncode != 0:
        detail = (completed.stderr or completed.stdout or "").strip()[:400]
        raise RuntimeError(f"PowerShell could not be started: {detail or f'exit {completed.returncode}'}")
    version = (completed.stdout or "").strip()
    if not version:
        raise RuntimeError("PowerShell started but reported no version")
    return version


def install_release(release: Mapping[str, Any], destination: Path) -> dict[str, str]:
    """Download, verify, extract and atomically publish the official PowerShell tree."""
    validated = _validate_release(release)
    _require_linux_x86_64()
    if getattr(ctypes.CDLL(None), "renameat2", None) is None:
        raise RuntimeError("Linux renameat2 is required for race-safe publication")
    destination = Path(os.path.normpath(str(Path(destination).expanduser())))
    parent_fd, _name = _open_destination_parent(destination)
    stage_path = None
    try:
        stage_path = Path(tempfile.mkdtemp(prefix=".pwsh-install-", dir=f"/proc/self/fd/{parent_fd}"))
        os.chmod(stage_path, 0o700)
        with tempfile.TemporaryDirectory(prefix=".pwsh-download-", dir=f"/proc/self/fd/{parent_fd}") as scratch:
            archive = Path(scratch) / "pwsh.tar.gz"
            size, digest = _download_archive(validated["url"], archive)
            if size != int(validated["size"]):
                raise RuntimeError("PowerShell archive download size mismatch")
            if digest != validated["sha256"]:
                raise RuntimeError("PowerShell archive SHA256 mismatch")
            _extract_archive(archive, stage_path)
        executable = stage_path / "pwsh"
        if not executable.is_file():
            raise RuntimeError("PowerShell archive does not contain a pwsh executable")
        _check_elf(executable)
        _publish_noreplace(stage_path, destination, parent_fd=parent_fd)
        stage_path = None
    finally:
        if stage_path is not None:
            shutil.rmtree(stage_path, ignore_errors=True)
        os.close(parent_fd)
    return {"version": validated["version"], "sha256": validated["sha256"],
            "path": str(destination), "pwsh_version": runtime_check(destination)}
