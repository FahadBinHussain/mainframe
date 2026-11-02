"""Live, opt-in tests for the approval relay - real ntfy, real RSA.

the mocked tests in test_linux_real_vault_relay.py pin the logic against a
local relay; these pin the thing the phone actually talks to: a genuine
RSA-2048 OAEP-SHA256 ciphertext posted to a real relay topic, decrypted by
the same module the runner uses.

the module under test is vault-approval.psm1 - the ONE implementation.

needs network access. skipped unless MAINFRAME_LIVE_RELAY=1.

    MAINFRAME_LIVE_RELAY=1 python -m unittest tests.test_linux_real_vault_relay_live -v
"""
from __future__ import annotations

import os
import re
import secrets
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from vault_relay_harness import PWSH, module_dir, profile_root

LIVE = os.environ.get("MAINFRAME_LIVE_RELAY") == "1"
RELAY = os.environ.get("MAINFRAME_LIVE_RELAY_SERVER", "https://ntfy.sh")


def _post(topic: str, body: bytes, server: str = RELAY) -> None:
    req = urllib.request.Request(f"{server}/{topic}", data=body, method="POST")
    with urllib.request.urlopen(req, timeout=15) as resp:
        if resp.status != 200:
            raise AssertionError(f"relay rejected post: {resp.status}")


def _read_topic(topic: str, server: str = RELAY) -> str:
    with urllib.request.urlopen(f"{server}/{topic}/raw?poll=1", timeout=15) as resp:
        return resp.read().decode("utf-8", errors="replace")


@unittest.skipUnless(LIVE, "set MAINFRAME_LIVE_RELAY=1 to hit the real relay")
@unittest.skipUnless(PWSH, "pwsh is not available on this machine")
class LiveRelayTests(unittest.TestCase):

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.modules = module_dir()
        self.env = dict(os.environ)
        self.env["MAINFRAME_PROFILE_ROOT"] = str(profile_root(self.tmp))
        self.topic = "mf-vault-live-" + secrets.token_hex(12)

    def tearDown(self):
        self._tmp.cleanup()

    def _script(self, body: str) -> Path:
        path = self.modules / "live-driver.ps1"
        path.write_text(
            "$ErrorActionPreference = 'Stop'\n"
            f"Import-Module '{self.modules / 'vault-approval.psm1'}' -Force -DisableNameChecking\n"
            f"{body}\n", encoding="utf-8")
        return path

    def test_the_real_relay_skips_junk_and_foreign_ciphertext_then_accepts_ours(self):
        password = "live-master-" + secrets.token_hex(4)
        script = self._script(f"""
$rsa = [System.Security.Cryptography.RSA]::Create(2048)
$foreign = [System.Security.Cryptography.RSA]::Create(2048)
$password = '{password}'
$ours = [Convert]::ToBase64String($rsa.Encrypt([Text.Encoding]::UTF8.GetBytes($password), [System.Security.Cryptography.RSAEncryptionPadding]::OaepSHA256))
$foreignCipher = [Convert]::ToBase64String($foreign.Encrypt([Text.Encoding]::UTF8.GetBytes('not-your-approval'), [System.Security.Cryptography.RSAEncryptionPadding]::OaepSHA256))
Write-Output "READY $ours $foreignCipher"
$ct = Wait-VaultApprovalCiphertext -Sid '{self.topic}' -TimeoutSeconds 60 -Rsa $rsa -Server '{RELAY}'
if (-not $ct) {{ Write-Output 'NO APPROVAL'; exit 1 }}
$plain = Decrypt-VaultApprovalCiphertext -Rsa $rsa -Ciphertext $ct
Write-Output "PASSWORD $plain"
""")
        proc = subprocess.Popen([PWSH, "-NoLogo", "-NoProfile", "-NonInteractive", "-File", str(script)],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=self.env)
        try:
            line = proc.stdout.readline()
            self.assertTrue(line.startswith("READY"), f"the driver did not start: {line}")
            ours, foreign = line.split()[1], line.split()[2]
            _post(self.topic, b"junk-16-bytes!!")
            time.sleep(3)
            _post(self.topic, foreign.encode())
            time.sleep(3)
            _post(self.topic, ours.encode())
            out, err = proc.communicate(timeout=90)
        except Exception:
            proc.kill()
            raise
        self.assertIn(f"PASSWORD {password}", out, f"stderr: {err[-800:]}")
        self.assertNotIn("NO APPROVAL", out)

    def test_a_timeout_publishes_the_expired_marker(self):
        script = self._script(f"""
$rsa = [System.Security.Cryptography.RSA]::Create(2048)
$pw = Get-VaultMasterPassword -NtfyTopic '{self.topic}' -TimeoutSeconds 8 -PromptContext 'live test' -Server '{RELAY}'
Write-Output "RESULT $pw"
""")
        proc = subprocess.Popen([PWSH, "-NoLogo", "-NoProfile", "-NonInteractive", "-File", str(script)],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=self.env)
        out, err = proc.communicate(timeout=120)
        sid = re.search(r"sid=(mf-vault-[0-9a-f]+)", out)
        self.assertIsNotNone(sid, f"no sid in the approval url: {out[-800:]} {err[-400:]}")
        markers = []
        deadline = time.time() + 20
        while time.time() < deadline:
            markers = [line for line in _read_topic(sid.group(1)).splitlines()
                       if line.strip().startswith('{"mf"')]
            if markers:
                break
            time.sleep(1)
        self.assertTrue(markers, "the timeout did not publish an expired marker")
        self.assertIn('"expired"', markers[-1])
        self.assertIn('"live test"', markers[-1] + out)


if __name__ == "__main__":
    unittest.main()
