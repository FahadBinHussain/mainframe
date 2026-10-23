"""Synthetic, offline tests for Linux-native WACLI state preservation."""
from __future__ import annotations

import fcntl
import io
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

    def test_snapshot_and_unlocked_restore_preserve_arbitrary_bytes_and_real_sqlite(self):
        inner = Path(self.tmp.name) / "snapshot.zip"
        count = ws.snapshot(self.root, inner, quiesced=True)
        self.assertEqual(count, 5)
        destination = Path(self.tmp.name) / "restored"
        report = ws.restore_unlocked(inner, destination)
        self.assertEqual(report["activation"], "not-performed")
        restored = destination / "config.yaml"
        self.assertEqual(restored.read_bytes(), (self.root / "config.yaml").read_bytes())
        self.assertEqual((destination / "media" / "odd.bin").read_bytes(),
                         (self.root / "media" / "odd.bin").read_bytes())
        with sqlite3.connect(destination / "wacli.db") as con:
            self.assertEqual(con.execute("select body from messages").fetchone()[0], b"raw \\x00\\xff")
        with ZipFile(inner) as z:
            self.assertIn(ws.PREFIX + "config.yaml", z.namelist())
            self.assertEqual(z.read(ws.PREFIX + "config.yaml"), (self.root / "config.yaml").read_bytes())

    def test_snapshot_requires_quiesced_and_explicit_absolute_root(self):
        with self.assertRaises(ValueError):
            ws.snapshot(self.root, Path(self.tmp.name) / "x.zip")
        with self.assertRaises(ValueError):
            ws.scan(Path("relative-state"))
        with self.assertRaises(ValueError):
            ws.scan(Path("/tmp") / ".." / "tmp")

    def test_snapshot_cannot_overwrite_an_existing_archive(self):
        existing = Path(self.tmp.name) / 'existing.zip'
        existing.write_bytes(b'existing synthetic backup, must not change')
        with self.assertRaises(FileExistsError):
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

    def test_sqlite_sidecars_are_blocked_even_when_quiesced(self):
        (self.root / "wacli.db-wal").write_bytes(b"WAL")
        with self.assertRaises(ValueError):
            ws.snapshot(self.root, Path(self.tmp.name) / "x.zip", quiesced=True)

    def test_held_fcntl_lock_is_blocked_without_source_mutation(self):
        handle = open(self.root / "LOCK", "rb")
        try:
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            before = {p.relative_to(self.root).as_posix(): p.read_bytes() for p in self.root.rglob("*") if p.is_file()}
            with self.assertRaises(ValueError):
                ws.snapshot(self.root, Path(self.tmp.name) / "x.zip", quiesced=True)
            self.assertEqual(before, {p.relative_to(self.root).as_posix(): p.read_bytes() for p in self.root.rglob("*") if p.is_file()})
        finally:
            fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
            handle.close()

    def test_missing_database_lock_is_blocked_without_source_mutation(self):
        (self.root / "LOCK").unlink()
        before = {p.relative_to(self.root).as_posix(): p.read_bytes() for p in self.root.rglob("*") if p.is_file()}
        with self.assertRaises(ValueError):
            ws.snapshot(self.root, Path(self.tmp.name) / "x.zip", quiesced=True)
        self.assertEqual(before, {p.relative_to(self.root).as_posix(): p.read_bytes() for p in self.root.rglob("*") if p.is_file()})

    def test_plan_is_metadata_only_and_does_not_open_payload(self):
        with patch.object(ws, "opened_file", side_effect=AssertionError("payload opened")):
            result = ws.main(["plan", "--state-root", str(self.root)])
        self.assertEqual(result, 0)

    def test_source_mutation_between_metadata_and_copy_is_detected(self):
        original = ws.opened_file
        calls = {"n": 0}
        def mutate_after_open(root, rel):
            stream = original(root, rel)
            calls["n"] += 1
            if calls["n"] == 2:
                (self.root / "config.yaml").write_bytes(b"changed after preflight")
            return stream
        with patch.object(ws, "opened_file", side_effect=mutate_after_open):
            with self.assertRaises(ValueError):
                ws.snapshot(self.root, Path(self.tmp.name) / "x.zip", quiesced=True)

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

    def test_capture_fails_closed_without_aes_provider_before_destination(self):
        destination = Path(self.tmp.name) / "no-provider"
        with patch.object(ws, "aes_zip", side_effect=ValueError("missing AES")):
            with self.assertRaises(ValueError):
                ws.capture(self.root, destination, b"password", quiesced=True)
        self.assertFalse(destination.exists())

    def test_aes_capture_includes_raw_inner_zip_and_round_trips(self):
        try:
            import pyzipper
        except ImportError:
            self.skipTest('Optional AES ZIP provider unavailable')
        destination = Path(self.tmp.name) / 'encrypted-capture'
        password = b'synthetic-fixture-only'
        result = ws.capture(self.root, destination, password, quiesced=True)
        self.assertEqual(result['status'], 'encrypted-state-preserved')
        self.assertEqual([p.name for p in destination.iterdir()], ['mainframe-secrets.zip'])
        with pyzipper.AESZipFile(destination / 'mainframe-secrets.zip') as outer:
            info = outer.infolist()[0]
            self.assertEqual(info.filename, 'tool-secrets.zip')
            self.assertTrue(info.flag_bits & 1)
            self.assertEqual(info.wz_aes_strength, 3)
            with self.assertRaises(RuntimeError):
                outer.read(info)
            outer.setpassword(b'wrong-password')
            with self.assertRaises(RuntimeError):
                outer.read(info)
            outer.setpassword(password)
            data = outer.read(info)
        with ZipFile(io.BytesIO(data)) as inner:
            for name, original in self.before.items():
                self.assertEqual(inner.read(ws.PREFIX + name), original)
        unlocked = Path(self.tmp.name) / 'tool-secrets.zip'
        unlocked.write_bytes(data)
        restored = Path(self.tmp.name) / 'round-trip'
        ws.restore_unlocked(unlocked, restored)
        for name, original in self.before.items():
            self.assertEqual((restored / name).read_bytes(), original)
            self.assertEqual((restored / name).stat().st_mode & 0o777, 0o600)
        self.assertEqual(restored.stat().st_mode & 0o777, 0o700)
        self.assertEqual(self.before, {p.relative_to(self.root).as_posix(): p.read_bytes() for p in self.root.rglob('*') if p.is_file()})

    def test_actual_uncheckpointed_wal_is_explicitly_blocked(self):
        con = sqlite3.connect(self.db)
        try:
            con.execute('pragma journal_mode=WAL')
            con.execute('pragma wal_autocheckpoint=0')
            con.execute('insert into messages(body) values (?)', (b'dummy committed WAL data',))
            con.commit()
            self.assertTrue(Path(str(self.db) + '-wal').exists())
            with self.assertRaisesRegex(ValueError, 'WAL/SHM/journal'):
                ws.snapshot(self.root, Path(self.tmp.name) / 'wal-snapshot.zip', True)
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
