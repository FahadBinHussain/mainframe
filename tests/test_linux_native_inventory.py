"""Offline integration guards; no real downloads, commands, or home changes."""
import contextlib
import io
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).parents[1]))
import linux_packages as lp

ROOT = Path(__file__).parents[1]


class NativeInventoryTests(unittest.TestCase):
    def setUp(self):
        host = patch.object(lp, "host_info", return_value=("ubuntu", "x86_64"))
        host.start(); self.addCleanup(host.stop)

    def fixture_plan(self, names):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            for filename, key, values in (
                ("scoop-allowed.json", "apps", names),
                ("winget-allowed.json", "packages", [{"id": "Vendor.Unknown"}]),
                ("pnpm-allowed.json", "packages", ["tool"]),
                ("uv-allowed.json", "packages", ["tool"]),
                ("go-allowed.json", "packages", ["example.com/tool"]),
            ):
                (root / filename).write_text(json.dumps({key: values}))
            with patch.object(lp, "_native_release", side_effect=lambda n, a: {"name": n, "version": "1.2.3"}):
                return lp.build_plan(root)

    def test_all_new_products_plan_without_substitutes_or_commands(self):
        names = sorted(lp.NATIVE_PACKAGES)
        plan = self.fixture_plan(names)
        for name in names:
            action = next(a for a in plan.actions if a.name == name)
            kind = "bun-archive" if name == "bun" else "native-archive"
            self.assertEqual((action.kind, action.status, action.version), (kind, "planned", "1.2.3"))
            self.assertIsNone(action.command)
            self.assertFalse(action.acceptance_required)
            self.assertIn("not runtime validation", action.reason)

    def test_metadata_failure_is_an_explicit_named_blocker(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            for filename, key, value in (("scoop-allowed.json", "apps", ["bun"]),
                                         ("winget-allowed.json", "packages", ["Unknown"]),
                                         ("pnpm-allowed.json", "packages", ["tool"]),
                                         ("uv-allowed.json", "packages", ["tool"]),
                                         ("go-allowed.json", "packages", ["example.com/tool"])):
                (root / filename).write_text(json.dumps({key: value}))
            with patch.object(lp, "_native_release", side_effect=RuntimeError("missing official digest")):
                plan = lp.build_plan(root)
        action = plan.actions[0]
        self.assertEqual(action.status, "blocked")
        self.assertIn("missing official digest", action.reason)
        self.assertIn(action.reason, plan.blockers)

    def test_bcu_and_all_uncertain_products_remain_explicitly_blocked(self):
        names = ["bulk-crap-uninstaller", *lp.NATIVE_REVIEW_REASONS]
        plan = self.fixture_plan(names)
        for name in names:
            action = next(a for a in plan.actions if a.name == name)
            self.assertEqual(action.status, "blocked")
            self.assertIn(action.reason, plan.blockers)
        bcu = plan.actions[0]
        self.assertEqual(bcu.reason, "Windows-only package: bulk-crap-uninstaller")
        self.assertIsNone(bcu.command)

    def test_missing_root_blocks_all_selected_changes_before_apt(self):
        plan = self.fixture_plan(["curl", "bun"])
        runner = Mock()
        with patch.object(lp.bun_tools, "install_release") as install:
            with self.assertRaisesRegex(RuntimeError, "--native-root bun=PATH"):
                lp.execute(plan, ["curl", "bun"], runner=runner)
        runner.assert_not_called(); install.assert_not_called()

    def test_each_product_dispatches_only_its_adapter_without_subprocess(self):
        for name in sorted(lp.NATIVE_PACKAGES):
            with self.subTest(name=name):
                plan = self.fixture_plan([name])
                adapter = lp._native_adapter(name)
                runner = Mock()
                root = Path("/synthetic") / name
                with patch.object(adapter, "validate_install") as validate, patch.object(adapter, "install_release") as install:
                    report = lp.execute(plan, [name], runner=runner, native_roots={name: root})
                validate.assert_called_once(); install.assert_called_once()
                self.assertEqual(report["executed"], [name]); self.assertTrue(report["partial"])
                runner.assert_not_called()

    def test_product_mismatch_blocks_before_download_or_other_changes(self):
        plan = self.fixture_plan(["curl", "deno"])
        next(a for a in plan.actions if a.name == "deno").archive["name"] = "yq"
        runner = Mock()
        with patch.object(lp.github_native_tools, "install_release") as install:
            with self.assertRaisesRegex(RuntimeError, "product does not match"):
                lp.execute(plan, ["curl", "deno"], runner=runner,
                           native_roots={"deno": Path("/synthetic/deno")})
        install.assert_not_called(); runner.assert_not_called()

    def test_duplicate_roots_and_invalid_root_prevent_partial_execution(self):
        plan = self.fixture_plan(["curl", "bun", "deno"])
        runner = Mock()
        roots = {n: Path("/synthetic/shared") for n in ("bun", "deno")}
        with patch.object(lp.bun_tools, "validate_install"), patch.object(lp.bun_tools, "install_release") as install:
            with self.assertRaisesRegex(RuntimeError, "distinct installation roots"):
                lp.execute(plan, ["curl", "bun", "deno"], runner=runner, native_roots=roots)
        runner.assert_not_called(); install.assert_not_called()
        with patch.object(lp.bun_tools, "validate_install", side_effect=ValueError("unsafe root")):
            with self.assertRaisesRegex(ValueError, "unsafe root"):
                lp.execute(plan, ["curl", "bun"], runner=runner, native_roots={"bun": Path("/synthetic/bun")})
        runner.assert_not_called()

    def test_failure_reports_exact_native_action_and_no_false_success(self):
        plan = self.fixture_plan(["bun"])
        with patch.object(lp.bun_tools, "validate_install"), patch.object(lp.bun_tools, "install_release", side_effect=ValueError("checksum mismatch")):
            with self.assertRaises(lp.PackageExecutionError) as caught:
                lp.execute(plan, ["bun"], native_roots={"bun": Path("/synthetic/bun")})
        self.assertEqual(caught.exception.report["executed"], [])
        self.assertEqual(caught.exception.report["failed"], {"name": "bun", "error": "checksum mismatch"})

    def test_dry_cli_never_executes_even_with_roots_and_vendor_consent(self):
        plan = self.fixture_plan(["bun", "bulk-crap-uninstaller"])
        out = io.StringIO()
        with patch.object(lp, "build_plan", return_value=plan), patch.object(lp, "execute") as execute, contextlib.redirect_stdout(out):
            code = lp.main(["--native-root", "bun=/synthetic/bun", "--anydesk-terms-accepted", "--android-sdk-terms-accepted"])
        execute.assert_not_called(); self.assertEqual(code, 3)
        self.assertEqual(json.loads(out.getvalue())["actions"][1]["status"], "blocked")

    def test_cli_rejects_unknown_duplicate_or_malformed_roots_before_planning(self):
        for values in (["unknown=/synthetic/x"], ["bun="], ["bun"], ["bun=/a", "bun=/b"]):
            args = [piece for value in values for piece in ("--native-root", value)]
            with self.subTest(values=values), patch.object(lp, "build_plan") as build, contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit): lp.main(args)
                build.assert_not_called()

    def test_global_manager_operations_are_named_blockers_not_silent_skips(self):
        plan = self.fixture_plan(["curl"])
        managers = [a for a in plan.actions if a.kind in {"pnpm", "uv", "go"}]
        self.assertEqual(len(managers), 3)
        for action in managers:
            self.assertEqual(action.status, "blocked")
            self.assertIsNotNone(action.command)
            self.assertIn(action.reason, plan.blockers)
            self.assertIn("destination preflight", action.reason)

    def test_even_handbuilt_global_actions_fail_before_earlier_native_or_apt_changes(self):
        for kind in ("pnpm", "uv", "go", "pip-venv", "pip-install", "unknown"):
            plan = lp.Plan(True, "ubuntu", "x86_64", [
                lp.Action("apt", "curl", ["apt-get", "install", "-y", "curl"]),
                lp.Action(kind, "unsafe", ["synthetic-command"])])
            runner = Mock()
            with self.subTest(kind=kind), self.assertRaisesRegex(RuntimeError, "Unvalidated command/runtime/destination"):
                lp.execute(plan, runner=runner)
            runner.assert_not_called()

    def test_missing_apt_executable_blocks_before_any_native_install(self):
        plan = self.fixture_plan(["curl", "bun"])
        runner = Mock()
        with patch.object(lp.bun_tools, "validate_install"), patch.object(lp.bun_tools, "install_release") as install, patch.object(lp.shutil, "which", return_value=None):
            with self.assertRaisesRegex(RuntimeError, "Required package command"):
                lp.execute(plan, ["curl", "bun"], runner=runner, native_roots={"bun": Path("/synthetic/bun")})
        runner.assert_not_called(); install.assert_not_called()

    def test_github_redirect_dispatch_and_exact_path_confinement(self):
        import urllib.request
        handler = lp.github_native_tools._Redirects()
        raw = "https://raw.githubusercontent.com/ScoopInstaller/Main/master/bucket/deno.json"
        request = urllib.request.Request(raw)
        redirected = handler.redirect_request(request, None, 302, "Found", {}, raw)
        self.assertEqual(redirected.full_url, raw)
        for bad in (raw.replace("deno.json", "other.json"), "https://evil.example/x", raw.replace("https:", "http:")):
            with self.assertRaises(RuntimeError): handler.redirect_request(request, None, 302, "Found", {}, bad)
        asset = "https://github.com/denoland/deno/releases/download/v1.2.3/deno-x86_64-unknown-linux-gnu.zip"
        cdn = "https://release-assets.githubusercontent.com/github-production-release-asset/123/file?signature=synthetic"
        redirected = handler.redirect_request(urllib.request.Request(asset), None, 302, "Found", {}, cdn)
        self.assertEqual(redirected.full_url, cdn)


if __name__ == "__main__":
    unittest.main()
