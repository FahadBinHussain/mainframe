from __future__ import annotations

import http.client
import json
import unittest
import urllib.error
from unittest.mock import patch

import windscribe_linux as wind

VERSION = "2.24.13"
WIN_X64_SHA = "1" * 64
WIN_ARM64_SHA = "2" * 64
LINUX_X64_SHA = "3" * 64
LINUX_ARM64_SHA = "4" * 64


def _names(version: str = VERSION, architecture: str = "x86_64") -> tuple[str, str, str, str]:
    suffix = "amd64" if architecture == "x86_64" else "arm64"
    winget_arch = "x64" if architecture == "x86_64" else "arm64"
    return (
        winget_arch,
        f"Windscribe_{version}_{suffix}.exe",
        f"windscribe_{version}_{suffix}.deb",
        suffix,
    )


def _urls(version: str = VERSION, architecture: str = "x86_64") -> tuple[str, str]:
    _winget_arch, windows_name, linux_name, _suffix = _names(version, architecture)
    base = f"https://github.com/Windscribe/Desktop-App/releases/download/v{version}/"
    return base + windows_name, base + linux_name


def _index(version: str = VERSION, extra: list[dict] | None = None) -> bytes:
    entries = [
        {"name": ".validation", "type": "file"},
        {"name": "2.9.10", "type": "dir"},
        {"name": "2.10.0", "type": "dir"},
        {"name": version, "type": "dir"},
    ]
    if extra:
        entries.extend(extra)
    return json.dumps(entries).encode("utf-8")


def _manifest(version: str = VERSION, architecture: str = "x86_64",
              windows_sha: str | None = None, windows_url: str | None = None,
              extra_installer_fields: str = "") -> bytes:
    x64_url, _ = _urls(version, "x86_64")
    arm_url, _ = _urls(version, "aarch64")
    x64_sha = windows_sha if architecture == "x86_64" and windows_sha is not None else WIN_X64_SHA
    arm_sha = windows_sha if architecture == "aarch64" and windows_sha is not None else WIN_ARM64_SHA
    if architecture == "x86_64" and windows_url is not None:
        x64_url = windows_url
    if architecture == "aarch64" and windows_url is not None:
        arm_url = windows_url
    text = (
        "# Untrusted metadata comments are inert.\n"
        "PackageIdentifier: Windscribe.Windscribe\n"
        f"PackageVersion: {version}\n"
        "InstallerType: exe\n"
        "InstallerSwitches:\n"
        "  Silent: -silent -no-auto-start\n"
        "Installers:\n"
        "- Architecture: x64\n"
        f"  InstallerUrl: {x64_url}\n"
        f"  InstallerSha256: {x64_sha}\n"
        "  InstallerSwitches: synthetic-never-execute\n"
        "- Architecture: arm64\n"
        f"  InstallerUrl: {arm_url}\n"
        f"  InstallerSha256: {arm_sha}\n"
        "ManifestType: installer\n"
    )
    if extra_installer_fields:
        text = text.replace("ManifestType: installer\n", extra_installer_fields + "ManifestType: installer\n")
    return text.encode("utf-8")


def _release(version: str = VERSION, *, windows_x64_sha: str = WIN_X64_SHA,
             windows_arm64_sha: str = WIN_ARM64_SHA,
             linux_x64_sha: str = LINUX_X64_SHA,
             linux_arm64_sha: str = LINUX_ARM64_SHA) -> bytes:
    assets = []
    for architecture, win_sha, linux_sha in (
        ("x86_64", windows_x64_sha, linux_x64_sha),
        ("aarch64", windows_arm64_sha, linux_arm64_sha),
    ):
        _winget_arch, windows_name, linux_name, _suffix = _names(version, architecture)
        windows_url, linux_url = _urls(version, architecture)
        assets.extend([
            {"name": windows_name, "browser_download_url": windows_url,
             "digest": f"sha256:{win_sha}", "size": 1000},
            {"name": linux_name, "browser_download_url": linux_url,
             "digest": f"sha256:{linux_sha}", "size": 2000},
        ])
    assets.append({"name": "synthetic-postinstall.sh", "browser_download_url": "https://example.invalid/postinstall.sh",
                   "digest": "sha256:" + "f" * 64, "size": 10})
    return json.dumps({
        "tag_name": f"v{version}",
        "draft": False,
        "prerelease": False,
        "published_at": "2026-09-08T20:10:42Z",
        "assets": assets,
    }).encode("utf-8")


def _payloads(version: str = VERSION) -> dict[str, bytes]:
    urls = wind._version_urls(version)
    return {
        wind.WINGET_INDEX_URL: _index(version),
        urls["manifest"]: _manifest(version),
        urls["release"]: _release(version),
    }


class _Response:
    def __init__(self, url: str, body: bytes, headers: dict[str, str] | None = None,
                 *, read_error: BaseException | None = None, final_url: str | None = None):
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


class WindscribeMetadataTests(unittest.TestCase):
    def _plan(self, architecture: str = "x86_64", payloads: dict[str, bytes] | None = None):
        sources = payloads or _payloads()
        calls: list[tuple[str, str | None]] = []

        def fetch(url: str, version: str | None = None) -> bytes:
            calls.append((url, version))
            return sources[url]

        with patch.object(wind, "_fetch_metadata", side_effect=fetch):
            plan = wind.build_dry_plan(architecture)
        return plan, calls

    def test_x64_matches_win_get_digest_and_same_release_linux_desktop_candidate(self):
        plan, calls = self._plan("x86_64")
        urls = wind._version_urls(VERSION)
        self.assertEqual(calls, [
            (wind.WINGET_INDEX_URL, None),
            (urls["manifest"], VERSION),
            (urls["release"], VERSION),
        ])
        self.assertTrue(all("/releases/download/" not in url for url, _ in calls))
        self.assertEqual(plan["package"], {
            "name": "Windscribe.Windscribe", "product": "Windscribe desktop app",
            "version": VERSION, "version_is_restore_pin": False, "architecture": "x86_64",
        })
        self.assertEqual(plan["winget_observation"]["windows_installer_sha256"], WIN_X64_SHA)
        self.assertTrue(plan["official_release"]["windows_digest_matches_winget"])
        self.assertEqual(plan["official_release"]["windows_asset"]["sha256"], WIN_X64_SHA)
        candidate = plan["official_release"]["linux_desktop_deb_candidate"]
        self.assertEqual(candidate["name"], f"windscribe_{VERSION}_amd64.deb")
        self.assertEqual(candidate["url"], _urls(VERSION, "x86_64")[1])
        self.assertEqual(candidate["sha256"], LINUX_X64_SHA)
        self.assertFalse(plan["official_release"]["publisher_signature_verified"])
        self.assertFalse(plan["executable"])
        self.assertNotIn("synthetic-never-execute", json.dumps(plan))
        self.assertNotIn("synthetic-postinstall.sh", json.dumps(plan))

    def test_arm64_matches_its_own_windows_digest_and_linux_deb(self):
        plan, _calls = self._plan("aarch64")
        self.assertEqual(plan["package"]["architecture"], "aarch64")
        self.assertEqual(plan["winget_observation"]["windows_architecture"], "arm64")
        self.assertEqual(plan["winget_observation"]["windows_installer_sha256"], WIN_ARM64_SHA)
        self.assertEqual(plan["official_release"]["windows_asset"]["sha256"], WIN_ARM64_SHA)
        candidate = plan["official_release"]["linux_desktop_deb_candidate"]
        self.assertEqual(candidate["name"], f"windscribe_{VERSION}_arm64.deb")
        self.assertEqual(candidate["sha256"], LINUX_ARM64_SHA)

    def test_latest_version_is_selected_numerically_and_unsupported_shape_fails_closed(self):
        value = [
            {"name": "2.9.99", "type": "dir"},
            {"name": "2.10.0", "type": "dir"},
            {"name": "2.24.13", "type": "dir"},
            {"name": ".validation", "type": "file"},
        ]
        self.assertEqual(wind._latest_version(json.dumps(value).encode()), VERSION)
        with self.assertRaisesRegex(ValueError, "Unsupported Windscribe WinGet version format"):
            wind._latest_version(json.dumps(value + [{"name": "2.24.13.1", "type": "dir"}]).encode())

    def test_index_duplicate_versions_and_duplicate_json_keys_fail_closed(self):
        duplicate = _index(extra=[{"name": VERSION, "type": "dir"}])
        with self.assertRaisesRegex(ValueError, "Duplicate Windscribe WinGet version"):
            wind._latest_version(duplicate)
        with self.assertRaisesRegex(ValueError, "Invalid official Windscribe WinGet index"):
            wind._latest_version(b'[{"name":"2.24.13","name":"2.24.14","type":"dir"}]')
        with self.assertRaisesRegex(ValueError, "Invalid official Windscribe WinGet index"):
            wind._latest_version(b"not-json")
        with self.assertRaisesRegex(ValueError, "contains no supported versions"):
            wind._latest_version(b'[{"name":".validation","type":"file"}]')

    def test_wrong_manifest_identity_version_url_hash_and_duplicate_fields_fail_closed(self):
        valid = _manifest()
        with self.assertRaisesRegex(ValueError, "identity changed"):
            wind._installer_metadata(valid.replace(b"Windscribe.Windscribe", b"Other.Product"), VERSION, "x86_64")
        with self.assertRaisesRegex(ValueError, "versions differ"):
            wind._installer_metadata(valid.replace(b"PackageVersion: 2.24.13", b"PackageVersion: 2.24.14"), VERSION, "x86_64")
        with self.assertRaisesRegex(ValueError, "invalid target installer metadata"):
            wind._installer_metadata(_manifest(windows_url="https://evil.invalid/Windscribe.exe"), VERSION, "x86_64")
        with self.assertRaisesRegex(ValueError, "invalid target installer metadata"):
            wind._installer_metadata(_manifest(windows_sha="not-a-hash"), VERSION, "x86_64")
        duplicate_version = valid.replace(b"PackageVersion: 2.24.13", b"PackageVersion: 2.24.13\nPackageVersion: 2.24.13")
        with self.assertRaisesRegex(ValueError, "duplicate or missing identity"):
            wind._installer_metadata(duplicate_version, VERSION, "x86_64")
        duplicate_url = valid.replace(
            f"  InstallerUrl: {_urls()[0]}\n".encode(),
            f"  InstallerUrl: {_urls()[0]}\n  InstallerUrl: {_urls()[0]}\n".encode(),
        )
        with self.assertRaisesRegex(ValueError, "Duplicate Windscribe WinGet installer field"):
            wind._installer_metadata(duplicate_url, VERSION, "x86_64")
        duplicate_section = valid.replace(b"Installers:\n", b"Installers:\nInstallers:\n")
        with self.assertRaisesRegex(ValueError, "duplicate or missing Installers"):
            wind._installer_metadata(duplicate_section, VERSION, "x86_64")

    def test_untrusted_installer_fields_are_inert_and_not_returned(self):
        manifest = _manifest(extra_installer_fields="UntrustedTopLevel: synthetic-secret-command\n")
        version, url, sha = wind._installer_metadata(manifest, VERSION, "x86_64")
        self.assertEqual((version, url, sha), (VERSION, _urls()[0], WIN_X64_SHA))
        self.assertNotIn("synthetic-secret-command", json.dumps({"version": version, "url": url, "sha": sha}))

    def test_release_tag_and_exact_windows_digest_must_match_win_get(self):
        urls = wind._version_urls(VERSION)
        version, windows_url, windows_sha = wind._installer_metadata(_manifest(), VERSION, "x86_64")
        parsed = wind._release_metadata(_release(), version, "x86_64", windows_url, windows_sha)
        self.assertTrue(parsed["windows_digest_matches_winget"])
        with self.assertRaisesRegex(ValueError, "tag/status"):
            wind._release_metadata(_release().replace(b"v2.24.13", b"v2.24.14"), VERSION, "x86_64", windows_url, windows_sha)
        with self.assertRaisesRegex(ValueError, "SHA-256 differs"):
            wind._release_metadata(_release(windows_x64_sha="f" * 64), VERSION, "x86_64", windows_url, windows_sha)
        self.assertEqual(urls["release"], wind.RELEASE_API_PREFIX + VERSION)

    def test_release_missing_duplicate_bad_digest_or_bad_linux_asset_fails_closed(self):
        version, windows_url, windows_sha = wind._installer_metadata(_manifest(), VERSION, "x86_64")
        base = json.loads(_release())
        linux_name = _names(VERSION, "x86_64")[2]
        missing = dict(base)
        missing["assets"] = [a for a in base["assets"] if a["name"] != linux_name]
        with self.assertRaisesRegex(ValueError, "missing or ambiguous"):
            wind._release_metadata(json.dumps(missing).encode(), version, "x86_64", windows_url, windows_sha)
        duplicate = dict(base)
        duplicate["assets"] = list(base["assets"]) + [next(a for a in base["assets"] if a["name"] == linux_name)]
        with self.assertRaisesRegex(ValueError, "missing or ambiguous"):
            wind._release_metadata(json.dumps(duplicate).encode(), version, "x86_64", windows_url, windows_sha)
        bad_digest = json.loads(_release())
        next(a for a in bad_digest["assets"] if a["name"] == linux_name)["digest"] = "sha256:bad"
        with self.assertRaisesRegex(ValueError, "asset metadata is invalid"):
            wind._release_metadata(json.dumps(bad_digest).encode(), version, "x86_64", windows_url, windows_sha)
        bad_url = json.loads(_release())
        next(a for a in bad_url["assets"] if a["name"] == linux_name)["browser_download_url"] = "https://evil.invalid/pkg.deb"
        with self.assertRaisesRegex(ValueError, "asset metadata is invalid"):
            wind._release_metadata(json.dumps(bad_url).encode(), version, "x86_64", windows_url, windows_sha)

    def test_draft_prerelease_invalid_release_and_duplicate_json_keys_fail_closed(self):
        version, windows_url, windows_sha = wind._installer_metadata(_manifest(), VERSION, "x86_64")
        draft = json.loads(_release())
        draft["draft"] = True
        with self.assertRaisesRegex(ValueError, "tag/status"):
            wind._release_metadata(json.dumps(draft).encode(), version, "x86_64", windows_url, windows_sha)
        prerelease = json.loads(_release())
        prerelease["prerelease"] = True
        with self.assertRaisesRegex(ValueError, "tag/status"):
            wind._release_metadata(json.dumps(prerelease).encode(), version, "x86_64", windows_url, windows_sha)
        with self.assertRaisesRegex(ValueError, "Invalid official Windscribe GitHub release"):
            wind._release_metadata(b'{"tag_name":"v2.24.13","tag_name":"v2.24.13"}', version, "x86_64", windows_url, windows_sha)

    def test_fixed_endpoint_guard_redirect_and_final_url_guard(self):
        with self.assertRaisesRegex(ValueError, "Refusing non-metadata"):
            wind._fetch_metadata("https://github.com/Windscribe/Desktop-App/releases/download/v2.24.13/windscribe_2.24.13_amd64.deb", VERSION)
        with self.assertRaisesRegex(ValueError, "Refusing non-metadata"):
            wind._fetch_metadata("https://evil.invalid/metadata.json")
        response = _Response(wind.WINGET_INDEX_URL, b"[]", final_url="https://evil.invalid/redirected")
        opener = type("Opener", (), {"open": lambda self, request, timeout: response})()
        with patch.object(wind.urllib.request, "build_opener", return_value=opener):
            with self.assertRaisesRegex(RuntimeError, "source changed"):
                wind._fetch_metadata(wind.WINGET_INDEX_URL)
        with patch.object(wind.urllib.request, "build_opener", side_effect=RuntimeError("Official Windscribe metadata redirect refused")):
            with self.assertRaisesRegex(RuntimeError, "redirect refused"):
                wind._fetch_metadata(wind.WINGET_INDEX_URL)

    def test_bounded_fetch_rejects_oversized_content_length_and_stream(self):
        response = _Response(wind.WINGET_INDEX_URL, b"[]", {"Content-Length": "9"})
        opener = type("Opener", (), {"open": lambda self, request, timeout: response})()
        with patch.object(wind, "INDEX_LIMIT", 8), patch.object(wind.urllib.request, "build_opener", return_value=opener):
            with self.assertRaisesRegex(RuntimeError, "exceeds its size limit"):
                wind._fetch_metadata(wind.WINGET_INDEX_URL)
        self.assertFalse(response.read_called)
        response = _Response(wind.WINGET_INDEX_URL, b"123456789")
        opener = type("Opener", (), {"open": lambda self, request, timeout: response})()
        with patch.object(wind, "INDEX_LIMIT", 8), patch.object(wind.urllib.request, "build_opener", return_value=opener):
            with self.assertRaisesRegex(RuntimeError, "exceeds its size limit"):
                wind._fetch_metadata(wind.WINGET_INDEX_URL)

    def test_manifest_and_release_limits_reject_oversized_headers_and_streams(self):
        urls = wind._version_urls(VERSION)
        for source in ("manifest", "release"):
            url = urls[source]
            for mode in ("content-length", "stream"):
                with self.subTest(source=source, mode=mode):
                    limit_value = 8
                    other_limit = 128
                    with patch.object(wind, "MANIFEST_LIMIT", limit_value if source == "manifest" else other_limit), \
                            patch.object(wind, "RELEASE_LIMIT", limit_value if source == "release" else other_limit):
                        headers = {"Content-Length": str(limit_value + 1)} if mode == "content-length" else {}
                        body = b"x" * (limit_value + 1)
                        response = _Response(url, body, headers)
                        opened: list[str] = []

                        def open_request(request, timeout):
                            opened.append(request.full_url)
                            return response

                        opener = type("Opener", (), {"open": lambda self, request, timeout: open_request(request, timeout)})()
                        with patch.object(wind.urllib.request, "build_opener", return_value=opener):
                            with self.assertRaisesRegex(RuntimeError, "exceeds its size limit"):
                                wind._fetch_metadata(url, VERSION)
                        self.assertEqual(opened, [url])
                        self.assertNotIn("/releases/download/", opened[0])
                        self.assertEqual(response.read_called, mode == "stream")

    def test_http_failures_are_sanitized_and_non_string_architecture_is_rejected(self):
        marker = "synthetic-secret-response-marker"
        with patch.object(wind.urllib.request, "build_opener", side_effect=urllib.error.URLError(marker)):
            with self.assertRaisesRegex(RuntimeError, "metadata request failed") as caught:
                wind._fetch_metadata(wind.WINGET_INDEX_URL)
        self.assertNotIn(marker, str(caught.exception))
        response = _Response(wind.WINGET_INDEX_URL, b"[]", read_error=http.client.IncompleteRead(marker.encode(), 99))
        opener = type("Opener", (), {"open": lambda self, request, timeout: response})()
        with patch.object(wind.urllib.request, "build_opener", return_value=opener):
            with self.assertRaisesRegex(RuntimeError, "metadata request failed") as caught:
                wind._fetch_metadata(wind.WINGET_INDEX_URL)
        self.assertNotIn(marker, str(caught.exception))
        with self.assertRaisesRegex(ValueError, "supports x86_64 or aarch64"):
            wind.build_dry_plan([])
        with self.assertRaisesRegex(ValueError, "supports x86_64 or aarch64"):
            wind.build_dry_plan("armv7")


if __name__ == "__main__":
    unittest.main()
