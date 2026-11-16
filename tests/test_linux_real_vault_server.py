"""The linux side of ntfy server convergence.

There is no python copy of the vault flow (see
test_linux_real_vault_session.py): linux shells out to vault-flow.ps1,
so the server convergence lives there too, next to the topic
convergence. these tests pin the WIRING - the module exists, the flow
imports it and calls the sync on both live-session paths - so a
refactor cannot silently drop the linux half of the convergence. the
sync behavior itself is covered by
tests/vault-approval-server-converge.Tests.ps1.
"""
import sys
import unittest
from pathlib import Path

REPO = Path(__file__).parents[1]
sys.path.insert(0, str(REPO))
from linux import linux_real as lr  # noqa: E402

MODULE = REPO / "windows" / "vault-ntfy-server.psm1"
FLOW = REPO / "windows" / "vault-flow.ps1"
ITEM_NAME = "github.com/FahadBinHussain/mainframe / mainframe.ntfy-server"


class ServerConvergenceModuleTests(unittest.TestCase):
    """The sync module exists and mirrors the topic sync's shape."""

    def test_the_module_exists(self):
        self.assertTrue(MODULE.is_file())

    def test_the_sync_functions_exist(self):
        source = MODULE.read_text(encoding="utf-8")
        self.assertIn("function Sync-VaultNtfyServerFromVault", source)
        self.assertIn("function Get-VaultNtfyServerFromVault", source)

    def test_the_vault_item_name_matches_the_topic_items_shape(self):
        source = MODULE.read_text(encoding="utf-8")
        self.assertIn(ITEM_NAME, source)

    def test_the_sync_functions_are_exported(self):
        source = MODULE.read_text(encoding="utf-8")
        self.assertIn("Get-VaultNtfyServerFromVault, `", source)
        self.assertIn("Sync-VaultNtfyServerFromVault", source)

    def test_validation_requires_https_and_the_ntfy_path(self):
        source = MODULE.read_text(encoding="utf-8")
        self.assertIn("^https://", source)
        self.assertIn("/ntfy$", source)


class VaultFlowWiringTests(unittest.TestCase):
    """vault-flow.ps1 - the ONE flow, linux included - runs the sync."""

    def test_the_flow_imports_the_server_module(self):
        source = FLOW.read_text(encoding="utf-8")
        self.assertIn("vault-ntfy-server.psm1", source)

    def test_the_sync_runs_on_both_live_session_paths(self):
        # cached session AND fresh unlock: the two places the topic sync
        # runs, the server sync runs too. two call sites, no more, no less.
        source = FLOW.read_text(encoding="utf-8")
        calls = [line for line in source.splitlines()
                 if "Sync-VaultNtfyServerFromVault -Session" in line]
        self.assertEqual(len(calls), 2,
                         "expected exactly two sync call sites "
                         "(cached session + fresh unlock)")
        self.assertTrue(any("$cached" in line for line in calls),
                        "one call site must use the cached session")
        self.assertTrue(any("$session" in line for line in calls),
                        "one call site must use the fresh session")

    def test_the_sync_never_fails_the_flow(self):
        # both call sites are best-effort, like the topic sync: wrapped in
        # try/catch with an empty catch.
        source = FLOW.read_text(encoding="utf-8")
        calls = [line for line in source.splitlines()
                 if "Sync-VaultNtfyServerFromVault -Session" in line]
        for line in calls:
            self.assertIn("try {", line)
            self.assertIn("} catch {}", line)


class LinuxEntryPointTests(unittest.TestCase):
    """Linux reaches the same flow, so it converges the same way."""

    def test_linux_still_runs_vault_flow_ps1(self):
        cmd = lr.vault_flow_command(REPO, "/opt/pwsh", "/opt/bw")
        self.assertIn(str(REPO / "windows" / "vault-flow.ps1"), cmd)


if __name__ == "__main__":
    unittest.main()
