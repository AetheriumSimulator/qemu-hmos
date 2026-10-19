#!/usr/bin/env python3
"""Collect a source candidate and verify hash-bound HAP distribution evidence.

Collection is not a license approval. No network access, signing or publication
occurs here. Strict review and disclosed-test policies are explicit.
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
import shlex
import tempfile
import subprocess
import tarfile
import zipfile

from check_public_source import ARTIFACT_SUFFIXES, content_problems
from prepare_hap_sources import NOTE_PATH
from delivery_policy import POLICY, collect_notices, disclosure, verify_disclosure, runtime_provenance

ASSETS = {'aetherium-unsigned.hap', 'aetherium-source.tar.gz', 'release-evidence.json'}
REQUIRED_REVIEWS = {'component-licenses', 'source-completeness', 'sdk-runtime-terms'}
REQUIRED_SOURCES = {
    'project/LICENSE', 'project/LICENSE-APACHE',
    'project/.github/actions/validate-so/action.yml',
    'project/.github/actions/validate-uefi/action.yml',
    'project/.github/actions/validate-hap/action.yml',
    'project/entry/src/main/cpp/CMakeLists.txt',
    'project/tools/build_curl_ohos.sh', 'project/tools/verify_curl_source.py',
    'project/tools/prepare_hap_sources.py',
    'project/tools/apply_ohaudio_patch.py',
    'project/tools/verify_ohaudio_api18.py',
    'project/third_party/qemu/build/ohaudio-hap-evidence.json',
    'project/third_party/qemu/build/ohaudio-api18-evidence.json',
    'project/patches/qemu/0002-ohos-ohaudio-audiodev.patch',
    'project/third_party/qemu/audio/aether_soundkit_hmos.c',
    'project/third_party/qemu/build/ohaudio-build-evidence.json',
    'project/tools/replay_source_inputs.py',
    'project/tools/delivery_policy.py',
    'project/docs/audits/2026-10-17-test-delivery-policy.md',
    'project/third_party/qemu/pc-bios/meson.build',
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


TEXT_BUILD_INPUTS = {
    'project/third_party/qemu/roms/edk2/BaseTools/Source/C/Makefiles/ms.app',
    'project/third_party/qemu/roms/edk2/ShellPkg/Application/ShellCTestApp/TestArgv.log',
}
REQUIRED_SOURCES.update(TEXT_BUILD_INPUTS)


def excluded_payload(name, data):
    """Shared collector/verifier policy, including compound firmware suffixes."""
    if data.startswith((b'\x7fELF', b'MZ', b'!<arch>\n', b'\xd0\x0d\xfe\xed')):
        return True
    if name in TEXT_BUILD_INPUTS:
        try:
            # EDK2's expected ShellCTestApp output is BOM-marked UTF-16.
            text = data.decode('utf-16' if data.startswith((b'\xff\xfe', b'\xfe\xff')) else 'utf-8')
            return any(ord(c) < 32 and c not in '\r\n\t' for c in text)
        except UnicodeDecodeError:
            return True
    suffixes = [s.lower() for s in Path(name).suffixes]
    while suffixes and suffixes[-1] in {'.bz2', '.gz', '.xz', '.zst', '.zip'}:
        suffixes.pop()
    return (bool(suffixes and suffixes[-1] in ARTIFACT_SUFFIXES | {'.rom', '.bin', '.dtb'})
            or '.so' in suffixes)


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
    if name == 'project/' + NOTE_PATH:
        from prepare_hap_sources import note_bytes
        if data != note_bytes():
            raise ValueError('EDK2 BTI note does not match its reconstruction recipe')
        omissions.append({'path': name, 'reason': 'reconstructed build data; tools/prepare_hap_sources.py'})
        return
    if excluded_payload(name, data):
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
        'third_party/qemu/audio/aether_soundkit_hmos.c',
        'third_party/qemu/build/ohaudio-build-evidence.json',
        'third_party/qemu/build/ohaudio-api18-evidence.json',
        'third_party/qemu/build/ohaudio-hap-evidence.json',
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
    collect_notices(root/'commandline-tools.zip', files)
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
                                        for word in ('license', 'licence', 'copying', 'copyright', 'notice'))]
    evidence = {'schemaVersion': 1, 'commit': git(root, 'rev-parse', 'HEAD'),
                'eventCommit': os.environ.get('GITHUB_SHA', ''),
                'run': os.environ.get('GITHUB_RUN_ID', ''),
                'unsigned': True, 'deviceTest': 'not-executed',
                'testDistribution': disclosure(), 'sdkRuntimeEvidence': runtime_provenance(),
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
    # Keep reviewable identities visible even when public artifact upload is held.
    print(json.dumps({key: evidence[key] for key in (
        'commit', 'assets', 'components', 'sdkInputs', 'toolVersions',
        'nativeDynamicDependencies', 'omissions', 'licenseFiles')}, indent=2))
    print('Packaged native/firmware identities: ' + json.dumps([
        item for item in payload if item['path'].endswith(('.so', '.fd'))]))
    link_name = 'project/third_party/qemu/build/meson-shared-link.rsp'
    if link_name in files:
        # Audit the actual selected link inputs while artifact publication is held.
        tokens = shlex.split(files[link_name][1].decode())
        print('Selected QEMU link inputs: ' + json.dumps({
            'sourceMember': link_name, 'sha256': digest(files[link_name][1]),
            'archivesAndLibraries': [t for t in tokens if t.endswith('.a') or t.startswith('-l')],
            'vfioObjects': [t for t in tokens if 'vfio' in t and t.endswith('.o')],
        }))
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
                           'omissions': evidence['omissions'],
                           'testDistribution': evidence.get('testDistribution'),
                           'sdkRuntimeEvidence': evidence.get('sdkRuntimeEvidence')}))


def verify(out, review, expected_commit=None, policy='strict-review'):
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
                if excluded_payload(member.name, data):
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
    members = {s['path']: s['sha256'] for s in sources}
    if not REQUIRED_SOURCES <= members.keys():
        errors.append('Required root/dependency/firmware source or license missing')
    if policy == POLICY:
        errors.extend(verify_disclosure(e, members))
    elif policy == 'strict-review':
        if review.get('scopeSha256') != e.get('scopeSha256'):
            errors.append('Distribution review missing or stale for this exact source/SDK scope')
        records = review.get('reviews', {})
        if set(records) != REQUIRED_REVIEWS:
            errors.append('Need component license, source completeness and SDK runtime reviews')
        for topic, record in records.items():
            path = record.get('path', '')
            if (not path.startswith('project/compliance/distribution-review/') or
                    not record.get('sha256') or members.get(path) != record['sha256']):
                errors.append('Missing/hash-mismatched review document: ' + topic)
    else:
        errors.append('Unsupported distribution policy')
    expected_licenses = [s for s in sources if any(word in Path(s['path']).name.lower()
                                                for word in ('license', 'licence', 'copying', 'copyright', 'notice'))]
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
    parser.add_argument('--policy', choices=['strict-review', POLICY], default='strict-review')
    parser.add_argument('--report-only', action='store_true', help='Report blocked eligibility without failing validation')
    args = parser.parse_args()
    if args.command == 'collect':
        collect(args.root.resolve(), args.hap, args.out)
        return 0
    review = json.loads(args.review.read_text()) if args.review.exists() else {}
    errors = verify(args.out, review, args.expected_commit, args.policy)
    if args.policy == POLICY:
        print('Test distribution policy: integrity verified separately; human review NOT approved')
        for topic, detail in disclosure()['unresolved'].items():
            print('UNRESOLVED: ' + topic + ': ' + detail)
    allowed = not errors
    for error in errors:
        print('BLOCKED: ' + error)
    print('Distribution evidence allowed=' + str(allowed).lower())
    if os.environ.get('GITHUB_OUTPUT'):
        with open(os.environ['GITHUB_OUTPUT'], 'a') as stream:
            stream.write('allowed=' + str(allowed).lower() + '\n')
    if os.environ.get('GITHUB_STEP_SUMMARY'):
        with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as stream:
            stream.write('Distribution policy: ' + args.policy + '\n')
            if args.policy == POLICY:
                stream.write('Human license/source/SDK reviews: NOT APPROVED; see release-evidence.json disclosures.\n')
            stream.write('Distribution eligibility: ' + str(allowed).lower() + '\n')
            stream.writelines('- ' + error + '\n' for error in errors)
    return 0 if allowed or args.report_only else 1


if __name__ == '__main__':
    raise SystemExit(main())
