"""Tests for mobile approval / ntfy vault unlock flow in linux_real.py."""

from __future__ import annotations

import base64
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

import linux_real as lr


class LinuxRealVaultRelayTests(unittest.TestCase):

    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.root = Path(self.temp_dir.name)

    def tearDown(self):
        self.temp_dir.cleanup()

    def test_load_config_and_get_ntfy_topic_precedence(self):
        cfg_file = self.root / "mainframe.config.json"
        cfg_file.write_text(json.dumps({
            "bitwardenEmail": "user@example.com",
            "ntfyTopic": "cfg-topic"
        }))

        # 1. From config
        with patch.dict(os.environ, {}, clear=True):
            loaded = lr.load_config(self.root)
            self.assertEqual(loaded.get("ntfyTopic"), "cfg-topic")
            self.assertEqual(lr.get_ntfy_topic(self.root), "cfg-topic")

        # 2. Env overrides config
        with patch.dict(os.environ, {"MAINFRAME_NTFY_TOPIC": "env-topic"}):
            self.assertEqual(lr.get_ntfy_topic(self.root), "env-topic")

        # 3. Explicit argument overrides env and config
        with patch.dict(os.environ, {"MAINFRAME_NTFY_TOPIC": "env-topic"}):
            self.assertEqual(
                lr.get_ntfy_topic(self.root, explicit="explicit-topic"),
                "explicit-topic"
            )

    @patch("urllib.request.urlopen")
    def test_dispatch_ntfy_unlock_success(self, mock_urlopen):
        mock_resp = MagicMock()
        mock_resp.status = 200
        mock_resp.__enter__.return_value = mock_resp
        mock_urlopen.return_value = mock_resp

        url = "https://fahadbinhussain.github.io/mainframe/docs/vault-tab.html#k=testpub&sid=mf-vault-1234"
        ok = lr.dispatch_ntfy_unlock("my-phone-topic", url, hostname="test-box")
        self.assertTrue(ok)

        self.assertEqual(mock_urlopen.call_count, 1)
        req = mock_urlopen.call_args[0][0]
        self.assertEqual(req.full_url, "https://ntfy.sh/my-phone-topic")
        self.assertEqual(req.headers.get("Title"), "Mainframe Restore: Vault Unlock (test-box)")
        self.assertEqual(req.headers.get("Priority"), "urgent")
        self.assertEqual(req.headers.get("Click"), url)
        self.assertIn("view, Unlock Vault", req.headers.get("Actions"))

    @patch("urllib.request.urlopen")
    def test_dispatch_ntfy_unlock_custom_server(self, mock_urlopen):
        mock_resp = MagicMock()
        mock_resp.status = 200
        mock_resp.__enter__.return_value = mock_resp
        mock_urlopen.return_value = mock_resp

        url = "https://example.com/tab"
        ok = lr.dispatch_ntfy_unlock("https://custom.ntfy.corp/my-topic", url, hostname="test-box")
        self.assertTrue(ok)

        req = mock_urlopen.call_args[0][0]
        self.assertEqual(req.full_url, "https://custom.ntfy.corp/my-topic")

    @patch("os.chmod")
    @patch("subprocess.run")
    def test_generate_tab_key_format(self, mock_run, mock_chmod):
        def fake_run(cmd, capture_output=True):
            if "-out" in cmd:
                out_path = Path(cmd[cmd.index("-out") + 1])
                out_path.write_text("fake private key")
            return MagicMock(returncode=0, stdout=b"dummy_der_public_key_bytes")

        mock_run.side_effect = fake_run

        work_root = self.root / "work"
        url, priv, reply_topic = lr.generate_tab_key(work_root, reply_topic="mf-vault-fixed123")

        self.assertEqual(priv.name, "vault-tab.key")
        self.assertEqual(reply_topic, "mf-vault-fixed123")
        self.assertIn("#k=", url)
        self.assertIn("&sid=mf-vault-fixed123", url)

    @patch("os.chmod")
    @patch("subprocess.run")
    def test_generate_tab_key_no_relay(self, mock_run, mock_chmod):
        def fake_run(cmd, capture_output=True):
            if "-out" in cmd:
                out_path = Path(cmd[cmd.index("-out") + 1])
                out_path.write_text("fake private key")
            return MagicMock(returncode=0, stdout=b"dummy_der_public_key_bytes")

        mock_run.side_effect = fake_run

        work_root = self.root / "work"
        url, priv, reply_topic = lr.generate_tab_key(work_root, enable_relay=False)
        self.assertIsNone(reply_topic)
        self.assertIn("#k=", url)
        self.assertNotIn("&sid=", url)

    @patch("subprocess.run")
    @patch("urllib.request.urlopen")
    def test_wait_for_tab_password_from_relay(self, mock_urlopen, mock_subproc):
        cipher_bytes = b"encrypted_payload_bytes"
        b64_cipher = base64.b64encode(cipher_bytes).decode("ascii")

        mock_resp = MagicMock()
        mock_resp.status = 200
        mock_resp.read.return_value = (b64_cipher + "\n").encode("utf-8")
        mock_resp.__enter__.return_value = mock_resp
        mock_urlopen.return_value = mock_resp

        mock_subproc.return_value = MagicMock(returncode=0, stdout=b"plaintext_master_pw")

        priv_key = self.root / "vault-tab.key"
        priv_key.write_text("dummy key")

        pw = lr.wait_for_tab_password(priv_key, reply_topic="mf-vault-test999")
        self.assertEqual(pw, "plaintext_master_pw")

        mock_subproc.assert_called_once()
        cmd = mock_subproc.call_args[0][0]
        self.assertIn("-decrypt", cmd)
        self.assertIn("rsa_padding_mode:oaep", cmd)
        self.assertEqual(mock_subproc.call_args[1]["input"], cipher_bytes)

    @patch("pathlib.Path.home")
    @patch("subprocess.run")
    def test_wait_for_tab_password_from_file(self, mock_subproc, mock_home):
        fake_home = self.root / "fakehome"
        mock_home.return_value = fake_home
        downloads_dir = fake_home / "Downloads"
        downloads_dir.mkdir(parents=True, exist_ok=True)
        target = downloads_dir / lr.TAB_CIPHER_NAME

        cipher_bytes = b"file_payload_bytes"
        b64_cipher = base64.b64encode(cipher_bytes).decode("ascii")

        # Simulate file arriving during sleep
        def fake_sleep(seconds):
            target.write_text(b64_cipher)

        mock_subproc.return_value = MagicMock(returncode=0, stdout=b"unlocked_from_file")

        priv_key = self.root / "vault-tab.key"
        priv_key.write_text("dummy key")

        with patch("time.sleep", side_effect=fake_sleep):
            pw = lr.wait_for_tab_password(priv_key, reply_topic=None)
            self.assertEqual(pw, "unlocked_from_file")
            self.assertFalse(target.exists(), "Target file must be removed after decryption")


if __name__ == "__main__":
    unittest.main()
