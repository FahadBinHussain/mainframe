#!/usr/bin/env python3
"""Coordinated WACLI capture preflight; no live capture backend is enabled."""
from __future__ import annotations

import argparse
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import stat
import sys
import tempfile
import unicodedata
from zipfile import ZIP_DEFLATED, ZipFile

from wacli_snapshot_protocol import PROTOCOL

PREPARATION_PREFIX = 'WacliPreparation/v1/'


def capture_status():
    """Return fixed diagnostics without discovering or reading any source."""
    return {
        'operation': 'coordinated-wacli-snapshot', 'status': 'blocked',
        'capture_enabled': False, 'complete': False, 'publishable': False,
        'windows_validated': False, 'source_read': False,
        'activation': 'not-performed',
        'blockers': ['verified-all-writer-boundary-backend-unavailable',
                     'approved-complete-input-membership-unverified',
                     'historical-producer-provenance-unverified',
                     'windows-capture-acceptance-run-required'],
        'preparation': 'private-staged-sqlite-and-encryption-only',
        'documentation': 'docs/wacli-snapshot-preparation.md',
        'producer_protocol': PROTOCOL,
        'producer_inspection': 'stdin-only-informational-never-authorizes-capture',
        'producer_execution': False,
    }


def capture(source_root, destination):
    """Refuse capture before reading either supplied path or loading providers."""
    return capture_status()


def _digest(stream):
    result = hashlib.sha256()
    while block := stream.read(1024 * 1024):
        result.update(block)
    return result.hexdigest()


def _safe_root(value, label, *, private=False):
    path = Path(value)
    if not path.is_absolute() or '..' in path.parts:
        raise ValueError(f'Invalid private {label} directory.')
    # Every existing ancestor is checked with lstat: resolving a link is not approval.
    for part in reversed((path,) + tuple(path.parents)):
        try:
            info = part.lstat()
        except FileNotFoundError:
            continue
        if stat.S_ISLNK(info.st_mode):
            raise ValueError(f'Private {label} path contains a link.')
        if part == path:
            if not stat.S_ISDIR(info.st_mode):
                raise ValueError(f'Private {label} directory required.')
            if private and os.name == 'posix' and info.st_mode & 0o077:
                raise ValueError('Private workspace permissions required.')
        elif not stat.S_ISDIR(info.st_mode):
            raise ValueError(f'Invalid private {label} parent.')
    if not path.exists() or not path.is_dir():
        raise ValueError(f'Private {label} directory required.')
    if path.resolve(strict=True) != path:
        raise ValueError(f'Private {label} path contains a link.')
    return path


def _receipt(prepared, limit=16 * 1024 * 1024):
    path = prepared / 'receipt.json'
    try:
        info = path.lstat()
        if not stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode) or info.st_nlink != 1:
            raise ValueError
        if info.st_size <= 0 or info.st_size > limit:
            raise ValueError
        with path.open('rb') as stream:
            raw = stream.read(limit + 1)
        if len(raw) != info.st_size or len(raw) > limit:
            raise ValueError
        value = json.loads(raw.decode('utf-8'))
    except (OSError, ValueError, UnicodeError, json.JSONDecodeError):
        raise ValueError('Invalid preparation receipt.') from None
    if (not isinstance(value, dict) or value.get('format') != 'wacli-snapshot-preparation-v1'
            or value.get('status') != 'PREPARATION'
            or value.get('publishable') is not False
            or value.get('boundary') != 'UNVERIFIED'
            or value.get('provenance') != 'UNVERIFIED'
            or value.get('cross_database_consistency') != 'NOT_CERTIFIED'):
        raise ValueError('Invalid preparation receipt.')
    return value


def _inventory(root, max_files=10000, max_bytes=512 * 1024 * 1024):
    """Return a normalized complete tree manifest, including hashes for files and dirs."""
    from wacli_snapshot_stage import _opened_file
    result, folded, total = {}, set(), 0
    def fail_walk(error):
        raise ValueError('Private preparation enumeration failed.') from None
    for base, dirs, files in os.walk(root, followlinks=False, onerror=fail_walk):
        names = sorted(dirs + files)
        if len(names) != len(dirs) + len(files):
            raise ValueError('Invalid private preparation member.')
        for name in names:
            if not name or name in ('.', '..') or any(ord(c) < 32 or c in '/\\' for c in name):
                raise ValueError('Invalid private preparation member.')
            item = Path(base) / name
            info = item.lstat()
            if stat.S_ISLNK(info.st_mode) or not (stat.S_ISDIR(info.st_mode) or stat.S_ISREG(info.st_mode)):
                raise ValueError('Invalid private preparation member.')
            rel = item.relative_to(root).as_posix()
            key = unicodedata.normalize('NFC', rel).casefold()
            if key in folded:
                raise ValueError('Colliding private preparation names.')
            folded.add(key)
            if stat.S_ISREG(info.st_mode):
                if info.st_nlink != 1:
                    raise ValueError('Hardlinked private preparation file.')
                total += info.st_size
                if total > max_bytes:
                    raise ValueError('Private preparation limit exceeded.')
                with _opened_file(item) as stream:
                    digest = _digest(stream)
                result[rel] = ('file', info.st_size, digest, info.st_mode, info.st_mtime_ns, info.st_ctime_ns)
            else:
                result[rel] = ('directory', 0, hashlib.sha256(b'').hexdigest(), info.st_mode,
                               info.st_mtime_ns, info.st_ctime_ns)
            if len(result) > max_files:
                raise ValueError('Private preparation limit exceeded.')
    return result


def _encrypt_candidate(prepared, workspace, password):
    """INTERNAL: validate and envelope private preparation; never publish or certify it."""
    from wacli_snapshot_stage import _opened_file
    try:
        import pyzipper
    except ImportError:
        raise ValueError('AES provider unavailable; preparation blocked.') from None
    if not isinstance(password, bytes) or not password:
        raise ValueError('Non-empty archive password required.')
    prepared = _safe_root(prepared, 'preparation')
    workspace = _safe_root(workspace, 'workspace', private=True)
    if prepared.resolve() == workspace.resolve() or prepared.resolve() in workspace.resolve().parents or workspace.resolve() in prepared.resolve().parents:
        raise ValueError('Private preparation and workspace overlap.')
    _receipt(prepared)
    inner, envelope = workspace / 'tool-secrets.zip', workspace / 'mainframe-secrets.zip'
    if os.path.lexists(inner) or os.path.lexists(envelope):
        raise ValueError('Private candidate workspace already contains output.')
    before = _inventory(prepared)
    owned_inner = owned_envelope = False
    try:
        fd = os.open(inner, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        os.close(fd); owned_inner = True
        with ZipFile(inner, 'w', compression=ZIP_DEFLATED) as archive:
            for rel, record in sorted(before.items()):
                item = prepared / rel
                kind, size, digest, *_ = record
                name = PREPARATION_PREFIX + rel + ('/' if kind == 'directory' else '')
                if kind == 'directory':
                    archive.writestr(name, b'')
                    continue
                try:
                    actual_digest, count = hashlib.sha256(), 0
                    with _opened_file(item) as stream, archive.open(name, 'w', force_zip64=True) as target:
                        while block := stream.read(1024 * 1024):
                            count += len(block)
                            if count > size:
                                raise ValueError('Private preparation changed during encryption.')
                            actual_digest.update(block)
                            target.write(block)
                    now = item.lstat()
                except OSError:
                    raise ValueError('Private preparation changed during encryption.') from None
                if count != size or now.st_size != size or actual_digest.hexdigest() != digest:
                    raise ValueError('Private preparation changed during encryption.')
        if _inventory(prepared) != before:
            raise ValueError('Private preparation changed during encryption.')
        fd = os.open(envelope, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        os.close(fd); owned_envelope = True
        with pyzipper.AESZipFile(envelope, 'w', compression=pyzipper.ZIP_DEFLATED, encryption=pyzipper.WZ_AES) as archive:
            archive.setpassword(password); archive.setencryption(pyzipper.WZ_AES, nbits=256)
            archive.write(inner, 'tool-secrets.zip')
        with pyzipper.AESZipFile(envelope) as archive:
            archive.setpassword(password)
            if archive.namelist() != ['tool-secrets.zip']:
                raise ValueError('Invalid encrypted candidate membership.')
            with archive.open('tool-secrets.zip') as stream:
                actual = _digest(stream)
        with inner.open('rb') as stream:
            if actual != _digest(stream):
                raise ValueError('Encrypted candidate byte verification failed.')
        with ZipFile(inner) as archive:
            names = archive.namelist()
            expected_names = [PREPARATION_PREFIX + rel + ('/' if rec[0] == 'directory' else '') for rel, rec in sorted(before.items())]
            if names != expected_names:
                raise ValueError('Invalid private candidate membership.')
            for rel, record in sorted(before.items()):
                name = PREPARATION_PREFIX + rel + ('/' if record[0] == 'directory' else '')
                with archive.open(name) as stream:
                    if _digest(stream) != record[2]:
                        raise ValueError('Private candidate member verification failed.')
        if _inventory(prepared) != before:
            raise ValueError('Private preparation changed during encryption.')
        return envelope
    except BaseException:
        cleanup_error = False
        for path, owned in ((envelope, owned_envelope), (inner, owned_inner)):
            if owned:
                try:
                    if path.is_file() and not path.is_symlink():
                        path.unlink()
                except BaseException:
                    cleanup_error = True
        if cleanup_error:
            raise ValueError('Private candidate cleanup failed.') from None
        raise
    finally:
        if owned_inner:
            try:
                if inner.is_file() and not inner.is_symlink():
                    inner.unlink()
            except BaseException:
                raise ValueError('Private candidate cleanup failed.') from None


@contextmanager
def _private_candidate(staged_source, password, *, deadline_seconds=30.0):
    try:
        import pyzipper
    except ImportError:
        raise ValueError('AES provider unavailable; preparation blocked.') from None
    if not isinstance(password, bytes) or not password:
        raise ValueError('Non-empty archive password required.')
    from wacli_snapshot_stage import _prepare_staged_snapshot
    with tempfile.TemporaryDirectory(prefix='mainframe-wacli-candidate-') as work:
        workspace = Path(work)
        receipt = _prepare_staged_snapshot(staged_source, workspace / 'prepared', deadline_seconds=deadline_seconds)
        # Keep the generated preparation and encryption outputs disjoint; both
        # remain inside the private temporary tree and disappear on exit.
        encryption_workspace = workspace / 'encryption-work'
        encryption_workspace.mkdir(mode=0o700)
        envelope = _encrypt_candidate(workspace / 'prepared', encryption_workspace, password)
        yield envelope, receipt


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='operation', required=True)
    commands.add_parser('plan', help='fixed capability report; reads no files')
    command = commands.add_parser('capture', help='BLOCKED: no verified boundary backend')
    command.add_argument('--source-root', required=True); command.add_argument('--destination', required=True)
    commands.add_parser('check-producer', help='inspect bounded capability JSON on stdin; never enables capture')
    args = parser.parse_args(argv)
    if args.operation == 'check-producer':
        from wacli_snapshot_protocol import MAX_CAPABILITY_BYTES, ProducerProtocolError, inspect_producer
        try:
            report = inspect_producer(sys.stdin.buffer.read(MAX_CAPABILITY_BYTES + 1))
        except (ProducerProtocolError, OSError) as error:
            diagnostic = (str(error) if isinstance(error, ProducerProtocolError)
                          else 'WACLI producer capability input unavailable.')
            print(json.dumps({'status': 'blocked', 'capture_enabled': False,
                              'complete': False, 'publishable': False,
                              'source_read': False, 'snapshot_consumed': False,
                              'error': diagnostic}, sort_keys=True))
            return 2
        print(json.dumps(report, sort_keys=True)); return 3
    report = capture(args.source_root, args.destination) if args.operation == 'capture' else capture_status()
    print(json.dumps(report, sort_keys=True)); return 3


if __name__ == '__main__':
    raise SystemExit(main())
