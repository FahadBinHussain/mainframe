#!/usr/bin/env python3
"""Metadata-only Windscribe desktop release review; never downloads or installs packages."""
from __future__ import annotations

import http.client
import json
import re
import urllib.error
import urllib.request
from collections.abc import Mapping
from typing import Any

WINGET_INDEX_URL = "https://api.github.com/repos/microsoft/winget-pkgs/contents/manifests/w/Windscribe/Windscribe"
WINGET_RAW_PREFIX = "https://raw.githubusercontent.com/microsoft/winget-pkgs/master/manifests/w/Windscribe/Windscribe/"
RELEASE_API_PREFIX = "https://api.github.com/repos/Windscribe/Desktop-App/releases/tags/v"
INDEX_LIMIT = 256 * 1024
MANIFEST_LIMIT = 64 * 1024
RELEASE_LIMIT = 512 * 1024
TIMEOUT = 20
VERSION = re.compile(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\Z")
SHA256 = re.compile(r"[0-9a-fA-F]{64}\Z")
RELEASE_DIGEST = re.compile(r"sha256:([0-9a-fA-F]{64})\Z")


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise RuntimeError("Official Windscribe metadata redirect refused")


def _version_urls(version: str) -> dict[str, str]:
    if not isinstance(version, str) or not VERSION.fullmatch(version):
        raise ValueError("Invalid Windscribe release version")
    return {
        "manifest": f"{WINGET_RAW_PREFIX}{version}/Windscribe.Windscribe.installer.yaml",
        "release": f"{RELEASE_API_PREFIX}{version}",
    }


def _fetch_metadata(url: str, version: str | None = None) -> bytes:
    """Fetch bounded public metadata from fixed endpoints; artifact URLs are never accepted."""
    if not isinstance(url, str):
        raise ValueError("Refusing non-metadata Windscribe URL")
    if url == WINGET_INDEX_URL:
        limit = INDEX_LIMIT
    elif isinstance(version, str):
        sources = _version_urls(version)
        limits = {sources["manifest"]: MANIFEST_LIMIT, sources["release"]: RELEASE_LIMIT}
        limit = limits.get(url)
        if limit is None:
            raise ValueError("Refusing non-metadata Windscribe URL")
    else:
        raise ValueError("Refusing non-metadata Windscribe URL")

    request = urllib.request.Request(
        url,
        headers={
            "User-Agent": "mainframe-windscribe-metadata/1.0",
            "Accept": "application/vnd.github+json, text/plain, application/yaml",
        },
    )
    try:
        response = urllib.request.build_opener(_NoRedirect()).open(request, timeout=TIMEOUT)
    except RuntimeError:
        raise
    except (urllib.error.URLError, http.client.HTTPException, OSError, ValueError):
        raise RuntimeError("Official Windscribe metadata request failed") from None

    with response:
        if response.geturl() != url:
            raise RuntimeError("Official Windscribe metadata source changed")
        length = response.headers.get("Content-Length")
        if length is not None:
            try:
                parsed_length = int(length)
            except (TypeError, ValueError):
                raise RuntimeError("Official Windscribe metadata has invalid size") from None
            if parsed_length < 0 or parsed_length > limit:
                raise RuntimeError("Official Windscribe metadata exceeds its size limit")
        chunks: list[bytes] = []
        total = 0
        while True:
            try:
                chunk = response.read(min(65536, limit - total + 1))
            except (urllib.error.URLError, http.client.HTTPException, OSError, ValueError):
                raise RuntimeError("Official Windscribe metadata request failed") from None
            if not chunk:
                break
            total += len(chunk)
            if total > limit:
                raise RuntimeError("Official Windscribe metadata exceeds its size limit")
            chunks.append(chunk)
        return b"".join(chunks)


def _unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("Duplicate JSON key")
        result[key] = value
    return result


def _json_value(raw: bytes, label: str) -> Any:
    try:
        return json.loads(raw.decode("utf-8"), object_pairs_hook=_unique_object)
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError, RecursionError):
        raise ValueError(f"Invalid official Windscribe {label} metadata") from None


def _latest_version(raw: bytes) -> str:
    value = _json_value(raw, "WinGet index")
    if not isinstance(value, list):
        raise ValueError("Invalid official Windscribe WinGet index metadata")
    versions: list[tuple[tuple[int, int, int], str]] = []
    seen: set[str] = set()
    for entry in value:
        if not isinstance(entry, Mapping):
            raise ValueError("Invalid official Windscribe WinGet index entry")
        name, kind = entry.get("name"), entry.get("type")
        if kind != "dir" or not isinstance(name, str):
            continue
        if name[:1].isdigit():
            if not VERSION.fullmatch(name):
                raise ValueError("Unsupported Windscribe WinGet version format")
            if name in seen:
                raise ValueError("Duplicate Windscribe WinGet version directory")
            seen.add(name)
            versions.append((tuple(int(part) for part in name.split(".")), name))
    if not versions:
        raise ValueError("Windscribe WinGet index contains no supported versions")
    return max(versions)[1]


def _top_scalar(lines: list[str], key: str) -> str:
    matches = [line for line in lines if re.match(rf"^{re.escape(key)}:", line)]
    if len(matches) != 1:
        raise ValueError("Windscribe WinGet installer manifest has duplicate or missing identity fields")
    match = re.fullmatch(rf"{re.escape(key)}: ([^\s#]+)", matches[0])
    if not match:
        raise ValueError("Windscribe WinGet installer manifest has malformed identity fields")
    return match.group(1)


def _installer_metadata(raw: bytes, expected_version: str, architecture: str) -> tuple[str, str, str]:
    try:
        text = raw.decode("utf-8", "strict")
    except UnicodeDecodeError:
        raise ValueError("Invalid official Windscribe WinGet installer metadata") from None
    if not text.isascii() or "\x00" in text or any("\t" in line for line in text.splitlines()):
        raise ValueError("Invalid official Windscribe WinGet installer metadata")
    lines = text.splitlines()
    if _top_scalar(lines, "PackageIdentifier") != "Windscribe.Windscribe":
        raise ValueError("Windscribe WinGet package identity changed")
    version = _top_scalar(lines, "PackageVersion")
    if not VERSION.fullmatch(version) or version != expected_version:
        raise ValueError("Windscribe WinGet directory and manifest versions differ")

    installers_indices = [i for i, line in enumerate(lines) if line == "Installers:"]
    if len(installers_indices) != 1:
        raise ValueError("Windscribe WinGet installer manifest has duplicate or missing Installers section")
    blocks: list[dict[str, str]] = []
    current: dict[str, str] | None = None
    for line in lines[installers_indices[0] + 1:]:
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        item = re.fullmatch(r"- Architecture: ([A-Za-z0-9_-]+)", line)
        if item:
            if current is not None:
                blocks.append(current)
            current = {"Architecture": item.group(1)}
            continue
        if line.startswith("  "):
            if current is None:
                raise ValueError("Malformed Windscribe WinGet installer entry")
            field = re.fullmatch(r" {2}(InstallerUrl|InstallerSha256): (\S+)", line)
            if field:
                key, value = field.groups()
                if key in current:
                    raise ValueError("Duplicate Windscribe WinGet installer field")
                current[key] = value
            # Other WinGet data is deliberately treated as inert and ignored.
            continue
        if line.startswith(" "):
            raise ValueError("Malformed Windscribe WinGet installer structure")
        # A new top-level field ends the relevant Installers list.
        break
    if current is not None:
        blocks.append(current)

    target_arch = "x64" if architecture == "x86_64" else "arm64"
    matches = [block for block in blocks if block.get("Architecture") == target_arch]
    if len(matches) != 1:
        raise ValueError("Windscribe WinGet manifest lacks a unique target Windows architecture")
    block = matches[0]
    url, digest = block.get("InstallerUrl"), block.get("InstallerSha256")
    suffix = "amd64" if architecture == "x86_64" else "arm64"
    expected_url = f"https://github.com/Windscribe/Desktop-App/releases/download/v{version}/Windscribe_{version}_{suffix}.exe"
    if url != expected_url or not isinstance(digest, str) or not SHA256.fullmatch(digest):
        raise ValueError("Windscribe WinGet manifest has invalid target installer metadata")
    return version, url, digest.lower()


def _asset(release: Mapping[str, Any], name: str, url: str) -> dict[str, Any]:
    assets = release.get("assets")
    if not isinstance(assets, list):
        raise ValueError("Windscribe release has no asset metadata")
    matches = [asset for asset in assets if isinstance(asset, Mapping) and asset.get("name") == name]
    if len(matches) != 1:
        raise ValueError("Windscribe release asset is missing or ambiguous")
    asset = matches[0]
    digest = asset.get("digest")
    size = asset.get("size")
    if (asset.get("browser_download_url") != url or not isinstance(digest, str)
            or not RELEASE_DIGEST.fullmatch(digest) or not isinstance(size, int)
            or isinstance(size, bool) or size <= 0):
        raise ValueError("Windscribe release asset metadata is invalid")
    return {"name": name, "url": url, "sha256": RELEASE_DIGEST.fullmatch(digest).group(1).lower(), "size": size}


def _release_metadata(raw: bytes, version: str, architecture: str,
                      winget_url: str, winget_sha256: str) -> dict[str, Any]:
    release = _json_value(raw, "GitHub release")
    if not isinstance(release, Mapping):
        raise ValueError("Invalid official Windscribe GitHub release metadata")
    if (release.get("tag_name") != f"v{version}" or release.get("draft") is not False
            or release.get("prerelease") is not False):
        raise ValueError("Windscribe GitHub release tag/status does not match WinGet")
    published = release.get("published_at")
    if not isinstance(published, str) or not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[^\s]+Z", published):
        raise ValueError("Windscribe release publication metadata is invalid")
    suffix = "amd64" if architecture == "x86_64" else "arm64"
    windows_name = f"Windscribe_{version}_{suffix}.exe"
    linux_name = f"windscribe_{version}_{suffix}.deb"
    expected_windows_url = f"https://github.com/Windscribe/Desktop-App/releases/download/v{version}/{windows_name}"
    expected_linux_url = f"https://github.com/Windscribe/Desktop-App/releases/download/v{version}/{linux_name}"
    if winget_url != expected_windows_url:
        raise ValueError("Windscribe WinGet Windows URL differs from the exact official release asset")
    windows_asset = _asset(release, windows_name, expected_windows_url)
    if windows_asset["sha256"] != winget_sha256:
        raise ValueError("Windscribe WinGet Windows SHA-256 differs from the official release asset digest")
    linux_asset = _asset(release, linux_name, expected_linux_url)
    return {
        "tag": f"v{version}",
        "published_at": published,
        "windows_asset": windows_asset,
        "windows_digest_matches_winget": True,
        "linux_desktop_deb_candidate": linux_asset,
        "publisher_signature_verified": False,
    }


def build_dry_plan(architecture: str) -> dict[str, Any]:
    """Compare public version/hash metadata only; no installer/package/signature bytes are read."""
    if not isinstance(architecture, str) or architecture not in {"x86_64", "aarch64"}:
        raise ValueError("Windscribe metadata review supports x86_64 or aarch64 only")
    index = _fetch_metadata(WINGET_INDEX_URL)
    version = _latest_version(index)
    urls = _version_urls(version)
    manifest = _fetch_metadata(urls["manifest"], version)
    version, windows_url, windows_sha256 = _installer_metadata(manifest, version, architecture)
    release_raw = _fetch_metadata(urls["release"], version)
    release = _release_metadata(release_raw, version, architecture, windows_url, windows_sha256)
    return {
        "package": {
            "name": "Windscribe.Windscribe",
            "product": "Windscribe desktop app",
            "version": version,
            "version_is_restore_pin": False,
            "architecture": architecture,
        },
        "winget_observation": {
            "manifest_url": urls["manifest"],
            "windows_architecture": "x64" if architecture == "x86_64" else "arm64",
            "windows_installer_url": windows_url,
            "windows_installer_sha256": windows_sha256,
        },
        "official_release": release,
        "execution_blockers": [
            "The current WinGet version is an upstream observation, not a selected restore pin.",
            "No package or signature contents are downloaded; GitHub asset digests are metadata, not GPG signature verification.",
            "Privileged VPN service, routing, firewall/network changes, account login, and Windows state migration require separate review and authorization.",
        ],
        "executable": False,
    }
