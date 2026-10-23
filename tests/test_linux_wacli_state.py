"""Synthetic, offline tests for Linux-native WACLI state preservation."""
from __future__ import annotations

import io
import json
import os
from pathlib import Path
import sqlite3
import stat
import sys
import tempfile
import unittest
from unittest.mock import patch
from zipfile import ZIP_DEFLATED, ZipFile, ZipInfo

sys.path.insert(0, str(Path(__file__).parents[1]))
import wacli_state as ws
import linux_restore as lr


class WacliStateTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="wacli-state-test-")
        self.root = Path(self.tmp.name) / "state"
        self.root.mkdir()
        (self.root / "config.yaml").write_bytes(b"\\x00\\xffconfig\\x80\\x00")
        (self.root / "media").mkdir()
        (self.root / "media" / "odd.bin").write_bytes(bytes(range(256)) * 3)
        (self.root / "LOCK").write_bytes(b"held by the store, but not a secret")
        self.db = self.root / "wacli.db"
        with sqlite3.connect(self.db) as con:
            con.execute("create table messages (id integer primary key, body blob)")
            con.execute("insert into messages(body) values (?)", (b"raw \\x00\\xff",))
            con.commit()
        self.before = {p.relative_to(self.root).as_posix(): p.read_bytes()
                       for p in self.root.rglob("*") if p.is_file()}

    def tearDown(self):
        self.tmp.cleanup()

    def _plain_archive(self, members, name="input.zip"):
        archive = Path(self.tmp.name) / name
        with ZipFile(archive, "w", ZIP_DEFLATED) as z:
            for member, data in members:
                if member.endswith("/"):
                    z.writestr(member, b"")
                else:
                    z.writestr(member, data)
        return archive

    def test_fixture_archive_and_unlocked_restore_preserve_arbitrary_bytes_and_sqlite(self):
        # Construct an offline test archive directly, never via disabled capture.
        inner = self._plain_archive([(ws.PREFIX + name, data)
                                     for name, data in self.before.items()])
        destination = Path(self.tmp.name) / "restored"
        report = ws.restore_unlocked(inner, destination)
        self.assertEqual(report["activation"], "not-performed")
        self.assertEqual(self.before, {p.relative_to(self.root).as_posix(): p.read_bytes()
                                      for p in self.root.rglob("*") if p.is_file()})
        for name, data in self.before.items():
            self.assertEqual((destination / name).read_bytes(), data)
            self.assertEqual((destination / name).stat().st_mode & 0o777, 0o600)
        self.assertEqual(destination.stat().st_mode & 0o777, 0o700)
        with sqlite3.connect(destination / "wacli.db") as con:
            self.assertEqual(con.execute("select body from messages").fetchone()[0], b"raw \\x00\\xff")

    def test_scan_requires_explicit_absolute_root(self):
        with self.assertRaises(ValueError):
            ws.scan(Path("relative-state"))
        with self.assertRaises(ValueError):
            ws.scan(Path("/tmp") / ".." / "tmp")

    def test_snapshot_refuses_even_when_quiesced_without_any_io(self):
        for quiesced in (False, True):
            with self.subTest(quiesced=quiesced), \
                    patch.object(ws, "absolute_path", side_effect=AssertionError("path inspected")), \
                    patch.object(ws, "scan", side_effect=AssertionError("source scanned")), \
                    patch.object(ws, "opened_file", side_effect=AssertionError("payload read")), \
                    patch.object(ws, "ZipFile", side_effect=AssertionError("archive opened")):
                with self.assertRaisesRegex(ws.StateError, "boundary unavailable"):
                    ws.snapshot(object(), object(), quiesced=quiesced)

    def test_disabled_snapshot_does_not_touch_existing_archive(self):
        existing = Path(self.tmp.name) / 'existing.zip'
        existing.write_bytes(b'existing synthetic backup, must not change')
        with self.assertRaisesRegex(ws.StateError, "boundary unavailable"):
            ws.snapshot(self.root, existing, True)
        self.assertEqual(existing.read_bytes(), b'existing synthetic backup, must not change')

    def test_existing_destination_is_untouched_and_capture_rejects_it(self):
        destination = Path(self.tmp.name) / "existing"
        destination.mkdir()
        sentinel = destination / "sentinel"
        sentinel.write_bytes(b"do not overwrite")
        with self.assertRaises(ValueError):
            ws.destination_parent(destination, self.root)
        self.assertEqual(sentinel.read_bytes(), b"do not overwrite")
        self.assertEqual(list(destination.iterdir()), [sentinel])

    def test_default_live_home_and_source_overlap_are_not_implicit_targets(self):
        with patch.object(Path, "home", return_value=Path(self.tmp.name) / "home"):
            home = Path(self.tmp.name) / "home"
            (home / ".wacli").mkdir(parents=True)
            with self.assertRaises(ValueError):
                ws.destination_parent(home / ".wacli", self.root)
            with self.assertRaises(ValueError):
                ws.destination_parent(self.root / "new", self.root)

    def test_links_and_special_files_are_blocked(self):
        (self.root / "symlink").symlink_to(self.root / "config.yaml")
        with self.assertRaises(ValueError):
            ws.scan(self.root)
        (self.root / "symlink").unlink()
        os.mkfifo(self.root / "pipe")
        with self.assertRaises(ValueError):
            ws.scan(self.root)

        (self.root / "pipe").unlink()
        os.link(self.root / "config.yaml", self.root / "hardlink")
        with self.assertRaises(ValueError):
            ws.scan(self.root)

    def test_plan_is_metadata_only_and_does_not_open_payload(self):
        with patch.object(ws, "opened_file", side_effect=AssertionError("payload opened")):
            result = ws.main(["plan", "--state-root", str(self.root)])
        self.assertEqual(result, 0)

    def test_restore_rejects_traversal_collisions_specials_and_encrypted_duplicates(self):
        bad = [
            [(ws.PREFIX + "../escape", b"x")],
            [(ws.PREFIX + "A", b"x"), (ws.PREFIX + "a", b"y")],
            [(ws.PREFIX + "node", b"x"), (ws.PREFIX + "node/child", b"y")],
        ]
        for index, members in enumerate(bad):
            with self.subTest(index=index):
                archive = self._plain_archive(members, "bad-%d.zip" % index)
                with self.assertRaises(ValueError):
                    ws.restore_unlocked(archive, Path(self.tmp.name) / ("out-%d" % index))

        special = Path(self.tmp.name) / "special.zip"
        with ZipFile(special, "w") as z:
            info = ZipInfo(ws.PREFIX + "fifo")
            info.create_system = 3
            info.external_attr = (stat.S_IFIFO | 0o600) << 16
            z.writestr(info, b"x")
        with self.assertRaises(ValueError):
            ws.restore_unlocked(special, Path(self.tmp.name) / "special-out")

        try:
            import pyzipper
        except ImportError:
            return
        encrypted = Path(self.tmp.name) / "encrypted.zip"
        with pyzipper.AESZipFile(encrypted, "w", encryption=pyzipper.WZ_AES) as z:
            z.setpassword(b"test")
            z.setencryption(pyzipper.WZ_AES, nbits=256)
            z.writestr(ws.PREFIX + "secret", b"opaque")
        with self.assertRaises(ValueError):
            ws.restore_unlocked(encrypted, Path(self.tmp.name) / "encrypted-out")

    def test_restore_accepts_conventional_root_directory_marker(self):
        archive = self._plain_archive([(ws.PREFIX, b''), (ws.PREFIX + 'config.yaml', b'dummy bytes')], 'root-dir.zip')
        destination = Path(self.tmp.name) / 'root-dir-export'
        ws.restore_unlocked(archive, destination)
        self.assertEqual((destination / 'config.yaml').read_bytes(), b'dummy bytes')

    def test_root_marker_does_not_hide_special_or_unsafe_entries(self):
        archive = Path(self.tmp.name) / 'special-root.zip'
        with ZipFile(archive, 'w') as z:
            info = ZipInfo(ws.PREFIX)
            info.create_system = 3
            info.external_attr = (stat.S_IFLNK | 0o700) << 16
            z.writestr(info, b'dummy')
            z.writestr(ws.PREFIX + 'config.yaml', b'unchanged')
        with self.assertRaises(ValueError):
            ws.restore_unlocked(archive, Path(self.tmp.name) / 'special-root-out')

    def test_windows_account_only_archive_is_not_remapped(self):
        archive = self._plain_archive([("AppData/account.sqlite", b"windows")])
        with self.assertRaises(ValueError):
            ws.restore_unlocked(archive, Path(self.tmp.name) / "windows-out")

    def test_generic_linux_recovery_keeps_encrypted_envelope_opaque(self):
        backup = Path(self.tmp.name) / "backup"
        backup.mkdir()
        envelope = b"synthetic encrypted envelope, never decrypted"
        with ZipFile(backup / "mainframe-quick.zip", "w") as z:
            z.writestr("mainframe-secrets.zip", envelope)
        destination = Path(self.tmp.name) / "offline-recovery"
        report = lr.copy_recovery(backup, destination, mode="quick")
        self.assertEqual((destination / "recovered/mainframe-quick.zip/mainframe-secrets.zip").read_bytes(), envelope)
        self.assertFalse((destination / "home-staging").exists())
        self.assertEqual(report['entries'][0]['category'], 'opaque-archive')

    def test_capture_refuses_before_paths_password_providers_or_publication(self):
        for quiesced in (False, True):
            with self.subTest(quiesced=quiesced), \
                    patch.object(ws, 'absolute_path', side_effect=AssertionError('path inspected')), \
                    patch.object(ws, 'aes_zip', side_effect=AssertionError('provider loaded')), \
                    patch.object(ws, 'snapshot', side_effect=AssertionError('snapshot called')), \
                    patch.object(ws, 'publish_tree', side_effect=AssertionError('published')):
                with self.assertRaisesRegex(ws.StateError, 'boundary unavailable'):
                    ws.capture(object(), object(), object(), quiesced=quiesced)

    def test_capture_cli_attestation_is_only_legacy_syntax(self):
        for attestation in ([], ['--quiesced']):
            with self.subTest(attestation=attestation), \
                    patch.object(ws, 'capture', side_effect=AssertionError('capture called')), \
                    patch.object(ws, 'scan', side_effect=AssertionError('source inspected')), \
                    patch.object(ws, 'aes_zip', side_effect=AssertionError('provider loaded')), \
                    patch('getpass.getpass', side_effect=AssertionError('password requested')), \
                    patch('sys.stdout', new=io.StringIO()) as output:
                result = ws.main(['capture', '--state-root', '/nonexistent/synthetic-state',
                                  '--destination', '/nonexistent/synthetic-output'] + attestation)
                self.assertEqual(result, 3)
                report = json.loads(output.getvalue())
                for key in ('capture_enabled', 'publishable', 'complete', 'source_read'):
                    self.assertIs(report[key], False)

    def test_actual_uncheckpointed_wal_is_explicitly_blocked(self):
        con = sqlite3.connect(self.db)
        try:
            con.execute('pragma journal_mode=WAL')
            con.execute('pragma wal_autocheckpoint=0')
            con.execute('insert into messages(body) values (?)', (b'dummy committed WAL data',))
            con.commit()
            self.assertTrue(Path(str(self.db) + '-wal').exists())
            with self.assertRaisesRegex(ValueError, 'WAL/SHM/journal'):
                ws.scan(self.root)
        finally:
            con.close()

    def test_all_sidecar_types_block_without_deleting_them(self):
        for suffix in ws.SIDECARS:
            with self.subTest(suffix=suffix):
                sidecar = self.root / ('wacli.db' + suffix)
                sidecar.write_bytes(b'dummy')
                with self.assertRaises(ValueError):
                    ws.scan(self.root)
                self.assertEqual(sidecar.read_bytes(), b'dummy')
                sidecar.unlink()

    def test_native_members_are_never_automatically_staged(self):
        category, reason, target = lr.classify(ws.PREFIX + 'config.yaml')
        self.assertEqual(category, 'blocked')
        self.assertIsNone(target)

    def test_cli_has_no_implicit_root_or_restore_destination(self):
        for argv in (['plan'], ['capture'], ['restore-unlocked']):
            with self.subTest(argv=argv), patch('sys.stderr', new=io.StringIO()):
                with self.assertRaises(SystemExit):
                    ws.main(argv)


if __name__ == "__main__":
    unittest.main()
