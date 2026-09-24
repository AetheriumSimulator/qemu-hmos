"""Source reconstruction tests using real Git objects, not build/runtime claims."""
import copy
import io
import json
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest

from verify_port_sources import digest, indexed_files, replay_qemu, validate_qemu, validate_vnc


class PortTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='port-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / 'upstream'
        self.repo.mkdir()
        self.git('init', '-q')
        self.git('config', 'core.autocrlf', 'false')
        for name, data in {'VERSION': b'1.0\n', 'COPYING': b'fixture license\n',
                           'core.c': b'int main(void) { return 0; }\n'}.items():
            (self.repo / name).write_bytes(data)
        self.git('add', '.')
        self.git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                 'commit', '-qm', 'fixture base')
        base = self.git('rev-parse', 'HEAD').decode().strip()
        base_tree = self.git('rev-parse', 'HEAD^{tree}').decode().strip()
        (self.repo / 'core.c').write_bytes(b'int main(void) { return 1; }\n')
        self.git('add', 'core.c')
        port_tree = self.git('write-tree').decode().strip()
        patch = self.git('diff', '--cached', '--full-index', '--no-ext-diff', 'HEAD')
        (self.repo / 'phone.c').write_bytes(b'void phone(void) {}\n')
        self.git('add', 'phone.c')
        final_tree = self.git('write-tree').decode().strip()
        self.files = {'base-port.patch': patch, 'COPYING': b'fixture license\n',
                      'overlay/phone.c': b'void phone(void) {}\n'}
        self.manifest = {'schemaVersion': 1, 'upstream': {'commit': base,
            'tree': base_tree, 'version': '1.0'}, 'downstream': {'commit': base,
            'tree': port_tree, 'patch': {'path': 'base-port.patch', 'sha256': digest(patch)}},
            'exportedTree': final_tree, 'licenses': [{'path': 'COPYING',
            'sha256': digest(self.files['COPYING'])}], 'overlay': [{'path': 'phone.c',
            'mode': '100644', 'sha256': digest(self.files['overlay/phone.c'])}],
            'runtimeEvidence': {'reentrant': False, 'binaryRebuiltFromThisExport': False,
                                'hapMatchedToThisExport': False},
            'remainingInputs': ['Complete application review and binary reproduction.']}
        self.save_manifest()

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.repo), *args], stderr=subprocess.PIPE)

    def save_manifest(self):
        self.files['manifest.json'] = json.dumps(self.manifest).encode()

    def test_replay_and_archive_leave_upstream_untouched(self):
        index = self.git('write-tree')
        refs = self.git('show-ref')
        output = self.root / 'source.tar'
        self.assertEqual(replay_qemu(self.repo, self.files, output), self.manifest['exportedTree'])
        self.assertEqual(self.git('write-tree'), index)
        self.assertEqual(self.git('show-ref'), refs)
        with tarfile.open(fileobj=io.BytesIO(output.read_bytes())) as archive:
            self.assertEqual(archive.extractfile('phone.c').read(), self.files['overlay/phone.c'])
            self.assertEqual(archive.extractfile('core.c').read(), b'int main(void) { return 1; }\n')

    def test_patch_tampering(self):
        self.files['base-port.patch'] += b'changed'
        with self.assertRaisesRegex(ValueError, 'changed source evidence'):
            validate_qemu(self.files)

    def test_overlay_tampering(self):
        self.files['overlay/phone.c'] += b'changed'
        with self.assertRaises(ValueError):
            validate_qemu(self.files)

    def test_updated_hash_does_not_bypass_tree_check(self):
        self.files['overlay/phone.c'] += b'changed'
        self.manifest['overlay'][0]['sha256'] = digest(self.files['overlay/phone.c'])
        self.save_manifest()
        with self.assertRaisesRegex(ValueError, 'overlay tree mismatch'):
            replay_qemu(self.repo, self.files)

    def test_wrong_base_tree(self):
        self.manifest['upstream']['tree'] = '0' * 40
        self.save_manifest()
        with self.assertRaisesRegex(ValueError, 'commit/tree mismatch'):
            replay_qemu(self.repo, self.files)

    def test_wrong_downstream_tree(self):
        self.manifest['downstream']['tree'] = '0' * 40
        self.save_manifest()
        with self.assertRaisesRegex(ValueError, 'recorded tree'):
            replay_qemu(self.repo, self.files)

    def test_missing_upstream_object(self):
        self.manifest['upstream']['commit'] = '0' * 40
        self.save_manifest()
        with self.assertRaises(ValueError):
            replay_qemu(self.repo, self.files)

    def test_unlisted_overlay(self):
        self.files['overlay/extra.c'] = b'unreviewed'
        with self.assertRaisesRegex(ValueError, 'inventory'):
            validate_qemu(self.files)

    def test_unsafe_duplicate_and_symlink_entries(self):
        original = copy.deepcopy(self.manifest)
        for path in ('../escape', '/absolute', 'C:/absolute', '.git/config', 'a\\b', 'a//b'):
            with self.subTest(path=path):
                self.manifest = copy.deepcopy(original)
                self.manifest['overlay'][0]['path'] = path
                self.save_manifest()
                with self.assertRaises(ValueError):
                    validate_qemu(self.files)
        self.manifest = copy.deepcopy(original)
        self.manifest['overlay'].append(self.manifest['overlay'][0])
        self.save_manifest()
        with self.assertRaises(ValueError):
            validate_qemu(self.files)
        self.manifest = copy.deepcopy(original)
        self.manifest['overlay'][0]['mode'] = '120000'
        self.save_manifest()
        with self.assertRaises(ValueError):
            validate_qemu(self.files)

    def test_source_check_cannot_enable_reentry(self):
        self.manifest['runtimeEvidence']['reentrant'] = True
        self.save_manifest()
        with self.assertRaisesRegex(ValueError, 'cannot certify'):
            validate_qemu(self.files)

    def test_archive_does_not_overwrite(self):
        output = self.root / 'source.tar'
        output.write_bytes(b'keep me')
        with self.assertRaises(FileExistsError):
            replay_qemu(self.repo, self.files, output)
        self.assertEqual(output.read_bytes(), b'keep me')

    def test_reads_staged_evidence_not_unstaged_repair(self):
        path = self.repo / 'ports/fixture/data.txt'
        path.parent.mkdir(parents=True)
        path.write_bytes(b'staged')
        self.git('add', 'ports')
        path.write_bytes(b'unstaged')
        self.assertEqual(indexed_files(self.repo, 'ports/fixture/')['data.txt'], b'staged')

    def test_vnc_recipe_drift_is_not_hidden(self):
        files = {'COPYING': b'license', 'tools/build_libvnc_ohos.sh': b'new recipe'}
        lock = {'component': {'upstreamRevision': 'a' * 40, 'upstreamTree': 'b' * 40,
            'repository': 'https://example.invalid/upstream',
            'licenseSha256': digest(files['COPYING']), 'build': {'scriptSha256': digest(b'old recipe')}}}
        files['sources.lock.json'] = json.dumps(lock).encode()
        manifest = {'schemaVersion': 1, 'source': {'commit': 'a' * 40, 'tree': 'b' * 40,
            'url': 'https://example.invalid/upstream'},
            'recipeMatchesRetainedLock': False,
            'evidence': [{'path': p, 'sha256': digest(b)} for p, b in files.items()]}
        files['manifest.json'] = json.dumps(manifest).encode()
        validate_vnc(files)
        manifest['recipeMatchesRetainedLock'] = True
        files['manifest.json'] = json.dumps(manifest).encode()
        with self.assertRaisesRegex(ValueError, 'drift'):
            validate_vnc(files)


if __name__ == '__main__':
    unittest.main()
