"""Synthetic regressions; never open real backups or invoke package installers."""
import json
import subprocess
import sys
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).parents[1]))
import linux_packages as lp
import linux_restore as lr

ROOT = Path(__file__).parents[1]


class PipSnapshotRetirementTests(unittest.TestCase):
    def repo(self, root):
        for name, key, values in (
            ('scoop-allowed.json', 'apps', ['curl', 'python312']),
            ('winget-allowed.json', 'packages', [{'id': 'Synthetic.Tool'}]),
            ('pnpm-allowed.json', 'packages', ['synthetic-tool']),
            ('uv-allowed.json', 'packages', ['synthetic-tool']),
            ('go-allowed.json', 'packages', ['example.invalid/tool']),
        ):
            (root / name).write_text(json.dumps({key: values}))

    def plan(self, repo, backup=None):
        return lp.build_plan(repo, backup_root=backup, distro='ubuntu', architecture='x86_64')

    def test_legacy_snapshot_never_read_planned_reported_or_changed(self):
        with TemporaryDirectory() as d:
            repo = Path(d) / 'repo'
            backup = Path(d) / 'backup'
            repo.mkdir()
            backup.mkdir()
            self.repo(repo)
            expected_repo = self.plan(repo).to_dict()
            expected_backup = self.plan(repo, backup).to_dict()
            # Invalid UTF-8 proves no decoder reads this retired input. The option
            # is synthetic; real index URLs/package inventories are never fixtures.
            original = b'\xff\xfe\r\n--extra-index-url https://snapshot.invalid/simple\r\n'
            for root in (repo, backup):
                manifest = root / 'pip-freeze.txt'
                manifest.write_bytes(original)
                with patch.object(lp, 'host_info', return_value=('ubuntu', 'x86_64')), \
                        patch.object(Path, 'read_text', side_effect=AssertionError('snapshot read forbidden')):
                    plan = self.plan(repo, backup if root == backup else None)
                self.assertEqual(plan.to_dict(), expected_backup if root == backup else expected_repo)
                self.assertEqual(manifest.read_bytes(), original)
                self.assertFalse(any(a.kind.startswith('pip-') for a in plan.actions))
                self.assertNotIn('snapshot.invalid', json.dumps(plan.to_dict()))
                self.assertNotIn('pip-freeze.txt', json.dumps(plan.to_dict()))
                self.assertIn('python312', {a.name for a in plan.actions})

    def test_empty_missing_snapshot_and_backup_requirements_not_required_or_consumed(self):
        with TemporaryDirectory() as d:
            repo = Path(d) / 'repo'
            backup = Path(d) / 'backup'
            repo.mkdir()
            backup.mkdir()
            self.repo(repo)
            expected = self.plan(repo, backup).to_dict()
            (backup / 'pip-freeze.txt').write_bytes(b'')
            (backup / 'requirements.txt').write_bytes(b'\xff')
            (backup / 'requirements-linux.txt').write_bytes(b'\xff')
            self.assertEqual(expected, self.plan(repo, backup).to_dict())

    def test_curated_repository_requirements_support_remains_fail_closed(self):
        with TemporaryDirectory() as d:
            repo = Path(d)
            self.repo(repo)
            (repo / 'requirements-linux.txt').write_text('synthetic-future-tool==1.0\n')
            plan = self.plan(repo)
            backup = repo / 'backup'
            backup.mkdir()
            (backup / 'pip-freeze.txt').write_bytes(b'\xff')
            self.assertEqual(plan.to_dict(), self.plan(repo, backup).to_dict())
            pip = [a for a in plan.actions if a.kind.startswith('pip-')]
            self.assertEqual({a.kind for a in pip}, {'pip-venv', 'pip-install'})
            self.assertTrue(all(a.status == 'blocked' for a in pip))
            runner = Mock(side_effect=AssertionError('must not execute'))
            with patch.object(lp, 'host_info', return_value=('ubuntu', 'x86_64')):
                with self.assertRaises(RuntimeError):
                    lp.execute(plan, ['curl', 'requirements-linux.txt'], runner=runner)
            runner.assert_not_called()

    def test_stale_snapshot_selection_fails_before_any_command(self):
        plan = lp.Plan(True, 'ubuntu', 'x86_64', [lp.Action('apt', 'curl', ['apt-get', 'install', 'curl'])])
        runner = Mock(side_effect=AssertionError('must not execute'))
        with patch.object(lp, 'host_info', return_value=('ubuntu', 'x86_64')):
            with self.assertRaisesRegex(RuntimeError, 'Unknown'):
                lp.execute(plan, ['curl', 'pip-freeze.txt'], runner=runner)
        runner.assert_not_called()

    def test_forged_pip_install_fails_before_earlier_apt_action(self):
        actions = [lp.Action('apt', 'curl', ['apt-get', 'install', 'curl']),
                   lp.Action('pip-install', 'pip-freeze.txt', ['pip', 'install', '-r', 'pip-freeze.txt'])]
        runner = Mock(side_effect=AssertionError('must not execute'))
        with patch.object(lp, 'host_info', return_value=('ubuntu', 'x86_64')):
            with self.assertRaisesRegex(RuntimeError, 'Unvalidated'):
                lp.execute(lp.Plan(True, 'ubuntu', 'x86_64', actions), runner=runner)
        runner.assert_not_called()

    def test_legacy_snapshot_stays_control_metadata_not_user_data(self):
        self.assertIn('pip-freeze.txt', lr.CONTROL_FILES)
        for name in ('pip-freeze.txt', 'UserProfile/pip-freeze.txt', 'repos/example/pip-freeze.txt'):
            category, reason, target = lr.classify(name)
            self.assertEqual(category, 'metadata')
            self.assertIsNone(target)
            self.assertIn('no command is executed', reason)

    def test_windows_no_capture_or_frozen_install_step(self):
        backup = (ROOT / 'backup.ps1').read_text()
        restore = (ROOT / 'restore.ps1').read_text()
        self.assertNotIn('pip-freeze.txt', backup)
        self.assertNotIn('$pipFreezeFile', backup + restore)
        self.assertNotIn('$freezeLines', backup)
        self.assertNotRegex(backup, r'(?im)^\s*[^#\n]*\bpip\s+(?:list|freeze)\b')
        self.assertNotIn("Update-Step 'Installing pip packages'", restore)
        self.assertNotIn('$pipCmd.Source install', restore)
        # Retiring a snapshot does not strip Python persistence or its tooling.
        self.assertIn("$item.Name -eq 'python312'", backup)
        self.assertIn("'/XD', 'site-packages'", backup)


if __name__ == '__main__':
    unittest.main()
