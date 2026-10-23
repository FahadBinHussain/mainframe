"""Offline regression boundary for the still-blocked uv tool path."""
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).parents[1]))
import linux_packages as lp


class UvReviewTests(unittest.TestCase):
    def build(self, declaration):
        with tempfile.TemporaryDirectory(prefix="uv-review-") as directory:
            root = Path(directory)
            manifests = {
                "scoop-allowed.json": {"apps": ["curl"]},
                "winget-allowed.json": {"packages": [{"id": "Fixture.Windows"}]},
                "pnpm-allowed.json": {"packages": ["fixture-node-tool"]},
                "uv-allowed.json": {"packages": [declaration]},
                "go-allowed.json": {"packages": ["example.invalid/tool"]},
            }
            for filename, value in manifests.items():
                (root / filename).write_text(json.dumps(value), encoding="utf-8")
            before = {p.name: p.read_bytes() for p in root.iterdir()}
            # This path needs no release resolution, process, or package download.
            with patch.object(lp, "_native_release", side_effect=AssertionError("unexpected metadata fetch")), \
                    patch("urllib.request.urlopen", side_effect=AssertionError("unexpected network")), \
                    patch.object(lp.subprocess, "run", side_effect=AssertionError("unexpected process")):
                plan = lp.build_plan(root, distro="ubuntu", architecture="x86_64")
            self.assertEqual(before, {p.name: p.read_bytes() for p in root.iterdir()})
            return plan

    def test_unpinned_declarations_remain_original_and_precisely_blocked(self):
        for declaration in ("graphifyy", {"name": "graphifyy"}):
            with self.subTest(declaration=declaration):
                plan = self.build(declaration)
                action = next(a for a in plan.actions if a.kind == "uv")
                self.assertEqual(action.status, "blocked")
                self.assertIsNone(action.version)
                self.assertEqual(action.command, ["uv", "tool", "install", "--", "graphifyy"])
                self.assertIsNone(action.archive)
                self.assertIsNone(action.dry_plan)
                for fragment in ("Unpinned declaration", "provenance/version/ABI", "wheel set with hashes",
                                 "root wheel alone", "executable-bin", "config", "Python runtime roots",
                                 "missing/overlap", "no-build/no-Python-download", "no live-home",
                                 "reviewed target Python patch/ABI, architecture and libc",
                                 "hashed PEP 658", "cannot verify wheel bytes",
                                 "No metadata observation is an install lock",
                                 "effective-path equality checks under a clean child environment"):
                    self.assertIn(fragment, action.reason)
                self.assertIn(action.reason, plan.blockers)

    def test_pin_alone_does_not_unblock_or_resolve_dependencies(self):
        plan = self.build({"name": "graphifyy", "version": "1.2.3"})
        action = next(a for a in plan.actions if a.kind == "uv")
        self.assertEqual(action.status, "blocked")
        self.assertEqual(action.version, "1.2.3")
        self.assertEqual(action.command[-1], "graphifyy==1.2.3")
        self.assertNotIn("Unpinned declaration", action.reason)
        self.assertIn("complete marker-resolved dependency wheel set", action.reason)
        self.assertIn("missing/overlap rejection", action.reason)

    def test_observed_current_pin_still_requires_reviewed_runtime_and_roots(self):
        # Evidence is not an executable policy input or permission. A pin matching
        # the review observation must retain every runtime/path gate.
        observation = json.loads((Path(__file__).parents[1] / "docs" /
                                  "linux-uv-tool-metadata-observation.json").read_text())
        root = next(n for n in observation["nodes"] if n["name"] == "graphifyy")
        plan = self.build({"name": root["name"], "version": root["version"]})
        action = next(a for a in plan.actions if a.kind == "uv")
        self.assertEqual(action.status, "blocked")
        self.assertIsNone(action.dry_plan)
        self.assertIsNone(action.archive)
        self.assertFalse(observation["runtime_tested"])
        self.assertFalse(observation["interpreter_selected"])
        self.assertFalse(observation["isolated_roots_validated"])
        self.assertFalse(observation["artifact_bytes_downloaded"])
        for fragment in ("interpreter provenance", "effective-path equality", "no live-home"):
            self.assertIn(fragment, action.reason)

    def test_observation_records_complete_non_policy_metadata_evidence(self):
        observation = json.loads((Path(__file__).parents[1] / "docs" /
                                  "linux-uv-tool-metadata-observation.json").read_text())
        self.assertEqual(observation["status"], "observed-metadata-closure-not-install-plan")
        self.assertEqual(observation["root_declaration"], "graphifyy")
        self.assertEqual(observation["extras"], [])
        self.assertTrue(observation["target"]["hypothetical"])
        self.assertEqual(observation["target"]["python"], "3.12.0")
        self.assertEqual(observation["target"]["architecture"], "x86_64")
        self.assertIn("glibc", observation["target"]["libc"])
        self.assertRegex(observation["observed_at_utc"], r"^\d{4}-\d\d-\d\dT.*Z$")
        nodes = {n["name"]: n for n in observation["nodes"]}
        self.assertEqual(len(nodes), 30)
        self.assertEqual(len(observation["nodes"]), len(nodes))
        root = nodes["graphifyy"]
        # Structural evidence validation is deliberately stdlib-only, not a new
        # production resolver or claim to reverify unfetched wheel bytes.
        import re
        edges = {re.match(r"[A-Za-z0-9-]+", req)[0] for req in root["dependencies"]}
        self.assertEqual(edges, set(nodes) - {"graphifyy"})
        for name, node in nodes.items():
            self.assertEqual(node["metadata_url"],
                             f"https://pypi.org/pypi/{name}/{node['version']}/json")
            self.assertTrue(node["metadata_hash_verified"])
            self.assertRegex(node["metadata_sha256"], r"^[0-9a-f]{64}$")
            wheel = node["wheel"]
            self.assertRegex(wheel["digests"]["sha256"], r"^[0-9a-f]{64}$")
            self.assertGreater(wheel["size"], 0)
            self.assertTrue(wheel["url"].startswith("https://files.pythonhosted.org/packages/"))
            self.assertTrue(wheel["url"].endswith("/" + wheel["filename"]))
            self.assertTrue(wheel["filename"].endswith(".whl"))
            if name != "graphifyy":
                self.assertEqual(node["dependencies"], [])

    def test_blocked_uv_prevents_earlier_selected_apt_mutation(self):
        plan = self.build("graphifyy")
        runner = Mock()
        with patch.object(lp, "host_info", return_value=("ubuntu", "x86_64")), \
                patch.object(lp, "_apt_preflight") as apt:
            with self.assertRaisesRegex(RuntimeError, "Unresolved blockers"):
                lp.execute(plan, ["curl", "graphifyy"], runner=runner)
        apt.assert_not_called()
        runner.assert_not_called()

    def test_forged_planned_uv_cannot_bypass_missing_root_contract(self):
        # There is intentionally no uv executor: no supplied/missing/overlapping
        # roots or hand-built status can turn this command into permission.
        for command in (["uv", "tool", "install", "--", "graphifyy"],
                        ["/fixture/uv", "--no-config", "tool", "install", "--no-build", "graphifyy==1.2.3"]):
            with self.subTest(command=command):
                plan = lp.Plan(True, "ubuntu", "x86_64", [
                    lp.Action("apt", "curl", ["sudo", "-n", "apt-get", "install", "-y", "curl"]),
                    lp.Action("uv", "graphifyy", command),
                ])
                runner = Mock()
                with patch.object(lp, "host_info", return_value=("ubuntu", "x86_64")), \
                        patch.object(lp, "_apt_preflight") as apt:
                    with self.assertRaisesRegex(RuntimeError, "Unvalidated command/runtime/destination"):
                        lp.execute(plan, ["curl", "graphifyy"], runner=runner)
                apt.assert_not_called()
                runner.assert_not_called()


if __name__ == "__main__":
    unittest.main()
