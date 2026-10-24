import hashlib
import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from zipfile import ZipFile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import linux_migrations as lm
import linux_restore as lr


class GitAdapterTests(unittest.TestCase):
    def convert(self, text):
        return lm.convert_git_config(text.encode())

    def test_all_enums_and_native_line_endings(self):
        for key, values in lm.RULES.items():
            section, option = key.split('.')
            for original, expected in values.items():
                with self.subTest(key=key, value=original):
                    output, result = self.convert(f'[{section}]\r\n {option} = {original}\r\n')
                    self.assertIn(f'\t{option} = {expected}\n'.encode(), output)
                    self.assertNotIn(b'\r', output)
                    self.assertEqual(result['status'], 'converted-subset')
                    self.assertEqual(result['activation'], 'not-performed')
                    self.assertEqual(result['accepted_settings'], 1)
                    self.assertEqual(result['blocked_settings'], 0)

    def test_determinism_and_quoted_git_grammar(self):
        config = '[Diff]\n Algorithm = "histogram"\n[CORE]\n AutoCRLF = tr\\\nue\n eol = "crlf" # fixture\n'
        first = self.convert(config)
        self.assertEqual(first, self.convert(config))
        self.assertIn(b'\tautocrlf = input\n', first[0])
        self.assertIn(b'\teol = lf\n', first[0])
        self.assertLess(first[0].find(b'[core]'), first[0].find(b'[diff]'))

    def test_unknown_sensitive_keys_and_values_never_echoed(self):
        marker = 'SYNTHETIC_PRIVATE_MARKER'
        config = f'''[core]
 autocrlf = true
 editor = "!{marker}"
[credential "https://{marker}.invalid"]
 helper = "!{marker}"
[include]
 path = /nonexistent-{marker}
[includeIf "gitdir:/{marker}/"]
 path = /nonexistent-{marker}
[user]
 name = {marker}
 email = {marker}@example.invalid
 signingkey = {marker}
[gpg]
 program = {marker}
[remote "{marker}"]
 url = https://{marker}.invalid
[commit]
 gpgsign = true
'''
        output, result = self.convert(config)
        self.assertNotIn(marker, output.decode())
        self.assertNotIn(marker, json.dumps(result))
        self.assertEqual(result['accepted_settings'], 1)
        self.assertEqual(result['blocked_settings'], 10)
        self.assertNotIn(b'include', output)
        self.assertEqual(result['decisions'][0]['reason'], 'unmapped-or-sensitive-setting')

    def test_duplicates_case_variants_and_invalid_values_are_blocked(self):
        output, result = self.convert('[core]\n AutoCRLF=true\n autocrlf=false\n eol=private-unsupported-value\n')
        self.assertIsNone(output)
        self.assertEqual(result['blocked_settings'], 3)
        self.assertNotIn('private-unsupported-value', json.dumps(result))
        self.assertIn('duplicate-setting', json.dumps(result))
        self.assertIn('unsupported-value', json.dumps(result))

    def test_unsupported_value_for_every_key(self):
        for key in lm.RULES:
            section, option = key.split('.')
            output, result = self.convert(f'[{section}]\n {option} = "SYNTHETIC_VALUE\\nnext"\n')
            self.assertIsNone(output)
            self.assertEqual(result['blocked_settings'], 1)
            self.assertNotIn('SYNTHETIC_VALUE', json.dumps(result))

    def test_multiple_arbitrary_preference_values_never_enter_decisions(self):
        marker_values = {
            key: f'SYNTHETIC_PRIVATE_PREFERENCE_{index}_\\nnext'
            for index, key in enumerate(lm.RULES, 1)
        }
        config = ''.join(f'[{section}]\n {option} = "{value}"\n'
                         for (section, option), value in
                         ((key.split('.'), value) for key, value in marker_values.items()))
        output, result = self.convert(config)
        self.assertIsNone(output)
        serialized = json.dumps(result)
        for value in marker_values.values():
            self.assertNotIn(value.split('\\n', 1)[0], serialized)
        self.assertEqual(result['blocked_settings'], len(marker_values))

    def test_unknown_empty_and_bare_values_produce_no_output(self):
        for config in ('', '[user]\n email = example@example.invalid\n', '[core]\n autocrlf\n'):
            output, result = self.convert(config)
            self.assertIsNone(output)
            self.assertEqual(result['reason'], 'no-supported-settings')

    def test_size_nul_and_malformed_input_are_sanitized(self):
        for payload, reason in ((b'x' * (lm.MAX_CONFIG_BYTES + 1), 'config-size-limit'),
                                (b'[core]\x00', 'invalid-config'),
                                (b'[SYNTHETIC_MALFORMED', 'invalid-config')):
            output, result = lm.convert_git_config(payload)
            self.assertIsNone(output)
            self.assertEqual(result['reason'], reason)
            self.assertNotIn('SYNTHETIC_MALFORMED', json.dumps(result))

    def test_missing_parser_timeout_stderr_and_invalid_output_are_sanitized(self):
        def raises(*args, **kwargs):
            raise FileNotFoundError('SYNTHETIC_PRIVATE_ERROR')
        def timesout(*args, **kwargs):
            raise subprocess.TimeoutExpired('SYNTHETIC_PRIVATE_ERROR', 5)
        def bad_exit(*args, **kwargs):
            return subprocess.CompletedProcess(args, 3, b'', b'SYNTHETIC_PRIVATE_ERROR')
        def bad_output(*args, **kwargs):
            return subprocess.CompletedProcess(args, 0, b'core.autocrlf\ntrue', b'')
        for runner in (raises, timesout, bad_exit, bad_output):
            output, result = lm.convert_git_config(b'[core]\n autocrlf=true', runner=runner)
            self.assertIsNone(output)
            self.assertEqual(result['status'], 'blocked')
            self.assertNotIn('SYNTHETIC_PRIVATE_ERROR', json.dumps(result))

    def test_subprocess_contract_and_environment_isolation(self):
        def parser(command, **kwargs):
            self.assertEqual(command, ['git', 'config', '--no-includes', '--null', '--list', '--file', '-'])
            self.assertFalse(kwargs['shell'])
            self.assertFalse(kwargs['check'])
            self.assertEqual(kwargs['timeout'], 5)
            self.assertEqual(kwargs['input'], b'[core]\n eol=crlf')
            self.assertNotIn('GIT_CONFIG_COUNT', kwargs['env'])
            self.assertEqual(kwargs['env']['GIT_CONFIG_GLOBAL'], '/dev/null')
            return subprocess.CompletedProcess(command, 0, b'core.eol\ncrlf\x00', b'')
        with patch.dict(os.environ, {'GIT_CONFIG_COUNT': '1', 'GIT_CONFIG_KEY_0': 'core.eol', 'GIT_CONFIG_VALUE_0': 'private'}):
            output, _ = lm.convert_git_config(b'[core]\n eol=crlf', runner=parser)
        self.assertIn(b'eol = lf', output)

    def test_include_and_conditional_include_are_never_read(self):
        with tempfile.TemporaryDirectory() as folder:
            include = Path(folder) / 'include'
            include.write_text('[diff]\n algorithm = histogram\n')
            output, result = self.convert(f'[include]\n path={include}\n[includeIf "onbranch:*"]\n path={include}\n[core]\n eol=crlf\n')
        self.assertNotIn(b'[diff]', output)
        self.assertEqual(result['accepted_settings'], 1)
        self.assertEqual(result['blocked_settings'], 2)


class MpvAdapterTests(unittest.TestCase):
    def convert(self, text):
        return lm.convert_mpv_config(text.encode())

    def test_supported_boolean_subset_is_deterministic_and_lf_only(self):
        config = ('save-position-on-quit=yes\r\n'
                  'fullscreen = no # display preference\r\n'
                  'force-window=no\r\n'
                  'input-default-bindings\r\n'
                  'osc=yes\r\n')
        first = self.convert(config)
        self.assertEqual(first, self.convert(config))
        output, result = first
        self.assertEqual(output, (
            b'# Portable mpv subset generated offline; original config is preserved separately.\n'
            b'force-window = no\nfullscreen = no\ninput-default-bindings = yes\n'
            b'osc = yes\nsave-position-on-quit = yes\n'))
        self.assertNotIn(b'\r', output)
        self.assertEqual(result['adapter'], 'mpv-portable-options-v1')
        self.assertEqual(result['accepted_settings'], 5)
        self.assertEqual(result['blocked_settings'], 0)
        self.assertEqual(result['activation'], 'not-performed')

    def test_profile_settings_are_not_flattened_and_default_resumes_global(self):
        output, result = self.convert(
            'fullscreen=yes\n[portable]\nfullscreen=no\n'
            'script=C:\\Users\\Fixture\\custom.lua\n[default]\nosc=no\n')
        self.assertIn(b'fullscreen = yes\n', output)
        self.assertIn(b'osc = no\n', output)
        self.assertNotIn(b'custom.lua', output)
        self.assertEqual(result['accepted_settings'], 2)
        self.assertEqual(result['blocked_settings'], 2)
        self.assertIn('profile-scoped-setting', json.dumps(result))
        self.assertNotIn('C:\\Users', json.dumps(result))

    def test_unknown_paths_scripts_and_devices_are_blocked_without_echo(self):
        marker = 'SYNTHETIC_PRIVATE_MARKER'
        config = (f'fullscreen=yes\ninclude=C:\\Users\\{marker}\\extra.conf\n'
                  f'script=C:\\Users\\{marker}\\scripts\\user.lua\n'
                  f'glsl-shaders=~~exe_dir/{marker}.glsl\n'
                  f'input-ipc-server=\\\\.\\pipe\\{marker}\n')
        output, result = self.convert(config)
        self.assertIn(b'fullscreen = yes\n', output)
        self.assertNotIn(marker.encode(), output)
        self.assertNotIn(marker, json.dumps(result))
        self.assertEqual(result['accepted_settings'], 1)
        self.assertEqual(result['blocked_settings'], 4)
        self.assertEqual(result['decisions'][0]['reason'], 'unmapped-or-sensitive-setting')

    def test_duplicates_and_non_boolean_values_are_blocked(self):
        output, result = self.convert('fullscreen=yes\nfullscreen=no\nosc=auto\n')
        self.assertIsNone(output)
        self.assertEqual(result['accepted_settings'], 0)
        self.assertEqual(result['blocked_settings'], 3)
        self.assertIn('duplicate-setting', json.dumps(result))
        self.assertIn('unsupported-value', json.dumps(result))
        self.assertNotIn('auto', json.dumps(result))

    def test_no_flag_and_fs_aliases_are_blocked_and_collide_canonically(self):
        for config, option in (
                ('osc=yes\nno-osc\n', 'osc'),
                ('fullscreen=yes\nfs=no\n', 'fullscreen')):
            with self.subTest(option=option):
                output, result = self.convert(config)
                self.assertIsNone(output)
                decision = next(d for d in result['decisions'] if d.get('key') == option)
                self.assertEqual(decision['reason'], 'duplicate-setting')
                self.assertEqual(decision['count'], 2)
        for config, option in (('no-osc\n', 'osc'), ('fs\n', 'fullscreen')):
            with self.subTest(lone_alias=config):
                output, result = self.convert(config)
                self.assertIsNone(output)
                decision = next(d for d in result['decisions'] if d.get('key') == option)
                self.assertEqual(decision['reason'], 'unsupported-value')

    def test_unknown_only_empty_malformed_and_invalid_encoding_inputs(self):
        for payload, reason in (
                (b'', 'no-supported-settings'),
                (b'script=fixture.lua\n', 'no-supported-settings'),
                (b'[unterminated\nfullscreen=yes\n', 'invalid-config'),
                (b'fullscreen=yes\n=bad\n', 'invalid-config'),
                (b'fullscreen=\xff\n', 'invalid-config'),
                (b'fullscreen=yes\x00\n', 'invalid-config')):
            with self.subTest(reason=reason, payload=payload[:24]):
                output, result = lm.convert_mpv_config(payload)
                self.assertIsNone(output)
                self.assertEqual(result['reason'], reason)

    def test_size_limit_is_checked_before_parsing(self):
        output, result = lm.convert_mpv_config(b'x' * (lm.MAX_CONFIG_BYTES + 1))
        self.assertIsNone(output)
        self.assertEqual(result['reason'], 'config-size-limit')


class MigrationRecoveryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.backup = self.root / 'backup'
        self.backup.mkdir()
        self.dest = self.root / 'offline'
        self.manifest = self.root / 'manifest.json'
        self.manifest.write_text('{"items": []}')
        self.payload = b'[core]\r\n autocrlf=true\r\n eol=crlf\r\n[credential]\r\n helper=!SYNTHETIC_PRIVATE_MARKER\r\n'
        self.archive('mainframe-quick.zip', [('.gitconfig', self.payload)])

    def tearDown(self):
        self.temp.cleanup()

    def archive(self, name, members):
        with ZipFile(self.backup / name, 'w') as archive:
            for key, payload in members:
                archive.writestr(key, payload)

    def recover(self, **kwargs):
        return lr.copy_recovery(self.backup, self.dest, manifest_path=self.manifest,
                                mode=kwargs.pop('mode', 'quick'), **kwargs)

    def test_conversion_preserves_original_and_never_activates_home(self):
        live = self.root / 'live-home'
        live.mkdir()
        (live / '.gitconfig').write_bytes(b'live-sentinel')
        with patch.dict(os.environ, {'HOME': str(live)}):
            report = self.recover(convert_portable=True)
        output = self.dest / 'home-staging/.gitconfig'
        self.assertIn(b'autocrlf = input', output.read_bytes())
        self.assertEqual((live / '.gitconfig').read_bytes(), b'live-sentinel')
        self.assertEqual((self.dest / 'recovered/mainframe-quick.zip/.gitconfig').read_bytes(), self.payload)
        self.assertEqual(lr.file_hash(self.dest / 'raw-archives/mainframe-quick.zip'), lr.file_hash(self.backup / 'mainframe-quick.zip'))
        self.assertEqual(report['data_preservation_status'], 'raw-archives-verified')
        self.assertEqual(report['operational_status'], 'incomplete')
        self.assertFalse(report['complete'])
        self.assertEqual(report['conversion_counts'], {'converted-subset': 1})
        self.assertEqual(report['activation_status'], 'not-performed')
        self.assertEqual(report['entries'][0]['migration']['sha256'], hashlib.sha256(output.read_bytes()).hexdigest())
        self.assertNotIn('SYNTHETIC_PRIVATE_MARKER', json.dumps(report))
        for path in self.dest.rglob('*'):
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o700 if path.is_dir() else 0o600)

    def test_default_and_candidate_copy_do_not_convert(self):
        with patch.object(lr, 'convert_git_config', side_effect=AssertionError('conversion forbidden')):
            report = self.recover(apply_portable=True)
        self.assertEqual(report['conversion_status'], 'not-requested')
        self.assertFalse((self.dest / 'home-staging/.gitconfig').exists())

    def test_metadata_inventory_does_not_invoke_adapter(self):
        with patch.object(lr, 'convert_git_config', side_effect=AssertionError('conversion forbidden')), \
             patch.object(ZipFile, 'open', side_effect=AssertionError('payload forbidden')):
            self.assertFalse(lr.inventory(self.backup, self.manifest, 'quick')[2])
        self.assertFalse(self.dest.exists())

    def test_cross_archive_conflicts_have_no_winner(self):
        for second in ('.gitconfig', '.GITCONFIG'):
            with self.subTest(second=second):
                self.archive('mainframe-persist.zip', [(second, b'[core]\n eol=lf\n')])
                with patch.object(lr, 'convert_git_config', side_effect=AssertionError('conflict must preclude parsing')):
                    report = self.recover(mode='full', convert_portable=True)
                self.assertFalse((self.dest / 'home-staging/.gitconfig').exists())
                self.assertEqual(report['conversion_counts'],
                                 {'blocked': 2 if second == '.gitconfig' else 1})
                self.assertEqual(report['data_preservation_status'], 'raw-archives-verified')
                exact = next(e for e in report['entries'] if e['path'] == '.gitconfig')
                self.assertEqual(exact['migration']['reason'], 'conversion-target-conflict')
                if second == '.gitconfig':
                    for entry in report['entries']:
                        self.assertEqual(entry['migration']['reason'], 'conversion-target-conflict')
                else:
                    alias = next(e for e in report['entries'] if e['path'] == '.GITCONFIG')
                    self.assertNotIn('migration', alias)
                import shutil
                shutil.rmtree(self.dest)

    def test_case_variant_root_config_is_not_an_adapter_input(self):
        self.archive('mainframe-quick.zip', [('.GITCONFIG', self.payload)])
        with patch.object(lr, 'convert_git_config', side_effect=AssertionError('variant path must not parse')):
            report = self.recover(convert_portable=True)
        self.assertFalse((self.dest / 'home-staging/.gitconfig').exists())
        self.assertEqual(report['conversion_counts'], {})
        self.assertTrue(all('migration' not in entry for entry in report['entries']))

    def test_preexisting_output_is_not_overwritten(self):
        report = self.recover(convert_portable=True)
        output = self.dest / 'home-staging/.gitconfig'
        sentinel = output.read_bytes()
        lr.stage_conversions(report, self.dest)
        self.assertEqual(output.read_bytes(), sentinel)
        self.assertEqual(report['entries'][0]['migration']['reason'], 'conversion-target-conflict')

    def test_blocked_config_does_not_change_preservation_success(self):
        self.archive('mainframe-quick.zip', [('.gitconfig', b'[malformed')])
        report = self.recover(convert_portable=True)
        self.assertEqual(report['data_preservation_status'], 'raw-archives-verified')
        self.assertFalse(report['errors'])
        self.assertEqual(report['entries'][0]['migration']['reason'], 'invalid-config')
        self.assertFalse((self.dest / 'home-staging/.gitconfig').exists())

    def test_oversized_config_is_not_parsed(self):
        self.archive('mainframe-quick.zip', [('.gitconfig', b'x' * (lm.MAX_CONFIG_BYTES + 1))])
        with patch.object(lr, 'convert_git_config', side_effect=AssertionError('size must preclude parsing')):
            report = self.recover(convert_portable=True)
        self.assertEqual(report['entries'][0]['migration']['reason'], 'config-size-limit')

    def test_failed_publication_has_no_partial_output_or_original_loss(self):
        with patch.object(lr.os, 'link', side_effect=OSError('SYNTHETIC_PRIVATE_ERROR')):
            report = self.recover(convert_portable=True)
        self.assertFalse((self.dest / 'home-staging/.gitconfig').exists())
        self.assertFalse(list((self.dest / 'home-staging').iterdir()))
        self.assertEqual((self.dest / 'recovered/mainframe-quick.zip/.gitconfig').read_bytes(), self.payload)
        self.assertEqual(report['entries'][0]['migration']['reason'], 'conversion-write-or-read-failed')
        self.assertNotIn('SYNTHETIC_PRIVATE_ERROR', json.dumps(report))

    def test_unsafe_and_directory_sources_are_not_parsed(self):
        from zipfile import ZipInfo
        link = ZipInfo('.gitconfig')
        link.create_system = 3
        link.external_attr = (stat.S_IFLNK | 0o777) << 16
        for source in (link, '.gitconfig/'):
            with self.subTest(source=str(source)):
                self.archive('mainframe-quick.zip', [(source, b'fixture')])
                with patch.object(lr, 'convert_git_config', side_effect=AssertionError('source must not be parsed')):
                    report = self.recover(convert_portable=True)
                self.assertEqual(report['entries'][0]['migration']['reason'], 'source-not-verified-regular-file')
                self.assertFalse((self.dest / 'home-staging/.gitconfig').exists())
                import shutil
                shutil.rmtree(self.dest)

    def test_only_exact_root_config_is_an_adapter_input(self):
        self.archive('mainframe-quick.zip', [('.gitconfig', self.payload),
                     ('mainframe-secrets.zip', b'opaque-fixture'),
                     ('AppData/account/private.enc', b'opaque-fixture'),
                     ('persist/git/etc/gitconfig', b'raw-fixture'),
                     ('UserProfile/.gitconfig', b'raw-fixture')])
        original = lr.convert_git_config
        with patch.object(lr, 'convert_git_config', wraps=original) as adapter:
            report = self.recover(convert_portable=True)
        self.assertEqual(adapter.call_count, 1)
        self.assertEqual(adapter.call_args.args[0], self.payload)

    def test_symlinked_staging_parent_prevents_publication(self):
        report = self.recover(convert_portable=True)
        stage = self.dest / 'home-staging'
        (stage / '.gitconfig').unlink()
        stage.rmdir()
        outside = self.root / 'outside'
        outside.mkdir()
        stage.symlink_to(outside, target_is_directory=True)
        lr.stage_conversions(report, self.dest)
        self.assertFalse(list(outside.iterdir()))
        self.assertEqual(report['entries'][0]['migration']['reason'], 'conversion-write-or-read-failed')

    def test_cleanup_failure_does_not_expose_errors_or_change_preservation(self):
        original = Path.unlink
        def refuse_temporary(path, *args, **kwargs):
            if path.name.endswith('.convert-partial'):
                raise PermissionError('SYNTHETIC_PRIVATE_ERROR')
            return original(path, *args, **kwargs)
        with patch.object(Path, 'unlink', refuse_temporary):
            report = self.recover(convert_portable=True)
        self.assertEqual(report['data_preservation_status'], 'raw-archives-verified')
        self.assertEqual(report['entries'][0]['migration']['reason'], 'conversion-temporary-cleanup-failed')
        self.assertNotIn('SYNTHETIC_PRIVATE_ERROR', json.dumps(report))

    def test_insufficient_conversion_space_fails_before_creating_destination(self):
        from collections import namedtuple
        usage = namedtuple('Usage', 'total used free')(100, 99, 1)
        with patch.object(lr.shutil, 'disk_usage', return_value=usage):
            with self.assertRaisesRegex(ValueError, 'Insufficient free space'):
                self.recover(convert_portable=True)
        self.assertFalse(self.dest.exists())

    def test_cli_guards_and_success_summary(self):
        command = [sys.executable, str(Path(lr.__file__)), str(self.backup), '--mode', 'quick',
                   '--manifest', str(self.manifest), '--convert-portable']
        blocked = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(blocked.returncode, 2)
        self.assertFalse(self.dest.exists())
        result = subprocess.run(command + ['--recover', '--destination', str(self.dest)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 3)  # explicitly incomplete operational restore
        self.assertEqual(json.loads(result.stdout)['conversion_status'], 'review-required')
        self.assertNotIn('SYNTHETIC_PRIVATE_MARKER', result.stdout + result.stderr)


class MpvMigrationRecoveryTests(unittest.TestCase):
    SOURCE = 'persist/mpv/portable_config/mpv.conf'

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.backup = self.root / 'backup'
        self.backup.mkdir()
        self.dest = self.root / 'offline'
        self.manifest = self.root / 'manifest.json'
        self.manifest.write_text('{"items": []}')

    def tearDown(self):
        self.temp.cleanup()

    def archive(self, name, members):
        with ZipFile(self.backup / name, 'w') as archive:
            for key, payload in members:
                archive.writestr(key, payload)

    def recover(self, **kwargs):
        return lr.copy_recovery(self.backup, self.dest, manifest_path=self.manifest,
                                mode=kwargs.pop('mode', 'full'), **kwargs)

    def test_exact_scoop_portable_config_layout_converts_only_mpvcfg(self):
        config = (b'fullscreen=yes\r\nosc=no\r\n'
                  b'script=C:\\Users\\Fixture\\mpv\\scripts\\ignored.lua\r\n')
        self.archive('mainframe-quick.zip', [])
        self.archive('mainframe-persist.zip', [
            (self.SOURCE, config),
            ('persist/mpv/portable_config/input.conf', b'Q quit\n'),
            ('persist/mpv/portable_config/scripts/user.lua', b'-- inert fixture\n'),
            ('persist/mpv/portable_config/script-opts/example.conf', b'path=C:\\Fixture\n'),
            ('persist/mpv/portable_config/watch_later/fixture', b'opaque state\n'),
            ('persist/mpv/mpv.conf', b'fullscreen=no\n'),
        ])
        report = self.recover(convert_portable=True)
        converted = self.dest / 'home-staging/.config/mpv/mpv.conf'
        recovered = self.dest / 'recovered/mainframe-persist.zip' / self.SOURCE
        self.assertEqual(converted.read_bytes(),
                         b'# Portable mpv subset generated offline; original config is preserved separately.\n'
                         b'fullscreen = yes\nosc = no\n')
        self.assertEqual(recovered.read_bytes(), config)
        self.assertEqual(lr.file_hash(self.dest / 'raw-archives/mainframe-persist.zip'),
                         lr.file_hash(self.backup / 'mainframe-persist.zip'))
        self.assertFalse((self.dest / 'home-staging/.config/mpv/input.conf').exists())
        self.assertFalse((self.dest / 'home-staging/.config/mpv/scripts/user.lua').exists())
        source_entry = next(e for e in report['entries'] if e['normalized_path'] == self.SOURCE)
        self.assertEqual(source_entry['migration']['adapter'], 'mpv-portable-options-v1')
        self.assertEqual(source_entry['migration']['target'],
                         'home-staging/.config/mpv/mpv.conf')
        self.assertEqual(report['conversion_counts'], {'converted-subset': 1})
        self.assertEqual(report['activation_status'], 'not-performed')
        self.assertEqual(report['operational_status'], 'incomplete')
        self.assertNotIn('Fixture', json.dumps(report))

    def test_alternate_or_nested_layouts_are_not_adapter_inputs(self):
        self.archive('mainframe-quick.zip', [])
        self.archive('mainframe-persist.zip', [
            ('persist/mpv/mpv.conf', b'fullscreen=yes\n'),
            ('persist/mpv/portable_config/nested/mpv.conf', b'osc=no\n'),
            ('persist/mpv/portable_config/input.conf', b'Q quit\n'),
        ])
        with patch.object(lr, 'convert_mpv_config', side_effect=AssertionError('unsupported layout must not parse')):
            report = self.recover(convert_portable=True)
        self.assertFalse((self.dest / 'home-staging/.config/mpv/mpv.conf').exists())
        self.assertEqual(report['conversion_counts'], {})
        self.assertTrue(all('migration' not in entry for entry in report['entries']))

    def test_quick_full_duplicate_source_has_no_winner(self):
        self.archive('mainframe-quick.zip', [(self.SOURCE, b'fullscreen=yes\n')])
        self.archive('mainframe-persist.zip', [(self.SOURCE, b'fullscreen=no\n')])
        with patch.object(lr, 'convert_mpv_config', side_effect=AssertionError('duplicate must preclude parsing')):
            report = self.recover(convert_portable=True)
        self.assertFalse((self.dest / 'home-staging/.config/mpv/mpv.conf').exists())
        self.assertEqual(report['conversion_counts'], {'blocked': 2})
        self.assertTrue(all(e['migration']['reason'] == 'conversion-target-conflict'
                            for e in report['entries']))
        self.assertEqual(report['data_preservation_status'], 'raw-archives-verified')

    def test_case_and_unicode_casefold_variants_are_not_adapter_inputs(self):
        self.archive('mainframe-quick.zip', [])
        self.archive('mainframe-persist.zip', [
            ('PERSIST/MPV/PORTABLE_CONFIG/MPV.CONF', b'fullscreen=yes\n'),
            ('perſist/mpv/portable_config/mpv.conf', b'osc=no\n'),
        ])
        with patch.object(lr, 'convert_mpv_config', side_effect=AssertionError('variant path must not parse')):
            report = self.recover(convert_portable=True)
        self.assertFalse((self.dest / 'home-staging/.config/mpv/mpv.conf').exists())
        self.assertEqual(report['conversion_counts'], {})
        self.assertTrue(all('migration' not in entry for entry in report['entries']))

    def test_casefold_alias_conflict_blocks_exact_source_without_parsing_alias(self):
        self.archive('mainframe-quick.zip', [(self.SOURCE, b'fullscreen=yes\n')])
        alias = 'persist/MPV/portable_config/mpv.conf'
        self.archive('mainframe-persist.zip', [(alias, b'fullscreen=no\n')])
        with patch.object(lr, 'convert_mpv_config', side_effect=AssertionError('ambiguous source must not parse')):
            report = self.recover(convert_portable=True)
        self.assertFalse((self.dest / 'home-staging/.config/mpv/mpv.conf').exists())
        self.assertEqual(report['conversion_counts'], {'blocked': 1})
        exact = next(e for e in report['entries'] if e['normalized_path'] == self.SOURCE)
        variant = next(e for e in report['entries'] if e['normalized_path'] == alias)
        self.assertEqual(exact['migration']['reason'], 'conversion-target-conflict')
        self.assertNotIn('migration', variant)

    def test_candidate_output_collision_is_not_overwritten(self):
        self.archive('mainframe-quick.zip', [])
        self.archive('mainframe-persist.zip', [
            (self.SOURCE, b'fullscreen=yes\n'),
            ('persist/mpv/mpv.conf', b'candidate bytes\n'),
        ])
        report = self.recover(apply_portable=True, convert_portable=True)
        output = self.dest / 'home-staging/.config/mpv/mpv.conf'
        self.assertEqual(output.read_bytes(), b'candidate bytes\n')
        source_entry = next(e for e in report['entries'] if e['normalized_path'] == self.SOURCE)
        self.assertEqual(source_entry['migration']['reason'], 'conversion-target-conflict')
        self.assertEqual((self.dest / 'recovered/mainframe-persist.zip' / self.SOURCE).read_bytes(),
                         b'fullscreen=yes\n')

    def test_failed_publication_preserves_archive_and_emits_no_partial_config(self):
        self.archive('mainframe-quick.zip', [])
        self.archive('mainframe-persist.zip', [(self.SOURCE, b'fullscreen=yes\n')])
        with patch.object(lr.os, 'link', side_effect=OSError('SYNTHETIC_PRIVATE_ERROR')):
            report = self.recover(convert_portable=True)
        self.assertFalse((self.dest / 'home-staging/.config/mpv/mpv.conf').exists())
        self.assertFalse(any((self.dest / 'home-staging').rglob('*.convert-partial')))
        self.assertEqual((self.dest / 'recovered/mainframe-persist.zip' / self.SOURCE).read_bytes(),
                         b'fullscreen=yes\n')
        self.assertEqual(report['entries'][0]['migration']['reason'], 'conversion-write-or-read-failed')
        self.assertNotIn('SYNTHETIC_PRIVATE_ERROR', json.dumps(report))
        self.assertEqual(sum('migration' in entry for entry in report['entries']), 1)


if __name__ == '__main__':
    unittest.main()
