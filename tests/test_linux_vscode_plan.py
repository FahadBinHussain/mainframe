import json
import sys
import unittest
import urllib.request
from pathlib import Path
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).parents[1]))
import vscode_linux as vscode

VERSION = "1.2.3"
COMMIT = "a" * 40
WINDOWS_SHA = "b" * 64
LINUX_SHA = "c" * 64
WINDOWS_API = vscode._api_url(VERSION, "win32-x64-archive")
LINUX_API = vscode._api_url(VERSION, "linux-x64")
WINDOWS_ARTIFACT = f"https://{vscode.DOWNLOAD_HOST}/dbazure/download/stable/{COMMIT}/VSCode-win32-x64-{VERSION}.zip"
LINUX_ARTIFACT = f"https://{vscode.DOWNLOAD_HOST}/dbazure/download/stable/{COMMIT}/code-stable-x64-1234567890.tar.gz"
UNTRUSTED_MARKER = "SYNTHETIC_DO_NOT_RUN_MANIFEST_SCRIPT"


def _manifest_bytes(**overrides):
    manifest = {
        "version": VERSION,
        "description": "synthetic fixture",
        "architecture": {
            "64bit": {
                "url": f"https://update.code.visualstudio.com/{VERSION}/win32-x64-archive/stable#/dl.7z",
                "hash": WINDOWS_SHA,
            },
            "arm64": {"url": "https://invalid.example/unused", "hash": "0" * 64},
        },
        "pre_install": UNTRUSTED_MARKER,
        "persist": {"data": "synthetic Windows profile path"},
        "unknown_vendor_field": {"nested": True},
    }
    manifest.update(overrides)
    return json.dumps(manifest, separators=(",", ":")).encode()


def _api_bytes(platform, **overrides):
    if platform == "win32-x64-archive":
        data = {
            "name": VERSION,
            "productVersion": VERSION,
            "version": COMMIT,
            "sha256hash": WINDOWS_SHA,
            "url": WINDOWS_ARTIFACT,
            "untrusted_note": UNTRUSTED_MARKER,
        }
    else:
        data = {
            "name": VERSION,
            "productVersion": VERSION,
            "version": COMMIT,
            "sha256hash": LINUX_SHA,
            "url": LINUX_ARTIFACT,
            "untrusted_note": UNTRUSTED_MARKER,
        }
    data.update(overrides)
    return json.dumps(data, separators=(",", ":")).encode()


class FakeResponse:
    def __init__(self, url, body, content_type="application/json", content_length=True,
                 status=200, declared_length=None):
        self.url = url
        self.body = body
        self.offset = 0
        self.status = status
        self.headers = {"Content-Type": content_type}
        if content_length:
            self.headers["Content-Length"] = str(len(body) if declared_length is None else declared_length)

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return False

    def geturl(self):
        return self.url

    def getcode(self):
        return self.status

    def read(self, amount=-1):
        if amount < 0:
            amount = len(self.body) - self.offset
        result = self.body[self.offset:self.offset + amount]
        self.offset += len(result)
        return result


class VSCodeMetadataPlanTests(unittest.TestCase):
    def _sources(self, manifest=None, windows=None, linux=None):
        sources = {
            vscode.SCOOP_MANIFEST_URL: _manifest_bytes() if manifest is None else manifest,
            WINDOWS_API: _api_bytes("win32-x64-archive") if windows is None else windows,
            LINUX_API: _api_bytes("linux-x64") if linux is None else linux,
        }
        opener = Mock()
        opener.open.side_effect = lambda request, timeout: FakeResponse(request.full_url, sources[request.full_url])
        return sources, opener

    def test_build_dry_plan_matches_windows_hash_and_linux_same_commit_without_artifact_requests(self):
        sources, opener = self._sources()
        with patch.object(vscode.urllib.request, "build_opener", return_value=opener):
            plan = vscode.build_dry_plan("x86_64")
        requested = [call.args[0].full_url for call in opener.open.call_args_list]
        self.assertEqual(requested, [vscode.SCOOP_MANIFEST_URL, WINDOWS_API, LINUX_API])
        self.assertEqual(set(sources), set(requested))
        self.assertEqual(plan["package"], {
            "name": "vscode", "version": VERSION, "source": "scoop", "version_is_restore_pin": False,
        })
        self.assertEqual(plan["windows_declaration"]["sha256"], WINDOWS_SHA)
        self.assertTrue(plan["windows_declaration"]["checksum_matches_microsoft"])
        self.assertEqual(plan["official_build"]["commit"], COMMIT)
        self.assertEqual(plan["linux_archive_candidate"]["url"], LINUX_ARTIFACT)
        self.assertEqual(plan["linux_archive_candidate"]["sha256"], LINUX_SHA)
        self.assertEqual(plan["linux_archive_candidate"]["format"], "tar.gz")
        self.assertFalse(plan["executable"])
        self.assertFalse(plan["terms"]["accepted_for_this_review"])
        self.assertNotIn(UNTRUSTED_MARKER, json.dumps(plan))

    def test_non_x64_architecture_fails_before_metadata_requests(self):
        with patch.object(vscode.urllib.request, "build_opener") as opener:
            with self.assertRaisesRegex(ValueError, "limited to Linux x86_64"):
                vscode.build_dry_plan("aarch64")
        opener.assert_not_called()

    def test_duplicate_json_keys_are_rejected(self):
        raw = b'{"version":"1.2.3","version":"9.9.9"}'
        with self.assertRaisesRegex(ValueError, "Invalid official VS Code Scoop metadata"):
            vscode._manifest_metadata(raw)
        with self.assertRaisesRegex(ValueError, "Invalid official VS Code Scoop metadata"):
            vscode._json_object(b'{"unknown":NaN}', "Scoop")

    def test_invalid_manifest_versions_urls_and_hashes_fail_closed(self):
        bad_version = json.dumps({"version": "1.2.3/../latest", "architecture": {"64bit": {}}}).encode()
        with self.assertRaisesRegex(ValueError, "exact stable Windows x64"):
            vscode._manifest_metadata(bad_version)
        manifest = json.loads(_manifest_bytes())
        manifest["architecture"]["64bit"]["url"] = "https://evil.example/artifact.zip"
        with self.assertRaisesRegex(ValueError, "valid Windows x64 URL or SHA-256"):
            vscode._manifest_metadata(json.dumps(manifest).encode())
        manifest = json.loads(_manifest_bytes())
        manifest["architecture"]["64bit"]["hash"] = "not-a-digest"
        with self.assertRaisesRegex(ValueError, "valid Windows x64 URL or SHA-256"):
            vscode._manifest_metadata(json.dumps(manifest).encode())

    def test_windows_api_digest_must_match_scoop_manifest(self):
        _, opener = self._sources(windows=_api_bytes("win32-x64-archive", sha256hash="d" * 64))
        with patch.object(vscode.urllib.request, "build_opener", return_value=opener):
            with self.assertRaisesRegex(ValueError, "does not match Microsoft's version metadata"):
                vscode.build_dry_plan("x86_64")

    def test_linux_build_commit_must_match_windows(self):
        other_commit = "e" * 40
        other_url = f"https://{vscode.DOWNLOAD_HOST}/dbazure/download/stable/{other_commit}/code-stable-x64-1234567890.tar.gz"
        _, opener = self._sources(linux=_api_bytes("linux-x64", version=other_commit, url=other_url))
        with patch.object(vscode.urllib.request, "build_opener", return_value=opener):
            with self.assertRaisesRegex(ValueError, "different build commit"):
                vscode.build_dry_plan("x86_64")

    def test_version_api_identity_commit_digest_and_artifact_url_are_validated(self):
        for mutation in (
            {"productVersion": "9.9.9"},
            {"version": "not-a-commit"},
            {"sha256hash": "bad"},
            {"url": f"https://evil.example/dbazure/download/stable/{COMMIT}/code-stable-x64-1234567890.tar.gz"},
            {"url": LINUX_ARTIFACT.replace("code-stable-x64", "code-stable-\nx64")},
        ):
            with self.subTest(mutation=mutation):
                raw = _api_bytes("linux-x64", **mutation)
                with self.assertRaises(ValueError):
                    vscode._version_metadata(raw, VERSION, "linux-x64")

    def test_artifact_urls_are_not_in_metadata_request_allowlist(self):
        with patch.object(vscode.urllib.request, "build_opener") as opener:
            with self.assertRaisesRegex(ValueError, "Refusing non-metadata VS Code URL"):
                vscode._fetch_metadata(LINUX_ARTIFACT)
        opener.assert_not_called()

    def test_metadata_response_size_and_content_type_are_bounded(self):
        opener = Mock()
        opener.open.return_value = FakeResponse(WINDOWS_API, b"", content_length=False)
        opener.open.return_value.headers["Content-Length"] = str(vscode.API_LIMIT + 1)
        with patch.object(vscode.urllib.request, "build_opener", return_value=opener):
            with self.assertRaisesRegex(RuntimeError, "exceeds its size limit"):
                vscode._fetch_metadata(WINDOWS_API)
        opener.open.return_value = FakeResponse(WINDOWS_API, b"{}", content_type="text/html")
        with patch.object(vscode.urllib.request, "build_opener", return_value=opener):
            with self.assertRaisesRegex(RuntimeError, "unexpected content type"):
                vscode._fetch_metadata(WINDOWS_API)
        opener.open.return_value = FakeResponse(
            WINDOWS_API, b"x" * (vscode.API_LIMIT + 1), content_length=False,
        )
        with patch.object(vscode.urllib.request, "build_opener", return_value=opener):
            with self.assertRaisesRegex(RuntimeError, "exceeds its size limit"):
                vscode._fetch_metadata(WINDOWS_API)

    def test_metadata_http_status_and_content_length_framing_are_checked(self):
        opener = Mock()
        opener.open.return_value = FakeResponse(WINDOWS_API, b"{}", status=503)
        with patch.object(vscode.urllib.request, "build_opener", return_value=opener):
            with self.assertRaisesRegex(RuntimeError, "response was not successful"):
                vscode._fetch_metadata(WINDOWS_API)
        for body, declared_length in ((b"{}", 3), (b"{}x", 2)):
            with self.subTest(body=body, declared_length=declared_length):
                opener.open.return_value = FakeResponse(
                    WINDOWS_API, body, declared_length=declared_length,
                )
                with patch.object(vscode.urllib.request, "build_opener", return_value=opener):
                    with self.assertRaisesRegex(RuntimeError, "does not match Content-Length"):
                        vscode._fetch_metadata(WINDOWS_API)

    def test_redirect_handler_refuses_source_change(self):
        handler = vscode._NoRedirect()
        request = urllib.request.Request(WINDOWS_API)
        with self.assertRaisesRegex(RuntimeError, "redirect refused"):
            handler.redirect_request(request, None, 302, "Found", {}, "https://evil.example/metadata")


if __name__ == "__main__":
    unittest.main()
