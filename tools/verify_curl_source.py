#!/usr/bin/env python3
"""Verify curl's fixed Git tree without Git metadata or network access."""
import hashlib
import os
from pathlib import Path
import stat
import sys

CURL_REVISION = '01346829096c61b372692f6dc43ffa778c6caccd'
# `git rev-parse <CURL_REVISION>^{tree}` from https://github.com/curl/curl.git.
CURL_TREE = '6ae23d9333713707a02588b44ed238a50e8b3bde'
# These four files are checked out as CRLF by the pinned .gitattributes files;
# Git blob identities use LF. No other content normalization is permitted.
CRLF_PATHS = {
    'projects/Windows/generate.bat',
    'projects/Windows/tmpl/curl-all.sln',
    'projects/Windows/tmpl/curl.sln',
    'projects/Windows/tmpl/libcurl.sln',
}


def object_id(kind, data):
    return hashlib.sha1(kind + b' ' + str(len(data)).encode() + b'\0' + data).digest()


def tree_id(root, top=True, prefix=''):
    entries = []
    for path in root.iterdir():
        if top and path.name == '.git':
            continue
        mode = path.lstat().st_mode
        name = os.fsencode(path.name)
        if stat.S_ISLNK(mode):
            kind, oid, key = b'120000', object_id(b'blob', os.fsencode(os.readlink(path))), name
        elif stat.S_ISDIR(mode):
            kind, oid, key = b'40000', tree_id(path, False, prefix + path.name + '/'), name + b'/'
        elif stat.S_ISREG(mode):
            kind = b'100755' if mode & 0o111 else b'100644'
            data = path.read_bytes()
            if prefix + path.name in CRLF_PATHS:
                data = data.replace(b'\r\n', b'\n')
            oid, key = object_id(b'blob', data), name
        else:
            raise ValueError(f'Unsupported source entry: {path}')
        entries.append((key, kind + b' ' + name + b'\0' + oid))
    return object_id(b'tree', b''.join(entry for _, entry in sorted(entries)))


def verify(root, expected=CURL_TREE):
    actual = tree_id(Path(root)).hex()
    if actual != expected:
        raise ValueError(f'curl source tree mismatch: expected {expected}, got {actual}')
    return actual


if __name__ == '__main__':
    try:
        print(f'Verified curl {CURL_REVISION} source tree: {verify(sys.argv[1])}')
    except (ValueError, OSError, IndexError) as error:
        raise SystemExit(str(error))
