"""Offline regression boundary for the exact still-blocked WACLI Go build."""
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).parents[1]))
import linux_packages as lp

PATH = "github.com/openclaw/wacli/cmd/wacli"
COMMAND = ["go", "install", "-tags", "sqlite_fts5", PATH + "@v0.15.0"]


class WacliReviewTests(unittest.TestCase):
    def build(self, declaration=None, architecture="x86_64"):
        if declaration is None:
            declaration = {"path": PATH, "version": "v0.15.0", "tags": ["sqlite_fts5"]}
        with tempfile.TemporaryDirectory(prefix="wacli-review-") as directory:
            root = Path(directory)
            manifests = {
                "scoop-allowed.json": {"apps": ["curl"]},
                "winget-allowed.json": {"packages": [{"id": "Fixture.Windows"}]},
                "pnpm-allowed.json": {"packages": ["fixture-node-tool"]},
                "uv-allowed.json": {"packages": ["fixture-python-tool"]},
                "go-allowed.json": {"packages": [declaration]},
            }
            for filename, value in manifests.items():
                (root / filename).write_text(json.dumps(value), encoding="utf-8")
            before = {p.name: p.read_bytes() for p in root.iterdir()}
            environment = dict(os.environ)
            with patch.object(lp, "_native_release", side_effect=AssertionError("no metadata fetch")), \
                    patch.object(lp.subprocess, "run", side_effect=AssertionError("no processes")), \
                    patch.object(lp.shutil, "which", side_effect=AssertionError("no global binary fallback")):
                plan = lp.build_plan(root, distro="ubuntu", architecture=architecture)
            self.assertEqual(before, {p.name: p.read_bytes() for p in root.iterdir()})
            self.assertEqual(environment, dict(os.environ))
            return plan

    def test_exact_pin_tags_source_and_original_command_remain_blocked(self):
        for architecture in ("x86_64", "aarch64"):
            with self.subTest(architecture=architecture):
                plan = self.build(architecture=architecture)
                action = next(a for a in plan.actions if a.kind == "go")
                self.assertEqual((action.name, action.version, action.tags, action.source),
                                 (PATH, "v0.15.0", ["sqlite_fts5"], "go"))
                self.assertEqual(action.command, COMMAND)
                self.assertEqual(action.status, "blocked")
                self.assertIsNone(action.archive)
                self.assertIsNone(action.dry_plan)
                self.assertIn(action.reason, plan.blockers)
                for fragment in ("Go >=1.25.12", "CGO_ENABLED=1", "C compiler/libc", "bundled",
                                 "v1.14.48", "not an external libsqlite3/FTS5 package",
                                 "CGO_CFLAGS=-Wno-error=missing-braces", "provenance", "checksum",
                                 "GOTOOLCHAIN=local", "GOBIN", "GOPATH", "GOMODCACHE", "GOCACHE",
                                 "GOTMPDIR", "HOME/config", "missing/overlap/symlink", "GOENV/GOFLAGS/GOWORK",
                                 "No executor", "no live-home/PATH/cache changes"):
                    self.assertIn(fragment, action.reason)

    def test_other_versions_or_tags_do_not_borrow_exact_review(self):
        for declaration in (
            {"path": PATH, "version": "v0.14.0", "tags": ["sqlite_fts5"]},
            {"path": PATH, "version": "v0.15.0", "tags": []},
            {"path": PATH, "version": "v0.15.0", "tags": ["sqlite_fts5", "libsqlite3"]},
            PATH,
        ):
            with self.subTest(declaration=declaration):
                action = next(a for a in self.build(declaration).actions if a.kind == "go")
                self.assertEqual(action.status, "blocked")
                self.assertNotIn("Go >=1.25.12", action.reason)
                self.assertIn("not validated", action.reason)

    def test_selected_blocker_prevents_every_earlier_selected_mutation(self):
        plan = self.build()
        runner = Mock()
        with patch.object(lp, "host_info", return_value=("ubuntu", "x86_64")), \
                patch.object(lp, "_apt_preflight") as apt:
            with self.assertRaisesRegex(RuntimeError, "Unresolved blockers"):
                lp.execute(plan, ["curl", PATH], runner=runner)
        apt.assert_not_called()
        runner.assert_not_called()

    def test_forged_planned_go_or_build_cannot_bypass_gate(self):
        for command in (COMMAND, ["/fixture/go/bin/go", "install", "-tags", "sqlite_fts5", PATH + "@v0.15.0"],
                        ["/fixture/go/bin/go", "build", "-tags", "sqlite_fts5", "-o", "/fixture/bin/wacli", "./cmd/wacli"],
                        ["/fixture/global/wacli", "--version"]):
            with self.subTest(command=command):
                plan = lp.Plan(True, "ubuntu", "x86_64", [
                    lp.Action("apt", "curl", ["apt-get", "install", "-y", "curl"]),
                    lp.Action("go", PATH, command, version="v0.15.0", tags=["sqlite_fts5"]),
                ])
                runner = Mock()
                with patch.object(lp, "host_info", return_value=("ubuntu", "x86_64")), \
                        patch.object(lp, "_apt_preflight") as apt:
                    with self.assertRaisesRegex(RuntimeError, "Unvalidated command/runtime/destination"):
                        lp.execute(plan, ["curl", PATH], runner=runner)
                apt.assert_not_called()
                runner.assert_not_called()


if __name__ == "__main__":
    unittest.main()
