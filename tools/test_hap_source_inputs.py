import hashlib
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import prepare_hap_sources as prepare


class HapSourceInputTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.meson = self.root/'third_party/qemu/pc-bios/meson.build'
        self.meson.parent.mkdir(parents=True)
        self.original = b"roms = []\n# fixture preserves the upstream remainder\n"
        self.meson.write_bytes(self.original)
        self.pin = patch.object(prepare, 'PC_BIOS_SHA256', hashlib.sha256(self.original).hexdigest())
        self.pin.start()
        self.addCleanup(self.pin.stop)

    def test_metadata_free_source_preparation_and_idempotent_reconstruction(self):
        prepare.prepare(self.root)
        result = self.meson.read_bytes()
        self.assertTrue(result.startswith(prepare.GUARD))
        self.assertTrue(result.endswith(self.original[len(b'roms = []\n'):]))
        note = self.root/prepare.NOTE_PATH
        self.assertEqual(hashlib.sha256(note.read_bytes()).hexdigest(), prepare.NOTE_SHA256)
        note.unlink()
        prepare.prepare(self.root)
        self.assertEqual(self.meson.read_bytes(), result)
        self.assertEqual(note.read_bytes(), bytes.fromhex(
            '040000001000000005000000474e5500000000c0040000000100000000000000'))

    def test_unknown_upstream_recipe_is_not_patched(self):
        self.meson.write_bytes(self.original+b'# changed\n')
        with self.assertRaisesRegex(ValueError, 'Unexpected QEMU'):
            prepare.prepare(self.root)

    def test_changed_existing_note_is_not_overwritten(self):
        note = self.root/prepare.NOTE_PATH
        note.parent.mkdir(parents=True)
        note.write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'Unexpected EDK2'):
            prepare.prepare(self.root)
        self.assertEqual(note.read_bytes(), b'changed')


if __name__ == '__main__':
    unittest.main()
