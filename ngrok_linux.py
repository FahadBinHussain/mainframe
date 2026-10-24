#!/usr/bin/env python3
"""Metadata-only ngrok Linux candidate review; no binary fetcher or installer."""
from __future__ import annotations

import json
import re
import urllib.error
import urllib.request
from html.parser import HTMLParser
from typing import Any, Mapping
from urllib.parse import urlsplit

SCOOP_MANIFEST = "https://raw.githubusercontent.com/ScoopInstaller/Main/master/bucket/ngrok.json"
ARCHIVE_INDEX = "https://ngrok.com/download/archive/ngrok/ngrok-v3/stable/ngrok_archive"
SCOOP_LIMIT = 1024 * 1024
ARCHIVE_INDEX_LIMIT = 2 * 1024 * 1024
TIMEOUT = 20
VERSION = re.compile(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\Z")
SHA256 = re.compile(r"[0-9a-fA-F]{64}\Z")
_VOID = {"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"}


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise RuntimeError("Official metadata redirect refused")


def _fetch_metadata(url: str) -> bytes:
    """Fetch only one of two fixed public metadata URLs, with bounded bytes."""
    limits = {SCOOP_MANIFEST: SCOOP_LIMIT, ARCHIVE_INDEX: ARCHIVE_INDEX_LIMIT}
    if not isinstance(url, str) or url not in limits:
        raise ValueError("Refusing non-metadata ngrok URL")
    limit = limits[url]
    request = urllib.request.Request(
        url,
        headers={"User-Agent": "mainframe-ngrok-metadata/1.0", "Accept": "application/json, text/plain, text/html"},
    )
    try:
        response = urllib.request.build_opener(_NoRedirect()).open(request, timeout=TIMEOUT)
    except RuntimeError:
        raise
    except (urllib.error.URLError, OSError, ValueError):
        raise RuntimeError("Official ngrok metadata request failed") from None
    with response:
        if response.geturl() != url:
            raise RuntimeError("Official ngrok metadata source changed")
        length = response.headers.get("Content-Length")
        if length is not None:
            try:
                if int(length) < 0 or int(length) > limit:
                    raise RuntimeError("Official ngrok metadata exceeds its size limit")
            except (TypeError, ValueError):
                raise RuntimeError("Official ngrok metadata has invalid size") from None
        chunks: list[bytes] = []
        total = 0
        while True:
            try:
                chunk = response.read(min(65536, limit - total + 1))
            except (urllib.error.URLError, OSError, ValueError):
                raise RuntimeError("Official ngrok metadata request failed") from None
            if not chunk:
                break
            total += len(chunk)
            if total > limit:
                raise RuntimeError("Official ngrok metadata exceeds its size limit")
            chunks.append(chunk)
        return b"".join(chunks)


class _ArchiveIndexParser(HTMLParser):
    """Extract release/platform/archive rows from ngrok's published HTML table."""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.stack: list[tuple[str, set[str]]] = []
        self.releases: list[dict[str, Any]] = []
        self.release: dict[str, Any] | None = None
        self.release_depth: int | None = None
        self.platform: dict[str, Any] | None = None
        self.platform_depth: int | None = None
        self.entry: dict[str, Any] | None = None
        self.entry_depth: int | None = None
        self.capture: tuple[str, str, int] | None = None
        self.capture_buffer: list[str] = []
        self.html_seen = False
        self.html_closed = False
        self.body_seen = False
        self.body_closed = False

    def is_complete(self) -> bool:
        return (self.html_seen and self.html_closed and self.body_seen and self.body_closed and
                not self.stack and self.release is None and self.platform is None and
                self.entry is None and self.capture is None)

    def _begin_capture(self, field: str, tag: str, depth: int) -> None:
        if self.capture is not None:
            raise ValueError("Malformed ngrok archive-index field nesting")
        self.capture = (field, tag, depth)
        self.capture_buffer = []

    def _capture_entry_field(self, field: str, tag: str, depth: int) -> None:
        if self.entry is None or field in self.entry["seen_fields"]:
            raise ValueError("Duplicate or misplaced ngrok archive-index field")
        self.entry["seen_fields"].add(field)
        self._begin_capture(field, tag, depth)

    def _finish_capture(self) -> None:
        assert self.capture is not None
        field, _tag, _depth = self.capture
        value = "".join(self.capture_buffer).strip()
        if field == "version" and self.release is not None:
            match = re.fullmatch(r"Version\s+([0-9]+\.[0-9]+\.[0-9]+)", value)
            self.release["version"] = match.group(1) if match else None
        elif field == "platform_name" and self.platform is not None:
            self.platform["name"] = value
        elif field in {"archive", "arch", "checksum_label"} and self.entry is not None:
            self.entry[field] = value
        self.capture = None
        self.capture_buffer = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        tag = tag.lower()
        attribute_names = [name for name, _value in attrs]
        if len(attribute_names) != len(set(attribute_names)):
            raise ValueError("Duplicate ngrok archive-index attribute")
        if self.html_closed or self.body_closed or (not self.html_seen and tag != "html"):
            raise ValueError("Malformed ngrok archive-index document order")
        values = dict(attrs)
        classes = set((values.get("class") or "").split())
        if tag == "html":
            if self.html_seen or self.stack:
                raise ValueError("Duplicate or nested ngrok archive-index document")
            self.html_seen = True
        elif tag == "body":
            if (not self.html_seen or self.body_seen or not self.stack or
                    self.stack[-1][0] != "html"):
                raise ValueError("Malformed ngrok archive-index body")
            self.body_seen = True
        if tag not in _VOID:
            self.stack.append((tag, classes))
        depth = len(self.stack)
        if tag == "div" and "release" in classes:
            if self.release is not None or not self.body_seen:
                raise ValueError("Nested or misplaced ngrok archive-index release")
            self.release = {"version": None, "version_seen": False, "platforms": []}
            self.release_depth = depth
            self.releases.append(self.release)
        elif tag == "h2" and self.release is not None:
            if self.release["version_seen"]:
                raise ValueError("Duplicate ngrok archive-index release version")
            self.release["version_seen"] = True
            self._begin_capture("version", tag, depth)
        elif tag == "div" and {"platform", "archive"}.issubset(classes) and self.release is not None:
            if self.platform is not None or self.entry is not None:
                raise ValueError("Nested ngrok archive-index platform")
            self.platform = {"name": "", "name_seen": False, "entries": []}
            self.platform_depth = depth
            self.release["platforms"].append(self.platform)
        elif (tag == "span" and self.platform is not None and
              any("logo" in parent_classes for _parent_tag, parent_classes in self.stack[:-1])):
            if self.platform["name_seen"]:
                raise ValueError("Duplicate ngrok archive-index platform name")
            self.platform["name_seen"] = True
            self._begin_capture("platform_name", tag, depth)
        elif tag == "div" and "link" in classes and self.platform is not None:
            if self.entry is not None:
                raise ValueError("Nested ngrok archive-index asset row")
            self.entry = {"url": None, "archive": "", "arch": "", "sha_values": [],
                          "checksum_label": "", "seen_fields": set()}
            self.entry_depth = depth
            self.platform["entries"].append(self.entry)
        elif tag == "a" and self.entry is not None and "href" in values:
            if self.entry["url"] is not None:
                self.entry["url_duplicate"] = True
            else:
                self.entry["url"] = values["href"]
        elif tag == "div" and self.entry is not None and "archive" in classes:
            self._capture_entry_field("archive", tag, depth)
        elif tag == "div" and self.entry is not None and "arch" in classes:
            self._capture_entry_field("arch", tag, depth)
        elif tag == "div" and self.entry is not None and "checksum-label" in classes:
            self._capture_entry_field("checksum_label", tag, depth)
        elif tag == "input" and self.entry is not None and any("sha" in parent_classes for _parent_tag, parent_classes in self.stack):
            self.entry["sha_values"].append(values.get("value"))

    def handle_startendtag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        tag = tag.lower()
        self.handle_starttag(tag, attrs)
        if tag not in _VOID:
            self.handle_endtag(tag)

    def handle_data(self, data: str) -> None:
        if self.capture is not None:
            self.capture_buffer.append(data)

    def handle_endtag(self, tag: str) -> None:
        tag = tag.lower()
        if not self.stack or self.stack[-1][0] != tag:
            raise ValueError("Unbalanced ngrok archive-index document")
        depth = len(self.stack)
        if self.capture is not None and self.capture[1] == tag and self.capture[2] == depth:
            self._finish_capture()
        if tag == "div":
            if self.entry is not None and self.entry_depth == depth:
                self.entry = None
                self.entry_depth = None
            if self.platform is not None and self.platform_depth == depth:
                self.platform = None
                self.platform_depth = None
            if self.release is not None and self.release_depth == depth:
                self.release = None
                self.release_depth = None
        self.stack.pop()
        if tag == "body":
            self.body_closed = True
        elif tag == "html":
            self.html_closed = True


def _manifest_metadata(raw: bytes) -> tuple[str, str, str]:
    try:
        manifest = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        raise ValueError("Invalid Scoop ngrok manifest metadata") from None
    if not isinstance(manifest, Mapping):
        raise ValueError("Invalid Scoop ngrok manifest metadata")
    version = manifest.get("version")
    architecture = manifest.get("architecture")
    win64 = architecture.get("64bit") if isinstance(architecture, Mapping) else None
    if (not isinstance(version, str) or not VERSION.fullmatch(version) or
            not isinstance(win64, Mapping)):
        raise ValueError("Scoop ngrok manifest lacks an exact stable Windows x64 declaration")
    url, digest = win64.get("url"), win64.get("hash")
    if not isinstance(url, str) or not isinstance(digest, str) or not SHA256.fullmatch(digest):
        raise ValueError("Scoop ngrok manifest lacks a valid Windows x64 URL or SHA-256")
    _validate_asset_url(url, version, "windows", "zip")
    return version, url, digest.lower()


def _validate_asset_url(url: Any, version: str, platform_name: str, suffix: str) -> str:
    if not isinstance(url, str):
        raise ValueError("ngrok archive URL is missing")
    try:
        parsed = urlsplit(url)
        port = parsed.port
    except (TypeError, ValueError):
        raise ValueError("ngrok archive URL is invalid") from None
    if (parsed.scheme != "https" or parsed.netloc != "bin.ngrok.com" or port is not None or
            parsed.username or parsed.password or parsed.query or parsed.fragment):
        raise ValueError("ngrok archive URL is not an approved vendor URL")
    pattern = rf"/a/[A-Za-z0-9]+/ngrok-v3-{re.escape(version)}-{platform_name}-amd64\.{re.escape(suffix)}"
    if not re.fullmatch(pattern, parsed.path):
        raise ValueError("ngrok archive URL does not match the selected product, version, platform and format")
    return url


def _archive_release(raw: bytes, version: str) -> dict[str, Any]:
    try:
        page = raw.decode("utf-8")
        parser = _ArchiveIndexParser()
        parser.feed(page)
        parser.close()
        if not parser.is_complete():
            raise ValueError("Incomplete ngrok archive-index document")
    except (UnicodeDecodeError, ValueError):
        raise ValueError("Invalid ngrok official archive index") from None
    matches = [release for release in parser.releases if release.get("version") == version]
    if len(matches) != 1:
        raise ValueError("Scoop ngrok version is missing or ambiguous in the official stable archive index")
    return matches[0]


def _asset(release: Mapping[str, Any], platform_name: str, archive: str, arch: str, version: str) -> dict[str, str]:
    if platform_name not in {"Windows", "Linux"} or archive not in {".zip", ".tar.gz"} or arch != "64-bit":
        raise ValueError("Unsupported ngrok archive-index selection")
    entries = [entry for platform in release.get("platforms", [])
               if isinstance(platform, Mapping) and platform.get("name", "").casefold() == platform_name.casefold()
               for entry in platform.get("entries", [])
               if isinstance(entry, Mapping) and entry.get("archive") == archive and entry.get("arch") == arch]
    if len(entries) != 1:
        raise ValueError("Official ngrok archive index has missing or ambiguous target metadata")
    entry = entries[0]
    values = entry.get("sha_values", [])
    if (entry.get("checksum_label") != "SHA256" or len(values) != 1 or
            not isinstance(values[0], str) or not SHA256.fullmatch(values[0]) or entry.get("url_duplicate")):
        raise ValueError("Official ngrok archive index lacks a unique valid SHA-256 record")
    platform_slug = "linux" if platform_name == "Linux" else "windows"
    format_slug = "tar.gz" if archive == ".tar.gz" else "zip"
    url = _validate_asset_url(entry.get("url"), version, platform_slug, format_slug)
    return {"url": url, "sha256": values[0].lower(), "archive": archive, "architecture_label": arch}


def build_dry_plan(architecture: str) -> dict[str, Any]:
    """Compare public version/checksum metadata only; never fetch an ngrok archive."""
    if architecture != "x86_64":
        raise ValueError("ngrok metadata review is limited to Linux x86_64")
    version, windows_url, windows_sha = _manifest_metadata(_fetch_metadata(SCOOP_MANIFEST))
    release = _archive_release(_fetch_metadata(ARCHIVE_INDEX), version)
    windows = _asset(release, "Windows", ".zip", "64-bit", version)
    linux = _asset(release, "Linux", ".tar.gz", "64-bit", version)
    if windows["url"] != windows_url or windows["sha256"] != windows_sha:
        raise ValueError("Scoop Windows source or checksum disagrees with the official ngrok archive index")
    return {
        "status": "dry-only",
        "executable": False,
        "proposed_command": [],
        "package": {
            "name": "ngrok",
            "version": version,
            "version_source": SCOOP_MANIFEST,
            "version_is_user_pinned": False,
        },
        "windows_manifest_observation": {
            "url": windows_url,
            "sha256": windows_sha,
            "source": SCOOP_MANIFEST,
        },
        "official_archive_index": ARCHIVE_INDEX,
        "windows_archive_index_match": windows,
        "linux_archive_candidate": linux,
        "artifact_review": "Public metadata only; no Linux archive bytes or member layout were inspected; SHA-256 is publisher metadata, not local verification.",
        "installation": {
            "enabled": False,
            "activation_in_plan": False,
            "account_or_agent_config_read": False,
            "service_or_path_changes": False,
        },
        "execution_blockers": [
            "The current Scoop version is an observation, not a user-selected restore pin.",
            "The Linux archive member layout and a bounded no-replace extractor have not been validated.",
            "No binary was downloaded, installed, executed or runtime-tested; token/profile setup remains separate.",
        ],
    }
