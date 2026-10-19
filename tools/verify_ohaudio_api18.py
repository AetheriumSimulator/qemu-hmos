#!/usr/bin/env python3
"""Recompile the actual backend with the HAP's API18 compiler/sysroot."""
import json
import os
from pathlib import Path
import shlex
import subprocess

root = Path(__file__).resolve().parents[1]
build = root/'third_party/qemu/build'
native = Path(os.environ['HARMONY_NATIVE_DIR'])
metadata = json.loads((native/'oh-uni-package.json').read_text())
if str(metadata.get('apiVersion')) != '18':
    raise SystemExit('Expected native SDK apiVersion 18: ' + str(metadata))
commands = json.loads((build/'compile_commands.json').read_text())
entries = [x for x in commands if x['file'].endswith('/aether_soundkit_hmos.c')]
if len(entries) != 1:
    raise SystemExit('Expected exactly one compiled OHAudio backend')
entry = entries[0]
args = entry.get('arguments') or shlex.split(entry['command'])
compiler = native/'llvm/bin/clang'
if not compiler.is_file():
    raise SystemExit('API18 compiler missing')
args[0] = str(compiler)
output = build/'ohaudio-api18.o'
for i, arg in enumerate(args):
    if arg.startswith('--sysroot='):
        args[i] = '--sysroot=' + str(native/'sysroot')
    elif arg == '-o':
        args[i+1] = str(output)
# Fail on incompatible callback signatures or undeclared API calls.
args += ['-Werror=implicit-function-declaration', '-Werror=incompatible-function-pointer-types']
subprocess.run(args, cwd=entry['directory'], check=True)
# Resolve the API18 object's native imports against the same API18 system library.
# QEMU symbols remain undefined in this isolated probe; the complete core link is checked separately.
probe = build/'ohaudio-api18-probe.so'
subprocess.run([str(compiler), '--target=aarch64-unknown-linux-ohos', '--sysroot='+str(native/'sysroot'), '-shared',
                str(output), '-lohaudio', '-o', str(probe)], check=True)
from verify_ohaudio_build import verify
result = verify(probe)
# Shared-object links allow unresolved QEMU symbols. Independently require every
# imported OH_Audio API to be exported by the actual API18 SDK library.
imports = subprocess.check_output(['readelf', '--wide', '--dyn-syms', str(probe)], text=True)
required = {line.split()[7].split('@')[0] for line in imports.splitlines()
            if ' UND ' in line and len(line.split()) >= 8 and line.split()[7].startswith('OH_Audio')}
libraries = list((native/'sysroot').rglob('libohaudio.so'))
exports = set()
for library in libraries:
    header = subprocess.check_output(['readelf', '-h', str(library)], text=True)
    if 'AArch64' not in header:
        continue
    symbols = subprocess.check_output(['readelf', '--wide', '--dyn-syms', str(library)], text=True)
    exports.update(line.split()[7].split('@')[0] for line in symbols.splitlines()
                   if len(line.split()) >= 8 and ' UND ' not in line)
if not required or not required <= exports:
    raise SystemExit('API18 SDK does not export required audio APIs: ' + str(sorted(required - exports)))
result['api18ExportedApis'] = sorted(required)
result['nativeSdkMetadata'] = metadata
result['api18BackendCompile'] = 'verified'
result['scope'] = 'backend recompile/link probe; full core uses separately recorded native SDK'
(build/'ohaudio-api18-evidence.json').write_text(json.dumps(result, indent=2)+'\n')
print(json.dumps(result, indent=2))
