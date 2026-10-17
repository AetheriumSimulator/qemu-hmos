"""Explicit test-distribution disclosures, not legal or source-completeness approval."""
import copy
import hashlib
import zipfile

POLICY = 'test-disclosure-v1'
SDK_SHA = '1dcefa4741dc289277560b2802040e0c45b433898d8db453d711d5376e0478f1'
RUNTIME_MEMBER = 'command-line-tools/sdk/default/openharmony/native/llvm/lib/aarch64-linux-ohos/libc++_shared.so'
RUNTIME_PATH = 'libs/arm64-v8a/libc++_shared.so'
RUNTIME_SHA = '899545c5e6c43134f20d611dc5b72f329f8e143c75a7cb3ec69f66df77ddc6b6'
NOTICE_FILES = {
    'command-line-tools/LICENSE.txt': 'ce19d08d8bbdad17a2866511e3f9b947915b96b0d57ef1acb7989859feb60669',
    'command-line-tools/sdk/default/openharmony/native/oh-uni-package.json': '3a7be9dc7caa0b022fd877e6221e803c346bf412b8dea567834eb75475b40120',
    'command-line-tools/sdk/default/openharmony/native/llvm/NOTICE': '0de99f6e07e1f7c2438ab21c20a5b05635ba7b206d843be32b75b2029c288f31',
    'command-line-tools/sdk/default/openharmony/native/NOTICE.txt': '6179b3b8bd4017b4de8f486a0bdfc4c189a40a6850bb1efcc19fe707ed86c178',
}
DISCLOSURE = {
    'policy': POLICY,
    'reviewStatus': 'not-approved',
    'sourceCompleteness': 'not-certified',
    'fullArchiveRebuild': 'not-executed',
    'deviceTest': 'not-executed',
    'unresolved': {
        'component-licenses': 'Actual native link includes GPLv2-only VFIO code and static Apache-2.0 OpenSSL. Applicable combined terms/exceptions are unresolved; no compatibility or infringement determination.',
        'source-completeness': 'Collected source, recipes and explicit omissions accompany the HAP. Targeted extracted-input replay passed in prior CI; a complete clean archive-to-HAP rebuild and source closure assessment remain outstanding.',
        'sdk-runtime-terms': 'Packaged libc++ matches OpenHarmony native 5.1.0.125/API18. Original bundled notices/metadata are included, but exact downstream runtime source/patch/build mapping is unresolved. The Exhibit C URL returned HTTP 403 during audit; it has not been bypassed.',
    },
}


def disclosure():
    return copy.deepcopy(DISCLOSURE)


def notice_path(member):
    return 'project/compliance/sdk-runtime/' + member


def runtime_provenance():
    return {'archive': 'commandline-tools.zip', 'archiveSha256': SDK_SHA,
            'runtimeMember': RUNTIME_MEMBER, 'hapMember': RUNTIME_PATH,
            'runtimeSha256': RUNTIME_SHA,
            'noticeFiles': [{'archiveMember': k, 'sourceMember': notice_path(k), 'sha256': v}
                            for k, v in NOTICE_FILES.items()]}


def collect_notices(sdk_zip, files):
    """Only extract audited text records, never SDK binaries or an access workaround."""
    with sdk_zip.open('rb') as stream:
        if hashlib.file_digest(stream, 'sha256').hexdigest() != SDK_SHA:
            raise ValueError('SDK archive changed; refresh runtime/notice provenance')
    with zipfile.ZipFile(sdk_zip) as archive:
        for member, expected in NOTICE_FILES.items():
            data = archive.read(member)
            if hashlib.sha256(data).hexdigest() != expected:
                raise ValueError('SDK notice/metadata identity mismatch: ' + member)
            data.decode('utf-8')
            files[notice_path(member)] = ('file', data, 0o644)
        if hashlib.sha256(archive.read(RUNTIME_MEMBER)).hexdigest() != RUNTIME_SHA:
            raise ValueError('SDK runtime identity mismatch')


def verify_disclosure(evidence, members):
    errors = []
    if evidence.get('sdkRuntimeEvidence') != runtime_provenance():
        errors.append('SDK runtime/notice provenance manifest mismatch')
    if evidence.get('testDistribution') != DISCLOSURE:
        errors.append('Missing/changed test-distribution disclosures or unsupported approval claim')
    if evidence.get('deviceTest') != 'not-executed':
        errors.append('Unsupported device-test claim')
    payload = {p['path']: p['sha256'] for p in evidence.get('payload', [])}
    if payload.get(RUNTIME_PATH) != RUNTIME_SHA:
        errors.append('Packaged SDK runtime does not match audited notice provenance')
    if not any(s.get('path') == 'commandline-tools.zip' and s.get('sha256') == SDK_SHA
               for s in evidence.get('sdkInputs', [])):
        errors.append('SDK archive does not match audited notice provenance')
    for member, expected in NOTICE_FILES.items():
        if members.get(notice_path(member)) != expected:
            errors.append('Missing/hash-mismatched SDK notice or metadata: ' + member)
    return errors
