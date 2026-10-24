"""Exercise firmware preparation and the actual HAP payload validator."""
import hashlib
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import zipfile

from prepare_firmware import PFLASH_SIZE, prepare_arm64_code
from validate_hap import FIRMWARE_ENTRY, FIRMWARE_DIGEST_ENTRY, REQUIRED_ENTRIES


ROOT = Path(__file__).resolve().parents[1]


class FirmwarePackageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / 'QEMU_EFI.fd'
        self.destination = self.root / 'artifacts' / 'edk2-aarch64-code.fd'

    def test_two_mib_volume_keeps_bytes_and_gets_zero_tail_and_digest(self):
        original = bytes(range(256)) * (2 * 1024 * 1024 // 256)
        self.source.write_bytes(original)
        digest = prepare_arm64_code(self.source, self.destination)
        image = self.destination.read_bytes()
        self.assertEqual(self.source.read_bytes(), original)
        self.assertEqual(len(image), PFLASH_SIZE)
        self.assertEqual(image[:len(original)], original)
        self.assertEqual(image[len(original):], bytes(PFLASH_SIZE - len(original)))
        self.assertEqual(digest, hashlib.sha256(image).hexdigest())
        self.assertEqual(self.destination.with_name(self.destination.name + '.sha256').read_text(),
                         digest + '\n')

    def test_full_size_input_is_byte_identical_and_repeatable(self):
        with self.source.open('wb') as stream:
            stream.write(b'full size code')
            stream.truncate(PFLASH_SIZE)
            stream.seek(PFLASH_SIZE - 4)
            stream.write(b'tail')
        original = hashlib.sha256(self.source.read_bytes()).hexdigest()
        self.assertEqual(prepare_arm64_code(self.source, self.destination), original)
        self.assertEqual(prepare_arm64_code(self.source, self.destination), original)
        self.assertEqual(hashlib.sha256(self.destination.read_bytes()).hexdigest(), original)

    def test_invalid_inputs_leave_existing_artifact_unchanged(self):
        self.destination.parent.mkdir()
        self.destination.write_bytes(b'existing artifact')
        for size in (0, PFLASH_SIZE + 1):
            with self.subTest(size=size):
                with self.source.open('wb') as stream:
                    stream.truncate(size)
                with self.assertRaisesRegex(ValueError, '1..67108864'):
                    prepare_arm64_code(self.source, self.destination)
                self.assertEqual(self.destination.read_bytes(), b'existing artifact')
        self.source.write_bytes(b'original')
        with self.assertRaisesRegex(ValueError, 'must differ'):
            prepare_arm64_code(self.source, self.source)
        self.assertEqual(self.source.read_bytes(), b'original')

    def make_hap(self, firmware: bytes, digest: bytes | None) -> Path:
        hap = self.root / 'fixture.hap'
        with zipfile.ZipFile(hap, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
            for name in REQUIRED_ENTRIES:
                if name not in (FIRMWARE_ENTRY, FIRMWARE_DIGEST_ENTRY):
                    archive.writestr(name, b'nonempty fixture')
            archive.writestr(FIRMWARE_ENTRY, firmware)
            if digest is not None:
                archive.writestr(FIRMWARE_DIGEST_ENTRY, digest)
        return hap

    def validate(self, hap: Path) -> subprocess.CompletedProcess:
        return subprocess.run([sys.executable, str(ROOT / 'tools/validate_hap.py'), str(hap)],
                              capture_output=True, text=True, timeout=30)

    def test_actual_hap_validator_accepts_padded_firmware(self):
        self.source.write_bytes(b'EDK2 volume')
        digest = prepare_arm64_code(self.source, self.destination)
        hap = self.make_hap(self.destination.read_bytes(), (digest + '\n').encode('ascii'))
        result = self.validate(hap)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('67108864 bytes', result.stdout)

    def test_actual_hap_validator_rejects_wrong_size_digest_or_missing_sidecar(self):
        full = bytes(PFLASH_SIZE)
        digest = (hashlib.sha256(full).hexdigest() + '\n').encode('ascii')
        cases = ((full[:2 * 1024 * 1024], digest, 'exactly 67108864'),
                 (full, b'0' * 64 + b'\n', 'does not match'),
                 (full, digest[:-1], '64 hex digits'),
                 (full, None, 'missing required entries'))
        for firmware, sidecar, expected in cases:
            with self.subTest(expected=expected):
                result = self.validate(self.make_hap(firmware, sidecar))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(expected, result.stderr)


if __name__ == '__main__':
    unittest.main()
