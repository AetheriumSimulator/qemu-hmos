#!/usr/bin/env python3
"""Check the exact Git index, never ignored developer files or secret values.

This is a source-hygiene gate, not a license/completeness certification.
Vendored third_party source text needs a separate upstream/provenance audit.
"""
import argparse
import json
import pathlib
import re
import subprocess
import sys


CACHE_PARTS = {
    '.appanalyzer', '.cxx', '.hvigor', '.idea', '.pytest_cache', '__pycache__',
    'node_modules', 'oh_modules', 'config-temp', '.ohos-build', 'build-ohos',
    'build-native', 'build-test', 'CMakeFiles', '.aetherium-sync-backup',
}
ARTIFACT_SUFFIXES = {
    '.a', '.o', '.obj', '.pyc', '.hap', '.hsp', '.app', '.dll', '.dylib',
    '.exe', '.qcow2', '.iso', '.img', '.fd', '.log', '.bak',
}
LOCAL_SUFFIXES = {'.p12', '.pfx', '.p7b', '.jks', '.keystore'}
GENERATED_NAMES = {
    'CMakeCache.txt', 'cmake_install.cmake', 'compile_commands.json',
    'build.ninja', '.ninja_deps', '.ninja_log', 'config.log',
    'cmake.check_cache', 'CTestTestfile.cmake',
}


def path_problem(path):
    p = pathlib.PurePosixPath(path)
    if any(part in CACHE_PARTS for part in p.parts):
        return 'generated/cache directory'
    if path in {'git', '.claude/settings.local.json', 'local.properties'}:
        return 'local-only file'
    if p.name in {'.DS_Store', 'Thumbs.db'} or p.name == '.env' or p.name.startswith('.env.'):
        return 'local settings or environment file'
    if p.name in GENERATED_NAMES:
        return 'generated build file'
    if p.suffix.lower() in ARTIFACT_SUFFIXES or re.search(r'\.so(?:\.|$)', p.name):
        return 'compiled artifact or system image'
    if path.startswith('entry/src/main/resources/rawfile/') and p.suffix.lower() == '.bin':
        return 'firmware image without release provenance'
    if p.suffix.lower() in LOCAL_SUFFIXES:
        return 'signing material'
    if not path.startswith('third_party/') and p.suffix.lower() in {'.key', '.pem', '.cer', '.crt'}:
        return 'unreviewed credential/certificate file'
    return None


def content_problems(path, content):
    if content.startswith((b'\x7fELF', b'MZ', b'!<arch>\n')):
        return ['compiled binary magic']
    # Upstream cryptography fixtures are not classified as developer secrets.
    # Their source provenance and licenses remain a separate release blocker.
    if path.startswith('third_party/') or b'\0' in content:
        return []
    text = content.decode('utf-8', errors='replace')
    rules = {
        'private key marker': r'-----BEGIN (?:RSA |EC |DSA |OPENSSH |ENCRYPTED )?PRIVATE KEY-----',
        'GitHub token': r'\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,})\b',
        'credential-bearing URL': r'https?://[^\s/\"\x27:@]+:[^\s/\"\x27@]+@',
        'saved signing password': r'[\"\x27](?:keyPassword|storePassword)[\"\x27]\s*:\s*[\"\x27][^\"\x27]+[\"\x27]',
    }
    return [name for name, pattern in rules.items() if re.search(pattern, text)]


def index_entries(root):
    raw = subprocess.check_output(['git', 'ls-files', '--stage', '-z'], cwd=root)
    entries = []
    for record in raw.split(b'\0'):
        if not record:
            continue
        metadata, name = record.split(b'\t', 1)
        mode, oid, stage = metadata.decode('ascii').split()
        if stage != '0':
            raise ValueError('Unmerged index; resolve conflicts before publication')
        entries.append((name.decode('utf-8'), mode, oid))
    return entries


def read_index_blobs(root, entries):
    objects = [oid for _, mode, oid in entries if mode != '160000']
    result = subprocess.run(['git', 'cat-file', '--batch'], cwd=root,
                            input=('\n'.join(objects) + '\n').encode(),
                            stdout=subprocess.PIPE, check=True).stdout
    offset = 0
    blobs = {}
    for oid in objects:
        end = result.index(b'\n', offset)
        header = result[offset:end].split()
        if len(header) != 3 or header[1] != b'blob':
            raise ValueError('Index references a missing or non-blob object')
        size = int(header[2])
        offset = end + 1
        blobs[oid] = result[offset:offset + size]
        offset += size + 1
    return blobs


def check(root):
    entries = index_entries(root)
    blobs = read_index_blobs(root, entries)
    findings = []
    for path, mode, oid in entries:
        problem = path_problem(path)
        if problem:
            findings.append({'path': path, 'rule': problem})
        if mode == '160000':
            continue
        if mode == '120000':
            target = pathlib.PurePosixPath(blobs[oid].decode('utf-8'))
            if target.is_absolute() or '..' in target.parts:
                findings.append({'path': path, 'rule': 'unreviewed external symlink'})
        for problem in content_problems(path, blobs[oid]):
            findings.append({'path': path, 'rule': problem})
    required = {'LICENSE', 'LICENSE-APACHE', 'entry/src/main/cpp/types/libqemu_hmos/Index.d.ts',
                'entry/src/main/cpp/types/libqemu_hmos/oh-package.json5'}
    present = {path for path, _, _ in entries}
    for path in sorted(required - present):
        findings.append({'path': path, 'rule': 'required license or native module source missing'})
    return {'scope': 'Git index; vendored source text requires separate provenance review',
            'files': len(entries), 'findings': findings, 'passed': not findings}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=pathlib.Path, default=pathlib.Path(__file__).resolve().parents[1])
    parser.add_argument('--json', action='store_true')
    args = parser.parse_args()
    result = check(args.root)
    if args.json:
        print(json.dumps(result, ensure_ascii=False, indent=2))
    else:
        for finding in result['findings']:
            print(f"FAIL {finding['path']}: {finding['rule']}")
        print(f"{'PASS' if result['passed'] else 'FAIL'} indexed source hygiene ({result['files']} entries)")
        print('Not a GPL isolation or complete corresponding-source certification.')
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    sys.exit(main())
