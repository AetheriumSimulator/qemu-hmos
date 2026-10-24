#!/usr/bin/env python3
"""Prepare EDK2's ARM64 CODE volume for QEMU virt's 64 MiB pflash bank."""
from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path
import tempfile


PFLASH_SIZE = 64 * 1024 * 1024


def prepare_arm64_code(source: Path, destination: Path) -> str:
    """Preserve the built volume and zero-pad its tail; never alter the input."""
    if source.resolve() == destination.resolve():
        raise ValueError('Firmware source and destination must differ')
    with source.open('rb') as stream:
        volume = stream.read(PFLASH_SIZE + 1)
    if not volume or len(volume) > PFLASH_SIZE:
        raise ValueError('ARM64 firmware must contain 1..67108864 bytes')
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(dir=destination.parent, delete=False) as stream:
            temporary = Path(stream.name)
            stream.write(volume)
            # POSIX extends with zeros, matching QEMU's upstream pflash image.
            stream.truncate(PFLASH_SIZE)
            stream.flush()
            os.fsync(stream.fileno())
        with temporary.open('rb') as stream:
            digest = hashlib.file_digest(stream, 'sha256').hexdigest()
        temporary.replace(destination)
        temporary = None
        # Runtime uses this content identity to choose a new managed path on
        # upgrade, leaving every legacy/custom sandbox firmware file intact.
        destination.with_name(destination.name + '.sha256').write_text(digest + '\n', encoding='ascii')
        return digest
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('destination', type=Path)
    args = parser.parse_args()
    digest = prepare_arm64_code(args.source, args.destination)
    print(f'{args.destination}: {PFLASH_SIZE} bytes, SHA-256 {digest}')


if __name__ == '__main__':
    main()
