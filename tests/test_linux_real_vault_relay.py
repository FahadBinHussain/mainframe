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
        self.assertEqual(req.headers.get("Title"), "Vault Unlock (test-box)")
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
        url, priv, reply_topic, code, agent, model = lr.generate_tab_key(work_root, reply_topic="mf-vault-fixed123")

        self.assertEqual(priv.name, "vault-tab.key")
        self.assertEqual(reply_topic, "mf-vault-fixed123")
        self.assertIn("#k=", url)
        self.assertIn("&sid=mf-vault-fixed123", url)
        self.assertTrue(code.isdigit())

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
        url, priv, reply_topic, code, agent, model = lr.generate_tab_key(work_root, enable_relay=False)
        self.assertIsNone(reply_topic)
        self.assertIn("#k=", url)
        self.assertNotIn("&sid=", url)

    @patch("os.chmod")
    @patch("subprocess.run")
    def test_generate_tab_key_deadline(self, mock_run, mock_chmod):
        def fake_run(cmd, capture_output=True):
            if "-out" in cmd:
                out_path = Path(cmd[cmd.index("-out") + 1])
                out_path.write_text("fake private key")
            return MagicMock(returncode=0, stdout=b"dummy_der_public_key_bytes")

        mock_run.side_effect = fake_run

        work_root = self.root / "work"
        started = int(lr.time.time())
        url, *_ = lr.generate_tab_key(work_root, enable_relay=False,
                                      expires_in=lr.TAB_WAIT_SECONDS)
        # the card needs the runner's own deadline in the link, otherwise it
        # can only sit there looking approvable after the runner gave up.
        exp = int(url.split("&exp=")[1].split("&")[0])
        self.assertGreaterEqual(exp, started + lr.TAB_WAIT_SECONDS)
        self.assertLessEqual(exp, started + lr.TAB_WAIT_SECONDS + 5)

        url, *_ = lr.generate_tab_key(work_root, enable_relay=False)
        self.assertNotIn("&exp=", url)

    def test_get_ntfy_server_precedence(self):
        cfg_file = self.root / "mainframe.config.json"
        cfg_file.write_text(json.dumps({
            "ntfyTopic": "cfg-topic",
            "ntfyServer": "https://cfg-relay.example"
        }))

        with patch.dict(os.environ, {}, clear=True):
            self.assertEqual(lr.get_ntfy_server(self.root), "https://cfg-relay.example")

        with patch.dict(os.environ, {"MAINFRAME_NTFY_SERVER": "https://env-relay.example"}):
            self.assertEqual(lr.get_ntfy_server(self.root), "https://env-relay.example")

        with patch.dict(os.environ, {"MAINFRAME_NTFY_SERVER": "https://env-relay.example"}):
            self.assertEqual(
                lr.get_ntfy_server(self.root, explicit="https://explicit-relay.example/"),
                "https://explicit-relay.example")

        # no config, no env -> ntfy.sh
        with patch.dict(os.environ, {}, clear=True):
            self.assertEqual(lr.get_ntfy_server(self.root / "missing"), lr.DEFAULT_NTFY_SERVER)

    def test_get_pages_base_precedence(self):
        cfg_file = self.root / "mainframe.config.json"
        cfg_file.write_text(json.dumps({"pagesBase": "https://pages.example"}))

        with patch.dict(os.environ, {}, clear=True):
            self.assertEqual(lr.get_pages_base(self.root), "https://pages.example")

        with patch.dict(os.environ, {"MAINFRAME_PAGES_BASE": "https://env-pages.example/"}):
            self.assertEqual(lr.get_pages_base(self.root), "https://env-pages.example")

        with patch.dict(os.environ, {"MAINFRAME_PAGES_BASE": "https://env-pages.example"}):
            self.assertEqual(
                lr.get_pages_base(self.root, explicit="https://explicit-pages.example"),
                "https://explicit-pages.example")

        # no config, no env -> the GitHub Pages url of the public tool repo
        with patch.dict(os.environ, {}, clear=True):
            self.assertEqual(lr.get_pages_base(self.root / "missing"),
                             "https://fahadbinhussain.github.io/mainframe")

    @patch("urllib.request.urlopen")
    def test_dispatch_ntfy_unlock_uses_configured_server(self, mock_urlopen):
        mock_resp = MagicMock()
        mock_resp.status = 200
        mock_resp.__enter__.return_value = mock_resp
        mock_urlopen.return_value = mock_resp

        ok = lr.dispatch_ntfy_unlock("my-phone-topic", "https://example.com/tab",
                                     hostname="test-box",
                                     server="https://relay.example/ntfy")
        self.assertTrue(ok)

        req = mock_urlopen.call_args[0][0]
        self.assertEqual(req.full_url, "https://relay.example/ntfy/my-phone-topic")

    @patch("os.chmod")
    @patch("subprocess.run")
    def test_generate_tab_key_uses_configured_pages_base_and_relay(self, mock_run, mock_chmod):
        def fake_run(cmd, capture_output=True):
            if "-out" in cmd:
                out_path = Path(cmd[cmd.index("-out") + 1])
                out_path.write_text("fake private key")
            return MagicMock(returncode=0, stdout=b"dummy_der_public_key_bytes")

        mock_run.side_effect = fake_run

        work_root = self.root / "work"
        url, *_ = lr.generate_tab_key(
            work_root, reply_topic="mf-vault-fixed123",
            pages_base="https://pages.example",
            relay_base="https://relay.example/ntfy")

        self.assertTrue(url.startswith("https://pages.example/docs/vault-tab.html#"))
        self.assertIn("srv=https%3A%2F%2Frelay.example%2Fntfy", url)

    @patch("os.chmod")
    @patch("subprocess.run")
    def test_generate_tab_key_omits_relay_param_for_default_server(self, mock_run, mock_chmod):
        def fake_run(cmd, capture_output=True):
            if "-out" in cmd:
                out_path = Path(cmd[cmd.index("-out") + 1])
                out_path.write_text("fake private key")
            return MagicMock(returncode=0, stdout=b"dummy_der_public_key_bytes")

        mock_run.side_effect = fake_run

        url, *_ = lr.generate_tab_key(self.root / "work", enable_relay=False,
                                      relay_base=lr.DEFAULT_NTFY_SERVER)
        self.assertNotIn("srv=", url)

    @patch("urllib.request.urlopen")
    def test_wait_for_tab_password_polls_configured_server(self, mock_urlopen):
        cipher_bytes = b"x" * 256
        b64_cipher = base64.b64encode(cipher_bytes).decode("ascii")

        mock_resp = MagicMock()
        mock_resp.status = 200
        mock_resp.read.return_value = (b64_cipher + "\n").encode("utf-8")
        mock_resp.__enter__.return_value = mock_resp
        mock_urlopen.return_value = mock_resp

        with patch("subprocess.run") as mock_subproc:
            mock_subproc.return_value = MagicMock(returncode=0, stdout=b"plaintext_master_pw")
            priv_key = self.root / "vault-tab.key"
            priv_key.write_text("dummy key")

            pw = lr.wait_for_tab_password(priv_key, reply_topic="mf-vault-test999",
                                          server="https://relay.example/ntfy")
            self.assertEqual(pw, "plaintext_master_pw")

        req = mock_urlopen.call_args[0][0]
        self.assertEqual(req.full_url, "https://relay.example/ntfy/mf-vault-test999/raw?poll=1")

    @patch("subprocess.run")
    @patch("urllib.request.urlopen")
    def test_wait_for_tab_password_ignores_expired_marker(self, mock_urlopen, mock_subproc):
        cipher_bytes = b"x" * 256
        b64_cipher = base64.b64encode(cipher_bytes).decode("ascii")
        marker = json.dumps({"mf": "expired", "at": 1700000000})

        mock_resp = MagicMock()
        mock_resp.status = 200
        mock_resp.read.return_value = (marker + "\n" + b64_cipher + "\n").encode("utf-8")
        mock_resp.__enter__.return_value = mock_resp
        mock_urlopen.return_value = mock_resp

        mock_subproc.return_value = MagicMock(returncode=0, stdout=b"plaintext_master_pw")

        priv_key = self.root / "vault-tab.key"
        priv_key.write_text("dummy key")

        pw = lr.wait_for_tab_password(priv_key, reply_topic="mf-vault-test999")
        self.assertEqual(pw, "plaintext_master_pw")
        self.assertEqual(mock_subproc.call_args[1]["input"], cipher_bytes)

    @patch("pathlib.Path.home")
    @patch("urllib.request.urlopen")
    def test_wait_for_tab_password_timeout_publishes_expired_marker(self, mock_urlopen, mock_home):
        mock_home.return_value = self.root / "fakehome"
        mock_resp = MagicMock()
        mock_resp.status = 200
        mock_resp.read.return_value = b""
        mock_resp.__enter__.return_value = mock_resp
        mock_urlopen.return_value = mock_resp

        priv_key = self.root / "vault-tab.key"
        priv_key.write_text("dummy key")

        with patch.object(lr, "TAB_WAIT_SECONDS", 0):
            with self.assertRaises(RuntimeError):
                lr.wait_for_tab_password(priv_key, reply_topic="mf-vault-test999",
                                         host="test-box", code="42")

        self.assertEqual(mock_urlopen.call_count, 1)
        req = mock_urlopen.call_args[0][0]
        self.assertEqual(req.full_url, "https://ntfy.sh/mf-vault-test999")
        self.assertEqual(req.headers.get("Title"), "Vault Request Expired")
        body = json.loads(req.data.decode("utf-8"))
        self.assertEqual(body["mf"], "expired")
        self.assertEqual(body["host"], "test-box")
        self.assertEqual(body["code"], "42")
        self.assertIsInstance(body["at"], int)

    @patch("subprocess.run")
    @patch("urllib.request.urlopen")
    def test_wait_for_tab_password_from_relay(self, mock_urlopen, mock_subproc):
        cipher_bytes = b"x" * 256
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

    @patch("subprocess.run")
    @patch("urllib.request.urlopen")
    def test_wait_for_tab_password_skips_noise_that_does_not_decrypt(self, mock_urlopen, mock_subproc):
        good = base64.b64encode(b"g" * 256).decode("ascii")
        junk = base64.b64encode(b"j" * 256).decode("ascii")

        mock_resp = MagicMock()
        mock_resp.status = 200
        # junk posted last: newest-first scan must try it, fail, then take good
        mock_resp.read.return_value = (good + "\n" + junk + "\n").encode("utf-8")
        mock_resp.__enter__.return_value = mock_resp
        mock_urlopen.return_value = mock_resp

        mock_subproc.side_effect = [
            MagicMock(returncode=1, stdout=b""),
            MagicMock(returncode=0, stdout=b"plaintext_master_pw"),
        ]

        priv_key = self.root / "vault-tab.key"
        priv_key.write_text("dummy key")

        pw = lr.wait_for_tab_password(priv_key, reply_topic="mf-vault-test999")
        self.assertEqual(pw, "plaintext_master_pw")
        self.assertEqual(mock_subproc.call_count, 2)

    @patch("pathlib.Path.home")
    @patch("subprocess.run")
    def test_wait_for_tab_password_from_file(self, mock_subproc, mock_home):
        fake_home = self.root / "fakehome"
        mock_home.return_value = fake_home
        downloads_dir = fake_home / "Downloads"
        downloads_dir.mkdir(parents=True, exist_ok=True)
        target = downloads_dir / lr.TAB_CIPHER_NAME

        cipher_bytes = b"x" * 256
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
