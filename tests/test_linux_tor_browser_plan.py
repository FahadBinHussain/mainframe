from __future__ import annotations

import http.client
import json
import unittest
import urllib.error
from unittest.mock import Mock, patch

import tor_browser_linux as tor

VERSION = "15.0.26"
WINDOWS_SHA = "37c2201f31f2fd9ea8470cf8f3cafc8dd3cd92d9ed9109b3913e1105b47d2af5"
LINUX_SHA = "327ac7443724b9eb6d3697506391b110ee159739bdc14bd731caa6fc16ffbf74"


def _names(version: str = VERSION) -> tuple[str, str, str]:
    return tor._release_filenames(version)


def _manifest(version: str = VERSION, windows_sha: str = WINDOWS_SHA, windows_url: str | None = None) -> bytes:
    windows_name, _linux_name, _checksums_name = _names(version)
    if windows_url is None:
        windows_url = f"{tor.TOR_ARCHIVE_PREFIX}{version}/{windows_name}#/dl.7z"
    value = {
        "version": version,
        "architecture": {"64bit": {"url": windows_url, "hash": windows_sha}},
        "pre_install": ["UNTRUSTED_SCRIPT_SHOULD_NEVER_BE_EVALUATED"],
        "persist": ["TorBrowser\\Data\\Browser\\profile.default"],
    }
    return json.dumps(value).encode("utf-8")


def _release_html(version: str = VERSION) -> bytes:
    return (
        "<!doctype html><html><head><title>Tor Project</title></head><body>"
        f"<main><h1>New Release: Tor Browser <span>{version}</span></h1></main>"
        "</body></html>"
    ).encode("utf-8")


def _directory_html(version: str = VERSION, duplicate: str | None = None) -> bytes:
    windows_name, linux_name, checksums_name = _names(version)
    names = [
        windows_name,
        windows_name + ".asc",
        linux_name,
        linux_name + ".asc",
        checksums_name,
        checksums_name + ".asc",
    ]
    if duplicate is not None:
        names.append(duplicate)
    links = "".join(f'<tr><td><a href="{name}">{name}</a></td></tr>' for name in names)
    return (
        "<!doctype html><html><head><title>Index</title></head><body>"
        f"<h1>Index of Tor Browser {version}</h1><table>{links}</table>"
        "</body></html>"
    ).encode("utf-8")


def _checksums(version: str = VERSION, windows_sha: str = WINDOWS_SHA, linux_sha: str = LINUX_SHA) -> bytes:
    windows_name, linux_name, _checksums_name = _names(version)
    return f"{windows_sha} {windows_name}\n{linux_sha} {linux_name}\n".encode("ascii")


def _metadata_payloads(version: str = VERSION) -> dict[str, bytes]:
    urls = tor._release_metadata_urls(version)
    return {
        tor.SCOOP_MANIFEST: _manifest(version),
        urls["announcement"]: _release_html(version),
        urls["directory"]: _directory_html(version),
        urls["checksums"]: _checksums(version),
    }


class _Response:
    def __init__(self, url: str, body: bytes, headers: dict[str, str] | None = None,
                 read_error: BaseException | None = None, final_url: str | None = None):
        self.url = url
        self.body = body
        self.headers = headers or {}
        self.read_error = read_error
        self.final_url = final_url or url
        self.offset = 0
        self.read_called = False

    def __enter__(self):
        return self

    def __exit__(self, _kind, _value, _traceback):
        return False

    def geturl(self) -> str:
        return self.final_url

    def read(self, size: int) -> bytes:
        self.read_called = True
        if self.read_error is not None:
            raise self.read_error
        if self.offset >= len(self.body):
            return b""
        part = self.body[self.offset:self.offset + size]
        self.offset += len(part)
        return part


class TorBrowserMetadataTests(unittest.TestCase):
    def _plan(self, payloads: dict[str, bytes] | None = None):
        sources = payloads or _metadata_payloads()
        calls: list[tuple[str, str | None]] = []

        def fetch(url: str, version: str | None = None) -> bytes:
            calls.append((url, version))
            return sources[url]

        with patch.object(tor, "_fetch_metadata", side_effect=fetch):
            plan = tor.build_dry_plan("x86_64")
        return plan, calls

    def test_matches_same_version_windows_checksum_and_linux_candidate_without_artifact_fetch(self):
        plan, calls = self._plan()
        urls = tor._release_metadata_urls(VERSION)
        windows_name, linux_name, checksums_name = _names()
        self.assertEqual(
            calls,
            [
                (tor.SCOOP_MANIFEST, None),
                (urls["announcement"], VERSION),
                (urls["directory"], VERSION),
                (urls["checksums"], VERSION),
            ],
        )
        self.assertTrue(all(not any(ext in url for ext in (".exe", ".tar.xz", ".asc")) for url, _version in calls))
        self.assertEqual(plan["package"], {"name": "tor-browser", "version": VERSION, "version_is_restore_pin": False})
        self.assertEqual(plan["scoop_observation"]["sha256"], WINDOWS_SHA)
        self.assertEqual(plan["official_checksum_metadata"]["windows_x86_64_sha256"], WINDOWS_SHA)
        self.assertTrue(plan["official_checksum_metadata"]["matches_scoop_manifest"])
        self.assertFalse(plan["official_checksum_metadata"]["signature_verified"])
        self.assertEqual(plan["linux_archive_candidate"]["name"], linux_name)
        self.assertEqual(plan["linux_archive_candidate"]["url"], urls["directory"] + linux_name)
        self.assertEqual(plan["linux_archive_candidate"]["sha256"], LINUX_SHA)
        self.assertEqual(plan["linux_archive_candidate"]["signature_url"], urls["directory"] + linux_name + ".asc")
        self.assertEqual(plan["windows_archive_signature_url"], urls["directory"] + windows_name + ".asc")
        self.assertEqual(plan["official_checksum_metadata"]["signature_url"], urls["checksums"] + ".asc")
        self.assertFalse(plan["manifest_script_fields_used"])
        self.assertFalse(plan["package_or_signature_contents_downloaded"])
        self.assertFalse(plan["checksum_signature_verified"])
        self.assertFalse(plan["signer_key_fetched"])
        self.assertFalse(plan["executable"])
        self.assertEqual(plan["proposed_command"], [])
        serialized = json.dumps(plan)
        self.assertNotIn("UNTRUSTED_SCRIPT_SHOULD_NEVER_BE_EVALUATED", serialized)
        self.assertNotIn("TorBrowser\\Data\\Browser\\profile.default", serialized)
        self.assertIn(checksums_name, plan["metadata_sources"][3])
        self.assertTrue(plan["execution_blockers"])

    def test_architecture_is_rejected_before_any_metadata_request(self):
        with patch.object(tor, "_fetch_metadata") as fetch:
            with self.assertRaisesRegex(ValueError, "x86_64"):
                tor.build_dry_plan("aarch64")
        fetch.assert_not_called()

    def test_manifest_rejects_duplicate_json_keys(self):
        raw = (
            b'{"version":"15.0.26","version":"15.0.25",'
            b'"architecture":{"64bit":{"url":"x","hash":"' + WINDOWS_SHA.encode() + b'"}}}'
        )
        with self.assertRaisesRegex(ValueError, "Invalid official Tor Browser Scoop"):
            tor._manifest_metadata(raw)

    def test_manifest_rejects_unstable_version_or_unexpected_windows_url(self):
        unstable = json.dumps({
            "version": "15.0.26-alpha",
            "architecture": {"64bit": {"url": "https://archive.torproject.org/tor-package-archive/torbrowser/15.0.26/tor-browser-windows-x86_64-portable-15.0.26.exe#/dl.7z", "hash": WINDOWS_SHA}},
        }).encode("utf-8")
        with self.assertRaisesRegex(ValueError, "exact stable Windows x64"):
            tor._manifest_metadata(unstable)
        url = f"{tor.TOR_ARCHIVE_PREFIX}{VERSION}/other.exe#/dl.7z"
        with self.assertRaisesRegex(ValueError, "valid Windows x64 URL"):
            tor._manifest_metadata(_manifest(windows_url=url))

    def test_manifest_rejects_invalid_sha256(self):
        with self.assertRaisesRegex(ValueError, "valid Windows x64 URL or SHA-256"):
            tor._manifest_metadata(_manifest(windows_sha="not-a-hash"))

    def test_release_announcement_must_name_the_manifest_version(self):
        payloads = _metadata_payloads()
        url = tor._release_metadata_urls(VERSION)["announcement"]
        payloads[url] = _release_html("15.0.25")
        with self.assertRaisesRegex(ValueError, "does not match Scoop version"):
            self._plan(payloads)

    def test_release_directory_requires_unique_asset_and_signature_links(self):
        with self.assertRaisesRegex(ValueError, "lacks unique versioned assets/signatures"):
            tor._release_directory(_directory_html().replace(b"tor-browser-linux-x86_64-15.0.26.tar.xz.asc", b"missing.asc"), VERSION)
        linux_name = _names()[1]
        with self.assertRaisesRegex(ValueError, "lacks unique versioned assets/signatures"):
            tor._release_directory(_directory_html(duplicate=linux_name), VERSION)

    def test_directory_and_release_parsers_reject_truncated_or_unbalanced_html(self):
        with self.assertRaisesRegex(ValueError, "Incomplete official Tor Browser"):
            tor._release_announcement(b"<html><body><h1>New Release: Tor Browser 15.0.26</h1>", VERSION)
        with self.assertRaisesRegex(ValueError, "Malformed official Tor Browser"):
            tor._release_directory(b"<html><body></html>", VERSION)

    def test_checksum_parser_requires_exact_unique_windows_and_linux_entries(self):
        windows_name, _linux_name, _checksums_name = _names()
        missing_linux = f"{WINDOWS_SHA} {windows_name}\n".encode("ascii")
        with self.assertRaisesRegex(ValueError, "missing a required"):
            tor._published_checksums(missing_linux, VERSION)
        duplicate = _checksums() + f"{WINDOWS_SHA} {windows_name}\n".encode()
        with self.assertRaisesRegex(ValueError, "Duplicate Tor Browser checksum"):
            tor._published_checksums(duplicate, VERSION)
        with self.assertRaisesRegex(ValueError, "Malformed Tor Browser checksum"):
            tor._published_checksums(b"not a checksum line\n", VERSION)

    def test_scoop_checksum_mismatch_fails_closed(self):
        payloads = _metadata_payloads()
        urls = tor._release_metadata_urls(VERSION)
        payloads[urls["checksums"]] = _checksums(windows_sha="0" * 64)
        with self.assertRaisesRegex(ValueError, "does not match official Tor Browser"):
            self._plan(payloads)

    def test_fetch_metadata_rejects_artifact_and_external_urls(self):
        for url in (
            f"{tor.TOR_ARCHIVE_PREFIX}{VERSION}/tor-browser-linux-x86_64-{VERSION}.tar.xz",
            "https://example.invalid/manifest.json",
        ):
            with self.subTest(url=url), self.assertRaisesRegex(ValueError, "Refusing non-metadata"):
                tor._fetch_metadata(url, VERSION)

    def test_fetch_metadata_rejects_redirect_and_changed_response_url(self):
        url = tor.SCOOP_MANIFEST
        handler = tor._NoRedirect()
        with self.assertRaisesRegex(RuntimeError, "redirect refused"):
            handler.redirect_request(Mock(), None, 302, "Found", {}, "https://example.invalid/manifest")
        response = _Response(url, b"{}", final_url="https://example.invalid/manifest")
        opener = Mock()
        opener.open.return_value = response
        with patch.object(tor.urllib.request, "build_opener", return_value=opener):
            with self.assertRaisesRegex(RuntimeError, "source changed"):
                tor._fetch_metadata(url)

    def test_fetch_metadata_enforces_streaming_size_limit(self):
        url = tor.SCOOP_MANIFEST
        response = _Response(url, b"x" * (tor.SCOOP_LIMIT + 1))
        opener = Mock()
        opener.open.return_value = response
        with patch.object(tor.urllib.request, "build_opener", return_value=opener):
            with self.assertRaisesRegex(RuntimeError, "exceeds its size limit"):
                tor._fetch_metadata(url)

    def test_fetch_metadata_sanitizes_transport_and_partial_body_errors(self):
        url = tor.SCOOP_MANIFEST
        opener = Mock()
        opener.open.side_effect = urllib.error.URLError("SYNTHETIC-SECRET-TRANSPORT-MARKER")
        with patch.object(tor.urllib.request, "build_opener", return_value=opener):
            with self.assertRaisesRegex(RuntimeError, "metadata request failed") as caught:
                tor._fetch_metadata(url)
        self.assertNotIn("SYNTHETIC-SECRET-TRANSPORT-MARKER", str(caught.exception))

        response = _Response(url, b"", read_error=http.client.IncompleteRead(b"SYNTHETIC-SECRET-BODY-MARKER", 50))
        opener = Mock()
        opener.open.return_value = response
        with patch.object(tor.urllib.request, "build_opener", return_value=opener):
            with self.assertRaisesRegex(RuntimeError, "metadata request failed") as caught:
                tor._fetch_metadata(url)
        self.assertNotIn("SYNTHETIC-SECRET-BODY-MARKER", str(caught.exception))

    def test_fetch_metadata_rejects_declared_oversize_before_reading(self):
        url = tor.SCOOP_MANIFEST
        response = _Response(url, b"ignored", headers={"Content-Length": str(tor.SCOOP_LIMIT + 1)})
        opener = Mock()
        opener.open.return_value = response
        with patch.object(tor.urllib.request, "build_opener", return_value=opener):
            with self.assertRaisesRegex(RuntimeError, "exceeds its size limit"):
                tor._fetch_metadata(url)
        self.assertFalse(response.read_called)


if __name__ == "__main__":
    unittest.main()
