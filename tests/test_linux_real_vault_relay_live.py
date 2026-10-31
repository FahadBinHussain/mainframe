"""Live, opt-in tests for the python approval relay path -- real ntfy, real openssl.

the mocked tests in test_linux_real_vault_relay.py pin the logic; these pin the
thing the phone actually talks to: a genuine RSA-2048 OAEP-SHA256 ciphertext
posted to a real relay topic, decrypted by the runner's own openssl call. needs
network access and the openssl cli. skipped unless MAINFRAME_LIVE_RELAY=1.

    MAINFRAME_LIVE_RELAY=1 python -m unittest tests.test_linux_real_vault_relay_live -v
"""

from __future__ import annotations

import base64
import os
import secrets
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.request
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import linux_real as lr

LIVE = os.environ.get("MAINFRAME_LIVE_RELAY") == "1"
RELAY = "https://ntfy.sh"


def _run(argv, stdin: bytes | None = None) -> bytes:
    return subprocess.run(argv, input=stdin, capture_output=True,
                          check=True).stdout


def _keypair(root: Path, name: str) -> tuple[Path, Path]:
    priv = root / f"{name}.key"
    pub = root / f"{name}.pub"
    _run(["openssl", "genpkey", "-algorithm", "RSA",
          "-pkeyopt", "rsa_keygen_bits:2048", "-out", str(priv)])
    _run(["openssl", "pkey", "-in", str(priv), "-pubout", "-out", str(pub)])
    return priv, pub


def _encrypt(pub: Path, plain: bytes) -> str:
    ct = _run(["openssl", "pkeyutl", "-encrypt", "-pubin", "-inkey", str(pub),
               "-pkeyopt", "rsa_padding_mode:oaep",
               "-pkeyopt", "rsa_oaep_md:sha256",
               "-pkeyopt", "rsa_mgf1_md:sha256"], stdin=plain)
    return base64.b64encode(ct).decode("ascii")


def _post(topic: str, body: bytes) -> None:
    req = urllib.request.Request(f"{RELAY}/{topic}", data=body, method="POST")
    with urllib.request.urlopen(req, timeout=10) as resp:
        assert resp.status == 200, f"relay rejected post: {resp.status}"


def _read_topic(topic: str) -> str:
    with urllib.request.urlopen(f"{RELAY}/{topic}/raw?poll=1", timeout=10) as resp:
        return resp.read().decode("utf-8")


@unittest.skipUnless(LIVE, "set MAINFRAME_LIVE_RELAY=1 to hit the real ntfy relay")
class LiveRelayTests(unittest.TestCase):

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self._home = self.root / "home"
        self._home.mkdir()
        self.topic = "mf-vault-" + secrets.token_hex(12)

    def tearDown(self):
        self._tmp.cleanup()

    def test_skips_junk_and_foreign_ciphertext_then_accepts_ours(self):
        priv, pub = _keypair(self.root, "ours")
        _, foreign_pub = _keypair(self.root, "foreign")

        password = "live-master-" + secrets.token_hex(4)
        junk = base64.b64encode(b"junk-16-bytes!!").decode("ascii")
        foreign = _encrypt(foreign_pub, b"not-your-approval")
        ours = _encrypt(pub, password.encode())

        result: dict = {}

        def waiter():
            result["pw"] = lr.wait_for_tab_password(priv, reply_topic=self.topic)

        with patch("pathlib.Path.home", return_value=self._home), \
                patch.object(lr, "TAB_WAIT_SECONDS", 30):
            t = threading.Thread(target=waiter, daemon=True)
            t.start()
            time.sleep(1.0)
            _post(self.topic, junk.encode())
            time.sleep(2.5)
            _post(self.topic, foreign.encode())
            time.sleep(2.5)
            _post(self.topic, ours.encode())
            t.join(timeout=30)

        self.assertFalse(t.is_alive(), "waiter did not return on a live relay")
        self.assertEqual(result.get("pw"), password)

    def test_timeout_publishes_expired_marker(self):
        priv, _ = _keypair(self.root, "idle")

        with patch("pathlib.Path.home", return_value=self._home), \
                patch.object(lr, "TAB_WAIT_SECONDS", 4):
            with self.assertRaises(RuntimeError):
                lr.wait_for_tab_password(priv, reply_topic=self.topic,
                                         host="live-test", code="42")

        markers = []
        deadline = time.time() + 15
        while time.time() < deadline:
            markers = [ln for ln in _read_topic(self.topic).splitlines()
                       if ln.strip().startswith('{"mf"')]
            if markers:
                break
            time.sleep(1)
        self.assertTrue(markers, "timeout did not publish an expired marker")
        self.assertIn('"expired"', markers[-1])
        self.assertIn('"live-test"', markers[-1])
        self.assertIn('"42"', markers[-1])


if __name__ == "__main__":
    unittest.main()
