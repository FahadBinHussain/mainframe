#!/usr/bin/env python3
"""Metadata-only Tor Browser Linux candidate review; no archive fetcher or installer."""
from __future__ import annotations

import http.client
import json
import re
import urllib.error
import urllib.request
from html.parser import HTMLParser
from typing import Any, Mapping

SCOOP_MANIFEST = "https://raw.githubusercontent.com/ScoopInstaller/Extras/master/bucket/tor-browser.json"
TOR_ARCHIVE_PREFIX = "https://archive.torproject.org/tor-package-archive/torbrowser/"
TOR_RELEASE_BLOG_PREFIX = "https://blog.torproject.org/new-release-tor-browser-"
SCOOP_LIMIT = 64 * 1024
RELEASE_PAGE_LIMIT = 256 * 1024
DIRECTORY_LIMIT = 512 * 1024
CHECKSUM_LIMIT = 64 * 1024
TIMEOUT = 20
VERSION = re.compile(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\Z")
SHA256 = re.compile(r"[0-9a-fA-F]{64}\Z")
_VOID = {"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"}


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise RuntimeError("Official Tor Browser metadata redirect refused")


def _release_metadata_urls(version: str) -> dict[str, str]:
    if not isinstance(version, str) or not VERSION.fullmatch(version):
        raise ValueError("Invalid Tor Browser release version")
    base = TOR_ARCHIVE_PREFIX + version + "/"
    return {
        "announcement": TOR_RELEASE_BLOG_PREFIX + version.replace(".", "") + "/",
        "directory": base,
        "checksums": base + "sha256sums-signed-build.txt",
    }


def _fetch_metadata(url: str, version: str | None = None) -> bytes:
    """Read bounded bytes only from the fixed manifest or exact versioned metadata URLs."""
    if not isinstance(url, str):
        raise ValueError("Refusing non-metadata Tor Browser URL")
    if url == SCOOP_MANIFEST:
        limit = SCOOP_LIMIT
    elif isinstance(version, str):
        sources = _release_metadata_urls(version)
        limits = {
            sources["announcement"]: RELEASE_PAGE_LIMIT,
            sources["directory"]: DIRECTORY_LIMIT,
            sources["checksums"]: CHECKSUM_LIMIT,
        }
        limit = limits.get(url)
        if limit is None:
            raise ValueError("Refusing non-metadata Tor Browser URL")
    else:
        raise ValueError("Refusing non-metadata Tor Browser URL")
    request = urllib.request.Request(
        url,
        headers={
            "User-Agent": "mainframe-tor-browser-metadata/1.0",
            "Accept": "application/json, text/plain, text/html",
        },
    )
    try:
        response = urllib.request.build_opener(_NoRedirect()).open(request, timeout=TIMEOUT)
    except RuntimeError:
        raise
    except (urllib.error.URLError, http.client.HTTPException, OSError, ValueError):
        raise RuntimeError("Official Tor Browser metadata request failed") from None
    with response:
        if response.geturl() != url:
            raise RuntimeError("Official Tor Browser metadata source changed")
        length = response.headers.get("Content-Length")
        if length is not None:
            try:
                parsed_length = int(length)
            except (TypeError, ValueError):
                raise RuntimeError("Official Tor Browser metadata has invalid size") from None
            if parsed_length < 0 or parsed_length > limit:
                raise RuntimeError("Official Tor Browser metadata exceeds its size limit")
        chunks: list[bytes] = []
        total = 0
        while True:
            try:
                chunk = response.read(min(65536, limit - total + 1))
            except (urllib.error.URLError, http.client.HTTPException, OSError, ValueError):
                raise RuntimeError("Official Tor Browser metadata request failed") from None
            if not chunk:
                break
            total += len(chunk)
            if total > limit:
                raise RuntimeError("Official Tor Browser metadata exceeds its size limit")
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
        raise ValueError(f"Invalid official Tor Browser {label} metadata") from None
    if not isinstance(value, Mapping):
        raise ValueError(f"Invalid official Tor Browser {label} metadata")
    return value


def _manifest_metadata(raw: bytes) -> tuple[str, str, str]:
    manifest = _json_object(raw, "Scoop")
    version = manifest.get("version")
    architecture = manifest.get("architecture")
    win64 = architecture.get("64bit") if isinstance(architecture, Mapping) else None
    if not isinstance(version, str) or not VERSION.fullmatch(version) or not isinstance(win64, Mapping):
        raise ValueError("Scoop Tor Browser manifest lacks an exact stable Windows x64 declaration")
    filename = f"tor-browser-windows-x86_64-portable-{version}.exe"
    expected_url = f"{TOR_ARCHIVE_PREFIX}{version}/{filename}#/dl.7z"
    url, digest = win64.get("url"), win64.get("hash")
    if url != expected_url or not isinstance(digest, str) or not SHA256.fullmatch(digest):
        raise ValueError("Scoop Tor Browser manifest lacks a valid Windows x64 URL or SHA-256")
    return version, url, digest.lower()


class _HTMLMetadataParser(HTMLParser):
    """Collect only anchor hrefs and h1 text from a complete HTML document."""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.stack: list[str] = []
        self.links: list[str | None] = []
        self.headings: list[str] = []
        self.heading_parts: list[str] | None = None
        self.heading_depth: int | None = None
        self.html_seen = False
        self.html_closed = False
        self.body_seen = False
        self.body_closed = False

    def is_complete(self) -> bool:
        return (self.html_seen and self.html_closed and self.body_seen and self.body_closed and
                not self.stack and self.heading_parts is None)

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        tag = tag.lower()
        names = [name for name, _value in attrs]
        if len(names) != len(set(names)):
            raise ValueError("Duplicate Tor metadata HTML attribute")
        if self.html_closed or self.body_closed or (not self.html_seen and tag != "html"):
            raise ValueError("Malformed Tor metadata HTML document order")
        values = dict(attrs)
        if tag == "html":
            if self.html_seen or self.stack:
                raise ValueError("Duplicate or nested Tor metadata HTML document")
            self.html_seen = True
        elif tag == "body":
            if not self.html_seen or self.body_seen or not self.stack or self.stack[-1] != "html":
                raise ValueError("Malformed Tor metadata HTML body")
            self.body_seen = True
        if tag not in _VOID:
            self.stack.append(tag)
        depth = len(self.stack)
        if tag == "a" and "href" in values:
            self.links.append(values.get("href"))
        elif tag == "h1":
            if self.heading_parts is not None or not self.body_seen:
                raise ValueError("Nested or misplaced Tor metadata HTML heading")
            self.heading_parts = []
            self.heading_depth = depth

    def handle_startendtag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        tag = tag.lower()
        self.handle_starttag(tag, attrs)
        if tag not in _VOID:
            self.handle_endtag(tag)

    def handle_data(self, data: str) -> None:
        if self.heading_parts is not None:
            self.heading_parts.append(data)

    def handle_endtag(self, tag: str) -> None:
        tag = tag.lower()
        if not self.stack or self.stack[-1] != tag:
            raise ValueError("Unbalanced Tor metadata HTML document")
        depth = len(self.stack)
        if tag == "h1" and self.heading_depth == depth:
            self.headings.append(" ".join("".join(self.heading_parts or []).split()))
            self.heading_parts = None
            self.heading_depth = None
        self.stack.pop()
        if tag == "body":
            self.body_closed = True
        elif tag == "html":
            self.html_closed = True


def _html_metadata(raw: bytes, label: str) -> _HTMLMetadataParser:
    try:
        text = raw.decode("utf-8")
        parser = _HTMLMetadataParser()
        parser.feed(text)
        parser.close()
    except (UnicodeDecodeError, ValueError, RecursionError):
        raise ValueError(f"Malformed official Tor Browser {label} metadata") from None
    if not parser.is_complete():
        raise ValueError(f"Incomplete official Tor Browser {label} metadata")
    return parser


def _release_announcement(raw: bytes, version: str) -> str:
    parser = _html_metadata(raw, "release announcement")
    expected = f"New Release: Tor Browser {version}"
    if parser.headings != [expected]:
        raise ValueError("Official Tor Browser release announcement does not match Scoop version")
    return expected


def _release_filenames(version: str) -> tuple[str, str, str]:
    if not isinstance(version, str) or not VERSION.fullmatch(version):
        raise ValueError("Invalid Tor Browser release version")
    windows_name = f"tor-browser-windows-x86_64-portable-{version}.exe"
    linux_name = f"tor-browser-linux-x86_64-{version}.tar.xz"
    checksums_name = "sha256sums-signed-build.txt"
    return windows_name, linux_name, checksums_name


def _release_directory(raw: bytes, version: str) -> tuple[str, str, str]:
    parser = _html_metadata(raw, "release directory")
    windows_name, linux_name, checksums_name = _release_filenames(version)
    required = {
        windows_name, windows_name + ".asc",
        linux_name, linux_name + ".asc",
        checksums_name, checksums_name + ".asc",
    }
    counts = {name: parser.links.count(name) for name in required}
    if any(count != 1 for count in counts.values()):
        raise ValueError("Official Tor Browser release directory lacks unique versioned assets/signatures")
    return windows_name, linux_name, checksums_name


def _published_checksums(raw: bytes, version: str) -> dict[str, str]:
    windows_name, linux_name, _checksums_name = _release_filenames(version)
    wanted = {windows_name, linux_name}
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        raise ValueError("Invalid Tor Browser checksum text encoding") from None
    if "\x00" in text or len(text.splitlines()) > 2048:
        raise ValueError("Invalid Tor Browser checksum text")
    found: dict[str, str] = {}
    for line in text.splitlines():
        if not line:
            continue
        if len(line) > 512:
            raise ValueError("Invalid Tor Browser checksum line")
        match = re.fullmatch(r"([0-9a-fA-F]{64})[ \t]+([^\s]+)", line)
        if match is None:
            raise ValueError("Malformed Tor Browser checksum metadata")
        digest, name = match.groups()
        if name in wanted:
            if name in found:
                raise ValueError("Duplicate Tor Browser checksum entry")
            found[name] = digest.lower()
    if found.keys() != wanted:
        raise ValueError("Official Tor Browser checksum metadata is missing a required x86_64 asset")
    return found


def build_dry_plan(architecture: str) -> dict[str, Any]:
    """Cross-check versioned public metadata only; never fetch package/signature contents or install."""
    if architecture != "x86_64":
        raise ValueError("Tor Browser metadata review is limited to Linux x86_64")
    version, windows_url, windows_sha = _manifest_metadata(_fetch_metadata(SCOOP_MANIFEST))
    urls = _release_metadata_urls(version)
    release_note = _fetch_metadata(urls["announcement"], version)
    _release_announcement(release_note, version)
    directory = _fetch_metadata(urls["directory"], version)
    windows_name, linux_name, checksums_name = _release_directory(directory, version)
    checksums = _published_checksums(_fetch_metadata(urls["checksums"], version), version)
    if checksums[windows_name] != windows_sha:
        raise ValueError("Scoop Windows x64 checksum does not match official Tor Browser checksum metadata")
    linux_url = urls["directory"] + linux_name
    windows_signature_url = urls["directory"] + windows_name + ".asc"
    linux_signature_url = linux_url + ".asc"
    checksums_signature_url = urls["checksums"] + ".asc"
    return {
        "status": "metadata-only-blocked",
        "package": {"name": "tor-browser", "version": version, "version_is_restore_pin": False},
        "scoop_observation": {"url": windows_url, "sha256": windows_sha},
        "official_release": {
            "version": version,
            "announcement_url": urls["announcement"],
            "directory_url": urls["directory"],
        },
        "official_checksum_metadata": {
            "url": urls["checksums"],
            "signature_url": checksums_signature_url,
            "windows_x86_64_sha256": checksums[windows_name],
            "matches_scoop_manifest": True,
            "signature_verified": False,
        },
        "linux_archive_candidate": {
            "name": linux_name,
            "url": linux_url,
            "sha256": checksums[linux_name],
            "signature_url": linux_signature_url,
        },
        "windows_archive_signature_url": windows_signature_url,
        "metadata_sources": [SCOOP_MANIFEST, urls["announcement"], urls["directory"], urls["checksums"]],
        "manifest_script_fields_used": False,
        "package_or_signature_contents_downloaded": False,
        "checksum_signature_verified": False,
        "signer_key_fetched": False,
        "executable": False,
        "proposed_command": [],
        "execution_blockers": [
            "The observed Scoop version is not a user-selected restore pin.",
            "The published checksum text and detached OpenPGP signatures have not been cryptographically verified against a trusted Tor Browser Developers key.",
            "No Windows executable or Linux archive bytes/member layout were inspected; safe extraction and runtime dependencies remain unvalidated.",
            "No isolated Linux install destination or activation contract is approved.",
            "Tor Browser profile, Tor network, and account/session state are not imported.",
        ],
    }
