"""Private staged WACLI preparation, NOT a coordinated source capture backend.

Never discover HOME or certify caller-supplied staging as a consistent boundary.
SQLite is opened only on scratch copies; originals and caller input stay opaque.
"""
from __future__ import annotations

from contextlib import closing
from dataclasses import dataclass
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import sqlite3
import stat
import tempfile
import time
import unicodedata


class SnapshotStageError(RuntimeError):
    """Fixed diagnostics only; no source paths, SQL, or payloads."""


@dataclass(frozen=True)
class StageLimits:
    """Finite preparation limits; no production capture guarantee is implied."""
    max_files: int = 10000  # includes directories
    max_bytes: int = 512 * 1024 * 1024
    max_schema_bytes: int = 4 * 1024 * 1024
    max_metadata_rows: int = 256
    max_receipt_bytes: int = 16 * 1024 * 1024
    deadline_seconds: float = 30.0
    backup_pages: int = 64


def _fail(message):
    raise SnapshotStageError(message)


def _deadline(deadline):
    if time.monotonic() >= deadline:
        _fail('Staging deadline exceeded.')


def _stamp(info):
    return (info.st_dev, info.st_ino, info.st_mode, info.st_nlink,
            info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def _path(value):
    path = Path(value)
    if not path.is_absolute() or '..' in path.parts:
        _fail('Explicit absolute canonical staging paths required.')
    # Inspect all existing ancestors; do not resolve a link into an approved path.
    for component in reversed((path,) + tuple(path.parents)):
        try:
            info = component.lstat()
        except FileNotFoundError:
            continue
        if stat.S_ISLNK(info.st_mode):
            _fail('Staging path contains a link.')
        if component != path and not stat.S_ISDIR(info.st_mode):
            _fail('Invalid staging parent.')
    return path


def _name(value):
    base = value.split('.')[0].upper()
    reserved = {'CON', 'PRN', 'AUX', 'NUL'} | {f'{x}{n}' for x in ('COM', 'LPT') for n in range(1, 10)}
    if (not value or value in ('.', '..') or value.endswith(('.', ' '))
            or any(ord(c) < 32 or c in '<>:"/\\|?*' for c in value)
            or base in reserved):
        _fail('Unsafe staged member name.')


def _inventory(root, limits, deadline):
    """Metadata inventory with complete directory/error accounting and no links."""
    _deadline(deadline)
    root_info = root.lstat()
    if not stat.S_ISDIR(root_info.st_mode):
        _fail('Staged source must be a real directory.')
    result, folded, total = {}, set(), 0
    def fail_walk(error):
        _fail('Staged source enumeration failed.')
    for base, dirs, files in os.walk(root, followlinks=False, onerror=fail_walk):
        _deadline(deadline)
        for name in sorted(dirs + files):
            _name(name)
            path = Path(base) / name
            info = path.lstat()
            rel = path.relative_to(root).as_posix()
            key = unicodedata.normalize('NFC', rel).casefold()
            if key in folded:
                _fail('Colliding staged names.')
            folded.add(key)
            if not (stat.S_ISDIR(info.st_mode) or stat.S_ISREG(info.st_mode)):
                _fail('Links or special staged files are blocked.')
            if stat.S_ISREG(info.st_mode):
                if info.st_nlink != 1:
                    _fail('Hardlinked staged files are blocked.')
                total += info.st_size
            result[rel] = _stamp(info)
            if len(result) > limits.max_files or total > limits.max_bytes:
                _fail('Staged tree limit exceeded.')
    return result


def _hash(path, deadline):
    digest = hashlib.sha256()
    with _opened_file(path) as stream:
        while True:
            _deadline(deadline)
            block = stream.read(1024 * 1024)
            if not block:
                break
            digest.update(block)
    return digest.hexdigest()


def _opened_file(path):
    """Walk every input ancestor descriptor-relative; never follow a symlink."""
    directory = os.open(path.anchor, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        for name in path.parts[1:-1]:
            child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                            dir_fd=directory)
            os.close(directory)
            directory = child
        fd = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                     dir_fd=directory)
    finally:
        os.close(directory)
    if not stat.S_ISREG(os.fstat(fd).st_mode):
        os.close(fd)
        _fail('Staged input is not a regular file.')
    return os.fdopen(fd, 'rb')


def _copy_file(source, destination, expected, deadline, limits):
    """Bounded opaque copy; caller-private trees, no input SQLite opens."""
    with _opened_file(source) as inp:
        if _stamp(os.fstat(inp.fileno())) != expected:
            _fail('Staged source changed before copy.')
        fd = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        digest, count = hashlib.sha256(), 0
        with os.fdopen(fd, 'wb') as out:
            while True:
                _deadline(deadline)
                block = inp.read(1024 * 1024)
                if not block:
                    break
                count += len(block)
                if count > expected[4] or count > limits.max_bytes:
                    _fail('Staged source changed during copy.')
                digest.update(block)
                out.write(block)
        if count != expected[4] or _stamp(os.fstat(inp.fileno())) != expected:
            _fail('Staged source changed during copy.')
    if _hash(destination, deadline) != digest.hexdigest():
        _fail('Staged copy byte verification failed.')
    return digest.hexdigest()


def _copy_tree(source, destination, inventory, deadline, limits):
    destination.mkdir(mode=0o700)
    members = []
    for rel, stamp in sorted(inventory.items()):
        _deadline(deadline)
        item = destination / rel
        if stat.S_ISDIR(stamp[2]):
            item.mkdir(mode=0o700)
            members.append({'path': rel, 'type': 'directory'})
        else:
            digest = _copy_file(source / rel, item, stamp, deadline, limits)
            members.append({'path': rel, 'type': 'file', 'size': stamp[4], 'sha256': digest})
    return members


def _connect(path, mode, deadline, limits):
    con = sqlite3.connect(path.as_uri() + '?mode=' + mode, uri=True, timeout=0.05)
    try:
        con.enable_load_extension(False)
        con.execute('PRAGMA trusted_schema=OFF')
        con.setlimit(sqlite3.SQLITE_LIMIT_LENGTH, limits.max_schema_bytes)
        con.setlimit(sqlite3.SQLITE_LIMIT_SQL_LENGTH, limits.max_schema_bytes)
        con.set_progress_handler(lambda: int(time.monotonic() >= deadline), 1000)
        return con
    except BaseException:
        con.close()
        raise


def _derive(source, destination, deadline, limits):
    """Recover ONLY a disposable scratch tree; full backup preserves unknown SQL."""
    _deadline(deadline)
    # mode=rw permits hot-journal recovery on scratch, never original input/raw.
    with closing(_connect(source, 'rw', deadline, limits)) as src:
        page_size = src.execute('PRAGMA page_size').fetchone()[0]
        page_count = src.execute('PRAGMA page_count').fetchone()[0]
        if page_size * page_count > limits.max_bytes:
            _fail('Derived database size limit exceeded.')
        fd = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        os.close(fd)
        with closing(_connect(destination, 'rw', deadline, limits)) as dst:
            dst.execute('PRAGMA journal_mode=DELETE')
            def progress(status, remaining, total):
                _deadline(deadline)
                if total * page_size > limits.max_bytes:
                    _fail('Derived database size limit exceeded.')
            src.backup(dst, pages=limits.backup_pages, progress=progress, sleep=0.001)
            dst.commit()
    _deadline(deadline)
    if destination.stat().st_size > limits.max_bytes:
        _fail('Derived database size limit exceeded.')


def _metadata(path, deadline, limits):
    """Read schema/version metadata only, not chat, device, or key table rows."""
    with closing(_connect(path, 'ro', deadline, limits)) as con:
        checks = con.execute('PRAGMA integrity_check').fetchmany(2)
        if checks != [('ok',)]:
            _fail('Derived database integrity check failed.')
        result = {}
        for key in ('user_version', 'application_id', 'schema_version', 'page_size', 'journal_mode'):
            _deadline(deadline)
            result[key] = con.execute('PRAGMA ' + key).fetchone()[0]
        objects, encoded_size = [], 0
        cursor = con.execute('SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY type,name')
        for row in cursor:
            _deadline(deadline)
            if any(value is not None and not isinstance(value, str) for value in row):
                _fail('Invalid schema metadata.')
            encoded_size += len(json.dumps(row, ensure_ascii=False).encode('utf-8'))
            if encoded_size > limits.max_schema_bytes or len(objects) >= limits.max_files:
                _fail('Schema metadata limit exceeded.')
            objects.append(dict(zip(('type', 'name', 'table', 'sql'), row)))
        encoded = json.dumps(objects, sort_keys=True, ensure_ascii=False, separators=(',', ':')).encode('utf-8')
        if len(encoded) > limits.max_schema_bytes:
            _fail('Schema metadata limit exceeded.')
        result['schema_definitions'] = objects
        result['schema_digest'] = hashlib.sha256(encoded).hexdigest()
        allowed_tables = {'schema_migrations': {'version': int, 'name': str, 'applied_at': int},
                          'whatsmeow_version': {'version': int, 'compat': int}}
        for table, allowed in allowed_tables.items():
            matching = [obj for obj in objects if obj['name'] == table]
            if not matching:
                result[table] = None
                continue
            if len(matching) != 1 or matching[0]['type'] != 'table' or 'VIRTUAL TABLE' in (matching[0]['sql'] or '').upper():
                _fail('Unsupported version metadata shape.')
            fields = con.execute('PRAGMA table_info("' + table + '")').fetchall()
            names = [row[1] for row in fields]
            if not names or 'version' not in names or any(name not in allowed for name in names):
                _fail('Unsupported version metadata shape.')
            columns = ','.join('"' + name + '"' for name in names)
            rows = con.execute('SELECT ' + columns + ' FROM "' + table + '" ORDER BY "version" LIMIT ?',
                               (limits.max_metadata_rows + 1,)).fetchall()
            if len(rows) > limits.max_metadata_rows:
                _fail('Version metadata row limit exceeded.')
            for row in rows:
                for name, value in zip(names, row):
                    if value is None and name == 'compat':
                        continue
                    if type(value) is not allowed[name] or isinstance(value, str) and len(value.encode('utf-8')) > 4096:
                        _fail('Invalid version metadata value.')
            result[table] = {'columns': names, 'rows': [list(row) for row in rows]}
        return result


def stage_snapshot(source, destination, *, limits=StageLimits()):
    """INTERNAL preparation of a caller-private staged tree; never capture proof.

    Output is also private staging, not a published backup or accepted restore
    format. A receipt appears only after verification. No quiescence is inferred.
    """
    owned = False
    out = None
    try:
        if (os.name != 'posix' or os.open not in os.supports_dir_fd
                or not hasattr(os, 'O_NOFOLLOW') or not hasattr(os, 'O_DIRECTORY')):
            _fail('Private preparation requires supported POSIX filesystem operations.')
        integer_limits = (limits.max_files, limits.max_bytes, limits.max_schema_bytes,
                          limits.max_metadata_rows, limits.max_receipt_bytes, limits.backup_pages)
        if (any(type(value) is not int or value <= 0 for value in integer_limits)
                or not math.isfinite(limits.deadline_seconds) or limits.deadline_seconds <= 0):
            _fail('Invalid staging limits.')
        deadline = time.monotonic() + limits.deadline_seconds
        src, out = _path(source), _path(destination)
        if src == out or src in out.parents or out in src.parents:
            _fail('Source and destination overlap.')
        if os.path.lexists(out):
            _fail('Destination already exists.')
        before = _inventory(src, limits, deadline)
        if any(db not in before or not stat.S_ISREG(before[db][2]) for db in ('wacli.db', 'session.db')):
            _fail('Required database pair is incomplete.')
        out.mkdir(mode=0o700)  # exclusive reservation, NEVER replace even an empty directory
        owned = True
        members = _copy_tree(src, out / 'originals', before, deadline, limits)
        if _inventory(src, limits, deadline) != before:
            _fail('Staged source changed during preparation.')
        derived = out / 'derived'
        derived.mkdir(mode=0o700)
        with tempfile.TemporaryDirectory(prefix='scratch-', dir=out) as work:
            scratch = Path(work) / 'store'
            raw_inventory = _inventory(out / 'originals', limits, deadline)
            _copy_tree(out / 'originals', scratch, raw_inventory, deadline, limits)
            for db in ('session.db', 'wacli.db'):
                _derive(scratch / db, derived / db, deadline, limits)
        data = {}
        for db in ('session.db', 'wacli.db'):
            metadata = _metadata(derived / db, deadline, limits)
            data[db] = {'size': (derived / db).stat().st_size,
                        'sha256': _hash(derived / db, deadline), 'metadata': metadata}
        for member in members:
            if member['type'] == 'file':
                if (_hash(src / member['path'], deadline) != member['sha256']
                        or _hash(out / 'originals' / member['path'], deadline) != member['sha256']):
                    _fail('Staged source or original changed during preparation.')
        if _inventory(src, limits, deadline) != before:
            _fail('Staged source changed during preparation.')
        if _inventory(out / 'originals', limits, deadline) != raw_inventory:
            _fail('Preserved original membership changed during preparation.')
        with closing(sqlite3.connect(':memory:')) as con:
            options = [row[0] for row in con.execute('PRAGMA compile_options')]
        receipt = {'format': 'wacli-snapshot-preparation-v1', 'status': 'PREPARATION',
                   'boundary': 'UNVERIFIED', 'provenance': 'UNVERIFIED', 'publishable': False,
                   'complete': False, 'windows_validated': False,
                   'capture_attestation': None, 'cross_database_consistency': 'NOT_CERTIFIED',
                   'raw_complete': 'supplied-stage-only', 'raw_members': members, 'derived': data,
                   'sqlite': {'engine': sqlite3.sqlite_version, 'backup_api': True, 'options': options}}
        encoded = (json.dumps(receipt, sort_keys=True, ensure_ascii=False, indent=2) + '\n').encode('utf-8')
        if len(encoded) > limits.max_receipt_bytes:
            _fail('Preparation receipt limit exceeded.')
        _deadline(deadline)
        fd = os.open(out / 'receipt.json', os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, 'wb') as stream:
            stream.write(encoded)
        return receipt
    except BaseException as exc:
        if owned:
            try:
                shutil.rmtree(out)
            except OSError:
                raise SnapshotStageError('Private staging cleanup failed; residual data requires review. No capture published.') from None
        if isinstance(exc, (KeyboardInterrupt, SystemExit, SnapshotStageError)):
            raise
        raise SnapshotStageError('Private staged snapshot preparation failed.') from None


def _prepare_staged_snapshot(source, destination, *, deadline_seconds=30.0):
    """Internal coordinator hook; no live boundary or producer attestation."""
    return stage_snapshot(source, destination, limits=StageLimits(deadline_seconds=deadline_seconds))
