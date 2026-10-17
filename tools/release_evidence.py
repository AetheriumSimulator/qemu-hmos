#!/usr/bin/env python3
"""Collect a source candidate and verify hash-bound HAP distribution evidence.

Collection is not a license approval. No network access, extraction, signing or
publication occurs here. A missing/stale distribution review blocks publication.
"""
import argparse
import hashlib
import gzip
import io
import json
import os
from pathlib import Path, PurePosixPath
import posixpath
import shutil
import re
import tempfile
import subprocess
import tarfile
import zipfile

from check_public_source import ARTIFACT_SUFFIXES, content_problems

ASSETS = {'aetherium-unsigned.hap', 'aetherium-source.tar.gz', 'release-evidence.json'}
REQUIRED_REVIEWS = {'component-licenses', 'source-completeness', 'sdk-runtime-terms'}
REQUIRED_SOURCES = {
    'project/LICENSE', 'project/LICENSE-APACHE',
    'project/.github/actions/validate-so/action.yml',
    'project/.github/actions/validate-uefi/action.yml',
    'project/.github/actions/validate-hap/action.yml',
    'project/entry/src/main/cpp/CMakeLists.txt',
    'project/third_party/qemu/configure', 'project/third_party/qemu/COPYING',
    'project/third_party/qemu/roms/edk2/ArmVirtPkg/ArmVirtQemu.dsc',
    'project/third_party/qemu/roms/edk2/OvmfPkg/OvmfPkgX64.dsc',
    'project/third_party/deps/glib/src/COPYING',
    'project/third_party/deps/pcre2/src/LICENCE.md',
    'project/third_party/deps/pixman/src/COPYING',
    'project/third_party/deps/openssl/src/LICENSE.txt',
    'project/third_party/deps/.ohos-build/curl-01346829096c61b372692f6dc43ffa778c6caccd/COPYING',
}
REQUIRED_PAYLOAD = {
    'libs/arm64-v8a/libqemu_full.so', 'libs/arm64-v8a/libqemu_hmos.so',
    'resources/rawfile/edk2-aarch64-code.fd', 'resources/rawfile/OVMF_CODE.fd',
}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def encoded(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':')).encode()


def file_hash(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def git(root, *args):
    return subprocess.check_output(['git', '-C', str(root), *args]).decode().strip()


def safe_name(name):
    p = PurePosixPath(name)
    return bool(name) and not p.is_absolute() and '..' not in p.parts and '\\' not in name


def snapshot(root, prefix, files, components, omissions, recurse=True):
    """Archive tracked working-tree source, including local build recipe edits."""
    if Path(git(root, 'rev-parse', '--show-toplevel')).resolve() != root.resolve():
        raise ValueError(f'Not an initialized source repository: {prefix}')
    components.append({'path': prefix, 'revision': git(root, 'rev-parse', 'HEAD'),
                       'origin': git(root, 'remote', 'get-url', 'origin') if prefix != 'project' else
                       'https://github.com/AetheriumSimulator/qemu-hmos.git'})
    raw = subprocess.check_output(['git', '-C', str(root), 'ls-files', '--stage', '-z'])
    for record in raw.split(b'\0'):
        if not record:
            continue
        meta, path = record.split(b'\t', 1)
        mode, _, stage = meta.decode().split()
        path = path.decode()
        if stage != '0' or not safe_name(path):
            raise ValueError('Unsafe or unmerged source entry')
        target = root / path
        name = f'{prefix}/{path}'
        if prefix == 'project' and path.startswith('ports/'):
            # Supplementary phone/Aether exports are not inputs to this HAP.
            continue
        if mode == '160000':
            # QEMU's other ROM platforms are not built or packaged by this workflow.
            if prefix == 'project/third_party/qemu' and path != 'roms/edk2':
                omissions.append({'path': name, 'reason': 'unused QEMU submodule; review scope'})
            elif recurse:
                snapshot(target, name, files, components, omissions)
            continue
        if not target.exists() and not target.is_symlink():
            omissions.append({'path': name, 'reason': 'missing tracked source'})
            continue
        add_file(target, name, files, omissions)


def add_file(path, name, files, omissions):
    if not safe_name(name):
        raise ValueError('Unsafe source name')
    if path.is_symlink():
        target = os.readlink(path)
        resolved = posixpath.normpath(posixpath.join(posixpath.dirname(name), target))
        if target.startswith('/') or not resolved.startswith('project/'):
            omissions.append({'path': name, 'reason': 'external source symlink excluded', 'target': target})
            return
        files[name] = ('symlink', target.encode(), 0o777)
        return
    data = path.read_bytes()
    if (path.suffix.lower() in ARTIFACT_SUFFIXES | {'.rom', '.bin'} or
            '.so' in path.suffixes or data.startswith((b'\x7fELF', b'MZ', b'!<arch>\n'))):
        omissions.append({'path': name, 'reason': 'compiled payload/fixture excluded from source delivery'})
        return
    problems = content_problems('third_party/' + name if '/third_party/' in name else name, data)
    if problems:
        raise ValueError(f'Source content check failed: {name}: {problems}')
    files[name] = ('file', data, 0o755 if path.stat().st_mode & 0o111 else 0o644)


def collect(root, hap, out):
    out.mkdir(parents=True, exist_ok=False)
    files, components, omissions = {}, [], [{'path': 'project/ports', 'reason': 'supplementary phone exports outside this HAP build'}]
    snapshot(root, 'project', files, components, omissions)
    # Meson wraps and curl are fetched during the native build, outside gitlinks.
    dynamic = [root/'third_party/deps/.ohos-build/curl-01346829096c61b372692f6dc43ffa778c6caccd']
    for base in (root/'third_party/deps/glib/src/subprojects', root/'third_party/qemu/subprojects'):
        dynamic.extend(p for p in base.iterdir() if p.is_dir() and (p/'.git').exists())
    for path in sorted(set(dynamic)):
        snapshot(path, 'project/' + path.relative_to(root).as_posix(), files, components, omissions)
    # Preserve build-created GLib scaffolding, firmware configuration and exact
    # configuration/link graphs as reconstruction evidence (never SDK binaries).
    extra_patterns = [
        'third_party/deps/glib/src/tests/template*.in',
        'third_party/deps/glib/src/tests/lib/__init__.py',
        'third_party/deps/glib/src/.gitlab-ci/thorough-test-wrapper.sh',
        'third_party/qemu/roms/edk2/Conf/*.txt',
        'third_party/qemu/build/config-host.mak',
        'third_party/qemu/build/meson-info/*.json',
        'third_party/deps/.ohos-build/toolchain/*',
        'entry/src/main/cpp/build/CMakeCache.txt',
        'entry/src/main/cpp/build/CMakeFiles/qemu_hmos.dir/link.txt',
        'third_party/qemu/build/meson-shared-link.rsp',
    ]
    for pattern in extra_patterns:
        for path in root.glob(pattern):
            if path.is_file():
                add_file(path, 'project/' + path.relative_to(root).as_posix(), files, omissions)
    # Vendored components are source snapshots, not claimed upstream revisions.
    for component in ('glib', 'pcre2', 'pixman', 'openssl'):
        prefix = f'project/third_party/deps/{component}/src'
        components.append({'path': prefix, 'revision': None,
                           'sourceTreeSha256': digest(encoded([
                               (name, digest(value[1])) for name, value in sorted(files.items())
                               if name.startswith(prefix + '/')]))})
    sources = []
    with (out/'aetherium-source.tar.gz').open('wb') as raw, gzip.GzipFile(fileobj=raw, mode='wb', mtime=0, filename='') as compressed, tarfile.open(fileobj=compressed, mode='w') as archive:
        for name, (kind, data, mode) in sorted(files.items()):
            info = tarfile.TarInfo(name)
            info.mode = mode
            if kind == 'symlink':
                info.type, info.linkname = tarfile.SYMTYPE, data.decode()
                archive.addfile(info)
            else:
                info.size = len(data)
                archive.addfile(info, io.BytesIO(data))
            sources.append({'path': name, 'kind': kind, 'sha256': digest(data)})
    shutil.copyfile(hap, out/'aetherium-unsigned.hap')
    native_dependencies = {}
    with zipfile.ZipFile(hap) as archive:
        payload = [{'path': i.filename, 'sha256': digest(archive.read(i)), 'bytes': i.file_size}
                   for i in archive.infolist() if not i.is_dir()]
        for info in archive.infolist():
            if info.filename.endswith('.so'):
                with tempfile.NamedTemporaryFile() as native:
                    native.write(archive.read(info))
                    native.flush()
                    dynamic = subprocess.check_output(['readelf', '-d', native.name], text=True)
                    native_dependencies[info.filename] = re.findall(r'NEEDED.*\[(.*?)\]', dynamic)
    sdk_inputs = []
    for name in ('harmonyos-sdk.tar.gz', 'commandline-tools.zip'):
        path = root/name
        source_url = ((root/'.ci-native-sdk-url').read_text().strip() if name == 'harmonyos-sdk.tar.gz'
                      else 'https://repo.huaweicloud.com/harmonyos/ohpm/5.1.0/commandline-tools-linux-x64-5.1.0.840.zip')
        sdk_inputs.append({'path': name, 'url': source_url, 'sha256': file_hash(path)})
    tool_versions = {}
    for name, executable in {
        'native-clang': Path(os.environ.get('NDK_DIR', '/missing'))/'llvm/bin/clang',
        'meson': root/'.ci-venv-so/bin/meson',
        'ninja': root/'.ci-venv-so/bin/ninja',
        'node': Path(shutil.which('node') or '/missing'),
        'cmake': Path(shutil.which('cmake') or '/missing'),
    }.items():
        tool_versions[name] = (subprocess.check_output([str(executable), '--version'], text=True).strip()
                               if executable.exists() else 'not-found')
    licenses = [s for s in sources if any(word in Path(s['path']).name.lower()
                                        for word in ('license', 'licence', 'copying', 'copyright'))]
    evidence = {'schemaVersion': 1, 'commit': git(root, 'rev-parse', 'HEAD'),
                'eventCommit': os.environ.get('GITHUB_SHA', ''),
                'run': os.environ.get('GITHUB_RUN_ID', ''),
                'unsigned': True, 'deviceTest': 'not-executed',
                'components': components, 'sourceMembers': sources, 'licenseFiles': licenses,
                'omissions': omissions, 'sdkInputs': sdk_inputs, 'payload': payload,
                'nativeDynamicDependencies': native_dependencies, 'toolVersions': tool_versions,
                'assets': {name: file_hash(out/name) for name in ASSETS - {'release-evidence.json'}}}
    # Review binds the actual source set (excluding the review itself), recipes,
    # resolved revisions, SDK bytes and omissions. No self-declared ready flag.
    evidence['scopeSha256'] = scope_hash(evidence)
    (out/'release-evidence.json').write_text(json.dumps(evidence, indent=2) + '\n')
    print(f"Source candidate: {len(sources)} entries; {len(components)} source records; "
          f"{len(omissions)} exclusions. Review scope SHA-256: {evidence['scopeSha256']}")
    return evidence


def scope_hash(evidence):
    sources = [s for s in evidence['sourceMembers']
               if not s['path'].startswith('project/compliance/distribution-review')]
    # The checkout commit is recorded separately; including it here would make a
    # review commit invalidate itself. Source paths/hashes still bind all code.
    components = [dict(c, revision='source-members-bind-root') if c['path'] == 'project' else c
                  for c in evidence['components']]
    return digest(encoded({'sources': sources, 'components': components,
                           'sdkInputs': evidence['sdkInputs'], 'toolVersions': evidence.get('toolVersions', {}),
                           'omissions': evidence['omissions']}))


def verify(out, review, expected_commit=None):
    errors = []
    if {p.name for p in out.iterdir()} != ASSETS:
        return ['Delivery must contain exactly HAP, source archive and evidence JSON']
    e = json.loads((out/'release-evidence.json').read_text())
    if e.get('schemaVersion') != 1 or e.get('unsigned') is not True:
        errors.append('Unsupported evidence schema or signing claim')
    if expected_commit and e.get('commit') != expected_commit:
        errors.append('Build checkout does not match expected commit')
    if set(e.get('assets', {})) != ASSETS - {'release-evidence.json'}:
        errors.append('Asset manifest mismatch')
    for name, expected in e.get('assets', {}).items():
        if name not in ASSETS or file_hash(out/name) != expected:
            errors.append('Asset hash mismatch: ' + name)
    sources = []
    with tarfile.open(out/'aetherium-source.tar.gz', 'r:gz') as archive:
        for member in archive:
            if not safe_name(member.name) or not member.name.startswith('project/'):
                errors.append('Unsafe archive member')
                continue
            if member.issym():
                target = posixpath.normpath(posixpath.join(posixpath.dirname(member.name), member.linkname))
                if member.linkname.startswith('/') or not target.startswith('project/'):
                    errors.append('Unsafe archive link')
                data, kind = member.linkname.encode(), 'symlink'
            elif member.isfile():
                data, kind = archive.extractfile(member).read(), 'file'
                if data.startswith((b'\x7fELF', b'MZ', b'!<arch>\n')) or Path(member.name).suffix in ARTIFACT_SUFFIXES | {'.bin', '.rom'}:
                    errors.append('Compiled binary in source archive')
            else:
                errors.append('Unsupported archive member')
                continue
            sources.append({'path': member.name, 'kind': kind, 'sha256': digest(data)})
    if sources != e.get('sourceMembers') or len({s['path'] for s in sources}) != len(sources):
        errors.append('Source member manifest mismatch or duplicate')
    with zipfile.ZipFile(out/'aetherium-unsigned.hap') as archive:
        payload = [{'path': i.filename, 'sha256': digest(archive.read(i)), 'bytes': i.file_size}
                   for i in archive.infolist() if not i.is_dir()]
    if payload != e.get('payload') or len({p['path'] for p in payload}) != len(payload):
        errors.append('HAP payload manifest mismatch or duplicate')
    if not REQUIRED_PAYLOAD <= {p['path'] for p in payload if p['bytes'] > 0}:
        errors.append('Required native/firmware HAP payload missing')
    if e.get('scopeSha256') != scope_hash(e):
        errors.append('Review scope hash mismatch')
    if review.get('scopeSha256') != e.get('scopeSha256'):
        errors.append('Distribution review missing or stale for this exact source/SDK scope')
    records = review.get('reviews', {})
    if set(records) != REQUIRED_REVIEWS:
        errors.append('Need component license, source completeness and SDK runtime reviews')
    members = {s['path']: s['sha256'] for s in sources}
    if not REQUIRED_SOURCES <= members.keys():
        errors.append('Required root/dependency/firmware source or license missing')
    for topic, record in records.items():
        path = record.get('path', '')
        if (not path.startswith('project/compliance/distribution-review/') or
                not record.get('sha256') or members.get(path) != record['sha256']):
            errors.append('Missing/hash-mismatched review document: ' + topic)
    expected_licenses = [s for s in sources if any(word in Path(s['path']).name.lower()
                                                for word in ('license', 'licence', 'copying', 'copyright'))]
    if e.get('licenseFiles') != expected_licenses:
        errors.append('License file inventory mismatch')
    if not e.get('licenseFiles') or not e.get('components') or len(e.get('sdkInputs', [])) != 2:
        errors.append('Missing source/license/SDK evidence')
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['collect', 'verify'])
    parser.add_argument('--root', type=Path, default=Path.cwd())
    parser.add_argument('--hap', type=Path)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--review', type=Path, default=Path('compliance/distribution-review.json'))
    parser.add_argument('--expected-commit')
    parser.add_argument('--report-only', action='store_true', help='Report blocked eligibility without failing validation')
    args = parser.parse_args()
    if args.command == 'collect':
        collect(args.root.resolve(), args.hap, args.out)
        return 0
    review = json.loads(args.review.read_text()) if args.review.exists() else {}
    errors = verify(args.out, review, args.expected_commit)
    allowed = not errors
    for error in errors:
        print('BLOCKED: ' + error)
    print('Distribution evidence allowed=' + str(allowed).lower())
    if os.environ.get('GITHUB_OUTPUT'):
        with open(os.environ['GITHUB_OUTPUT'], 'a') as stream:
            stream.write('allowed=' + str(allowed).lower() + '\n')
    if os.environ.get('GITHUB_STEP_SUMMARY'):
        with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as stream:
            stream.write('Distribution eligibility: ' + str(allowed).lower() + '\n')
            stream.writelines('- ' + error + '\n' for error in errors)
    return 0 if allowed or args.report_only else 1


if __name__ == '__main__':
    raise SystemExit(main())
