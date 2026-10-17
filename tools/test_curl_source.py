import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from verify_curl_source import tree_id, verify


class CurlSourceTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / 'a.c').write_text('source\n')
        (self.root / 'a').mkdir()
        (self.root / 'a' / 'build.sh').write_text('#!/bin/sh\n')
        (self.root / 'a' / 'build.sh').chmod(0o755)
        (self.root / 'a.c-link').symlink_to('a.c')
        subprocess.run(['git', 'init', '-q', str(self.root)], check=True)
        subprocess.run(['git', '-C', str(self.root), 'add', '.'], check=True)
        self.expected = subprocess.check_output(
            ['git', '-C', str(self.root), 'write-tree'], text=True).strip()

    def test_git_tree_matches_git_oracle_and_metadata_free_archive(self):
        self.assertEqual(verify(self.root, self.expected), self.expected)
        import shutil
        shutil.rmtree(self.root / '.git')
        self.assertEqual(verify(self.root, self.expected), self.expected)

    def test_tamper_missing_extra_mode_and_symlink_are_rejected(self):
        changes = [
            lambda: (self.root / 'a.c').write_text('changed'),
            lambda: (self.root / 'a.c').unlink(),
            lambda: (self.root / 'extra').write_text('extra'),
            lambda: (self.root / 'a' / 'build.sh').chmod(0o644),
            lambda: ((self.root / 'a.c-link').unlink(),
                     (self.root / 'a.c-link').symlink_to('/outside')),
        ]
        for change in changes:
            with self.subTest(change=change):
                subprocess.run(['git', '-C', str(self.root), 'checkout', '--', '.'], check=True)
                (self.root / 'extra').unlink(missing_ok=True)
                change()
                with self.assertRaisesRegex(ValueError, 'tree mismatch'):
                    verify(self.root, self.expected)

    def test_existing_invalid_snapshot_fails_without_fetch(self):
        import shutil
        project = self.root / 'project'
        (project / 'tools').mkdir(parents=True)
        for name in ('build_curl_ohos.sh', 'verify_curl_source.py'):
            shutil.copy(Path(__file__).parent / name, project / 'tools' / name)
        build = project / 'third_party/deps/.ohos-build'
        (build / 'toolchain').mkdir(parents=True)
        (build / 'toolchain/aarch64-unknown-linux-ohos-toolchain.cmake').touch()
        prefix = project / 'third_party/deps/install-ohos/lib'
        prefix.mkdir(parents=True)
        for lib in ('libssl.a', 'libcrypto.a'):
            (prefix / lib).touch()
        from verify_curl_source import CURL_REVISION
        (build / ('curl-' + CURL_REVISION)).mkdir()
        fake = project / 'bin'
        fake.mkdir()
        for name in ('git', 'cmake'):
            p = fake / name
            p.write_text('#!/bin/sh\necho UNEXPECTED_TOOL >&2\nexit 99\n')
            p.chmod(0o755)
        result = subprocess.run(['bash', str(project / 'tools/build_curl_ohos.sh')],
                                env={**os.environ, 'PATH': str(fake) + ':' + os.environ['PATH']},
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('tree mismatch', result.stderr)
        self.assertNotIn('UNEXPECTED_TOOL', result.stderr)

    def test_pinned_git_crlf_checkout_rules(self):
        p = self.root / 'projects/Windows/tmpl/curl.sln'
        p.parent.mkdir(parents=True)
        p.write_bytes(b'line\n')
        expected = tree_id(self.root).hex()
        p.write_bytes(b'line\r\n')
        self.assertEqual(verify(self.root, expected), expected)
        (self.root / 'a.c').write_bytes(b'source\r\n')
        with self.assertRaises(ValueError):
            verify(self.root, expected)


if __name__ == '__main__':
    unittest.main()
