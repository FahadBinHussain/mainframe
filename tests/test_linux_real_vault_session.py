"""The linux side of the ONE vault flow.

The vault has exactly one implementation: vault-flow.ps1 (powershell). linux
shells out to it. these tests pin the CONTRACT between the two - the argv,
the result document and the failure modes - so the two platforms cannot
drift apart.

the behaviours that used to be tested here (session cache, TTL, approval
polling, secret extraction) now live in the powershell implementation and
are covered by tests/vault-flow.Tests.ps1 and tests/vault-approval-*.Tests.ps1.
"""
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

REPO = Path(__file__).parents[1]
sys.path.insert(0, str(REPO))
import linux_real as lr  # noqa: E402


class PythonVaultDuplicateIsGoneTests(unittest.TestCase):
    """There must be no second implementation of the vault flow."""

    REMOVED = (
        "obtain_master_password", "unseal_email", "generate_tab_key",
        "wait_for_tab_password", "read_cached_session", "write_cached_session",
        "clear_cached_session", "session_key_path", "get_vault_ttl_minutes",
        "extract_vault_secrets", "dispatch_ntfy_unlock", "detect_caller_identity",
        "publish_request_expired", "try_open_phone_adb",
        "get_ntfy_topic", "get_ntfy_server", "get_pages_base", "load_config",
    )

    def test_the_python_copy_of_the_vault_flow_is_gone(self):
        for name in self.REMOVED:
            with self.subTest(name=name):
                self.assertFalse(hasattr(lr, name),
                                 f"{name} is a second implementation of the vault flow - "
                                 "it belongs in vault-flow.ps1")

    def test_the_powershell_cli_is_the_only_entry_point(self):
        self.assertTrue((REPO / "vault-flow.ps1").is_file())
        source = (REPO / "linux_real.py").read_text(encoding="utf-8")
        self.assertIn("vault-flow.ps1", source)
        self.assertNotIn("secretsPassword =", source)

    def test_the_flow_never_logs_the_approval_topic(self):
        # the topic is the whole privacy of the approval channel: whoever holds
        # it can read requests and push fake cards. the flow's log line goes to
        # a screen someone may paste, so it names the relay and the page only.
        source = (REPO / "vault-flow.ps1").read_text(encoding="utf-8")
        self.assertNotIn("topic '$approvalTopic'", source)
        self.assertIn("relay '$approvalServer'", source)


class VaultFlowCommandTests(unittest.TestCase):
    def test_pins_the_one_cli_with_the_json_contract(self):
        cmd = lr.vault_flow_command(REPO, "/opt/pwsh", "/opt/bw")
        self.assertEqual(cmd[0], "/opt/pwsh")
        self.assertEqual(cmd[1:5], ["-NoLogo", "-NoProfile", "-NonInteractive", "-File"])
        self.assertEqual(cmd[5], str(REPO / "vault-flow.ps1"))
        self.assertIn("-Json", cmd)
        self.assertIn("-Checkout", cmd)
        self.assertIn("-BwPath", cmd)
        self.assertNotIn("-Lock", cmd)
        self.assertNotIn("-LockIfStale", cmd)

    def test_carries_the_explicit_overrides_only(self):
        cmd = lr.vault_flow_command(REPO, "/opt/pwsh", "/opt/bw",
                                    ntfy_topic="topic-abc", ntfy_server="https://relay.invalid",
                                    pages_base="https://pages.invalid")
        self.assertEqual(cmd[cmd.index("-NtfyTopic") + 1], "topic-abc")
        self.assertEqual(cmd[cmd.index("-Server") + 1], "https://relay.invalid")
        self.assertEqual(cmd[cmd.index("-PagesBase") + 1], "https://pages.invalid")

    def test_omits_the_overrides_that_were_not_given(self):
        cmd = lr.vault_flow_command(REPO, "/opt/pwsh", "/opt/bw")
        for flag in ("-NtfyTopic", "-Server", "-PagesBase", "-OutputPath"):
            self.assertNotIn(flag, cmd)

    def test_the_lock_flags_are_mutually_exclusive_modes(self):
        self.assertIn("-Lock", lr.vault_flow_command(REPO, "pwsh", "bw", lock=True))
        self.assertIn("-LockIfStale",
                      lr.vault_flow_command(REPO, "pwsh", "bw", lock_if_stale=True))

    def test_fails_loudly_when_the_cli_is_missing(self):
        with tempfile.TemporaryDirectory() as scratch:
            with self.assertRaisesRegex(RuntimeError, "vault flow cli is missing"):
                lr.vault_flow_command(Path(scratch), "pwsh", "bw")


class VaultSessionTests(unittest.TestCase):
    """vault_session reads the result document the cli writes."""

    def _run_with(self, document, *, write=True, work_root=None):
        calls = {}

        def fake_run(cmd, **kwargs):
            calls["cmd"] = cmd
            calls["kwargs"] = kwargs
            if write:
                output = Path(cmd[cmd.index("-OutputPath") + 1])
                output.parent.mkdir(parents=True, exist_ok=True)
                output.write_text(document, encoding="utf-8")
            return subprocess.CompletedProcess(cmd, 0, "", "")

        root = work_root or Path(tempfile.mkdtemp())
        with patch.object(lr, "ensure_pwsh", return_value="/opt/pwsh"), \
             patch.object(lr, "ensure_bw", return_value="/opt/bw"), \
             patch.object(lr, "run", side_effect=fake_run):
            token, password = lr.vault_session(root, REPO)
        return token, password, calls

    def test_reads_the_token_and_the_secrets_password(self):
        document = json.dumps({
            "githubToken": "ghp_0123456789012345678901",
            "secretsPassword": "the secrets password",
            "sessionCached": True,
            "sessionReused": True,
            "approvalRequested": False,
            "ttlMinutes": 60,
        })
        token, password, calls = self._run_with(document)
        self.assertEqual(token, "ghp_0123456789012345678901")
        self.assertEqual(password, "the secrets password")
        self.assertIn("-Json", calls["cmd"])

    def test_fails_loudly_when_the_document_has_no_token(self):
        document = json.dumps({"githubToken": "", "secretsPassword": "x"})
        with self.assertRaisesRegex(RuntimeError, "no GitHub token"):
            self._run_with(document)

    def test_fails_loudly_when_the_document_is_missing(self):
        with self.assertRaisesRegex(RuntimeError, "produced no result document"):
            self._run_with(json.dumps({}), write=False)

    def test_fails_loudly_when_the_document_is_broken(self):
        with self.assertRaisesRegex(RuntimeError, "could not be read"):
            self._run_with("{not json")

    def test_fails_loudly_when_the_document_is_not_an_object(self):
        with self.assertRaisesRegex(RuntimeError, "not a JSON object"):
            self._run_with(json.dumps(["a", "b"]))

    def test_reads_a_document_written_with_a_bom(self):
        document = json.dumps({"githubToken": "ghp_0123456789012345678901",
                               "secretsPassword": "p"})
        token, _, _ = self._run_with(document)
        self.assertEqual(token, "ghp_0123456789012345678901")


class PwshAndBwResolutionTests(unittest.TestCase):
    def test_every_child_process_runs_with_powershell_telemetry_off(self):
        # a freshly installed pwsh initialises on first start and would open a
        # connection to Microsoft's telemetry endpoint, which on a governed
        # container raises an approval card for something nobody asked for.
        captured = {}

        def fake_run(cmd, **kwargs):
            captured.update(kwargs)
            return subprocess.CompletedProcess(cmd, 0, "", "")

        with patch.object(lr.subprocess, "run", side_effect=fake_run):
            lr.run(["/bin/true"])
        env = captured.get("env") or {}
        self.assertEqual(env.get("POWERSHELL_TELEMETRY_OPTOUT"), "1")
        self.assertEqual(env.get("POWERSHELL_UPDATECHECK"), "Off")

    def test_pwsh_prefers_path(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            with patch.object(lr.shutil, "which", side_effect=lambda n: "/usr/bin/pwsh" if n == "pwsh" else None):
                self.assertEqual(lr.pwsh_executable(root), "/usr/bin/pwsh")
                self.assertEqual(lr.ensure_pwsh(root), "/usr/bin/pwsh")

    def test_pwsh_falls_back_to_the_local_install(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            local = root / lr.PWSH_ROOT / "pwsh"
            local.parent.mkdir(parents=True)
            local.write_text("#!/bin/sh\n", encoding="utf-8")
            with patch.object(lr.shutil, "which", return_value=None):
                self.assertEqual(lr.pwsh_executable(root), str(local))
                self.assertEqual(lr.ensure_pwsh(root), str(local))

    def test_pwsh_installs_with_the_hardened_installer(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            with patch.object(lr.shutil, "which", return_value=None), \
                 patch.object(lr, "log"), \
                 patch("pwsh_linux.resolve_release", return_value={"version": "9.9.9"}) as resolve, \
                 patch("pwsh_linux.install_release",
                       return_value={"version": "9.9.9", "pwsh_version": "9.9.9"}) as install:
                result = lr.ensure_pwsh(root)
            self.assertEqual(result, str(root / lr.PWSH_ROOT / "pwsh"))
            resolve.assert_called_once_with("x86_64")
            self.assertEqual(install.call_count, 1)

    def test_pwsh_refuses_to_delete_a_half_installed_root(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            (root / lr.PWSH_ROOT).mkdir(parents=True)
            with patch.object(lr.shutil, "which", return_value=None):
                with self.assertRaisesRegex(RuntimeError, "exists but has no usable pwsh"):
                    lr.ensure_pwsh(root)

    def test_bw_prefers_path(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            with patch.object(lr.shutil, "which", side_effect=lambda n: "/usr/bin/bw" if n == "bw" else None):
                self.assertEqual(lr.bw_executable(root), "/usr/bin/bw")
                self.assertEqual(lr.ensure_bw(root), "/usr/bin/bw")

    def test_bw_falls_back_to_the_local_install(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            local = root / "vault" / "bitwarden-cli" / "bw"
            local.parent.mkdir(parents=True)
            local.write_text("#!/bin/sh\n", encoding="utf-8")
            with patch.object(lr.shutil, "which", return_value=None):
                self.assertEqual(lr.bw_executable(root), str(local))
                self.assertEqual(lr.ensure_bw(root), str(local))

    def test_bw_installs_with_the_pinned_installer(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            with patch.object(lr.shutil, "which", return_value=None), \
                 patch.object(lr, "log"), \
                 patch("bitwarden_cli_linux.resolve_release", return_value={"version": "1.2.3"}) as resolve, \
                 patch("bitwarden_cli_linux.install_release", return_value={}) as install:
                result = lr.ensure_bw(root)
            self.assertEqual(result, str(root / "vault" / "bitwarden-cli" / "bw"))
            resolve.assert_called_once_with("x86_64")
            self.assertEqual(install.call_count, 1)


class PrereqTests(unittest.TestCase):
    def test_nothing_missing_when_everything_is_there(self):
        with patch.object(lr.shutil, "which", return_value="/usr/bin/tool"), \
             patch.object(lr.Path, "is_file", return_value=True):
            self.assertEqual(lr.prereqs_present(), [])

    def test_reports_the_missing_tools(self):
        with patch.object(lr.shutil, "which", return_value=None), \
             patch.object(lr.Path, "is_file", return_value=True):
            missing = lr.prereqs_present()
        self.assertIn("git", missing)
        self.assertIn("curl", missing)
        self.assertIn("python3", missing)
        self.assertIn("openssl", missing)

    def test_reports_the_missing_certificate_bundle(self):
        with patch.object(lr.shutil, "which", return_value="/usr/bin/tool"), \
             patch.object(lr.Path, "is_file", return_value=False):
            missing = lr.prereqs_present()
        self.assertIn("ca-certificates", missing)


if __name__ == "__main__":
    unittest.main()
