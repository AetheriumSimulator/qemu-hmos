"""Parse the actual Actions graph; evaluate its event gate and inspect every sink."""
import ast
import copy
from pathlib import Path
import re
import os
import tempfile
import subprocess
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[1]


def read(path):
    # BaseLoader preserves GitHub's `on` key instead of YAML 1.1's boolean True.
    return yaml.load(path.read_text(), Loader=yaml.BaseLoader)


def condition(expression, event, ref, review='success', allowed='false', validation='success', success=True, upload='success'):
    """Evaluate the small, deliberately bounded expression grammar used here."""
    expression = expression.replace('success()', str(success))
    expression = expression.removeprefix('${{').removesuffix('}}').strip()
    values = {'github.event_name': event, 'github.ref': ref,
              'needs.publication-review.result': review,
              'needs.publication-review.outputs.allowed': allowed,
              'needs.validation.result': validation,
              'needs.validation.outputs.review': review,
              'steps.eligibility.outputs.allowed': allowed,
              'needs.validation.outputs.allowed': allowed,
              'needs.validation.outputs.upload': upload}
    for key, value in values.items():
        expression = expression.replace(key, repr(value))
    expression = re.sub(r'startsWith\(([^,]+),\s*([^\)]+)\)', r'(\1).startswith(\2)', expression)
    expression = expression.replace('&&', ' and ').replace('||', ' or ')
    expression = re.sub(r'!(?!=)', ' not ', expression).strip()
    tree = ast.parse(expression, mode='eval')
    for node in ast.walk(tree):
        if not isinstance(node, (ast.Expression, ast.BoolOp, ast.And, ast.Or, ast.UnaryOp,
                                 ast.Not, ast.Compare, ast.Eq, ast.Constant, ast.Call,
                                 ast.Attribute, ast.Load)):
            raise AssertionError(f'Unsupported gate syntax: {ast.dump(node)}')
        if isinstance(node, ast.Attribute) and node.attr != 'startswith':
            raise AssertionError('Unsupported function')
    return eval(compile(tree, '<workflow gate>', 'eval'), {'__builtins__': {}}, {})


def assert_no_transport(test, steps):
    for step in steps:
        use = step.get('uses', '').lower()
        test.assertFalse(any(x in use for x in ('upload-artifact', 'download-artifact', 'cache', 'release')), use)
        test.assertNotIn('secrets', step)
        run = step.get('run', '')
        test.assertNotRegex(run, r'(?i)gh\s+(release|api)|curl[^\n]*(--upload-file|--data-binary)|aws\s+s3')


class WorkflowGuardTests(unittest.TestCase):
    def setUp(self):
        self.workflows = {p.name: read(p) for p in (ROOT/'.github/workflows').glob('*.yml')}
        self.pipeline = self.workflows['build-complete.yml']
        self.complete = self.workflows['build-validation.yml']
        self.job = self.complete['jobs']['validation']
        self.actions = {p.parent.name: read(p) for p in (ROOT/'.github/actions').glob('*/action.yml')}

    def test_actual_event_condition_matrix(self):
        events = [('pull_request', 'refs/pull/42/merge', True),
                  ('pull_request', 'refs/pull/43/merge', True),  # fork, same unprivileged event
                  ('pull_request_target', 'refs/heads/main', False),
                  ('push', 'refs/heads/main', True), ('push', 'refs/heads/develop', False),
                  ('push', 'refs/tags/v1', False), ('push', 'refs/tags/custom', False),
                  ('workflow_dispatch', 'refs/heads/main', True),
                  ('workflow_call', 'refs/heads/main', True),
                  ('workflow_dispatch', 'refs/heads/test', True),
                  ('workflow_dispatch', 'refs/tags/v1', False)]
        for event, ref, expected in events:
            for allowed in ('false', 'true'):
                for review in ('success', 'failure', 'cancelled', 'skipped'):
                    with self.subTest(event=event, ref=ref, allowed=allowed, review=review):
                        self.assertEqual(condition(self.job['if'], event, ref, review, allowed),
                                         expected and review == 'success')
        self.assertEqual(self.pipeline['on']['push'], {'branches': ['main'], 'tags': ['*']})
        self.assertNotIn('pull_request_target', self.pipeline['on'])

    def test_single_hosted_runner_and_no_privileged_fork_path(self):
        self.assertEqual(self.job['runs-on'], 'ubuntu-24.04')
        self.assertEqual(self.complete['permissions'], {'contents': 'read'})
        self.assertEqual(self.job['needs'], 'publication-review')
        uses = [s['uses'] for s in self.job['steps'] if 'uses' in s]
        self.assertEqual(uses, ['actions/checkout@v4', './.github/actions/validate-so',
                               './.github/actions/validate-uefi', './.github/actions/validate-hap',
                               'actions/upload-artifact@v4'])
        self.assertEqual(self.job['steps'][0]['with']['persist-credentials'], 'false')
        for workflow in self.workflows.values():
            self.assertNotIn('secrets:', yaml.dump(workflow))
        self.assertNotIn('deploy-test', self.complete['jobs'])

    def test_all_upload_paths_require_publication_evidence(self):
        for workflow in self.workflows.values():
            for job in workflow['jobs'].values():
                for step in job.get('steps', []):
                    if 'upload-artifact' not in step.get('uses', ''):
                        continue
                    self.assertEqual(job['needs'], 'publication-review')
                    gate = step['if'] if job is self.job else job['if']
                    for event, ref in [('pull_request', 'refs/pull/1/merge'), ('push', 'refs/heads/main'),
                                       ('push', 'refs/tags/v1'), ('workflow_dispatch', 'refs/heads/main')]:
                        for allowed in ('false', '', 'true'):
                            for review in ('success', 'failure', 'cancelled', 'skipped'):
                                for success in (True, False):
                                    reachable = condition(job['if'], event, ref, review, allowed)
                                    upload = condition(gate, event, ref, review, allowed, success=success)
                                    if job is self.job:
                                        expected = reachable and review == 'success' and allowed == 'true' and success and event == 'push' and ref == 'refs/heads/main'
                                        self.assertEqual(reachable and upload, expected)
                                    elif allowed != 'true':
                                        self.assertFalse(upload)
                    self.assertEqual(workflow['jobs']['publication-review']['uses'],
                                     './.github/workflows/binary-publication-gate.yml')
        validation_transport_steps = [s for s in self.job['steps']
                                      if 'upload-artifact' not in s.get('uses', '')]
        assert_no_transport(self, validation_transport_steps)
        upload = next(s for s in self.job['steps'] if 'upload-artifact' in s.get('uses', ''))
        self.assertEqual(upload['with']['if-no-files-found'], 'error')
        self.assertEqual(upload['with']['retention-days'], '7')
        release = self.pipeline['jobs']['release']
        self.assertEqual(release['needs'], 'validation')
        self.assertFalse(condition(release['if'], 'push', 'refs/heads/main', allowed='false'))
        self.assertTrue(condition(release['if'], 'push', 'refs/heads/main', allowed='true'))
        self.assertFalse(condition(release['if'], 'pull_request', 'refs/pull/1/merge', allowed='true'))
        self.assertTrue(any('download-artifact' in s.get('uses', '') for s in release['steps']))
        download = next(s for s in release['steps'] if 'download-artifact' in s.get('uses', ''))
        self.assertEqual(download['with']['artifact-ids'], '${{ needs.validation.outputs.artifact_id }}')
        self.assertEqual(download['with']['merge-multiple'], 'true')
        self.assertNotIn('name', download['with'])
        for action in self.actions.values():
            assert_no_transport(self, action['runs']['steps'])
        gate = self.workflows['binary-publication-gate.yml']['jobs']['review']
        self.assertEqual(gate['outputs']['allowed'], '${{ steps.eligibility.outputs.allowed }}')
        eligibility = next(s for s in gate['steps'] if s.get('id') == 'eligibility')
        self.assertIn("echo 'allowed=false'", eligibility['run'])
        self.assertNotIn('allowed=true', eligibility['run'])

    def test_release_matrix_and_scoped_write_permissions(self):
        release = self.pipeline['jobs']['release']
        for event, ref in [('push', 'refs/heads/main'), ('push', 'refs/tags/v1'),
                           ('pull_request', 'refs/pull/1/merge'),
                           ('workflow_dispatch', 'refs/heads/main'), ('workflow_call', 'refs/heads/main')]:
            for allowed in ('true', 'false', ''):
                for review in ('success', 'failure', 'cancelled', 'skipped'):
                    for validation in ('success', 'failure', 'cancelled', 'skipped'):
                        self.assertEqual(condition(release['if'], event, ref, review, allowed, validation),
                                         event == 'push' and ref == 'refs/heads/main' and
                                         allowed == 'true' and review == validation == 'success')
        self.assertEqual(release['permissions'], {'contents': 'write'})
        self.assertNotIn('permissions', self.job)
        for upload in ('failure', 'cancelled', 'skipped', ''):
            self.assertFalse(condition(release['if'], 'push', 'refs/heads/main', allowed='true', upload=upload))
        self.assertEqual(self.pipeline['jobs']['summary']['needs'],
                         ['validation', 'release'])
        self.assertIn('publish_hap_prerelease.sh', release['steps'][-1]['run'])
        self.assertIn('release_evidence.py verify', release['steps'][-2]['run'])
        self.assertNotIn('--report-only', release['steps'][-2]['run'])
        self.assertFalse(any('release@' in step.get('uses', '') for step in release['steps']))

    def test_summary_reports_actual_outcomes_even_when_upload_fails(self):
        summary = next(s for s in self.job['steps'] if s.get('name') == 'Validation evidence')
        self.assertEqual(summary['env']['UPLOAD'], '${{ steps.upload.outcome }}')
        pipeline = self.pipeline['jobs']['summary']['steps'][0]
        self.assertEqual(pipeline['env']['UPLOAD'], '${{ needs.validation.outputs.upload }}')
        self.assertEqual(self.job['outputs']['upload'], '${{ steps.upload.outcome }}')
        for state in ('success', 'failure', 'cancelled', 'skipped', ''):
            with tempfile.TemporaryDirectory() as temp:
                path = Path(temp)/'summary'
                env = dict(os.environ, GITHUB_STEP_SUMMARY=str(path), GITHUB_SHA='abc',
                           GITHUB_EVENT_NAME='push', GITHUB_REF='refs/heads/main',
                           NATIVE=state, FIRMWARE=state, HAP=state, IDENTITY=state,
                           UPLOAD=state, EVIDENCE=state, RELEASE=state, REVIEW=state, ALLOWED='false', VALIDATION=state)
                for step in (summary, pipeline):
                    subprocess.run(['bash', '-e', '-c', step['run']], env=env, cwd=ROOT, check=True)
                text = path.read_text()
                self.assertIn(f'public artifact upload: {state or "not-run"}', text)
                self.assertIn('Device test: not executed', text)
                self.assertNotIn('HAP uploaded', text)

    def test_transport_regression_is_detected(self):
        for sink in ('actions/upload-artifact@v4', 'actions/download-artifact@v4', 'actions/cache@v4'):
            steps = [s for s in copy.deepcopy(self.job['steps']) if 'upload-artifact' not in s.get('uses', '')] + [{'uses': sink}]
            with self.assertRaises(AssertionError):
                assert_no_transport(self, steps)

    def test_legacy_entries_cannot_bypass_pipeline(self):
        for name in ('build-qemu-so.yml', 'build-uefi-firmware.yml', 'build-hap-package.yml'):
            workflow = self.workflows[name]
            self.assertEqual(workflow['jobs'], {'validation': {'uses': './.github/workflows/build-validation.yml'}})
            self.assertEqual(set(workflow['on']), {'workflow_dispatch', 'workflow_call'})

    def test_reusable_workflow_cannot_escalate_caller_permissions(self):
        self.assertEqual(set(self.complete['on']), {'workflow_call'})
        self.assertNotIn('workflow_call', self.pipeline['on'])
        for job in self.complete['jobs'].values():
            self.assertNotIn('permissions', job)
        self.assertEqual(self.pipeline['jobs']['validation'],
                         {'uses': './.github/workflows/build-validation.yml'})
        for name in ('native', 'firmware', 'hap', 'upload', 'artifact_id', 'evidence', 'allowed'):
            self.assertEqual(self.complete['on']['workflow_call']['outputs'][name]['value'],
                             '${{ jobs.validation.outputs.' + name + ' }}')

    def test_actual_shell_syntax_and_local_payload(self):
        for name, action in self.actions.items():
            self.assertEqual(action['runs']['using'], 'composite')
            for step in action['runs']['steps']:
                if 'run' in step:
                    self.assertEqual(step['shell'], 'bash')
                    subprocess.run(['bash', '-n'], input=step['run'], text=True, check=True)
        hap = '\n'.join(s.get('run', '') for s in self.actions['validate-hap']['runs']['steps'])
        self.assertIn('assembleHap', hap)
        self.assertIn('python3 tools/validate_hap.py "$hap"', hap)
        self.assertIn('so-artifacts/libs/arm64-v8a/*.so', hap)
        self.assertIn('firmware-artifacts/*.fd', hap)
        so = '\n'.join(s.get('run', '') for s in self.actions['validate-so']['runs']['steps'])
        uefi = '\n'.join(s.get('run', '') for s in self.actions['validate-uefi']['runs']['steps'])
        self.assertIn('python3 -m venv .ci-venv-so', so)
        self.assertIn('python3 -m venv .ci-venv-uefi', uefi)
        restore = next(s for s in self.job['steps'] if s['name'] == 'Restore host tools for firmware and HAP') if False else self.job['steps'][3]
        self.assertIn('PATH=$CI_HOST_PATH', restore['run'])
        self.assertIn('CC=gcc', restore['run'])

    def test_sha_and_truthful_summary_on_failure(self):
        identity = next(s for s in self.job['steps'] if s.get('id') == 'identity')
        self.assertNotIn('if', identity)  # default success() only
        self.assertIn('sha256sum', identity['run'])
        summary = next(s for s in self.job['steps'] if s.get('name') == 'Validation evidence')
        self.assertEqual(summary['if'], '${{ always() }}')
        for marker in ('git rev-parse HEAD', '$GITHUB_SHA', 'Public HAP artifact upload: %s', 'not executed'):
            self.assertIn(marker, summary['run'])
        for job in list(self.complete['jobs'].values()) + list(self.pipeline['jobs'].values()):
            for step in job.get('steps', []):
                if 'run' in step:
                    subprocess.run(['bash', '-n'], input=step['run'], text=True, check=True)


if __name__ == '__main__':
    unittest.main()
