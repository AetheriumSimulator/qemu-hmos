#!/usr/bin/env python3
"""Validate the unsigned HAP contains the runtime payload produced by CI."""
from __future__ import annotations

import argparse
import hashlib
import json
import struct
import zipfile
from pathlib import Path

from prepare_firmware import PFLASH_SIZE


FIRMWARE_ENTRY = 'resources/rawfile/edk2-aarch64-code.fd'
FIRMWARE_DIGEST_ENTRY = FIRMWARE_ENTRY + '.sha256'

REQUIRED_ENTRIES = (
    "module.json",
    "ets/modules.abc",
    "libs/arm64-v8a/libqemu_hmos.so",
    "libs/arm64-v8a/libqemu_full.so",
    FIRMWARE_ENTRY,
    FIRMWARE_DIGEST_ENTRY,
)


def validate_arm64_firmware(archive: zipfile.ZipFile) -> None:
    if archive.getinfo(FIRMWARE_ENTRY).file_size != PFLASH_SIZE:
        raise ValueError('ARM64 pflash CODE must be exactly 67108864 bytes')
    if archive.getinfo(FIRMWARE_DIGEST_ENTRY).file_size != 65:
        raise ValueError('ARM64 firmware SHA-256 sidecar must contain 64 hex digits and a newline')
    with archive.open(FIRMWARE_ENTRY) as stream:
        digest = hashlib.file_digest(stream, 'sha256').hexdigest()
    if archive.read(FIRMWARE_DIGEST_ENTRY) != (digest + '\n').encode('ascii'):
        raise ValueError('ARM64 firmware SHA-256 sidecar does not match packaged CODE')


def load_image(data: bytes) -> bytes:
    """Canonical ELF64 PT_LOAD bytes; ignore only section-table header metadata.

    Hvigor strips non-loaded debug/symbol sections. Program headers, executable
    bytes, dynamic symbols/relocations and loaded data must remain unchanged.
    """
    if len(data) < 64 or data[:6] != b'\x7fELF\x02\x01':
        raise ValueError('Expected a little-endian ELF64 core')
    header = bytearray(data[:64])
    phoff = struct.unpack_from('<Q', data, 32)[0]
    phsize, count = struct.unpack_from('<HH', data, 54)
    if phsize != 56 or not count:
        raise ValueError('Invalid ELF program headers')
    header[40:48] = b'\0' * 8  # e_shoff
    header[58:64] = b'\0' * 6  # e_shentsize, e_shnum, e_shstrndx
    result = bytearray(header)
    loads = 0
    for i in range(count):
        entry = data[phoff+i*phsize:phoff+(i+1)*phsize]
        kind, flags, offset, vaddr, paddr, filesz, memsz, align = struct.unpack('<IIQQQQQQ', entry)
        result.extend(entry)  # Keep every program header, including offsets/flags.
        if kind != 1:
            continue
        if offset + filesz > len(data):
            raise ValueError('Truncated ELF load segment')
        segment = bytearray(data[offset:offset+filesz])
        if offset == 0 and filesz >= 64:
            segment[:64] = header
        result.extend(segment)
        loads += 1
    if not loads:
        raise ValueError('ELF has no load segments')
    return bytes(result)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("hap", type=Path)
    parser.add_argument("--core", type=Path, help="Require identical validated ELF load image in HAP")
    parser.add_argument("--identity-report", type=Path)
    args = parser.parse_args()

    if not args.hap.is_file() or args.hap.stat().st_size == 0:
        raise SystemExit(f"HAP is missing or empty: {args.hap}")

    with zipfile.ZipFile(args.hap) as archive:
        bad_entry = archive.testzip()
        if bad_entry is not None:
            raise SystemExit(f"corrupt HAP entry: {bad_entry}")
        entries = set(archive.namelist())
        missing = [name for name in REQUIRED_ENTRIES if name not in entries]
        if missing:
            raise SystemExit("HAP is missing required entries: " + ", ".join(missing))
        empty = [
            name for name in REQUIRED_ENTRIES
            if archive.getinfo(name).file_size == 0
        ]
        if empty:
            raise SystemExit("HAP contains empty required entries: " + ", ".join(empty))
        try:
            validate_arm64_firmware(archive)
        except ValueError as error:
            raise SystemExit(f"HAP firmware validation failed: {error}")
        if args.core:
            packaged = archive.read("libs/arm64-v8a/libqemu_full.so")
            original = args.core.read_bytes()
            try:
                image = original if packaged == original else load_image(original)
                if packaged != original and load_image(packaged) != image:
                    raise ValueError('loaded code/data or program headers changed')
            except (ValueError, struct.error) as error:
                raise SystemExit(f"HAP core differs from the validated native build: {error}")
            report = {'originalSha256': hashlib.sha256(original).hexdigest(),
                      'packagedSha256': hashlib.sha256(packaged).hexdigest(),
                      'comparison': 'byte-identical' if packaged == original else 'elf64-pt-load-excluding-section-table-header-fields',
                      'loadImageSha256': hashlib.sha256(image).hexdigest(),
                      'result': 'match', 'deviceTest': 'not-executed'}
            if args.identity_report:
                args.identity_report.write_text(json.dumps(report, indent=2)+'\n')
            print('HAP/native core identity: ' + json.dumps(report))
        print(f"Validated {args.hap}: {len(entries)} entries")
        for name in REQUIRED_ENTRIES:
            print(f"  {name}: {archive.getinfo(name).file_size} bytes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
