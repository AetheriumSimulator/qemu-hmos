#!/usr/bin/env python3
"""Apply the required OHAudio patch, or verify an already-applied copy."""
import argparse
from pathlib import Path
import subprocess


def apply(source, patch):
    if not patch.is_file():
        raise RuntimeError(f'Required OHAudio patch missing: {patch}')
    def git(*args):
        return subprocess.run(['git', '-C', str(source), 'apply', *args, str(patch)],
                              capture_output=True, text=True)
    if git('--reverse', '--check').returncode == 0:
        print('OHAudio patch already applied and verified')
        return
    check = git('--check')
    if check.returncode:
        raise RuntimeError('OHAudio patch does not apply cleanly:\n' + check.stderr)
    result = git('--whitespace=nowarn')
    if result.returncode:
        raise RuntimeError(result.stderr)
    if git('--reverse', '--check').returncode:
        raise RuntimeError('OHAudio patch post-application verification failed')
    print('OHAudio patch applied and verified')


if __name__ == '__main__':
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=root/'third_party/qemu')
    parser.add_argument('--patch', type=Path, default=root/'patches/qemu/0002-ohos-ohaudio-audiodev.patch')
    args = parser.parse_args()
    apply(args.source.resolve(), args.patch.resolve())
