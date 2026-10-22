#!/usr/bin/env python3
"""Offline Linux recovery. Planning reads ZIP metadata only; never decrypts secrets.

Recovery preserves original ZIPs and verifies streamed copies. Native-path staging
is an export for review, not activation or proof of Linux runtime compatibility.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import stat
import sys
import unicodedata
from collections import Counter
from pathlib import Path, PurePosixPath
from zipfile import BadZipFile, ZipFile

VERSION = 2
CHUNK = 1024 * 1024
MAX_MEMBER_BYTES = 8 * 1024 ** 3
MAX_EXPANDED_BYTES = 100 * 1024 ** 3
BINARY_SUFFIXES = {'.exe', '.dll', '.msi', '.sys', '.com', '.scr', '.lnk', '.pdb', '.so', '.dylib', '.jar', '.class', '.pyc', '.wasm'}
CONTROL_FILES = {'scoopfile.json', 'scoop-allowed.json', 'winget-allowed.json', 'pnpm-allowed.json', 'pnpm-config.json', 'pnpm-globals.json', 'uv-allowed.json', 'uv-tools.json', 'go-allowed.json', 'pip-freeze.txt', 'tool-secrets.manifest.json'}
# Targets are relative to an OFFLINE home-staging tree, never the live home.
PERSIST_TARGETS = {
    'alist': '.local/share/alist', 'archisteamfarm': '.local/share/ArchiSteamFarm',
    'ffmpeg': '.config/ffmpeg', 'firefox': '.mozilla/firefox', 'ghidra': '.ghidra',
    'gradle': '.gradle', 'megatools': '.config/megatools', 'mpv': '.config/mpv',
    'mpv-git': '.config/mpv', 'rclone': '.config/rclone', 'syncplay': '.config/syncplay',
    'tesseract': '.local/share/tessdata', 'vlc': '.config/vlc', 'yt-dlp': '.config/yt-dlp',
}
PERSIST_BLOCKERS = {
    '7zip': 'Windows GUI/registry settings have no native p7zip import',
    'autohotkey': 'AutoHotkey scripts require a deliberate Linux automation rewrite',
    'bulk-crap-uninstaller': 'Windows uninstaller has no equivalent state import',
    'discordchatexporter': 'native runtime and settings adapter have not been validated',
    'ditto': 'Ditto is Windows-only; starred SQLite data is retained, not imported into another clipboard app',
    'git': 'Scoop Git settings mix Windows paths/helpers; use separately reviewed .gitconfig',
    'micmute': 'Windows audio bindings have no native state import',
    'mpc-hc': 'Windows-only player configuration', 'parsec': 'Windows host/identity state is not a Linux host restore',
    'proton-vpn': 'VPN credentials/network integration must be recreated through a native client',
    'pwsh': 'Windows PowerShell modules/profiles need explicit dependency/path review',
    'python312': 'Windows interpreter/native modules cannot be copied into Linux Python',
    'rufus': 'Windows-only disk utility configuration',
    'tor-browser': 'browser encryption, profile layout, and version migration are not validated',
    'v2rayn': 'Windows frontend profiles need an explicit native client adapter',
    'windhawk': 'Windows injection/modification framework has no Linux equivalent',
    'windows-terminal': 'Windows Terminal has no Linux runtime; preferences need a deliberate terminal port',
    'x64dbg': 'Windows debugger state/plugins have no native Linux runtime',
}
ACTION_BLOCKERS = [
    {'action': 'package-installation', 'reason': 'Not performed by data recovery; inspect linux_packages.py for explicit native package mappings.'},
    {'action': 'account-helpers', 'reason': 'Windows account helpers have not been ported; opaque profiles are not authenticated Linux sessions.'},
    {'action': 'browser-logins', 'reason': 'DPAPI/app-bound Windows browser encryption cannot be activated by copying files on Linux.'},
    {'action': 'registry-and-services', 'reason': 'Registry, Windows service identity, and shell integration require separately reviewed native adapters.'},
    {'action': 'scheduled-tasks', 'reason': 'Task XML is preserved; triggers, Windows commands, credentials, and timezones require a deliberate systemd/cron port.'},
    {'action': 'private-source-and-patches', 'reason': 'Private repository clone and Windows fork patch/build actions are not run by offline recovery.'},
    {'action': 'instruction-activation', 'reason': 'AGENTS.md and skills are preserved only; global agent instructions are never changed.'},
]


def safe_member(name):
    n = name.replace('\\', '/')
    parts = n.rstrip('/').split('/')
    if (not n or n.startswith('/') or any(x in ('', '.', '..') for x in parts)
            or any(':' in x for x in parts) or any(ord(c) < 32 for c in n)):
        return False, None
    return True, '/'.join(parts)


def link_or_special(info):
    kind = stat.S_IFMT(info.external_attr >> 16)
    return kind not in (0, stat.S_IFREG, stat.S_IFDIR)


def zip_signature(infos):
    records = [(i.filename, i.CRC, i.file_size, i.compress_size, i.flag_bits,
                i.external_attr, i.compress_type, i.header_offset) for i in infos]
    return hashlib.sha256(json.dumps(records, ensure_ascii=True).encode()).hexdigest()


def classify(path, archive=''):
    """Return explicit category, reason, optional native-relative export target."""
    low = path.lower()
    p = PurePosixPath(path)
    if low.endswith(('.zip', '.7z')):
        return 'opaque-archive', 'Nested archive preserved unopened; encrypted secrets require a separately authorized export/unlock workflow.', None
    if low.endswith(('.dpapi', '.enc')) or p.name == '.encryption_key':
        return 'blocked', 'Encrypted/key material preserved, never decrypted or claimed usable.', None
    if p.name.lower() in ('agents.md', 'agent.md') or low.startswith(('.agents/', 'userprofile/.agents/')):
        return 'blocked', 'Agent instructions/skills are retained, never activated or written globally.', None
    if p.suffix.lower() in BINARY_SUFFIXES or p.suffix.lower() in {'.ps1', '.cmd', '.bat', '.reg'}:
        return 'blocked', 'Windows scripts/registry or platform-dependent binary require a native replacement.', None
    if low.startswith('scheduled-tasks/'):
        return 'blocked', 'Windows task triggers/actions need a reviewed systemd/cron translation.', None
    if low.startswith('edge-profile/'):
        return 'blocked', 'Browser data retained; Windows encryption, extension policies, and signatures are not migrated.', None
    if p.name in CONTROL_FILES:
        return 'metadata', 'Package/control manifest retained verbatim; no command is executed.', None
    if path == '.gitconfig':
        return 'review-required', 'Git helpers/includes/signing paths need review; original is retained, not activated.', None
    if path.startswith('UserProfile/'):
        rel = path[len('UserProfile/'):]
        if rel.startswith(('.ssh/', '.opencode/', '.config/opencode/', '.local/share/opencode/')) or rel == '.wakatime.cfg':
            return 'native-staging', 'Native-relative config export only; Windows paths/plugins/auth still need validation.', rel
        return 'blocked', 'UserProfile path has no validated native adapter; retained without activation.', None
    if low.startswith(('secrets/', 'appdata/', 'localappdata/')):
        return 'blocked', 'Opaque account/application profile retained; no blanket AppData-to-XDG substitution is safe.', None
    if low.startswith(('native/', 'winget-persist/')):
        return 'blocked', 'AnyDesk/Directory Opus or other native Windows state requires app-specific identity/config migration.', None
    if low.startswith('obs-studio/'):
        return 'native-staging', 'OBS export needs source paths, devices, encoders, and plugins relinked.', '.config/obs-studio/' + path.split('/', 1)[1]
    if low.startswith('qbittorrent/'):
        tail = path.split('/', 1)[1]
        if tail.startswith('BT_backup/'):
            return 'native-staging', 'Torrent metadata only; download files absent and Windows save paths require relinking.', '.local/share/qBittorrent/' + tail
        return 'native-staging', 'qBittorrent export needs path/client-version review before use.', '.config/qBittorrent/' + tail
    for prefix in ('persist/', 'quick-persist/'):
        if low.startswith(prefix):
            pieces = path.split('/', 2)
            app = pieces[1].lower()
            if app in PERSIST_BLOCKERS:
                return 'blocked', PERSIST_BLOCKERS[app], None
            if app == 'flameshot' and len(pieces) == 3:
                return 'native-staging', 'Flameshot config export; review desktop shortcuts, paths, and INI version.', '.config/flameshot/' + pieces[2]
            if app in PERSIST_TARGETS and len(pieces) == 3:
                return 'native-staging', 'Native-path export candidate; layout/path/plugin compatibility remains unverified.', PERSIST_TARGETS[app] + '/' + pieces[2]
            return 'unknown', 'Persist application/path lacks an implemented native adapter; raw data is retained.', None
    if low.startswith(('repo/', 'repos/', 'downloads/')):
        return 'native-staging', 'Source files retained; dependencies and Windows scripts need review.', path
    return 'unknown', 'No native adapter exists for this item; retained and explicitly unresolved.', None


def discover(root, mode):
    sources = sorted(root.glob('*.zip'))
    if mode == 'quick':
        sources = [p for p in sources if p.name != 'mainframe-persist.zip']
    return sources


def inventory(root, manifest_path=None, mode='full'):
    root = Path(root)
    errors, archives, entries = [], [], []
    if not root.is_dir() or root.is_symlink():
        return [], [], ['Backup root must be a real directory, not a symlink.']
    sources = discover(root, mode)
    names = {p.name for p in sources}
    if not ({'mainframe-quick.zip', 'mainframe-backup.zip'} & names):
        errors.append('Missing mainframe-quick.zip or mainframe-backup.zip; standalone secrets alone are not a full machine backup.')
    if mode == 'full' and 'mainframe-backup.zip' not in names and 'mainframe-persist.zip' not in names:
        errors.append('Full mode requires mainframe-persist.zip; use --mode quick only for an explicitly partial inventory.')
    for loose in root.iterdir():
        if loose.name not in names and not (mode == 'quick' and loose.name == 'mainframe-persist.zip') and loose.name != 'tool-secrets.manifest.json':
            errors.append('Unexpected loose input present: use a ZIP-only input directory (loose trees are not silently ignored).')
            break
    for src in sources:
        if src.is_symlink() or not src.is_file():
            errors.append('ZIP input must be a regular, non-symlink file.')
            continue
        rec = {'name': src.name, 'size': src.stat().st_size, 'entries': 0}
        try:
            with ZipFile(src) as z:
                infos = z.infolist()
                rec['metadata_signature'] = zip_signature(infos)
                counts = Counter(safe_member(i.filename)[1] for i in infos)
                folded = Counter(unicodedata.normalize('NFC', safe_member(i.filename)[1] or '').casefold() for i in infos)
                file_names = {safe_member(i.filename)[1] for i in infos if not i.is_dir()}
                conflict_names = set()
                for name in counts:
                    if name:
                        parents = PurePosixPath(name).parents
                        for parent in parents:
                            if str(parent) != '.' and str(parent) in file_names:
                                conflict_names.update((name, str(parent)))
                for info in infos:
                    ok, norm = safe_member(info.filename)
                    category, reason, target = classify(norm or info.filename, src.name)
                    problem = None
                    if not ok:
                        problem = 'Unsafe path: absolute, traversal, drive, empty segment, or control character.'
                    elif counts[norm] > 1:
                        problem = 'Duplicate normalized member path; all duplicates remain raw-only.'
                    elif folded[unicodedata.normalize('NFC', norm).casefold()] > 1:
                        problem = 'Case/Unicode-normalized collision; all conflicting names remain raw-only.'
                    elif norm in conflict_names:
                        problem = 'File/directory prefix collision; conflicting entries remain raw-only.'
                    elif link_or_special(info):
                        problem = 'Symlink/special entry remains raw-only; no filesystem link is created.'
                    elif info.flag_bits & 1:
                        problem = 'Encrypted ZIP member remains raw-only; no decryption is attempted.'
                    e = {'archive': src.name, 'path': info.filename, 'normalized_path': norm,
                         'category': category, 'reason': reason, 'is_dir': info.is_dir(),
                         'size': info.file_size, 'compressed_size': info.compress_size,
                         'crc32': f'{info.CRC:08x}', 'status': 'metadata-only', 'native_target': target}
                    if problem:
                        e.update(category='blocked', reason=problem, materialization_blocked=True, native_target=None)
                    entries.append(e)
                rec['entries'] = len(infos)
                if len(infos) > 1000000:
                    errors.append('Archive entry count exceeds the safety limit.')
        except (BadZipFile, OSError, ValueError) as exc:
            rec['error'] = type(exc).__name__
            errors.append(f'{src.name}: unreadable ZIP metadata ({type(exc).__name__}).')
        archives.append(rec)
    # This is the PUBLIC manifest, never extracted secret payloads.
    mp = Path(manifest_path) if manifest_path else Path(__file__).with_name('tool-secrets.manifest.json')
    try:
        manifest = json.loads(mp.read_text(encoding='utf-8'))
        if not isinstance(manifest.get('items'), list):
            raise ValueError('items must be a list')
        if not all(isinstance(item, dict) and isinstance(item.get('archivePath'), str)
                   and safe_member(item['archivePath'])[0] for item in manifest['items']):
            raise ValueError('Every manifest item must have a safe relative archivePath.')
    except (OSError, ValueError, AttributeError):
        errors.append('Cannot load public secret-path manifest; coverage cannot be claimed.')
        manifest = {'items': []}
    for item in manifest['items']:
        ap = str(item.get('archivePath', ''))
        match = any(e.get('normalized_path') == ap or (e.get('normalized_path') or '').startswith(ap + '/') for e in entries)
        entries.append({'archive': 'manifest-coverage', 'path': ap, 'category': 'disabled' if item.get('disabled') else 'secret-coverage',
                        'status': 'excluded-by-backup' if item.get('disabled') else ('present-opaque-or-unverified' if match else 'not-visible-in-outer-archives'),
                        'reason': 'Disabled at backup time: cannot reconstruct omitted data.' if item.get('disabled') else 'Encrypted nested payload is not inspected/decrypted; presence/usability is unverified.',
                        'is_dir': False, 'size': 0})
    return archives, entries, errors


def safe_dest(destination, source):
    destination = Path(destination).absolute()
    source = Path(source).resolve()
    if destination.exists() or destination.is_symlink():
        raise ValueError('Destination already exists or is a symlink; nothing may be overwritten.')
    if destination == source or source in destination.parents:
        raise ValueError('Destination cannot be inside the backup source.')
    for part in [destination.parent, *destination.parent.parents]:
        if part.is_symlink():
            raise ValueError('Destination parent contains a symlink.')
    if not destination.parent.is_dir():
        raise ValueError('Destination parent must already exist; no implicit parent creation.')
    destination.mkdir(mode=0o700)
    return destination


def secure_directory(path, create=False):
    """Open an absolute directory by walking no-follow descriptors on Linux."""
    path = Path(path).absolute()
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    fd = os.open('/', flags)
    try:
        for part in path.parts[1:]:
            if part in ('.', '..'):
                raise ValueError('Non-canonical output path.')
            if create:
                try:
                    os.mkdir(part, mode=0o700, dir_fd=fd)
                except FileExistsError:
                    pass
            nxt = os.open(part, flags, dir_fd=fd)
            os.close(fd)
            fd = nxt
        return fd
    except BaseException:
        os.close(fd)
        raise


def private_file(path):
    fd = secure_directory(path.parent)
    try:
        out = os.open(path.name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=fd)
        return os.fdopen(out, 'wb')
    finally:
        os.close(fd)


def make_private_dirs(path):
    os.close(secure_directory(path, create=True))


def stream_copy(source, target, limit=None):
    digest = hashlib.sha256()
    size = 0
    with private_file(target) as out:
        while True:
            block = source.read(CHUNK)
            if not block:
                break
            if limit is not None and size + len(block) > limit:
                raise ValueError('Stream exceeds its declared/safety size limit.')
            out.write(block)
            digest.update(block)
            size += len(block)
        out.flush()
        os.fsync(out.fileno())
    return digest.hexdigest(), size


def file_hash(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        while block := stream.read(CHUNK):
            digest.update(block)
    return digest.hexdigest()


def write_private_json(path, obj):
    data = (json.dumps(obj, indent=2, sort_keys=True) + '\n').encode('utf-8')
    with private_file(path) as out:
        out.write(data)
        out.flush()
        os.fsync(out.fileno())


def copy_recovery(root, destination, apply_portable=False, manifest_path=None, mode='full',
                  max_member_bytes=MAX_MEMBER_BYTES, max_expanded_bytes=MAX_EXPANDED_BYTES):
    root = Path(root)
    archives, entries, errors = inventory(root, manifest_path, mode)
    expanded = sum(e['size'] for e in entries if not e.get('materialization_blocked'))
    if max_member_bytes <= 0 or max_expanded_bytes <= 0:
        errors.append('Extraction safety limits must be positive.')
    if expanded > max_expanded_bytes or any(e['size'] > max_member_bytes for e in entries):
        errors.append('Expanded data exceeds the configured safety limits; review archive metadata and raise limits explicitly if appropriate.')
    if errors:
        raise ValueError('Input preflight failed: ' + '; '.join(errors))
    needed = sum(a['size'] for a in archives) + expanded * (2 if apply_portable else 1)
    if Path(destination).parent.is_dir() and shutil.disk_usage(Path(destination).parent).free < needed:
        raise ValueError('Insufficient free space for verified raw archives and offline materialization.')
    destination = safe_dest(destination, root)
    report = {'version': VERSION, 'mode': mode, 'archives': archives, 'entries': entries, 'errors': [],
              'data_preservation_status': 'in-progress', 'operational_status': 'incomplete', 'complete': False,
              'action_blockers': ACTION_BLOCKERS,
              'limitations': ['Every original ZIP is retained byte-for-byte; unsafe/encrypted members remain in that raw ZIP.',
                              'Native targets are OFFLINE export candidates only. No settings, tasks, services, packages, credentials, or global instructions are activated.']}
    try:
        raw = destination / 'raw-archives'
        raw.mkdir(mode=0o700)
        recovered = destination / 'recovered'
        recovered.mkdir(mode=0o700)
        stage = destination / 'home-staging'
        if apply_portable:
            stage.mkdir(mode=0o700)
        for arc in archives:
            src = root / arc['name']
            partial = raw / (arc['name'] + '.partial')
            with os.fdopen(os.open(src, os.O_RDONLY | os.O_NOFOLLOW), 'rb') as stream:
                before = os.fstat(stream.fileno())
                digest, size = stream_copy(stream, partial, arc['size'])
                after = os.fstat(stream.fileno())
            if (before.st_size, before.st_mtime_ns, before.st_ctime_ns, before.st_ino) != (after.st_size, after.st_mtime_ns, after.st_ctime_ns, after.st_ino):
                raise ValueError('Input ZIP changed during copying; recovery is incomplete.')
            if size != arc['size'] or file_hash(partial) != digest:
                raise ValueError('Raw archive copy verification failed.')
            with ZipFile(partial) as snapshot:
                if zip_signature(snapshot.infolist()) != arc['metadata_signature']:
                    raise ValueError('ZIP metadata changed after preflight; no members will be materialized.')
            os.rename(partial, raw / arc['name'])
            arc.update(sha256=digest, raw_copy_verified=True)
            # Read only the copied, immutable snapshot, with one ZIP handle per archive.
            with ZipFile(raw / arc['name']) as z:
                member_entries = [e for e in entries if e['archive'] == arc['name']]
                for info, e in zip(z.infolist(), member_entries):
                    if e.get('materialization_blocked'):
                        e['status'] = 'raw-only'
                        continue
                    target = recovered / arc['name'] / e['normalized_path']
                    if e['is_dir']:
                        make_private_dirs(target)
                        e['status'] = 'directory-preserved'
                        continue
                    make_private_dirs(target.parent)
                    try:
                        with z.open(info) as stream:
                            digest, size = stream_copy(stream, target, min(e['size'], max_member_bytes))
                        if size != e['size'] or file_hash(target) != digest:
                            raise ValueError('Materialized member verification failed.')
                        e.update(sha256=digest, status='bytes-preserved')
                        if apply_portable and e.get('native_target'):
                            out = stage / e['native_target']
                            make_private_dirs(out.parent)
                            if out.exists() or out.is_symlink():
                                e.update(status='staging-conflict', reason='Native export collision; both originals retained separately in recovered/.')
                                continue
                            with target.open('rb') as stream:
                                staged_hash, _ = stream_copy(stream, out, e['size'])
                            if staged_hash != digest:
                                raise ValueError('Native staging copy failed verification.')
                            e.update(status='native-staged-unverified', portable_target=str(out.relative_to(destination)))
                    except (OSError, ValueError, RuntimeError, NotImplementedError, BadZipFile) as exc:
                        e.update(status='raw-only-error', error=type(exc).__name__)
                        if target.is_file() and not target.is_symlink():
                            target.unlink()
                        report['errors'].append('Member materialization failed; raw ZIP retained. See private entry status.')
        report['data_preservation_status'] = 'raw-archives-verified' if not report['errors'] else 'raw-verified-with-materialization-errors'
        report['preserved_raw_bytes'] = sum(a['size'] for a in archives)
    except (OSError, ValueError, RuntimeError, BadZipFile) as exc:
        report['errors'].append(type(exc).__name__ + ': ' + str(exc))
        report['data_preservation_status'] = 'failed'
    finally:
        for partial in (destination / 'raw-archives').glob('*.partial'):
            if partial.is_file() and not partial.is_symlink():
                partial.unlink()
        report['category_counts'] = dict(Counter(e['category'] for e in entries))
        write_private_json(destination / 'restore-manifest.json', report)
    return report


def main(argv=None):
    parser = argparse.ArgumentParser(description='Metadata-only Linux recovery planning; never an automatic live machine restore.')
    parser.add_argument('backup', type=Path)
    parser.add_argument('--mode', choices=('quick', 'full'), default='full')
    group = parser.add_mutually_exclusive_group()
    group.add_argument('--inventory', action='store_true', help='metadata-only plan (default): does not read/decrypt member payloads')
    group.add_argument('--recover', action='store_true', help='preserve ZIPs and materialize safe members in a NEW offline directory')
    parser.add_argument('--destination', type=Path)
    parser.add_argument('--apply-portable', action='store_true', help='also export native-path candidates to offline home-staging, NOT live HOME')
    parser.add_argument('--manifest', type=Path, help='public path manifest; never a credential payload')
    parser.add_argument('--max-member-bytes', type=int, default=MAX_MEMBER_BYTES)
    parser.add_argument('--max-expanded-bytes', type=int, default=MAX_EXPANDED_BYTES)
    args = parser.parse_args(argv)
    if args.apply_portable and not args.recover:
        parser.error('--apply-portable requires --recover')
    if args.destination and not args.recover:
        parser.error('--destination requires --recover')
    if args.recover:
        if not args.destination:
            parser.error('--recover requires --destination')
        try:
            report = copy_recovery(args.backup, args.destination, args.apply_portable, args.manifest, args.mode,
                                   args.max_member_bytes, args.max_expanded_bytes)
        except (ValueError, OSError) as exc:
            print('BLOCKED: ' + str(exc), file=sys.stderr)
            return 2
        print(json.dumps({k: report[k] for k in ('data_preservation_status', 'operational_status', 'category_counts')}, sort_keys=True))
        return 2 if report['errors'] else 3
    archives, entries, errors = inventory(args.backup, args.manifest, args.mode)
    report = {'version': VERSION, 'mode': args.mode, 'archives': archives, 'entries': entries, 'errors': errors,
              'operational_status': 'incomplete', 'action_blockers': ACTION_BLOCKERS,
              'category_counts': dict(Counter(e['category'] for e in entries)),
              'notice': 'Metadata only. No payload was read, extracted, hashed, or decrypted. Full operational parity is NOT implemented.'}
    print(json.dumps(report, indent=2, sort_keys=True))
    return 2 if errors else 3


if __name__ == '__main__':
    raise SystemExit(main())
