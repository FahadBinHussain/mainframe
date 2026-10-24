"""Read-only WakaTime Desktop package/release metadata comparison.

This module never fetches Windows installers, Linux AppImages, checksum-file
contents, or user state. Its output is descriptive only and is not executable.
"""
from __future__ import annotations

import http.client
import json
import re
import urllib.error
import urllib.parse
import urllib.request
from collections.abc import Mapping
from typing import Any

WINGET_INDEX_URL = "https://api.github.com/repos/microsoft/winget-pkgs/contents/manifests/w/Wakatime/DesktopWakatime"
WINGET_RAW_PREFIX = "https://raw.githubusercontent.com/microsoft/winget-pkgs/master/manifests/w/Wakatime/DesktopWakatime/"
RELEASE_API_PREFIX = "https://api.github.com/repos/wakatime/desktop-wakatime/releases/tags/"
RELEASE_DOWNLOAD_PREFIX = "https://github.com/wakatime/desktop-wakatime/releases/download/"
INDEX_LIMIT = 256 * 1024
MANIFEST_LIMIT = 64 * 1024
RELEASE_LIMIT = 512 * 1024
TIMEOUT = 20
_COMPONENT = r"(?:0|[1-9][0-9]*)"
VERSION = re.compile(rf"{_COMPONENT}\.{_COMPONENT}\.{_COMPONENT}(?:\.{_COMPONENT})?\Z")
RELEASE_TAG = re.compile(rf"v{_COMPONENT}\.{_COMPONENT}\.{_COMPONENT}(?:\+[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?\Z")
SHA256 = re.compile(r"[0-9a-fA-F]{64}\Z")
RELEASE_DIGEST = re.compile(r"sha256:([0-9a-fA-F]{64})\Z")
_PUBLISHED_AT = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\Z")


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise RuntimeError("Official WakaTime metadata redirect refused")


def _version_key(version: str) -> tuple[int, ...]:
    return tuple(int(part) for part in version.split("."))


def _version_urls(version: str) -> dict[str, str]:
    if not isinstance(version, str) or not VERSION.fullmatch(version):
        raise ValueError("Invalid WakaTime Desktop release version")
    segment = urllib.parse.quote(version, safe=".")
    return {"manifest": f"{WINGET_RAW_PREFIX}{segment}/Wakatime.DesktopWakatime.installer.yaml"}


def _release_api_url(tag: str) -> str:
    if not isinstance(tag, str) or not RELEASE_TAG.fullmatch(tag):
        raise ValueError("Invalid WakaTime official release tag")
    return f"{RELEASE_API_PREFIX}{urllib.parse.quote(tag, safe='.')}"


def _release_asset_url(tag: str, name: str) -> str:
    allowed = {
        "wakatime-win32-x86.exe", "wakatime-win32-x64.exe", "wakatime-win32-arm64.exe",
        "wakatime-linux-x86_64.AppImage", "wakatime-linux-arm64.AppImage",
    }
    if name not in allowed:
        raise ValueError("Unsupported WakaTime release asset name")
    _release_api_url(tag)
    return f"{RELEASE_DOWNLOAD_PREFIX}{urllib.parse.quote(tag, safe='.')}/{name}"


def _parse_release_asset_url(url: str, expected_name: str) -> tuple[str, str]:
    try:
        parsed = urllib.parse.urlsplit(url)
        parts = parsed.path.split("/")
        segment = parts[5] if len(parts) == 7 else ""
        tag = urllib.parse.unquote(segment, errors="strict")
    except (TypeError, ValueError):
        raise ValueError("Invalid WakaTime official asset URL") from None
    if (parsed.scheme != "https" or parsed.netloc != "github.com" or parsed.query or parsed.fragment
            or len(parts) != 7 or parts[1:5] != ["wakatime", "desktop-wakatime", "releases", "download"]
            or parts[6] != expected_name or not RELEASE_TAG.fullmatch(tag)
            or segment not in {tag, urllib.parse.quote(tag, safe=".")}):
        raise ValueError("Invalid WakaTime official asset URL")
    return tag, _release_asset_url(tag, expected_name)


def _fetch_metadata(url: str, version: str | None = None, *, release_tag: str | None = None) -> bytes:
    """Fetch bounded metadata from fixed endpoints; artifact URLs are never accepted."""
    if not isinstance(url, str):
        raise ValueError("Refusing non-metadata WakaTime URL")
    if url == WINGET_INDEX_URL:
        limit = INDEX_LIMIT
    elif isinstance(version, str):
        sources = _version_urls(version)
        limits = {sources["manifest"]: MANIFEST_LIMIT}
        if release_tag is not None:
            limits[_release_api_url(release_tag)] = RELEASE_LIMIT
        limit = limits.get(url)
        if limit is None:
            raise ValueError("Refusing non-metadata WakaTime URL")
    else:
        raise ValueError("Refusing non-metadata WakaTime URL")

    request = urllib.request.Request(
        url,
        headers={
            "User-Agent": "mainframe-wakatime-metadata/1.0",
            "Accept": "application/vnd.github+json, text/plain, application/yaml",
        },
    )
    try:
        response = urllib.request.build_opener(_NoRedirect()).open(request, timeout=TIMEOUT)
    except RuntimeError:
        raise
    except (urllib.error.URLError, http.client.HTTPException, OSError, ValueError):
        raise RuntimeError("Official WakaTime metadata request failed") from None

    with response:
        if response.geturl() != url:
            raise RuntimeError("Official WakaTime metadata source changed")
        length = response.headers.get("Content-Length")
        if length is not None:
            try:
                parsed_length = int(length)
            except (TypeError, ValueError):
                raise RuntimeError("Official WakaTime metadata has invalid size") from None
            if parsed_length < 0 or parsed_length > limit:
                raise RuntimeError("Official WakaTime metadata exceeds its size limit")
        chunks: list[bytes] = []
        total = 0
        while True:
            try:
                chunk = response.read(min(65536, limit - total + 1))
            except (urllib.error.URLError, http.client.HTTPException, OSError, ValueError):
                raise RuntimeError("Official WakaTime metadata request failed") from None
            if not chunk:
                break
            total += len(chunk)
            if total > limit:
                raise RuntimeError("Official WakaTime metadata exceeds its size limit")
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
        return json.loads(raw.decode("utf-8", "strict"), object_pairs_hook=_unique_object)
    except (UnicodeDecodeError, ValueError, RecursionError):
        raise ValueError(f"Invalid official WakaTime {label} metadata") from None


def _latest_version(raw: bytes) -> str:
    value = _json_value(raw, "WinGet index")
    if not isinstance(value, list):
        raise ValueError("Invalid official WakaTime WinGet index metadata")
    versions: list[str] = []
    seen: set[str] = set()
    for entry in value:
        if not isinstance(entry, Mapping):
            raise ValueError("Invalid official WakaTime WinGet index entry")
        name, kind = entry.get("name"), entry.get("type")
        if kind != "dir" or not isinstance(name, str):
            continue
        if name[:1].isdigit():
            if not VERSION.fullmatch(name):
                raise ValueError("Unsupported WakaTime WinGet version format")
            if name in seen:
                raise ValueError("Duplicate WakaTime WinGet version directory")
            seen.add(name)
            versions.append(name)
    if not versions:
        raise ValueError("WakaTime WinGet index contains no supported versions")
    return max(versions, key=_version_key)


def _top_scalar(lines: list[str], key: str) -> str:
    matches = [line for line in lines if re.match(rf"^{re.escape(key)}:", line)]
    if len(matches) != 1:
        raise ValueError("WakaTime WinGet installer manifest has duplicate or missing identity fields")
    match = re.fullmatch(rf"{re.escape(key)}: ([^\s#]+)", matches[0])
    if not match:
        raise ValueError("WakaTime WinGet installer manifest has malformed identity fields")
    return match.group(1)


def _installer_metadata(raw: bytes, expected_version: str, architecture: str) -> tuple[str, str, str, str]:
    try:
        text = raw.decode("utf-8", "strict")
    except UnicodeDecodeError:
        raise ValueError("Invalid official WakaTime WinGet installer metadata") from None
    if not text.isascii() or "\x00" in text or any("\t" in line for line in text.splitlines()):
        raise ValueError("Invalid official WakaTime WinGet installer metadata")
    lines = text.splitlines()
    if _top_scalar(lines, "PackageIdentifier") != "Wakatime.DesktopWakatime":
        raise ValueError("WakaTime WinGet package identity changed")
    version = _top_scalar(lines, "PackageVersion")
    if not VERSION.fullmatch(version) or version != expected_version:
        raise ValueError("WakaTime WinGet directory and manifest versions differ")

    installers_indices = [i for i, line in enumerate(lines) if line == "Installers:"]
    if len(installers_indices) != 1:
        raise ValueError("WakaTime WinGet installer manifest has duplicate or missing Installers section")
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
                raise ValueError("Malformed WakaTime WinGet installer entry")
            field = re.fullmatch(r" {2}(InstallerUrl|InstallerSha256): (\S+)", line)
            if field:
                key, value = field.groups()
                if key in current:
                    raise ValueError("Duplicate WakaTime WinGet installer field")
                current[key] = value
            # Other WinGet metadata is inert and deliberately ignored.
            continue
        if line.startswith(" "):
            raise ValueError("Malformed WakaTime WinGet installer structure")
        break
    if current is not None:
        blocks.append(current)

    target_arch = "x64" if architecture == "x86_64" else "arm64"
    matches = [block for block in blocks if block.get("Architecture") == target_arch]
    if len(matches) != 1:
        raise ValueError("WakaTime WinGet manifest lacks a unique target Windows architecture")
    block = matches[0]
    url, digest = block.get("InstallerUrl"), block.get("InstallerSha256")
    suffix = "x64" if architecture == "x86_64" else "arm64"
    asset_name = f"wakatime-win32-{suffix}.exe"
    try:
        release_tag, _ = _parse_release_asset_url(url, asset_name)
    except ValueError:
        raise ValueError("WakaTime WinGet manifest has invalid target installer metadata") from None
    if not isinstance(digest, str) or not SHA256.fullmatch(digest):
        raise ValueError("WakaTime WinGet manifest has invalid target installer metadata")
    return version, url, digest.lower(), release_tag


def _asset(release: Mapping[str, Any], name: str, expected_url: str) -> dict[str, Any]:
    assets = release.get("assets")
    if not isinstance(assets, list) or any(not isinstance(asset, Mapping) for asset in assets):
        raise ValueError("Invalid official WakaTime release asset list")
    matches = [asset for asset in assets if asset.get("name") == name]
    if len(matches) != 1:
        raise ValueError("Official WakaTime release is missing or duplicates a target asset")
    asset = matches[0]
    size, url, digest = asset.get("size"), asset.get("browser_download_url"), asset.get("digest")
    match = RELEASE_DIGEST.fullmatch(digest) if isinstance(digest, str) else None
    if type(size) is not int or size <= 0 or url != expected_url or not match:
        raise ValueError("Official WakaTime release asset metadata is invalid")
    return {"name": name, "url": url, "size": size, "sha256": match.group(1).lower()}


def _release_metadata(raw: bytes, version: str, tag: str, architecture: str,
                      windows_url: str, windows_sha256: str) -> dict[str, Any]:
    release = _json_value(raw, "GitHub release")
    if not isinstance(release, Mapping):
        raise ValueError("Invalid official WakaTime GitHub release metadata")
    _release_api_url(tag)
    if (release.get("tag_name") != tag or release.get("draft") is not False
            or release.get("prerelease") is not False):
        raise ValueError("WakaTime GitHub release tag/status does not match WinGet")
    published_at = release.get("published_at")
    if not isinstance(published_at, str) or not _PUBLISHED_AT.fullmatch(published_at):
        raise ValueError("WakaTime GitHub release publication metadata is invalid")

    suffix = "x64" if architecture == "x86_64" else "arm64"
    windows_name = f"wakatime-win32-{suffix}.exe"
    expected_windows_url = _release_asset_url(tag, windows_name)
    try:
        manifest_tag, canonical_windows_url = _parse_release_asset_url(windows_url, windows_name)
    except ValueError:
        raise ValueError("WakaTime WinGet Windows asset does not match the release architecture") from None
    if manifest_tag != tag or canonical_windows_url != expected_windows_url:
        raise ValueError("WakaTime WinGet Windows asset does not match the release architecture")
    windows_asset = _asset(release, windows_name, expected_windows_url)
    if windows_asset["sha256"] != windows_sha256.lower():
        raise ValueError("WakaTime WinGet Windows hash differs from official release digest")

    linux_arch = "x86_64" if architecture == "x86_64" else "arm64"
    linux_name = f"wakatime-linux-{linux_arch}.AppImage"
    linux_url = _release_asset_url(tag, linux_name)
    linux_asset = _asset(release, linux_name, linux_url)
    return {
        "tag_name": tag,
        "winget_version": version,
        "published_at": published_at,
        "windows_digest_matches_winget": True,
        "linux_desktop_appimage_candidate": linux_asset,
    }


def build_dry_plan(architecture: str) -> dict[str, Any]:
    """Compare public release metadata only; no AppImage/installer/checksum bytes are read."""
    if not isinstance(architecture, str) or architecture not in {"x86_64", "aarch64"}:
        raise ValueError("WakaTime metadata review supports x86_64 or aarch64 only")
    version = _latest_version(_fetch_metadata(WINGET_INDEX_URL))
    urls = _version_urls(version)
    manifest = _fetch_metadata(urls["manifest"], version)
    version, windows_url, windows_sha256, release_tag = _installer_metadata(manifest, version, architecture)
    release_url = _release_api_url(release_tag)
    release = _fetch_metadata(release_url, version, release_tag=release_tag)
    release_info = _release_metadata(release, version, release_tag, architecture, windows_url, windows_sha256)
    windows_arch = "x64" if architecture == "x86_64" else "arm64"
    return {
        "package": {
            "name": "Wakatime.DesktopWakatime",
            "version": version,
            "version_is_restore_pin": False,
        },
        "winget_observation": {
            "architecture": windows_arch,
            "windows_url": windows_url,
            "windows_sha256": windows_sha256,
        },
        "official_release": release_info,
        "execution_blockers": [
            "AppImage contents, desktop integration, and runtime compatibility have not been reviewed",
            "GitHub asset digests are metadata, not independent signature verification",
            "WakaTime Desktop config/API-key/account state is excluded from the backup and is not imported or activated",
        ],
        "executable": False,
    }
