import copy
import hashlib
import unittest

from check_source_inventory import validate


class SourceInventoryTest(unittest.TestCase):
    def setUp(self):
        self.license = b'upstream license fixture'
        self.entries = [('third_party/example', '160000', '1' * 40),
                        ('LICENSES/example.txt', '100644', '2' * 40)]
        self.blobs = {'2' * 40: self.license}
        self.manifest = {
            'schemaVersion': 1,
            'binaryPublication': {'status': 'blocked', 'blockers': ['missing release evidence']},
            'components': [{'id': 'example', 'origin': 'https://example.invalid/upstream.git',
                            'status': 'pinned-upstream-with-patches',
                            'source': {'kind': 'gitlink', 'path': 'third_party/example', 'revision': '1' * 40},
                            'licenseEvidence': [{'path': 'LICENSES/example.txt',
                                                 'sha256': hashlib.sha256(self.license).hexdigest()}]}],
        }

    def errors(self):
        return validate(self.manifest, self.entries, self.blobs, lambda path: '3' * 40)

    def test_valid_partial_inventory_does_not_claim_release_readiness(self):
        self.assertFalse(self.errors())
        self.assertEqual(self.manifest['binaryPublication']['status'], 'blocked')

    def test_changed_gitlink_is_rejected(self):
        self.manifest['components'][0]['source']['revision'] = '4' * 40
        self.assertTrue(self.errors())

    def test_missing_or_changed_license_is_rejected(self):
        self.blobs['2' * 40] = b'changed'
        self.assertTrue(self.errors())
        self.entries.pop()
        self.assertTrue(self.errors())

    def test_empty_license_evidence_is_rejected(self):
        self.manifest['components'][0]['licenseEvidence'] = []
        self.assertTrue(self.errors())

    def test_forged_ready_flag_does_not_enable_release(self):
        self.manifest['binaryPublication'] = {'status': 'ready', 'blockers': []}
        self.assertTrue(self.errors())

    def test_credential_bearing_origin_is_rejected(self):
        self.manifest['components'][0]['origin'] = 'https://' + 'user:secret@example.invalid/upstream'
        self.assertTrue(self.errors())

    def test_source_tree_changes_require_review(self):
        self.manifest['components'][0]['source'] = {
            'kind': 'vendored-tree', 'path': 'third_party/example', 'gitTree': '3' * 40}
        self.assertFalse(self.errors())
        self.manifest['components'][0]['source']['gitTree'] = '4' * 40
        self.assertTrue(self.errors())

    def test_duplicate_components_are_rejected(self):
        self.manifest['components'].append(copy.deepcopy(self.manifest['components'][0]))
        self.assertTrue(self.errors())

    def test_submodule_remote_cannot_silently_change(self):
        origins = {'third_party/example': 'https://different.invalid/upstream.git'}
        self.assertTrue(validate(self.manifest, self.entries, self.blobs, lambda path: '', origins))


if __name__ == '__main__':
    unittest.main()
