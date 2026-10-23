import json
import sys
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).parents[1]))
import linux_packages as lp


class PipPlatformTests(unittest.TestCase):
    def actions(self, root):
        blockers = []
        actions = lp._requirements_actions(root, blockers, require_pip_freeze=True)
        self.assertEqual(len(actions), 1)
        self.assertEqual(len(blockers), 1)
        action = actions[0]
        self.assertEqual(action.name, 'pip-freeze.txt')
        self.assertEqual(action.source, str(root / 'pip-freeze.txt'))
        self.assertEqual(action.status, 'blocked')
        self.assertIsNone(action.command)
        self.assertIn('pywin32-ctypes wraps Windows DLL APIs', action.reason)
        self.assertIn('no exclusion or substitute is approved', action.reason)
        return actions, blockers

    def test_exact_manifest_bytes_preserved_and_no_package_filtered(self):
        original = (b'# synthetic fixture\r\nrequests==2.32.0\r\n'
                    b'pywin32-ctypes==0.2.3\r\nidna==3.10\r\n')
        with TemporaryDirectory() as d:
            root = Path(d)
            manifest = root / 'pip-freeze.txt'
            manifest.write_bytes(original)
            before = set(root.iterdir())
            self.actions(root)
            self.assertEqual(manifest.read_bytes(), original)
            self.assertEqual(set(root.iterdir()), before)

    def test_normalized_project_names_and_markers_remain_blocked(self):
        for requirement in ('PyWin32_Ctypes==0.2.3', 'pywin32.ctypes==0.2.3',
                            'pywin32-ctypes[example]>=0.2.3',
                            'pywin32-ctypes==0.2.3; sys_platform == "win32"'):
            with self.subTest(requirement=requirement), TemporaryDirectory() as d:
                root = Path(d)
                original = (requirement + '\n').encode()
                manifest = root / 'pip-freeze.txt'
                manifest.write_bytes(original)
                self.actions(root)
                self.assertEqual(manifest.read_bytes(), original)

    def test_raw_requirement_and_index_details_not_reported(self):
        with TemporaryDirectory() as d:
            root = Path(d)
            original = ('--extra-index-url https://synthetic-user:synthetic-token@private.invalid/simple\n'
                        'pywin32_ctypes @ https://private.invalid/private-artifact.whl\n')
            (root / 'pip-freeze.txt').write_text(original)
            actions, blockers = self.actions(root)
            report = json.dumps(lp.Plan(True, 'ubuntu', 'x86_64', actions, blockers).to_dict())
            for private in ('synthetic-user', 'synthetic-token', 'private.invalid', 'private-artifact'):
                self.assertNotIn(private, report)

    def test_selected_pip_and_earlier_apt_rejected_before_any_command(self):
        with TemporaryDirectory() as d:
            root = Path(d)
            (root / 'pip-freeze.txt').write_bytes(b'pywin32-ctypes==0.2.3\n')
            actions, blockers = self.actions(root)
            apt = lp.Action('apt', 'curl', ['apt-get', 'install', '-y', 'curl'])
            plan = lp.Plan(True, 'ubuntu', 'x86_64', [apt] + actions, blockers)
            runner = Mock(side_effect=AssertionError('must not run'))
            with patch.object(lp, 'host_info', return_value=('ubuntu', 'x86_64')):
                with self.assertRaises(RuntimeError):
                    lp.execute(plan, ['curl', 'pip-freeze.txt'], runner=runner)
            runner.assert_not_called()

    def test_similarly_named_package_does_not_get_windows_api_diagnostic(self):
        with TemporaryDirectory() as d:
            root = Path(d)
            (root / 'pip-freeze.txt').write_text('pywin32-ctypes-helper==1.0\n')
            blockers = []
            actions = lp._requirements_actions(root, blockers, require_pip_freeze=True)
            self.assertTrue(all(a.status == 'blocked' for a in actions))
            self.assertNotIn('wraps Windows DLL APIs', ' '.join(blockers))
            self.assertIn('interpreter', blockers[0])


if __name__ == '__main__':
    unittest.main()
