"""Resolve and install Google's Android SDK command-line tools, conservatively.

The resolver uses only public metadata.  Installation requires an explicit terms
attestation and a new, explicit SDK root; it never runs SDK programs.
"""
from __future__ import annotations

import hashlib
from html.parser import HTMLParser
import io
import json
import os
from pathlib import Path
import re
import shutil
import tempfile
from typing import Any, BinaryIO
from urllib.parse import urlparse
from urllib.request import Request, urlopen
import zipfile

MANIFEST_SOURCE = "https://raw.githubusercontent.com/ScoopInstaller/Main/master/bucket/android-clt.json"
METADATA_SOURCE = "https://developer.android.com/studio"
TERMS_URL = "https://developer.android.com/studio/terms.html"
_OFFICIAL_HOST = "dl.google.com"
_MANIFEST_MAX = 256 * 1024
_METADATA_MAX = 4 * 1024 * 1024
_ARCHIVE_MAX = 1024 * 1024 * 1024
_EXTRACTED_MAX = 2 * 1024 * 1024 * 1024
_TIMEOUT = 30
_HEX64 = re.compile(r"^[0-9a-fA-F]{64}$")
_WIN_NAME = re.compile(r"^commandlinetools-win-(\d+)_latest\.zip$")
_LINUX_NAME = re.compile(r"^commandlinetools-linux-(\d+)_latest\.zip$")


def _open_url(url: str, *, timeout: int = _TIMEOUT):
    """Small patchable network seam; callers receive a urllib response."""
    return urlopen(Request(url, headers={"User-Agent": "mainframe-android-tools/1"}), timeout=timeout)


def _read_response(response: Any, limit: int) -> bytes:
    data = bytearray()
    while len(data) <= limit:
        chunk = response.read(min(65536, limit + 1 - len(data)))
        if not chunk:
            return bytes(data)
        data.extend(chunk)
    raise ValueError("metadata response exceeds safe size limit")


def _fetch(url: str, limit: int) -> bytes:
    with _open_url(url, timeout=_TIMEOUT) as response:
        return _read_response(response, limit)


def _official_archive(url: str, kind: str, version: str | None = None) -> bool:
    parsed = urlparse(url)
    if (parsed.scheme != "https" or parsed.hostname != _OFFICIAL_HOST or
            parsed.username is not None or parsed.password is not None or
            parsed.port is not None or parsed.query or parsed.fragment):
        return False
    filename = Path(parsed.path).name
    match = (_WIN_NAME if kind == "windows" else _LINUX_NAME).fullmatch(filename)
    return bool(match and (version is None or match.group(1) == version) and
                parsed.path == "/android/repository/" + filename)


class _DownloadTableParser(HTMLParser):
    """Extract table rows and matching terms-modal download links."""
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.rows: list[dict[str, Any]] = []
        self._row: list[str] | None = None
        self._cell: list[str] | None = None
        self._button: tuple[str, list[str]] | None = None
        self._row_buttons: list[tuple[str, str]] = []
        self.modals: dict[str, list[str]] = {}
        self._modal_stack: list[str | None] = []
        self._ignore = 0

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        tag = tag.lower()
        if tag in {"script", "style"}:
            self._ignore += 1
        if self._ignore:
            return
        values = dict(attrs)
        if tag == "tr":
            self._row, self._row_buttons = [], []
        elif tag in {"td", "th"} and self._row is not None:
            self._cell = []
        elif tag == "button" and self._row is not None and values.get("data-modal-dialog-id"):
            self._button = (values["data-modal-dialog-id"], [])
        elif tag == "div":
            current = self._modal_stack[-1] if self._modal_stack else None
            self._modal_stack.append(current or values.get("id"))
        elif tag == "a" and self._modal_stack and self._modal_stack[-1]:
            href = values.get("href")
            if href:
                self.modals.setdefault(self._modal_stack[-1], []).append(href)

    def handle_endtag(self, tag: str) -> None:
        tag = tag.lower()
        if tag in {"script", "style"}:
            self._ignore = max(0, self._ignore - 1)
            return
        if self._ignore:
            return
        if tag == "button" and self._button is not None:
            modal, text = self._button
            self._row_buttons.append((modal, " ".join("".join(text).split())))
            self._button = None
        elif tag in {"td", "th"} and self._row is not None and self._cell is not None:
            self._row.append(" ".join("".join(self._cell).split()))
            self._cell = None
        elif tag == "tr" and self._row is not None:
            self.rows.append({"cells": self._row, "buttons": self._row_buttons})
            self._row = None
        elif tag == "div" and self._modal_stack:
            self._modal_stack.pop()

    def handle_data(self, data: str) -> None:
        if self._ignore == 0 and self._cell is not None:
            self._cell.append(data)
        if self._button is not None:
            self._button[1].append(data)


def _validate_manifest(manifest: Any) -> tuple[str, str, str]:
    if not isinstance(manifest, dict):
        raise ValueError("Scoop manifest is not an object")
    version = manifest.get("version")
    win_url = manifest.get("url")
    checksum = manifest.get("hash")
    if not isinstance(version, str) or not re.fullmatch(r"\d+", version):
        raise ValueError("Scoop manifest has no valid version")
    if not isinstance(win_url, str) or not _official_archive(win_url, "windows", version):
        raise ValueError("Scoop manifest Windows URL is not an official matching archive")
    if not isinstance(checksum, str) or not _HEX64.fullmatch(checksum):
        raise ValueError("Scoop manifest must contain one valid 64-hex checksum")
    return version, win_url, checksum.lower()


def _linux_metadata(html_bytes: bytes, version: str) -> tuple[str, str]:
    parser = _DownloadTableParser()
    try:
        parser.feed(html_bytes.decode("utf-8", "strict"))
    except (UnicodeDecodeError, ValueError) as exc:
        raise ValueError("Android Studio metadata HTML is invalid") from exc
    candidates: list[tuple[str, str]] = []
    for row in parser.rows:
        joined = " ".join(row["cells"])
        name_match = re.search(r"(commandlinetools-linux-\d+_latest\.zip)", joined)
        if not name_match or _LINUX_NAME.fullmatch(name_match.group(1)).group(1) != version:
            continue
        hashes = [x.lower() for x in re.findall(r"(?<![0-9A-Fa-f])[0-9A-Fa-f]{64}(?![0-9A-Fa-f])", joined)]
        if len(hashes) != 1:
            raise ValueError("Linux metadata row has missing or ambiguous SHA-256 checksum")
        filename = name_match.group(0)
        if not _LINUX_NAME.fullmatch(filename):
            raise ValueError("Linux metadata contains an invalid archive filename")
        urls: list[str] = []
        for modal, button_text in row["buttons"]:
            if button_text == filename:
                urls.extend(parser.modals.get(modal, []))
        approved = [url for url in urls if _official_archive(url, "linux", version)]
        if len(urls) != 1 or len(approved) != 1 or Path(urlparse(approved[0]).path).name != filename:
            raise ValueError("Linux metadata row must contain exactly one matching official archive URL")
        candidates.append((approved[0], hashes[0]))
    if len(candidates) != 1:
        raise ValueError("Android Studio metadata has no unambiguous matching Linux archive")
    return candidates[0]


def resolve_release(architecture: str) -> dict[str, str]:
    """Resolve the current x86_64 Linux archive without downloading it."""
    if architecture != "x86_64":
        raise ValueError("Android command-line tools support only x86_64 here; refusing architecture %r" % architecture)
    manifest = json.loads(_fetch(MANIFEST_SOURCE, _MANIFEST_MAX).decode("utf-8"))
    version, _win_url, _win_checksum = _validate_manifest(manifest)
    linux_url, linux_checksum = _linux_metadata(_fetch(METADATA_SOURCE, _METADATA_MAX), version)
    return {
        "version": version,
        "url": linux_url,
        "sha256": linux_checksum,
        "manifest_source": MANIFEST_SOURCE,
        "checksum_source": METADATA_SOURCE,
        "terms_url": TERMS_URL,
    }


def _validate_release(release: Any) -> tuple[str, str, str]:
    if not isinstance(release, dict):
        raise ValueError("release must be a dictionary")
    required = ("version", "url", "sha256", "manifest_source", "checksum_source", "terms_url")
    if any(not isinstance(release.get(k), str) or not release[k] for k in required):
        raise ValueError("release is missing required string fields")
    version, url, checksum = release["version"], release["url"], release["sha256"]
    if not re.fullmatch(r"\d+", version) or not _official_archive(url, "linux", version):
        raise ValueError("release URL/version is not an official matching Linux archive")
    if not _HEX64.fullmatch(checksum):
        raise ValueError("release sha256 must be exactly 64 hexadecimal characters")
    if release["manifest_source"] != MANIFEST_SOURCE or release["checksum_source"] != METADATA_SOURCE or release["terms_url"] != TERMS_URL:
        raise ValueError("release metadata sources are not the approved official sources")
    return version, url, checksum.lower()


def _validate_new_root(sdk_root: Path) -> Path:
    if not isinstance(sdk_root, Path) or not sdk_root.is_absolute():
        raise ValueError("sdk_root must be an explicit absolute Path")
    if sdk_root == Path(sdk_root.root) or sdk_root.name in {"", ".", ".."} or ".." in sdk_root.parts:
        raise ValueError("sdk_root is not a safe explicit directory")
    if sdk_root.exists() or sdk_root.is_symlink():
        raise FileExistsError("refusing to clobber existing SDK root")
    parent = sdk_root.parent
    while True:
        if parent.is_symlink():
            raise ValueError("sdk_root ancestors must not be symlinks")
        if not parent.exists() or not parent.is_dir():
            raise ValueError("sdk_root ancestors must be existing directories")
        if parent == Path(parent.root):
            break
        parent = parent.parent
    return sdk_root


def validate_install(release: dict, sdk_root: Path, accepted_terms: bool = False) -> None:
    """Validate terms, release metadata, and destination without network or writes."""
    if accepted_terms is not True:
        raise PermissionError("explicit Android SDK terms acceptance is required")
    _validate_release(release)
    _validate_new_root(sdk_root)


def _safe_member(name: str) -> tuple[str, ...]:
    if not name or "\\" in name or name.startswith("/") or re.match(r"^[A-Za-z]:", name):
        raise ValueError("unsafe ZIP member path")
    parts = tuple(p for p in name.split("/") if p)
    if not parts or any(p in {".", ".."} for p in parts) or parts[0] != "cmdline-tools":
        raise ValueError("ZIP contains entry outside cmdline-tools")
    return parts


def _extract_verified(data: bytes | Path | BinaryIO, staging: Path) -> None:
    source: Any = io.BytesIO(data) if isinstance(data, bytes) else data
    with zipfile.ZipFile(source) as archive:
        seen: set[tuple[str, ...]] = set()
        entries: list[tuple[zipfile.ZipInfo, tuple[str, ...], bool]] = []
        files: set[tuple[str, ...]] = set()
        dirs: set[tuple[str, ...]] = set()
        expanded = 0
        for info in archive.infolist():
            parts = _safe_member(info.filename)
            if parts in seen:
                raise ValueError("ZIP contains duplicate member")
            seen.add(parts)
            mode = (info.external_attr >> 16) & 0o170000
            is_dir = info.is_dir() or mode == 0o040000
            if mode not in {0, 0o100000, 0o040000}:
                raise ValueError("ZIP contains unsupported special file")
            if is_dir:
                dirs.add(parts)
            else:
                if info.file_size < 1 or info.file_size > _EXTRACTED_MAX - expanded:
                    raise ValueError("ZIP expanded contents exceed safe size limit")
                expanded += info.file_size
                files.add(parts)
            entries.append((info, parts, is_dir))
        for path in files | dirs:
            for index in range(1, len(path)):
                if path[:index] in files:
                    raise ValueError("ZIP contains a file/ancestor path conflict")
        launcher = ("cmdline-tools", "bin", "sdkmanager")
        properties = ("cmdline-tools", "source.properties")
        notice = {("cmdline-tools", "NOTICE"), ("cmdline-tools", "NOTICE.txt")}
        lib_files = [path for path in files if len(path) > 2 and path[:2] == ("cmdline-tools", "lib")]
        launcher_info = next((info for info, path, is_dir in entries if path == launcher and not is_dir), None)
        if launcher_info is None or not ((launcher_info.external_attr >> 16) & 0o111):
            raise ValueError("ZIP lacks an executable cmdline-tools/bin/sdkmanager launcher")
        if properties not in files or not notice & files or not lib_files:
            raise ValueError("ZIP lacks required cmdline-tools files")
        for info, parts, is_dir in entries:
            if is_dir:
                continue
            target = staging.joinpath(*parts)
            target.parent.mkdir(parents=True, exist_ok=True)
            copied = 0
            with archive.open(info, "r") as src, target.open("wb") as dst:
                while True:
                    chunk = src.read(min(1024 * 1024, info.file_size - copied + 1))
                    if not chunk:
                        break
                    copied += len(chunk)
                    if copied > info.file_size or copied > _EXTRACTED_MAX:
                        raise ValueError("ZIP expanded contents exceed safe size limit")
                    dst.write(chunk)
            perms = (info.external_attr >> 16) & 0o777
            if perms:
                os.chmod(target, perms)
            if parts in lib_files and target.stat().st_size == 0:
                raise ValueError("ZIP contains an empty cmdline-tools/lib file")


def install_release(release: dict, sdk_root: Path, accepted_terms: bool = False) -> None:
    """Download, verify, and install one official archive; never execute SDK code."""
    validate_install(release, sdk_root, accepted_terms)
    _version, url, expected = _validate_release(release)
    temp_zip: Path | None = None
    staging: Path | None = None
    created_root = False
    try:
        with _open_url(url, timeout=_TIMEOUT) as response:
            fd, temp_name = tempfile.mkstemp(prefix="android-clt-", suffix=".zip", dir=str(sdk_root.parent))
            os.close(fd)
            temp_zip = Path(temp_name)
            digest = hashlib.sha256()
            total = 0
            with temp_zip.open("wb") as out:
                while True:
                    chunk = response.read(1024 * 1024)
                    if not chunk:
                        break
                    total += len(chunk)
                    if total > _ARCHIVE_MAX:
                        raise ValueError("Android archive exceeds safe size limit")
                    digest.update(chunk); out.write(chunk)
        if digest.hexdigest() != expected:
            raise ValueError("Android archive SHA-256 checksum mismatch")
        staging = Path(tempfile.mkdtemp(prefix="android-clt-stage-", dir=str(sdk_root.parent)))
        _extract_verified(temp_zip, staging)
        # Recheck the destination immediately before the final move.
        if sdk_root.exists() or sdk_root.is_symlink():
            raise FileExistsError("SDK root appeared during installation")
        sdk_root.mkdir()
        created_root = True
        (sdk_root / "cmdline-tools").mkdir()
        (staging / "cmdline-tools").rename(sdk_root / "cmdline-tools" / "latest")
        # Scoop's PATH parity includes platform-tools, but this installer does not
        # invent adb: create only the empty directory for later package installs.
        (sdk_root / "platform-tools").mkdir()
    except Exception:
        if created_root:
            shutil.rmtree(sdk_root, ignore_errors=True)
        raise
    finally:
        if temp_zip is not None:
            try: temp_zip.unlink()
            except OSError: pass
        if staging is not None:
            shutil.rmtree(staging, ignore_errors=True)
