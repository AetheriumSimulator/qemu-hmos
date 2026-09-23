"""Exercise publication boundaries against real temporary Git indexes."""
import pathlib
import subprocess
import tempfile
import unittest

from check_public_source import check


class PublicSourceTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = pathlib.Path(self.directory.name)
        self.git('init', '-q')
        self.git('config', 'core.autocrlf', 'false')
        for path in ('LICENSE', 'LICENSE-APACHE',
                     'entry/src/main/cpp/types/libqemu_hmos/Index.d.ts',
                     'entry/src/main/cpp/types/libqemu_hmos/oh-package.json5'):
            self.stage(path, b'fixture source\n')

    def git(self, *args, data=None):
        return subprocess.run(['git', *args], cwd=self.root, input=data,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True).stdout

    def stage(self, name, data):
        target = self.root / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        self.git('add', '--', name)

    def findings(self):
        return check(self.root)['findings']

    def test_source_only_index_passes(self):
        self.assertFalse(self.findings())

    def test_untracked_developer_files_are_not_published(self):
        (self.root / 'local.properties').write_text('developer local')
        self.assertFalse(self.findings())

    def test_generated_dependency_cache_is_rejected(self):
        self.stage('entry/oh_modules/generated/Index.ets', b'generated copy')
        self.assertTrue(self.findings())

    def test_native_module_source_survives_cache_removal(self):
        self.stage('entry/oh_modules/qemu_hmos/Index.d.ts', b'generated copy')
        self.git('rm', '--cached', '--', 'entry/oh_modules/qemu_hmos/Index.d.ts')
        self.assertFalse(self.findings())

    def test_missing_native_module_source_is_rejected(self):
        self.git('rm', '--cached', '--', 'entry/src/main/cpp/types/libqemu_hmos/Index.d.ts')
        self.assertTrue(self.findings())

    def test_disguised_binary_is_rejected(self):
        self.stage('tools/innocent.txt', b'\x7fELF' + bytes(20))
        self.assertTrue(self.findings())

    def test_versioned_library_is_rejected(self):
        self.stage('entry/src/main/libs/libexample.so.0.backup', b'not even an ELF')
        self.assertTrue(self.findings())

    def test_unsigned_profile_passes(self):
        self.stage('build-profile.json5', b'{"app":{"signingConfigs":[]}}')
        self.assertFalse(self.findings())

    def test_staged_secret_remains_rejected_after_worktree_cleanup(self):
        name = 'build-profile.json5'
        secret = b'synthetic-value-for-test'
        self.stage(name, b'{"' + b'keyPassword' + b'":"' + secret + b'"}')
        (self.root / name).write_text('{}')
        result = str(self.findings())
        self.assertIn('saved signing password', result)
        self.assertNotIn(secret.decode(), result)

    def test_private_key_and_credential_url_report_no_values(self):
        key = b'-----BEGIN ' + b'PRIVATE KEY-----'
        self.stage('config.txt', key + b'\nhttps://' + b'fixture-user:fixture-secret@example.invalid')
        result = str(self.findings())
        self.assertIn('private key marker', result)
        self.assertIn('credential-bearing URL', result)
        self.assertNotIn('fixture-secret', result)

    def test_vendored_fixture_is_explicitly_outside_secret_scan(self):
        self.stage('third_party/example/test_fixture.c', b'-----BEGIN ' + b'PRIVATE KEY-----')
        result = check(self.root)
        self.assertTrue(result['passed'])
        self.assertIn('separate provenance review', result['scope'])

    def test_upstream_license_is_preserved(self):
        self.stage('third_party/example/COPYING', b'upstream license')
        self.assertFalse(self.findings())

    def test_external_symlink_is_rejected_without_following_it(self):
        oid = self.git('hash-object', '-w', '--stdin', data=b'../../outside').strip().decode()
        self.git('update-index', '--add', '--cacheinfo', f'120000,{oid},external-link')
        self.assertTrue(self.findings())


if __name__ == '__main__':
    unittest.main()
