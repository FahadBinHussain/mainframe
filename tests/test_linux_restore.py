import hashlib
import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest
import warnings
from pathlib import Path
from unittest.mock import patch
from zipfile import ZipFile, ZipInfo

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import linux_restore as lr


class LinuxRestoreTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.backup = self.root / 'backup'
        self.backup.mkdir()
        self.dest = self.root / 'new-offline-export'
        self.manifest = self.root / 'public-manifest.json'
        self.manifest.write_text('{"items": []}')

    def tearDown(self):
        self.temp.cleanup()

    def archive(self, members, name='mainframe-quick.zip'):
        with warnings.catch_warnings():
            warnings.simplefilter('ignore', UserWarning)
            with ZipFile(self.backup / name, 'w') as z:
                for key, value in members:
                    z.writestr(key, value)

    def inspect(self, mode='quick'):
        return lr.inventory(self.backup, self.manifest, mode)

    def recover(self, portable=False, mode='quick'):
        return lr.copy_recovery(self.backup, self.dest, portable, self.manifest, mode)

    def test_default_inventory_never_reads_member_payloads(self):
        self.archive([('UserProfile/.ssh/id_example', b'synthetic-fixture')])
        with patch.object(ZipFile, 'open', side_effect=AssertionError('payload access forbidden')):
            arcs, entries, errors = self.inspect()
        self.assertFalse(errors)
        self.assertEqual(arcs[0]['entries'], 1)
        self.assertNotIn('sha256', entries[0])
        self.assertFalse(self.dest.exists())

    def test_complete_raw_copy_and_member_hash(self):
        payload = bytes(range(256)) * 8193
        self.archive([('persist/gradle/cache/fixture', payload)])
        report = self.recover()
        self.assertEqual(report['data_preservation_status'], 'raw-archives-verified')
        self.assertEqual(report['operational_status'], 'incomplete')
        raw = self.dest / 'raw-archives/mainframe-quick.zip'
        self.assertEqual(lr.file_hash(raw), lr.file_hash(self.backup / raw.name))
        out = self.dest / 'recovered/mainframe-quick.zip/persist/gradle/cache/fixture'
        self.assertEqual(out.read_bytes(), payload)
        self.assertEqual(report['entries'][0]['sha256'], hashlib.sha256(payload).hexdigest())

    def test_every_known_persist_application_is_explicit(self):
        expected = {'7zip', 'alist', 'archisteamfarm', 'autohotkey', 'bulk-crap-uninstaller', 'discordchatexporter', 'ditto', 'ffmpeg', 'firefox', 'ghidra', 'git', 'gradle', 'megatools', 'micmute', 'mpc-hc', 'mpv', 'mpv-git', 'parsec', 'proton-vpn', 'pwsh', 'python312', 'rclone', 'rufus', 'syncplay', 'tesseract', 'tor-browser', 'v2rayn', 'vlc', 'windhawk', 'windows-terminal', 'x64dbg', 'yt-dlp'}
        self.assertEqual(expected, set(lr.PERSIST_TARGETS) | set(lr.PERSIST_BLOCKERS))
        for app in expected:
            self.assertNotEqual(lr.classify('persist/' + app + '/settings.ini')[0], 'unknown')

    def test_native_targets_and_offline_only(self):
        self.archive([('UserProfile/.ssh/id_fixture', b'key-fixture'), ('obs-studio/basic/scenes/a.json', b'{}'), ('quick-persist/flameshot/flameshot.ini', b'[General]')])
        report = self.recover(True)
        self.assertFalse(report['errors'])
        self.assertTrue((self.dest / 'home-staging/.ssh/id_fixture').exists())
        self.assertTrue((self.dest / 'home-staging/.config/obs-studio/basic/scenes/a.json').exists())
        self.assertTrue((self.dest / 'home-staging/.config/flameshot/flameshot.ini').exists())
        self.assertEqual(report['operational_status'], 'incomplete')

    def test_unknown_bytes_are_not_dropped(self):
        self.archive([('unmapped/state.strange', b'opaque')])
        report = self.recover(True)
        self.assertEqual(report['entries'][0]['category'], 'unknown')
        self.assertEqual((self.dest / 'recovered/mainframe-quick.zip/unmapped/state.strange').read_bytes(), b'opaque')
        self.assertFalse(any((self.dest / 'home-staging').iterdir()))

    def test_nested_secrets_preserved_opaque(self):
        cipher = b'synthetic encrypted archive fixture, never a real credential'
        self.archive([('mainframe-secrets.zip', cipher)])
        report = self.recover(True)
        self.assertEqual(report['entries'][0]['category'], 'opaque-archive')
        self.assertEqual((self.dest / 'recovered/mainframe-quick.zip/mainframe-secrets.zip').read_bytes(), cipher)
        self.assertFalse(any((self.dest / 'home-staging').iterdir()))

    def test_windows_and_instruction_items_never_staged(self):
        files = ['AGENTS.md', '.agents/skills/example/SKILL.md', 'UserProfile/AGENTS.md', 'UserProfile/.agents/skills/a', 'native/winget-persist/AnyDesk/service.conf', 'edge-profile/Default/Bookmarks', 'scheduled-tasks/job.xml', 'persist/ditto/Ditto.db', 'UserProfile/.opencode/tool.exe']
        self.archive([(p, b'fixture') for p in files])
        report = self.recover(True)
        self.assertTrue(all(e['category'] == 'blocked' for e in report['entries']))
        self.assertFalse(any((self.dest / 'home-staging').iterdir()))

    def test_quick_full_and_missing_inputs(self):
        self.archive([('quick-persist/ditto/settings', b'q')])
        self.assertTrue(self.inspect('full')[2])
        with self.assertRaises(ValueError):
            self.recover(mode='full')
        self.assertFalse(self.dest.exists())
        self.archive([('persist/ditto/settings', b'p')], 'mainframe-persist.zip')
        self.assertEqual(len(self.inspect('quick')[0]), 1)
        report = self.recover(mode='full')
        self.assertEqual(len(report['archives']), 2)
        self.assertEqual((self.dest / 'recovered/mainframe-quick.zip/quick-persist/ditto/settings').read_bytes(), b'q')
        self.assertEqual((self.dest / 'recovered/mainframe-persist.zip/persist/ditto/settings').read_bytes(), b'p')

    def test_unsafe_paths_are_raw_only(self):
        names = ['../escape', '/absolute', 'C:/drive', 'safe/../escape', 'safe//empty', './dot', 'a:b/stream', 'safe\\..\\escape']
        self.archive([(p, b'bad') for p in names])
        report = self.recover()
        self.assertTrue(all(e['status'] == 'raw-only' for e in report['entries']))
        self.assertFalse((self.root / 'escape').exists())
        self.assertFalse(any((self.dest / 'recovered').iterdir()))

    def test_duplicates_and_normalized_collisions(self):
        self.archive([('same', b'one'), ('same', b'two'), ('dir\\file', b'three'), ('dir/file', b'four')])
        report = self.recover()
        self.assertTrue(all(e['status'] == 'raw-only' for e in report['entries']))

    def test_file_directory_prefix_conflict(self):
        self.archive([('prefix', b'one'), ('prefix/child', b'two')])
        report = self.recover()
        self.assertTrue(all(e['status'] == 'raw-only' for e in report['entries']))

    def test_symlink_and_special_members_are_never_materialized(self):
        link = ZipInfo('link')
        link.create_system = 3
        link.external_attr = (stat.S_IFLNK | 0o777) << 16
        fifo = ZipInfo('fifo')
        fifo.create_system = 3
        fifo.external_attr = (stat.S_IFIFO | 0o600) << 16
        self.archive([(link, b'/outside'), (fifo, b'')])
        report = self.recover()
        self.assertTrue(all(e['status'] == 'raw-only' for e in report['entries']))
        self.assertFalse((self.dest / 'recovered/mainframe-quick.zip/link').exists())

    def test_existing_destination_never_overwritten(self):
        self.archive([('x', b'x')])
        self.dest.mkdir()
        (self.dest / 'keep').write_text('keep')
        with self.assertRaises(ValueError):
            self.recover()
        self.assertEqual((self.dest / 'keep').read_text(), 'keep')

    def test_symlink_destination_and_parent_rejected(self):
        self.archive([('x', b'x')])
        self.dest.symlink_to(self.root / 'absent')
        with self.assertRaises(ValueError):
            self.recover()
        self.dest.unlink()
        parent = self.root / 'parent-link'
        parent.symlink_to(self.backup, target_is_directory=True)
        with self.assertRaises(ValueError):
            lr.copy_recovery(self.backup, parent / 'new', manifest_path=self.manifest, mode='quick')

    def test_destination_inside_source_rejected(self):
        self.archive([('x', b'x')])
        with self.assertRaises(ValueError):
            lr.copy_recovery(self.backup, self.backup / 'new', manifest_path=self.manifest, mode='quick')

    def test_output_permissions_private(self):
        self.archive([('UserProfile/.ssh/fixture', b'private-fixture')])
        self.recover(True)
        self.assertEqual(stat.S_IMODE(self.dest.stat().st_mode), 0o700)
        for p in self.dest.rglob('*'):
            if p.is_file():
                self.assertEqual(stat.S_IMODE(p.stat().st_mode), 0o600, str(p))

    def test_native_target_collisions_keep_both_originals(self):
        self.archive([('persist/mpv/config', b'one'), ('persist/mpv-git/config', b'two')])
        report = self.recover(True)
        self.assertIn('staging-conflict', {e['status'] for e in report['entries']})
        self.assertEqual((self.dest / 'recovered/mainframe-quick.zip/persist/mpv/config').read_bytes(), b'one')
        self.assertEqual((self.dest / 'recovered/mainframe-quick.zip/persist/mpv-git/config').read_bytes(), b'two')

    def test_public_secret_manifest_all_items_accounted(self):
        self.manifest.write_text(json.dumps({'items': [{'archivePath': 'UserProfile/.ssh'}, {'archivePath': 'UserProfile/.local/share/opencode', 'disabled': True}]}))
        self.archive([('mainframe-secrets.zip', b'opaque')])
        entries = self.inspect()[1]
        coverage = [e for e in entries if e['archive'] == 'manifest-coverage']
        self.assertEqual(len(coverage), 2)
        self.assertEqual(coverage[0]['status'], 'not-visible-in-outer-archives')
        self.assertEqual(coverage[1]['status'], 'excluded-by-backup')

    def test_missing_manifest_is_loud(self):
        self.archive([('x', b'x')])
        self.manifest.unlink()
        self.assertTrue(self.inspect()[2])
        with self.assertRaises(ValueError):
            self.recover()

    def test_bad_archive_is_preflight_error(self):
        (self.backup / 'mainframe-quick.zip').write_bytes(b'not a zip')
        self.assertTrue(self.inspect()[2])
        with self.assertRaises(ValueError):
            self.recover()
        self.assertFalse(self.dest.exists())

    def test_empty_source_and_loose_data_are_loud(self):
        self.assertTrue(self.inspect()[2])
        self.archive([('x', b'x')])
        (self.backup / 'loose.txt').write_text('not silently skipped')
        self.assertTrue(self.inspect()[2])

    def test_limits_fail_before_creating_destination(self):
        self.archive([('a', b'12345')])
        with self.assertRaisesRegex(ValueError, 'safety limits'):
            lr.copy_recovery(self.backup, self.dest, manifest_path=self.manifest, mode='quick', max_member_bytes=4)
        self.assertFalse(self.dest.exists())
        with self.assertRaisesRegex(ValueError, 'safety limits'):
            lr.copy_recovery(self.backup, self.dest, manifest_path=self.manifest, mode='quick', max_expanded_bytes=4)
        self.assertFalse(self.dest.exists())

    def test_metadata_snapshot_mismatch_is_loud(self):
        self.archive([('a', b'fixture')])
        with patch.object(lr, 'zip_signature', side_effect=['original-signature', 'changed-signature']):
            report = self.recover()
        self.assertEqual(report['data_preservation_status'], 'failed')
        self.assertTrue(report['errors'])
        self.assertFalse(any((self.dest / 'recovered').iterdir()))
        self.assertFalse(list((self.dest / 'raw-archives').glob('*.partial')))

    def test_case_and_unicode_collisions_are_raw_only(self):
        self.archive([('File', b'1'), ('file', b'2'), ('caf\u00e9', b'3'), ('cafe\u0301', b'4')])
        report = self.recover()
        self.assertTrue(all(e['status'] == 'raw-only' for e in report['entries']))

    def test_secure_writer_rejects_symlinked_parent(self):
        outside = self.root / 'outside'
        outside.mkdir()
        alias = self.root / 'alias'
        alias.symlink_to(outside, target_is_directory=True)
        with self.assertRaises(OSError):
            lr.private_file(alias / 'must-not-write')
        self.assertFalse((outside / 'must-not-write').exists())

    def test_stream_size_limit_is_enforced(self):
        import io
        with self.assertRaisesRegex(ValueError, 'limit'):
            lr.stream_copy(io.BytesIO(b'larger than declared'), self.root / 'bounded', limit=3)

    def test_cli_status_and_option_guards(self):
        self.archive([('x', b'x')])
        command = [sys.executable, str(Path(lr.__file__)), str(self.backup), '--mode', 'quick', '--manifest', str(self.manifest)]
        result = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(result.returncode, 3)
        self.assertEqual(json.loads(result.stdout)['operational_status'], 'incomplete')
        result = subprocess.run(command + ['--apply-portable'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertFalse(self.dest.exists())


if __name__ == '__main__':
    unittest.main()
