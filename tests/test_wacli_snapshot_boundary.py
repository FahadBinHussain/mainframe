"""Counterexamples, not a capture backend; all inputs are disposable fixtures."""
from __future__ import annotations

from contextlib import ExitStack, closing
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).parents[1]))
import wacli_snapshot as snapshot
from wacli_snapshot_stage import _prepare_staged_snapshot


def database(stack, path, mode='DELETE'):
    con = stack.enter_context(closing(sqlite3.connect(path)))
    actual = con.execute('PRAGMA journal_mode=' + mode).fetchone()[0]
    if actual.upper() != mode:
        raise AssertionError('fixture journal mode not established')
    con.execute('CREATE TABLE synthetic_epoch(value INTEGER NOT NULL)')
    con.execute('INSERT INTO synthetic_epoch VALUES (0)')
    con.commit()
    return con


def copy_database(source, path):
    with closing(sqlite3.connect(path)) as destination:
        source.backup(destination)


def epoch(path):
    with closing(sqlite3.connect(path)) as con:
        if con.execute('PRAGMA integrity_check').fetchall() != [('ok',)]:
            raise AssertionError('fixture database integrity failed')
        return con.execute('SELECT value FROM synthetic_epoch').fetchone()[0]


class SnapshotBoundaryCounterexamples(unittest.TestCase):
    """Demonstrate unsafe source combinations without authorizing capture."""

    def assert_uncertified(self, receipt):
        """Require preparation to retain every fail-closed capability marker."""
        self.assertEqual(receipt['status'], 'PREPARATION')
        self.assertEqual(receipt['boundary'], 'UNVERIFIED')
        self.assertEqual(receipt['cross_database_consistency'], 'NOT_CERTIFIED')
        self.assertEqual(receipt['raw_complete'], 'supplied-stage-only')
        self.assertIsNone(receipt['capture_attestation'])
        for key in ('complete', 'publishable', 'windows_validated'):
            self.assertIs(receipt[key], False)
        self.assertFalse(snapshot.capture_status()['capture_enabled'])

    def test_valid_sequential_backups_can_form_a_pair_that_never_existed(self):
        # No threads or sleeps: the interleaving is explicit and deterministic.
        for mode in ('DELETE', 'WAL'):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as temporary, ExitStack() as stack:
                root = Path(temporary)
                live = root / 'synthetic-writers'; live.mkdir(mode=0o700)
                stage = root / 'private-stage'; stage.mkdir(mode=0o700)
                session = database(stack, live / 'session.db', mode)
                messages = database(stack, live / 'wacli.db', mode)
                observed = [(0, 0)]
                copy_database(session, stage / 'session.db')
                session.execute('UPDATE synthetic_epoch SET value=1'); session.commit()
                observed.append((1, 0))
                messages.execute('UPDATE synthetic_epoch SET value=1'); messages.commit()
                observed.append((1, 1))
                copy_database(messages, stage / 'wacli.db')
                torn_pair = (epoch(stage / 'session.db'), epoch(stage / 'wacli.db'))
                self.assertEqual(torn_pair, (0, 1))
                self.assertNotIn(torn_pair, observed)
                # Stable hashes and successful recovery cannot repair an earlier tear.
                receipt = _prepare_staged_snapshot(stage, root / 'prepared')
                self.assert_uncertified(receipt)
                self.assertEqual((epoch(root / 'prepared/derived/session.db'),
                                  epoch(root / 'prepared/derived/wacli.db')), torn_pair)

    def test_valid_database_and_media_copy_can_have_different_epochs(self):
        with tempfile.TemporaryDirectory() as temporary, ExitStack() as stack:
            root = Path(temporary)
            stage = root / 'private-stage'; stage.mkdir(mode=0o700)
            session = database(stack, root / 'synthetic-session.db')
            messages = database(stack, root / 'synthetic-wacli.db')
            media = root / 'synthetic-media.bin'; media.write_bytes(b'epoch-zero')
            copy_database(session, stage / 'session.db')
            copy_database(messages, stage / 'wacli.db')
            messages.execute('UPDATE synthetic_epoch SET value=1'); messages.commit()
            media.write_bytes(b'epoch-one')
            (stage / 'media.bin').write_bytes(media.read_bytes())
            receipt = _prepare_staged_snapshot(stage, root / 'prepared')
            self.assert_uncertified(receipt)
            self.assertEqual(epoch(root / 'prepared/derived/wacli.db'), 0)
            self.assertEqual((root / 'prepared/originals/media.bin').read_bytes(), b'epoch-one')

    def test_tree_preservation_does_not_certify_external_media_membership(self):
        with tempfile.TemporaryDirectory() as temporary, ExitStack() as stack:
            root = Path(temporary)
            stage = root / 'private-stage'; stage.mkdir(mode=0o700)
            database(stack, stage / 'session.db')
            messages = database(stack, stage / 'wacli.db')
            external = root / 'synthetic-external-media.bin'
            external.write_bytes(b'external-fixture-only')
            # Deliberately generic schema: this tests preservation, NOT WACLI schema compatibility.
            messages.execute('CREATE TABLE synthetic_media_reference(local_path TEXT)')
            messages.execute('INSERT INTO synthetic_media_reference VALUES (?)', (str(external),))
            messages.commit()
            receipt = _prepare_staged_snapshot(stage, root / 'prepared')
            self.assert_uncertified(receipt)
            members = {member['path'] for member in receipt['raw_members']}
            self.assertNotIn(external.name, members)
            self.assertEqual(external.read_bytes(), b'external-fixture-only')
            with closing(sqlite3.connect(root / 'prepared/derived/wacli.db')) as con:
                self.assertEqual(con.execute('SELECT local_path FROM synthetic_media_reference').fetchone(),
                                 (str(external),))

    def test_reference_preservation_is_not_media_resolution_or_relocation(self):
        """Preserve reference rows without resolving missing or external bytes."""
        with tempfile.TemporaryDirectory() as temporary, ExitStack() as stack:
            root = Path(temporary)
            stage = root / 'private-stage'; stage.mkdir(mode=0o700)
            database(stack, stage / 'session.db')
            messages = database(stack, stage / 'wacli.db')
            missing = root / 'missing-local.bin'
            external = root / 'external-local.bin'; external.write_bytes(b'external')
            alias = root / 'external-alias.bin'; alias.write_bytes(b'alias')
            output_only = root / 'unreferenced-output.bin'; output_only.write_bytes(b'output-only')
            # Generic fixture schema, NOT a WACLI media parser or migration test.
            # A NULL path represents remote-only, not proof of remotely available bytes.
            references = [('remote-only', None), ('missing-local', str(missing)),
                          ('external-local', str(external)), ('local-alias', str(alias))]
            messages.execute('CREATE TABLE synthetic_media_membership(kind TEXT, local_path TEXT)')
            messages.executemany('INSERT INTO synthetic_media_membership VALUES (?, ?)', references)
            messages.commit()
            receipt = _prepare_staged_snapshot(stage, root / 'prepared')
            self.assert_uncertified(receipt)
            with closing(sqlite3.connect(root / 'prepared/derived/wacli.db')) as con:
                self.assertEqual(con.execute('SELECT kind, local_path FROM synthetic_media_membership '
                                             'ORDER BY rowid').fetchall(), references)
            # Preparation neither discovers external/alias/output-only bytes nor repairs
            # missing local bytes, downloads remote-only data, or relocates references.
            self.assertFalse(missing.exists())
            for path, content in ((external, b'external'), (alias, b'alias'),
                                  (output_only, b'output-only')):
                self.assertEqual(path.read_bytes(), content)
                self.assertNotIn(path.name, {member['path'] for member in receipt['raw_members']})
                self.assertFalse((root / 'prepared/originals' / path.name).exists())


if __name__ == '__main__':
    unittest.main()
