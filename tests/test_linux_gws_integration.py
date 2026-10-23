"""Offline integration only: never download an archive or invoke a product CLI."""
import contextlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).parents[1]))
import linux_packages as lp

PACKAGE = "@googleworkspace/cli"


class GwsIntegrationTests(unittest.TestCase):
    def setUp(self):
        host = patch.object(lp, "host_info", return_value=("ubuntu", "x86_64"))
        host.start()
        self.addCleanup(host.stop)

    def fixture(self, repo, *, gws_root=None, backup_root=None):
        for filename, key, entries in (
            ("scoop-allowed.json", "apps", ["curl"]),
            ("winget-allowed.json", "packages", [{"id": "Vendor.Unknown"}]),
            ("pnpm-allowed.json", "packages", [PACKAGE, "vercel"]),
            ("uv-allowed.json", "packages", ["graphifyy"]),
            ("go-allowed.json", "packages", ["example.com/tool"]),
        ):
            (repo / filename).write_text(json.dumps({key: entries}))
        with patch.object(lp.gws_tools, "resolve_release", return_value={"version": "1.2.3", "sha256": "a" * 64}):
            return lp.build_plan(repo, backup_root=backup_root, gws_root=gws_root)

    def test_official_route_is_not_a_global_install_or_script_suppression(self):
        with tempfile.TemporaryDirectory() as td:
            plan = self.fixture(Path(td))
        action = next(a for a in plan.actions if a.name == PACKAGE)
        self.assertEqual((action.kind, action.status, action.version), ("gws-archive", "planned", "1.2.3"))
        self.assertEqual(action.source, "pnpm")
        self.assertIsNone(action.command)
        self.assertIn("not skipped scripts", action.reason)
        self.assertIsNone(action.dry_plan["layout"])
        for name in ("vercel", "graphifyy", "example.com/tool"):
            self.assertEqual(next(a for a in plan.actions if a.name == name).status, "blocked")
        self.assertFalse(any(PACKAGE in reason for reason in plan.blockers))

    def test_missing_or_invalid_root_prevents_earlier_apt_mutation(self):
        with tempfile.TemporaryDirectory() as td:
            plan = self.fixture(Path(td))
            runner = Mock()
            with patch.object(lp.gws_tools, "install_release") as install:
                with self.assertRaisesRegex(RuntimeError, "--gws-root"):
                    lp.execute(plan, ["curl", PACKAGE], runner=runner)
                with patch.object(lp.gws_tools, "validate_install", side_effect=ValueError("unsafe root")):
                    with self.assertRaisesRegex(ValueError, "unsafe root"):
                        lp.execute(plan, ["curl", PACKAGE], runner=runner, gws_root=Path(td).parent / (Path(td).name + "-new"))
            runner.assert_not_called()
            install.assert_not_called()

    def test_explicit_selection_dispatches_only_adapter_not_runner(self):
        with tempfile.TemporaryDirectory() as td:
            plan = self.fixture(Path(td))
            runner = Mock()
            root = Path(td) / "install"
            with patch.object(lp.gws_tools, "validate_install") as validate, patch.object(lp.gws_tools, "install_release") as install:
                # Install outside the manifest/source tree.
                root = Path(td).parent / (Path(td).name + "-gws")
                report = lp.execute(plan, [PACKAGE], runner=runner, gws_root=root)
            validate.assert_called_once()
            install.assert_called_once()
            runner.assert_not_called()
            self.assertEqual(report["executed"], [PACKAGE])

    def test_source_and_backup_overlap_are_rejected_before_download(self):
        with tempfile.TemporaryDirectory() as td:
            repo = Path(td) / "repo"
            repo.mkdir()
            backup = Path(td) / "backup"
            backup.mkdir()
            plan = self.fixture(repo, backup_root=backup)
            for root in (repo / "new", backup / "new", Path(td)):
                with self.subTest(root=root), patch.object(lp.gws_tools, "validate_install") as validate:
                    with self.assertRaisesRegex(ValueError, "repository or backup"):
                        lp.execute(plan, [PACKAGE], gws_root=root)
                    validate.assert_not_called()
            with patch.object(lp.gws_tools, "layout_plan") as layout:
                blocked = self.fixture(repo, gws_root=backup / "new", backup_root=backup)
            layout.assert_not_called()
            self.assertEqual(next(a for a in blocked.actions if a.name == PACKAGE).status, "blocked")

    def test_gws_and_other_selected_root_overlap_is_rejected(self):
        for other in ("/tmp/isolated-gws", "/tmp/isolated-gws/child", "/tmp"):
            plan = lp.Plan(True, "ubuntu", "x86_64", [
                lp.Action("gws-archive", PACKAGE, version="1.2.3", archive={"version": "1.2.3"},
                          dry_plan={"route": "official-native-archive", "protected_roots": ["/fixture/repo"], "layout": None}),
                lp.Action("bun-archive", "bun", archive={})], protected_roots=("/fixture/repo",))
            with self.subTest(other=other), patch.object(lp.gws_tools, "validate_install"), patch.object(lp.bun_tools, "validate_install"), patch.object(lp.gws_tools, "install_release") as install:
                with self.assertRaisesRegex(RuntimeError, "non-overlapping"):
                    lp.execute(plan, [PACKAGE, "bun"], gws_root=Path("/tmp/isolated-gws"), native_roots={"bun": Path(other)})
                install.assert_not_called()

    def test_execution_root_must_match_preview(self):
        with tempfile.TemporaryDirectory() as td:
            repo = Path(td) / "repo"
            repo.mkdir()
            a, b = Path(td) / "previewed", Path(td) / "different"
            with patch.object(lp.gws_tools, "layout_plan", return_value={"root": str(a)}):
                plan = self.fixture(repo, gws_root=a)
            runner = Mock()
            with patch.object(lp.gws_tools, "validate_install") as validate, patch.object(lp.gws_tools, "install_release") as install:
                with self.assertRaisesRegex(RuntimeError, "differs from the preview"):
                    lp.execute(plan, ["curl", PACKAGE], gws_root=b, runner=runner)
            validate.assert_not_called()
            install.assert_not_called()
            runner.assert_not_called()

    def test_missing_or_altered_source_context_fails_before_adapter_or_apt(self):
        with tempfile.TemporaryDirectory() as td:
            for mode in ("missing-detail", "missing-context", "altered-detail", "wrong-version"):
                with self.subTest(mode=mode):
                    plan = self.fixture(Path(td))
                    action = next(a for a in plan.actions if a.name == PACKAGE)
                    if mode == "missing-detail": action.dry_plan = None
                    elif mode == "missing-context": plan.protected_roots = ()
                    elif mode == "altered-detail": action.dry_plan["protected_roots"] = []
                    else: action.version = "9.9.9"
                    runner = Mock()
                    with patch.object(lp.gws_tools, "validate_install") as validate, patch.object(lp.gws_tools, "install_release") as install:
                        with self.assertRaisesRegex(RuntimeError, "planner provenance"):
                            lp.execute(plan, ["curl", PACKAGE], gws_root=Path(td).parent / "new-gws", runner=runner)
                    validate.assert_not_called()
                    install.assert_not_called()
                    runner.assert_not_called()

    def test_dry_cli_root_routes_layout_but_never_executes(self):
        with tempfile.TemporaryDirectory() as td:
            repo = Path(td) / "repo"
            repo.mkdir()
            self.fixture(repo)
            root = Path(td) / "new"
            out = io.StringIO()
            with patch.object(lp.gws_tools, "resolve_release", return_value={"version": "1.2.3"}), patch.object(lp.gws_tools, "layout_plan", return_value={"binary": str(root / "bin/gws")}) as layout, patch.object(lp, "execute") as execute, contextlib.redirect_stdout(out):
                code = lp.main(["--repo", str(repo), "--gws-root", str(root)])
            layout.assert_called_once()
            execute.assert_not_called()
            self.assertEqual(code, 3)
            self.assertFalse(root.exists())
            action = next(a for a in json.loads(out.getvalue())["actions"] if a["name"] == PACKAGE)
            self.assertEqual(action["dry_plan"]["layout"]["binary"], str(root / "bin/gws"))

    def test_metadata_failure_remains_explicit_and_no_download_occurs(self):
        with tempfile.TemporaryDirectory() as td:
            repo = Path(td)
            self.fixture(repo)
            with patch.object(lp.gws_tools, "resolve_release", side_effect=ValueError("digest missing")):
                plan = lp.build_plan(repo)
        action = next(a for a in plan.actions if a.name == PACKAGE)
        self.assertEqual(action.status, "blocked")
        self.assertIn("digest missing", action.reason)
        self.assertIn(action.reason, plan.blockers)

    def test_forged_global_action_is_still_not_executable(self):
        plan = lp.Plan(True, "ubuntu", "x86_64", [lp.Action("pnpm", PACKAGE, ["pnpm", "add", "-g", PACKAGE])])
        runner = Mock()
        with self.assertRaisesRegex(RuntimeError, "Unvalidated"):
            lp.execute(plan, [PACKAGE], runner=runner)
        runner.assert_not_called()


if __name__ == "__main__":
    unittest.main()
