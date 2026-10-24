#!/usr/bin/env python3
"""Bounded metadata-only VS Code Linux candidate review; no artifact fetcher or installer."""
from __future__ import annotations

import http.client
import json
import re
import urllib.error
import urllib.request
from typing import Any, Mapping

SCOOP_MANIFEST_URL = "https://raw.githubusercontent.com/ScoopInstaller/Extras/master/bucket/vscode.json"
API_PREFIX = "https://update.code.visualstudio.com/api/versions/"
DOWNLOAD_HOST = "vscode.download.prss.microsoft.com"
LICENSE_URL = "https://code.visualstudio.com/license"
DOWNLOAD_PAGE_URL = "https://code.visualstudio.com/download"
SCOOP_LIMIT = 256 * 1024
API_LIMIT = 64 * 1024
TIMEOUT = 20
VERSION = re.compile(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\Z")
SHA256 = re.compile(r"[0-9a-fA-F]{64}\Z")
COMMIT = re.compile(r"[0-9a-f]{40}\Z")


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """Refuse redirects so metadata requests cannot silently change source."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise RuntimeError("Official VS Code metadata redirect refused")


def _unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    """Build JSON objects while rejecting duplicate keys at every nesting level."""
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("Duplicate JSON key")
        result[key] = value
    return result


def _reject_constant(_value: str) -> Any:
    """Reject non-standard JSON constants such as NaN and Infinity."""
    raise ValueError("Non-standard JSON constant")


def _json_object(raw: bytes, label: str) -> Mapping[str, Any]:
    """Parse a UTF-8 JSON object and fail closed on malformed or ambiguous data."""
    try:
        value = json.loads(raw.decode("utf-8"), object_pairs_hook=_unique_object,
                           parse_constant=_reject_constant)
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError, RecursionError):
        raise ValueError(f"Invalid official VS Code {label} metadata") from None
    if not isinstance(value, Mapping):
        raise ValueError(f"Invalid official VS Code {label} metadata")
    return value


def _api_url(version: str, platform: str) -> str:
    """Construct only a supported, version-pinned Microsoft metadata endpoint."""
    if not isinstance(version, str) or not VERSION.fullmatch(version):
        raise ValueError("Invalid VS Code release version")
    if platform not in {"win32-x64-archive", "linux-x64"}:
        raise ValueError("Unsupported VS Code metadata platform")
    return f"{API_PREFIX}{version}/{platform}/stable"


def _metadata_limit(url: str) -> int:
    """Allow only the fixed Scoop manifest or the two exact version API URLs."""
    if url == SCOOP_MANIFEST_URL:
        return SCOOP_LIMIT
    pattern = re.escape(API_PREFIX) + r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)/(?:win32-x64-archive|linux-x64)/stable\Z"
    if isinstance(url, str) and re.fullmatch(pattern, url):
        return API_LIMIT
    raise ValueError("Refusing non-metadata VS Code URL")


def _fetch_metadata(url: str) -> bytes:
    """Read bounded bytes from allowlisted JSON metadata endpoints only."""
    limit = _metadata_limit(url)
    request = urllib.request.Request(
        url,
        headers={
            "User-Agent": "mainframe-vscode-metadata/1.0",
            "Accept": "application/json, text/plain",
        },
    )
    try:
        response = urllib.request.build_opener(_NoRedirect()).open(request, timeout=TIMEOUT)
    except RuntimeError:
        raise
    except (urllib.error.URLError, http.client.HTTPException, OSError, ValueError):
        raise RuntimeError("Official VS Code metadata request failed") from None
    with response:
        if response.getcode() != 200:
            raise RuntimeError("Official VS Code metadata response was not successful")
        if response.geturl() != url:
            raise RuntimeError("Official VS Code metadata source changed")
        content_type = response.headers.get("Content-Type", "").split(";", 1)[0].strip().lower()
        if limit == API_LIMIT and content_type != "application/json":
            raise RuntimeError("Official VS Code version metadata has an unexpected content type")
        if limit == SCOOP_LIMIT and content_type not in {"application/json", "text/plain", "application/octet-stream"}:
            raise RuntimeError("Official VS Code Scoop metadata has an unexpected content type")
        expected_length = None
        length = response.headers.get("Content-Length")
        if length is not None:
            try:
                expected_length = int(length)
            except (TypeError, ValueError):
                raise RuntimeError("Official VS Code metadata has invalid size") from None
            if expected_length < 0 or expected_length > limit:
                raise RuntimeError("Official VS Code metadata exceeds its size limit")
        chunks: list[bytes] = []
        total = 0
        while True:
            try:
                chunk = response.read(min(65536, limit - total + 1))
            except (urllib.error.URLError, http.client.HTTPException, OSError, ValueError):
                raise RuntimeError("Official VS Code metadata request failed") from None
            if not chunk:
                break
            total += len(chunk)
            if total > limit:
                raise RuntimeError("Official VS Code metadata exceeds its size limit")
            chunks.append(chunk)
        if expected_length is not None and total != expected_length:
            raise RuntimeError("Official VS Code metadata size does not match Content-Length")
        return b"".join(chunks)


def _manifest_metadata(raw: bytes) -> tuple[str, str, str]:
    """Read only the current Scoop version and Windows x64 URL/hash fields."""
    manifest = _json_object(raw, "Scoop")
    version = manifest.get("version")
    architecture = manifest.get("architecture")
    win64 = architecture.get("64bit") if isinstance(architecture, Mapping) else None
    if not isinstance(version, str) or not VERSION.fullmatch(version) or not isinstance(win64, Mapping):
        raise ValueError("Scoop VS Code manifest lacks an exact stable Windows x64 declaration")
    expected_url = f"https://update.code.visualstudio.com/{version}/win32-x64-archive/stable#/dl.7z"
    windows_url, digest = win64.get("url"), win64.get("hash")
    if windows_url != expected_url or not isinstance(digest, str) or not SHA256.fullmatch(digest):
        raise ValueError("Scoop VS Code manifest lacks a valid Windows x64 URL or SHA-256")
    return version, windows_url, digest.lower()


def _artifact_url(url: Any, version: str, commit: str, platform: str) -> str:
    """Validate, but never request, an artifact URL returned inside API metadata."""
    if not isinstance(url, str) or any(ord(char) < 0x21 or ord(char) == 0x7f for char in url):
        raise ValueError("VS Code version metadata lacks an artifact URL")
    prefix = f"https://{DOWNLOAD_HOST}/dbazure/download/stable/{commit}/"
    if platform == "win32-x64-archive":
        valid = url == f"{prefix}VSCode-win32-x64-{version}.zip"
    elif platform == "linux-x64":
        valid = re.fullmatch(re.escape(prefix) + r"code-stable-x64-[0-9]{10}\.tar\.gz", url) is not None
    else:
        valid = False
    if not valid:
        raise ValueError("VS Code version metadata contains an unexpected artifact URL")
    return url


def _version_metadata(raw: bytes, version: str, platform: str) -> dict[str, str]:
    """Validate release identity, build commit, checksum, and expected artifact naming."""
    data = _json_object(raw, "version API")
    commit, digest = data.get("version"), data.get("sha256hash")
    if (data.get("name") != version or data.get("productVersion") != version or
            not isinstance(commit, str) or not COMMIT.fullmatch(commit) or
            not isinstance(digest, str) or not SHA256.fullmatch(digest)):
        raise ValueError("Microsoft VS Code version metadata does not match the requested release")
    url = _artifact_url(data.get("url"), version, commit, platform)
    return {"product_version": version, "commit": commit, "url": url, "sha256": digest.lower()}


def build_dry_plan(architecture: str) -> dict[str, Any]:
    """Compare the current Windows x64 declaration with same-build Linux x64 metadata only."""
    if architecture != "x86_64":
        raise ValueError("VS Code metadata review is limited to Linux x86_64")
    version, scoop_windows_url, scoop_windows_hash = _manifest_metadata(_fetch_metadata(SCOOP_MANIFEST_URL))
    windows = _version_metadata(_fetch_metadata(_api_url(version, "win32-x64-archive")), version,
                                "win32-x64-archive")
    linux = _version_metadata(_fetch_metadata(_api_url(version, "linux-x64")), version, "linux-x64")
    if windows["sha256"] != scoop_windows_hash:
        raise ValueError("Scoop VS Code Windows SHA-256 does not match Microsoft's version metadata")
    if linux["commit"] != windows["commit"]:
        raise ValueError("Microsoft VS Code Linux metadata identifies a different build commit")
    filename = linux["url"].rsplit("/", 1)[-1]
    return {
        "package": {"name": "vscode", "version": version, "source": "scoop",
                    "version_is_restore_pin": False},
        "windows_declaration": {"url": scoop_windows_url, "sha256": scoop_windows_hash,
                                "checksum_matches_microsoft": True},
        "official_build": {"product_version": version, "commit": windows["commit"],
                           "windows_api_source": _api_url(version, "win32-x64-archive"),
                           "linux_api_source": _api_url(version, "linux-x64")},
        "linux_archive_candidate": {"name": filename, "format": "tar.gz", "architecture": "x86_64",
                                    "url": linux["url"], "sha256": linux["sha256"]},
        "terms": {"license_url": LICENSE_URL, "download_page_url": DOWNLOAD_PAGE_URL,
                  "accepted_for_this_review": False},
        "execution_blockers": [
            "Microsoft states that VS Code download/use is subject to license terms and a privacy statement; neither was accepted for this metadata-only review",
            "Linux archive contents, safe extraction, runtime dependencies, and desktop integration are unvalidated",
            "Windows settings, extensions, profiles, and activation state are not migrated",
            "This live metadata observation is not a user-selected restore version pin",
        ],
        "executable": False,
    }
