#!/usr/bin/env python3
"""Verify source-only boundary patches in disposable trees, never an account store.

This is a developer test command, not a capture or installation command. It
requires an existing WACLI source repository; no repository is cloned or edited.
Go may fetch the pinned public dependency using its normal checksum checks.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile

BASE = '5578d1b6892f50a8f2329b11a6b6e27a1a81f88b'
DEPENDENCY = 'go.mau.fi/whatsmeow@v0.0.0-20261017175727-b2b1e71d45e2'
PATCHES = Path(__file__).resolve().parent


def run(args, cwd, *, env=None, output=False):
    print('+ ' + ' '.join(map(str, args)), flush=True)
    return subprocess.run(list(map(str, args)), cwd=cwd, env=env, check=True,
                          stdout=subprocess.PIPE if output else None,
                          text=output).stdout


def checked_artifact(entry):
    name = entry['path']
    if not isinstance(name, str) or Path(name).is_absolute() or '..' in Path(name).parts:
        raise ValueError('Invalid runtime patch member')
    path = PATCHES / name
    if path.is_symlink() or not path.is_file():
        raise ValueError('Runtime patch must be a regular file')
    if hashlib.sha256(path.read_bytes()).hexdigest() != entry['sha256']:
        raise ValueError('Runtime patch digest mismatch')
    return path


def verify(source, full_gate=False):
    manifest = json.loads((PATCHES / 'runtime-series.json').read_text())
    if manifest['base'] != BASE or manifest['dependency'] != DEPENDENCY:
        raise ValueError('Unsupported runtime series')
    wacli_patches = [checked_artifact(p) for p in manifest['wacli']]
    dependency_patches = [checked_artifact(p) for p in manifest['whatsmeow']]
    # Query before replacing HOME, to reuse the compiler/package caches only.
    goenv = json.loads(run(['go', 'env', '-json', 'GOPATH', 'GOCACHE'], source, output=True))
    with tempfile.TemporaryDirectory(prefix='wacli-runtime-synthetic-') as temporary:
        root = Path(temporary)
        tree = root / 'wacli'; tree.mkdir()
        archive = root / 'source.tar'
        run(['git', 'archive', '--format=tar', '--output', archive, BASE], source)
        with tarfile.open(archive) as source_archive:
            source_archive.extractall(tree, filter='data')
        env = {k: v for k, v in os.environ.items() if not k.startswith('WACLI_')}
        home = root / 'home'; home.mkdir(mode=0o700)
        env.update(HOME=str(home), GOPATH=goenv['GOPATH'], GOCACHE=goenv['GOCACHE'],
                   GOWORK='off', GOFLAGS='', XDG_CONFIG_HOME=str(home / 'config'),
                   XDG_STATE_HOME=str(home / 'state'), XDG_DATA_HOME=str(home / 'data'))
        for artifact in wacli_patches:
            run(['git', 'apply', '--unidiff-zero', artifact], tree, env=env)
        metadata = json.loads(run(['go', 'mod', 'download', '-json', DEPENDENCY], tree,
                                  env=env, output=True))
        run(['go', 'mod', 'verify'], tree, env=env)
        dependency = root / 'whatsmeow'
        shutil.copytree(metadata['Dir'], dependency)
        for directory, _, files in os.walk(dependency):
            os.chmod(directory, 0o700)
            for name in files:
                os.chmod(Path(directory) / name, 0o600)
        for artifact in dependency_patches:
            run(['git', 'apply', '--unidiff-zero', artifact], dependency, env=env)
        run(['go', 'mod', 'edit', '-replace=go.mau.fi/whatsmeow=' + str(dependency)], tree, env=env)
        # The local replace exists only in this temporary source tree.
        for race in ([], ['-race']):
            run(['go', 'test', *race, './cmd/wacli', './internal/app', './internal/wa',
                 './internal/store', './internal/mediamembership',
                 '-run', manifest['wacli_test_pattern'], '-count=10', '-timeout=180s'], tree, env=env)
            run(['go', 'test', *race, '.', '-run', manifest['dependency_test_pattern'],
                 '-count=10', '-timeout=180s'], dependency, env=env)
        if full_gate:
            for command in ('format:check', 'lint', 'lint:deadcode', 'test', 'build', 'docs:site'):
                run(['pnpm', command], tree, env=env)
        plan = json.loads(run(['go', 'run', './cmd/wacli', 'store', 'snapshot', 'plan'],
                              tree, env=env, output=True))
        expected = {'protocol': 'wacli-coordinated-snapshot-v1', 'status': 'blocked',
                    'capture_enabled': False, 'complete': False, 'publishable': False,
                    'boundary': 'UNVERIFIED', 'cross_database_consistency': 'NOT_CERTIFIED',
                    'windows_validated': False}
        if plan != expected:
            raise ValueError('Runtime series changed the fixed blocked capability contract')
        synthetic_source = root / 'synthetic-source'
        synthetic_source.mkdir(mode=0o700)
        marker = synthetic_source / 'marker.bin'
        marker.write_bytes(b'synthetic fixture only')
        before = marker.stat()
        refusal = subprocess.run(['go', 'run', './cmd/wacli', '--store', str(synthetic_source),
                                  'store', 'snapshot', 'create'], cwd=tree, env=env,
                                 capture_output=True, text=True, check=False)
        after = marker.stat()
        if (refusal.returncode == 0 or 'snapshot create is blocked' not in refusal.stderr
                or set(synthetic_source.iterdir()) != {marker}
                or marker.read_bytes() != b'synthetic fixture only'
                or before.st_mtime_ns != after.st_mtime_ns):
            raise ValueError('Runtime series failed its synthetic no-capture refusal check')
        print('Synthetic verification finished. Capture remains disabled; no Windows runtime was tested.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--wacli-source', type=Path, required=True,
                        help='Existing source repository containing the exact pinned base object')
    parser.add_argument('--full-gate', action='store_true')
    args = parser.parse_args()
    verify(args.wacli_source.resolve(strict=True), args.full_gate)


if __name__ == '__main__':
    main()
