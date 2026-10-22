import json
import contextlib
import io
import subprocess
import sys
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).parents[1]))
import linux_packages as lp
ROOT = Path(__file__).parents[1]

class LinuxPackagesTests(unittest.TestCase):
    def setUp(self):
        host = patch.object(lp, 'host_info', return_value=('ubuntu', 'x86_64'))
        host.start()
        self.addCleanup(host.stop)

    def test_complete_allowlists_are_accounted_for(self):
        plan = lp.build_plan(ROOT, distro="ubuntu", architecture="x86_64")
        names = {a.name for a in plan.actions}
        scoop = json.loads((ROOT / "scoop-allowed.json").read_text())["apps"]
        winget = [x["id"] for x in json.loads((ROOT / "winget-allowed.json").read_text())["packages"]]
        self.assertTrue(set(scoop) <= names); self.assertTrue(set(winget) <= names)
        self.assertTrue({"@googleworkspace/cli", "vercel", "graphifyy"} <= names)
        self.assertIn("github.com/openclaw/wacli/cmd/wacli", names)
        self.assertTrue(all(a.status in {"planned", "blocked"} for a in plan.actions))

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
        for item in ("ditto", "AnyDesk.AnyDesk", "cloudflared", "nodejs-lts", "mpv-git"):
            self.assertIn(item, blocked); self.assertTrue(blocked[item])
        mapped = {a.name for a in plan.actions if a.status == 'planned'}
        self.assertTrue({'qbittorrent', 'rclone', 'yt-dlp', 'syncplay'} <= mapped)
        for item in ('pwsh', 'anydesk', 'discord'):
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
