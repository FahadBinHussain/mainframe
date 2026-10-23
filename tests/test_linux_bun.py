import hashlib
import io
import json
import os
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parents[1]))
import bun_linux as bun


def elf_fixture() -> bytes:
    h = bytearray(64); h[:4] = b"\x7fELF"; h[4:7] = bytes((2, 1, 1))
    h[16:18] = (2).to_bytes(2, "little"); h[18:20] = (62).to_bytes(2, "little")
    h[20:24] = (1).to_bytes(4, "little"); h[52:54] = (64).to_bytes(2, "little")
    return bytes(h) + b"synthetic"


class Response:
    def __init__(self, data): self.io = io.BytesIO(data); self.headers = {"Content-Length": str(len(data))}
    def read(self, n=-1): return self.io.read(n)
    def close(self): pass


class BunTests(unittest.TestCase):
    def setUp(self):
        self.version = "1.2.3"
        self.manifest = {"version": self.version, "architecture": {"64bit": {"url": [
            f"https://github.com/oven-sh/bun/releases/download/bun-v{self.version}/bun-windows-x64.zip",
            f"https://github.com/oven-sh/bun/releases/download/bun-v{self.version}/bun-windows-x64-baseline.zip"]}, "arm64": {"url": f"https://github.com/oven-sh/bun/releases/download/bun-v{self.version}/bun-windows-aarch64.zip"}}}
        self.payload = self.zip_payload(); self.sha = hashlib.sha256(self.payload).hexdigest()

    def zip_payload(self, name="bun-linux-x64-baseline/bun"):
        out = io.BytesIO()
        with zipfile.ZipFile(out, "w") as z: z.writestr(name, elf_fixture())
        return out.getvalue()

    def release(self, **changes):
        r = {"version": self.version, "url": f"https://github.com/oven-sh/bun/releases/download/bun-v{self.version}/bun-linux-x64-baseline.zip", "sha256": self.sha, "size": str(len(self.payload)), "asset_name": "bun-linux-x64-baseline.zip", "manifest_source": bun.SCOOP_MANIFEST_URL, "release_source": bun.GITHUB_API_BASE + "bun-v" + self.version, "checksums_source": f"https://github.com/oven-sh/bun/releases/download/bun-v{self.version}/SHASUMS256.txt", "checksums_sha256": "a" * 64, "layout": "bun-linux-x64-baseline/bun"}
        r.update(changes); return r

    def api_release(self):
        def a(name, digest): return {"name": name, "size": 10, "digest": "sha256:" + digest, "browser_download_url": f"https://github.com/oven-sh/bun/releases/download/bun-v{self.version}/{name}"}
        d = {"linux": "1" * 64, "std": "2" * 64, "base": "3" * 64, "arm": "4" * 64, "sums": "5" * 64}
        return ({"tag_name": "bun-v" + self.version, "prerelease": False, "draft": False, "published_at": "2026-01-01T00:00:00Z", "assets": [a("bun-linux-x64-baseline.zip", d["linux"]), a("bun-windows-x64.zip", d["std"]), a("bun-windows-x64-baseline.zip", d["base"]), a("bun-windows-aarch64.zip", d["arm"]), a("SHASUMS256.txt", d["sums"])]}, d)

    def test_resolve_requires_checksum_and_github_agreement(self):
        api, d = self.api_release()
        sums = "\n".join([f"{d['linux']}  bun-linux-x64-baseline.zip", f"{d['std']}  bun-windows-x64.zip", f"{d['base']}  bun-windows-x64-baseline.zip", f"{d['arm']}  bun-windows-aarch64.zip"]).encode()
        sums_asset = next(a for a in api["assets"] if a["name"] == "SHASUMS256.txt")
        sums_asset["size"] = len(sums); sums_asset["digest"] = "sha256:" + hashlib.sha256(sums).hexdigest()
        with patch.object(bun, "_json", side_effect=[self.manifest, api]), patch.object(bun, "_open", return_value=Response(sums)):
            result = bun.resolve_release("x86_64")
        self.assertEqual(result["version"], self.version); self.assertEqual(result["sha256"], d["linux"])
        with patch.object(bun, "_json", side_effect=[self.manifest, api]), patch.object(bun, "_open", return_value=Response(sums.replace(d["linux"].encode(), b"0" * 64))):
            with self.assertRaisesRegex(RuntimeError, "disagree"): bun.resolve_release("x86_64")

    def test_checksum_asset_bytes_must_match_metadata(self):
        api, d = self.api_release()
        sums = "\n".join([f"{d['linux']}  bun-linux-x64-baseline.zip", f"{d['std']}  bun-windows-x64.zip", f"{d['base']}  bun-windows-x64-baseline.zip", f"{d['arm']}  bun-windows-aarch64.zip"]).encode()
        sums_asset = next(a for a in api["assets"] if a["name"] == "SHASUMS256.txt")
        sums_asset["size"] = len(sums); sums_asset["digest"] = "sha256:" + "f" * 64
        with patch.object(bun, "_json", side_effect=[self.manifest, api]), patch.object(bun, "_open", return_value=Response(sums)), self.assertRaisesRegex(RuntimeError, "bytes disagree"):
            bun.resolve_release("x86_64")

    def test_manifest_urls_and_architecture_are_strict(self):
        bad = json.loads(json.dumps(self.manifest)); bad["architecture"]["64bit"]["url"][0] = "https://evil.example/bun.zip"
        with patch.object(bun, "_json", return_value=bad), self.assertRaisesRegex(RuntimeError, "Windows URLs"):
            bun.resolve_release("x86_64")
        with self.assertRaisesRegex(RuntimeError, "x86_64 only"): bun.resolve_release("aarch64")

    def test_manifest_nested_url_elements_fail_as_runtime_error(self):
        bad = json.loads(json.dumps(self.manifest)); bad["architecture"]["64bit"]["url"][0] = {"url": "not-a-string"}
        with patch.object(bun, "_json", return_value=bad), self.assertRaisesRegex(RuntimeError, "Windows URLs"):
            bun.resolve_release("x86_64")

    def test_cpuinfo_missing_or_empty_fails_loudly(self):
        with patch.object(bun.platform, "system", return_value="Linux"), patch.object(bun.platform, "machine", return_value="x86_64"), patch.object(bun.platform, "libc_ver", return_value=("glibc", "2.35")), patch.object(bun.Path, "read_text", return_value=""), self.assertRaisesRegex(RuntimeError, "SSE4.2"):
            bun._cpu_compatible()

    def test_tampered_archive_never_publishes(self):
        root = Path(tempfile.mkdtemp()) / "bun-root"
        with patch.object(bun, "_cpu_compatible"), patch.object(bun, "_open", return_value=Response(self.payload[:-1])), self.assertRaisesRegex(RuntimeError, "mismatch"):
            bun.install_release(self.release(), root)
        self.assertFalse(root.exists())

    def test_zip_layout_and_elf_are_checked(self):
        bad = self.zip_payload("bun")
        root = Path(tempfile.mkdtemp()) / "bun-root"
        rel = self.release(sha256=hashlib.sha256(bad).hexdigest(), size=str(len(bad)))
        with patch.object(bun, "_cpu_compatible"), patch.object(bun, "_open", return_value=Response(bad)), self.assertRaisesRegex(ValueError, "expected baseline"):
            bun.install_release(rel, root)
        self.assertFalse(root.exists())

    def test_zip_duplicate_entries_are_rejected(self):
        out = io.BytesIO()
        with zipfile.ZipFile(out, "w") as z:
            z.writestr("bun-linux-x64-baseline/bun", elf_fixture())
            z.writestr("bun-linux-x64-baseline/bun", elf_fixture())
        bad = out.getvalue(); root = Path(tempfile.mkdtemp()) / "bun-root"
        rel = self.release(sha256=hashlib.sha256(bad).hexdigest(), size=str(len(bad)))
        with patch.object(bun, "_cpu_compatible"), patch.object(bun, "_open", return_value=Response(bad)), self.assertRaisesRegex(ValueError, "expected baseline"):
            bun.install_release(rel, root)

    def test_success_publishes_without_executing_binary(self):
        root = Path(tempfile.mkdtemp()) / "bun-root"
        with patch.object(bun, "_cpu_compatible"), patch.object(bun, "_open", return_value=Response(self.payload)):
            bun.install_release(self.release(), root)
        self.assertTrue((root / "bun").is_file()); self.assertTrue(os.access(root / "bun", os.X_OK)); self.assertEqual((root / "bun").read_bytes()[:4], b"\x7fELF")

    def test_existing_or_symlink_destination_refused(self):
        p = Path(tempfile.mkdtemp()); existing = p / "existing"; existing.mkdir()
        with patch.object(bun, "_cpu_compatible"):
            with self.assertRaisesRegex(ValueError, "existing"): bun.validate_install(self.release(), existing)
        link = p / "link"; link.symlink_to(existing, target_is_directory=True)
        with patch.object(bun, "_cpu_compatible"), self.assertRaisesRegex(ValueError, "existing|symlink"): bun.validate_install(self.release(), link)

    def test_redirects_preserve_exact_metadata_paths_and_only_allow_official_download_cdn(self):
        import urllib.request
        handler = bun._Redirects(); source = bun.SCOOP_MANIFEST_URL
        req = urllib.request.Request(source)
        self.assertEqual(handler.redirect_request(req, None, 302, "Found", {}, source).full_url, source)
        for bad in (source.replace("bun.json", "other.json"), "https://evil.example/bun.json", source.replace("https:", "http:")):
            with self.assertRaises(RuntimeError): handler.redirect_request(req, None, 302, "Found", {}, bad)
        asset = self.release()["url"]
        cdn = "https://release-assets.githubusercontent.com/github-production-release-asset/123/file?signature=fixture"
        self.assertEqual(handler.redirect_request(urllib.request.Request(asset), None, 302, "Found", {}, cdn).full_url, cdn)


class BunPlannerTests(unittest.TestCase):
    def setUp(self):
        import linux_packages as lp
        self.lp = lp
        host = patch.object(lp, "host_info", return_value=("ubuntu", "x86_64")); host.start(); self.addCleanup(host.stop)

    def plan(self, names=None, resolver_error=None):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            for filename, key, values in (
                ("scoop-allowed.json", "apps", names or ["bulk-crap-uninstaller", "bun", "ditto"]),
                ("winget-allowed.json", "packages", [{"id": "Vendor.Unknown"}]),
                ("pnpm-allowed.json", "packages", ["pnpm-fixture"]),
                ("uv-allowed.json", "packages", ["uv-fixture"]),
                ("go-allowed.json", "packages", ["example.com/fixture"]),
            ):
                (root / filename).write_text(json.dumps({key: values}))
            with patch.object(bun, "resolve_release", return_value={"version": "1.2.3"}, side_effect=resolver_error):
                return self.lp.build_plan(root)

    def test_bun_resolved_without_unblocking_bcu_or_ditto(self):
        plan = self.plan(); actions = {a.name: a for a in plan.actions}
        self.assertEqual((actions["bun"].kind, actions["bun"].status), ("bun-archive", "planned"))
        self.assertIsNone(actions["bun"].command)
        self.assertEqual(actions["bulk-crap-uninstaller"].reason, "Windows-only package: bulk-crap-uninstaller")
        self.assertEqual(actions["ditto"].status, "blocked")
        self.assertEqual(plan.blockers[:2], [actions["bulk-crap-uninstaller"].reason, actions["ditto"].reason])

    def test_missing_metadata_stays_named_blocker(self):
        plan = self.plan(resolver_error=RuntimeError("Missing SHA256"))
        action = next(a for a in plan.actions if a.name == "bun")
        self.assertEqual(action.status, "blocked"); self.assertIn("Missing SHA256", action.reason)

    def test_missing_root_or_unsafe_destination_blocks_before_apt_changes(self):
        from unittest.mock import Mock
        plan = self.plan(["curl", "bun"]); runner = Mock()
        with patch.object(bun, "install_release") as install:
            with self.assertRaisesRegex(RuntimeError, "--bun-root"): self.lp.execute(plan, ["curl", "bun"], runner=runner)
            with patch.object(bun, "validate_install", side_effect=ValueError("unsafe destination")), self.assertRaisesRegex(ValueError, "unsafe destination"):
                self.lp.execute(plan, ["curl", "bun"], runner=runner, bun_root=Path("/synthetic/bun"))
        runner.assert_not_called(); install.assert_not_called()

    def test_explicit_bun_selection_uses_only_the_adapter(self):
        from unittest.mock import Mock
        plan = self.plan(); runner = Mock(); root = Path("/synthetic/bun")
        with patch.object(bun, "validate_install") as validate, patch.object(bun, "install_release") as install:
            report = self.lp.execute(plan, ["bun"], runner=runner, bun_root=root)
        validate.assert_called_once_with({"version": "1.2.3"}, root)
        install.assert_called_once_with({"version": "1.2.3"}, root)
        runner.assert_not_called(); self.assertEqual(report["executed"], ["bun"]); self.assertTrue(report["partial"])

    def test_mixed_global_selection_is_rejected_before_bun_publication(self):
        from unittest.mock import Mock
        plan = self.plan(); runner = Mock()
        with patch.object(bun, "validate_install"), patch.object(bun, "install_release") as install, self.assertRaisesRegex(RuntimeError, "isolated"):
            self.lp.execute(plan, ["bun", "pnpm-fixture"], runner=runner, bun_root=Path("/synthetic/bun"))
        install.assert_not_called(); runner.assert_not_called()

    def test_dry_cli_remains_dry_even_with_root_and_consent_flags(self):
        import contextlib
        plan = self.plan(); out = io.StringIO()
        with patch.object(self.lp, "build_plan", return_value=plan), patch.object(self.lp, "execute") as execute, contextlib.redirect_stdout(out):
            code = self.lp.main(["--bun-root", "/synthetic/bun", "--android-sdk-terms-accepted", "--anydesk-terms-accepted"])
        execute.assert_not_called(); self.assertEqual(code, 3)
        self.assertEqual(next(a for a in json.loads(out.getvalue())["actions"] if a["name"] == "bun")["status"], "planned")

    def test_failed_bun_download_reports_failure_not_success(self):
        plan = self.plan()
        with patch.object(bun, "validate_install"), patch.object(bun, "install_release", side_effect=ValueError("SHA256 mismatch")):
            with self.assertRaises(self.lp.PackageExecutionError) as caught:
                self.lp.execute(plan, ["bun"], bun_root=Path("/synthetic/bun"))
        self.assertEqual(caught.exception.report["executed"], [])
        self.assertEqual(caught.exception.report["failed"]["name"], "bun")


if __name__ == "__main__": unittest.main()
