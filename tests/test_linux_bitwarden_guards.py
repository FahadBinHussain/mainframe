"""Synthetic Bitwarden source/integrity regression tests; never run a binary."""
import contextlib
import io
import json
import os
import stat
import tempfile
import unittest
import urllib.request
import zipfile
from pathlib import Path
from unittest.mock import Mock, patch

import bitwarden_cli_linux as bw
import linux_packages as lp
import test_linux_bitwarden as fixtures
from test_linux_bitwarden import Response, elf_fixture


class BitwardenGuardTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.parent = Path(temp.name)
        self.root = self.parent / "new"
        self.fixture = fixtures.BitwardenTests().release

    def metadata(self, version="3.4.5"):
        base = f"https://github.com/bitwarden/clients/releases/download/cli-v{version}/"
        manifest = {"version": version, "architecture": {"64bit": {
            "url": base + f"bw-oss-windows-{version}.zip", "hash": "a" * 64}}}
        release = {"tag_name": "cli-v" + version, "draft": False, "prerelease": False,
                   "published_at": "2025-01-01T00:00:00Z", "assets": []}
        for platform in ("linux", "windows"):
            name = f"bw-oss-{platform}-{version}.zip"
            release["assets"].append({"name": name, "browser_download_url": base + name,
                                      "size": 123, "digest": "sha256:" + "a" * 64})
        return manifest, release

    def archive(self, binary):
        raw = io.BytesIO()
        with zipfile.ZipFile(raw, "w") as z:
            z.writestr("bw", binary)
        return raw.getvalue()

    def test_resolves_multiple_exact_oss_versions(self):
        for version in ("3.4.5", "2040.12.7"):
            with self.subTest(version=version), patch.object(bw, "_json", side_effect=self.metadata(version)):
                release = bw.resolve_release("x86_64")
                self.assertEqual(release["version"], version)
                self.assertIn(f"bw-oss-linux-{version}.zip", release["url"])
                self.assertEqual(release["sha256"], "a" * 64)

    def test_draft_prerelease_missing_flags_and_publication_block(self):
        for change in ({"draft": True}, {"prerelease": True}, {"draft": None},
                       {"prerelease": None}, {"published_at": None}):
            manifest, release = self.metadata()
            release.update(change)
            with self.subTest(change=change), patch.object(bw, "_json", side_effect=[manifest, release]):
                with self.assertRaises(RuntimeError):
                    bw.resolve_release("x86_64")

    def test_asset_spoof_duplicates_and_nonoss_manifest_block(self):
        for mutate in ("variant", "duplicate", "path", "host", "size"):
            manifest, release = self.metadata()
            asset = release["assets"][0]
            if mutate == "variant":
                manifest["architecture"]["64bit"]["url"] = manifest["architecture"]["64bit"]["url"].replace("bw-oss-", "bw-")
            elif mutate == "duplicate":
                release["assets"].append(dict(asset))
            elif mutate == "path":
                asset["browser_download_url"] = asset["browser_download_url"].replace("/bitwarden/clients/", "/other/repo/")
            elif mutate == "host":
                asset["browser_download_url"] = asset["browser_download_url"].replace("github.com", "evil.example")
            else:
                asset["size"] = 0
            with self.subTest(mutate=mutate), patch.object(bw, "_json", side_effect=[manifest, release]):
                with self.assertRaises((RuntimeError, ValueError)):
                    bw.resolve_release("x86_64")

    def test_unsupported_architecture_precedes_network(self):
        with patch.object(bw, "_json") as network, self.assertRaises(RuntimeError):
            bw.resolve_release("aarch64")
        network.assert_not_called()

    def test_signed_official_redirect_allowed(self):
        request = urllib.request.Request(self.fixture()["url"])
        target = "https://release-assets.githubusercontent.com/github-production-release-asset/123/456-abc?sig=example"
        redirected = bw._Redirects().redirect_request(request, None, 302, "Found", {}, target)
        self.assertEqual(redirected.full_url, target)
        self.assertIsNone(redirected.get_header("Authorization"))

    def test_redirect_spoofs_and_cross_origin_metadata_block(self):
        request = urllib.request.Request(self.fixture()["url"])
        targets = ("https://evil.example/bw?secret=do-not-echo", "https://github.com/other/repo/bw",
                   "http://release-assets.githubusercontent.com/github-production-release-asset-1/x",
                   "https://release-assets.githubusercontent.com:443/github-production-release-asset/1/x",
                   "https://release-assets.githubusercontent.com/not-release/x")
        for target in targets:
            with self.subTest(target=target), self.assertRaises(RuntimeError) as caught:
                bw._Redirects().redirect_request(request, None, 302, "Found", {}, target)
            self.assertNotIn("do-not-echo", str(caught.exception))
        request = urllib.request.Request(bw.SCOOP_MANIFEST_URL)
        with self.assertRaises(RuntimeError):
            bw._Redirects().redirect_request(request, None, 302, "Found", {}, self.fixture()["url"])

    def test_zip_symlink_duplicate_and_expansion_limit(self):
        for mode in (stat.S_IFLNK | 0o777, stat.S_IFIFO | 0o600):
            raw = io.BytesIO()
            with zipfile.ZipFile(raw, "w") as z:
                info = zipfile.ZipInfo("bw")
                info.external_attr = mode << 16
                z.writestr(info, b"inert")
            with zipfile.ZipFile(io.BytesIO(raw.getvalue())) as z, self.assertRaises(ValueError):
                bw._zip_entry(z)
        info = zipfile.ZipInfo("bw")
        info.file_size = bw.ZIP_ENTRY_LIMIT + 1
        with self.assertRaises(ValueError):
            bw._zip_entry(Mock(infolist=lambda: [info]))
        with self.assertRaises(ValueError):
            bw._zip_entry(Mock(infolist=lambda: [info, info]))

    def test_non_glibc_host_refused_before_download(self):
        with patch.object(bw.platform, "libc_ver", return_value=("musl", "1.0")), patch.object(bw, "_open") as network:
            with self.assertRaisesRegex(RuntimeError, "glibc"):
                bw.install_release(self.fixture(), self.root)
            network.assert_not_called()

    def test_non_elf_truncated_and_wrong_arch_rejected(self):
        wrong = bytearray(elf_fixture())
        wrong[18:20] = (183).to_bytes(2, "little")
        for binary in (b"#!/bin/sh\necho unsafe", b"\x7fELF", bytes(wrong)):
            payload = self.archive(binary)
            with patch.object(bw, "_open", return_value=Response(payload)), self.assertRaisesRegex(RuntimeError, "ELF"):
                bw.install_release(self.fixture(payload), self.root)
            self.assertFalse(self.root.exists())
            self.assertEqual(list(self.parent.iterdir()), [])

    def test_position_independent_elf_executable_is_accepted(self):
        binary = bytearray(elf_fixture())
        binary[16:18] = (3).to_bytes(2, "little")
        payload = self.archive(bytes(binary))
        with patch.object(bw, "_open", return_value=Response(payload)):
            bw.install_release(self.fixture(payload), self.root)
        self.assertEqual((self.root / "bw").read_bytes(), bytes(binary))

    def test_atomic_publish_never_replaces_concurrent_destination(self):
        self.root.mkdir()
        sentinel = self.root / "keep"
        sentinel.write_text("original")
        stage = self.parent / "stage"
        stage.mkdir()
        with self.assertRaisesRegex(RuntimeError, "concurrently"):
            bw._publish_noreplace(stage, self.root)
        self.assertEqual(sentinel.read_text(), "original")
        self.assertTrue(stage.is_dir())

    def test_mixed_selection_preflight_blocks_every_install(self):
        plan = lp.Plan(True, "ubuntu", "x86_64", [
            lp.Action("apt", "curl", ["apt-get", "install", "-y", "curl"]),
            lp.Action("bitwarden-cli", "bitwarden-cli", archive=self.fixture())])
        runner = Mock()
        with patch.object(lp, "host_info", return_value=("ubuntu", "x86_64")), patch.object(bw, "install_release") as install:
            with self.assertRaisesRegex(RuntimeError, "root"):
                lp.execute(plan, ["curl", "bitwarden-cli"], runner=runner)
            runner.assert_not_called()
            install.assert_not_called()

    def test_planner_reports_failed_action(self):
        plan = lp.Plan(True, "ubuntu", "x86_64", [lp.Action("bitwarden-cli", "bitwarden-cli", archive=self.fixture())])
        with patch.object(lp, "host_info", return_value=("ubuntu", "x86_64")), patch.object(bw, "validate_install"), patch.object(bw, "install_release", side_effect=RuntimeError("SHA256 mismatch")):
            with self.assertRaises(lp.PackageExecutionError) as caught:
                lp.execute(plan, ["bitwarden-cli"], bitwarden_cli_root=self.root)
        self.assertEqual(caught.exception.report["executed"], [])
        self.assertEqual(caught.exception.report["failed"], {"name": "bitwarden-cli", "error": "SHA256 mismatch"})


if __name__ == "__main__":
    unittest.main()
