import json
import unittest
from unittest.mock import patch

import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parents[1]))

import wakatime_desktop_linux as wd


SHA_X64 = "a" * 64
SHA_ARM64 = "b" * 64
SHA_LINUX_X64 = "c" * 64
SHA_LINUX_ARM64 = "d" * 64


class FakeResponse:
    def __init__(self, body=b"", *, url, headers=None, read_error=None):
        self.body = body
        self.url = url
        self.headers = headers or {}
        self.read_error = read_error
        self.offset = 0

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        return False

    def geturl(self):
        return self.url

    def read(self, size=-1):
        if self.read_error is not None:
            raise self.read_error
        if size < 0:
            size = len(self.body) - self.offset
        chunk = self.body[self.offset:self.offset + size]
        self.offset += len(chunk)
        return chunk


class FakeOpener:
    def __init__(self, responses):
        self.responses = list(responses)
        self.calls = []

    def open(self, request, timeout):
        self.calls.append((request.full_url, timeout))
        if not self.responses:
            raise AssertionError("unexpected metadata or artifact request")
        url, response = self.responses.pop(0)
        if request.full_url != url:
            raise AssertionError("unexpected metadata or artifact URL")
        return response


class WakaTimeDesktopPlanTests(unittest.TestCase):
    def setUp(self):
        self.version = "3.0.0.1"
        self.release_tag = "v3.0.0+1"
        self.manifest_url = wd._version_urls(self.version)["manifest"]
        self.release_url = wd._release_api_url(self.release_tag)

    def _windows_url(self, architecture):
        name = "wakatime-win32-x64.exe" if architecture == "x64" else "wakatime-win32-arm64.exe"
        # The current WinGet manifest uses a literal '+' in its download URL.
        return f"{wd.RELEASE_DOWNLOAD_PREFIX}{self.release_tag}/{name}"

    def _manifest(self, *, version=None, release_tag=None, x64_url=None, x64_hash=SHA_X64,
                  arm64_url=None, arm64_hash=SHA_ARM64, extra=""):
        version = version or self.version
        release_tag = release_tag or self.release_tag
        x64_url = x64_url or f"{wd.RELEASE_DOWNLOAD_PREFIX}{release_tag}/wakatime-win32-x64.exe"
        arm64_url = arm64_url or f"{wd.RELEASE_DOWNLOAD_PREFIX}{release_tag}/wakatime-win32-arm64.exe"
        return (
            "PackageIdentifier: Wakatime.DesktopWakatime\n"
            f"PackageVersion: {version}\n"
            "InstallerType: nullsoft\n"
            "Installers:\n"
            "- Architecture: x64\n"
            f"  InstallerUrl: {x64_url}\n"
            f"  InstallerSha256: {x64_hash.upper()}\n"
            "  InstallerSwitches:\n"
            "    Custom: inert-manifest-option\n"
            "  Dependencies:\n"
            "    PackageDependencies:\n"
            "    - PackageIdentifier: Example.Dependency\n"
            "- Architecture: arm64\n"
            f"  InstallerUrl: {arm64_url}\n"
            f"  InstallerSha256: {arm64_hash.upper()}\n"
            "  Dependencies:\n"
            "    PackageDependencies:\n"
            "    - PackageIdentifier: Example.Dependency\n"
            "ManifestType: installer\n"
            "ManifestVersion: 1.12.0\n"
            + extra
        ).encode("ascii")

    def _release(self, *, tag=None, draft=False, prerelease=False,
                 x64_hash=SHA_X64, arm64_hash=SHA_ARM64,
                 linux_x64_hash=SHA_LINUX_X64, linux_arm64_hash=SHA_LINUX_ARM64,
                 linux_x64_url=None, linux_arm64_url=None, extra_assets=None):
        tag = tag or self.release_tag
        x64_url = wd._release_asset_url(tag, "wakatime-win32-x64.exe")
        arm64_url = wd._release_asset_url(tag, "wakatime-win32-arm64.exe")
        linux_x64_url = linux_x64_url or wd._release_asset_url(tag, "wakatime-linux-x86_64.AppImage")
        linux_arm64_url = linux_arm64_url or wd._release_asset_url(tag, "wakatime-linux-arm64.AppImage")
        assets = [
            {"name": "wakatime-win32-x64.exe", "size": 100, "digest": f"sha256:{x64_hash}", "browser_download_url": x64_url},
            {"name": "wakatime-win32-arm64.exe", "size": 101, "digest": f"sha256:{arm64_hash}", "browser_download_url": arm64_url},
            {"name": "wakatime-linux-x86_64.AppImage", "size": 200, "digest": f"sha256:{linux_x64_hash}", "browser_download_url": linux_x64_url},
            {"name": "wakatime-linux-arm64.AppImage", "size": 201, "digest": f"sha256:{linux_arm64_hash}", "browser_download_url": linux_arm64_url},
        ]
        if extra_assets:
            assets.extend(extra_assets)
        value = {
            "tag_name": tag,
            "draft": draft,
            "prerelease": prerelease,
            "published_at": "2026-05-21T15:15:41Z",
            "assets": assets,
        }
        return json.dumps(value, separators=(",", ":")).encode("utf-8")

    def test_x86_64_win_get_hash_matches_manifest_named_release_and_linux_appimage_is_metadata_only(self):
        version, win_url, win_hash, tag = wd._installer_metadata(self._manifest(), self.version, "x86_64")
        release = wd._release_metadata(self._release(), version, tag, "x86_64", win_url, win_hash)
        self.assertEqual(version, "3.0.0.1")
        self.assertEqual(tag, "v3.0.0+1")
        self.assertEqual(win_hash, SHA_X64)
        self.assertTrue(release["windows_digest_matches_winget"])
        candidate = release["linux_desktop_appimage_candidate"]
        self.assertEqual(candidate["name"], "wakatime-linux-x86_64.AppImage")
        self.assertEqual(candidate["url"], f"{wd.RELEASE_DOWNLOAD_PREFIX}v3.0.0%2B1/wakatime-linux-x86_64.AppImage")
        self.assertEqual(candidate["size"], 200)
        self.assertEqual(candidate["sha256"], SHA_LINUX_X64)
        self.assertNotIn("inert-manifest-option", json.dumps(release))

    def test_aarch64_matches_arm64_windows_and_linux_assets(self):
        version, win_url, win_hash, tag = wd._installer_metadata(self._manifest(), self.version, "aarch64")
        release = wd._release_metadata(self._release(), version, tag, "aarch64", win_url, win_hash)
        self.assertEqual(win_hash, SHA_ARM64)
        self.assertEqual(tag, self.release_tag)
        self.assertEqual(release["linux_desktop_appimage_candidate"]["name"], "wakatime-linux-arm64.AppImage")
        self.assertEqual(release["linux_desktop_appimage_candidate"]["sha256"], SHA_LINUX_ARM64)

    def test_latest_index_version_is_numeric_and_release_tag_is_manifest_derived(self):
        index = json.dumps([
            {"name": "2.1.7", "type": "dir"},
            {"name": "2.0.2.1", "type": "dir"},
            {"name": "3.0.0", "type": "dir"},
            {"name": "3.0.0.1", "type": "dir"},
            {"name": "README.md", "type": "file"},
        ]).encode()
        self.assertEqual(wd._latest_version(index), self.version)
        self.assertTrue(wd._version_urls(self.version)["manifest"].endswith("/3.0.0.1/Wakatime.DesktopWakatime.installer.yaml"))
        self.assertEqual(wd._release_api_url(self.release_tag), f"{wd.RELEASE_API_PREFIX}v3.0.0%2B1")

    def test_index_duplicate_keys_duplicate_versions_and_unsupported_versions_fail_closed(self):
        with self.assertRaisesRegex(ValueError, "Invalid official WakaTime WinGet index metadata"):
            wd._latest_version(b'[{"name":"3.0.0","name":"3.0.0","type":"dir"}]')
        with self.assertRaisesRegex(ValueError, "Duplicate WakaTime WinGet version"):
            wd._latest_version(b'[{"name":"3.0.0","type":"dir"},{"name":"3.0.0","type":"dir"}]')
        with self.assertRaisesRegex(ValueError, "Unsupported WakaTime WinGet version"):
            wd._latest_version(b'[{"name":"3.0.0-beta","type":"dir"}]')
        with self.assertRaisesRegex(ValueError, "Unsupported WakaTime WinGet version"):
            wd._latest_version(b'[{"name":"3.0.0.1.2","type":"dir"}]')
        with self.assertRaisesRegex(ValueError, "no supported versions"):
            wd._latest_version(b'[{"name":"README.md","type":"file"}]')

    def test_manifest_identity_version_duplicates_and_invalid_target_fields_fail_closed(self):
        cases = [
            (self._manifest().replace(b"Wakatime.DesktopWakatime", b"Other.Product", 1), "identity changed"),
            (self._manifest(version="3.0.1"), "versions differ"),
            (self._manifest().replace(b"PackageVersion: 3.0.0.1\n", b"PackageVersion: 3.0.0.1\nPackageVersion: 3.0.0.1\n"), "duplicate or missing identity"),
            (self._manifest(extra="PackageIdentifier: Wakatime.DesktopWakatime\n"), "duplicate or missing identity"),
            (self._manifest(x64_url="C:\\Users\\test\\wakatime.exe"), "invalid target installer metadata"),
            (self._manifest(x64_hash="not-a-hash"), "invalid target installer metadata"),
            (self._manifest().replace(b"  InstallerUrl: https://github.com/wakatime/desktop-wakatime/releases/download/v3.0.0+1/wakatime-win32-x64.exe\n", b"  InstallerUrl: https://github.com/wakatime/desktop-wakatime/releases/download/v3.0.0+1/wakatime-win32-x64.exe\n  InstallerUrl: https://github.com/wakatime/desktop-wakatime/releases/download/v3.0.0+1/wakatime-win32-x64.exe\n"), "Duplicate WakaTime WinGet installer field"),
            (self._manifest().replace(b"- Architecture: x64\n", b"- Architecture: x64\n- Architecture: x64\n"), "unique target Windows architecture"),
            (self._manifest().replace(b"PackageVersion: 3.0.0.1\n", b"PackageVersion: 3.0.0.1\tinvalid\n"), "Invalid official WakaTime WinGet installer metadata"),
            (self._manifest(release_tag="v3.0.0/../../other"), "invalid target installer metadata"),
        ]
        for payload, expected in cases:
            with self.subTest(expected=expected):
                with self.assertRaisesRegex(ValueError, expected):
                    wd._installer_metadata(payload, self.version, "x86_64")

    def test_release_tag_status_digest_url_and_duplicate_assets_are_checked(self):
        _, win_url, win_hash, tag = wd._installer_metadata(self._manifest(), self.version, "x86_64")
        duplicate_linux = {
            "name": "wakatime-linux-x86_64.AppImage",
            "size": 10,
            "digest": f"sha256:{SHA_LINUX_X64}",
            "browser_download_url": wd._release_asset_url(self.release_tag, "wakatime-linux-x86_64.AppImage"),
        }
        cases = [
            (self._release(tag="v3.0.1"), "tag/status"),
            (self._release(draft=True), "tag/status"),
            (self._release(prerelease=True), "tag/status"),
            (self._release(x64_hash="e" * 64), "hash differs"),
            (self._release(linux_x64_url="https://example.invalid/app.AppImage"), "asset metadata is invalid"),
            (self._release(extra_assets=[duplicate_linux]), "missing or duplicates"),
        ]
        for payload, expected in cases:
            with self.subTest(expected=expected):
                with self.assertRaisesRegex(ValueError, expected):
                    wd._release_metadata(payload, self.version, tag, "x86_64", win_url, win_hash)

    def test_release_rejects_malformed_asset_digest_size_and_publication_date(self):
        _, win_url, win_hash, tag = wd._installer_metadata(self._manifest(), self.version, "x86_64")
        value = json.loads(self._release())
        value["assets"][2]["digest"] = "sha1:" + SHA_LINUX_X64
        with self.assertRaisesRegex(ValueError, "asset metadata is invalid"):
            wd._release_metadata(json.dumps(value).encode(), self.version, tag, "x86_64", win_url, win_hash)
        value = json.loads(self._release())
        value["assets"][2]["size"] = True
        with self.assertRaisesRegex(ValueError, "asset metadata is invalid"):
            wd._release_metadata(json.dumps(value).encode(), self.version, tag, "x86_64", win_url, win_hash)
        value = json.loads(self._release())
        value["published_at"] = "not-a-date"
        with self.assertRaisesRegex(ValueError, "publication metadata is invalid"):
            wd._release_metadata(json.dumps(value).encode(), self.version, tag, "x86_64", win_url, win_hash)

    def test_build_plan_requests_only_the_three_fixed_metadata_sources(self):
        index = json.dumps([{"name": self.version, "type": "dir"}]).encode()
        manifest = self._manifest()
        release = self._release()
        opener = FakeOpener([
            (wd.WINGET_INDEX_URL, FakeResponse(index, url=wd.WINGET_INDEX_URL)),
            (self.manifest_url, FakeResponse(manifest, url=self.manifest_url)),
            (self.release_url, FakeResponse(release, url=self.release_url)),
        ])
        with patch.object(wd.urllib.request, "build_opener", return_value=opener):
            plan = wd.build_dry_plan("x86_64")
        self.assertEqual([call[0] for call in opener.calls], [wd.WINGET_INDEX_URL, self.manifest_url, self.release_url])
        self.assertTrue(all(call[1] == wd.TIMEOUT for call in opener.calls))
        self.assertFalse(plan["executable"])
        self.assertFalse(plan["package"]["version_is_restore_pin"])
        self.assertEqual(plan["package"]["version"], self.version)
        self.assertEqual(plan["official_release"]["tag_name"], self.release_tag)
        self.assertEqual(plan["official_release"]["linux_desktop_appimage_candidate"]["sha256"], SHA_LINUX_X64)

    def test_fixed_fetch_rejects_artifact_urls_redirects_and_read_failures(self):
        with self.assertRaisesRegex(ValueError, "Refusing non-metadata"):
            wd._fetch_metadata(f"{wd.RELEASE_DOWNLOAD_PREFIX}v3.0.0%2B1/wakatime-linux-x86_64.AppImage", self.version, release_tag=self.release_tag)
        response = FakeResponse(b"metadata", url="https://other.invalid/redirect")
        opener = FakeOpener([(wd.WINGET_INDEX_URL, response)])
        with patch.object(wd.urllib.request, "build_opener", return_value=opener):
            with self.assertRaisesRegex(RuntimeError, "source changed"):
                wd._fetch_metadata(wd.WINGET_INDEX_URL)
        marker = "synthetic-private-response-marker"
        response = FakeResponse(url=wd.WINGET_INDEX_URL, read_error=OSError(marker))
        opener = FakeOpener([(wd.WINGET_INDEX_URL, response)])
        with patch.object(wd.urllib.request, "build_opener", return_value=opener):
            with self.assertRaisesRegex(RuntimeError, "metadata request failed") as caught:
                wd._fetch_metadata(wd.WINGET_INDEX_URL)
        self.assertNotIn(marker, str(caught.exception))

    def test_all_metadata_endpoints_enforce_header_and_stream_limits(self):
        endpoints = [
            (wd.WINGET_INDEX_URL, None, None, wd.INDEX_LIMIT),
            (self.manifest_url, self.version, None, wd.MANIFEST_LIMIT),
            (self.release_url, self.version, self.release_tag, wd.RELEASE_LIMIT),
        ]
        for url, version, tag, limit in endpoints:
            with self.subTest(endpoint=url, kind="header"):
                response = FakeResponse(url=url, headers={"Content-Length": str(limit + 1)})
                opener = FakeOpener([(url, response)])
                with patch.object(wd.urllib.request, "build_opener", return_value=opener):
                    with self.assertRaisesRegex(RuntimeError, "exceeds its size limit"):
                        wd._fetch_metadata(url, version, release_tag=tag)
            with self.subTest(endpoint=url, kind="stream"):
                response = FakeResponse(b"x" * (limit + 1), url=url)
                opener = FakeOpener([(url, response)])
                with patch.object(wd.urllib.request, "build_opener", return_value=opener):
                    with self.assertRaisesRegex(RuntimeError, "exceeds its size limit"):
                        wd._fetch_metadata(url, version, release_tag=tag)

    def test_non_string_and_unsupported_architectures_fail_without_fetching(self):
        with patch.object(wd, "_fetch_metadata") as fetch:
            for architecture in (None, 5, "i686", "x86_64;unexpected"):
                with self.subTest(architecture=architecture):
                    with self.assertRaisesRegex(ValueError, "supports x86_64 or aarch64"):
                        wd.build_dry_plan(architecture)
            fetch.assert_not_called()


if __name__ == "__main__":
    unittest.main()
