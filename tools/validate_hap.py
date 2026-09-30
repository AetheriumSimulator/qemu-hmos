#!/usr/bin/env python3
"""Validate the unsigned HAP contains the runtime payload produced by CI."""
from __future__ import annotations

import argparse
import zipfile
from pathlib import Path


REQUIRED_ENTRIES = (
    "module.json",
    "ets/modules.abc",
    "libs/arm64-v8a/libqemu_hmos.so",
    "libs/arm64-v8a/libqemu_full.so",
)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("hap", type=Path)
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
        print(f"Validated {args.hap}: {len(entries)} entries")
        for name in REQUIRED_ENTRIES:
            print(f"  {name}: {archive.getinfo(name).file_size} bytes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
