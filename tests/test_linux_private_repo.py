import json, os, subprocess, sys, tempfile, time, unittest
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).parents[1]))
import linux_real as lr

TOKEN = 'fake-vault-token-not-a-real-secret'


def fake_git(result=0, stderr='', stdout=''):
    """Capture the git command instead of running it."""
    calls = []

    def _run(cmd, env=None, check=True, input_text=None):
        calls.append({'cmd': list(cmd), 'env': dict(env or {})})
        return subprocess.CompletedProcess(list(cmd), result, stdout, stderr)

    return calls, _run


class PrivateRepoTests(unittest.TestCase):
    """The live Linux flow must sync automata-private the way the Windows
    restore does: named credential source, loud failure, no silent skip."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.work = self.tmp / 'work'
        self.work.mkdir(parents=True)
        self.dest = self.tmp / 'home' / 'Downloads' / 'automata-private'
        self.dest.parent.mkdir(parents=True)

    def sync(self, token=TOKEN, result=0, stderr='', gh=None):
        calls, runner = fake_git(result, stderr)
        which = (lambda name: gh) if gh else (lambda name: None)
        with patch.object(lr, 'private_repo_dir', return_value=self.dest), \
             patch.object(lr.shutil, 'which', side_effect=which), \
             patch.object(lr, 'run', runner):
            return calls, lr.sync_automata_private(self.work, token)

    def test_destination_is_the_same_downloads_root_the_public_checkout_uses(self):
        dest = lr.private_repo_dir()
        self.assertEqual(dest.name, 'automata-private')
        self.assertEqual(dest.parent.name, 'Downloads')
        self.assertEqual(dest.parent.parent, Path.home())

    def test_clone_uses_the_named_credential_source_and_never_the_token_in_argv(self):
        calls, report = self.sync()
        cmd = calls[0]['cmd']
        self.assertEqual(cmd[0], 'git')
        self.assertIn('clone', cmd)
        self.assertEqual(cmd[-1], str(self.dest))
        self.assertIn(lr.PRIVATE_REPO_URL, cmd)
        self.assertIn('credential.helper=', cmd)
        self.assertNotIn(TOKEN, ' '.join(cmd))
        self.assertEqual(calls[0]['env']['MF_GH_TOKEN'], TOKEN)
        self.assertEqual(calls[0]['env']['GIT_TERMINAL_PROMPT'], '0')
        self.assertEqual(report['action'], 'cloned')
        self.assertEqual(report['credential_source'], 'a private credential helper')

    def test_gh_is_preferred_when_it_is_installed(self):
        calls, report = self.sync(gh='/usr/bin/gh')
        cmd = calls[0]['cmd']
        self.assertIn('credential.helper=!gh auth git-credential', cmd)
        self.assertEqual(calls[0]['env']['GH_TOKEN'], TOKEN)
        self.assertNotIn('MF_GH_TOKEN', calls[0]['env'])
        self.assertEqual(report['credential_source'], 'the GH_TOKEN github profile')

    def test_an_existing_checkout_is_pulled_not_cloned(self):
        (self.dest / '.git').mkdir(parents=True)
        calls, report = self.sync()
        cmd = calls[0]['cmd']
        self.assertIn('pull', cmd)
        self.assertIn('--ff-only', cmd)
        self.assertNotIn('clone', cmd)
        self.assertEqual(report['action'], 'pulled')

    def test_a_directory_that_is_not_a_checkout_is_refused(self):
        self.dest.mkdir(parents=True)
        with self.assertRaisesRegex(RuntimeError, 'not a git checkout'):
            self.sync()

    def test_a_failed_sync_names_the_credential_source_and_the_repo(self):
        with self.assertRaises(RuntimeError) as ctx:
            self.sync(result=128, stderr="fatal: Authentication failed for "
                                        "'https://github.com/FahadBinHussain/"
                                        "automata-private.git/'")
        message = str(ctx.exception)
        self.assertIn('automata-private sync failed (git exit 128)', message)
        self.assertIn('a private credential helper', message)
        self.assertIn(lr.PRIVATE_REPO_URL, message)
        self.assertIn('Authentication failed', message)

    def test_without_a_token_the_machine_credentials_are_used_and_said_so(self):
        calls, report = self.sync(token='')
        cmd = calls[0]['cmd']
        self.assertNotIn('-c', cmd)
        self.assertNotIn('MF_GH_TOKEN', calls[0]['env'])
        self.assertNotIn('GH_TOKEN', calls[0]['env'])
        self.assertIn('machine', report['credential_source'])

    def test_the_helper_answers_get_from_the_environment_only(self):
        helper = lr.write_credential_helper(self.work)
        body = helper.read_text(encoding='utf-8')
        self.assertNotIn(TOKEN, body)
        env = dict(os.environ, MF_GH_TOKEN=TOKEN)
        got = subprocess.run([sys.executable, str(helper), 'get'], env=env,
                              capture_output=True, text=True)
        self.assertEqual(got.stdout,
                         'username=x-access-token\npassword=%s\n' % TOKEN)
        empty = subprocess.run([sys.executable, str(helper), 'get'],
                               env={k: v for k, v in os.environ.items()
                                    if k != 'MF_GH_TOKEN'},
                               capture_output=True, text=True)
        self.assertEqual(empty.stdout, '')
        store = subprocess.run([sys.executable, str(helper), 'store'], env=env,
                               capture_output=True, text=True)
        self.assertEqual(store.stdout, '')


class RestoreLegTests(unittest.TestCase):
    """The private checkout is a hard requirement of the restore leg, the
    same way the Windows restore treats it."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.backup = self.tmp / 'release'
        self.backup.mkdir(parents=True)
        (self.backup / 'mainframe-quick.zip').write_bytes(b'PK\x05\x06' + b'\x00' * 18)

    def leg(self, sync=None, skip=False):
        restored = []

        def _restore(backup_root, work_root, yes, restore_global_agents):
            restored.append(str(backup_root))
            return {'staged': []}

        sync = sync or (lambda work_root, token: {'path': '/x', 'repo': 'r',
                                                   'credential_source': 's',
                                                   'action': 'cloned'})
        with patch.object(lr, 'sync_automata_private', sync), \
             patch.object(lr, 'run_restore', _restore):
            report, failures = lr.run_restore_leg(
                self.backup, self.tmp / 'work', yes=True,
                restore_global_agents=False, skip_private_repo=skip,
                gh_token=TOKEN)
            return report, failures, restored

    def test_a_successful_sync_runs_the_restore(self):
        report, failures, restored = self.leg()
        self.assertEqual(failures, [])
        self.assertEqual(report['private_repo']['action'], 'cloned')
        self.assertIn('restore', report)
        self.assertEqual(len(restored), 1)

    def test_a_failed_sync_aborts_the_restore_loudly(self):
        def boom(work_root, token):
            raise RuntimeError('automata-private sync failed (git exit 128)')

        report, failures, restored = self.leg(sync=boom)
        self.assertEqual(restored, [])
        self.assertEqual(len(failures), 1)
        self.assertIn('private repo:', failures[0])
        self.assertNotIn('restore', report)

    def test_the_skip_flag_is_explicit_and_still_restores(self):
        report, failures, restored = self.leg(skip=True)
        self.assertEqual(failures, [])
        self.assertNotIn('private_repo', report)
        self.assertEqual(len(restored), 1)

    def test_without_a_backup_root_nothing_runs(self):
        report, failures = lr.run_restore_leg(
            None, self.tmp / 'work', yes=True, restore_global_agents=False,
            skip_private_repo=False, gh_token=TOKEN)
        self.assertEqual(failures, [])
        self.assertEqual(report, {})


class ConfigAndTimeoutTests(unittest.TestCase):
    """Two defects the live container run exposed: a powershell-written config
    carries a UTF-8 BOM, and a hung apt-get blocked the whole flow."""

    def test_a_bom_config_still_loads(self):
        tmp = Path(tempfile.mkdtemp())
        cfg = tmp / "mainframe.config.json"
        # exactly what powershell's Set-Content -Encoding utf8 writes
        cfg.write_bytes(b"\xef\xbb\xbf" + json.dumps(
            {"ntfyTopic": "topic-not-real", "bitwardenEmail": "a@b.c"}
        ).encode("utf-8"))
        with patch.object(lr, "Path", Path):
            data = lr.load_config(tmp)
        self.assertEqual(data.get("ntfyTopic"), "topic-not-real")
        self.assertEqual(data.get("bitwardenEmail"), "a@b.c")

    def test_a_plain_config_still_loads(self):
        tmp = Path(tempfile.mkdtemp())
        (tmp / "mainframe.config.json").write_text(
            json.dumps({"ntfyTopic": "topic-not-real"}), encoding="utf-8")
        data = lr.load_config(tmp)
        self.assertEqual(data.get("ntfyTopic"), "topic-not-real")

    def test_the_ntfy_topic_resolves_from_a_bom_config(self):
        tmp = Path(tempfile.mkdtemp())
        (tmp / "mainframe.config.json").write_bytes(
            b"\xef\xbb\xbf" + json.dumps({"ntfyTopic": "topic-not-real"}).encode())
        self.assertEqual(lr.get_ntfy_topic(tmp), "topic-not-real")

    def test_a_hung_command_times_out_loudly(self):
        start = time.time()
        with self.assertRaises(RuntimeError) as ctx:
            lr.run([sys.executable, "-c", "import time; time.sleep(30)"], timeout=1)
        self.assertIn("timed out after 1s", str(ctx.exception))
        self.assertLess(time.time() - start, 20)

    def test_the_apt_legs_are_bounded(self):
        self.assertGreater(lr.APT_UPDATE_TIMEOUT_SECONDS, 0)
        self.assertGreater(lr.APT_INSTALL_TIMEOUT_SECONDS,
                           lr.APT_UPDATE_TIMEOUT_SECONDS)


if __name__ == '__main__':
    unittest.main()
