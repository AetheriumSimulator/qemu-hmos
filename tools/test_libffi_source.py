import hashlib
import io
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch
import urllib.error
import libffi_source as source


class LibffiTests(unittest.TestCase):
    def test_official_success_never_uses_cache(self):
        calls=[]
        def fetch(*args): calls.append(args)
        self.assertEqual(source.obtain(Path('unused'), fetch, lambda _:None)[0], source.OFFICIAL)
        self.assertEqual(len(calls), 1)

    def test_504_retries_then_uses_locked_cache(self):
        calls=[]
        def fetch(url, target, digest):
            calls.append((url,digest))
            if url==source.OFFICIAL:
                raise urllib.error.HTTPError(url,504,'service failure',{},None)
        result=source.obtain(Path('unused'),fetch,lambda _:None)
        self.assertEqual(result, (source.CACHE,source.CACHE_SHA,source.PREFIX))
        self.assertEqual(calls,[(source.OFFICIAL,source.OFFICIAL_SHA)]*2+[(source.CACHE,source.CACHE_SHA)])

    def test_denial_or_hash_failure_never_falls_back(self):
        for error in (urllib.error.HTTPError(source.OFFICIAL,403,'denied',{},None),
                      urllib.error.HTTPError(source.OFFICIAL,401,'denied',{},None),
                      ValueError('archive hash mismatch')):
            calls=[]
            def fetch(*args): calls.append(args);raise error
            with self.assertRaises(type(error)):
                source.obtain(Path('unused'),fetch,lambda _:None)
            self.assertEqual(len(calls),1)

    def test_download_checks_sha256(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/'archive'
            with patch('libffi_source.urllib.request.urlopen',return_value=io.BytesIO(b'bytes')):
                source.download('fixture',path,hashlib.sha256(b'bytes').hexdigest())
            with patch('libffi_source.urllib.request.urlopen',return_value=io.BytesIO(b'altered')):
                with self.assertRaisesRegex(ValueError,'SHA-256'):
                    source.download('fixture',path,hashlib.sha256(b'bytes').hexdigest())

    def test_tree_hash_covers_contents_names_and_executable_bits(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);p=root/'LICENSE';p.write_text('license');p.chmod(0o644)
            expected=source.tree_id(root)
            with patch.object(source,'TREE',expected):
                source.verify(root)
                p.chmod(0o755)
                with self.assertRaises(ValueError): source.verify(root)
                p.chmod(0o644);p.write_text('changed')
                with self.assertRaises(ValueError): source.verify(root)

    def test_archive_rejects_traversal_links_and_duplicates(self):
        for names,symlink in [(['root/../escape'],False),(['root/.git/config'],False),
                              (['root/link'],True),(['root/a','root/a'],False)]:
            with tempfile.TemporaryDirectory() as tmp:
                root=Path(tmp);archive=root/'archive.tar.gz';dest=root/'out';dest.mkdir()
                with tarfile.open(archive,'w:gz') as tar:
                    for name in names:
                        entry=tarfile.TarInfo(name)
                        if symlink: entry.type=tarfile.SYMTYPE;entry.linkname='/outside';tar.addfile(entry)
                        else: entry.size=1;tar.addfile(entry,io.BytesIO(b'x'))
                with self.assertRaises(ValueError): source.extract(archive,'root/',dest)

if __name__=='__main__': unittest.main()
