"""Synthetic feasibility evidence, NOT a Windows capture implementation.

Only TemporaryDirectory databases are opened. The Windows guard is exercised by
AST extraction, never by executing a backup program. No payload is printed.
"""
from contextlib import closing
import hashlib
import io
import json
import sqlite3
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from zipfile import ZipFile

import test_wacli_windows_contract as windows_contract
import wacli_state as ws


class SQLiteSnapshotEvidence(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='wacli-synthetic-snapshot-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def fixture(self, name='wacli.db'):
        path = self.root / name
        con = sqlite3.connect(path)
        self.addCleanup(con.close)
        con.execute('CREATE TABLE records (id INTEGER PRIMARY KEY, payload BLOB)')
        con.execute('CREATE TABLE schema_migrations (version INTEGER PRIMARY KEY)')
        con.execute('INSERT INTO schema_migrations VALUES (24)')
        con.execute('PRAGMA user_version=17')
        con.commit()
        self.assertEqual(con.execute('PRAGMA journal_mode=WAL').fetchone()[0], 'wal')
        con.execute('PRAGMA wal_autocheckpoint=0')
        # Make incremental backup span many pages, with every row committed in WAL.
        con.executemany('INSERT INTO records VALUES (?, ?)',
                        ((i, bytes([i % 256]) * 2048) for i in range(96)))
        con.commit()
        self.assertGreater(path.with_name(path.name + '-wal').stat().st_size, 0)
        return path, con

    def readonly(self, path):
        # as_uri escapes '?' / '#' / '%' instead of interpreting them as options.
        return sqlite3.connect(path.as_uri() + '?mode=ro', uri=True)

    @staticmethod
    def ledger(con):
        return [(row[0], hashlib.sha256(row[1]).digest())
                for row in con.execute('SELECT id, payload FROM records ORDER BY id')]

    def test_base_file_copy_silently_loses_committed_wal_rows(self):
        source, writer = self.fixture()
        copied = self.root / 'unsafe-base-only.db'
        copied.write_bytes(source.read_bytes())
        with closing(self.readonly(copied)) as con:
            self.assertEqual(con.execute('PRAGMA integrity_check').fetchone()[0], 'ok')
            self.assertEqual(con.execute('SELECT count(*) FROM records').fetchone()[0], 0)
        self.assertEqual(len(self.ledger(writer)), 96)
        # An integrity check is not a completeness check.

    def test_online_backup_includes_every_committed_wal_row_and_schema(self):
        source, writer = self.fixture('escaped ?#% name.db')
        expected = self.ledger(writer)
        with closing(self.readonly(source)) as reader, closing(sqlite3.connect(self.root / 'snapshot.db')) as target:
            reader.backup(target, pages=1)
            self.assertEqual(self.ledger(target), expected)
            self.assertEqual(target.execute('PRAGMA integrity_check').fetchone()[0], 'ok')
            self.assertEqual(target.execute('PRAGMA user_version').fetchone()[0], 17)
            self.assertEqual(target.execute('SELECT version FROM schema_migrations').fetchall(), [(24,)])
            self.assertEqual(target.execute("SELECT type,name,tbl_name,sql FROM sqlite_schema ORDER BY name").fetchall(),
                             reader.execute("SELECT type,name,tbl_name,sql FROM sqlite_schema ORDER BY name").fetchall())
        self.assertGreater(source.with_name(source.name + '-wal').stat().st_size, 0)

    def test_mutation_during_incremental_backup_keeps_all_committed_rows(self):
        source, writer = self.fixture()
        mutated = False
        def progress(status, remaining, total):
            nonlocal mutated
            if not mutated and remaining > 0:
                writer.execute('INSERT INTO records VALUES (?, ?)', (1000, b'synthetic-new-row'))
                writer.commit()
                mutated = True
        with closing(self.readonly(source)) as reader, closing(sqlite3.connect(self.root / 'snapshot.db')) as target:
            reader.backup(target, pages=1, progress=progress)
            self.assertTrue(mutated)
            self.assertEqual(self.ledger(target), self.ledger(writer))
        # A controlled, finite writer is not proof of bounded completion under load.

    def test_two_valid_backups_can_represent_no_common_source_instant(self):
        first, a = self.fixture('first.db')
        second, b = self.fixture('second.db')
        for con in (a, b):
            con.execute('CREATE TABLE epoch (value INTEGER)')
            con.execute('INSERT INTO epoch VALUES (0)')
            con.commit()
        with closing(self.readonly(first)) as ra, closing(sqlite3.connect(self.root / 'first-copy.db')) as ca, \
                closing(self.readonly(second)) as rb, closing(sqlite3.connect(self.root / 'second-copy.db')) as cb:
            ra.backup(ca)
            # Source pairs over time: (0,0), (1,0), (1,1). Never (0,1).
            a.execute('UPDATE epoch SET value=1')
            a.commit()
            b.execute('UPDATE epoch SET value=1')
            b.commit()
            rb.backup(cb)
            self.assertEqual(ca.execute('SELECT value FROM epoch').fetchone()[0], 0)
            self.assertEqual(cb.execute('SELECT value FROM epoch').fetchone()[0], 1)
            for con in (ca, cb):
                self.assertEqual(con.execute('PRAGMA integrity_check').fetchone()[0], 'ok')

    def test_schema_numbers_do_not_identify_producing_binary(self):
        source, writer = self.fixture()
        with closing(self.readonly(source)) as reader, closing(sqlite3.connect(self.root / 'snapshot.db')) as target:
            reader.backup(target)
            self.assertEqual(target.execute('PRAGMA user_version').fetchone()[0], 17)
            names = {row[0] for row in target.execute("SELECT name FROM sqlite_schema")}
            self.assertNotIn('producer_build', names)
        # Neither a target install pin nor user_version supplies missing provenance.

    def test_wal_derived_bytes_and_metadata_roundtrip_existing_aes_envelope(self):
        try:
            import pyzipper
        except ImportError:
            self.skipTest('Optional AES ZIP provider unavailable; not an encryption pass')
        source, writer = self.fixture()
        staged = self.root / 'offline-synthetic-stage'
        staged.mkdir()
        (staged / 'LOCK').touch()
        metadata = {'fixture_version': 1, 'producer': 'synthetic-only',
                    'schema_migrations': [24], 'user_version': 17}
        (staged / 'fixture-metadata.json').write_text(json.dumps(metadata))
        snapshot = staged / 'wacli.db'
        with closing(self.readonly(source)) as reader, closing(sqlite3.connect(snapshot)) as target:
            reader.backup(target)
        before = {p.name: p.read_bytes() for p in staged.iterdir()}
        destination = self.root / 'encrypted-output'
        password = b'synthetic-test-password'
        ws.capture(staged, destination, password, quiesced=True)
        encrypted = destination / 'mainframe-secrets.zip'
        with pyzipper.AESZipFile(encrypted) as outer:
            member, = outer.infolist()
            self.assertEqual(member.filename, 'tool-secrets.zip')
            self.assertTrue(member.flag_bits & 1)
            self.assertEqual(member.wz_aes_strength, 3)
            outer.setpassword(b'wrong-synthetic-password')
            with self.assertRaises(RuntimeError):
                outer.read(member)
            outer.setpassword(password)
            inner_bytes = outer.read(member)
        with ZipFile(io.BytesIO(inner_bytes)) as inner:
            recovered = {Path(n).name: inner.read(n) for n in inner.namelist()}
        self.assertEqual(set(recovered), set(before))
        for name in before:
            # Hash assertions avoid dumping even synthetic DB/metadata values.
            self.assertEqual(hashlib.sha256(recovered[name]).digest(),
                             hashlib.sha256(before[name]).digest())
        restored = self.root / 'restored-snapshot.db'
        restored.write_bytes(recovered['wacli.db'])
        with closing(self.readonly(restored)) as con:
            self.assertEqual(self.ledger(con), self.ledger(writer))
        # Authentication corruption: flip the last HMAC byte of the AES member.
        damaged = bytearray(encrypted.read_bytes())
        with ZipFile(encrypted) as index:
            entry, = index.infolist()
            offset = entry.header_offset
            name_len = int.from_bytes(damaged[offset + 26:offset + 28], 'little')
            extra_len = int.from_bytes(damaged[offset + 28:offset + 30], 'little')
            data_start = offset + 30 + name_len + extra_len
            damaged[data_start + entry.compress_size - 1] ^= 1
        with pyzipper.AESZipFile(io.BytesIO(damaged)) as outer:
            outer.setpassword(password)
            with self.assertRaises(pyzipper.BadZipFile):
                outer.read('tool-secrets.zip')
        # This exercises the existing Linux clean-stage envelope, not a Windows
        # capture integration or coordinated raw-WAL preservation protocol.

    def test_missing_and_malformed_paths_are_not_created_by_readonly_open(self):
        missing = self.root / 'missing.db'
        with self.assertRaises(sqlite3.OperationalError):
            self.readonly(missing)
        self.assertFalse(missing.exists())
        with self.assertRaises(ValueError):
            sqlite3.connect(str(self.root / 'bad\x00.db'))

    def test_unreadable_database_and_wal_fail_instead_of_immutable_retry(self):
        if __import__('os').geteuid() == 0:
            self.skipTest('Real permission denial requires an unprivileged POSIX test runner')
        source, writer = self.fixture()
        for path in (source, source.with_name(source.name + '-wal')):
            with self.subTest(kind='database' if path == source else 'wal'):
                mode = path.stat().st_mode
                path.chmod(0)
                try:
                    with self.assertRaises(sqlite3.DatabaseError):
                        with closing(self.readonly(source)) as con:
                            con.execute('SELECT count(*) FROM records').fetchone()
                finally:
                    path.chmod(mode)

    def test_missing_encryption_provider_fails_before_state_read_or_output(self):
        destination = self.root / 'must-not-exist'
        with patch.dict('sys.modules', {'pyzipper': None}), \
                patch.object(ws, 'snapshot', side_effect=AssertionError('state read')):
            with self.assertRaisesRegex(ws.StateError, 'no plaintext fallback'):
                ws.capture(self.root / 'not-opened', destination, b'synthetic-password', True)
        self.assertFalse(destination.exists())


class WindowsCaptureStillBlocked(unittest.TestCase):
    def test_missing_powershell_skips_before_subprocess(self):
        """A missing optional shell must skip, not fail or spawn a process."""
        harness = windows_contract.WindowsWacliContractTests()
        with patch.object(windows_contract.shutil, 'which', return_value=None), \
                patch.object(windows_contract.subprocess, 'run', side_effect=AssertionError('spawned')):
            with self.assertRaises(unittest.SkipTest):
                harness.run_function(windows_contract.ROOT / 'backup.ps1',
                                     'Assert-WindowsWhatsappCaptureSafe', '')

    def test_real_uncheckpointed_wal_is_blocked_even_with_version_metadata(self):
        harness = windows_contract.WindowsWacliContractTests()
        with tempfile.TemporaryDirectory(prefix='wacli-windows-synthetic-') as td:
            root = Path(td) / 'whatsapp'
            store = root / 'synthetic-profile' / 'store'
            store.mkdir(parents=True)
            (root / 'synthetic-profile' / 'mainframe-whatsapp.json').write_text(
                '{"kind":"wacli","version":"v0.15.0","whatsmeow":"synthetic"}')
            with closing(sqlite3.connect(store / 'wacli.db')) as con:
                con.execute('PRAGMA journal_mode=WAL')
                con.execute('PRAGMA wal_autocheckpoint=0')
                con.execute('CREATE TABLE committed (id INTEGER)')
                con.execute('INSERT INTO committed VALUES (1)')
                con.commit()
                wal = store / 'wacli.db-wal'
                before = wal.read_bytes()
                for script in (windows_contract.ROOT / 'backup.ps1', windows_contract.ROOT / 'backup-secrets.ps1'):
                    passed, output = harness.invoke_guard(script, root)
                    self.assertFalse(passed)
                    self.assertIn('consistent snapshot', output)
                    self.assertEqual(wal.read_bytes(), before)

    def test_permission_enumeration_error_propagates_without_success(self):
        harness = windows_contract.WindowsWacliContractTests()
        with tempfile.TemporaryDirectory(prefix='wacli-enumeration-synthetic-') as td:
            root = Path(td) / 'whatsapp'
            root.mkdir()
            for script in (windows_contract.ROOT / 'backup.ps1', windows_contract.ROOT / 'backup-secrets.ps1'):
                body = ("$ErrorActionPreference = 'Continue'; "
                        "function Get-ChildItem { [CmdletBinding()] param([string]$LiteralPath, "
                        "[switch]$File, [switch]$Directory, [switch]$Recurse, [switch]$Force) "
                        "Write-Error 'synthetic permission denial' }; "
                        "try { Assert-WindowsWhatsappCaptureSafe -Source " + harness.ps_quote(str(root)) +
                        "; 'UNEXPECTED_SUCCESS' } catch { 'EXPECTED_FAILURE' }; "
                        # Only mutate the extracted in-memory function as a negative
                        # control. Repository scripts are never changed or invoked.
                        "$weakened = (Get-Item Function:Assert-WindowsWhatsappCaptureSafe).ScriptBlock.ToString() "
                        "-replace '-ErrorAction Stop', '-ErrorAction Continue'; "
                        "Set-Item Function:Assert-WindowsWhatsappCaptureSafe ([scriptblock]::Create($weakened)); "
                        "try { Assert-WindowsWhatsappCaptureSafe -Source " + harness.ps_quote(str(root)) +
                        "; 'CONTROL_CONTINUED' } catch { 'CONTROL_FAILED' }")
                output = harness.run_function(script, 'Assert-WindowsWhatsappCaptureSafe', body)
                self.assertIn('EXPECTED_FAILURE', output)
                self.assertNotIn('UNEXPECTED_SUCCESS', output)
                self.assertIn('CONTROL_CONTINUED', output)
                self.assertNotIn('CONTROL_FAILED', output)


if __name__ == '__main__':
    unittest.main()
