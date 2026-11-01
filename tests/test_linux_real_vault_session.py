"""Tests for the linux vault session cache (the 1-hour TTL, windows parity).

The windows side caches the raw bw session key in
%APPDATA%\\mainframe\\accounts\\bitwarden\\session.key and reuses it while it
is younger than the TTL, so a second run inside the hour needs no phone
approval. linux_real.py now does the same thing at
<work_root>/vault/session.key.

These fixtures only touch a temp dir - no packages, no clones, no live home.
"""

from __future__ import annotations

import json
import os
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

import linux_real as lr


class LinuxVaultSessionCacheTests(unittest.TestCase):

    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.root = Path(self.temp_dir.name)
        self.work_root = self.root / "work"
        self.checkout = self.root / "checkout"
        self.checkout.mkdir(parents=True, exist_ok=True)
        # the config loader falls back to the working directory, and this box
        # has a real mainframe.config.json in the repo root - run inside an
        # empty temp dir so the fixtures never see it.
        self._old_cwd = os.getcwd()
        self.cwd = self.root / "cwd"
        self.cwd.mkdir(exist_ok=True)
        os.chdir(self.cwd)

    def tearDown(self):
        os.chdir(self._old_cwd)
        self.temp_dir.cleanup()

    # ----------------------------------------------------------- ttl

    def test_ttl_defaults_to_60_minutes(self):
        with patch.dict(os.environ, {}, clear=True):
            self.assertEqual(lr.get_vault_ttl_minutes(self.checkout), 60)

    def test_ttl_comes_from_the_same_config_key_as_windows(self):
        cfg = self.checkout / "mainframe.config.json"
        cfg.write_text(json.dumps({"vaultTtlMinutes": 15}), encoding="utf-8")
        with patch.dict(os.environ, {}, clear=True):
            self.assertEqual(lr.get_vault_ttl_minutes(self.checkout), 15)

    def test_env_overrides_the_config(self):
        cfg = self.checkout / "mainframe.config.json"
        cfg.write_text(json.dumps({"vaultTtlMinutes": 15}), encoding="utf-8")
        with patch.dict(os.environ, {"MAINFRAME_VAULT_TTL_MINUTES": "5"}):
            self.assertEqual(lr.get_vault_ttl_minutes(self.checkout), 5)

    def test_a_broken_ttl_falls_back_to_the_default(self):
        cfg = self.checkout / "mainframe.config.json"
        cfg.write_text(json.dumps({"vaultTtlMinutes": "soon"}), encoding="utf-8")
        with patch.dict(os.environ, {}, clear=True):
            self.assertEqual(lr.get_vault_ttl_minutes(self.checkout), 60)

    # ------------------------------------------------------- the cache

    def test_session_key_lives_next_to_the_bw_install(self):
        self.assertEqual(lr.session_key_path(self.work_root),
                         self.work_root / "vault" / "session.key")

    def test_write_then_read_round_trips_the_key(self):
        lr.write_cached_session(self.work_root, "s3cr3t-session-key")
        path = lr.session_key_path(self.work_root)
        self.assertTrue(path.is_file())
        self.assertEqual(path.read_text(encoding="utf-8"), "s3cr3t-session-key")
        self.assertEqual(lr.read_cached_session(self.work_root, 60),
                         "s3cr3t-session-key")

    @unittest.skipIf(os.name == "nt", "posix file modes do not exist on windows")
    def test_the_cached_key_is_not_world_readable(self):
        lr.write_cached_session(self.work_root, "s3cr3t-session-key")
        mode = lr.session_key_path(self.work_root).stat().st_mode & 0o777
        self.assertEqual(mode, 0o600, "the session key must be owner-only")

    def test_a_fresh_session_is_reused(self):
        lr.write_cached_session(self.work_root, "s3cr3t-session-key")
        self.assertEqual(lr.read_cached_session(self.work_root, 60),
                         "s3cr3t-session-key")

    def test_an_expired_session_is_not_reused(self):
        lr.write_cached_session(self.work_root, "s3cr3t-session-key")
        path = lr.session_key_path(self.work_root)
        old = time.time() - 3600
        os.utime(path, (old, old))
        self.assertIsNone(lr.read_cached_session(self.work_root, 60),
                          "a session older than the TTL must not be reused")

    def test_clear_removes_the_cached_key(self):
        lr.write_cached_session(self.work_root, "s3cr3t-session-key")
        lr.clear_cached_session(self.work_root)
        self.assertFalse(lr.session_key_path(self.work_root).exists())
        self.assertIsNone(lr.read_cached_session(self.work_root, 60))

    def test_clear_on_a_missing_file_is_not_an_error(self):
        lr.clear_cached_session(self.work_root)  # must not raise

    # ------------------------------------------- secret extraction

    def test_extract_picks_the_token_and_the_secrets_password(self):
        items = [
            {"name": "github.com - fahadbinhussain",
             "notes": "[tokens]\nghp_" + "a" * 36},
            {"name": "mainframe-production",
             "notes": "the-secrets-password"},
        ]
        token, secrets = lr.extract_vault_secrets(items)
        self.assertTrue(token.startswith("ghp_"))
        self.assertEqual(secrets, "the-secrets-password")

    def test_extract_falls_back_to_any_github_item_with_a_token(self):
        items = [{"name": "github.com - someone-else",
                  "notes": "[tokens]\nghp_" + "b" * 36}]
        token, secrets = lr.extract_vault_secrets(items)
        self.assertTrue(token.startswith("ghp_"))
        self.assertEqual(secrets, "")

    def test_extract_raises_loudly_when_there_is_no_token(self):
        with self.assertRaises(RuntimeError):
            lr.extract_vault_secrets([{"name": "nothing", "notes": "x"}])


if __name__ == "__main__":
    unittest.main()
