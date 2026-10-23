"""Synthetic, filesystem-only tests for the WACLI snapshot preparation boundary."""
from __future__ import annotations

import hashlib
import json
import os
import sqlite3
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import sys
sys.path.insert(0, str(Path(__file__).parents[1]))
import wacli_snapshot_stage as stage
from wacli_snapshot_stage import SnapshotStageError, StageLimits, stage_snapshot


class SnapshotStageTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="wacli-stage-test-")
        self.root = Path(self.tmp.name)
        self.connections: list[sqlite3.Connection] = []

    def tearDown(self):
        for con in self.connections:
            try:
                con.close()
            except sqlite3.Error:
                pass
        self.tmp.cleanup()

    def make_pair(self, root: Path | None = None, *, wal: bool = True) -> Path:
        """Build one pair once, retain both connections, and leave WAL bytes live."""
        root = root or self.root / "source"
        root.mkdir(parents=True, exist_ok=False)
        for name in ("session.db", "wacli.db"):
            con = sqlite3.connect(root / name)
            self.connections.append(con)
            if wal:
                self.assertEqual(con.execute("PRAGMA journal_mode=WAL").fetchone()[0], "wal")
                con.execute("PRAGMA wal_autocheckpoint=0")
            con.execute("PRAGMA user_version=7")
            con.execute("PRAGMA application_id=1234")
            con.execute("CREATE TABLE data (id INTEGER PRIMARY KEY, payload BLOB)")
            con.execute("CREATE TABLE schema_migrations (version INTEGER)")
            con.execute("CREATE TABLE whatsmeow_version (version INTEGER, compat INTEGER)")
            con.execute("CREATE TABLE mystery (value TEXT)")
            con.execute("CREATE INDEX mystery_idx ON mystery(value)")
            con.execute("CREATE TRIGGER mystery_trigger AFTER INSERT ON mystery BEGIN UPDATE data SET payload=payload WHERE id=1; END")
            con.execute("CREATE VIEW mystery_view AS SELECT id, payload FROM data")
            con.execute("INSERT INTO schema_migrations VALUES (7)")
            con.execute("INSERT INTO whatsmeow_version VALUES (1, NULL)")
            con.execute("INSERT INTO data VALUES (?,?)", (1, b"binary\x00fixture\xff"))
            con.execute("INSERT INTO mystery VALUES ('unknown-table-row')")
            try:
                con.execute("CREATE VIRTUAL TABLE search USING fts5(payload)")
                con.execute("INSERT INTO search VALUES ('retained wal text')")
            except sqlite3.OperationalError as exc:
                if 'no such module: fts5' not in str(exc):
                    raise
            con.commit()
            # A second committed transaction ensures data remains in the retained WAL.
            con.execute("INSERT INTO data VALUES (?,?)", (2, b"second\x00row"))
            con.commit()
        (root / "media.bin").write_bytes(b"opaque media\x00\xff")
        nested = root / "empty" / "deep"
        nested.mkdir(parents=True)
        (root / "nested" / "payload.bin").parent.mkdir()
        (root / "nested" / "payload.bin").write_bytes(bytes(range(256)))
        (root / "unknown.sidecar").write_bytes(b"unknown")
        return root

    def source_bytes(self, root: Path) -> dict[str, bytes]:
        return {p.relative_to(root).as_posix(): p.read_bytes() for p in root.rglob("*") if p.is_file()}

    def stage(self, source: Path | None = None, name: str = "out", **kw):
        return stage_snapshot(source or self.root / "source", self.root / name, **kw)

    def assertFailure(self, fn):
        with self.assertRaises(SnapshotStageError) as cm:
            fn()
        self.assertNotIn(str(self.root), str(cm.exception))
        self.assertNotIn("binary", str(cm.exception))

    def test_retained_wal_pair_is_byte_exact_and_source_unchanged(self):
        src = self.make_pair()
        before = self.source_bytes(src)
        out = self.stage()
        self.assertEqual(out["status"], "PREPARATION")
        self.assertFalse(out["publishable"])
        self.assertEqual(out["raw_complete"], "supplied-stage-only")
        self.assertEqual(out["boundary"], "UNVERIFIED")
        self.assertEqual(out["provenance"], "UNVERIFIED")
        self.assertEqual(out["cross_database_consistency"], "NOT_CERTIFIED")
        for rel, content in before.items():
            self.assertEqual((self.root / "out" / "originals" / rel).read_bytes(), content)
        self.assertTrue((self.root / "out" / "originals" / "empty" / "deep").is_dir())
        raw_paths = {item["path"] for item in out["raw_members"]}
        self.assertIn("empty/deep", raw_paths)
        self.assertEqual(before, self.source_bytes(src))
        self.assertTrue((src / "session.db-wal").exists() or (src / "session.db-shm").exists())

    def test_derived_recovers_binary_rows_and_optional_fts(self):
        self.make_pair()
        receipt = self.stage()
        for name in ("session.db", "wacli.db"):
            con = sqlite3.connect(self.root / "out" / "derived" / name)
            self.assertEqual(con.execute("SELECT payload FROM data WHERE id=1").fetchone()[0], b"binary\x00fixture\xff")
            self.assertEqual(con.execute("SELECT payload FROM data WHERE id=2").fetchone()[0], b"second\x00row")
            if self.connections[0].execute("SELECT 1 FROM sqlite_master WHERE name='search'").fetchone():
                self.assertTrue(con.execute("SELECT rowid FROM search WHERE search MATCH 'retained'").fetchone())
            con.close()
        serialized = json.dumps(receipt, sort_keys=True)
        self.assertNotIn("binary\u0000fixture", serialized)
        self.assertNotIn("unknown-table-row", serialized)

    def test_unknown_schema_objects_and_metadata_rows_are_retained_in_derived(self):
        self.make_pair()
        receipt = self.stage()
        md = receipt["derived"]["wacli.db"]["metadata"]
        names = {d["name"] for d in md["schema_definitions"]}
        self.assertTrue({"mystery", "mystery_idx", "mystery_trigger", "mystery_view"} <= names)
        self.assertEqual(md["schema_migrations"], {"columns": ["version"], "rows": [[7]]})
        self.assertEqual(md["whatsmeow_version"], {"columns": ["version", "compat"], "rows": [[1, None]]})
        self.assertEqual(md["user_version"], 7)

    def test_receipt_is_written_and_raw_members_have_digests(self):
        self.make_pair()
        receipt = self.stage()
        self.assertEqual(json.loads((self.root / "out" / "receipt.json").read_text()), receipt)
        for item in receipt["raw_members"]:
            raw = self.root / "out" / "originals" / item["path"]
            if item["type"] == "directory":
                self.assertTrue(raw.is_dir())
            else:
                self.assertEqual(item["size"], raw.stat().st_size)
                self.assertEqual(item["sha256"], hashlib.sha256(raw.read_bytes()).hexdigest())
        if os.name != "nt":
            self.assertEqual(stat.S_IMODE((self.root / "out").stat().st_mode), 0o700)

    def test_missing_pair_and_corrupt_pair_leave_no_output(self):
        src = self.root / "source"; src.mkdir()
        (src / "session.db").write_bytes(b"not sqlite")
        self.assertFailure(lambda: self.stage(src))
        self.assertFalse((self.root / "out").exists())
        src2 = self.root / "source2"; self.make_pair(src2, wal=False)
        (src2 / "wacli.db").write_bytes(b"bad-secret-payload")
        self.assertFailure(lambda: self.stage(src2, "out2"))
        self.assertFalse((self.root / "out2").exists())
        self.assertFalse(list(self.root.glob(".wacli-stage-*")))

    def test_rejects_relative_and_parent_destination_paths(self):
        src = self.make_pair()
        self.assertFailure(lambda: stage_snapshot(Path("relative-source"), self.root / "out"))
        self.assertFailure(lambda: stage_snapshot(src, src / ".." / "out"))
        self.assertFailure(lambda: stage_snapshot(src, src / "nested"))

    def test_rejects_existing_empty_directory_and_symlink_destination(self):
        src = self.make_pair()
        empty = self.root / "empty-out"; empty.mkdir()
        self.assertFailure(lambda: stage_snapshot(src, empty))
        link = self.root / "out-link"; link.symlink_to(self.root)
        self.assertFailure(lambda: stage_snapshot(src, link))

    def test_rejects_symlink_ancestor_link_hardlink_and_fifo(self):
        src = self.make_pair()
        linked = self.root / "linked"; linked.symlink_to(src, target_is_directory=True)
        self.assertFailure(lambda: stage_snapshot(linked, self.root / "out1"))
        (src / "file-link").symlink_to(src / "media.bin")
        self.assertFailure(lambda: self.stage(name="out2"))
        (src / "file-link").unlink()
        os.link(src / "media.bin", src / "hardlink.bin")
        self.assertFailure(lambda: self.stage(name="out3"))
        (src / "hardlink.bin").unlink()
        if hasattr(os, "mkfifo"):
            os.mkfifo(src / "pipe")
            self.assertFailure(lambda: self.stage(name="out4"))

    def test_rejects_case_and_unicode_collisions(self):
        src = self.make_pair()
        (src / "Media.BIN").write_bytes(b"collision")
        self.assertFailure(lambda: self.stage(name="out1"))
        (src / "Media.BIN").unlink()
        (src / "é").write_bytes(b"one")
        (src / "e\u0301").write_bytes(b"two")
        self.assertFailure(lambda: self.stage(name="out2"))

    def test_limits_files_bytes_schema_rows_and_deadline(self):
        self.make_pair()
        for limits in (StageLimits(max_files=1), StageLimits(max_bytes=1), StageLimits(deadline_seconds=-1)):
            self.assertFailure(lambda limits=limits: self.stage(name=f"out-{id(limits)}", limits=limits))
        self.assertFalse(list(self.root.glob(".wacli-stage-*")))

    def test_metadata_and_schema_bounds_fail_closed(self):
        src = self.make_pair()
        self.assertFailure(lambda: self.stage(limits=StageLimits(max_schema_bytes=1)))
        con = self.connections[0]
        for i in range(3):
            con.execute("INSERT INTO schema_migrations VALUES (?)", (str(i),))
        con.commit()
        self.assertFailure(lambda: self.stage(name="out2", limits=StageLimits(max_metadata_rows=1)))

    def test_input_mutation_during_copy_is_rejected(self):
        src = self.make_pair(wal=False)
        original = stage._copy_file
        changed = {"done": False}
        def mutate(source, destination, expected, deadline, limits):
            result = original(source, destination, expected, deadline, limits)
            if not changed["done"] and Path(source).name == "media.bin":
                Path(source).write_bytes(b"changed")
                changed["done"] = True
            return result
        with patch.object(stage, "_copy_file", side_effect=mutate):
            self.assertFailure(lambda: self.stage())
        self.assertFalse((self.root / "out").exists())

    def test_copy_hook_signature_is_used_and_deadline_checked(self):
        self.make_pair(wal=False)
        seen = []
        original = stage._copy_file
        def observe(source, destination, expected, deadline, limits):
            seen.append((Path(source).name, Path(destination).name, expected, deadline, limits))
            return original(source, destination, expected, deadline, limits)
        with patch.object(stage, "_copy_file", side_effect=observe):
            self.stage()
        self.assertTrue(seen)
        self.assertTrue(all(item[3] > 0 and isinstance(item[4], StageLimits) for item in seen))

    def test_inventory_hook_receives_limits_and_deadline(self):
        self.make_pair(wal=False)
        original = stage._inventory
        seen = []
        def observe(root, limits, deadline):
            seen.append((root, limits, deadline))
            return original(root, limits, deadline)
        with patch.object(stage, "_inventory", side_effect=observe):
            self.stage()
        self.assertGreaterEqual(len(seen), 1)
        self.assertIsInstance(seen[0][1], StageLimits)

    def test_failure_messages_have_fixed_non_payload_errors(self):
        src = self.make_pair(wal=False)
        (src / "wacli.db").write_bytes(b"SECRET-PAYLOAD-123")
        with self.assertRaises(SnapshotStageError) as cm:
            self.stage()
        self.assertTrue(str(cm.exception))
        self.assertNotIn("SECRET", str(cm.exception))

    def test_hot_rollback_journal_recovers_only_on_scratch(self):
        """A crashed fixture transaction rolls back without changing original bytes."""
        src = self.make_pair(wal=False)
        for con in self.connections:
            con.close()
        self.connections.clear()
        code = '''import os, sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.execute('PRAGMA cache_size=1')
con.execute('BEGIN EXCLUSIVE')
con.execute('UPDATE data SET payload=zeroblob(1000000) WHERE id=1')
os._exit(0)
'''
        subprocess.run([sys.executable, '-c', code, str(src / 'wacli.db')], check=True, timeout=10)
        self.assertTrue((src / 'wacli.db-journal').exists())
        before = self.source_bytes(src)
        self.stage()
        self.assertEqual(before, self.source_bytes(src))
        self.assertEqual(before, self.source_bytes(self.root / 'out' / 'originals'))
        with sqlite3.connect(self.root / 'out' / 'derived' / 'wacli.db') as con:
            self.assertEqual(con.execute('SELECT payload FROM data WHERE id=1').fetchone()[0], b'binary\x00fixture\xff')

    def test_ancestor_swap_to_symlink_cannot_read_outside_staging(self):
        """Input descriptor traversal blocks a symlink inserted after inventory."""
        src = self.make_pair(wal=False)
        original = stage._copy_file
        def swap(source, destination, expected, deadline, limits):
            if Path(source) == src / 'nested' / 'payload.bin':
                (src / 'nested').rename(src / 'renamed')
                (src / 'nested').symlink_to(src / 'renamed', target_is_directory=True)
            return original(source, destination, expected, deadline, limits)
        with patch.object(stage, '_copy_file', side_effect=swap):
            self.assertFailure(lambda: self.stage())
        self.assertFalse((self.root / 'out').exists())

    def test_unknown_metadata_columns_and_views_are_rejected(self):
        """Never SELECT arbitrary payload columns or a masquerading view."""
        self.make_pair(wal=False)
        con = self.connections[0]
        con.execute('ALTER TABLE schema_migrations ADD COLUMN secret_payload BLOB')
        con.commit()
        self.assertFailure(lambda: self.stage())
        con.execute('DROP TABLE schema_migrations')
        con.execute('CREATE VIEW schema_migrations AS SELECT payload AS version FROM data')
        con.commit()
        self.assertFailure(lambda: self.stage(name='out2'))

    def test_schema_sql_is_sensitive_private_evidence_not_a_log(self):
        """Full schema preservation includes SQL literals only in private receipt."""
        import contextlib
        import io
        self.make_pair(wal=False)
        con = self.connections[0]
        con.execute("CREATE TABLE literal_fixture(value TEXT DEFAULT 'synthetic-sensitive-literal')")
        con.commit()
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            receipt = self.stage()
        self.assertEqual(stdout.getvalue() + stderr.getvalue(), '')
        self.assertIn('synthetic-sensitive-literal', json.dumps(receipt))
        self.assertFalse(receipt['publishable'])
        self.assertEqual(stat.S_IMODE((self.root / 'out' / 'receipt.json').stat().st_mode), 0o600)

    def test_cleanup_failure_has_fixed_diagnostic_and_no_receipt(self):
        """Residual private bytes cannot masquerade as completed preparation."""
        src = self.make_pair(wal=False)
        (src / 'session.db').write_bytes(b'invalid fixture')
        real_cleanup = stage.shutil.rmtree
        with patch.object(stage.shutil, 'rmtree', side_effect=PermissionError('sensitive-path')):
            with self.assertRaisesRegex(SnapshotStageError, 'cleanup failed') as failure:
                self.stage()
        self.assertNotIn('sensitive-path', str(failure.exception))
        self.assertFalse((self.root / 'out' / 'receipt.json').exists())
        real_cleanup(self.root / 'out')

    def test_separate_database_epochs_never_become_capture_attestation(self):
        """Individually valid staged DBs need not share an application boundary."""
        self.make_pair(wal=False)
        for index, con in enumerate(self.connections):
            con.execute('CREATE TABLE epoch(value INTEGER)')
            con.execute('INSERT INTO epoch VALUES (?)', (index + 1,))
            con.commit()
        receipt = self.stage()
        self.assertFalse(receipt['publishable'])
        self.assertFalse(receipt['complete'])
        self.assertFalse(receipt['windows_validated'])
        self.assertIsNone(receipt['capture_attestation'])
        self.assertEqual(receipt['cross_database_consistency'], 'NOT_CERTIFIED')

    def test_receipt_bound_and_invalid_metadata_values_fail(self):
        """Large reports and falsely typed version rows never get a receipt."""
        self.make_pair(wal=False)
        self.assertFailure(lambda: self.stage(limits=StageLimits(max_receipt_bytes=1)))
        self.assertFalse((self.root / 'out').exists())
        con = self.connections[0]
        con.execute("UPDATE schema_migrations SET version='not-a-version'")
        con.commit()
        self.assertFailure(lambda: self.stage(name='out2'))
        self.assertFalse((self.root / 'out2').exists())


if __name__ == "__main__":
    unittest.main()
