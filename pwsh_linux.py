#!/usr/bin/env python3
"""Metadata-only PowerShell Linux candidate review; no archive fetcher or installer."""
from __future__ import annotations

import http.client
import json
import re
import urllib.error
import urllib.request
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
