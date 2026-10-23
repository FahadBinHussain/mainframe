"""WACLI parity assessment: synthetic metadata only, never a real account."""
from contextlib import redirect_stdout
import io
import json
from pathlib import Path
import sqlite3
import stat
import sys
import tempfile
import unittest
from unittest.mock import patch
from zipfile import ZipFile, ZipInfo

sys.path.insert(0, str(Path(__file__).parents[1]))
import linux_restore as lr
import wacli_go_plan as gp
import wacli_state as ws
from wacli_restore_contract import WINDOWS_PREFIX, restoration_status


class WacliRestoreContractTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='wacli-parity-fixture-')
        self.root = Path(self.tmp.name)
        self.archive = self.root / 'tool-secrets.zip'
        self.prefix = WINDOWS_PREFIX + '+15555550100/'

    def tearDown(self):
        self.tmp.cleanup()

    def write_zip(self, members):
        with ZipFile(self.archive, 'w') as z:
            for name, data in members:
                z.writestr(name, data)

    def test_metadata_pair_and_fake_version_never_prove_migration(self):
        self.write_zip([
            (self.prefix + 'store/session.db', b'not even sqlite'),
            (self.prefix + 'store/wacli.db', b'not even sqlite'),
            (self.prefix + 'mainframe-whatsapp.json', b'{"version":"v0.15.0","storePath":"C:\\private"}'),
            (WINDOWS_PREFIX + 'current.txt', b'+15555550100'),
        ])
        before = self.archive.read_bytes()
        with patch.object(ZipFile, 'open', side_effect=AssertionError('payload opened')), \
             patch.object(sqlite3, 'connect', side_effect=AssertionError('database opened')):
            report = ws.plan_windows_unlocked(self.archive)
        self.assertEqual(report['candidate_store_pairs'], 1)
        self.assertEqual(report['windows_entries'], 4)
        self.assertEqual(report['status'], 'blocked')
        self.assertFalse(report['complete'])
        self.assertFalse(report['member_payloads_read'])
        self.assertEqual(report['activation_status'], 'not-performed')
        self.assertEqual(report['usability_status'], 'unverified')
        self.assertNotIn('+15555550100', json.dumps(report))
        self.assertEqual(before, self.archive.read_bytes())
        self.assertEqual(list(self.root.iterdir()), [self.archive])

    def test_uncheckpointed_wal_remains_blocked_without_open_or_repair(self):
        # Make a real SQLite WAL, but never ask the assessor to open its data.
        db = self.root / 'synthetic.db'
        con = sqlite3.connect(db)
        try:
            con.execute('pragma journal_mode=wal')
            con.execute('pragma wal_autocheckpoint=0')
            con.execute('create table fixture (value blob)')
            con.execute('insert into fixture values (?)', (b'synthetic-only',))
            con.commit()
            wal = db.with_name(db.name + '-wal')
            self.assertTrue(wal.stat().st_size > 0)
            self.write_zip([(self.prefix + 'store/wacli.db', db.read_bytes()),
                            (self.prefix + 'store/wacli.db-wal', wal.read_bytes()),
                            (self.prefix + 'store/wacli.db-shm', db.with_name(db.name + '-shm').read_bytes()),
                            (self.prefix + 'store/session.db', b'fixture')])
            before = self.archive.read_bytes()
            with patch.object(ZipFile, 'open', side_effect=AssertionError('payload opened')), \
                 patch.object(sqlite3, 'connect', side_effect=AssertionError('database opened')):
                report = ws.plan_windows_unlocked(self.archive)
            self.assertEqual(report['sqlite_sidecars'], 2)
            self.assertEqual(report['status'], 'blocked')
            self.assertEqual(before, self.archive.read_bytes())
            self.assertTrue(wal.exists())
        finally:
            con.close()

    def test_missing_pair_or_missing_subtree_cannot_be_ready(self):
        for members in ([(self.prefix + 'store/session.db', b'fixture')],
                        [('mainframe-secrets.zip', b'opaque encrypted envelope')]):
            self.write_zip(members)
            with patch.object(ZipFile, 'open', side_effect=AssertionError('payload opened')):
                report = ws.plan_windows_unlocked(self.archive)
            self.assertEqual(report['candidate_store_pairs'], 0)
            self.assertFalse(report['complete'])
            self.assertEqual(report['status'], 'blocked')
            if not report['windows_entries']:
                self.assertEqual(report['blockers'][0]['code'], 'windows-profile-not-visible')

    def test_windows_separator_and_case_are_metadata_only(self):
        self.write_zip([((self.prefix + 'store/SESSION.DB').replace('/', '\\').upper(), b'fixture'),
                        (self.prefix + 'store/wacli.db', b'fixture')])
        report = ws.plan_windows_unlocked(self.archive)
        self.assertEqual(report['candidate_store_pairs'], 1)
        self.assertFalse(report['complete'])

    def test_unsafe_duplicate_collision_and_special_members_block(self):
        cases = [
            [(self.prefix + '../escape', b'x')],
            [(self.prefix + 'A', b'x'), (self.prefix + 'a', b'y')],
            [(self.prefix + 'node', b'x'), (self.prefix + 'node/child', b'y')],
            [(self.prefix + 'node/', b''), (self.prefix + 'node', b'y')],
        ]
        for members in cases:
            self.write_zip(members)
            with self.assertRaises(ws.StateError):
                ws.plan_windows_unlocked(self.archive)
        info = ZipInfo(self.prefix + 'link')
        info.create_system = 3
        info.external_attr = (stat.S_IFLNK | 0o600) << 16
        self.write_zip([(info, b'not followed')])
        with self.assertRaises(ws.StateError):
            ws.plan_windows_unlocked(self.archive)

    def test_encrypted_selected_members_block_without_decryption(self):
        self.write_zip([(self.prefix + 'store/session.db', b'fixture')])
        original = ZipFile.infolist
        def encrypted(z):
            infos = original(z)
            infos[0].flag_bits |= 1
            return infos
        with patch.object(ZipFile, 'infolist', encrypted):
            with self.assertRaises(ws.StateError):
                ws.plan_windows_unlocked(self.archive)

    def test_limits_and_cli_incomplete_exit(self):
        self.write_zip([(self.prefix + 'store/session.db', b'fixture')])
        with patch.object(ws, 'MAX_MEMBER_BYTES', 1):
            with self.assertRaises(ws.StateError):
                ws.plan_windows_unlocked(self.archive)
        with redirect_stdout(io.StringIO()) as output:
            code = ws.main(['plan-windows-unlocked', '--archive', str(self.archive)])
        self.assertEqual(code, 3)
        self.assertFalse(json.loads(output.getvalue())['complete'])

    def test_generic_plan_and_recovery_keep_install_separate_from_usable_data(self):
        detail = gp.build_dry_plan('x86_64')
        self.assertEqual(detail['route'], 'standard-linux-go-install')
        self.assertFalse(detail['execution_supported'])
        self.assertEqual(detail['restoration'], restoration_status())
        backup = self.root / 'backup'
        backup.mkdir()
        with ZipFile(backup / 'mainframe-quick.zip', 'w') as z:
            z.writestr('mainframe-secrets.zip', b'opaque fixture; do not open')
        with redirect_stdout(io.StringIO()) as output:
            code = lr.main([str(backup), '--mode', 'quick'])
        self.assertEqual(code, 3)
        self.assertFalse(json.loads(output.getvalue())['wacli_restoration']['complete'])
        report = lr.copy_recovery(backup, self.root / 'recovered', mode='quick', apply_portable=True)
        status = report['wacli_restoration']
        self.assertEqual(status['installation_status'], 'not-performed-by-this-operation')
        self.assertEqual(status['windows_migration_status'], 'blocked')
        self.assertEqual(status['usability_status'], 'unverified')
        self.assertFalse(status['complete'])
        self.assertEqual(list((self.root / 'recovered/home-staging').iterdir()), [])

    def test_windows_profiles_never_get_native_targets(self):
        for prefix in (WINDOWS_PREFIX, 'secrets/' + WINDOWS_PREFIX, 'UserProfile/.wacli/'):
            category, reason, target = lr.classify(prefix + 'store/session.db')
            self.assertEqual(category, 'blocked')
            self.assertIn('consistent SQLite snapshot', reason)
            self.assertIsNone(target)

    def test_native_staging_is_not_usable_or_windows_migration(self):
        self.write_zip([(ws.PREFIX + 'config.yaml', b'synthetic config')])
        report = ws.restore_unlocked(self.archive, self.root / 'offline')
        self.assertEqual(report['status'], 'offline-state-staged')
        self.assertEqual(report['restoration']['data_preservation_status'], 'explicit-native-root-offline-staged')
        self.assertFalse(report['restoration']['complete'])
        self.assertEqual(report['restoration']['usability_status'], 'unverified')


if __name__ == '__main__':
    unittest.main()
