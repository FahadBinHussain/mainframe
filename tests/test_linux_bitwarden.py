import hashlib
import io
import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).parents[1]))
import bitwarden_cli_linux as bw
import linux_packages as lp


def elf_fixture() -> bytes:
    header = bytearray(64)
    header[:4] = b"\x7fELF"
    header[4:7] = bytes((2, 1, 1))
    header[16:18] = (2).to_bytes(2, "little")
    header[18:20] = (62).to_bytes(2, "little")
    header[20:24] = (1).to_bytes(4, "little")
    header[52:54] = (64).to_bytes(2, "little")
    return bytes(header) + b"synthetic"


class Response:
    def __init__(self, data):
        self._io = io.BytesIO(data); self.headers = {"Content-Length": str(len(data))}
    def read(self, n=-1): return self._io.read(n)
    def close(self): pass


@unittest.skipUnless(sys.platform.startswith("linux"), "Linux filesystem publication fixtures")
class BitwardenTests(unittest.TestCase):
    def setUp(self):
        patches = [patch.object(bw.platform, "system", return_value="Linux"),
                   patch.object(bw.platform, "machine", return_value="x86_64"),
                   patch.object(bw.platform, "libc_ver", return_value=("glibc", "2.0")),
                   patch.object(lp, "host_info", return_value=("ubuntu", "x86_64"))]
        for item in patches:
            item.start()
        self.addCleanup(lambda: [item.stop() for item in reversed(patches)])

    def release(self, payload=None):
        payload = elf_fixture() if payload is None else payload
        return {"version": "1.2.3", "url": "https://github.com/bitwarden/clients/releases/download/cli-v1.2.3/bw-oss-linux-1.2.3.zip",
                "sha256": hashlib.sha256(payload).hexdigest(), "size": str(len(payload)),
                "asset_name": "bw-oss-linux-1.2.3.zip", "manifest_source": bw.SCOOP_MANIFEST_URL,
                "release_source": bw.GITHUB_API_BASE + "cli-v1.2.3"}

    def test_version_drift_and_missing_digest_fail_closed(self):
        manifest = {"version": "2.0.0", "architecture": {"64bit": {"url": "https://github.com/bitwarden/clients/releases/download/cli-v2.0.0/bw-oss-windows-2.0.0.zip"}}}
        with patch.object(bw, "_json", side_effect=[manifest, {"tag_name": "cli-v1.2.3", "assets": []}]), self.assertRaisesRegex(RuntimeError, "tag"):
            bw.resolve_release("x86_64")
        release = {"tag_name": "cli-v2.0.0", "prerelease": False, "draft": False, "published_at": "2026-01-01T00:00:00Z",
                   "assets": [{"name": "bw-oss-linux-2.0.0.zip", "browser_download_url": "https://github.com/bitwarden/clients/releases/download/cli-v2.0.0/bw-oss-linux-2.0.0.zip", "size": 2},
                              {"name": "bw-oss-windows-2.0.0.zip", "browser_download_url": "https://github.com/bitwarden/clients/releases/download/cli-v2.0.0/bw-oss-windows-2.0.0.zip", "size": 2, "digest": "sha256:" + "a" * 64}]}
        manifest["version"] = "2.0.0"
        with patch.object(bw, "_json", side_effect=[manifest, release]), self.assertRaisesRegex(RuntimeError, "digest"):
            bw.resolve_release("x86_64")

    def test_tampered_size_or_digest_never_publishes(self):
        payload = b"payload"; root = Path(tempfile.mkdtemp()) / "new-bw"
        for change in ({"size": "999"}, {"sha256": "0" * 64}):
            release = self.release(payload); release.update(change)
            with patch.object(bw, "_open", return_value=Response(payload)), self.assertRaisesRegex(RuntimeError, "mismatch"):
                bw.install_release(release, root)
            self.assertFalse(root.exists())

    def test_unsafe_zip_is_rejected_before_destination_publish(self):
        raw = io.BytesIO()
        with zipfile.ZipFile(raw, "w") as z: z.writestr("../bw", b"bad")
        payload = raw.getvalue(); root = Path(tempfile.mkdtemp()) / "new-bw"
        release = self.release(payload)
        with patch.object(bw, "_open", return_value=Response(payload)), self.assertRaisesRegex(ValueError, "exactly one|regular"):
            bw.install_release(release, root)
        self.assertFalse(root.exists())

    def test_existing_and_symlink_roots_refused(self):
        parent = Path(tempfile.mkdtemp()); existing = parent / "existing"; existing.mkdir()
        with self.assertRaisesRegex(ValueError, "existing"):
            bw.validate_install(self.release(), existing)
        link = parent / "link"; link.symlink_to(existing, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "existing|symlink"):
            bw.validate_install(self.release(), link)

    def test_foreign_owned_ancestor_is_refused(self):
        real_fstat = os.fstat
        calls = 0

        def foreign_once(fd):
            nonlocal calls
            calls += 1
            result = real_fstat(fd)
            if calls == 2:
                values = list(result)
                values[4] = os.geteuid() + 1
                return os.stat_result(values)
            return result

        with patch.object(bw.os, "fstat", side_effect=foreign_once), self.assertRaisesRegex(ValueError, "ancestor"):
            bw.validate_install(self.release(), Path(tempfile.mkdtemp()) / "new")

    def test_success_publishes_executable_and_never_runs_it(self):
        raw = io.BytesIO()
        with zipfile.ZipFile(raw, "w") as z: z.writestr("bw", elf_fixture())
        payload = raw.getvalue(); root = Path(tempfile.mkdtemp()) / "new-bw"; release = self.release(payload)
        with patch.object(bw, "_open", return_value=Response(payload)):
            bw.install_release(release, root)
        self.assertTrue((root / "bw").is_file()); self.assertTrue(os.access(root / "bw", os.X_OK))

    def test_planner_bitwarden_requires_root_and_preflights_all_before_install(self):
        plan = lp.Plan(True, "ubuntu", "x86_64", [lp.Action("bitwarden-cli", "bitwarden-cli", archive=self.release())])
        with patch.object(lp.bitwarden_tools, "install_release") as install:
            with self.assertRaisesRegex(RuntimeError, "root"):
                lp.execute(plan, ["bitwarden-cli"])
            install.assert_not_called()
        root = Path(tempfile.mkdtemp()) / "new"
        with patch.object(lp.bitwarden_tools, "validate_install", side_effect=RuntimeError("unsafe root")), patch.object(lp.bitwarden_tools, "install_release") as install:
            with self.assertRaisesRegex(RuntimeError, "unsafe root"):
                lp.execute(plan, ["bitwarden-cli"], bitwarden_cli_root=root)
            install.assert_not_called()

    def test_dry_plan_does_not_execute(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            for name, key, value in (("scoop-allowed.json", "apps", ["bitwarden-cli"]), ("winget-allowed.json", "packages", []), ("pnpm-allowed.json", "packages", []), ("uv-allowed.json", "packages", []), ("go-allowed.json", "packages", [])):
                (root / name).write_text(json.dumps({key: value}))
            fixture = self.release();
            with patch.object(lp.bitwarden_tools, "resolve_release", return_value=fixture), patch.object(lp, "execute") as execute:
                self.assertIn(lp.main(["--repo", str(root), "--distro", "ubuntu", "--arch", "x86_64"]), (0, 3))
                execute.assert_not_called()


if __name__ == "__main__": unittest.main()
