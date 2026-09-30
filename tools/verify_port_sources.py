#!/usr/bin/env python3
"""Verify indexed port evidence; optionally replay QEMU in a disposable Git index.

This does not build binaries, certify a combined application's license, fetch
sources, or modify the supplied upstream checkout, its index or its references.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import tempfile

from check_public_source import index_entries, read_index_blobs

QEMU = 'ports/qemu-11.1/'
VNC = 'ports/libvnc/'


def digest(data):
    return hashlib.sha256(data).hexdigest()


def safe_path(path):
    if (not isinstance(path, str) or not path or
            not re.fullmatch(r'[A-Za-z0-9_./+-]+', path) or
            PurePosixPath(path).is_absolute() or
            any(p in ('', '.', '..', '.git') for p in path.split('/'))):
        raise ValueError('Unsafe source member path')
    return path


def object_id(value):
    if not isinstance(value, str) or not re.fullmatch('[0-9a-f]{40}', value):
        raise ValueError('Expected a full Git object id')
    return value


def evidence(files, item, prefix=''):
    path = prefix + safe_path(item['path'])
    if path not in files or digest(files[path]) != item.get('sha256'):
        raise ValueError('Missing or changed source evidence: ' + path)
    return files[path]


def validate_qemu(files):
    manifest = json.loads(files['manifest.json'])
    if manifest.get('schemaVersion') != 1:
        raise ValueError('Unsupported QEMU port schema')
    for value in (manifest['upstream']['commit'], manifest['upstream']['tree'],
                  manifest['downstream']['commit'], manifest['downstream']['tree'],
                  manifest['exportedTree']):
        object_id(value)
    patch = evidence(files, manifest['downstream']['patch'])
    if not patch.startswith(b'diff --git ') or b'GIT binary patch' in patch:
        raise ValueError('Expected a text-only downstream patch')
    if not manifest['licenses'] or not manifest['overlay']:
        raise ValueError('Port needs license and source evidence')
    for item in manifest['licenses']:
        evidence(files, item)
    expected = set()
    for item in manifest['overlay']:
        name = safe_path(item['path'])
        if name in expected or item['mode'] not in ('100644', '100755'):
            raise ValueError('Duplicate source path or unsupported file mode')
        expected.add(name)
        evidence(files, item, 'overlay/')
    actual = {p[len('overlay/'):] for p in files if p.startswith('overlay/')}
    if actual != expected:
        raise ValueError('Overlay inventory does not cover the indexed files')
    # There is no runtime/release-evidence verifier in this source export.
    if (manifest['runtimeEvidence'] != {'reentrant': False,
            'binaryRebuiltFromThisExport': False, 'hapMatchedToThisExport': False}
            or not manifest.get('remainingInputs')):
        raise ValueError('Source reconstruction cannot certify runtime or release readiness')
    return manifest


def git(repo, *args, data=None):
    env = os.environ.copy()
    # Prevent an inherited index or worktree from redirecting these operations.
    for key in ('GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE',
                'GIT_OBJECT_DIRECTORY', 'GIT_ALTERNATE_OBJECT_DIRECTORIES'):
        env.pop(key, None)
    env.update(GIT_NO_LAZY_FETCH='1', GIT_TERMINAL_PROMPT='0')
    result = subprocess.run(['git', '-c', 'protocol.allow=never',
        '-c', 'core.autocrlf=false', '-c', 'core.hooksPath=/dev/null',
        '-C', str(repo), *args], input=data, env=env,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        raise ValueError('Git source operation failed: ' + args[0])
    return result.stdout


def replay_qemu(upstream_repo, files, output=None):
    manifest = validate_qemu(files)
    base = manifest['upstream']
    if git(upstream_repo, 'rev-parse', base['commit'] + '^{tree}').decode().strip() != base['tree']:
        raise ValueError('Upstream commit/tree mismatch')
    if git(upstream_repo, 'show', base['commit'] + ':VERSION').decode().strip() != base['version']:
        raise ValueError('Upstream version mismatch')
    for item in manifest['licenses']:
        if git(upstream_repo, 'show', base['commit'] + ':' + item['path']) != files[item['path']]:
            raise ValueError('Upstream license mismatch')
    objects = git(upstream_repo, 'rev-parse', '--path-format=absolute',
                  '--git-path', 'objects').decode().strip()
    with tempfile.TemporaryDirectory(prefix='qemu-port-replay-') as directory:
        scratch = Path(directory) / 'source.git'
        git(Path(directory), 'init', '--bare', '--quiet', str(scratch))
        # Read upstream objects through alternates; all new objects and the
        # temporary index stay inside this disposable bare repository.
        (scratch / 'objects/info/alternates').write_bytes((Path(objects).as_posix() + '\n').encode())
        git(scratch, 'read-tree', base['commit'])
        patch = evidence(files, manifest['downstream']['patch'])
        git(scratch, 'apply', '--cached', '--check', '-', data=patch)
        git(scratch, 'apply', '--cached', '-', data=patch)
        if git(scratch, 'write-tree').decode().strip() != manifest['downstream']['tree']:
            raise ValueError('Downstream patch does not reconstruct the recorded tree')
        for item in manifest['overlay']:
            oid = git(scratch, 'hash-object', '-w', '--stdin',
                      data=files['overlay/' + item['path']]).decode().strip()
            git(scratch, 'update-index', '--add', '--cacheinfo',
                item['mode'], oid, item['path'])
        tree = git(scratch, 'write-tree').decode().strip()
        if tree != manifest['exportedTree']:
            raise ValueError('Reconstructed overlay tree mismatch')
        if output is not None:
            # No checkout or extraction: Git preserves symlinks and modes in
            # the archive, including when the verifier runs on Windows.
            archive = git(scratch, 'archive', '--format=tar', tree)
            with Path(output).open('xb') as handle:
                handle.write(archive)
        return tree


def validate_vnc(files, repo=None):
    manifest = json.loads(files['manifest.json'])
    if manifest.get('schemaVersion') != 1:
        raise ValueError('Unsupported LibVNC evidence schema')
    source = manifest['source']
    object_id(source['commit'])
    object_id(source['tree'])
    required = {'COPYING', 'sources.lock.json', 'tools/build_libvnc_ohos.sh'}
    if len(manifest['evidence']) != len(required) or {i['path'] for i in manifest['evidence']} != required:
        raise ValueError('LibVNC evidence must cover its lock, full license and recipe')
    for item in manifest['evidence']:
        evidence(files, item)
    lock = json.loads(files['sources.lock.json'])['component']
    if (lock['repository'] != source['url'] or not source['url'].startswith('https://') or
            '@' in source['url'] or lock['upstreamRevision'] != source['commit'] or
            lock['upstreamTree'] != source['tree'] or
            lock['licenseSha256'] != digest(files['COPYING'])):
        raise ValueError('LibVNC lock or license mismatch')
    matches = lock['build']['scriptSha256'] == digest(files['tools/build_libvnc_ohos.sh'])
    if manifest.get('recipeMatchesRetainedLock') is not matches:
        raise ValueError('LibVNC recipe drift must be reported accurately')
    if repo is not None:
        if git(repo, 'rev-parse', source['commit'] + '^{tree}').decode().strip() != source['tree']:
            raise ValueError('LibVNC upstream tree mismatch')
        if git(repo, 'show', source['commit'] + ':COPYING') != files['COPYING']:
            raise ValueError('LibVNC upstream license mismatch')


def indexed_files(root, prefix):
    entries = [e for e in index_entries(root) if e[0].startswith(prefix)]
    if any(mode not in ('100644', '100755') for _, mode, _ in entries):
        raise ValueError('Port evidence must be indexed regular files')
    blobs = read_index_blobs(root, entries)
    return {name[len(prefix):]: blobs[oid] for name, _, oid in entries}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--qemu-repo', type=Path)
    parser.add_argument('--libvnc-repo', type=Path)
    parser.add_argument('--output', type=Path, help='New QEMU source tar; requires --qemu-repo')
    args = parser.parse_args()
    try:
        if args.output and not args.qemu_repo:
            raise ValueError('--output requires --qemu-repo')
        qemu = indexed_files(args.root, QEMU)
        validate_qemu(qemu)
        validate_vnc(indexed_files(args.root, VNC), args.libvnc_repo)
        if args.qemu_repo:
            tree = replay_qemu(args.qemu_repo, qemu, args.output)
            print('PASS reconstructed QEMU source tree: ' + tree)
        print('PASS indexed port evidence; binaries and combined-application licensing remain unverified')
        return 0
    except (ValueError, KeyError, TypeError, OSError) as error:
        print('FAIL port evidence: ' + str(error))
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
