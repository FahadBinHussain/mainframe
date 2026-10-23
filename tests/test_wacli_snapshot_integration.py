"""Synthetic preparation tests; never invoke Windows backup programs or WACLI."""
from __future__ import annotations

import contextlib
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from zipfile import ZipFile

sys.path.insert(0, str(Path(__file__).parents[1]))
import wacli_snapshot as snapshot

HAS_AES = importlib.util.find_spec('pyzipper') is not None


class CapturePreflightTests(unittest.TestCase):
    """No caller assertion, path or staged receipt may enable source capture."""

    def test_capture_is_blocked_without_touching_paths(self):
        """Even arbitrary path-like objects are not inspected by the backend."""
        with patch('builtins.open', side_effect=AssertionError('source I/O')), \
                patch.object(Path, 'stat', side_effect=AssertionError('source stat')):
            result = snapshot.capture(object(), object())
        self.assertFalse(result['capture_enabled'])
        self.assertFalse(result['publishable'])
        self.assertFalse(result['complete'])
        self.assertFalse(result['source_read'])
        self.assertFalse(result['windows_validated'])
        self.assertIn('verified-all-writer-boundary-backend-unavailable', result['blockers'])

    def test_cli_returns_blocked_and_creates_no_destination(self):
        """Capture returns distinct blocked exit 3 with no password or source use."""
        with tempfile.TemporaryDirectory() as root:
            destination = Path(root) / 'must-not-exist'
            proc = subprocess.run([sys.executable, str(Path(snapshot.__file__)), 'capture',
                                   '--source-root', str(Path(root) / 'absent-private-source'),
                                   '--destination', str(destination)], capture_output=True,
                                  text=True, timeout=10)
            self.assertEqual(proc.returncode, 3, proc.stderr)
            self.assertEqual(json.loads(proc.stdout), snapshot.capture_status())
            self.assertFalse(destination.exists())
            self.assertNotIn(root, proc.stdout + proc.stderr)

    def test_no_quiescence_or_receipt_override_exists(self):
        """An attestation flag cannot accidentally unlock this protocol."""
        for option in ('--quiesced', '--receipt', '--force'):
            with self.subTest(option=option), contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as error:
                    snapshot.main(['capture', '--source-root', '/not-read',
                                   '--destination', '/not-written', option])
                self.assertEqual(error.exception.code, 2)

    def test_existing_mainframe_cli_exposes_identical_blockers(self):
        """The existing native helper wires only the no-I/O capability report."""
        proc = subprocess.run([sys.executable,
                               str(Path(snapshot.__file__).with_name('wacli_state.py')),
                               'plan-coordinated-capture'],
                              capture_output=True, text=True, timeout=10)
        self.assertEqual(proc.returncode, 3, proc.stderr)
        self.assertEqual(json.loads(proc.stdout), snapshot.capture_status())

    def test_missing_encryption_provider_fails_before_prepared_tree_read(self):
        """Missing optional AES never falls back to an unencrypted export."""
        with patch.dict(sys.modules, {'pyzipper': None}), \
                patch.object(Path, 'rglob', side_effect=AssertionError('payload read')):
            with self.assertRaisesRegex(ValueError, 'AES provider unavailable'):
                snapshot._encrypt_candidate('/not-read', '/not-written', b'synthetic')


@unittest.skipUnless(HAS_AES, 'optional pyzipper AES provider unavailable')
class CandidateEnvelopeTests(unittest.TestCase):
    """Candidate-only private workspace tests, not Windows publication coverage."""

    def setUp(self):
        """Create temporary synthetic preparation bytes and separate workspace."""
        self.tmp = tempfile.TemporaryDirectory(prefix='wacli-candidate-test-')
        self.root = Path(self.tmp.name)
        self.prepared = self.root / 'prepared'
        self.prepared.mkdir(mode=0o700)
        (self.prepared / 'originals').mkdir()
        (self.prepared / 'originals' / 'unknown.bin').write_bytes(bytes(range(256)))
        (self.prepared / 'receipt.json').write_text(json.dumps({
            'format': 'wacli-snapshot-preparation-v1',
            'status': 'PREPARATION',
            'publishable': False,
            'boundary': 'UNVERIFIED',
            'provenance': 'UNVERIFIED',
            'cross_database_consistency': 'NOT_CERTIFIED',
        }))
        self.work = self.root / 'private-work'
        self.work.mkdir(mode=0o700)
        self.password = b'synthetic-fixture-only-password'

    def tearDown(self):
        """Remove all synthetic plaintext and encrypted temporary data."""
        self.tmp.cleanup()

    def test_existing_aes_layout_round_trips_every_candidate_member(self):
        """Exact bytes survive AES but preparation prefix cannot activate state."""
        import pyzipper
        envelope = snapshot._encrypt_candidate(self.prepared, self.work, self.password)
        self.assertEqual(envelope.name, 'mainframe-secrets.zip')
        self.assertFalse((self.work / 'tool-secrets.zip').exists())
        with pyzipper.AESZipFile(envelope) as archive:
            archive.setpassword(self.password)
            self.assertEqual(archive.namelist(), ['tool-secrets.zip'])
            info = archive.getinfo('tool-secrets.zip')
            self.assertEqual(info.wz_aes_strength, 3)
            data = archive.read('tool-secrets.zip')
        with ZipFile(io.BytesIO(data)) as archive:
            for name in archive.namelist():
                self.assertTrue(name.startswith(snapshot.PREPARATION_PREFIX))
                self.assertFalse(name.startswith('NativeState/wacli/'))
                self.assertFalse(name.startswith('AppData/'))
                expected = self.prepared / name[len(snapshot.PREPARATION_PREFIX):]
                self.assertEqual(archive.read(name), b'' if name.endswith('/') else expected.read_bytes())
        self.assertFalse(snapshot.capture_status()['publishable'])

    def test_wrong_password_truncation_and_authentication_corruption_fail(self):
        """Both authentication failure and truncated candidates fail closed."""
        import pyzipper
        envelope = snapshot._encrypt_candidate(self.prepared, self.work, self.password)
        with pyzipper.AESZipFile(envelope) as archive:
            archive.setpassword(b'wrong-synthetic-password')
            with self.assertRaises(RuntimeError):
                archive.read('tool-secrets.zip')
        original = envelope.read_bytes()
        with pyzipper.AESZipFile(envelope) as archive:
            info = archive.getinfo('tool-secrets.zip')
        raw = bytearray(original)
        start = info.header_offset
        name_size = int.from_bytes(raw[start + 26:start + 28], 'little')
        extra_size = int.from_bytes(raw[start + 28:start + 30], 'little')
        auth_end = start + 30 + name_size + extra_size + info.compress_size
        raw[auth_end - 1] ^= 1
        envelope.write_bytes(raw)
        with pyzipper.AESZipFile(envelope) as archive:
            archive.setpassword(self.password)
            with self.assertRaises(Exception):
                archive.read('tool-secrets.zip')
        envelope.write_bytes(original[:-24])
        with self.assertRaises(Exception):
            with pyzipper.AESZipFile(envelope) as archive:
                archive.setpassword(self.password)
                archive.read('tool-secrets.zip')

    def test_existing_candidate_is_never_overwritten(self):
        """No replace semantics protect even a private existing envelope."""
        existing = self.work / 'mainframe-secrets.zip'
        existing.write_bytes(b'keep fixture')
        with self.assertRaises(ValueError):
            snapshot._encrypt_candidate(self.prepared, self.work, self.password)
        self.assertEqual(existing.read_bytes(), b'keep fixture')

    def test_private_sqlite_candidate_is_temporary_and_not_a_restore(self):
        """Real synthetic WAL pair reaches AES, with no persistent publication."""
        import pyzipper
        source = self.root / 'synthetic-stage'
        source.mkdir(mode=0o700)
        connections = []
        try:
            for name in ('wacli.db', 'session.db'):
                con = sqlite3.connect(source / name)
                connections.append(con)
                con.execute('PRAGMA journal_mode=WAL')
                con.execute('PRAGMA wal_autocheckpoint=0')
                con.execute('CREATE TABLE synthetic_data(value BLOB)')
                con.execute('INSERT INTO synthetic_data VALUES (?)', (b'fixture-only',))
                con.commit()
            before = {p.name: p.read_bytes() for p in source.iterdir()}
            with snapshot._private_candidate(source, self.password) as (envelope, receipt):
                self.assertFalse(receipt['publishable'])
                self.assertEqual(receipt['boundary'], 'UNVERIFIED')
                private_root = envelope.parent
                with pyzipper.AESZipFile(envelope) as archive:
                    archive.setpassword(self.password)
                    inner = archive.read('tool-secrets.zip')
                with ZipFile(io.BytesIO(inner)) as archive:
                    names = archive.namelist()
                    self.assertIn(snapshot.PREPARATION_PREFIX + 'originals/wacli.db-wal', names)
                    self.assertIn(snapshot.PREPARATION_PREFIX + 'derived/session.db', names)
                    self.assertTrue(all(name.startswith(snapshot.PREPARATION_PREFIX) for name in names))
                self.assertEqual(before, {p.name: p.read_bytes() for p in source.iterdir()})
            self.assertFalse(private_root.exists())
            self.assertFalse(snapshot.capture_status()['capture_enabled'])
        finally:
            for con in connections:
                con.close()

    def test_archive_failure_cleans_new_candidate_and_plaintext_inner(self):
        """Archive errors cannot leave an apparently completed candidate."""
        import pyzipper
        with patch.object(pyzipper.AESZipFile, 'write', side_effect=OSError('fixture failure')):
            with self.assertRaises(OSError):
                snapshot._encrypt_candidate(self.prepared, self.work, self.password)
        self.assertFalse((self.work / 'mainframe-secrets.zip').exists())
        self.assertFalse((self.work / 'tool-secrets.zip').exists())

    def test_missing_or_non_directory_preparation_is_rejected(self):
        with self.assertRaises(ValueError):
            snapshot._encrypt_candidate(self.root / 'missing', self.work, self.password)
        not_a_directory = self.root / 'not-a-directory'
        not_a_directory.write_bytes(b'fixture')
        with self.assertRaises(ValueError):
            snapshot._encrypt_candidate(not_a_directory, self.work, self.password)

    def test_overlapping_private_roots_are_rejected(self):
        with self.assertRaisesRegex(ValueError, 'overlap'):
            snapshot._encrypt_candidate(self.prepared, self.prepared, self.password)

    def test_invalid_receipt_is_rejected_before_archiving(self):
        receipt = self.prepared / 'receipt.json'
        receipt.write_text('{"publishable": true}')
        with self.assertRaisesRegex(ValueError, 'receipt'):
            snapshot._encrypt_candidate(self.prepared, self.work, self.password)

    def test_new_member_after_enumeration_is_rejected_and_cleaned(self):
        original_inventory = snapshot._inventory
        calls = [0]

        def inventory_with_mutation(root, *args, **kwargs):
            calls[0] += 1
            result = original_inventory(root, *args, **kwargs)
            if calls[0] == 2:
                (self.prepared / 'added-after-enumeration.bin').write_bytes(b'late')
            return result

        with patch.object(snapshot, '_inventory', side_effect=inventory_with_mutation):
            with self.assertRaisesRegex(ValueError, 'changed'):
                snapshot._encrypt_candidate(self.prepared, self.work, self.password)
        self.assertFalse((self.work / 'tool-secrets.zip').exists())
        self.assertFalse((self.work / 'mainframe-secrets.zip').exists())


if __name__ == '__main__':
    unittest.main()
