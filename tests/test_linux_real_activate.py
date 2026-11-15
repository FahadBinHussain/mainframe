"""activate(): staged files landing on a live home.

A backup can store a directory itself as a zero-byte member alongside its
children (AppData/Roaming/mainframe/accounts in the real backup), and the
live home can already hold a directory there - the vault flow creates
~/.config/mainframe/accounts for its own session state. Activation must not
die on that file/directory collision, and it must never delete the live
directory to make room for an empty file.
"""
from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO))

from linux import linux_real as lr  # noqa: E402


class ActivateFileDirTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.staging = self.root / "staging"
        self.home = self.root / "home"
        self.work = self.root / "work"
        for d in (self.staging, self.home, self.work):
            d.mkdir(parents=True)

    def tearDown(self):
        self._tmp.cleanup()

    def _stage(self, rel: str, data: bytes):
        path = self.staging / "home-staging" / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)

    def test_empty_staged_file_against_live_directory_is_skipped(self):
        self._stage(".config/mainframe/accounts", b"")
        live = self.home / ".config" / "mainframe" / "accounts" / "bitwarden"
        live.mkdir(parents=True)
        (live / "session.key").write_text("live-session")
        result = lr.activate(self.staging, self.home, self.work)
        self.assertIn(".config/mainframe/accounts",
                      result["skipped_file_dir_conflicts"])
        self.assertTrue((live / "session.key").exists())
        self.assertEqual((live / "session.key").read_text(), "live-session")

    def test_nonempty_staged_file_against_live_directory_fails_loudly(self):
        self._stage(".config/mainframe/accounts", b"real data")
        (self.home / ".config" / "mainframe" / "accounts").mkdir(parents=True)
        with self.assertRaisesRegex(RuntimeError, "live directory"):
            lr.activate(self.staging, self.home, self.work)

    def test_empty_staged_file_under_a_live_file_is_skipped(self):
        blocker = self.home / ".config" / "mainframe" / "accounts"
        blocker.parent.mkdir(parents=True)
        blocker.write_text("a live file, not a directory")
        self._stage(".config/mainframe/accounts/child", b"")
        result = lr.activate(self.staging, self.home, self.work)
        self.assertIn(".config/mainframe/accounts/child",
                      result["skipped_file_dir_conflicts"])
        self.assertEqual(blocker.read_text(), "a live file, not a directory")

    def test_empty_staged_file_deep_under_a_live_file_is_skipped(self):
        # the blocker is an ancestor, not the parent itself: mkdir raises
        # NotADirectoryError here, not FileExistsError.
        blocker = self.home / ".config" / "mainframe" / "accounts"
        blocker.parent.mkdir(parents=True)
        blocker.write_text("a live file, not a directory")
        self._stage(".config/mainframe/accounts/bitwarden/child", b"")
        result = lr.activate(self.staging, self.home, self.work)
        self.assertIn(".config/mainframe/accounts/bitwarden/child",
                      result["skipped_file_dir_conflicts"])
        self.assertEqual(blocker.read_text(), "a live file, not a directory")

    def test_nonempty_staged_file_under_a_live_file_fails_loudly(self):
        blocker = self.home / ".config" / "mainframe" / "accounts"
        blocker.parent.mkdir(parents=True)
        blocker.write_text("a live file, not a directory")
        self._stage(".config/mainframe/accounts/child", b"real data")
        with self.assertRaisesRegex(RuntimeError, "blocks creating"):
            lr.activate(self.staging, self.home, self.work)

    def test_normal_file_still_activates_and_backs_up(self):
        target = self.home / "plain.txt"
        target.write_text("old")
        self._stage("plain.txt", b"new")
        result = lr.activate(self.staging, self.home, self.work)
        self.assertEqual(target.read_bytes(), b"new")
        self.assertIn("plain.txt", result["activated"])
        self.assertIn("plain.txt", result["backed_up"])


if __name__ == "__main__":
    unittest.main()
