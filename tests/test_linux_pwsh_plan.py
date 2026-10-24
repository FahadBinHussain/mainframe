import json
import http.client
import sys
import unittest
import urllib.request
from pathlib import Path
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).parents[1]))
import pwsh_linux as pwsh

VERSION = "9.8.7"
WINDOWS_NAME = f"PowerShell-{VERSION}-win-x64.zip"
LINUX_NAME = f"powershell-{VERSION}-linux-x64.tar.gz"
WINDOWS_URL = f"https://github.com/PowerShell/PowerShell/releases/download/v{VERSION}/{WINDOWS_NAME}"
LINUX_URL = f"https://github.com/PowerShell/PowerShell/releases/download/v{VERSION}/{LINUX_NAME}"
RELEASE_URL = pwsh.RELEASE_API_PREFIX + VERSION
WINDOWS_SHA = "a" * 64
LINUX_SHA = "b" * 64
SCRIPT_MARKER = "SYNTHETIC_DO_NOT_EXECUTE_MARKER"


def manifest_bytes(*, version=VERSION, url=None, digest=WINDOWS_SHA, extra=None):
    value = {
        "version": version,
        "architecture": {"64bit": {"url": url or WINDOWS_URL, "hash": digest}},
        "pre_install": [SCRIPT_MARKER],
        "post_install": ["synthetic registry mutation text"],
        "uninstaller": {"script": ["synthetic uninstaller text"]},
        "persist": ["synthetic-profile.ps1"],
    }
    if extra:
        value.update(extra)
    return json.dumps(value).encode("utf-8")


def release_body(*, windows_sha=WINDOWS_SHA, linux_sha=LINUX_SHA, duplicate_windows=False):
    rows = [
        f"- {WINDOWS_NAME}\n - {windows_sha.upper()}",
        f"- {LINUX_NAME}\n - {linux_sha.upper()}",
    ]
    if duplicate_windows:
        rows.append(f"- {WINDOWS_NAME}\n - {windows_sha.upper()}")
    return "\n\n### SHA256 Hashes of the release artifacts\n\n" + "\n".join(rows) + "\n"


def release_bytes(*, version=VERSION, body=None, assets=None, draft=False, prerelease=False):
    if assets is None:
        assets = [
            {"name": WINDOWS_NAME, "browser_download_url": WINDOWS_URL},
            {"name": LINUX_NAME, "browser_download_url": LINUX_URL},
        ]
    value = {
        "tag_name": f"v{version}",
        "draft": draft,
        "prerelease": prerelease,
        "assets": assets,
        "body": body if body is not None else release_body(),
        "unexpected_release_notes": SCRIPT_MARKER,
    }
    return json.dumps(value).encode("utf-8")


def plan_with_metadata(manifest=None, release=None):
    mapping = {
        pwsh.SCOOP_MANIFEST: manifest if manifest is not None else manifest_bytes(),
        RELEASE_URL: release if release is not None else release_bytes(),
    }
    with patch.object(pwsh, "_fetch_metadata", side_effect=lambda url: mapping[url]) as fetch:
        plan = pwsh.build_dry_plan("x86_64")
    return plan, fetch


class PowerShellMetadataPlanTests(unittest.TestCase):
    def test_matches_exact_current_windows_and_linux_release_metadata(self):
        plan, fetch = plan_with_metadata()
        self.assertEqual(fetch.call_args_list, [unittest.mock.call(pwsh.SCOOP_MANIFEST), unittest.mock.call(RELEASE_URL)])
        self.assertEqual(plan["package"], {"name": "pwsh", "version": VERSION, "version_is_restore_pin": False})
        self.assertEqual(plan["scoop_observation"], {"url": WINDOWS_URL, "sha256": WINDOWS_SHA})
        self.assertEqual(plan["release"]["tag"], f"v{VERSION}")
        self.assertEqual(plan["linux_archive_candidate"], {
            "name": LINUX_NAME,
            "url": LINUX_URL,
            "sha256": LINUX_SHA,
        })
        self.assertFalse(plan["package_archive_downloaded"])
        self.assertFalse(plan["scripts_or_archives_executed"])
        self.assertFalse(plan["manifest_script_fields_used"])
        self.assertFalse(plan["windows_profiles_or_modules_read"])
        self.assertFalse(plan["executable"])
        self.assertEqual(plan["proposed_command"], [])

    def test_ignores_script_shaped_manifest_fields_and_release_notes(self):
        plan, _fetch = plan_with_metadata()
        serialized = json.dumps(plan)
        self.assertNotIn(SCRIPT_MARKER, serialized)
        self.assertNotIn("synthetic registry mutation text", serialized)
        self.assertNotIn("synthetic uninstaller text", serialized)
        self.assertNotIn("synthetic-profile.ps1", serialized)
        self.assertNotIn("unexpected_release_notes", serialized)

    def test_rejects_non_x64_before_any_metadata_request(self):
        with patch.object(pwsh, "_fetch_metadata") as fetch:
            with self.assertRaisesRegex(ValueError, "x86_64"):
                pwsh.build_dry_plan("aarch64")
        fetch.assert_not_called()

    def test_rejects_invalid_scoop_version_url_and_hash(self):
        cases = [
            (manifest_bytes(version="../7.6.8"), "exact stable"),
            (manifest_bytes(url="https://attacker.invalid/PowerShell-9.8.7-win-x64.zip"), "valid Windows x64 URL"),
            (manifest_bytes(digest="not-a-sha256"), "valid Windows x64 URL"),
            (manifest_bytes(extra={"architecture": []}), "exact stable"),
        ]
        for raw, message in cases:
            with self.subTest(message=message, raw=raw[:50]), self.assertRaisesRegex(ValueError, message):
                pwsh._manifest_metadata(raw)

    def test_rejects_release_tag_draft_and_prerelease_drift(self):
        cases = [
            (release_bytes(version="9.8.8"), "tag or stable-release status"),
            (release_bytes(draft=True), "tag or stable-release status"),
            (release_bytes(prerelease=True), "tag or stable-release status"),
        ]
        for raw, message in cases:
            with self.subTest(message=message), self.assertRaisesRegex(ValueError, message):
                pwsh._release_metadata(raw, VERSION)

    def test_rejects_missing_duplicate_or_wrong_release_assets(self):
        cases = [
            ([{"name": WINDOWS_NAME, "browser_download_url": WINDOWS_URL}], "asset URL is missing"),
            ([
                {"name": WINDOWS_NAME, "browser_download_url": WINDOWS_URL},
                {"name": WINDOWS_NAME, "browser_download_url": WINDOWS_URL},
                {"name": LINUX_NAME, "browser_download_url": LINUX_URL},
            ], "asset URL is missing"),
            ([
                {"name": WINDOWS_NAME, "browser_download_url": "https://attacker.invalid/file.zip"},
                {"name": LINUX_NAME, "browser_download_url": LINUX_URL},
            ], "asset URL is missing"),
        ]
        for assets, message in cases:
            with self.subTest(assets=assets), self.assertRaisesRegex(ValueError, message):
                pwsh._release_metadata(release_bytes(assets=assets), VERSION)

    def test_rejects_missing_duplicate_and_invalid_checksum_rows(self):
        bodies = [
            "- " + LINUX_NAME + "\n - " + LINUX_SHA.upper(),
            release_body(duplicate_windows=True),
            release_body(windows_sha="not-a-sha256"),
        ]
        for body in bodies:
            with self.subTest(body=body[:50]), self.assertRaises(ValueError):
                pwsh._release_metadata(release_bytes(body=body), VERSION)

    def test_rejects_scoop_checksum_that_does_not_match_release(self):
        manifest = manifest_bytes(digest="c" * 64)
        with patch.object(pwsh, "_fetch_metadata", side_effect={
            pwsh.SCOOP_MANIFEST: manifest,
            RELEASE_URL: release_bytes(),
        }.get):
            with self.assertRaisesRegex(ValueError, "does not match"):
                pwsh.build_dry_plan("x86_64")

    def test_duplicate_json_keys_fail_closed(self):
        duplicate_manifest = (
            f'{{"version":"{VERSION}","version":"9.8.8","architecture":{{"64bit":{{"url":"{WINDOWS_URL}","hash":"{WINDOWS_SHA}"}}}}}}'
        ).encode("utf-8")
        with self.assertRaisesRegex(ValueError, "Invalid official PowerShell Scoop metadata"):
            pwsh._manifest_metadata(duplicate_manifest)
        release_text = release_bytes().decode("utf-8")
        duplicate_release = release_text.replace(
            f'"tag_name": "v{VERSION}",',
            f'"tag_name": "v{VERSION}", "tag_name": "v{VERSION}",',
            1,
        ).encode("utf-8")
        with self.assertRaisesRegex(ValueError, "Invalid official PowerShell GitHub release metadata"):
            pwsh._release_metadata(duplicate_release, VERSION)

    def test_only_fixed_metadata_urls_are_accepted(self):
        with self.assertRaisesRegex(ValueError, "non-metadata"):
            pwsh._fetch_metadata(LINUX_URL)
        with self.assertRaisesRegex(ValueError, "non-metadata"):
            pwsh._fetch_metadata("https://api.github.com/repos/PowerShell/PowerShell/releases/tags/v9.8.7?query=1")

    def test_metadata_content_length_is_bounded(self):
        response = Mock()
        response.__enter__ = lambda self: self
        response.__exit__ = Mock(return_value=False)
        response.geturl.return_value = pwsh.SCOOP_MANIFEST
        response.headers = {"Content-Length": str(pwsh.SCOOP_LIMIT + 1)}
        with patch.object(urllib.request, "build_opener") as opener:
            opener.return_value.open.return_value = response
            with self.assertRaisesRegex(RuntimeError, "exceeds its size limit"):
                pwsh._fetch_metadata(pwsh.SCOOP_MANIFEST)
        response.read.assert_not_called()

    def test_streaming_metadata_limit_without_content_length(self):
        class Response:
            headers = {}

            def __init__(self, url):
                self.url = url
                self.remaining = b"x" * (pwsh.SCOOP_LIMIT + 1)

            def __enter__(self):
                return self

            def __exit__(self, *_args):
                return False

            def geturl(self):
                return self.url

            def read(self, amount):
                chunk, self.remaining = self.remaining[:amount], self.remaining[amount:]
                return chunk

        with patch.object(urllib.request, "build_opener") as opener:
            opener.return_value.open.return_value = Response(pwsh.SCOOP_MANIFEST)
            with self.assertRaisesRegex(RuntimeError, "exceeds its size limit"):
                pwsh._fetch_metadata(pwsh.SCOOP_MANIFEST)

    def test_http_protocol_errors_are_sanitized(self):
        marker = "synthetic-private-partial-payload"
        with patch.object(urllib.request, "build_opener") as opener:
            opener.return_value.open.side_effect = http.client.IncompleteRead(marker.encode(), 100)
            with self.assertRaisesRegex(RuntimeError, "metadata request failed") as caught:
                pwsh._fetch_metadata(pwsh.SCOOP_MANIFEST)
        self.assertNotIn(marker, str(caught.exception))

    def test_http_read_errors_are_sanitized(self):
        marker = "synthetic-private-read-payload"

        class BrokenResponse:
            headers = {}

            def __enter__(self):
                return self

            def __exit__(self, *_args):
                return False

            def geturl(self):
                return pwsh.SCOOP_MANIFEST

            def read(self, _amount):
                raise http.client.IncompleteRead(marker.encode(), 100)

        with patch.object(urllib.request, "build_opener") as opener:
            opener.return_value.open.return_value = BrokenResponse()
            with self.assertRaisesRegex(RuntimeError, "metadata request failed") as caught:
                pwsh._fetch_metadata(pwsh.SCOOP_MANIFEST)
        self.assertNotIn(marker, str(caught.exception))

    def test_metadata_redirects_are_refused(self):
        handler = pwsh._NoRedirect()
        with self.assertRaisesRegex(RuntimeError, "redirect refused"):
            handler.redirect_request(None, None, 302, "Found", {}, "https://attacker.invalid/")


if __name__ == "__main__":
    unittest.main()
