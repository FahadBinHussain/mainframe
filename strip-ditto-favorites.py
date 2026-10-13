#!/usr/bin/env python3
"""strip-ditto-favorites.py - build a starred-only Ditto.db for mainframe backups.

WHY: backups never ship the full clip DB (clip history is huge + local-only), but
the STARRED clips are wanted on a fresh box. starred = Main.lDontAutoDelete > 0 -
the exact flag the user's fork PRs (#1098 starred clips filter, #1107 starred
clips shortcut) read - so no new schema is introduced and stock Ditto understands
the rows as-is ("star" sets lDontAutoDelete).

usage: python strip-ditto-favorites.py <src Ditto.db> <dst Ditto.db>

table roles:
  Main        - rows with lDontAutoDelete > 0 (starred clips) + ancestor groups
                (recursive lParentID walk) so a starred clip inside a group keeps
                its parent
  Data        - clip content blobs, rows for every kept lID / group lID
  Types       - clipboard-format config, copied whole (tiny)
  MainDeletes - schema only, NO rows: old-deletion tombstones must never
                propagate to a restored box via sync
  CopyBuffers - schema only, NO rows: transient copy state
  sqlite_sequence - copied as-is so future autoincrement lIDs never collide with
                the kept rows' original ids
  anything else - copied whole but announced loud (review this script)

the source db is opened READ-ONLY (mode=ro, immutable=1 retry) - this script
never writes to the source, so it is safe to run while Ditto holds the db open.
any problem = loud reason on stderr + exit 1; a half-broken dst is deleted,
never shipped.
"""

import os
import sqlite3
import sys


def fail(msg):
    print(f"STRIP FAILED: {msg}", file=sys.stderr)
    sys.exit(1)


def open_ro(src):
    # mode=ro: reads committed WAL frames through the live -shm, writes nothing.
    # immutable=1: last resort when -shm is unavailable (Ditto not running and db
    # mid-checkpoint) - may miss un-checkpointed frames, so it announces itself.
    try:
        return sqlite3.connect(f"file:{src}?mode=ro", uri=True)
    except sqlite3.OperationalError as e:
        print(f"mode=ro failed ({e}) - RETRY METHOD 2: immutable=1 (may miss un-checkpointed wal data)", file=sys.stderr)
        try:
            return sqlite3.connect(f"file:{src}?immutable=1", uri=True)
        except sqlite3.OperationalError as e2:
            fail(f"cannot open source read-only: {e2}")


def main():
    if len(sys.argv) != 3:
        fail(f"usage: {sys.argv[0]} <src Ditto.db> <dst Ditto.db>")
    src, dst = sys.argv[1], sys.argv[2]
    if not os.path.isfile(src):
        fail(f"source db not found: {src}")

    scon = open_ro(src)

    # --- schema requirements (fail loud, never guess columns) ---
    tables = {r[0]: r[1] for r in scon.execute("SELECT name, sql FROM sqlite_master WHERE type='table'")}
    lower = {t.lower(): t for t in tables}
    for want in ("main", "data"):
        if want not in lower:
            fail(f"source has no '{want}' table - not a Ditto db? tables: {sorted(tables)}")
    main_t, data_t = lower["main"], lower["data"]
    main_cols = {r[1].lower(): r[1] for r in scon.execute(f'PRAGMA table_info("{main_t}")')}
    for want in ("lid", "lparentid", "bisgroup", "ldontautodelete"):
        if want not in main_cols:
            fail(f"{main_t} has no '{want}' column - schema changed upstream, update the strip logic. columns: {sorted(main_cols)}")
    c_id, c_parent, c_star = main_cols["lid"], main_cols["lparentid"], main_cols["ldontautodelete"]

    total = scon.execute(f'SELECT COUNT(*) FROM "{main_t}"').fetchone()[0]
    starred = scon.execute(f'SELECT COUNT(*) FROM "{main_t}" WHERE "{c_star}" > 0').fetchone()[0]
    if starred == 0:
        fail(f"0 starred clips in {src} - refusing to ship an EMPTY favorites db (it would wipe clips on restore); fix the source first")

    # --- build dst ---
    if os.path.exists(dst):
        os.remove(dst)
    # isolation_level=None: autocommit each statement - VACUUM cannot run inside
    # python's implicit transaction, and the whole build is one-shot anyway.
    dcon = sqlite3.connect(dst, isolation_level=None)
    try:
        # copy schema: every user table/index/trigger except sqlite_* internals
        for name, sql in scon.execute("SELECT name, sql FROM sqlite_master WHERE type IN ('table','index','trigger') AND name NOT LIKE 'sqlite_%'"):
            dcon.execute(sql)
        # sqlite_sequence is a reserved internal table: it auto-exists in dst as
        # long as the copied schema has an AUTOINCREMENT table (Ditto's Main does),
        # so only the rows get copied - never CREATE it.
        # sqlite_sequence is a reserved internal table: it auto-exists in dst as
        # long as the copied schema has an AUTOINCREMENT table (Ditto's Main does).
        # never CREATE it - just carry the rows over when it's there.
        if "sqlite_sequence" in tables:
            dst_has_seq = dcon.execute("SELECT COUNT(*) FROM sqlite_master WHERE name='sqlite_sequence'").fetchone()[0]
            if dst_has_seq:
                for row in scon.execute("SELECT name, seq FROM sqlite_sequence"):
                    dcon.execute("INSERT INTO sqlite_sequence VALUES (?,?)", row)
            else:
                print("NOTE: dst has no sqlite_sequence (no AUTOINCREMENT table) - source counters not carried", file=sys.stderr)

        # kept rows are selected from the READ-ONLY source and inserted into dst
        # (dst Main/Data start empty - never SELECT from them)
        kept_rows = scon.execute(
            f'WITH RECURSIVE anc(lid) AS ('
            f'  SELECT "{c_id}" FROM "{main_t}" WHERE "{c_star}" > 0 AND COALESCE("{c_parent}",0) > 0'
            f'  UNION'
            f'  SELECT m."{c_parent}" FROM "{main_t}" m JOIN anc a ON m."{c_id}" = a.lid'
            f'  WHERE COALESCE(m."{c_parent}",0) > 0'
            f') '
            f'SELECT * FROM "{main_t}" WHERE "{c_id}" IN (SELECT lid FROM anc) OR "{c_star}" > 0').fetchall()
        kept_ids = [r[list(main_cols.values()).index(c_id)] for r in kept_rows]
        n_marked = scon.execute(f'SELECT COUNT(*) FROM "{main_t}" WHERE "{c_star}" > 0').fetchone()[0]
        kept_groups = len(kept_rows) - n_marked
        marks = ','.join('?' * len(kept_ids))
        kept_data_rows = scon.execute(
            f'SELECT * FROM "{data_t}" WHERE "{c_id}" IN ({marks}) OR COALESCE("{c_parent}",0) IN ({marks})',
            kept_ids + kept_ids).fetchall()
        n_main_cols = len(main_cols)
        n_data_cols = len([r for r in scon.execute(f'PRAGMA table_info("{data_t}")')])
        dcon.executemany(f'INSERT INTO "{main_t}" VALUES ({",".join("?" * n_main_cols)})', kept_rows)
        dcon.executemany(f'INSERT INTO "{data_t}" VALUES ({",".join("?" * n_data_cols)})', kept_data_rows)

        # remaining tables: explicit roles, unknown = copy whole + announce.
        # rows always come from the READ-ONLY source, never the empty dst.
        skip_rows = {main_t.lower(), data_t.lower(), "maindeletes", "copybuffers", "sqlite_sequence"}
        for t in tables:
            lt = t.lower()
            if lt in skip_rows:
                continue
            n_cols = len([r for r in scon.execute(f'PRAGMA table_info("{t}")')])
            rows_all = scon.execute(f'SELECT * FROM "{t}"').fetchall()
            if lt != "types":
                print(f"NOTE: unknown table '{t}' copied whole ({len(rows_all)} rows) - review strip-ditto-favorites.py roles", file=sys.stderr)
            if rows_all:
                dcon.executemany(f'INSERT INTO "{t}" VALUES ({",".join("?" * n_cols)})', rows_all)

        dcon.execute("VACUUM")
        ok = dcon.execute("PRAGMA integrity_check").fetchone()[0]
        if ok != "ok":
            fail(f"integrity_check on stripped db: {ok}")
        dcon.commit()
    except Exception as e:
        dcon.close()
        if os.path.exists(dst):
            os.remove(dst)
        fail(f"strip error: {e}")

    print(f"stripped ditto db: {src} ({os.path.getsize(src)/1048576:.1f} MB, {total} clips) -> {dst} ({os.path.getsize(dst)/1048576:.1f} MB)")
    print(f"  kept: {n_marked} starred clip(s), {kept_groups} ancestor group(s), {len(kept_data_rows)} data row(s)")
    print(f"  dropped: {total - len(kept_rows)} clip row(s); MainDeletes/CopyBuffers kept as empty tables")
    scon.close()
    dcon.close()


if __name__ == "__main__":
    main()
