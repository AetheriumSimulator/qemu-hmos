#!/usr/bin/env python3
"""Replay repaired build inputs from the actual source archive, without Git/SDK.

This exercises real pc-bios Meson logic and BTI reconstruction, not a complete
archive-to-HAP build or device test. No download or publication occurs.
"""
import argparse
import hashlib
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile

from prepare_hap_sources import NOTE_PATH, NOTE_SHA256
from release_evidence import TEXT_BUILD_INPUTS, excluded_payload, safe_name


def replay(archive_path, meson):
    with tempfile.TemporaryDirectory(prefix='hap-source-replay-') as temporary:
        root = Path(temporary) / 'project'
        selected = TEXT_BUILD_INPUTS | {'project/tools/prepare_hap_sources.py', 'project/tools/libffi_source.py'}
        with tarfile.open(archive_path, 'r:gz') as archive:
            for member in archive:
                if (member.name not in selected and not member.name.startswith('project/third_party/qemu/pc-bios/')
                        and not member.name.startswith('project/third_party/deps/glib/src/subprojects/libffi/')):
                    continue
                if not safe_name(member.name) or not member.isfile():
                    raise ValueError('Unsafe replay source member: ' + member.name)
                data = archive.extractfile(member).read()
                if excluded_payload(member.name, data):
                    raise ValueError('Prebuilt payload remained in replay source: ' + member.name)
                target = Path(temporary) / member.name
                target.parent.mkdir(parents=True, exist_ok=True)
                if target.exists():
                    raise ValueError('Duplicate replay member')
                target.write_bytes(data)
                target.chmod(0o755 if member.mode & 0o111 else 0o644)
        for name in selected:
            if not (Path(temporary) / name).is_file():
                raise ValueError('Missing replay source: ' + name)
        subprocess.run([sys.executable, '-c',
                        "import sys; from pathlib import Path; sys.path.insert(0, sys.argv[1]); "
                        "import libffi_source; print('PASS extracted libffi tree:', libffi_source.verify(Path(sys.argv[2])))",
                        str(root/'tools'), str(root/'third_party/deps/glib/src/subprojects/libffi')], check=True)
        subprocess.run([sys.executable, str(root/'tools/prepare_hap_sources.py'), '--root', str(root)], check=True)
        assert hashlib.sha256((root/NOTE_PATH).read_bytes()).hexdigest() == NOTE_SHA256
        probe = Path(temporary) / 'meson-probe'
        probe.mkdir()
        shutil.copytree(root/'third_party/qemu/pc-bios', probe/'pc-bios')
        (probe/'meson_options.txt').write_text("option('install_blobs', type: 'boolean', value: true)\n")
        (probe/'meson.build').write_text("""project('archive-pc-bios-replay')
unpack_edk2_blobs = true
have_system = true
qemu_datadir = 'share/qemu'
bzip2 = find_program('bzip2')
xkbcommon = declare_dependency()
qemu_keymap = find_program('/nonexistent-aetherium-source-replay-keymap', required: false)
subdir('pc-bios')
# The parent functional/qtest recipes consume both variables.
test_deps = [roms, keymap_targets]
""")
        for enabled in (False, True):
            result = subprocess.run([meson, 'setup', str(probe/str(enabled)), str(probe),
                                     '--backend=none',
                                     '-Dinstall_blobs=' + str(enabled).lower()],
                                    text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            if not enabled and result.returncode:
                raise ValueError('Archive HAP pc-bios configuration failed:\n' + result.stdout)
            if enabled and (result.returncode == 0 or 'edk2-aarch64-code.fd.bz2' not in result.stdout):
                raise ValueError('Upstream install_blobs=true behavior was not preserved:\n' + result.stdout)
        print('PASS extracted-archive inputs: text Makefile/test expectation retained; '
              'BTI note reconstructed byte-for-byte; actual pc-bios Meson config works '
              'without prebuilt ROMs for install_blobs=false; true still requires its ROM inputs.')
        print('Scope: targeted source-input replay, not a full HAP rebuild or device validation.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archive', type=Path)
    parser.add_argument('--meson', default='meson')
    args = parser.parse_args()
    replay(args.archive, args.meson)
