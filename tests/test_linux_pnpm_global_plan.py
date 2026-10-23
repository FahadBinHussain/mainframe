import base64
import contextlib
import io
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

import sys
sys.path.insert(0, str(Path(__file__).parents[1]))
import linux_packages as lp
import pnpm_global_plan as plan


class PnpmGlobalPlanTests(unittest.TestCase):
    INTEGRITY = "sha512-" + base64.b64encode(b"synthetic-canonical-sha512".ljust(64, b"\0")).decode()

    def roots(self, base):
        return {k: str(base / k) for k in plan.ROOT_KEYS}

    def package_meta(self, name="vercel", version="1.2.3", *, scripts=None,
                     deps=None, optional=None, peers=None, engines=None,
                     platform=None, integrity=None):
        return {"name": name, "version": version,
                "dist": {"tarball": f"https://registry.npmjs.org/{name}/-/{name.rsplit('/', 1)[-1]}-{version}.tgz",
                         "integrity": integrity or self.INTEGRITY},
                "scripts": scripts or {}, "dependencies": deps or {},
                "optionalDependencies": optional or {}, "peerDependencies": peers or {},
                "engines": engines or {}, **(platform or {})}

    def runtime_fixture(self, node="20.1.0", pnpm="12.0.0"):
        nr = {"version": node, "url": "synthetic-node"}
        pr = {"name": "pnpm", "version": pnpm, "url": "synthetic-pnpm"}
        return nr, pr

    def build(self, base, *, pkg=None, pnpm_meta=None, deps=None, optional=None,
              scripts=None, engines=None, dependency_scripts=None,
              optional_scripts=None, node="20.1.0", pnpm="12.0.0",
              peers=None, platform=None):
        pkg = pkg or "vercel"
        nr, pr = self.runtime_fixture(node, pnpm)
        meta = self.package_meta(pkg, scripts=scripts, deps=deps, optional=optional,
                                 peers=peers, engines=engines, platform=platform)
        pm = pnpm_meta or self.package_meta("pnpm", version=pnpm, engines={"node": ">=18"})
        responses = {pkg: meta, "pnpm": pm}
        for n, v in {**(deps or {}), **(optional or {})}.items():
            if plan.VERSION.fullmatch(v):
                responses[n] = self.package_meta(
                    n, v, scripts=(dependency_scripts or {}).get(n) or
                    (optional_scripts or {}).get(n))

        def fake_manifest(name, selector="latest"):
            item = dict(responses[name])
            item["name"] = name
            item["version"] = selector if selector != "latest" else item["version"]
            item["source"] = f"https://registry.npmjs.org/{name}/{item['version']}"
            item["selector_source"] = item["source"]
            item["tarball"] = item["dist"]["tarball"]
            item["integrity"] = item["dist"]["integrity"]
            item["engines"] = item.get("engines", {})
            item["install_scripts"] = {k: v for k, v in item.get("scripts", {}).items() if k in plan.HOOKS}
            item["dependencies"] = item.get("dependencies", {})
            item["optional_dependencies"] = item.get("optionalDependencies", {})
            item["peer_dependencies"] = item.get("peerDependencies", {})
            item["platform"] = {k: item[k] for k in ("os", "cpu", "libc") if k in item}
            item["implicit_build_review"] = "binding.gyp and archive-only hooks unknown until verified artifact review"
            item["bin"] = item.get("bin")
            return item
        with patch.object(plan.node, "_validate_release", return_value=nr), \
             patch.object(plan.native, "_validate_release", return_value=pr), \
             patch.object(plan, "manifest", side_effect=fake_manifest):
            return plan.build_dry_plan(pkg, {"roots": self.roots(base)}, nr, pr, architecture="x86_64")

    def test_roots_require_independent_explicit_new_paths(self):
        with tempfile.TemporaryDirectory() as d:
            base = Path(d); roots = self.roots(base)
            self.assertEqual(plan.validate_roots(roots), roots)
            for key in plan.ROOT_KEYS:
                bad = dict(roots); bad.pop(key)
                with self.subTest(key=key), self.assertRaises(ValueError): plan.validate_roots(bad)
            for value in ("relative", "/tmp/x//y", "/tmp/../x", "/tmp/~", "/tmp/a\n"):
                bad = dict(roots); bad["node"] = value
                with self.subTest(value=value), self.assertRaises(ValueError): plan.validate_roots(bad)

    def test_roots_reject_equal_nested_existing_symlink_and_protected(self):
        with tempfile.TemporaryDirectory() as d:
            base = Path(d); roots = self.roots(base)
            for a, b in (("node", "pnpm"),):
                bad = dict(roots); bad[b] = bad[a]
                with self.assertRaisesRegex(ValueError, "distinct"): plan.validate_roots(bad)
                bad[b] = str(Path(bad[a]) / "child")
                with self.assertRaisesRegex(ValueError, "distinct"): plan.validate_roots(bad)
            existing = base / "exists"; existing.mkdir()
            bad = dict(roots); bad["node"] = str(existing)
            with self.assertRaisesRegex(ValueError, "new"): plan.validate_roots(bad)
            target = base / "target"; target.mkdir(); link = base / "link"; link.symlink_to(target)
            bad["node"] = str(link)
            with self.assertRaises(ValueError): plan.validate_roots(bad)
            for protected in (Path.home(), Path("/etc"), base / "repo"):
                bad = dict(roots); bad["node"] = str(protected / "child")
                with self.assertRaises(ValueError): plan.validate_roots(bad, protected=(base / "repo",))

    def test_roots_are_not_mutated_when_planner_errors(self):
        with tempfile.TemporaryDirectory() as d:
            roots = self.roots(Path(d)); before = dict(roots)
            with self.assertRaises(ValueError): plan.build_dry_plan("../bad", {"roots": roots}, None, None, architecture="x86_64")
            self.assertEqual(roots, before)
            self.assertFalse(any(Path(p).exists() for p in roots.values()))

    def test_runtime_missing_wrong_source_version_and_major_fail(self):
        with tempfile.TemporaryDirectory() as d:
            config = {"roots": self.roots(Path(d))}
            with self.assertRaisesRegex(ValueError, "Missing pinned"):
                plan.build_dry_plan("vercel", config, None, None, architecture="x86_64")
            nr, pr = self.runtime_fixture()
            for bad in ({"version": "20.1.0"}, {"name": "npm", "version": "12.0.0"}):
                with self.subTest(bad=bad), patch.object(plan.node, "_validate_release", return_value=nr), patch.object(plan.native, "_validate_release", return_value=bad):
                    with self.assertRaises(ValueError): plan.build_dry_plan("vercel", config, nr, bad, architecture="x86_64")
            with self.assertRaisesRegex(ValueError, "major"): self.build(Path(d), pnpm="11.9.0")

    def test_runtime_minimum_rejects_node19_but_accepts_node20(self):
        with tempfile.TemporaryDirectory() as d:
            with self.assertRaisesRegex(ValueError, "does not satisfy"):
                self.build(Path(d), node="19.9.0", engines={"node": ">=20"})
            result = self.build(Path(d), node="20.1.0", engines={"node": ">=20"})
            self.assertTrue(result["engine_checks"])

    def test_production_runtime_validators_reject_malformed_fixture(self):
        nr, pr = self.runtime_fixture()
        with self.assertRaises(ValueError): plan.node._validate_release(nr)
        with self.assertRaises(ValueError): plan.native._validate_release(pr)

    def test_manifest_rejects_registry_source_name_version_and_integrity(self):
        good = self.package_meta("vercel")
        cases = [(lambda m: {**m, "name": "other"}, "identity"),
                 (lambda m: {**m, "version": "9.9.9"}, "version mismatch"),
                 (lambda m: {**m, "dist": {**m["dist"], "tarball": "https://evil.invalid/a.tgz"}}, "tarball")]
        for mutate, message in cases:
            with self.subTest(message=message), patch.object(plan.registry, "_json", return_value=mutate(good)), patch.object(plan.registry, "_integrity", return_value="ok"):
                with self.assertRaises(ValueError): plan.manifest("vercel", "1.2.3" if "version" in message else "latest")
        with patch.object(plan.registry, "_json", return_value=good), patch.object(plan.registry, "_integrity", side_effect=ValueError("bad integrity")):
            with self.assertRaisesRegex(ValueError, "integrity"): plan.manifest("vercel")
        with self.assertRaises(ValueError): plan.manifest("../unsafe")

    def test_latest_exact_drift_is_rejected_for_all_install_relevant_fields(self):
        fields = ("integrity", "install_scripts", "dependencies", "optional_dependencies", "engines", "platform",
                  "peer_dependencies_meta", "bundled_dependencies", "has_install_script")
        for field in fields:
            with self.subTest(field=field):
                latest = {"name": "vercel", "version": "1.2.3", "source": "s", "selector_source": "latest",
                          "tarball": "t", "integrity": self.INTEGRITY, "engines": {}, "install_scripts": {},
                          "dependencies": {}, "optional_dependencies": {}, "peer_dependencies": {}, "platform": {},
                          "implicit_build_review": "review", "bin": None}
                exact = dict(latest); exact["selector_source"] = "exact"
                exact[field] = {"changed": True} if field not in ("integrity", "platform") else ("sha512-" + base64.b64encode(b"other".ljust(64, b"x")).decode() if field == "integrity" else {"os": ["linux"]})
                with patch.object(plan, "manifest", side_effect=[latest, exact]):
                    with self.assertRaisesRegex(ValueError, "metadata drift"): plan.pinned_manifest("vercel")

    def test_production_projection_binds_optional_peers_and_bundled_graph(self):
        for field, value in (("peerDependenciesMeta", {"peer": {"optional": True}}),
                             ("bundledDependencies", ["bundled"]),
                             ("bundleDependencies", True), ("hasInstallScript", True)):
            first = self.package_meta()
            second = {**first, field: value}
            with self.subTest(field=field), patch.object(plan.registry, "_json", side_effect=[first, second]):
                with self.assertRaisesRegex(ValueError, "metadata drift"):
                    plan.pinned_manifest("vercel")

    def test_malformed_peer_bundle_platform_and_implicit_build_fields_fail(self):
        for field, value in (("peerDependenciesMeta", {"peer": {"optional": "yes"}}),
                             ("bundledDependencies", ["../bad"]),
                             ("bundleDependencies", "yes"), ("hasInstallScript", "yes"),
                             ("os", "linux"), ("cpu", ["x64\n"])):
            with self.subTest(field=field), patch.object(plan.registry, "_json", return_value={**self.package_meta(), field: value}):
                with self.assertRaisesRegex(ValueError, "metadata"):
                    plan.manifest("vercel")

    def test_root_package_has_no_hooks_but_dependency_esbuild_hook_is_honest(self):
        with tempfile.TemporaryDirectory() as d:
            result = self.build(Path(d), deps={"esbuild": "0.20.0"}, scripts={}, engines={"node": ">=18"}, dependency_scripts={"esbuild": {"postinstall": "node install.js"}})
            self.assertEqual(result["package"]["install_scripts"], {})
            self.assertEqual(result["install_scripts"][0]["package"], "esbuild")
            self.assertEqual(result["script_policy"]["allow_builds_proposal"], {})
            self.assertNotIn("--allow-build", result["proposed_command"])
            self.assertEqual(result["script_policy"]["required_version_scoped_policy"], {"esbuild@0.20.0": "review-required"})
            self.assertEqual(result["script_policy"]["approval_requirements"][0]["approval"], "required-not-granted")
            self.assertIn("No reviewed pnpm-resolved full dependency/build closure", result["execution_blockers"][0])

    def test_exact_optional_dependency_scripts_are_inventoried(self):
        with tempfile.TemporaryDirectory() as d:
            result = self.build(Path(d), optional={"native-addon": "2.3.4"}, engines={"node": ">=18"}, optional_scripts={"native-addon": {"install": "node build.js"}})
            self.assertEqual(result["direct_dependencies_reviewed"][0]["name"], "native-addon")
            self.assertEqual(result["install_scripts"][0]["hooks"], {"install": "node build.js"})
            self.assertEqual(result["install_scripts"][0]["version"], "2.3.4")

    def test_optional_dependencies_kept_and_unknown_builds_strict(self):
        with tempfile.TemporaryDirectory() as d:
            result = self.build(Path(d), optional={"fsevents": "2.3.3"}, scripts={"postinstall": "node build"}, engines={"node": ">=18"})
            self.assertEqual(result["package"]["optional_dependencies"], {"fsevents": "2.3.3"})
            self.assertNotIn("--no-optional", result["proposed_command"])
            self.assertTrue(result["script_policy"]["strict_unknown_builds"])
            self.assertIn("--config.dangerouslyAllowAllBuilds=false", result["proposed_command"])
            self.assertIn("--config.verifyStoreIntegrity=true", result["proposed_command"])
            self.assertIn("--config.strictStorePkgContentCheck=true", result["proposed_command"])
            self.assertFalse(result["executable"])
            self.assertEqual(result["proposed_environment"]["HOME"], result["roots"]["home"])
            self.assertEqual(result["proposed_cwd"], result["roots"]["work"])

    def test_integrity_settings_and_effective_paths_are_explicit(self):
        with tempfile.TemporaryDirectory() as d:
            result = self.build(Path(d), engines={"node": ">=18"})
            settings = result["effective_paths"]["settings"]
            self.assertTrue(settings["verifyStoreIntegrity"])
            self.assertTrue(settings["strictStorePkgContentCheck"])
            self.assertEqual(result["effective_paths"]["expected_global_install_base"], str(Path(result["roots"]["global"]) / "v11"))
            self.assertFalse(result["effective_paths"]["layout_contract"]["confirmed_by_probe"])
            self.assertEqual(result["effective_paths"]["layout_contract"]["pnpm_version"], "12.0.0")
            self.assertEqual(result["effective_paths"]["status"], "expected-not-probed")
            self.assertTrue(result["effective_paths"]["verification_required"])

    def test_fresh_environment_does_not_inherit_tokens_or_pnpm_flags(self):
        suspicious = {"TOKEN": "secret", "NPM_TOKEN": "secret", "NODE_OPTIONS": "--require evil", "PNPM_HOME": "/live", "PNPM_CONFIG_GLOBAL_DIR": "/live"}
        before = dict(os.environ)
        with patch.dict(os.environ, suspicious, clear=False):
            with tempfile.TemporaryDirectory() as d:
                result = self.build(Path(d), engines={"node": ">=18"})
                env = result["proposed_environment"]
                self.assertNotIn("TOKEN", env); self.assertNotIn("NPM_TOKEN", env)
                self.assertNotIn("NODE_OPTIONS", env)
                self.assertEqual(env["PNPM_HOME"], result["roots"]["pnpm_home"])
                self.assertEqual(env["PNPM_CONFIG_GLOBAL_DIR"], result["roots"]["global"])
        self.assertEqual(dict(os.environ), before)

    def test_no_broad_approvals_under_version_drift(self):
        with tempfile.TemporaryDirectory() as d:
            result = self.build(Path(d), deps={"esbuild": "0.20.0"}, dependency_scripts={"esbuild": {"install": "build"}}, engines={"node": ">=18"})
            policy = result["script_policy"]
            self.assertEqual(policy["allow_builds_proposal"], {})
            self.assertNotIn("esbuild", policy["required_version_scoped_policy"])
            self.assertEqual(policy["required_version_scoped_policy"]["esbuild@0.20.0"], "review-required")
            self.assertTrue(all("@" in r["matcher"] for r in policy["approval_requirements"]))

    def test_engine_mismatch_and_pending_ranges_are_explicit(self):
        with tempfile.TemporaryDirectory() as d:
            with self.assertRaisesRegex(ValueError, "does not satisfy"):
                self.build(Path(d), engines={"node": ">=22"})
            result = self.build(Path(d), deps={"foo": "^1.2.0", "bar": "1.0.0"}, engines={"node": ">=18"})
            self.assertEqual(result["unresolved_direct_ranges"], {"foo": "^1.2.0"})
            self.assertIn("transitive", " ".join(result["future_executor_gates"]))

    def test_linux_integration_passes_config_and_blocks_metadata_plan(self):
        with tempfile.TemporaryDirectory() as d:
            repo = Path(d); manifests = {"scoop-allowed.json": {"apps": []}, "winget-allowed.json": {"packages": []}, "pnpm-allowed.json": {"packages": ["vercel"]}, "uv-allowed.json": {"packages": ["x"]}, "go-allowed.json": {"packages": ["example.com/x"]}}
            for name, value in manifests.items(): (repo / name).write_text(json.dumps(value))
            with patch.object(lp.pnpm_global_tools, "build_dry_plan", return_value={"package": {"version": "1.0.0"}, "execution_blockers": ["pending"], "proposed_command": []}) as build:
                built = lp.build_plan(repo, distro="ubuntu", architecture="x86_64", pnpm_plan_config={"roots": self.roots(repo / "isolated")})
            build.assert_called_once(); action = next(a for a in built.actions if a.name == "vercel")
            self.assertEqual(action.status, "blocked"); self.assertIn("pending", action.reason); self.assertTrue(built.blockers)

    def test_main_rejects_execute_with_dry_only_pnpm_config(self):
        with tempfile.TemporaryDirectory() as d:
            cfg = Path(d) / "cfg.json"; cfg.write_text("{}")
            with self.assertRaises(SystemExit) as caught: lp.main(["--repo", str(Path(d)), "--pnpm-plan-config", str(cfg), "--execute"])
            self.assertEqual(caught.exception.code, 2)

    def test_execute_mixed_selection_cannot_bypass_blocked_action(self):
        p = lp.Plan(True, "ubuntu", "x86_64", [lp.Action("apt", "curl", ["apt-get", "install", "-y", "curl"]), lp.Action("pnpm", "vercel", status="blocked", reason="dry-only")])
        with patch.object(lp, "host_info", return_value=("ubuntu", "x86_64")), patch.object(lp.subprocess, "run") as runner:
            with self.assertRaisesRegex(RuntimeError, "Unresolved blockers"): lp.execute(p, ["curl", "vercel"])
            runner.assert_not_called()


if __name__ == "__main__":
    unittest.main()
