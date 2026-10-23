#!/usr/bin/env python3
"""Explicit WACLI v0.15 state preservation; never install or execute WACLI.

Only caller-selected roots are read. No config, SQL, message or credential is
parsed. Captures require stopped writers, existing upstream LOCKs and no SQLite
sidecars; bytes are not normalized or checkpointed. See docs/linux-wacli-state.md.
"""
from __future__ import annotations

import argparse
from contextlib import ExitStack
import fcntl
import getpass
import hashlib
import json
import os
from pathlib import Path
import stat
import sys
import tempfile
import unicodedata
from zipfile import ZipFile, ZIP_DEFLATED

from linux_restore import (CHUNK, MAX_MEMBER_BYTES, MAX_EXPANDED_BYTES,
                           secure_directory, safe_member,
                           link_or_special, stream_copy, make_private_dirs)
from wacli_restore_contract import WINDOWS_PREFIX, restoration_status

PREFIX = 'NativeState/wacli/'
SIDECARS = ('-wal', '-shm', '-journal')


class StateError(ValueError):
    """A fixed, payload-free diagnostic safe to show at the CLI boundary."""


def aes_zip():
    try:
        import pyzipper
    except ImportError:
        raise StateError('AES ZIP support unavailable: pyzipper is required; capture/decryption blocked, no plaintext fallback.') from None
    return pyzipper


def stream_hash(stream):
    digest = hashlib.sha256()
    while block := stream.read(CHUNK):
        digest.update(block)
    return digest.hexdigest()


def stamp(s):
    return (s.st_dev, s.st_ino, s.st_mode, s.st_size, s.st_mtime_ns, s.st_ctime_ns)


def absolute_path(path):
    path = Path(path)
    if not path.is_absolute() or '..' in path.parts:
        raise StateError('An explicit absolute canonical path is required.')
    return path


def scan(root):
    """Metadata only, including hidden files. Never follow links or skip files."""
    root = absolute_path(root)
    os.close(secure_directory(root))
    records = {}
    def fail_walk(error):
        raise error
    for base, dirs, files in os.walk(root, followlinks=False, onerror=fail_walk):
        for name in sorted(dirs + files):
            path = Path(base) / name
            s = path.lstat()
            rel = path.relative_to(root).as_posix()
            if not safe_member(rel)[0] or stat.S_ISLNK(s.st_mode) or not (stat.S_ISDIR(s.st_mode) or stat.S_ISREG(s.st_mode)) or (stat.S_ISREG(s.st_mode) and s.st_nlink != 1):
                raise StateError('State contains an unsafe name, link, or special file; capture blocked.')
            if name.endswith(SIDECARS):
                raise StateError('SQLite WAL/SHM/journal present: stop all writers and obtain a clean closed store; capture blocked, no sidecar is ignored.')
            records[rel] = stamp(s)
    if len(records) > 100000 or sum(s[3] for s in records.values() if stat.S_ISREG(s[2])) > MAX_EXPANDED_BYTES:
        raise StateError('State exceeds safety limits.')
    folded = [unicodedata.normalize('NFC', k).casefold() for k in records]
    if len(set(folded)) != len(folded):
        raise StateError('State contains case/Unicode collisions.')
    return records


def opened_file(root, rel):
    parent = secure_directory(root / Path(rel).parent)
    try:
        fd = os.open(Path(rel).name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
    finally:
        os.close(parent)
    stream = os.fdopen(fd, 'rb')
    if not stat.S_ISREG(os.fstat(fd).st_mode):
        stream.close()
        raise StateError('State input is not a regular file.')
    return stream


def snapshot(root, output, quiesced=False):
    """Internal private staging; caller must encrypt before publishing anything."""
    if not quiesced:
        raise StateError('Explicit --quiesced attestation required: stop all WACLI and other writers first.')
    root = absolute_path(root)
    before = scan(root)
    if not before:
        raise StateError('State root is empty; no recoverable state captured.')
    locks = [rel for rel in before if Path(rel).name == 'LOCK' and stat.S_ISREG(before[rel][2])]
    for rel, s in before.items():
        if stat.S_ISREG(s[2]) and Path(rel).suffix.lower() in ('.db', '.sqlite', '.sqlite3'):
            lock = (Path(rel).parent / 'LOCK').as_posix()
            if lock not in locks:
                raise StateError('Database lacks an existing upstream LOCK; capture blocked without modifying the source.')
    with ExitStack() as stack:
        for rel in sorted(locks):
            handle = stack.enter_context(opened_file(root, rel))
            if stamp(os.fstat(handle.fileno())) != before[rel]:
                raise StateError('State changed during lock acquisition.')
            try:
                fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise StateError('WACLI store is active/locked; capture blocked.') from None
        if scan(root) != before:
            raise StateError('State changed during lock acquisition.')
        with ZipFile(output, 'x', compression=ZIP_DEFLATED, allowZip64=True) as z:
            for rel, s in sorted(before.items()):
                name = PREFIX + rel
                if stat.S_ISDIR(s[2]):
                    z.writestr(name + '/', b'')
                    continue
                if s[3] > MAX_MEMBER_BYTES:
                    raise StateError('State member exceeds safety limit.')
                with opened_file(root, rel) as source, z.open(name, 'w', force_zip64=True) as target:
                    if stamp(os.fstat(source.fileno())) != s:
                        raise StateError('State changed before copy.')
                    size = 0
                    while block := source.read(CHUNK):
                        size += len(block)
                        if size > s[3]:
                            raise StateError('State changed during copy.')
                        target.write(block)
                    if size != s[3] or stamp(os.fstat(source.fileno())) != s:
                        raise StateError('State changed during copy.')
        if scan(root) != before:
            raise StateError('State changed during snapshot; no capture published.')
    return len(before)


def destination_parent(destination, source):
    destination = absolute_path(destination)
    source = absolute_path(source)
    home = Path.home().resolve()
    if destination in (home, Path('/')) or destination == source or source in destination.parents or destination in source.parents:
        raise StateError('Destination overlaps source or live home root.')
    for live in (home / '.local/state/wacli', home / '.wacli'):
        if destination == live or live in destination.parents or destination in live.parents:
            raise StateError('Live default WACLI state destination is blocked; choose a new offline export.')
    fd = secure_directory(destination.parent)
    try:
        try:
            os.stat(destination.name, dir_fd=fd, follow_symlinks=False)
        except FileNotFoundError:
            return fd
        raise StateError('Destination already exists; nothing may be overwritten.')
    except BaseException:
        os.close(fd)
        raise


def publish_tree(temporary, destination, parent_fd):
    # Reserve a NEW destination with descriptor-relative mkdir, never rename over
    # an existing directory. Contents are copied with O_EXCL/no-follow helpers.
    os.mkdir(destination.name, 0o700, dir_fd=parent_fd)
    outfd = os.open(destination.name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent_fd)
    try:
        for base, dirs, files in os.walk(temporary):
            relative = Path(base).relative_to(temporary)
            target_fd = os.dup(outfd)
            try:
                for part in relative.parts:
                    nxt = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=target_fd)
                    os.close(target_fd)
                    target_fd = nxt
                for name in dirs:
                    os.mkdir(name, 0o700, dir_fd=target_fd)
                for name in files:
                    fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=target_fd)
                    expected = hashlib.sha256()
                    with os.fdopen(fd, 'wb') as out, (Path(base) / name).open('rb') as inp:
                        while block := inp.read(CHUNK):
                            expected.update(block)
                            out.write(block)
                        out.flush()
                        os.fsync(out.fileno())
                    verifyfd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=target_fd)
                    with os.fdopen(verifyfd, 'rb') as verify:
                        if stream_hash(verify) != expected.hexdigest():
                            raise StateError('Publication byte verification failed.')
            finally:
                os.close(target_fd)
    finally:
        os.close(outfd)


def capture(root, destination, password, quiesced=False):
    provider = aes_zip()  # fail before reading state or making a destination
    if not password:
        raise StateError('A non-empty archive password is required.')
    root, destination = absolute_path(root), absolute_path(destination)
    parent = destination_parent(destination, root)
    try:
        with tempfile.TemporaryDirectory(prefix='mainframe-wacli-') as work:
            work = Path(work)
            inner = work / 'tool-secrets.zip'
            count = snapshot(root, inner, quiesced)
            ready = work / 'ready'
            ready.mkdir(mode=0o700)
            with provider.AESZipFile(ready / 'mainframe-secrets.zip', 'w', compression=provider.ZIP_DEFLATED, encryption=provider.WZ_AES) as z:
                z.setpassword(password)
                z.setencryption(provider.WZ_AES, nbits=256)
                z.write(inner, 'tool-secrets.zip')
            # Authenticate and byte-verify the complete inner ZIP before publication.
            with provider.AESZipFile(ready / 'mainframe-secrets.zip') as z:
                z.setpassword(password)
                with z.open('tool-secrets.zip') as stream:
                    digest = stream_hash(stream)
            with inner.open('rb') as stream:
                expected = stream_hash(stream)
            if digest != expected:
                raise StateError('Encrypted archive verification failed.')
            publish_tree(ready, destination, parent)
            return {'status': 'encrypted-state-preserved', 'entries': count, 'activation': 'not-performed',
                    'restoration': restoration_status('explicit-native-root-encrypted'),
                    'coverage': 'explicit-root-only; external configured stores are not followed'}
    finally:
        os.close(parent)


def restore_unlocked(archive, destination):
    """Restore ONLY NativeState/wacli from explicitly unlocked tool-secrets.zip."""
    archive, destination = absolute_path(archive), absolute_path(destination)
    parent = destination_parent(destination, archive)
    try:
        with opened_file(archive.parent, archive.name) as raw, ZipFile(raw) as z:
            members = [i for i in z.infolist()
                       if i.filename.replace('\\', '/').startswith(PREFIX)
                       and not (i.filename == PREFIX and i.is_dir()
                                and not link_or_special(i) and not i.flag_bits & 1)]
            if not members:
                raise StateError('No native WACLI state found; Windows profiles are not a Linux migration.')
            seen, files = set(), set()
            total = 0
            for i in members:
                ok, norm = safe_member(i.filename)
                key = unicodedata.normalize('NFC', (norm or '')).casefold()
                if not ok or not norm.startswith(PREFIX) or '\\' in i.filename or link_or_special(i) or i.flag_bits & 1 or key in seen:
                    raise StateError('Unsafe, duplicate or encrypted native state member.')
                seen.add(key)
                rel = norm[len(PREFIX):]
                if not rel or Path(rel).name.endswith(SIDECARS):
                    raise StateError('Unclean or invalid native state snapshot.')
                if not i.is_dir():
                    files.add(key)
                total += i.file_size
                if i.file_size > MAX_MEMBER_BYTES or total > MAX_EXPANDED_BYTES or len(members) > 100000:
                    raise StateError('State archive exceeds safety limits.')
            if any(unicodedata.normalize('NFC', str(p)).casefold() in files for i in members for p in Path(i.filename.rstrip('/')).parents):
                raise StateError('State archive has file/directory collisions.')
            with tempfile.TemporaryDirectory(prefix='mainframe-wacli-restore-') as work:
                work = Path(work)
                state = work / 'state'
                state.mkdir(mode=0o700)
                for i in members:
                    out = state / i.filename[len(PREFIX):]
                    if i.is_dir():
                        make_private_dirs(out)
                    else:
                        make_private_dirs(out.parent)
                        with z.open(i) as inp:
                            _, size = stream_copy(inp, out, i.file_size)
                        if size != i.file_size:
                            raise StateError('State member verification failed.')
                publish_tree(state, destination, parent)
            return {'status': 'offline-state-staged', 'entries': len(members), 'activation': 'not-performed',
                    'restoration': restoration_status('explicit-native-root-offline-staged')}
    finally:
        os.close(parent)


def plan_windows_unlocked(archive):
    """ZIP central-directory assessment ONLY. Never read members or open SQLite.

    This is deliberately not a migration adapter: the existing archive contract
    cannot prove producing versions, store completeness or SQLite consistency.
    A plausible file pair must not promote the assessment to ready/complete.
    """
    archive = absolute_path(archive)
    with opened_file(archive.parent, archive.name) as raw, ZipFile(raw) as z:
        infos = z.infolist()
        if len(infos) > 100000:
            raise StateError('State archive exceeds safety limits.')
        members = []
        for i in infos:
            normalized = i.filename.replace('\\', '/')
            if normalized.casefold().startswith(WINDOWS_PREFIX.casefold()):
                members.append(i)
        seen, files = set(), set()
        total = sidecars = 0
        stores = {}
        for i in members:
            ok, norm = safe_member(i.filename)
            key = unicodedata.normalize('NFC', norm or '').casefold()
            if not ok or link_or_special(i) or i.flag_bits & 1 or key in seen:
                raise StateError('Unsafe, duplicate or encrypted Windows state member.')
            seen.add(key)
            total += i.file_size
            if i.file_size > MAX_MEMBER_BYTES or total > MAX_EXPANDED_BYTES:
                raise StateError('State archive exceeds safety limits.')
            if not i.is_dir():
                files.add(key)
                sidecars += Path(norm).name.casefold().endswith(SIDECARS)
                name = Path(norm).name.casefold()
                if name in ('session.db', 'wacli.db'):
                    stores.setdefault(str(Path(key).parent), set()).add(name)
        if any(str(p) in files for key in seen for p in Path(key).parents):
            raise StateError('State archive has file/directory collisions.')
    report = restoration_status('not-inspected')
    report.update(status='blocked', assessment='zip-metadata-only',
                  windows_entries=len(members), sqlite_sidecars=sidecars,
                  candidate_store_pairs=sum(names == {'session.db', 'wacli.db'} for names in stores.values()),
                  member_payloads_read=False,
                  notice='Counts do not prove a WACLI store, schema, completeness, SQLite consistency or usable login; no data is extracted or converted.')
    if not members:
        report['blockers'].insert(0, {'code': 'windows-profile-not-visible',
                                     'requires': 'An explicitly unlocked tool-secrets.zip with the standard Windows WhatsApp profile subtree; encrypted nested members are never opened.'})
    return report


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='operation', required=True)
    plan = sub.add_parser('plan', help='read filenames/metadata only, no payload, defaults or config discovery')
    plan.add_argument('--state-root', type=Path, required=True)
    cap = sub.add_parser('capture', help='new encrypted envelope only; never modify an existing backup')
    cap.add_argument('--state-root', type=Path, required=True)
    cap.add_argument('--destination', type=Path, required=True)
    cap.add_argument('--quiesced', action='store_true')
    restore = sub.add_parser('restore-unlocked', help='explicit authorized unlocked ZIP -> NEW offline directory only')
    restore.add_argument('--archive', type=Path, required=True)
    restore.add_argument('--destination', type=Path, required=True)
    windows = sub.add_parser('plan-windows-unlocked', help='metadata-only BLOCKED assessment; never extracts, migrates, installs or activates')
    windows.add_argument('--archive', type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        if args.operation == 'plan-windows-unlocked':
            print(json.dumps(plan_windows_unlocked(args.archive), sort_keys=True))
            return 3  # incomplete, not a successful migration
        elif args.operation == 'plan':
            result = {'status': 'metadata-only', 'entries': len(scan(args.state_root)),
                      'restoration': restoration_status('not-inspected'),
                      'capture_requires': 'quiesced writers, existing store LOCKs, no sidecars, AES ZIP provider'}
        elif args.operation == 'capture':
            if not args.quiesced:
                raise StateError('--quiesced is required; stop writers before capture.')
            aes_zip()
            result = capture(args.state_root, args.destination, getpass.getpass('Archive password: ').encode(), True)
        else:
            result = restore_unlocked(args.archive, args.destination)
        print(json.dumps(result, sort_keys=True))
        return 0
    except StateError as exc:
        print('BLOCKED: ' + str(exc), file=sys.stderr)
        return 2
    except Exception:
        # No library/parser error text can leak state paths, passwords or payload.
        print('BLOCKED: state preservation preflight or verification failed; see documented requirements. No activation performed.', file=sys.stderr)
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
