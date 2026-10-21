"""Retarget the full-core backend command without leaking its native SDK paths."""
from pathlib import Path


def retarget(arguments, old_native, native, output, depfile):
    old_native, native = str(old_native), str(native)
    if not old_native or old_native == native:
        raise ValueError('Expected distinct full-core and API18 SDK roots')
    args = [token.replace(old_native, native) for token in arguments]
    args[0] = str(Path(native)/'llvm/bin/clang')
    cleaned = []
    skip = False
    for arg in args:
        if skip:
            skip = False
            continue
        if arg in ('-o', '-MF', '-MT', '-MQ', '--sysroot'):
            skip = True
            continue
        if arg in ('-MD', '-MMD', '-MP') or arg.startswith('--sysroot='):
            continue
        cleaned.append(arg)
    return cleaned + ['--sysroot='+str(Path(native)/'sysroot'), '-o', str(output),
                      '-MD', '-MF', str(depfile),
                      '-Werror=implicit-function-declaration',
                      '-Werror=incompatible-function-pointer-types']


def check_dependencies(text, old_native, native):
    if str(old_native) in text:
        raise ValueError('API18 probe still depends on the full-core SDK')
    paths = text.replace('\\\n', ' ').split()
    headers = sorted(set(p for p in paths if '/ohaudio/' in p or '/accesstoken/' in p))
    expected = str(Path(native)/'sysroot/usr/include/ohaudio/native_audiostreambuilder.h')
    permission = str(Path(native)/'sysroot/usr/include/accesstoken/ability_access_control.h')
    if expected not in headers or permission not in headers or any(not p.startswith(str(Path(native)/'sysroot')+'/') for p in headers):
        raise ValueError('API18 probe did not use exclusively API18 OHAudio and access-token headers')
    return headers
