import json
import contextlib
import io
import os
import subprocess
import sys
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).parents[1]))
import linux_packages as lp
ROOT = Path(__file__).parents[1]
ANDROID_RESOLVER = lp.android_tools.resolve_release
ANYDESK_RESOLVER = lp.anydesk_tools.resolve_release
ANYDESK_RELEASE = {
    "version": "9.2.3",
    "url": "https://deb.anydesk.com/pool/main/a/anydesk/anydesk_9.2.3_amd64.deb",
    "sha256": "b" * 64,
    "size": "1234",
    "checksum_source": "https://deb.anydesk.com/dists/all/main/binary-amd64/Packages",
    "terms_url": "https://anydesk.com/en/terms-conditions",
}

ANDROID_RELEASE = {
    "version": "12345678",
    "url": "https://dl.google.com/android/repository/commandlinetools-linux-12345678_latest.zip",
    "sha256": "a" * 64,
    "manifest_source": "https://raw.githubusercontent.com/ScoopInstaller/Main/master/bucket/android-clt.json",
    "checksum_source": "https://developer.android.com/studio",
    "terms_url": "https://developer.android.com/studio/terms.html",
}

class LinuxPackagesTests(unittest.TestCase):
    def setUp(self):
        host = patch.object(lp, 'host_info', return_value=('ubuntu', 'x86_64'))
        host.start()
        self.addCleanup(host.stop)
        metadata = patch.object(lp.android_tools, 'resolve_release', return_value=dict(ANDROID_RELEASE))
        metadata.start()
        self.addCleanup(metadata.stop)
        anydesk_metadata = patch.object(lp.anydesk_tools, 'resolve_release', return_value=dict(ANYDESK_RELEASE))
        anydesk_metadata.start()
        self.addCleanup(anydesk_metadata.stop)

    def test_complete_allowlists_are_accounted_for(self):
        plan = lp.build_plan(ROOT, distro="ubuntu", architecture="x86_64")
        names = {a.name for a in plan.actions}
        scoop = json.loads((ROOT / "scoop-allowed.json").read_text())["apps"]
        winget = [x["id"] for x in json.loads((ROOT / "winget-allowed.json").read_text())["packages"]]
        self.assertTrue(set(scoop) <= names); self.assertTrue(set(winget) <= names)
        self.assertTrue({"@googleworkspace/cli", "vercel", "graphifyy"} <= names)
        self.assertIn("github.com/openclaw/wacli/cmd/wacli", names)
        self.assertTrue(all(a.status in {"planned", "blocked", "covered"} for a in plan.actions))

    def test_autohotkey_removed_from_both_allowlists_and_dry_plan(self):
        scoop = json.loads((ROOT / "scoop-allowed.json").read_text())["apps"]
        winget = [x["id"] for x in json.loads((ROOT / "winget-allowed.json").read_text())["packages"]]
        self.assertNotIn("autohotkey", scoop)
        self.assertNotIn("AutoHotkey.AutoHotkey", winget)
        output = io.StringIO()
        with patch.object(lp, "execute") as execute, contextlib.redirect_stdout(output):
            status = lp.main(["--repo", str(ROOT)])
        execute.assert_not_called()
        self.assertIn(status, (0, 3))
        plan = json.loads(output.getvalue())
        for action in plan["actions"]:
            self.assertNotIn("autohotkey", json.dumps(action).lower())
        self.assertFalse(any("autohotkey" in reason.lower() for reason in plan["blockers"]))

    def helper_plan(self, apps, winget=None):
        from tempfile import TemporaryDirectory
        with TemporaryDirectory() as d:
            root = Path(d)
            for filename, key, value in (
                ("scoop-allowed.json", "apps", apps),
                ("winget-allowed.json", "packages", winget if winget is not None else [{"id": "Vendor.Tool"}]),
                ("pnpm-allowed.json", "packages", ["tool"]),
                ("uv-allowed.json", "packages", ["tool"]),
                ("go-allowed.json", "packages", ["example.com/tool"]),
            ):
                (root / filename).write_text(json.dumps({key: value}))
            return lp.build_plan(root)

    def test_anydesk_plans_official_package_and_covers_winget_duplicate(self):
        plan = lp.build_plan(ROOT)
        action = next(a for a in plan.actions if a.name == "anydesk")
        self.assertEqual(action.kind, "anydesk-deb")
        self.assertEqual(action.version, ANYDESK_RELEASE["version"])
        self.assertEqual(action.archive, ANYDESK_RELEASE)
        self.assertTrue(action.acceptance_required)
        self.assertIsNone(action.command)
        self.assertIn("Xorg", action.reason)
        duplicate = next(a for a in plan.actions if a.name == "AnyDesk.AnyDesk")
        self.assertEqual((duplicate.status, duplicate.covered_by), ("covered", "anydesk"))
        self.assertFalse(any("AnyDesk" in b for b in plan.blockers))

    def test_anydesk_fail_closed_on_metadata_errors(self):
        with patch.object(lp.anydesk_tools, "resolve_release", side_effect=ValueError("Missing SHA256")):
            plan = self.helper_plan(["anydesk"])
        action = next(a for a in plan.actions if a.name == "anydesk")
        self.assertEqual(action.status, "blocked")
        self.assertIn("Missing SHA256", action.reason)
        self.assertIn(action.reason, plan.blockers)

    def test_anydesk_terms_and_service_gate_all_selected_changes(self):
        plan = self.helper_plan(["curl", "anydesk"])
        runner = Mock()
        with patch.object(lp.anydesk_tools, "install_release") as install:
            for options in ({}, {"anydesk_terms_accepted": True}):
                with self.assertRaises((PermissionError, RuntimeError, ValueError)):
                    lp.execute(plan, ["curl", "anydesk"], runner=runner, **options)
            install.assert_not_called()
            runner.assert_not_called()

    def test_anydesk_duplicate_select_installs_native_package_once(self):
        plan = lp.build_plan(ROOT)
        runner = Mock()
        with patch.object(lp.anydesk_tools, "validate_install") as validate, patch.object(lp.anydesk_tools, "install_release") as install:
            report = lp.execute(plan, ["AnyDesk.AnyDesk"], runner=runner,
                                anydesk_terms_accepted=True, anydesk_service_allowed=True)
        validate.assert_called_once_with(ANYDESK_RELEASE, accepted_terms=True, allow_service=True)
        install.assert_called_once_with(ANYDESK_RELEASE, accepted_terms=True, allow_service=True, runner=runner)
        runner.assert_not_called()
        self.assertEqual(report["executed"], ["anydesk"])
        self.assertEqual(report["covered"], {"AnyDesk.AnyDesk": "anydesk"})

    def test_anydesk_winget_only_creates_native_target_without_other_manager_selection(self):
        plan = self.helper_plan(["curl"], winget=[{"id": "AnyDesk.AnyDesk"}])
        plan.actions.append(lp.Action("pnpm", "anydesk", ["pnpm", "add", "--global", "anydesk"]))
        self.assertEqual(len([a for a in plan.actions if a.kind == "anydesk-deb"]), 1)
        runner = Mock()
        with patch.object(lp.anydesk_tools, "validate_install"), patch.object(lp.anydesk_tools, "install_release") as install:
            report = lp.execute(plan, ["AnyDesk.AnyDesk"], runner=runner,
                                anydesk_terms_accepted=True, anydesk_service_allowed=True)
        install.assert_called_once()
        runner.assert_not_called()
        self.assertEqual(report["executed"], ["anydesk"])

    def test_anydesk_dry_cli_with_acceptance_never_executes(self):
        with patch.object(lp, "execute") as execute, contextlib.redirect_stdout(io.StringIO()):
            lp.main(["--anydesk-terms-accepted", "--anydesk-service-allowed"])
        execute.assert_not_called()

    def test_anydesk_architecture_refusal_precedes_network(self):
        with patch.object(lp.anydesk_tools, "resolve_release", side_effect=ANYDESK_RESOLVER), patch.object(lp.anydesk_tools, "_open_url") as network:
            plan = lp.build_plan(ROOT, architecture="aarch64")
        action = next(a for a in plan.actions if a.name == "anydesk")
        self.assertEqual(action.status, "blocked")
        self.assertIn("aarch64", action.reason)
        network.assert_not_called()

    def test_anydesk_failure_reports_failed_action(self):
        plan = self.helper_plan(["anydesk"])
        with patch.object(lp.anydesk_tools, "validate_install"), patch.object(lp.anydesk_tools, "install_release", side_effect=ValueError("SHA-256 mismatch")):
            with self.assertRaises(lp.PackageExecutionError) as caught:
                lp.execute(plan, ["anydesk"], anydesk_terms_accepted=True, anydesk_service_allowed=True)
        self.assertEqual(caught.exception.report["executed"], [])
        self.assertEqual(caught.exception.report["failed"], {"name": "anydesk", "error": "SHA-256 mismatch"})

    def test_android_plans_same_product_archive_not_apt_adb_or_android_cli(self):
        plan = self.helper_plan(["android-clt"])
        action = next(a for a in plan.actions if a.name == "android-clt")
        self.assertEqual(action.kind, "android-sdk-archive")
        self.assertEqual(action.status, "planned")
        self.assertEqual(action.version, ANDROID_RELEASE["version"])
        self.assertEqual(action.archive, ANDROID_RELEASE)
        self.assertEqual(action.sdk_layout, "<explicit-sdk-root>/cmdline-tools/latest")
        self.assertTrue(action.acceptance_required)
        self.assertIsNone(action.command)
        self.assertIn("sdkmanager", action.reason)
        self.assertFalse(any("android-clt" in b for b in plan.blockers))
        self.assertEqual(plan.to_dict()["actions"][0]["archive"]["sha256"], "a" * 64)

    def test_android_metadata_or_arch_failure_remains_explicit_blocker(self):
        for error in ("Missing checksum", "Version mismatch", "Unsupported architecture: aarch64"):
            with self.subTest(error=error), patch.object(lp.android_tools, "resolve_release", side_effect=RuntimeError(error)):
                plan = self.helper_plan(["android-clt"])
                action = next(a for a in plan.actions if a.name == "android-clt")
                self.assertEqual(action.status, "blocked")
                self.assertIn(error, action.reason)
                self.assertIn(action.reason, plan.blockers)

    def test_android_consent_and_root_gate_all_selected_changes(self):
        plan = self.helper_plan(["curl", "android-clt"])
        runner = Mock()
        with patch.object(lp.android_tools, "install_release") as install:
            with self.assertRaisesRegex(RuntimeError, "terms"):
                lp.execute(plan, ["curl", "android-clt"], runner=runner)
            with self.assertRaisesRegex(RuntimeError, "sdk-root"):
                lp.execute(plan, ["curl", "android-clt"], runner=runner, android_sdk_terms_accepted=True)
            runner.assert_not_called()
            install.assert_not_called()

    def test_android_execution_uses_adapter_only_with_explicit_consent_and_root(self):
        plan = self.helper_plan(["android-clt"])
        root = Path("/synthetic/new-sdk")
        runner = Mock()
        with patch.object(lp.android_tools, "validate_install") as validate, patch.object(lp.android_tools, "install_release") as install:
            report = lp.execute(plan, ["android-clt"], runner=runner,
                                android_sdk_root=root, android_sdk_terms_accepted=True)
        validate.assert_called_once_with(ANDROID_RELEASE, root, accepted_terms=True)
        install.assert_called_once_with(ANDROID_RELEASE, root, accepted_terms=True)
        runner.assert_not_called()
        self.assertEqual(report["executed"], ["android-clt"])
        self.assertTrue(report["partial"])

    def test_android_invalid_destination_prevents_other_selected_installs(self):
        plan = self.helper_plan(["curl", "android-clt"])
        runner = Mock()
        with patch.object(lp.android_tools, "validate_install", side_effect=RuntimeError("Refusing existing SDK")), patch.object(lp.android_tools, "install_release") as install:
            with self.assertRaisesRegex(RuntimeError, "existing SDK"):
                lp.execute(plan, ["curl", "android-clt"], runner=runner,
                           android_sdk_root=Path("/synthetic/sdk"), android_sdk_terms_accepted=True)
            runner.assert_not_called()
            install.assert_not_called()

    def test_android_dry_run_even_with_consent_never_downloads(self):
        plan = self.helper_plan(["android-clt"])
        with patch.object(lp, "build_plan", return_value=plan), patch.object(lp, "execute") as execute, contextlib.redirect_stdout(io.StringIO()):
            lp.main(["--android-sdk-terms-accepted", "--android-sdk-root", "/synthetic/sdk"])
        execute.assert_not_called()

    def test_android_cli_reports_validation_and_corrupt_zip_errors_as_json(self):
        for error in (ValueError("bad SDK destination"), lp.zipfile.BadZipFile("bad ZIP")):
            output = io.StringIO()
            with self.subTest(error=error), patch.object(lp, "execute", side_effect=error), contextlib.redirect_stdout(output):
                code = lp.main(["--repo", str(ROOT), "--execute", "--select", "android-clt",
                                "--android-sdk-terms-accepted", "--android-sdk-root", "/synthetic/sdk"])
            self.assertEqual(code, 1)
            self.assertEqual(json.loads(output.getvalue())["error"], str(error))

    def test_android_architecture_blocker_never_fetches_metadata_or_installs(self):
        with patch.object(lp.android_tools, "resolve_release", side_effect=ANDROID_RESOLVER), patch.object(lp.android_tools, "_open_url") as network:
            plan = lp.build_plan(ROOT, distro="ubuntu", architecture="aarch64")
        android = next(a for a in plan.actions if a.name == "android-clt")
        self.assertEqual(android.status, "blocked")
        self.assertIn("aarch64", android.reason)
        network.assert_not_called()
        with patch.object(lp, "host_info", return_value=("ubuntu", "aarch64")), patch.object(lp.android_tools, "install_release") as install:
            with self.assertRaisesRegex(RuntimeError, "Unresolved blockers"):
                lp.execute(plan, ["android-clt"], android_sdk_terms_accepted=True,
                           android_sdk_root=Path("/synthetic/sdk"))
        install.assert_not_called()

    def test_android_failure_reports_prior_selected_actions_and_failed_action(self):
        plan = self.helper_plan(["curl", "android-clt"])
        runner = Mock(return_value=subprocess.CompletedProcess([], 0, stdout="Candidate: 1.0\n"))
        with patch.object(lp.android_tools, "validate_install"), patch.object(lp.android_tools, "install_release", side_effect=ValueError("SHA-256 checksum mismatch")):
            with self.assertRaises(lp.PackageExecutionError) as caught:
                lp.execute(plan, ["curl", "android-clt"], runner=runner,
                           android_sdk_terms_accepted=True, android_sdk_root=Path("/synthetic/sdk"))
        report = caught.exception.report
        self.assertEqual(report["executed"], ["curl"])
        self.assertEqual(report["failed"], {"name": "android-clt", "error": "SHA-256 checksum mismatch"})
        output = io.StringIO()
        with patch.object(lp, "build_plan", return_value=plan), patch.object(lp, "execute", side_effect=caught.exception), contextlib.redirect_stdout(output):
            code = lp.main(["--execute", "--select", "android-clt"])
        self.assertEqual(code, 1)
        self.assertEqual(json.loads(output.getvalue())["report"], report)

    def test_extractor_helper_is_explicitly_covered_without_duplicate_install(self):
        for apps in (["7zip", "7zip19.00-helper"], ["7zip19.00-helper", "7zip"], ["7zip19.00-helper"]):
            with self.subTest(apps=apps):
                plan = self.helper_plan(apps)
                helper = next(a for a in plan.actions if a.name == "7zip19.00-helper")
                self.assertEqual(helper.status, "covered")
                self.assertEqual(helper.covered_by, "7zip")
                self.assertIsNone(helper.command)
                self.assertIn("version pin does not apply", helper.reason)
                self.assertFalse(any("7zip19.00-helper" in b for b in plan.blockers))
                installs = [a for a in plan.actions if a.kind == "apt" and a.status == "planned"]
                self.assertEqual(len(installs), 1)
                self.assertEqual(installs[0].name, "7zip")
                self.assertEqual(installs[0].command[-3:], ["install", "-y", "7zip"])

    def test_selecting_helper_runs_only_native_target_after_preflight(self):
        plan = self.helper_plan(["7zip19.00-helper", "7zip"])
        runner = Mock(return_value=subprocess.CompletedProcess([], 0, stdout="Candidate: 1.0\n"))
        report = lp.execute(plan, ["7zip19.00-helper"], runner=runner)
        self.assertEqual(runner.call_count, 2)
        self.assertEqual(runner.call_args_list[0].args[0], ["apt-cache", "policy", "7zip"])
        self.assertEqual(runner.call_args_list[1].args[0][-3:], ["install", "-y", "7zip"])
        self.assertEqual(report["executed"], ["7zip"])
        self.assertEqual(report["covered"], {"7zip19.00-helper": "7zip"})
        self.assertNotIn("7zip19.00-helper", report["skipped"])
        self.assertTrue(report["partial"])

    def test_helper_selection_does_not_select_same_named_other_manager_action(self):
        plan = self.helper_plan(["7zip19.00-helper", "7zip"])
        plan.actions.append(lp.Action("pnpm", "7zip", ["pnpm", "add", "--global", "--", "7zip"]))
        runner = Mock(return_value=subprocess.CompletedProcess([], 0, stdout="Candidate: 1.0\n"))
        report = lp.execute(plan, ["7zip19.00-helper"], runner=runner)
        self.assertEqual(runner.call_count, 2)
        self.assertTrue(all(call.args[0][0] != "pnpm" for call in runner.call_args_list))
        self.assertEqual(report["executed"], ["7zip"])
        self.assertEqual(report["covered"], {"7zip19.00-helper": "7zip"})

    def test_non_apt_name_collision_cannot_satisfy_native_coverage(self):
        plan = self.helper_plan(["7zip19.00-helper"])
        plan.actions = [a for a in plan.actions if a.name != "7zip"]
        plan.actions.append(lp.Action("pnpm", "7zip", ["pnpm", "add", "--global", "--", "7zip"]))
        runner = Mock()
        with self.assertRaisesRegex(RuntimeError, "Missing planned native coverage target"):
            lp.execute(plan, ["7zip19.00-helper"], runner=runner)
        runner.assert_not_called()

    def test_selecting_native_target_also_reports_helper_coverage(self):
        plan = self.helper_plan(["7zip19.00-helper", "7zip"])
        runner = Mock(return_value=subprocess.CompletedProcess([], 0, stdout="Candidate: 1.0\n"))
        report = lp.execute(plan, ["7zip"], runner=runner)
        self.assertEqual(report["executed"], ["7zip"])
        self.assertEqual(report["covered"], {"7zip19.00-helper": "7zip"})
        self.assertNotIn("7zip19.00-helper", report["skipped"])
        self.assertEqual(runner.call_count, 2)

    def test_unrelated_selection_does_not_claim_helper_coverage(self):
        plan = self.helper_plan(["7zip19.00-helper", "7zip"])
        runner = Mock(return_value=subprocess.CompletedProcess([], 0))
        report = lp.execute(plan, ["example.com/tool"], runner=runner)
        self.assertEqual(report["covered"], {})
        self.assertIn("7zip19.00-helper", report["skipped"])
        self.assertIn("7zip", report["skipped"])
        self.assertEqual(report["executed"], ["example.com/tool"])

    def test_full_execution_covers_helper_once_and_keeps_blocker_guard(self):
        plan = self.helper_plan(["7zip19.00-helper", "7zip"])
        runner = Mock(return_value=subprocess.CompletedProcess([], 0, stdout="Candidate: 1.0\n"))
        with self.assertRaisesRegex(RuntimeError, "blockers"):
            lp.execute(plan, runner=runner)
        runner.assert_not_called()
        plan.actions = [a for a in plan.actions if a.name in {"7zip", "7zip19.00-helper"}]
        plan.blockers = []
        report = lp.execute(plan, runner=runner)
        self.assertEqual(report["executed"], ["7zip"])
        self.assertEqual(report["covered"], {"7zip19.00-helper": "7zip"})
        self.assertEqual(report["skipped"], [])
        self.assertFalse(report["partial"])
        self.assertEqual(runner.call_count, 2)

    def test_helper_cannot_bypass_missing_candidate_or_missing_target(self):
        plan = self.helper_plan(["7zip19.00-helper"])
        runner = Mock(return_value=subprocess.CompletedProcess([], 0, stdout="Candidate: (none)\n"))
        with self.assertRaisesRegex(RuntimeError, "No apt candidate"):
            lp.execute(plan, ["7zip19.00-helper"], runner=runner)
        self.assertEqual(runner.call_count, 1)
        plan.actions = [a for a in plan.actions if a.name != "7zip"]
        runner.reset_mock()
        with self.assertRaisesRegex(RuntimeError, "Missing planned native coverage target"):
            lp.execute(plan, ["7zip19.00-helper"], runner=runner)
        runner.assert_not_called()

    def test_helper_dry_plan_serializes_coverage_and_never_executes(self):
        plan = self.helper_plan(["7zip19.00-helper"])
        output = io.StringIO()
        with patch.object(lp, "build_plan", return_value=plan), patch.object(lp, "execute") as execute, contextlib.redirect_stdout(output):
            self.assertEqual(lp.main([]), 3)
        execute.assert_not_called()
        helper = next(a for a in json.loads(output.getvalue())["actions"] if a["name"] == "7zip19.00-helper")
        self.assertEqual(helper["covered_by"], "7zip")
        self.assertEqual(helper["status"], "covered")
        self.assertIsNone(helper["command"])

    def test_go_version_tags_and_string_declaration(self):
        plan = lp.build_plan(ROOT, distro="debian", architecture="aarch64")
        action = next(a for a in plan.actions if a.name.endswith("/wacli/cmd/wacli"))
        self.assertEqual(action.version, "v0.15.0"); self.assertEqual(action.tags, ["sqlite_fts5"])
        self.assertEqual(action.command, ["go", "install", "-tags", "sqlite_fts5", "github.com/openclaw/wacli/cmd/wacli@v0.15.0"])
        self.assertIsNotNone(lp.build_plan(ROOT, distro="ubuntu", architecture="x86_64"))

    def test_unsupported_distro_and_architecture_fail_closed(self):
        for distro, arch in (("fedora", "x86_64"), ("ubuntu", "armv7l")):
            plan = lp.build_plan(ROOT, distro=distro, architecture=arch)
            self.assertFalse(plan.supported); self.assertFalse(plan.actions); self.assertTrue(plan.blockers)

    def test_windows_vendor_and_variant_items_are_explicit_blockers(self):
        plan = lp.build_plan(ROOT, distro="ubuntu", architecture="x86_64")
        blocked = {a.name: a.reason for a in plan.actions if a.status == "blocked"}
        for item in ("ditto", "GPSoftware.DirectoryOpus", "cloudflared", "nodejs-lts", "mpv-git"):
            self.assertIn(item, blocked); self.assertTrue(blocked[item])
        mapped = {a.name for a in plan.actions if a.status == 'planned'}
        self.assertTrue({'qbittorrent', 'rclone', 'yt-dlp', 'syncplay'} <= mapped)
        for item in ('pwsh', 'discord'):
            self.assertIn('No validated Linux', blocked[item])

    def test_pip_freeze_required_for_backup_root_and_windows_lines_blocked(self):
        from tempfile import TemporaryDirectory
        with TemporaryDirectory() as d:
            root = Path(d); plan = lp.build_plan(ROOT, backup_root=root, distro="ubuntu", architecture="x86_64")
            self.assertTrue(any("pip-freeze.txt" in x for x in plan.blockers))
            (root / "pip-freeze.txt").write_text("requests==2.32.0\npywin32==306\n")
            plan = lp.build_plan(ROOT, backup_root=root, distro="ubuntu", architecture="x86_64")
            self.assertTrue(any(a.status == "blocked" and a.name == "pip-freeze.txt" for a in plan.actions))
            self.assertTrue(any("pywin32" in x for x in plan.blockers))

    def test_execute_rejects_unknown_select_and_blockers_before_runner(self):
        plan = lp.build_plan(ROOT, distro="ubuntu", architecture="x86_64")
        runner = Mock(side_effect=AssertionError("must not run"))
        with self.assertRaisesRegex(RuntimeError, "Unknown"):
            lp.execute(plan, ["not-an-action"], runner=runner)
        with self.assertRaisesRegex(RuntimeError, "blockers"):
            lp.execute(plan, runner=runner)

    def test_execute_preflights_apt_and_never_uses_shell(self):
        plan = lp.Plan(True, "ubuntu", "x86_64", [lp.Action("apt", "safe", ["sudo", "-n", "apt-get", "install", "-y", "curl"])])
        calls = []
        def runner(command, **kwargs):
            calls.append((command, kwargs))
            if command[0] == "apt-cache": return subprocess.CompletedProcess(command, 0, stdout="Candidate: 1.0\n")
            return subprocess.CompletedProcess(command, 7)
        with self.assertRaisesRegex(RuntimeError, "safe failed"): lp.execute(plan, runner=runner)
        self.assertEqual(len(calls), 2); self.assertFalse(calls[0][1]["shell"]); self.assertFalse(calls[1][1]["shell"])
        self.assertEqual(calls[1][0][:2], ["sudo", "-n"])
        self.assertEqual(calls[0][1]["timeout"], 30); self.assertEqual(calls[1][1]["timeout"], 300)

    def test_root_apt_action_does_not_require_sudo(self):
        with patch.object(lp.os, "geteuid", return_value=0):
            plan = lp.build_plan(ROOT, distro="ubuntu", architecture="x86_64")
        action = next(a for a in plan.actions if a.kind == "apt" and a.status == "planned")
        self.assertEqual(action.command[:3], ["apt-get", "install", "-y"])

    def test_non_root_apt_action_uses_noninteractive_sudo(self):
        with patch.object(lp.os, "geteuid", return_value=1000):
            plan = lp.build_plan(ROOT, distro="ubuntu", architecture="x86_64")
        action = next(a for a in plan.actions if a.kind == "apt" and a.status == "planned")
        self.assertEqual(action.command[:3], ["sudo", "-n", "apt-get"])

    def test_winget_ids_must_be_nonempty_strings(self):
        from tempfile import TemporaryDirectory
        with TemporaryDirectory() as d:
            root = Path(d)
            for filename, key, value in (
                ("scoop-allowed.json", "apps", ["curl"]),
                ("winget-allowed.json", "packages", [{"id": []}, {"id": "  "}, None, 42, {"id": "Vendor.Valid"}]),
                ("pnpm-allowed.json", "packages", ["tool"]),
                ("uv-allowed.json", "packages", [{"name": "tool"}]),
                ("go-allowed.json", "packages", ["example.com/tool"]),
            ):
                (root / filename).write_text(json.dumps({key: value}))
            plan = lp.build_plan(root, distro="ubuntu", architecture="x86_64")
        invalid = [a for a in plan.actions if a.kind == "winget" and a.status == "blocked"]
        self.assertEqual(len(invalid), 5)
        self.assertTrue(all("Invalid WinGet package ID" in a.reason for a in invalid[:4]))
        self.assertIsInstance(next(a for a in invalid if a.name == "Vendor.Valid").name, str)

    def test_install_timeout_is_reported_and_never_shells(self):
        plan = lp.Plan(True, "ubuntu", "x86_64", [lp.Action("pnpm", "tool", ["pnpm", "add", "--global", "--", "tool"])])
        def runner(command, **kwargs):
            raise subprocess.TimeoutExpired(command, kwargs["timeout"])
        with self.assertRaisesRegex(RuntimeError, "timed out"):
            lp.execute(plan, runner=runner)

    def test_cli_returns_json_for_timeout(self):
        output = io.StringIO()
        timeout = subprocess.TimeoutExpired(["pnpm"], 300)
        with patch.object(lp, "execute", side_effect=timeout), contextlib.redirect_stdout(output):
            self.assertEqual(lp.main(["--repo", str(ROOT), "--execute", "--select", "@googleworkspace/cli", "--distro", "ubuntu", "--arch", "x86_64"]), 1)
        self.assertIn("timed out", json.loads(output.getvalue())["error"])

    def test_existing_venv_is_never_overwritten(self):
        from tempfile import TemporaryDirectory
        with TemporaryDirectory() as d:
            old = Path.cwd()
            try:
                import os; os.chdir(d); Path(".linux-restore-venv").mkdir()
                plan = lp.Plan(True, "ubuntu", "x86_64", [lp.Action("pip-venv", "x", ["echo", "x"])])
                with self.assertRaisesRegex(RuntimeError, "Refusing to overwrite"): lp.execute(plan, runner=Mock())
            finally: os.chdir(old)

    def test_default_cli_is_json_dry_plan(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            self.assertEqual(lp.main(["--repo", str(ROOT), "--distro", "ubuntu", "--arch", "x86_64"]), 3)
        self.assertTrue(json.loads(output.getvalue())['blockers'])

    def test_execute_host_override_cannot_bypass_guard(self):
        plan = lp.build_plan(ROOT, distro='debian', architecture='x86_64')
        with self.assertRaisesRegex(RuntimeError, 'does not match'):
            lp.execute(plan, ['curl'], runner=Mock(side_effect=AssertionError('must not run')))

    def test_missing_allowlists_fail_closed(self):
        from tempfile import TemporaryDirectory
        with TemporaryDirectory() as d:
            plan = lp.build_plan(Path(d))
            self.assertEqual(len(plan.blockers), 5)
            with self.assertRaisesRegex(RuntimeError, 'blockers'):
                lp.execute(plan, runner=Mock(side_effect=AssertionError('must not run')))

    def test_apt_missing_candidate_prevents_every_install(self):
        plan = lp.Plan(True, 'ubuntu', 'x86_64', [lp.Action('apt', 'safe', ['sudo', '-n', 'apt-get', 'install', '-y', 'curl'])])
        runner = Mock(return_value=subprocess.CompletedProcess([], 0, stdout='Candidate: (none)\n'))
        with self.assertRaisesRegex(RuntimeError, 'No apt candidate'):
            lp.execute(plan, runner=runner)
        self.assertEqual(runner.call_count, 1)
        self.assertEqual(runner.call_args.args[0][0], 'apt-cache')

if __name__ == "__main__": unittest.main()
