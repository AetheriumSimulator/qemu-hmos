#!/usr/bin/env python3
"""Validate recorded source identities; binary publication stays explicitly blocked."""
import argparse
import configparser
import hashlib
import json
import pathlib
import re
import subprocess
import sys

from check_public_source import index_entries, read_index_blobs

MANIFEST = 'compliance/source-inventory.json'


def validate(manifest, entries, blobs, source_tree, source_origins=None):
    errors = []
    by_path = {path: (mode, oid) for path, mode, oid in entries}
    if manifest.get('schemaVersion') != 1:
        errors.append('Unsupported source inventory schema')
    components = manifest.get('components', [])
    if not components:
        errors.append('Source inventory must contain components')
    ids = set()
    for component in components:
        name = component.get('id', '')
        if not name or name in ids:
            errors.append('Missing or duplicate component id')
        ids.add(name)
        origin = component.get('origin', '')
        if not origin.startswith('https://') or '@' in origin:
            errors.append(f'{name}: expected a public HTTPS source origin')
        if component.get('status') not in ('pinned-upstream-with-patches', 'provenance-incomplete'):
            errors.append(f'{name}: unsupported evidence status')
        source = component.get('source', {})
        path = source.get('path', '')
        if not path or pathlib.PurePosixPath(path).is_absolute() or '..' in pathlib.PurePosixPath(path).parts:
            errors.append(f'{name}: unsafe source path')
            continue
        if source.get('kind') == 'gitlink':
            if by_path.get(path) != ('160000', source.get('revision')):
                errors.append(f'{name}: pinned submodule does not match the index')
            if source_origins is not None and source_origins.get(path) != origin:
                errors.append(f'{name}: submodule origin does not match the inventory')
        elif source.get('kind') == 'vendored-tree':
            if source_tree(path) != source.get('gitTree'):
                errors.append(f'{name}: vendored source tree changed; refresh reviewed evidence')
        else:
            errors.append(f'{name}: unsupported source kind')
        licenses = component.get('licenseEvidence', [])
        if not licenses:
            errors.append(f'{name}: missing license evidence')
        for item in licenses + component.get('patches', []) + component.get('recipes', []):
            item_path = item.get('path', '')
            entry = by_path.get(item_path)
            if not entry or entry[0] not in ('100644', '100755'):
                errors.append(f'{name}: evidence is not an indexed regular file: {item_path}')
                continue
            expected = item.get('sha256', '')
            if not re.fullmatch(r'[a-f0-9]{64}', expected) or hashlib.sha256(blobs[entry[1]]).hexdigest() != expected:
                errors.append(f'{name}: evidence hash mismatch: {item_path}')
    # No positive release certification is implemented yet. A flag edit must
    # not turn an incomplete inventory into approval to distribute binaries.
    release = manifest.get('binaryPublication', {})
    if release.get('status') != 'blocked' or not release.get('blockers'):
        errors.append('Binary publication requires a separately implemented release-evidence verifier')
    return errors


def check(root, require_binary_release=False):
    entries = index_entries(root)
    blobs = read_index_blobs(root, entries)
    by_path = {path: (mode, oid) for path, mode, oid in entries}
    entry = by_path.get(MANIFEST)
    if not entry:
        return ['Missing indexed source inventory']
    manifest = json.loads(blobs[entry[1]])
    origins = {}
    modules = by_path.get('.gitmodules')
    if modules:
        config = configparser.RawConfigParser()
        config.read_string(blobs[modules[1]].decode('utf-8'))
        for section in config.sections():
            origins[config.get(section, 'path')] = config.get(section, 'url')
    tree = subprocess.check_output(['git', 'write-tree'], cwd=root).decode().strip()

    def source_tree(path):
        result = subprocess.run(['git', 'rev-parse', '--verify', f'{tree}:{path}'], cwd=root,
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        return result.stdout.decode().strip() if result.returncode == 0 else None

    errors = validate(manifest, entries, blobs, source_tree, origins)
    if require_binary_release:
        errors.append('Binary publication is blocked; no complete corresponding-source/release verifier is available')
        for blocker in manifest.get('binaryPublication', {}).get('blockers', []):
            errors.append(str(blocker))
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=pathlib.Path, default=pathlib.Path(__file__).resolve().parents[1])
    parser.add_argument('--require-binary-release', action='store_true')
    args = parser.parse_args()
    try:
        errors = check(args.root, args.require_binary_release)
    except (ValueError, KeyError, TypeError, AttributeError, configparser.Error,
            subprocess.CalledProcessError) as error:
        print(f'FAIL source inventory could not be verified: {type(error).__name__}')
        return 1
    for error in errors:
        print(f'FAIL {error}')
    if not errors:
        print('PASS indexed source identities; binary publication remains blocked')
    return 1 if errors else 0


if __name__ == '__main__':
    sys.exit(main())
