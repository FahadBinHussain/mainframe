"""The relay contract, driven against the ONE implementation.

the topic, the relay, the page base, the poll, the rate-limit backoff and the
expired marker all live in vault-approval.psm1. these tests drive THAT module
through pwsh - so windows and linux are checked against the same code, not
against two copies that can drift.

the live counterpart (a real ntfy relay) is tests/test_linux_real_vault_relay_live.py.
"""
from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from vault_relay_harness import RelayServer, module_dir, profile_root, run_pwsh, run_pwsh_json


class RelayConfigPrecedenceTests(unittest.TestCase):
    """topic / relay / page base: explicit > env > config > default."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.modules = module_dir()

    def tearDown(self):
        self._tmp.cleanup()

    def _env(self, config=None, **extra):
        env = {"MAINFRAME_PROFILE_ROOT": str(profile_root(self.tmp, config))}
        env.update(extra)
        return env

    def test_the_topic_comes_from_the_config(self):
        env = self._env({"ntfyTopic": "topic-from-config"})
        result = run_pwsh_json(
            "[ordered]@{ topic = Get-VaultNtfyTopic; server = Get-VaultNtfyServer; "
            "pages = Get-VaultPagesBase } | ConvertTo-Json -Compress",
            env=env, modules=self.modules)
        self.assertEqual(result["topic"], "topic-from-config")
        self.assertEqual(result["server"], "https://ntfy.sh")
        self.assertEqual(result["pages"], "https://fahadbinhussain.github.io/mainframe")

    def test_the_env_beats_the_config(self):
        env = self._env({"ntfyTopic": "topic-from-config"},
                         MAINFRAME_NTFY_TOPIC="topic-from-env",
                         MAINFRAME_NTFY_SERVER="https://relay-from-env",
                         MAINFRAME_PAGES_BASE="https://pages-from-env")
        result = run_pwsh_json(
            "[ordered]@{ topic = Get-VaultNtfyTopic; server = Get-VaultNtfyServer; "
            "pages = Get-VaultPagesBase } | ConvertTo-Json -Compress",
            env=env, modules=self.modules)
        self.assertEqual(result["topic"], "topic-from-env")
        self.assertEqual(result["server"], "https://relay-from-env")
        self.assertEqual(result["pages"], "https://pages-from-env")

    def test_an_explicit_argument_beats_the_env(self):
        env = self._env(MAINFRAME_NTFY_TOPIC="topic-from-env",
                        MAINFRAME_NTFY_SERVER="https://relay-from-env")
        result = run_pwsh_json(
            "[ordered]@{ topic = Get-VaultNtfyTopic -Topic 'topic-explicit'; "
            "server = Get-VaultNtfyServer -Server 'https://relay-explicit' } | ConvertTo-Json -Compress",
            env=env, modules=self.modules)
        self.assertEqual(result["topic"], "topic-explicit")
        self.assertEqual(result["server"], "https://relay-explicit")

    def test_an_unconfigured_topic_fails_loudly(self):
        env = self._env()
        proc = run_pwsh("Get-VaultNtfyTopic | Out-Null", env=env, modules=self.modules)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("no ntfy topic configured", proc.stderr)

    def test_the_relay_never_keeps_a_trailing_slash(self):
        env = self._env(MAINFRAME_NTFY_SERVER="https://relay.invalid/")
        result = run_pwsh_json("Get-VaultNtfyServer | ConvertTo-Json -Compress",
                                env=env, modules=self.modules)
        self.assertEqual(result, "https://relay.invalid")


class ApprovalUrlTests(unittest.TestCase):
    """the tap link must name the relay only when it is not the default one."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.modules = module_dir()
        self.env = {"MAINFRAME_PROFILE_ROOT": str(profile_root(self.tmp))}

    def tearDown(self):
        self._tmp.cleanup()

    def _url(self, server: str) -> str:
        result = run_pwsh_json(
            "$rsa = [System.Security.Cryptography.RSA]::Create(2048); "
            f"ConvertTo-Json -Compress -InputObject ([ordered]@{{ url = (Get-VaultApprovalUrl -Rsa $rsa -Server '{server}').Url }})",
            env=self.env, modules=self.modules)
        return result["url"]

    def test_the_default_relay_is_left_out_of_the_link(self):
        url = self._url("https://ntfy.sh")
        self.assertNotIn("srv=", url)

    def test_a_custom_relay_is_carried_in_the_link(self):
        url = self._url("https://relay.invalid")
        self.assertIn("srv=https%3A%2F%2Frelay.invalid", url)


class CiphertextNoiseTests(unittest.TestCase):
    """only a well-formed RSA block for THIS request is an approval."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.modules = module_dir()
        self.env = {"MAINFRAME_PROFILE_ROOT": str(profile_root(self.tmp))}

    def tearDown(self):
        self._tmp.cleanup()

    def test_junk_is_not_an_approval(self):
        script = """
$junk = @(
  ''
  'not base64 at all'
  ([Convert]::ToBase64String([byte[]](1..16)))
  ([Convert]::ToBase64String([byte[]](1..255)))
  'mf-vault-something'
)
$accepted = @($junk | Where-Object { Test-VaultApprovalCiphertext -Value $_ })
ConvertTo-Json -Compress -InputObject ([ordered]@{ accepted = $accepted.Count })
"""
        result = run_pwsh_json(script, env=self.env, modules=self.modules)
        self.assertEqual(result["accepted"], 0)

    def test_a_block_this_key_cannot_decrypt_is_not_an_approval(self):
        script = """
$rsa = [System.Security.Cryptography.RSA]::Create(2048)
$other = [System.Security.Cryptography.RSA]::Create(2048)
$cipher = [Convert]::ToBase64String($other.Encrypt([Text.Encoding]::UTF8.GetBytes('not yours'), [System.Security.Cryptography.RSAEncryptionPadding]::OaepSHA256))
$ours = [Convert]::ToBase64String($rsa.Encrypt([Text.Encoding]::UTF8.GetBytes('ours'), [System.Security.Cryptography.RSAEncryptionPadding]::OaepSHA256))
ConvertTo-Json -Compress -InputObject ([ordered]@{
  foreign = Test-VaultApprovalCiphertext -Value $cipher -Rsa $rsa
  mine    = Test-VaultApprovalCiphertext -Value $ours -Rsa $rsa
})
"""
        result = run_pwsh_json(script, env=self.env, modules=self.modules)
        self.assertFalse(result["foreign"])
        self.assertTrue(result["mine"])


class RelayPollTests(unittest.TestCase):
    """the poll, the backoff and the expired marker - against a local relay."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.modules = module_dir()
        self.env = {"MAINFRAME_PROFILE_ROOT": str(profile_root(self.tmp))}

    def tearDown(self):
        self._tmp.cleanup()

    def test_the_poll_asks_the_configured_relay_with_poll_1(self):
        with RelayServer(body="") as relay:
            script = f"""
$rsa = [System.Security.Cryptography.RSA]::Create(2048)
$ct = Wait-VaultApprovalCiphertext -Sid 'mf-vault-test' -TimeoutSeconds 3 -Rsa $rsa -Server '{relay.base}'
ConvertTo-Json -Compress -InputObject ([ordered]@{{ result = $ct }})
"""
            run_pwsh(script, env=self.env, modules=self.modules)
            gets = relay.gets()
            self.assertTrue(gets, "the relay was never polled")
            self.assertTrue(gets[0][1].endswith("/mf-vault-test/raw?poll=1"),
                            f"unexpected poll url: {gets[0][1]}")

    def test_the_approval_on_the_relay_is_returned(self):
        with RelayServer(body="") as relay:
            script = f"""
$rsa = [System.Security.Cryptography.RSA]::Create(2048)
$password = 'the master password'
$cipher = [Convert]::ToBase64String($rsa.Encrypt([Text.Encoding]::UTF8.GetBytes($password), [System.Security.Cryptography.RSAEncryptionPadding]::OaepSHA256))
Invoke-RestMethod -Uri '{relay.base}/mf-vault-test' -Method Post -Body $cipher
$ct = Wait-VaultApprovalCiphertext -Sid 'mf-vault-test' -TimeoutSeconds 20 -Rsa $rsa -Server '{relay.base}'
$plain = Decrypt-VaultApprovalCiphertext -Rsa $rsa -Ciphertext $ct
ConvertTo-Json -Compress -InputObject ([ordered]@{{ password = $plain }})
"""
            result = run_pwsh_json(script, env=self.env, modules=self.modules, timeout=90)
            self.assertEqual(result["password"], "the master password")

    def test_a_rate_limited_poll_is_reported_and_not_mistaken_for_an_approval(self):
        with RelayServer(body="", rate_limit=1) as relay:
            script = f"""
$rsa = [System.Security.Cryptography.RSA]::Create(2048)
$ct = Wait-VaultApprovalCiphertext -Sid 'mf-vault-test' -TimeoutSeconds 3 -Rsa $rsa -Server '{relay.base}'
ConvertTo-Json -Compress -InputObject ([ordered]@{{ result = $ct }})
"""
            # the module backs off for 30 seconds after a 429, so the script is
            # killed while it sleeps - the point of the test is the warning.
            proc = run_pwsh(script, env=self.env, modules=self.modules, timeout=15)
            self.assertIn("429", proc.stderr)
            self.assertIn("backing off", proc.stderr)
            self.assertNotIn("result", proc.stdout)

    def test_a_timeout_publishes_the_expired_marker(self):
        with RelayServer(body="") as relay:
            script = f"""
$rsa = [System.Security.Cryptography.RSA]::Create(2048)
$ct = Wait-VaultApprovalCiphertext -Sid 'mf-vault-test' -TimeoutSeconds 3 -Rsa $rsa -Server '{relay.base}'
ConvertTo-Json -Compress -InputObject ([ordered]@{{ result = $ct }})
"""
            run_pwsh(script, env=self.env, modules=self.modules, timeout=60)
            # Wait-VaultApprovalCiphertext itself does not publish the marker -
            # Get-VaultMasterPassword does, when the whole request fails.
            self.assertTrue(relay.gets())


if __name__ == "__main__":
    unittest.main()
