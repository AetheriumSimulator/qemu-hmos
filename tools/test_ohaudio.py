"""Regression checks for mandatory patching and the compiled audio contract."""
from pathlib import Path
import subprocess
import tempfile
import unittest
import zipfile
from unittest.mock import patch
from apply_ohaudio_patch import apply
from verify_ohaudio_build import verify

ROOT = Path(__file__).resolve().parents[1]


class AudioTests(unittest.TestCase):
    def test_patch_apply_repeat_and_drift(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            subprocess.run(['git', 'init', '-q', str(root)], check=True)
            source = root/'x'
            source.write_text('old\n')
            delta = root/'change.patch'
            delta.write_text('diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-old\n+new\n')
            apply(root, delta)
            apply(root, delta)
            self.assertEqual(source.read_text(), 'new\n')
            source.write_text('unexpected\n')
            with self.assertRaisesRegex(RuntimeError, 'does not apply cleanly'):
                apply(root, delta)
            with self.assertRaisesRegex(RuntimeError, 'missing'):
                apply(root, root/'missing.patch')

    def test_backend_pcm_and_failure_cleanup(self):
        # Compile the actual patch-added source against deliberately minimal mocks.
        # Real QEMU + SDK headers and linking are checked by validate-so CI.
        delta = (ROOT/'patches/qemu/0002-ohos-ohaudio-audiodev.patch').read_text()
        chunk = delta.split('+++ b/audio/aether_soundkit_hmos.c\n', 1)[1].split('diff --git ', 1)[0]
        backend = '\n'.join(line[1:] for line in chunk.splitlines() if line.startswith('+'))
        backend = '\n'.join(line for line in backend.splitlines() if not line.startswith('#include'))
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)
            (path/'backend.c').write_text(backend)
            # Execute QEMU's real guest-facing dispatch as well as the backend:
            # a resampling queue must never bypass the current permission gate.
            audio = (ROOT/'third_party/qemu/audio/audio.c').read_text()
            start = audio.index('size_t AUD_read(SWVoiceIn *sw, void *buf, size_t size)')
            end = audio.index('\n}\n', start) + 3
            (path/'aud_read.c').write_text(audio[start:end])
            binary = path/'test'
            subprocess.run(['cc', '-std=c11', '-Wall', '-Werror', '-pthread', '-I', tmp,
                            str(ROOT/'tools/tests/ohaudio/harness.c'), '-o', str(binary)], check=True)
            subprocess.run([str(binary)], check=True, timeout=15)

    def test_native_microphone_session_generation(self):
        with tempfile.TemporaryDirectory() as tmp:
            binary = Path(tmp)/'session'
            subprocess.run(['c++', '-std=c++17', '-Wall', '-Wextra', '-Werror',
                            '-pthread', '-I', str(ROOT/'entry/src/main/cpp'),
                            str(ROOT/'tools/tests/ohaudio/session.cpp'), '-o', str(binary)], check=True)
            subprocess.run([str(binary)], check=True, timeout=15)

    def test_load_image_accepts_stripping_but_rejects_code_change(self):
        from validate_hap import load_image
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp)
            (p/'core.c').write_text('int audio_fixture(void) { return 42; }')
            subprocess.run(['cc', '-shared', '-fPIC', '-g', str(p/'core.c'), '-o', str(p/'core.so')], check=True)
            original = (p/'core.so').read_bytes()
            subprocess.run(['strip', '--strip-unneeded', str(p/'core.so')], check=True)
            stripped = (p/'core.so').read_bytes()
            self.assertNotEqual(original, stripped)
            self.assertEqual(load_image(original), load_image(stripped))
            # ELF .text offset from the actual section table, not guessed bytes.
            import re
            sections = subprocess.check_output(['readelf', '-SW', str(p/'core.so')], text=True)
            offset = int(re.search(r'\.text\s+PROGBITS\s+\S+\s+(\S+)', sections)[1], 16)
            altered = bytearray(stripped)
            altered[offset] ^= 1
            self.assertNotEqual(load_image(original), load_image(altered))

    def test_hap_requires_identical_validated_core(self):
        import hashlib
        from validate_hap import (FIRMWARE_ENTRY, FIRMWARE_DIGEST_ENTRY,
                                  PFLASH_SIZE, REQUIRED_ENTRIES)
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)
            hap = path/'test.hap'
            core = path/'core.so'
            firmware = bytes(PFLASH_SIZE)
            with zipfile.ZipFile(hap, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
                for name in REQUIRED_ENTRIES:
                    if name == FIRMWARE_ENTRY:
                        content = firmware
                    elif name == FIRMWARE_DIGEST_ENTRY:
                        content = (hashlib.sha256(firmware).hexdigest() + '\n').encode('ascii')
                    else:
                        content = b'synthetic core fixture'
                    archive.writestr(name, content)
            core.write_bytes(b'synthetic core fixture')
            command = ['python3', str(ROOT/'tools/validate_hap.py'), str(hap), '--core', str(core)]
            self.assertEqual(subprocess.run(command, capture_output=True).returncode, 0)
            core.write_bytes(b'wrong core')
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('differs from', result.stderr)

    def test_api18_command_and_dependency_isolation(self):
        from ohaudio_api18_args import retarget, check_dependencies
        args = retarget(['old-cc', '-I/old/sdk/sysroot/usr/include', '-isystem',
                         '/old/sdk/llvm/lib/clang/include', '--sysroot=/old/sdk/sysroot',
                         '-o', 'old.o', '-MMD', '-MF', 'old.d', '-c', 'backend.c'],
                        '/old/sdk', '/api18/sdk', 'new.o', 'new.d')
        self.assertFalse(any('/old/sdk' in arg for arg in args))
        self.assertIn('-I/api18/sdk/sysroot/usr/include', args)
        self.assertIn('-MD', args)
        self.assertNotIn('-MMD', args)
        self.assertNotIn('old.d', args)
        header = '/api18/sdk/sysroot/usr/include/ohaudio/native_audiostreambuilder.h'
        permission = '/api18/sdk/sysroot/usr/include/accesstoken/ability_access_control.h'
        self.assertEqual(check_dependencies('new.o: '+header+' '+permission,
                                             '/old/sdk', '/api18/sdk'), [permission, header])
        for deps in ('new.o: /old/sdk/sysroot/usr/include/sys/types.h '+header,
                     'new.o: /foreign/ohaudio/native_audiostreambuilder.h',
                     'new.o: '+header,
                     'new.o: '+header+' /foreign/accesstoken/ability_access_control.h'):
            with self.assertRaises(ValueError):
                check_dependencies(deps, '/old/sdk', '/api18/sdk')

    def test_compiled_napi_arguments(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp)/'args.cpp'
            source.write_text('''#include <cassert>
#include "ohaudio_args.h"
int main() {
  assert(BuildOHAudioArgs("snd0") == "aether-soundkit-hmos,id=snd0,out.frequency=48000,out.channels=2,out.format=s16,in.mixing-engine=off,in.voices=1");
  assert(BuildOHAudioArgs("second").find("id=second,") != std::string::npos);
}''')
            binary = Path(tmp)/'test'
            subprocess.run(['c++', '-std=c++17', '-Wall', '-Werror', '-I', str(ROOT/'entry/src/main/cpp'), str(source), '-o', str(binary)], check=True)
            subprocess.run([str(binary)], check=True)

    def test_elf_verifier_rejects_missing_registration_or_linkage(self):
        symbols = '\n'.join('1: 0 0 FUNC LOCAL DEFAULT 1 '+s for s in (
            'register_audio_aether_soundkit_hmos', 'aether_audio_driver', 'aether_init_out', 'aether_init_in'))
        exports = '\n'.join('1: 0 0 FUNC GLOBAL DEFAULT 1 '+s for s in (
            'qemu_hmos_set_microphone_enabled', 'qemu_hmos_get_microphone_status'))
        symbols += '\n' + exports
        symbols += '\n' + '\n'.join('1: 0 0 FUNC GLOBAL DEFAULT UND '+s for s in (
            'OH_AudioStreamBuilder_SetRendererCallback', 'OH_AudioStreamBuilder_SetCapturerCallback',
            'OH_AudioRenderer_Start', 'OH_AudioCapturer_Start', 'OH_AT_CheckSelfPermission'))
        dynamic = ('0 (NEEDED) Shared library: [libohaudio.so]\n'
                   '0 (NEEDED) Shared library: [libability_access_control.so]')
        with patch('verify_ohaudio_build.subprocess.check_output', side_effect=[symbols, dynamic, exports]):
            self.assertEqual(verify(Path('fixture'))['deviceCapture'], 'not-executed')
        for bad_symbols, bad_dynamic in [(symbols.replace('aether_init_in', 'missing'), dynamic),
                                         (symbols.replace('OH_AudioCapturer_Start', 'missing'), dynamic),
                                         (symbols.replace('OH_AT_CheckSelfPermission', 'missing'), dynamic),
                                         (symbols, dynamic.replace('libability_access_control.so', 'missing')),
                                         (symbols, '')]:
            with patch('verify_ohaudio_build.subprocess.check_output', side_effect=[bad_symbols, bad_dynamic, exports]):
                with self.assertRaises(ValueError):
                    verify(Path('fixture'))
        for bad_exports in ('', exports.replace('GLOBAL', 'LOCAL'),
                            exports.replace('DEFAULT', 'HIDDEN'),
                            exports.replace('DEFAULT 1', 'DEFAULT UND'),
                            exports.replace('qemu_hmos_set_microphone_enabled', 'missing'),
                            exports.replace('qemu_hmos_get_microphone_status', 'missing')):
            with patch('verify_ohaudio_build.subprocess.check_output',
                       side_effect=[symbols, dynamic, bad_exports]):
                with self.assertRaisesRegex(ValueError, 'exported microphone privacy ABI'):
                    verify(Path('fixture'))


if __name__ == '__main__':
    unittest.main()
