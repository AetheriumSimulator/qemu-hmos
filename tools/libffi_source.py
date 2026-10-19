#!/usr/bin/env python3
"""Obtain a locked libffi source tree without depending on GitLab smart HTTP."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import stat
import tarfile
import tempfile
import time
import urllib.error
import urllib.request

REVISION = '83d0cfd00d7d37af4b4349511d29f1f0512621b3'
TREE = 'c2e25557c3625c975bba5c7602877e17d3ca57c0'
ORIGIN = 'https://gitlab.freedesktop.org/gstreamer/meson-ports/libffi.git'
OFFICIAL = f'{ORIGIN[:-4]}/-/archive/{REVISION}/libffi-{REVISION}.tar.gz'
OFFICIAL_SHA = 'ab95eb62c77a0c7613458ed14972d9ba8448bb99de5e7901db7c98a49940c9fc'
BASELINE = 'https://github.com/AetheriumSimulator/qemu-hmos/releases/download/test-266a6c530b81bdf9f15dd473830137185a29630b/'
CACHE = BASELINE + 'aetherium-source.tar.gz'
CACHE_SHA = 'e6dbb7d12090a3db3577d5ed71030bbfc8d7855d0e29cf5eed5b846c420f5d2e'
EVIDENCE_SHA = 'd1e6850505b07b3d00a63fee1c89c19e627b88f477b94a81682dfafd931e56e9'
PREFIX = 'project/third_party/deps/glib/src/subprojects/libffi/'


def oid(kind, data):
    return hashlib.sha1(kind + b' ' + str(len(data)).encode() + b'\0' + data).digest()


def tree_id(root):
    entries = []
    for p in Path(root).iterdir():
        if p.name == '.git':
            continue
        name = os.fsencode(p.name)
        if p.is_symlink():
            mode, value, key = b'120000', oid(b'blob', os.fsencode(os.readlink(p))), name
        elif p.is_dir():
            mode, value, key = b'40000', bytes.fromhex(tree_id(p)), name+b'/'
        elif p.is_file():
            mode = b'100755' if p.stat().st_mode & 0o111 else b'100644'
            value, key = oid(b'blob', p.read_bytes()), name
        else:
            raise ValueError(f'Unsupported libffi source entry: {p}')
        entries.append((key, mode+b' '+name+b'\0'+value))
    return oid(b'tree', b''.join(v for _, v in sorted(entries))).hex()


def verify(root):
    actual = tree_id(root)
    if actual != TREE:
        raise ValueError(f'libffi tree mismatch: expected {TREE}, got {actual}')
    return actual


def download(url, target, expected):
    digest = hashlib.sha256()
    with urllib.request.urlopen(url, timeout=30) as response, target.open('wb') as output:
        total = 0
        while chunk := response.read(1024 * 1024):
            total += len(chunk)
            if total > 400 * 1024 * 1024:
                raise ValueError('Source download exceeds locked archive size bound')
            digest.update(chunk)
            output.write(chunk)
    if digest.hexdigest() != expected:
        raise ValueError(f'Source archive SHA-256 mismatch: {url}')


def obtain(target, fetch=download, pause=time.sleep):
    """Only transient service/network failures permit retry/cache fallback."""
    for attempt in range(2):
        try:
            fetch(OFFICIAL, target, OFFICIAL_SHA)
            return OFFICIAL, OFFICIAL_SHA, f'libffi-{REVISION}/'
        except urllib.error.HTTPError as error:
            # In particular, never use an alternative path after 401/403.
            if error.code not in (408, 429, 500, 502, 503, 504):
                raise
        except (urllib.error.URLError, TimeoutError, ConnectionError):
            pass
        if attempt == 0:
            pause(2)
    print('Official libffi service unavailable; using SHA-256-locked published source cache')
    fetch(CACHE, target, CACHE_SHA)
    return CACHE, CACHE_SHA, PREFIX


def extract(archive, prefix, destination):
    seen = set()
    with tarfile.open(archive, 'r:gz') as source:
        for member in source:
            if not member.name.startswith(prefix) or member.isdir():
                continue
            name = member.name[len(prefix):]
            path = PurePosixPath(name)
            if (not name or path.is_absolute() or '..' in path.parts or '.git' in path.parts or
                    name in seen or not member.isfile()):
                raise ValueError('Unsafe or duplicate libffi source archive member')
            seen.add(name)
            if len(seen) > 1000:
                raise ValueError('Unexpected libffi source member count')
            target = destination.joinpath(*path.parts)
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(source.extractfile(member).read())
            target.chmod(0o755 if member.mode & 0o111 else 0o644)
    verify(destination)


def prepare(root):
    destination = root/'third_party/deps/glib/src/subprojects/libffi'
    record = root/'third_party/deps/glib/libffi-source-evidence.json'
    if destination.exists():
        verify(destination)  # Never replace a drifted pre-existing source tree.
        if record.exists():
            previous = json.loads(record.read_text())
            if (previous.get('revision'), previous.get('gitTree'), previous.get('origin')) != (REVISION, TREE, ORIGIN):
                raise ValueError('Existing libffi provenance does not match locked source')
            print('Verified existing locked libffi source')
            return
        transport = {'archive': None, 'archiveSha256': None, 'method': 'verified-existing-tree'}
    else:
        destination.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=destination.parent) as tmp:
            tmp = Path(tmp)
            url, digest, prefix = obtain(tmp/'source.tar.gz')
            staged = tmp/'source'
            staged.mkdir()
            extract(tmp/'source.tar.gz', prefix, staged)
            staged.rename(destination)
        transport = {'archive': url, 'archiveSha256': digest, 'method': 'verified-archive'}
    evidence = dict(origin=ORIGIN, revision=REVISION, gitTree=TREE,
                    baselineEvidence=BASELINE+'release-evidence.json',
                    baselineEvidenceSha256=EVIDENCE_SHA, **transport)
    record.write_text(json.dumps(evidence, indent=2)+'\n')
    print('Verified locked libffi source: ' + TREE)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    prepare(args.root.resolve())
