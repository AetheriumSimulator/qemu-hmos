import copy
import io
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch
import delivery_policy as policy
import zipfile

from release_evidence import (ASSETS, REQUIRED_PAYLOAD, REQUIRED_REVIEWS, REQUIRED_SOURCES, digest,
                              file_hash, scope_hash, verify, add_file, TEXT_BUILD_INPUTS)


class ReleaseEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.out = Path(self.temp.name)
        self.sources = {'project/LICENSE': b'fixture license',
                        'project/src/main.c': b'int main(void) { return 0; }'}
        self.sources.update({name: b'Synthetic required-source fixture' for name in REQUIRED_SOURCES})
        self.review = {'reviews': {}}
        for topic in REQUIRED_REVIEWS:
            name = 'project/compliance/distribution-review/' + topic + '.md'
            self.sources[name] = ('Fixture review of ' + topic).encode()
            self.review['reviews'][topic] = {'path': name, 'sha256': digest(self.sources[name])}
        self.fixture_notices = {k: ('synthetic notice: ' + k).encode() for k in policy.NOTICE_FILES}
        self.notice_patch = patch.dict(policy.NOTICE_FILES,
                                       {k: digest(v) for k, v in self.fixture_notices.items()}, clear=True)
        self.notice_patch.start()
        self.addCleanup(self.notice_patch.stop)
        self.sources.update({policy.notice_path(k): v for k, v in self.fixture_notices.items()})
        runtime_patch = patch.object(policy, 'RUNTIME_SHA', digest(b'fixture, not a real device binary'))
        runtime_patch.start()
        self.addCleanup(runtime_patch.stop)
        self.repack()
        with zipfile.ZipFile(self.out/'aetherium-unsigned.hap', 'w') as archive:
            for name in sorted(REQUIRED_PAYLOAD | {policy.RUNTIME_PATH}):
                archive.writestr(name, b'fixture, not a real device binary')
        with zipfile.ZipFile(self.out/'aetherium-unsigned.hap') as archive:
            payload = [{'path': i.filename, 'sha256': digest(archive.read(i)), 'bytes': i.file_size}
                       for i in archive.infolist()]
        self.evidence = {'schemaVersion': 1, 'unsigned': True, 'commit': 'a'*40,
                         'deviceTest': 'not-executed', 'testDistribution': policy.disclosure(),
                         'sdkRuntimeEvidence': policy.runtime_provenance(),
                         'components': [{'path': 'project', 'revision': 'a'*40}],
                         'sourceMembers': self.members(), 'licenseFiles': [m for m in self.members() if any(word in Path(m['path']).name.lower() for word in ('license', 'licence', 'copying', 'copyright', 'notice'))],
                         'omissions': [], 'sdkInputs': [{'path': 'native', 'sha256': 'b'*64},
                                                       {'path': 'commandline-tools.zip', 'sha256': policy.SDK_SHA}],
                         'payload': payload, 'assets': {}}
        self.save()
        self.review['scopeSha256'] = self.evidence['scopeSha256']

    def members(self):
        return [{'path': k, 'kind': 'file', 'sha256': digest(v)} for k, v in sorted(self.sources.items())]

    def repack(self):
        with tarfile.open(self.out/'aetherium-source.tar.gz', 'w:gz') as archive:
            for name, data in sorted(self.sources.items()):
                member = tarfile.TarInfo(name)
                member.size = len(data)
                archive.addfile(member, io.BytesIO(data))

    def save(self):
        self.evidence['assets'] = {n: file_hash(self.out/n) for n in ASSETS - {'release-evidence.json'}}
        self.evidence['scopeSha256'] = scope_hash(self.evidence)
        (self.out/'release-evidence.json').write_text(json.dumps(self.evidence))

    def test_disclosed_test_policy_allows_pending_reviews_without_approval(self):
        self.assertEqual(verify(self.out, {}, 'a'*40, policy.POLICY), [])
        self.assertTrue(verify(self.out, {}, 'a'*40))
        self.assertEqual(self.evidence['testDistribution']['reviewStatus'], 'not-approved')

    def test_disclosure_cannot_claim_approval_or_hide_known_gaps(self):
        original = copy.deepcopy(self.evidence)
        for field, value in [('reviewStatus', 'approved'), ('unresolved', {}),
                             ('fullArchiveRebuild', 'success')]:
            self.evidence = copy.deepcopy(original)
            self.evidence['testDistribution'][field] = value
            self.save()
            self.assertTrue(verify(self.out, {}, 'a'*40, policy.POLICY))

    def test_test_policy_still_rejects_identity_and_source_defects(self):
        self.assertTrue(verify(self.out, {}, 'b'*40, policy.POLICY))
        for name in [policy.notice_path(next(iter(policy.NOTICE_FILES))), 'project/LICENSE']:
            data = self.sources.pop(name)
            self.repack()
            self.evidence['sourceMembers'] = self.members()
            self.save()
            self.assertTrue(verify(self.out, {}, 'a'*40, policy.POLICY))
            self.sources[name] = data
        self.repack()
        self.evidence['sourceMembers'] = self.members()
        self.evidence['sdkInputs'][1]['sha256'] = '0'*64
        self.save()
        self.assertTrue(verify(self.out, {}, 'a'*40, policy.POLICY))

    def test_test_policy_rejects_tampered_assets_and_scope(self):
        self.evidence['scopeSha256'] = '0'*64
        (self.out/'release-evidence.json').write_text(json.dumps(self.evidence))
        self.assertTrue(verify(self.out, {}, 'a'*40, policy.POLICY))
        self.save()
        with zipfile.ZipFile(self.out/'aetherium-unsigned.hap', 'a') as archive:
            archive.writestr('unexpected', b'tampered')
        self.assertTrue(verify(self.out, {}, 'a'*40, policy.POLICY))

    def test_new_source_scope_needs_identity_checks_not_fabricated_reviews(self):
        self.sources['project/src/main.c'] += b'\n/* changed */'
        self.repack()
        self.evidence['sourceMembers'] = self.members()
        self.save()
        self.assertEqual(verify(self.out, {}, 'a'*40, policy.POLICY), [])
        self.assertTrue(verify(self.out, self.review, 'a'*40))

    def test_complete_fixture_can_pass_without_signed_hap(self):
        self.assertEqual(verify(self.out, self.review, 'a'*40), [])

    def test_missing_reviews_and_ready_flag_cannot_approve(self):
        self.assertTrue(verify(self.out, {'allowed': True, 'status': 'ready'}))
        for topic in REQUIRED_REVIEWS:
            review = copy.deepcopy(self.review)
            del review['reviews'][topic]
            self.assertTrue(verify(self.out, review))

    def test_changed_hap_source_or_checkout_is_rejected(self):
        self.assertTrue(verify(self.out, self.review, 'd'*40))
        with zipfile.ZipFile(self.out/'aetherium-unsigned.hap', 'a') as archive:
            archive.writestr('unexpected.so', b'changed')
        self.assertTrue(verify(self.out, self.review))

    def test_changed_source_scope_requires_new_review(self):
        self.sources['project/src/main.c'] += b'\n/* changed */'
        self.repack()
        self.evidence['sourceMembers'] = self.members()
        self.save()
        self.assertTrue(verify(self.out, self.review))

    def test_review_document_hash_is_checked(self):
        self.sources['project/compliance/distribution-review/source-completeness.md'] = b'changed'
        self.repack()
        self.evidence['sourceMembers'] = self.members()
        self.save()
        self.assertTrue(verify(self.out, self.review))

    def test_extra_binary_delivery_is_rejected(self):
        (self.out/'libqemu_full.so').write_bytes(b'ELF')
        self.assertTrue(verify(self.out, self.review))

    def test_archive_traversal_and_compiled_payloads_are_rejected(self):
        for name, data in [('../outside', b'text'), ('project/evil', b'\x7fELFpayload')]:
            self.sources[name] = data
            self.repack()
            self.evidence['sourceMembers'] = self.members()
            self.save()
            self.review['scopeSha256'] = self.evidence['scopeSha256']
            self.assertTrue(verify(self.out, self.review))
            del self.sources[name]

    def test_collection_preserves_source_edits_and_excludes_binaries(self):
        source = self.out/'source.c'
        source.write_text('actual working tree')
        files, omissions = {}, []
        add_file(source, 'project/source.c', files, omissions)
        self.assertEqual(files['project/source.c'][1], b'actual working tree')
        source.write_bytes(b'\x7fELF')
        add_file(source, 'project/hidden.c', files, omissions)
        self.assertNotIn('project/hidden.c', files)
        self.assertEqual(len(omissions), 1)

    def test_external_source_symlink_is_reported_without_reading_host(self):
        link = self.out/'X11IncludeHack'
        link.symlink_to('/usr/include/X11')
        files, omissions = {}, []
        add_file(link, 'project/third_party/edk2/X11IncludeHack', files, omissions)
        self.assertFalse(files)
        self.assertEqual(omissions, [{'path': 'project/third_party/edk2/X11IncludeHack',
                                     'reason': 'external source symlink excluded',
                                     'target': '/usr/include/X11'}])

    def test_text_build_inputs_survive_but_binary_impersonation_fails(self):
        source = self.out/'input'
        for name in TEXT_BUILD_INPUTS:
            for data, accepted in [(b'# Makefile\r\nall:\n\techo test\n', True),
                                   ('expected output\r\n'.encode('utf-16'), True),
                                   (b'\x7fELFhidden', False), (b'MZhidden', False),
                                   (b'text\x00binary', False), (b'\xff', False)]:
                with self.subTest(name=name, data=data):
                    source.write_bytes(data)
                    files, omissions = {}, []
                    add_file(source, name, files, omissions)
                    self.assertEqual(name in files, accepted)

    def test_compressed_firmware_is_rejected_by_collection_and_verification(self):
        import bz2
        for name in ('project/pc-bios/code.fd.bz2', 'project/pc-bios/code.bin.gz',
                     'project/pc-bios/tree.dtb', 'project/pc-bios/code.fd.BZ2'):
            with self.subTest(name=name):
                data = bz2.compress(b'firmware volume')
                source = self.out/'fixture'
                source.write_bytes(data)
                files, omissions = {}, []
                add_file(source, name, files, omissions)
                self.assertFalse(files)
                source.unlink()
                self.sources[name] = data
                self.repack()
                self.evidence['sourceMembers'] = self.members()
                self.save()
                self.review['scopeSha256'] = self.evidence['scopeSha256']
                self.assertIn('Compiled binary in source archive', verify(self.out, self.review))
                del self.sources[name]

    def test_bti_note_is_reconstructed_not_silently_discarded(self):
        from prepare_hap_sources import NOTE_PATH, note_bytes
        source = self.out/'note'
        source.write_bytes(note_bytes())
        files, omissions = {}, []
        add_file(source, 'project/'+NOTE_PATH, files, omissions)
        self.assertFalse(files)
        self.assertIn('prepare_hap_sources.py', omissions[0]['reason'])
        source.write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'reconstruction recipe'):
            add_file(source, 'project/'+NOTE_PATH, {}, [])

    def test_no_device_claim_and_no_publication_outside_main_push(self):
        script = Path(__file__).with_name('publish_hap_prerelease.sh')
        subprocess.run(['bash', '-n', str(script)], check=True)
        for event, ref in [('pull_request', 'refs/heads/main'), ('push', 'refs/tags/v1'),
                           ('workflow_dispatch', 'refs/heads/main'), ('push', 'refs/heads/other')]:
            env = dict(os.environ, GITHUB_REPOSITORY='fixture/repo', GITHUB_SHA='a'*40,
                       GITHUB_EVENT_NAME=event, GITHUB_REF=ref)
            self.assertNotEqual(subprocess.run(['bash', str(script), str(self.out)], env=env).returncode, 0)

    def test_prerelease_stages_assets_before_publication(self):
        script = Path(__file__).with_name('publish_hap_prerelease.sh').resolve()
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            fake = base/'gh'
            fake.write_text("""#!/bin/bash
printf '%s\\n' "$*" >> "$GH_CALLS"
case "$1 $2" in
  'api '*) exit 1 ;;
  'release view') exit 1 ;;
  'release create') exit "${CREATE_EXIT:-0}" ;;
  'release edit') exit 0 ;;
esac
exit 2
""")
            fake.chmod(0o755)
            calls = base/'calls'
            env = dict(os.environ, PATH=str(base)+':'+os.environ['PATH'],
                       GH_CALLS=str(calls), GITHUB_REPOSITORY='fixture/repo',
                       GITHUB_SHA='a'*40, GITHUB_EVENT_NAME='push', GITHUB_REF='refs/heads/main')
            for create_exit in ('0', '1'):
                calls.unlink(missing_ok=True)
                result = subprocess.run(['bash', str(script), str(self.out)],
                                        env=dict(env, CREATE_EXIT=create_exit))
                recorded = calls.read_text().splitlines()
                creation = next(line for line in recorded if line.startswith('release create'))
                self.assertIn('--draft --prerelease', creation)
                for name in ASSETS:
                    self.assertIn(name, creation)
                published = any(line.startswith('release edit') for line in recorded)
                self.assertEqual(published, create_exit == '0')
                self.assertEqual(result.returncode == 0, create_exit == '0')


if __name__ == '__main__':
    unittest.main()
