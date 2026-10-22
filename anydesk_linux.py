#!/usr/bin/env python3
"""Safe, official AnyDesk DEB adapter for Debian/Ubuntu x86_64 hosts."""
from __future__ import annotations

import hashlib
import os
import re
import subprocess
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Callable, Mapping

METADATA_URL = "https://deb.anydesk.com/dists/all/main/binary-amd64/Packages"
OFFICIAL_BASE = "https://deb.anydesk.com/"
TERMS_URL = "https://anydesk.com/en/terms-conditions"
USER_AGENT = "mainframe-native-shells/1.0 (Debian package resolver)"
METADATA_LIMIT = 2 * 1024 * 1024
DOWNLOAD_LIMIT = 256 * 1024 * 1024
TIMEOUT = 30
INSTALL_TIMEOUT = 300

_FIELD_RE = re.compile(r"^[A-Za-z][A-Za-z0-9-]*$")
_SAFE_VERSION_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9.+:~_-]*$")
_SHA256_RE = re.compile(r"^[0-9a-fA-F]{64}$")


class _OfficialRedirectHandler(urllib.request.HTTPRedirectHandler):
    """Permit only redirects which remain on the fixed official origin."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if not _is_official_url(newurl):
            raise RuntimeError(f"Refusing non-official redirect: {newurl!r}")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def _is_official_url(url: str) -> bool:
    try:
        parsed = urllib.parse.urlsplit(url)
        port = parsed.port
    except (TypeError, ValueError):
        return False
    return (
        parsed.scheme == "https"
        and parsed.netloc == "deb.anydesk.com"
        and not parsed.username
        and not parsed.password
        and port is None
        and not parsed.query
        and not parsed.fragment
        and parsed.path.startswith("/")
    )


def _open_url(url: str, *, limit: int) -> Any:
    if not _is_official_url(url):
        raise RuntimeError(f"Refusing non-official URL: {url!r}")
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    opener = urllib.request.build_opener(_OfficialRedirectHandler())
    try:
        response = opener.open(request, timeout=TIMEOUT)
    except (urllib.error.URLError, OSError) as exc:
        raise RuntimeError(f"Official AnyDesk URL request failed: {exc}") from exc
    length = response.headers.get("Content-Length")
    if length is not None:
        try:
            if int(length) > limit:
                response.close()
                raise RuntimeError(f"Response exceeds limit of {limit} bytes")
        except ValueError:
            response.close()
            raise RuntimeError("Invalid Content-Length")
    return response


def _read_bounded(response: Any, limit: int) -> bytes:
    chunks: list[bytes] = []
    total = 0
    while True:
        chunk = response.read(min(64 * 1024, limit - total + 1))
        if not chunk:
            return b"".join(chunks)
        total += len(chunk)
        if total > limit:
            raise RuntimeError(f"Response exceeds limit of {limit} bytes")
        chunks.append(chunk)


def _parse_stanzas(data: bytes | str) -> list[dict[str, str]]:
    text = data.decode("utf-8", errors="strict") if isinstance(data, bytes) else data
    stanzas: list[dict[str, str]] = []
    for raw in re.split(r"\n[ \t]*\n", text.replace("\r\n", "\n")):
        if not raw.strip():
            continue
        fields: dict[str, str] = {}
        current: str | None = None
        for line in raw.splitlines():
            if line[:1] in (" ", "\t"):
                if current is None:
                    raise RuntimeError("Malformed Debian metadata continuation")
                fields[current] += "\n" + line[1:]
                continue
            if ":" not in line:
                raise RuntimeError("Malformed Debian metadata field")
            key, value = line.split(":", 1)
            if not _FIELD_RE.fullmatch(key) or key in fields:
                raise RuntimeError("Malformed or duplicate Debian metadata field")
            fields[key] = value.strip()
            current = key
        stanzas.append(fields)
    return stanzas


def _safe_filename(filename: str, version: str) -> bool:
    if not filename or not filename.startswith("pool/main/a/anydesk/"):
        return False
    if urllib.parse.urlsplit(filename).query or urllib.parse.urlsplit(filename).fragment:
        return False
    if "\\" in filename or any(part in ("", ".", "..") for part in filename.split("/")):
        return False
    return filename == f"pool/main/a/anydesk/anydesk_{version}_amd64.deb"


def _release_from_stanza(stanza: Mapping[str, str]) -> dict[str, str]:
    required = ("Package", "Architecture", "Version", "Filename", "Size", "SHA256")
    if any(not isinstance(stanza.get(field), str) or not stanza[field] for field in required):
        raise RuntimeError("Missing required AnyDesk metadata field")
    if stanza["Package"] != "anydesk" or stanza["Architecture"] != "amd64":
        raise RuntimeError("AnyDesk metadata has unexpected package or architecture")
    version = stanza["Version"]
    if not _SAFE_VERSION_RE.fullmatch(version) or not _safe_filename(stanza["Filename"], version):
        raise RuntimeError("Unsafe AnyDesk version or filename")
    try:
        size = int(stanza["Size"])
    except (TypeError, ValueError):
        raise RuntimeError("Invalid AnyDesk package size") from None
    if size <= 0 or size > DOWNLOAD_LIMIT or str(size) != stanza["Size"]:
        raise RuntimeError("Invalid or oversized AnyDesk package size")
    checksum = stanza["SHA256"].lower()
    if not _SHA256_RE.fullmatch(checksum):
        raise RuntimeError("Invalid AnyDesk SHA256 checksum")
    return {
        "version": version,
        "url": urllib.parse.urljoin(OFFICIAL_BASE, stanza["Filename"]),
        "sha256": checksum,
        "size": str(size),
        "checksum_source": METADATA_URL,
        "terms_url": TERMS_URL,
    }


def resolve_release(architecture: str) -> dict[str, str]:
    """Resolve the unique current official AnyDesk amd64 DEB release."""
    if architecture != "x86_64":
        raise RuntimeError(f"Unsupported architecture: {architecture}")
    response = _open_url(METADATA_URL, limit=METADATA_LIMIT)
    try:
        data = _read_bounded(response, METADATA_LIMIT)
    finally:
        response.close()
    candidates = []
    for stanza in _parse_stanzas(data):
        if stanza.get("Package") == "anydesk" or stanza.get("Architecture") == "amd64":
            if stanza.get("Package") == "anydesk" and stanza.get("Architecture") == "amd64":
                candidates.append(stanza)
    if len(candidates) != 1:
        raise RuntimeError("AnyDesk amd64 metadata is missing or ambiguous")
    return _release_from_stanza(candidates[0])


def _validate_release(release: Mapping[str, Any]) -> dict[str, str]:
    if not isinstance(release, Mapping):
        raise ValueError("Release must be a mapping")
    expected = {"version", "url", "sha256", "size", "checksum_source", "terms_url"}
    if set(release) != expected or any(not isinstance(release[k], str) or not release[k] for k in expected):
        raise ValueError("Invalid release fields")
    version = release["version"]
    if not _SAFE_VERSION_RE.fullmatch(version):
        raise ValueError("Unsafe release version")
    if not _is_official_url(release["url"]):
        raise ValueError("Release URL is not official")
    parsed = urllib.parse.urlsplit(release["url"])
    filename = parsed.path.lstrip("/")
    if not _safe_filename(filename, version):
        raise ValueError("Release URL has unsafe package path")
    if release["checksum_source"] != METADATA_URL or release["terms_url"] != TERMS_URL:
        raise ValueError("Release provenance is invalid")
    if not _SHA256_RE.fullmatch(release["sha256"]):
        raise ValueError("Invalid release SHA256 checksum")
    try:
        size = int(release["size"])
    except ValueError:
        raise ValueError("Invalid release size") from None
    if size <= 0 or size > DOWNLOAD_LIMIT or str(size) != release["size"]:
        raise ValueError("Invalid release size")
    return dict(release)


def validate_install(release: Mapping[str, Any], *, accepted_terms: bool = False, allow_service: bool = False) -> None:
    """Require reviewed release metadata and two distinct explicit attestations."""
    _validate_release(release)
    if accepted_terms is not True:
        raise PermissionError("Explicit acceptance of AnyDesk terms is required")
    if allow_service is not True:
        raise PermissionError("Explicit permission for the AnyDesk service is required")


def install_release(release: Mapping[str, Any], *, accepted_terms: bool = False,
                    allow_service: bool = False, runner: Callable[..., Any] = subprocess.run) -> None:
    """Verify and install a DEB; vendor maintainer scripts may start its service."""
    validated = _validate_release(release)
    validate_install(validated, accepted_terms=accepted_terms, allow_service=allow_service)
    expected_size = int(validated["size"])
    with tempfile.TemporaryDirectory(prefix="anydesk-", dir="/tmp") as directory:
        os.chmod(directory, 0o700)
        deb = Path(directory) / "anydesk.deb"
        response = _open_url(validated["url"], limit=DOWNLOAD_LIMIT)
        digest = hashlib.sha256()
        total = 0
        try:
            with deb.open("wb") as output:
                os.chmod(deb, 0o644)
                while True:
                    chunk = response.read(min(1024 * 1024, DOWNLOAD_LIMIT - total + 1))
                    if not chunk:
                        break
                    total += len(chunk)
                    if total > DOWNLOAD_LIMIT:
                        raise RuntimeError("AnyDesk download exceeds 256 MiB limit")
                    digest.update(chunk)
                    output.write(chunk)
        finally:
            response.close()
        if total != expected_size:
            raise RuntimeError("AnyDesk package size mismatch")
        if digest.hexdigest() != validated["sha256"]:
            raise RuntimeError("AnyDesk package SHA256 mismatch")
        command = ["apt-get", "install", "-y", str(deb)]
        if os.geteuid() != 0:
            command = ["sudo", "-n", *command]
        try:
            result = runner(command, check=False, shell=False, timeout=INSTALL_TIMEOUT)
        except Exception as exc:
            raise RuntimeError(f"AnyDesk apt installation failed: {exc}") from exc
        if getattr(result, "returncode", 1) != 0:
            raise RuntimeError(f"AnyDesk apt installation failed with exit code {result.returncode}")
