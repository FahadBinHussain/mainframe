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


class YtDlpAdapterTests(unittest.TestCase):
    HEADER = b'# Portable yt-dlp subset generated offline; original config is preserved separately.\n'

    def convert(self, text):
        return lm.convert_yt_dlp_config(text.encode())

    def test_documented_platform_neutral_flags_and_aliases(self):
        for source, target in (
                ('--ignore-errors', '--ignore-errors'),
                ('-i', '--ignore-errors'),
                ('--abort-on-error', '--abort-on-error'),
                ('--no-ignore-errors', '--abort-on-error'),
                ('--no-abort-on-error', '--no-abort-on-error')):
            with self.subTest(source=source):
                first = self.convert(f'# synthetic comment\r\n{source}\r\n')
                self.assertEqual(first, self.convert(f'# synthetic comment\r\n{source}\r\n'))
                output, result = first
                self.assertEqual(output, self.HEADER + target.encode('ascii') + b'\n')
                self.assertNotIn(b'\r', output)
                self.assertEqual(result['adapter'], 'yt-dlp-portable-options-v1')
                self.assertEqual(result['status'], 'converted-subset')
                self.assertEqual(result['accepted_settings'], 1)
                self.assertEqual(result['blocked_settings'], 0)
                self.assertEqual(result['activation'], 'not-performed')

    def test_unknown_sensitive_paths_credentials_plugins_and_commands_block_whole_file(self):
        markers = ('SYNTHETIC_COOKIE_PATH', 'SYNTHETIC_BROWSER_PROFILE',
                   'SYNTHETIC_USERNAME', 'SYNTHETIC_PASSWORD',
                   'SYNTHETIC_PROXY_HOST', 'SYNTHETIC_PLUGIN_PATH',
                   'SYNTHETIC_EXEC_COMMAND', 'SYNTHETIC_OUTPUT_PATH')
        config = '''--ignore-errors
--cookies C:\\Users\\Fixture\\SYNTHETIC_COOKIE_PATH
--cookies-from-browser SYNTHETIC_BROWSER_PROFILE
--username SYNTHETIC_USERNAME
--password SYNTHETIC_PASSWORD
--proxy https://SYNTHETIC_PROXY_HOST:8443
--plugin-dirs C:\\Users\\Fixture\\SYNTHETIC_PLUGIN_PATH
--exec "echo SYNTHETIC_EXEC_COMMAND"
-o C:\\Users\\Fixture\\SYNTHETIC_OUTPUT_PATH
'''
        output, result = self.convert(config)
        self.assertIsNone(output)
        self.assertEqual(result['accepted_settings'], 0)
        self.assertEqual(result['blocked_settings'], 9)
        serialized = json.dumps(result)
        for marker in markers:
            self.assertNotIn(marker, serialized)
        self.assertNotIn('C:\\Users', serialized)
        self.assertNotIn('SYNTHETIC_PROXY_HOST', serialized)
        self.assertIn('unmapped-or-sensitive-setting', serialized)

    def test_arguments_duplicates_and_mixed_policies_are_blocked(self):
        cases = (
            ('--ignore-errors yes\n', 'unsupported-option-form', 1),
            ('--ignore-errors=yes\n', 'unsupported-option-form', 1),
            ('--ignore-errors\n-i\n', 'duplicate-setting', 2),
            ('--ignore-errors\n--abort-on-error\n', 'mixed-error-policy', 2),
            ('--no-abort-on-error\n--ignore-errors\n', 'mixed-error-policy', 2),
        )
        for config, reason, count in cases:
            with self.subTest(config=config):
                output, result = self.convert(config)
                self.assertIsNone(output)
                self.assertEqual(result['blocked_settings'], count)
                self.assertIn(reason, json.dumps(result))
                self.assertEqual(result['accepted_settings'], 0)

    def test_malformed_encoding_controls_size_and_empty_inputs_are_sanitized(self):
        for payload, reason in (
                (b'\xff', 'invalid-config'),
                (b'\xef\xbb\xbf--ignore-errors\n', 'invalid-config'),
                (b'--ignore-errors\x00\n', 'invalid-config'),
                (b'--ignore-errors\n\x01', 'invalid-config'),
                (b'x' * (lm.MAX_CONFIG_BYTES + 1), 'config-size-limit')):
            with self.subTest(reason=reason):
                output, result = lm.convert_yt_dlp_config(payload)
                self.assertIsNone(output)
                self.assertEqual(result['reason'], reason)
                self.assertGreaterEqual(result['blocked_settings'], 1)
        for config, reason in (('', 'no-supported-settings'),
                               ('# only a synthetic comment\n\n', 'no-supported-settings'),
                               ('C:\\Users\\SYNTHETIC_PATH\n', 'unsupported-or-conflicting-settings')):
            with self.subTest(reason=reason):
                output, result = self.convert(config)
                self.assertIsNone(output)
                self.assertEqual(result['reason'], reason)
                self.assertNotIn('SYNTHETIC_PATH', json.dumps(result))


class FlameshotAdapterTests(unittest.TestCase):
    HEADER = b'; Portable Flameshot subset generated offline; original config is preserved separately.\n[General]\n'

    def convert(self, text):
        return lm.convert_flameshot_config(text.encode())

    def test_documented_shared_preferences_are_deterministic(self):
        config = ('[General]\r\nshowHelp=true\r\nuiColor=#740096\r\n'
                  'contrastUiColor=#270032\r\ndrawColor=#FF00AA\r\n'
                  'contrastOpacity=0255\r\n')
        first = self.convert(config)
        self.assertEqual(first, self.convert(config))
        output, result = first
        self.assertEqual(output, self.HEADER +
                         b'contrastOpacity=255\ncontrastUiColor=#270032\n'
                         b'drawColor=#ff00aa\nshowHelp=true\nuiColor=#740096\n')
        self.assertNotIn(b'\r', output)
        self.assertEqual(result['adapter'], 'flameshot-portable-preferences-v1')
        self.assertEqual(result['status'], 'converted-subset')
        self.assertEqual(result['accepted_settings'], 5)
        self.assertEqual(result['blocked_settings'], 0)
        self.assertEqual(result['activation'], 'not-performed')

    def test_paths_credentials_scripts_shortcuts_and_unknowns_are_blocked_without_echo(self):
        markers = ('SYNTHETIC_WINDOWS_PATH', 'SYNTHETIC_CREDENTIAL_MARKER',
                   'SYNTHETIC_COMMAND_MARKER', 'SYNTHETIC_PERSON_MARKER',
                   'SYNTHETIC_SHORTCUT_MARKER')
        config = '''[General]
uiColor=#abcdef
savePath=C:\\Users\\Fixture\\SYNTHETIC_WINDOWS_PATH
startupLaunch=true
uploadClientSecret=SYNTHETIC_CREDENTIAL_MARKER
postCaptureCommand=SYNTHETIC_COMMAND_MARKER
fontFamily=SYNTHETIC_PERSON_MARKER
[Shortcuts]
TAKE_SCREENSHOT=SYNTHETIC_SHORTCUT_MARKER
'''
        output, result = self.convert(config)
        self.assertEqual(output, self.HEADER + b'uiColor=#abcdef\n')
        self.assertEqual(result['accepted_settings'], 1)
        self.assertEqual(result['blocked_settings'], 6)
        serialized = json.dumps(result)
        for marker in markers:
            self.assertNotIn(marker, serialized)
        self.assertNotIn('C:\\\\Users', serialized)
        self.assertIn('unmapped-or-sensitive-setting', serialized)

    def test_duplicate_and_invalid_allowlisted_values_are_counted_not_echoed(self):
        config = ('[General]\nshowHelp=true\nshowHelp=false\n'
                  'uiColor=#abcdef\ncontrastOpacity=256\n')
        output, result = self.convert(config)
        self.assertEqual(output, self.HEADER + b'uiColor=#abcdef\n')
        self.assertEqual(result['accepted_settings'], 1)
        self.assertEqual(result['blocked_settings'], 3)
        serialized = json.dumps(result)
        self.assertIn('duplicate-setting', serialized)
        self.assertIn('unsupported-value', serialized)
        self.assertNotIn('256', serialized)

    def test_malformed_encoding_sections_and_ini_lines_are_sanitized(self):
        for payload, reason in (
                (b'\xff', 'invalid-config'),
                (b'\xef\xbb\xbf[General]\nshowHelp=true\n', 'invalid-config'),
                (b'[General]\x00showHelp=true\n', 'invalid-config'),
                (b'[General\nshowHelp=true\n', 'invalid-config'),
                (b'C:\\Users\\SYNTHETIC_PATH\n', 'invalid-config'),
                (b'[General]\nshowHelp=yes\ndrawColor=red\ncontrastOpacity=999\n',
                 'no-supported-settings'),
                (b'[General]\ncontrastOpacity=' + b'9' * 10000,
                 'no-supported-settings'),
                (b'x' * (lm.MAX_CONFIG_BYTES + 1), 'config-size-limit')):
            with self.subTest(reason=reason):
                output, result = lm.convert_flameshot_config(payload)
                self.assertIsNone(output)
                self.assertEqual(result['reason'], reason)
                self.assertGreaterEqual(result['blocked_settings'], 1)
                self.assertNotIn('SYNTHETIC_PATH', json.dumps(result))


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


class YtDlpMigrationRecoveryTests(unittest.TestCase):
    SOURCE = 'persist/yt-dlp/yt-dlp.conf'

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

    def test_exact_scoop_source_converts_only_flag_and_preserves_plugins_raw(self):
        config = b'# SYNTHETIC_PRIVATE_COMMENT\r\n-i\r\n'
        self.archive('mainframe-quick.zip', [])
        self.archive('mainframe-persist.zip', [
            (self.SOURCE, config),
            ('persist/yt-dlp/ytdlp_plugins/private.py', b'SYNTHETIC_PLUGIN_CODE'),
            ('persist/yt-dlp/yt-dlp-plugins/other.py', b'SYNTHETIC_OTHER_PLUGIN'),
        ])
        live = self.root / 'live-home'
        live.mkdir()
        (live / 'sentinel').write_bytes(b'unchanged')
        with patch.dict(os.environ, {'HOME': str(live)}):
            report = self.recover(apply_portable=True, convert_portable=True)

        converted = self.dest / 'home-staging/.config/yt-dlp/config'
        candidate = self.dest / 'home-staging/.config/yt-dlp/yt-dlp.conf'
        recovered = self.dest / 'recovered/mainframe-persist.zip' / self.SOURCE
        self.assertEqual(converted.read_bytes(), YtDlpAdapterTests.HEADER + b'--ignore-errors\n')
        self.assertEqual(candidate.read_bytes(), config)
        self.assertEqual(recovered.read_bytes(), config)
        self.assertEqual((live / 'sentinel').read_bytes(), b'unchanged')
        for rel in ('ytdlp_plugins/private.py', 'yt-dlp-plugins/other.py'):
            self.assertFalse((self.dest / 'home-staging/.config/yt-dlp' / rel).exists())
            self.assertTrue((self.dest / 'recovered/mainframe-persist.zip/persist/yt-dlp' / rel).exists())
        entries = {entry['normalized_path']: entry for entry in report['entries']}
        for plugin in ('persist/yt-dlp/ytdlp_plugins/private.py',
                       'persist/yt-dlp/yt-dlp-plugins/other.py'):
            self.assertEqual(entries[plugin]['category'], 'blocked')
        self.assertEqual(report['conversion_counts'], {'converted-subset': 1})
        self.assertEqual(report['activation_status'], 'not-performed')
        self.assertEqual(report['operational_status'], 'incomplete')
        self.assertNotIn('SYNTHETIC_PRIVATE_COMMENT', json.dumps(report))

    def test_apply_portable_keeps_config_as_candidate_but_blocks_plugin_directories(self):
        config = b'--ignore-errors\n# raw candidate only\n'
        self.archive('mainframe-quick.zip', [])
        self.archive('mainframe-persist.zip', [
            (self.SOURCE, config),
            ('persist/yt-dlp/ytdlp_plugins/private.py', b'SYNTHETIC_PLUGIN_CODE'),
        ])
        with patch.object(lr, 'convert_yt_dlp_config', side_effect=AssertionError('candidate copy must not convert')):
            report = self.recover(apply_portable=True)
        candidate = self.dest / 'home-staging/.config/yt-dlp/yt-dlp.conf'
        self.assertEqual(candidate.read_bytes(), config)
        self.assertFalse((self.dest / 'home-staging/.config/yt-dlp/config').exists())
        self.assertFalse((self.dest / 'home-staging/.config/yt-dlp/ytdlp_plugins/private.py').exists())
        self.assertEqual((self.dest / 'recovered/mainframe-persist.zip' / self.SOURCE).read_bytes(), config)
        plugin = next(e for e in report['entries']
                      if e['normalized_path'] == 'persist/yt-dlp/ytdlp_plugins/private.py')
        self.assertEqual(plugin['category'], 'blocked')

    def test_unknown_paths_credentials_proxy_and_plugins_remain_raw_without_output(self):
        config = (b'--ignore-errors\n'
                  b'--cookies C:\\Users\\Fixture\\SYNTHETIC_COOKIE\n'
                  b'--username SYNTHETIC_USER\n'
                  b'--password SYNTHETIC_PASSWORD\n'
                  b'--proxy https://SYNTHETIC_PROXY_HOST:8443\n'
                  b'--plugin-dirs C:\\Users\\Fixture\\SYNTHETIC_PLUGIN_PATH\n'
                  b'--exec "echo SYNTHETIC_SCRIPT"\n')
        self.archive('mainframe-quick.zip', [])
        self.archive('mainframe-persist.zip', [(self.SOURCE, config)])
        report = self.recover(convert_portable=True)
        source_entry = next(e for e in report['entries'] if e['normalized_path'] == self.SOURCE)
        self.assertEqual(source_entry['migration']['status'], 'blocked')
        self.assertEqual(source_entry['migration']['blocked_settings'], 7)
        self.assertFalse((self.dest / 'home-staging/.config/yt-dlp/config').exists())
        self.assertEqual((self.dest / 'recovered/mainframe-persist.zip' / self.SOURCE).read_bytes(), config)
        serialized = json.dumps(report)
        for marker in ('SYNTHETIC_COOKIE', 'SYNTHETIC_USER', 'SYNTHETIC_PASSWORD',
                       'SYNTHETIC_PROXY_HOST', 'SYNTHETIC_PLUGIN_PATH',
                       'SYNTHETIC_SCRIPT', 'C:\\Users'):
            self.assertNotIn(marker, serialized)

    def test_nonexact_config_layout_is_never_passed_to_adapter(self):
        self.archive('mainframe-quick.zip', [])
        self.archive('mainframe-persist.zip', [
            ('persist/yt-dlp/config', b'--ignore-errors\n'),
            ('persist/yt-dlp/yt-dlp.conf.backup', b'--abort-on-error\n'),
        ])
        with patch.object(lr, 'convert_yt_dlp_config', side_effect=AssertionError('nonexact path must not parse')):
            report = self.recover(apply_portable=True, convert_portable=True)
        self.assertFalse((self.dest / 'home-staging/.config/yt-dlp/config').exists())
        self.assertFalse((self.dest / 'home-staging/.config/yt-dlp').exists())
        self.assertEqual(report['conversion_counts'], {})
        self.assertTrue(all(entry['category'] == 'blocked'
                            for entry in report['entries']
                            if entry.get('normalized_path', '').startswith('persist/yt-dlp/')))

    def test_quick_full_duplicate_source_has_no_winner(self):
        self.archive('mainframe-quick.zip', [(self.SOURCE, b'--ignore-errors\n')])
        self.archive('mainframe-persist.zip', [(self.SOURCE, b'--abort-on-error\n')])
        with patch.object(lr, 'convert_yt_dlp_config', side_effect=AssertionError('duplicate must preclude parsing')):
            report = self.recover(convert_portable=True)
        self.assertFalse((self.dest / 'home-staging/.config/yt-dlp/config').exists())
        self.assertEqual(report['conversion_counts'], {'blocked': 2})
        self.assertTrue(all(e['migration']['reason'] == 'conversion-target-conflict'
                            for e in report['entries']))
        self.assertEqual(report['data_preservation_status'], 'raw-archives-verified')

    def test_casefold_alias_conflict_blocks_exact_source(self):
        alias = 'persist/yt-dlp/YT-DLP.conf'
        unicode_alias = 'perſist/yt-dlp/yt-dlp.conf'
        self.archive('mainframe-quick.zip', [(self.SOURCE, b'--ignore-errors\n')])
        self.archive('mainframe-persist.zip', [
            (alias, b'--abort-on-error\n'),
            (unicode_alias, b'--no-abort-on-error\n'),
        ])
        with patch.object(lr, 'convert_yt_dlp_config', side_effect=AssertionError('ambiguous source must not parse')):
            report = self.recover(convert_portable=True)
        exact = next(e for e in report['entries'] if e['normalized_path'] == self.SOURCE)
        variant = next(e for e in report['entries'] if e['normalized_path'] == alias)
        unicode_variant = next(e for e in report['entries'] if e['normalized_path'] == unicode_alias)
        self.assertFalse((self.dest / 'home-staging/.config/yt-dlp/config').exists())
        self.assertEqual(exact['migration']['reason'], 'conversion-target-conflict')
        self.assertNotIn('migration', variant)
        self.assertNotIn('migration', unicode_variant)
        self.assertEqual(report['conversion_counts'], {'blocked': 1})

    def test_existing_converted_target_is_not_overwritten(self):
        self.archive('mainframe-quick.zip', [])
        candidate = b'candidate fixture bytes\n'
        self.archive('mainframe-persist.zip', [(self.SOURCE, b'--no-abort-on-error\n')])
        report = self.recover()
        target = self.dest / 'home-staging/.config/yt-dlp/config'
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(candidate)
        lr.stage_conversions(report, self.dest)
        self.assertEqual(target.read_bytes(), candidate)
        source_entry = next(e for e in report['entries'] if e['normalized_path'] == self.SOURCE)
        self.assertEqual(source_entry['migration']['reason'], 'conversion-target-conflict')
        self.assertEqual((self.dest / 'recovered/mainframe-persist.zip' / self.SOURCE).read_bytes(),
                         b'--no-abort-on-error\n')


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


class FlameshotMigrationRecoveryTests(unittest.TestCase):
    SOURCE = 'quick-persist/flameshot/flameshot.ini'

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

    def test_exact_quick_export_converts_subset_preserves_raw_and_skips_live_home(self):
        config = (b'[General]\r\nshowHelp=true\r\nuiColor=#ABCDEF\r\n'
                  b'savePath=C:\\Users\\Fixture\\SYNTHETIC_WINDOWS_PATH\r\n'
                  b'uploadClientSecret=SYNTHETIC_CREDENTIAL_MARKER\r\n'
                  b'postCaptureCommand=SYNTHETIC_SCRIPT_MARKER\r\n'
                  b'[Shortcuts]\r\nTAKE_SCREENSHOT=SYNTHETIC_SHORTCUT_MARKER\r\n')
        self.archive('mainframe-quick.zip', [(self.SOURCE, config)])
        self.archive('mainframe-persist.zip', [])
        live = self.root / 'live-home'
        live.mkdir()
        (live / 'sentinel').write_bytes(b'unchanged')
        with patch.dict(os.environ, {'HOME': str(live)}):
            report = self.recover(apply_portable=True, convert_portable=True)

        output = self.dest / 'home-staging/.config/flameshot/flameshot.ini'
        recovered = self.dest / 'recovered/mainframe-quick.zip' / self.SOURCE
        self.assertEqual(output.read_bytes(), FlameshotAdapterTests.HEADER +
                         b'showHelp=true\nuiColor=#abcdef\n')
        self.assertEqual(recovered.read_bytes(), config)
        self.assertEqual(lr.file_hash(self.dest / 'raw-archives/mainframe-quick.zip'),
                         lr.file_hash(self.backup / 'mainframe-quick.zip'))
        self.assertEqual((live / 'sentinel').read_bytes(), b'unchanged')
        entry = next(e for e in report['entries'] if e['normalized_path'] == self.SOURCE)
        self.assertEqual(entry['migration']['accepted_settings'], 2)
        self.assertEqual(entry['migration']['blocked_settings'], 4)
        self.assertEqual(report['conversion_counts'], {'converted-subset': 1})
        self.assertEqual(report['activation_status'], 'not-performed')
        self.assertEqual(report['operational_status'], 'incomplete')
        serialized = json.dumps(report)
        for marker in ('SYNTHETIC_WINDOWS_PATH', 'SYNTHETIC_CREDENTIAL_MARKER',
                       'SYNTHETIC_SCRIPT_MARKER', 'SYNTHETIC_SHORTCUT_MARKER',
                       'C:\\\\Users'):
            self.assertNotIn(marker, serialized)

    def test_apply_portable_stages_only_exact_unconverted_candidate(self):
        config = b'[General]\nshowHelp=false\nsavePath=C:\\Users\\Fixture\\SYNTHETIC_RAW_PATH\n'
        self.archive('mainframe-quick.zip', [
            (self.SOURCE, config),
            ('quick-persist/flameshot/other.ini', b'[General]\nuiColor=#123456\n'),
        ])
        with patch.object(lr, 'convert_flameshot_config',
                          side_effect=AssertionError('candidate copy must not convert')):
            report = self.recover(mode='quick', apply_portable=True)
        candidate = self.dest / 'home-staging/.config/flameshot/flameshot.ini'
        self.assertEqual(candidate.read_bytes(), config)
        self.assertEqual((self.dest / 'recovered/mainframe-quick.zip' / self.SOURCE).read_bytes(),
                         config)
        self.assertFalse((self.dest / 'home-staging/.config/flameshot/other.ini').exists())
        self.assertEqual(report['conversion_status'], 'not-requested')

    def test_nonexact_persist_and_quick_paths_never_reach_adapter_or_staging(self):
        self.archive('mainframe-quick.zip', [
            ('quick-persist/flameshot/other.ini', b'[General]\nshowHelp=true\n'),
            ('quick-persist/Flameshot/flameshot.ini', b'[General]\nuiColor=#123456\n'),
        ])
        self.archive('mainframe-persist.zip', [
            ('persist/flameshot/flameshot.ini', b'[General]\nshowHelp=true\n'),
        ])
        with patch.object(lr, 'convert_flameshot_config',
                          side_effect=AssertionError('nonexact path must not parse')):
            report = self.recover(apply_portable=True, convert_portable=True)
        self.assertFalse((self.dest / 'home-staging/.config/flameshot').exists())
        self.assertEqual(report['conversion_counts'], {})
        self.assertTrue(all(e['category'] == 'blocked' for e in report['entries']))

    def test_quick_full_duplicate_source_has_no_winner(self):
        self.archive('mainframe-quick.zip', [(self.SOURCE, b'[General]\nshowHelp=true\n')])
        self.archive('mainframe-persist.zip', [(self.SOURCE, b'[General]\nshowHelp=false\n')])
        with patch.object(lr, 'convert_flameshot_config',
                          side_effect=AssertionError('duplicate source must not parse')):
            report = self.recover(convert_portable=True)
        self.assertFalse((self.dest / 'home-staging/.config/flameshot/flameshot.ini').exists())
        self.assertEqual(report['conversion_counts'], {'blocked': 2})
        self.assertTrue(all(e['migration']['reason'] == 'conversion-target-conflict'
                            for e in report['entries']))

    def test_casefold_alias_blocks_exact_source_without_parsing_alias(self):
        alias = 'quick-persist/Flameshot/flameshot.ini'
        self.archive('mainframe-quick.zip', [(self.SOURCE, b'[General]\nshowHelp=true\n')])
        self.archive('mainframe-persist.zip', [(alias, b'[General]\nshowHelp=false\n')])
        with patch.object(lr, 'convert_flameshot_config',
                          side_effect=AssertionError('ambiguous source must not parse')):
            report = self.recover(convert_portable=True)
        self.assertFalse((self.dest / 'home-staging/.config/flameshot/flameshot.ini').exists())
        self.assertEqual(report['conversion_counts'], {'blocked': 1})
        exact = next(e for e in report['entries'] if e['normalized_path'] == self.SOURCE)
        variant = next(e for e in report['entries'] if e['normalized_path'] == alias)
        self.assertEqual(exact['migration']['reason'], 'conversion-target-conflict')
        self.assertNotIn('migration', variant)

    def test_existing_converted_target_is_never_overwritten(self):
        self.archive('mainframe-quick.zip', [(self.SOURCE, b'[General]\nuiColor=#abcdef\n')])
        report = self.recover(mode='quick')
        target = self.dest / 'home-staging/.config/flameshot/flameshot.ini'
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(b'candidate fixture bytes\n')
        lr.stage_conversions(report, self.dest)
        self.assertEqual(target.read_bytes(), b'candidate fixture bytes\n')
        entry = next(e for e in report['entries'] if e['normalized_path'] == self.SOURCE)
        self.assertEqual(entry['migration']['reason'], 'conversion-target-conflict')
        self.assertEqual((self.dest / 'recovered/mainframe-quick.zip' / self.SOURCE).read_bytes(),
                         b'[General]\nuiColor=#abcdef\n')


if __name__ == '__main__':
    unittest.main()
