#!/usr/bin/env python3
"""Prepare source-only inputs for the existing root HAP build (no downloads).

The packaged ArmVirt/OVMF images are built separately by validate-uefi; the
QEMU shared-core build must not unpack/install unrelated prebuilt pc-bios ROMs.
"""
import argparse
import hashlib
from pathlib import Path
import struct

PC_BIOS_SHA256 = '012dd54e2faf6867582404799ede88a56799afe65b9cc8ac1000daa33e220b4e'
NOTE_SHA256 = '4cd79611a5b20ea164d0bb517e3babbaa1915f1a5698a7b033b669d35cc4f5d0'
NOTE_PATH = 'third_party/qemu/roms/edk2/BaseTools/Bin/GnuNoteBti.bin'
GUARD = b'''roms = []
# Modified by Aetherium on 2026-10-17 for its separately built HAP firmware.
# Preserve the upstream
# install_blobs=true path, but do not require/build bundled ROMs when disabled.
if not get_option('install_blobs')
  # Preserve keyboard maps and the keymap_targets consumed by QEMU tests.
  subdir('keymaps')
  subdir_done()
endif
'''


def note_bytes():
    # AArch64 ELF GNU property note: namesz=4, descsz=16, NT_GNU_PROPERTY_TYPE_0=5,
    # name="GNU\\0", GNU_PROPERTY_AARCH64_FEATURE_1_AND=0xc0000000,
    # datasz=4, GNU_PROPERTY_AARCH64_FEATURE_1_BTI=1, alignment padding=0.
    # Matches the 32-byte input in EDK2 4dfdca63a93497203f197ec98ba20e2327e4afe4.
    data = struct.pack('<III4sIIII', 4, 16, 5, b'GNU\0', 0xc0000000, 4, 1, 0)
    assert hashlib.sha256(data).hexdigest() == NOTE_SHA256
    return data


def prepare(root):
    root = Path(root)
    meson = root / 'third_party/qemu/pc-bios/meson.build'
    current = meson.read_bytes()
    original = b'roms = []\n' + current[len(GUARD):] if current.startswith(GUARD) else current
    if hashlib.sha256(original).hexdigest() != PC_BIOS_SHA256:
        raise ValueError('Unexpected QEMU pc-bios recipe; re-review the pinned source')
    updated = GUARD + original[len(b'roms = []\n'):]
    note = root / NOTE_PATH
    data = note_bytes()
    if note.exists() and note.read_bytes() != data:
        raise ValueError('Unexpected EDK2 BTI note bytes; refusing to replace them')
    if current != updated:
        meson.write_bytes(updated)
    note.parent.mkdir(parents=True, exist_ok=True)
    note.write_bytes(data)
    print('Prepared HAP-only pc-bios recipe; reconstructed BTI note SHA-256:', NOTE_SHA256)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path.cwd())
    args = parser.parse_args()
    prepare(args.root)
