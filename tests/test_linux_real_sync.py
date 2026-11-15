"""sync_checkout(): the linux engine heals its own checkout.

The python twin of Sync-MainframeCheckout (windows/mainframe-sync.psm1):
same algorithm, same contract. Real git in temp dirs, no network - the
"origin" is a local bare repo, so every scenario runs offline on any
machine with git on PATH. Skipped loudly when git is missing.
"""
from __future__ import annotations

import io
import shutil
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO))

from linux import linux_real as lr  # noqa: E402


def _git(cwd: Path, *args: str) -> str:
    proc = subprocess.run(["git", "-C", str(cwd), *args],
                          capture_output=True, text=True, timeout=60)
    if proc.returncode != 0:
        raise AssertionError(
            f"git {' '.join(args)} failed in {cwd}: {proc.stderr.strip()}")
    return proc.stdout


@unittest.skipIf(shutil.which("git") is None, "git not on PATH")
class SyncCheckoutTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.origin = self.root / "origin.git"
        subprocess.run(["git", "init", "--bare", "-b", "main",
                        str(self.origin)], capture_output=True, text=True,
                       timeout=60, check=True)
        self.seed = self.root / "seed"
        self._init_repo(self.seed)
        # commit 1 holds the files the tests modify (shared prefix - a
        # rewrite of the tip never drops them); commit 2 is the tip the
        # rewrite tests replace (HEAD~1 must exist for the reset).
        (self.seed / "shared.txt").write_text("line one\nline two\n",
                                              encoding="utf-8")
        (self.seed / "wip.txt").write_text("wip baseline\n", encoding="utf-8")
        _git(self.seed, "add", "shared.txt", "wip.txt")
        _git(self.seed, "commit", "-m", "seed commit")
        self._commit(self.seed, "other.txt", "other\n", "second seed commit")
        _git(self.seed, "remote", "add", "origin", str(self.origin))
        _git(self.seed, "push", "-u", "origin", "main")

    def tearDown(self):
        self._tmp.cleanup()

    def _init_repo(self, path: Path) -> None:
        path.mkdir(parents=True)
        subprocess.run(["git", "init", "-b", "main", str(path)],
                       capture_output=True, text=True, timeout=60, check=True)
        _git(path, "config", "user.email", "test@example.invalid")
        _git(path, "config", "user.name", "test")
        _git(path, "config", "commit.gpgsign", "false")

    def _commit(self, repo: Path, name: str, content: str, message: str) -> None:
        (repo / name).write_text(content, encoding="utf-8")
        _git(repo, "add", name)
        _git(repo, "commit", "-m", message)

    def _clone(self, name: str) -> Path:
        dest = self.root / name
        proc = subprocess.run(["git", "clone", "-q", str(self.origin),
                               str(dest)], capture_output=True, text=True,
                              timeout=60)
        self.assertEqual(proc.returncode, 0, f"clone failed: {proc.stderr}")
        _git(dest, "config", "user.email", "test@example.invalid")
        _git(dest, "config", "user.name", "test")
        return dest

    def _head(self, repo: Path) -> str:
        return _git(repo, "rev-parse", "HEAD").strip()

    def _sync(self, repo: Path) -> tuple[bool, str]:
        buf = io.StringIO()
        with redirect_stdout(buf):
            result = lr.sync_checkout(repo)
        return result, buf.getvalue()

    def test_ff_only(self):
        work = self._clone("work-ff")
        pusher = self._clone("pusher-ff")
        self._commit(pusher, "shared.txt", "line one\nline two\nline three\n",
                     "origin advances")
        _git(pusher, "push", "origin", "main")
        self.assertNotEqual(self._head(work), self._head(pusher))
        ok, _ = self._sync(work)
        self.assertTrue(ok)
        self.assertEqual(self._head(work), self._head(pusher))

    def test_divergent_wip_preserved(self):
        work = self._clone("work-divergent")
        pusher = self._clone("pusher-divergent")
        # uncommitted change to a tracked file (the WIP) + an untracked
        # file. wip.txt comes from the seed's first commit, so it
        # survives the reset and the stash pop applies cleanly.
        wip_modified = "wip baseline\nthird line, uncommitted\n"
        (work / "wip.txt").write_text(wip_modified, encoding="utf-8")
        untracked = "untracked, must survive\n"
        (work / "notes.txt").write_text(untracked, encoding="utf-8")
        # the origin rewrites its tip (a history rewrite, like the blob scrub).
        _git(pusher, "reset", "--hard", "HEAD~1")
        self._commit(pusher, "shared.txt", "line one rewritten\nline two\n",
                     "rewritten tip")
        _git(pusher, "push", "--force", "origin", "main")
        new_tip = self._head(pusher)
        ok, out = self._sync(work)
        self.assertTrue(ok)
        self.assertEqual(self._head(work), new_tip)
        self.assertEqual((work / "wip.txt").read_text(encoding="utf-8"),
                         wip_modified)
        self.assertEqual((work / "notes.txt").read_text(encoding="utf-8"),
                         untracked)
        self.assertIn("reset to origin/main", out)
        self.assertEqual(_git(work, "stash", "list").strip(), "")

    def test_pop_conflict_keeps_stash(self):
        work = self._clone("work-conflict")
        pusher = self._clone("pusher-conflict")
        (work / "shared.txt").write_text("MY uncommitted line one\nline two\n",
                                         encoding="utf-8")
        _git(pusher, "reset", "--hard", "HEAD~1")
        self._commit(pusher, "shared.txt",
                     "ORIGIN rewritten line one\nline two\n",
                     "rewrite touching the same lines")
        _git(pusher, "push", "--force", "origin", "main")
        ok, out = self._sync(work)
        self.assertFalse(ok)
        self.assertIn("STILL in the stash", out)
        self.assertTrue(_git(work, "stash", "list").strip())

    def test_not_a_repo(self):
        plain = self.root / "plain-dir"
        plain.mkdir()
        ok, out = self._sync(plain)
        self.assertFalse(ok)
        self.assertIn("not a git checkout", out)

    def test_no_origin(self):
        repo = self.root / "no-origin"
        self._init_repo(repo)
        self._commit(repo, "a.txt", "x", "one commit")
        ok, out = self._sync(repo)
        self.assertFalse(ok)
        self.assertIn("no origin remote", out)

    def test_no_upstream(self):
        work = self._clone("no-upstream")
        _git(work, "checkout", "-b", "orphan-branch")
        ok, out = self._sync(work)
        self.assertFalse(ok)
        self.assertIn("no upstream branch", out)


if __name__ == "__main__":
    unittest.main()
