"""The linux secrets mapping: decrypt the blob, then place it in a linux home.

`tool-secrets.zip` is the same 8-item manifest Windows restores, and the blob
that carries it travels inside mainframe-quick.zip. These tests drive the real
decryptor against a real 7-Zip AES-256 archive, so the format contract is pinned
rather than assumed - the WinZip AE-2 layout (salt, verifier, data, mac) and the
PBKDF2 order are exactly the parts that are easy to get subtly wrong.

The archive is built with `7z` when it is available; the tests skip loudly when
it is not, because a synthetic fixture would not prove the real writer's format.
"""
from __future__ import annotations

import json
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO))

import linux_secrets as ls  # noqa: E402

SEVEN_ZIP = shutil.which("7z") or shutil.which("7za")
PASSWORD = "unit-test-password-1!"
MANIFEST = REPO / "tool-secrets.manifest.json"

# the manifest's own layout, one file per mapped item
PAYLOAD = {
    "AppData/Roaming/mainframe/accounts/github/current.json": b'{"email":"probe@x.y"}\n',
    "UserProfile/.ssh/id_ed25519": b"PRIVATE-KEY-DATA\n",
    "UserProfile/.opencode/opencode.json": b'{"provider":"probe"}\n',
    "UserProfile/.opencode/plugins/probe.js": b"export default 1\n",
    "UserProfile/.config/opencode/opencode.jsonc": b"{/*v2*/}\n",
    "UserProfile/.wakatime.cfg": b"[settings]\napi_key=probe\n",
}


def build_blob(root: Path) -> Path:
    """A mainframe-secrets.zip exactly the way publish-backup.ps1 writes one."""
    inner = root / "tool-secrets.zip"
    with zipfile.ZipFile(inner, "w", zipfile.ZIP_DEFLATED) as archive:
        for name, data in PAYLOAD.items():
            info = zipfile.ZipInfo(name)
            info.external_attr = ((0o600 if "id_ed25519" in name else 0o644) << 16)
            archive.writestr(info, data)
    blob = root / "mainframe-secrets.zip"
    completed = subprocess.run(
        [SEVEN_ZIP, "a", "-tzip", "-mem=AES256", f"-p{PASSWORD}", "-mx5",
         "-bso0", "-bsp0", "-y", str(blob), inner.name],
        cwd=str(root), capture_output=True, text=True)
    if completed.returncode != 0:
        raise AssertionError(f"7z could not build the fixture: {completed.stderr[:300]}")
    return blob


@unittest.skipUnless(SEVEN_ZIP, "7z is required to build a real AES-256 archive")
class SecretsDecryptTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.blob = build_blob(self.root)

    def tearDown(self):
        self._tmp.cleanup()

    def test_decrypts_a_real_seven_zip_aes256_archive(self):
        members = ls.read_zip(self.blob, PASSWORD)
        self.assertIn("tool-secrets.zip", members)
        inner = members["tool-secrets.zip"]["data"]
        nested = self.root / "inner.zip"
        nested.write_bytes(inner)
        inner_members = ls.read_zip(nested, PASSWORD)
        self.assertEqual(sorted(inner_members), sorted(PAYLOAD))
        for name, expected in PAYLOAD.items():
            self.assertEqual(inner_members[name]["data"], expected, name)

    def test_a_wrong_password_fails_loudly_and_names_the_cause(self):
        with self.assertRaisesRegex(ls.SecretsError, "password is wrong"):
            ls.read_zip(self.blob, "definitely-not-the-password")

    def test_a_two_line_notes_value_decrypts_on_the_second_line(self):
        # the real vault layout: the `[secrets archive password]` header on
        # line 1, the password on line 2. vault-flow hands over the notes
        # verbatim, so read_zip must try each line against the verifier.
        notes = "[secrets archive password]\n" + PASSWORD
        members = ls.read_zip(self.blob, notes)
        self.assertIn("tool-secrets.zip", members)

    def test_the_password_line_wins_wherever_it_sits(self):
        members = ls.read_zip(self.blob, PASSWORD + "\n[secrets archive password]")
        self.assertIn("tool-secrets.zip", members)

    def test_crlf_notes_and_blank_lines_are_ignored(self):
        notes = "[secrets archive password]\r\n\r\n" + PASSWORD + "\r\n"
        members = ls.read_zip(self.blob, notes)
        self.assertIn("tool-secrets.zip", members)

    def test_all_lines_wrong_names_how_many_lines_were_tried(self):
        with self.assertRaisesRegex(ls.SecretsError, "tried 2 password lines"):
            ls.read_zip(self.blob, "nope-one\nnope-two")

    def test_a_mac_failure_never_retries_the_next_line(self):
        # a MAC failure after a verifier match means the password was right
        # and the data is corrupt - retrying the next line would mask that.
        # flip one byte in the body (after salt+verifier, before the MAC),
        # which keeps the verifier intact and breaks the authentication code.
        raw = bytearray(self.blob.read_bytes())
        eocd = bytes(raw).rfind(ls.SIG_EOCD)
        cd_offset = int.from_bytes(raw[eocd + 16:eocd + 20], "little")
        raw[cd_offset - 20] ^= 0xFF
        broken = self.root / "mac-broken.zip"
        broken.write_bytes(bytes(raw))
        with self.assertRaisesRegex(ls.SecretsError, "authentication code"):
            ls.read_zip(broken, PASSWORD + "\nwrong-line")

    def test_a_truncated_archive_is_refused(self):
        broken = self.root / "broken.zip"
        broken.write_bytes(self.blob.read_bytes()[:120])
        with self.assertRaisesRegex(ls.SecretsError, "not a zip|too short|truncated"):
            ls.read_zip(broken, PASSWORD)


class ManifestTests(unittest.TestCase):
    def test_the_real_manifest_parses_with_its_enabled_items(self):
        items = ls.load_manifest(MANIFEST)
        names = {item["name"] for item in items}
        # the two disabled entries must not come back
        self.assertNotIn("opencode sessions, message storage and session diffs", names)
        self.assertNotIn("wakatime desktop app config and monitored apps", names)
        self.assertIn("tailscale fleet ssh key", names)

    def test_every_enabled_item_resolves_to_a_linux_target(self):
        home = Path("/home/probe")
        plan = ls.plan_items(ls.load_manifest(MANIFEST), home=home, environment={})
        mapped = {row["archivePath"]: row["target"] for row in plan
                  if row["status"] == "mapped"}
        self.assertEqual(mapped["UserProfile/.ssh"], ".ssh")
        self.assertEqual(mapped["UserProfile/.opencode/opencode.json"],
                         ".opencode/opencode.json")
        self.assertEqual(mapped["UserProfile/.config/opencode"], ".config/opencode")
        self.assertEqual(mapped["UserProfile/.wakatime.cfg"], ".wakatime.cfg")
        self.assertEqual(mapped["AppData/Roaming/mainframe/accounts"],
                         ".config/mainframe/accounts")
        self.assertFalse([row for row in plan if row["status"] == "blocked"])

    def test_xdg_config_home_moves_the_profile_root_with_it(self):
        plan = ls.plan_items(ls.load_manifest(MANIFEST), home=Path("/home/probe"),
                             environment={"XDG_CONFIG_HOME": "/home/probe/xdg"})
        mapped = {row["archivePath"]: row["target"] for row in plan
                  if row["status"] == "mapped"}
        self.assertEqual(mapped["AppData/Roaming/mainframe/accounts"],
                         "xdg/mainframe/accounts")

    def test_xdg_config_home_outside_home_is_refused_not_ignored(self):
        # activation copies staging INTO the live home, so a root elsewhere
        # could not be honoured - and the profiles would land where no helper
        # looks. that is a loud refusal, never a silent misplacement.
        with self.assertRaisesRegex(ls.SecretsError, "outside the live home"):
            ls.plan_items(ls.load_manifest(MANIFEST), home=Path("/home/probe"),
                          environment={"XDG_CONFIG_HOME": "/elsewhere/config"})

    def test_an_unmapped_archive_path_is_reported_never_guessed(self):
        plan = ls.plan_items([{"name": "probe", "archivePath": "Windows/System32"}],
                             home=Path("/home/probe"), environment={})
        self.assertEqual(plan[0]["status"], "blocked")
        self.assertIn("no reviewed linux destination", plan[0]["reason"])

    def test_traversal_in_an_archive_path_is_refused(self):
        for value in ("../escape", "UserProfile/../../escape", ""):
            with self.subTest(value=value), self.assertRaises(ls.SecretsError):
                ls.safe_archive_path(value)


@unittest.skipUnless(SEVEN_ZIP, "7z is required to build a real AES-256 archive")
class SecretsStagingTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.blob = build_blob(self.root)

    def tearDown(self):
        self._tmp.cleanup()

    def test_stages_every_mapped_member_byte_for_byte(self):
        # a real linux home path shape: the target is derived from $HOME, and
        # `environment={}` keeps XDG_CONFIG_HOME out of the picture
        home = self.root / "home"
        home.mkdir()
        report = ls.stage_secrets(self.blob, MANIFEST, PASSWORD,
                                  self.root / "staging",
                                  home=home, environment={})
        self.assertEqual(report["blocked"], [])
        # `missing` is about the manifest, not the fixture: the real manifest
        # carries items whose files this synthetic archive does not contain
        # (e.g. antigravity's ~/.gemini/config), and naming them is correct.
        named_missing = {row["archivePath"] for row in report["missing"]}
        self.assertNotIn("UserProfile/.ssh", named_missing)
        self.assertNotIn("UserProfile/.wakatime.cfg", named_missing)
        tree = self.root / "staging" / "secrets-staging"
        staged = {row["target"].replace("\\", "/"): row["from"]
                  for row in report["staged"]}
        self.assertEqual(staged[".ssh/id_ed25519"], "UserProfile/.ssh/id_ed25519")
        self.assertEqual(staged[".wakatime.cfg"], "UserProfile/.wakatime.cfg")
        for from_name, target in ((v, k) for k, v in staged.items()):
            self.assertEqual((tree / target).read_bytes(), PAYLOAD[from_name],
                             f"{target} must match {from_name}")

    def test_private_material_never_lands_world_readable(self):
        # an ssh private key with mode 644 is REFUSED by openssh, and a config
        # holding an api key has no business being group/world readable either.
        # the mode is asserted from the report, not the disk: windows rejects
        # chmod beyond the read-only bit, so an on-disk check there would
        # measure the platform instead of this code.
        home = self.root / "home"
        home.mkdir()
        report = ls.stage_secrets(self.blob, MANIFEST, PASSWORD,
                                  self.root / "staging",
                                  home=home, environment={})
        modes = {row["target"].replace("\\", "/"): row["mode"]
                 for row in report["staged"]}
        # the archive records 0600 for the key; the reader must carry it through
        self.assertEqual(modes[".ssh/id_ed25519"], "600")
        # and nothing a secret carries may be group/world readable
        for target, mode in modes.items():
            self.assertIn(mode, {"600", "700"}, f"{target} landed as {mode}")

    def test_an_empty_password_is_refused_before_any_work(self):
        with self.assertRaisesRegex(ls.SecretsError, "password is empty"):
            ls.stage_secrets(self.blob, MANIFEST, "", self.root / "staging",
                             home=self.root, environment={})

    def test_a_missing_archive_is_named(self):
        with self.assertRaisesRegex(ls.SecretsError, "missing"):
            ls.stage_secrets(self.root / "nope.zip", MANIFEST, PASSWORD,
                             self.root / "staging", home=self.root, environment={})

    def test_stages_with_a_two_line_notes_password(self):
        # the whole leg, not just read_zip: the notes value as vault-flow
        # hands it over must stage the same files as the bare password.
        home = self.root / "home"
        home.mkdir()
        notes = "[secrets archive password]\n" + PASSWORD
        report = ls.stage_secrets(self.blob, MANIFEST, notes,
                                  self.root / "staging",
                                  home=home, environment={})
        self.assertEqual(report["blocked"], [])
        staged = {row["target"].replace("\\", "/")
                  for row in report["staged"]}
        self.assertIn(".ssh/id_ed25519", staged)
        self.assertIn(".wakatime.cfg", staged)


class QuickBlobTests(unittest.TestCase):
    def test_the_blob_is_extracted_from_quick_byte_for_byte(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            blob = root / "mainframe-secrets.zip"
            blob.write_bytes(b"PRETEND-CIPHERTEXT")
            quick = root / "mainframe-quick.zip"
            with zipfile.ZipFile(quick, "w") as archive:
                archive.write(blob, "mainframe-secrets.zip")
                archive.writestr("AGENTS.md", b"# rules\n")
            out = ls.extract_secrets_blob(quick, root / "out" / "blob.zip")
            self.assertEqual(out.read_bytes(), blob.read_bytes())

    def test_a_quick_archive_without_the_blob_says_the_release_cannot_restore(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            quick = root / "mainframe-quick.zip"
            with zipfile.ZipFile(quick, "w") as archive:
                archive.writestr("AGENTS.md", b"# rules\n")
            with self.assertRaisesRegex(ls.SecretsError, "carries no mainframe-secrets"):
                ls.extract_secrets_blob(quick, root / "out.zip")


if __name__ == "__main__":
    unittest.main()
