import argparse
import json
from pathlib import Path
import plistlib
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import release
from build_provenance import source_files


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.root = self.base / 'source'
        self.root.mkdir()
        for name in release.PUBLIC_PATHS:
            path = self.root / name
            if name in ('Sources', 'Tests', 'Resources', 'script', 'website', 'docs/release-notes'):
                path.mkdir(parents=True)
            else:
                path.write_text('fixture\n')
        for name in ('script/build_and_run.sh', 'script/pack_icns.py', 'Sources/App.swift', 'Resources/icon.png'):
            (self.root / name).write_text('source\n')
        (self.root / 'PRIVATE.txt').write_text('private')
        (self.root / 'README.md').write_text(
            '## Download\nDownload Codex Weekly Reset 0.1.5\n'
            '## What’s New\n\n- **0.1.5:** Older note.\n\n'
            '## Source Of Truth\nprivate paths\n')
        (self.root / 'website/index.html').write_text('<p>Version 0.1.5 is available</p><dl class="feature-list"><div class="feature-row feature-row-primary"><dt>0.1.5</dt><dd>Older note</dd></div></dl>')
        (self.root / 'website/downloads').mkdir()
        (self.root / 'docs/release-notes/0.1.6.html').write_text('<h1>Codex Weekly Reset 0.1.6</h1><ul><li><strong>0.1.6:</strong> See resets clearly.</li></ul>')
        (self.root / 'website/appcast.xml').write_text('<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><sparkle:version>130</sparkle:version><sparkle:shortVersionString>0.1.5</sparkle:shortVersionString></item></channel></rss>')
        (self.root / 'docs/release').mkdir(exist_ok=True)
        (self.root / 'docs/release/targets.json').write_text(
            (release.ROOT / 'docs/release/targets.json').read_text())
        self.app = self.base / release.APP_NAME
        (self.app / 'Contents/Resources').mkdir(parents=True)
        info = dict(CFBundleIdentifier=release.BUNDLE_ID, CFBundleName='Codex Weekly Reset', CFBundleVersion='131', CFBundleShortVersionString='0.1.6', SUFeedURL='https://macintog.github.io/codex-weekly-reset/appcast.xml', SUPublicEDKey='test-public-key')
        (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        (self.app / 'Contents/Resources/BuildProvenance.json').write_text(json.dumps(dict(schema=1, source_commit='a'*40, source_files=source_files(self.root))))
        self.editorial = self.base / 'editorial'
        self.editorial.mkdir()
        for name in release.EDITORIAL:
            body = '0.1.6: See resets clearly.' if name == 'release' else 'Approved paragraph.\n\nSecond paragraph.'
            (self.editorial / (name + '.json')).write_text(json.dumps(dict(title='0.1.6: See resets clearly', body=body)))
        self.note_review = self.base / 'note-review'
        note_result = release.review_note(argparse.Namespace(
            notes=self.root / 'docs/release-notes/0.1.6.html', review_dir=self.note_review,
            version='0.1.6', summary='See resets clearly.'))
        release.approve_note(argparse.Namespace(
            review_dir=self.note_review, review_sha256=note_result['review_sha256']))
        self.rd = self.base / 'candidate'
        self.args = argparse.Namespace(app=self.app, release_dir=self.rd, root=self.root,
                                       config=release.ROOT / 'docs/release/targets.json', summary='See resets clearly.',
                                       editorial=self.editorial, note_review=self.note_review)
        self.submissions = 0
        self.notary_status = 'In Progress'
        self.fail_submit = False
        self.wrong_notary_hash = False
        self.notary_history = []
        self.tools = self.base / 'tools'
        self.tools.mkdir()
        for name in ('generate_keys', 'generate_appcast', 'sign_update'):
            (self.tools / name).touch()
        self.helper = self.base / 'codex'
        self.helper.touch()
        self.usage_evidence = self.base / 'live-usage.log'
        self.usage_evidence.write_text('rateLimits/read succeeded with remaining quota\n')
        self.prepare_args = argparse.Namespace(release_dir=self.rd, tools_dir=self.tools, sparkle_account='test',
                                              team='TESTTEAM', signing_identity='TEST ID', notary_profile='test')

    def fake_run(self, *args):
        args = tuple(map(str, args))
        if args[0] == '/usr/bin/ditto':
            if '-c' in args:
                Path(args[-1]).write_bytes(b'exact submitted bytes')
            else:
                shutil.copytree(args[-2], args[-1], dirs_exist_ok=True)
            return ''
        if args[0].endswith('generate_keys'):
            return 'test-public-key\n'
        if args[0:3] == ('xcrun', 'notarytool', 'submit'):
            self.submissions += 1
            if self.fail_submit:
                raise RuntimeError('upload response lost')
            return json.dumps({'id': 'submission-1'})
        if args[0:3] == ('xcrun', 'notarytool', 'info'):
            return json.dumps({'status': self.notary_status})
        if args[0:3] == ('xcrun', 'notarytool', 'log'):
            receipt = release.load(self.rd)
            return json.dumps({'sha256': 'wrong' if self.wrong_notary_hash else receipt['notary_sha256'], 'jobId': 'submission-1'})
        if args[0:3] == ('xcrun', 'notarytool', 'history'):
            return json.dumps({'history': self.notary_history})
        if args[:2] == ('xcrun', 'stapler'):
            return ''
        raise AssertionError(args)

    def fake_finalize(self, args, **kwargs):
        website = Path(args[args.index('--website-dir') + 1])
        (website / 'downloads/CodexWeeklyReset.zip').write_bytes(b'final stapled archive')
        (website / 'appcast.xml').write_text('signed final feed')

    def capture(self):
        with patch.object(release, 'run', self.fake_run):
            release.capture(self.args)

    def prepare(self):
        with patch.object(release, 'run', self.fake_run), patch.object(release, 'sign'), patch.object(release.subprocess, 'run', self.fake_finalize):
            return release.prepare(self.prepare_args)

    def make_ready(self):
        self.capture()
        self.notary_status = 'Accepted'
        self.prepare()

    def smoke_observation(self):
        extracted = self.base / 'extracted' / release.APP_NAME
        if extracted.exists():
            shutil.rmtree(extracted)
        shutil.copytree(self.rd / 'signed' / release.APP_NAME, extracted)
        return {
            'schema': 1,
            'artifact': {
                'version': '0.1.6', 'build': '131',
                'zip_sha256': release.sha(self.rd / 'publication/website/downloads/CodexWeeklyReset.zip'),
            },
            'launch': {
                'app_path': str(extracted), 'bundle_id': release.BUNDLE_ID,
                'version': '0.1.6', 'build': '131',
            },
            'codex_usage': {
                'success': True, 'helper_path': str(self.helper),
                'evidence_path': str(self.usage_evidence),
                'evidence_sha256': release.sha(self.usage_evidence),
            },
            'visual': {'result': 'pass', 'notes': 'Operator saw the current weekly usage after launch.'},
        }

    def record_smoke(self, observed=None):
        path = self.base / 'observed-smoke.json'
        path.write_text(json.dumps(observed or self.smoke_observation()))
        return release.record_smoke(argparse.Namespace(release_dir=self.rd, observed=path))

    def make_smoke_ready(self):
        self.make_ready()
        self.record_smoke()

    def reopen_as_stapled(self):
        self.make_smoke_ready()
        receipt = release.load(self.rd)
        receipt['state'] = 'stapled'
        release.write_json(self.rd / 'receipt.json', receipt)
        return receipt

    def test_note_review_is_required_before_capture_and_bound_to_customer_copy(self):
        receipt = json.loads((self.note_review / 'receipt.json').read_text())
        receipt.pop('approval')
        release.write_json(self.note_review / 'receipt.json', receipt)
        with self.assertRaisesRegex(ValueError, 'operator-approved customer note'):
            self.capture()
        release.approve_note(argparse.Namespace(
            review_dir=self.note_review, review_sha256=receipt['review_sha256']))
        self.args.summary = 'Different copy.'
        with self.assertRaisesRegex(ValueError, 'operator-approved customer note'):
            self.capture()

    def test_final_review_requires_exact_functional_smoke_evidence(self):
        self.make_ready()
        with self.assertRaisesRegex(ValueError, 'functional smoke'):
            release.review(argparse.Namespace(release_dir=self.rd))
        observed = self.smoke_observation()
        observed['artifact']['zip_sha256'] = '0' * 64
        with self.assertRaisesRegex(ValueError, 'artifact identity'):
            self.record_smoke(observed)
        observed = self.smoke_observation()
        observed['codex_usage']['success'] = False
        with self.assertRaisesRegex(ValueError, 'successful live Codex usage read'):
            self.record_smoke(observed)
        observed = self.smoke_observation()
        Path(observed['launch']['app_path'], 'Contents/Resources/foreign').write_text('different executable bundle')
        with self.assertRaisesRegex(ValueError, 'app bytes differ'):
            self.record_smoke(observed)
        observed = self.smoke_observation()
        observed['visual'] = {'result': 'fail', 'notes': 'Red error state on launch.'}
        with self.assertRaisesRegex(ValueError, 'passing operator visual result'):
            self.record_smoke(observed)
        self.record_smoke()
        self.assertTrue(release.status(self.rd)['functional_smoke'])
        release.review(argparse.Namespace(release_dir=self.rd))

    def test_changed_or_deleted_live_read_evidence_invalidates_smoke(self):
        self.make_smoke_ready()
        args = argparse.Namespace(release_dir=self.rd)
        digest = release.review(args)['review_sha256']
        release.approve(argparse.Namespace(release_dir=self.rd, review_sha256=digest))
        self.usage_evidence.write_text('edited after observation\n')
        with self.assertRaisesRegex(ValueError, 'live usage-read evidence changed'):
            release.review(args)
        self.assertFalse(release.status(self.rd)['approved'])
        self.usage_evidence.unlink()
        self.assertFalse(release.status(self.rd)['functional_smoke'])

    def test_changed_smoke_or_prepared_artifact_invalidates_final_review(self):
        self.make_smoke_ready()
        args = argparse.Namespace(release_dir=self.rd)
        digest = release.review(args)['review_sha256']
        release.approve(argparse.Namespace(release_dir=self.rd, review_sha256=digest))
        smoke = self.rd / 'functional-smoke.json'
        smoke.write_text(smoke.read_text() + '\n')
        with self.assertRaisesRegex(ValueError, 'smoke evidence changed'):
            release.plan(self.rd)
        smoke.write_text(smoke.read_text().rstrip() + '\n')
        receipt = release.load(self.rd)
        receipt['functional_smoke']['observed_sha256'] = release.sha(smoke)
        release.write_json(self.rd / 'receipt.json', receipt)
        (self.rd / 'publication/website/downloads/CodexWeeklyReset.zip').write_bytes(b'changed archive')
        with self.assertRaisesRegex(ValueError, 'Publication bytes changed'):
            release.plan(self.rd)

    def test_capture_freezes_app_public_source_and_editorial(self):
        self.capture()
        self.assertFalse((self.rd / 'public/PRIVATE.txt').exists())
        self.assertNotIn('private paths', (self.rd / 'public/README.md').read_text())
        page = (self.rd / 'public/website/index.html').read_text()
        self.assertIn('Version 0.1.6', page)
        self.assertIn('Older note', page)
        (self.root / 'Sources/App.swift').write_text('changed later')
        self.assertEqual(release.status(self.rd)['state'], 'captured')
        (self.rd / 'tested' / release.APP_NAME / 'Contents/Info.plist').write_text('tampered')
        with self.assertRaisesRegex(ValueError, 'Frozen tested app changed'):
            release.status(self.rd)

    def test_capture_rejects_wrong_source_and_released_build(self):
        (self.root / 'Sources/App.swift').write_text('other source')
        with self.assertRaisesRegex(ValueError, 'different source'):
            self.capture()
        self.assertFalse(self.rd.exists())
        with (self.app / 'Contents/Info.plist').open('rb') as f:
            info = plistlib.load(f)
        info['CFBundleVersion'] = '130'
        (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        with self.assertRaisesRegex(ValueError, 'already released'):
            self.capture()

    def test_resume_never_rebuilds_or_reuploads_and_ready_is_noop(self):
        self.capture()
        self.assertEqual(self.prepare()['state'], 'submitted')
        self.notary_status = 'Accepted'
        self.assertEqual(self.prepare()['state'], 'ready')
        self.assertEqual(self.submissions, 1)
        with patch.object(release, 'run', side_effect=AssertionError('external work repeated')):
            self.assertEqual(release.prepare(self.prepare_args)['state'], 'ready')
        self.assertEqual((self.rd / 'public/website/appcast.xml').read_text(), (self.root / 'website/appcast.xml').read_text())

    def test_uncertain_upload_stops_and_unrelated_acceptance_is_rejected(self):
        self.capture()
        self.fail_submit = True
        with self.assertRaisesRegex(RuntimeError, 'lost'):
            self.prepare()
        with self.assertRaisesRegex(ValueError, 'uncertain'):
            self.prepare()
        self.assertEqual(self.submissions, 1)
        release.attach_notary(argparse.Namespace(release_dir=self.rd, submission_id='submission-1'))
        self.notary_status = 'Accepted'
        self.wrong_notary_hash = True
        with self.assertRaisesRegex(ValueError, 'exact submitted archive'):
            self.prepare()

    def test_review_required_and_locks_build_targets_and_all_text(self):
        self.make_smoke_ready()
        with self.assertRaisesRegex(ValueError, 'Review'):
            release.plan(self.rd)
        args = argparse.Namespace(release_dir=self.rd)
        digest = release.review(args)['review_sha256']
        release.approve(argparse.Namespace(release_dir=self.rd, review_sha256=digest))
        self.assertEqual(release.plan(self.rd)['approval_sha256'], digest)
        observed = {name: json.loads((self.editorial / (name + '.json')).read_text()) for name in release.EDITORIAL}
        observed['announcement'] = {'status': 'disabled'}
        observed['commit'] = {'titles': ['0.1.6: See resets clearly']}
        path = self.base / 'observed.json'
        path.write_text(json.dumps(observed))
        release.verify_text(argparse.Namespace(release_dir=self.rd, observed=path))
        observed['pages-pr']['body'] = 'regenerated body'
        path.write_text(json.dumps(observed))
        with self.assertRaisesRegex(ValueError, 'Published pages-pr differs'):
            release.verify_text(argparse.Namespace(release_dir=self.rd, observed=path))
        receipt = release.load(self.rd)
        receipt['targets']['discussion']['enabled'] = True
        release.write_json(self.rd / 'receipt.json', receipt)
        with self.assertRaisesRegex(ValueError, 'Review'):
            release.plan(self.rd)

    def test_review_tamper_blocks_approval_and_invalidates_an_existing_approval(self):
        self.make_smoke_ready()
        args = argparse.Namespace(release_dir=self.rd)
        digest = release.review(args)['review_sha256']
        review_path = self.rd / 'REVIEW.md'
        review_path.write_text(review_path.read_text() + '\nUnreviewed instruction.\n')
        with self.assertRaisesRegex(ValueError, 'reviewed packet changed'):
            release.approve(argparse.Namespace(release_dir=self.rd, review_sha256=digest))
        with self.assertRaisesRegex(ValueError, 'Review'):
            release.plan(self.rd)

        digest = release.review(args)['review_sha256']
        release.approve(argparse.Namespace(release_dir=self.rd, review_sha256=digest))
        review_path.write_text(review_path.read_text().replace('Approved paragraph.', 'Changed paragraph.', 1))
        with self.assertRaisesRegex(ValueError, 'Review'):
            release.plan(self.rd)

    def test_changed_publication_and_editorial_are_rejected(self):
        self.make_ready()
        (self.rd / 'publication/website/index.html').write_text('changed')
        with self.assertRaisesRegex(ValueError, 'Publication bytes changed'):
            release.ready(self.rd)
        (self.rd / 'editorial/release.json').write_text('{}')
        with self.assertRaisesRegex(ValueError, 'Reviewed text changed'):
            release.status(self.rd)

    def test_materialized_copy_checks_all_files_and_extras(self):
        self.make_ready()
        copy = self.base / 'public-checkout'
        shutil.copytree(self.rd / 'publication', copy)
        (copy / '.git').write_text('gitdir: /outside/repository')
        args = argparse.Namespace(release_dir=self.rd, checkout=copy, pages=False)
        release.verify_copy(args)
        (copy / 'private-handoff.md').write_text('leaked')
        with self.assertRaisesRegex(ValueError, 'private-handoff'):
            release.verify_copy(args)

    def test_editorial_rejects_literal_escapes_and_wrong_headlines(self):
        path = self.editorial / 'pages-pr.json'
        doc = json.loads(path.read_text())
        doc['body'] = 'first\\n\\nsecond'
        path.write_text(json.dumps(doc))
        with self.assertRaisesRegex(ValueError, 'literal newline'):
            release.validate_editorial(self.editorial, '0.1.6', 'See resets clearly.')

    def test_capture_rejects_release_directory_inside_public_source(self):
        self.args.release_dir = self.root / 'script/release-evidence'
        with self.assertRaisesRegex(ValueError, 'outside public inputs'):
            self.capture()
        self.assertFalse(self.args.release_dir.exists())

    def test_capture_rejects_wrong_or_nonminimal_provenance_schema(self):
        provenance_path = self.app / 'Contents/Resources/BuildProvenance.json'
        valid = json.loads(provenance_path.read_text())
        for changed in (
            dict(valid, schema=2),
            dict(valid, private_path='/Users/operator/private', remote='ssh://private/repository'),
        ):
            with self.subTest(fields=sorted(changed)):
                provenance_path.write_text(json.dumps(changed))
                with self.assertRaisesRegex(ValueError, 'unsafe build provenance'):
                    self.capture()
                self.assertFalse(self.rd.exists())
        provenance_path.write_text(json.dumps(valid))

    def test_capture_rejects_public_source_mutation_during_copy(self):
        original = release.copy_public

        def copy_then_change(root, destination):
            original(root, destination)
            (root / 'Tests/changed-during-copy.txt').write_text('late source change')

        with patch.object(release, 'copy_public', copy_then_change):
            with self.assertRaisesRegex(ValueError, 'Public source changed during capture'):
                self.capture()
        self.assertTrue((self.rd / 'CAPTURE_FAILED').is_file())

    def test_prepare_rejects_changed_sparkle_tools_on_resume(self):
        self.capture()
        self.assertEqual(self.prepare()['state'], 'submitted')
        (self.tools / 'sign_update').write_text('replacement tool')
        with self.assertRaisesRegex(ValueError, 'Sparkle release tools changed'):
            self.prepare()
        self.assertEqual(self.submissions, 1)

    def test_revise_text_preserves_notarization_and_signed_app_without_reupload(self):
        self.make_smoke_ready()
        review_args = argparse.Namespace(release_dir=self.rd)
        digest = release.review(review_args)['review_sha256']
        release.approve(argparse.Namespace(release_dir=self.rd, review_sha256=digest))
        before = release.load(self.rd)
        submission = before['notary_submission']
        signed_files = release.files(self.rd / 'signed' / release.APP_NAME)

        summary = 'See the next reset at a glance.'
        revised = self.base / 'revised-editorial'
        revised.mkdir()
        for name in release.EDITORIAL:
            body = f'0.1.6: {summary}' if name == 'release' else 'Revised approved paragraph.\n\nSecond paragraph.'
            (revised / (name + '.json')).write_text(json.dumps({
                'title': '0.1.6: See the next reset at a glance',
                'body': body,
            }))
        notes = self.base / 'revised-notes.html'
        notes.write_text(f'<h1>Codex Weekly Reset 0.1.6</h1><ul><li><strong>0.1.6:</strong> {summary}</li></ul>')
        result = release.revise_text(argparse.Namespace(
            release_dir=self.rd,
            editorial=revised,
            notes=notes,
            summary=summary,
        ))
        self.assertEqual(result['state'], 'stapled')
        self.assertFalse(result['approved'])
        revised_receipt = release.load(self.rd)
        self.assertEqual(revised_receipt['notary_submission'], submission)
        self.assertEqual(release.files(self.rd / 'signed' / release.APP_NAME), signed_files)
        self.assertEqual(self.submissions, 1)

        self.assertIn(summary, (self.rd / 'public/README.md').read_text())
        website = release.visible_text((self.rd / 'public/website/index.html').read_text())
        self.assertIn(summary, website)
        self.assertNotIn('See resets clearly.', website)
        self.assertEqual(self.prepare()['state'], 'ready')
        self.assertEqual(self.submissions, 1)
        with self.assertRaisesRegex(ValueError, 'Review'):
            release.plan(self.rd)

    def test_refresh_source_replaces_only_release_tooling_and_preserves_notarization(self):
        before = self.reopen_as_stapled()
        (self.root / 'script/release_feed.py').write_text('corrected feed tooling\n')
        root_page = (self.root / 'website/index.html').read_bytes()
        result = release.refresh_source(argparse.Namespace(
            release_dir=self.rd, root=self.root, resume=False))

        self.assertEqual(result['state'], 'stapled')
        after = release.load(self.rd)
        for key in ('notary_submission', 'notary_archive', 'notary_sha256', 'tool_hashes',
                    'signed_files', 'stapled_files', 'tested_files', 'editorial_files',
                    'targets', 'summary', 'note_review_sha256'):
            self.assertEqual(after[key], before[key], key)
        self.assertEqual(self.submissions, 1)
        self.assertEqual((self.root / 'website/index.html').read_bytes(), root_page)
        self.assertIn('Version 0.1.6', (self.rd / 'public/website/index.html').read_text())
        self.assertEqual((self.rd / 'public/script/release_feed.py').read_text(),
                         'corrected feed tooling\n')
        self.assertFalse((self.rd / 'prepared-website').exists())
        self.assertFalse((self.rd / 'publication').exists())
        self.assertFalse((self.rd / 'functional-smoke.json').exists())
        self.assertNotIn('prepared_files', after)
        self.assertNotIn('publication_files', after)
        self.assertNotIn('functional_smoke', after)
        self.assertEqual(after['source_refresh']['changed_paths'], ['script/release_feed.py'])
        self.assertRegex(after['source_refresh']['prior_public_manifest_sha256'], r'^[0-9a-f]{64}$')
        self.assertRegex(after['source_refresh']['new_public_manifest_sha256'], r'^[0-9a-f]{64}$')

        self.prepare()
        self.assertEqual(self.submissions, 1, 'Source refresh must not submit the stapled app again')

    def test_refresh_source_rejects_runtime_source_changes(self):
        self.reopen_as_stapled()
        (self.root / 'Sources/App.swift').write_text('changed runtime\n')
        with self.assertRaisesRegex(ValueError, 'runtime source'):
            release.refresh_source(argparse.Namespace(
                release_dir=self.rd, root=self.root, resume=False))

    def test_refresh_source_rejects_release_note_changes(self):
        self.reopen_as_stapled()
        (self.root / 'docs/release-notes/0.1.6.html').write_text('changed note\n')
        with self.assertRaisesRegex(ValueError, 'release note'):
            release.refresh_source(argparse.Namespace(
                release_dir=self.rd, root=self.root, resume=False))

    def test_refresh_source_rejects_publication_target_changes(self):
        self.reopen_as_stapled()
        targets = json.loads((self.root / 'docs/release/targets.json').read_text())
        targets['discussion']['reason'] = 'changed after capture'
        (self.root / 'docs/release/targets.json').write_text(json.dumps(targets))
        with self.assertRaisesRegex(ValueError, 'Publication targets'):
            release.refresh_source(argparse.Namespace(
                release_dir=self.rd, root=self.root, resume=False))

    def test_refresh_source_rejects_non_tooling_public_changes(self):
        self.reopen_as_stapled()
        page = self.root / 'website/index.html'
        page.write_text(page.read_text().replace('Older note', 'Changed older note'))
        with self.assertRaisesRegex(ValueError, 'release tooling'):
            release.refresh_source(argparse.Namespace(
                release_dir=self.rd, root=self.root, resume=False))

    def test_refresh_source_imports_optional_policy_from_ready_receipt(self):
        self.make_ready()
        before = release.load(self.rd)
        policy = b'# Security\n\nReport vulnerabilities privately.\n'
        (self.root / 'SECURITY.md').write_bytes(policy)

        result = release.refresh_source(argparse.Namespace(
            release_dir=self.rd, root=self.root, resume=False))

        self.assertEqual(result['state'], 'stapled')
        after = release.load(self.rd)
        self.assertEqual((self.rd / 'public/SECURITY.md').read_bytes(), policy)
        self.assertEqual(after['source_refresh']['changed_paths'], ['SECURITY.md'])
        for key in ('notary_submission', 'notary_archive', 'notary_sha256', 'tool_hashes',
                    'signed_files', 'stapled_files'):
            self.assertEqual(after[key], before[key], key)
        self.assertFalse((self.rd / 'publication').exists())
        self.assertEqual(self.submissions, 1)

    def test_refresh_source_validates_ready_publication_before_replacement(self):
        self.make_ready()
        (self.rd / 'publication/README.md').write_text('changed after preparation\n')
        with self.assertRaisesRegex(ValueError, 'Publication bytes changed'):
            release.refresh_source(argparse.Namespace(
                release_dir=self.rd, root=self.root, resume=False))

    def test_refresh_source_rejects_approval_and_nonstapled_receipts(self):
        self.reopen_as_stapled()
        receipt = release.load(self.rd)
        receipt['approval'] = {'manifest': 'approved'}
        release.write_json(self.rd / 'receipt.json', receipt)
        with self.assertRaisesRegex(ValueError, 'approval'):
            release.refresh_source(argparse.Namespace(
                release_dir=self.rd, root=self.root, resume=False))

        receipt.pop('approval')
        receipt['state'] = 'finalized'
        release.write_json(self.rd / 'receipt.json', receipt)
        with self.assertRaisesRegex(ValueError, 'stapled or ready'):
            release.refresh_source(argparse.Namespace(
                release_dir=self.rd, root=self.root, resume=False))

    def test_interrupted_source_refresh_resumes_from_revision_journal(self):
        before = self.reopen_as_stapled()
        (self.root / 'script/release_feed.py').write_text('corrected feed tooling\n')
        args = argparse.Namespace(release_dir=self.rd, root=self.root, resume=False)
        with patch.object(release, 'finish_revision', side_effect=RuntimeError('interrupted')):
            with self.assertRaisesRegex(RuntimeError, 'interrupted'):
                release.refresh_source(args)
        self.assertTrue((self.rd / 'pending-revision.json').exists())
        shutil.rmtree(self.rd / 'public')

        result = release.refresh_source(argparse.Namespace(
            release_dir=self.rd, root=None, resume=True))
        self.assertEqual(result['state'], 'stapled')
        self.assertFalse((self.rd / 'pending-revision.json').exists())
        self.assertEqual(release.load(self.rd)['notary_submission'], before['notary_submission'])
        self.assertEqual(self.submissions, 1)

    def test_retry_upload_requires_confirmation_and_reconciles_archive_history(self):
        self.capture()
        self.fail_submit = True
        with self.assertRaisesRegex(RuntimeError, 'lost'):
            self.prepare()
        retry_args = argparse.Namespace(
            release_dir=self.rd,
            notary_profile='test',
            confirmed_not_submitted=False,
        )
        with self.assertRaisesRegex(ValueError, 'operator confirmation'):
            release.retry_upload(retry_args)

        receipt = release.load(self.rd)
        archive = self.rd / receipt['notary_archive']
        archive_bytes = archive.read_bytes()
        retry_args.confirmed_not_submitted = True
        self.notary_history = [{'id': 'existing-submission', 'name': receipt['notary_archive']}]
        with self.assertRaisesRegex(ValueError, 'matching archive name'):
            with patch.object(release, 'run', self.fake_run):
                release.retry_upload(retry_args)
        self.assertEqual(release.load(self.rd)['state'], 'submitting')

        self.notary_history = [{'id': 'other-submission', 'name': 'AnotherApp.zip'}]
        with patch.object(release, 'run', self.fake_run):
            result = release.retry_upload(retry_args)
        self.assertEqual(result['state'], 'signed')
        self.assertEqual(archive.read_bytes(), archive_bytes)


    def test_interrupted_editorial_revision_resumes_from_journal(self):
        self.make_ready()
        args = argparse.Namespace(release_dir=self.rd, editorial=self.editorial,
                                  notes=self.root / 'docs/release-notes/0.1.6.html', summary='See resets clearly.')
        with patch.object(release, 'finish_revision', side_effect=RuntimeError('interrupted')):
            with self.assertRaisesRegex(RuntimeError, 'interrupted'):
                release.revise_text(args)
        self.assertTrue((self.rd / 'pending-revision.json').exists())
        with self.assertRaisesRegex(ValueError, 'revise-text --resume'):
            release.status(self.rd)
        shutil.rmtree(self.rd / 'public')  # Model an interruption during directory replacement.
        result = release.revise_text(argparse.Namespace(release_dir=self.rd, resume=True))
        self.assertEqual(result['state'], 'stapled')
        self.assertFalse((self.rd / 'pending-revision.json').exists())
        self.assertEqual(self.submissions, 1)

    def test_headline_check_reads_every_changed_path(self):
        self.make_smoke_ready()
        args = argparse.Namespace(release_dir=self.rd)
        digest = release.review(args)['review_sha256']
        release.approve(argparse.Namespace(release_dir=self.rd, review_sha256=digest))
        check = argparse.Namespace(release_dir=self.rd, checkout=self.root, base='a'*40)
        def git(*command):
            if 'diff' in command:
                return 'Sources/App.swift\0website/index.html\0'
            if 'log' in command:
                return '0.1.6: See resets clearly\n' if command[-1] == 'Sources/App.swift' else 'Late wording tweak\n'
            raise AssertionError(command)
        with patch.object(release, 'run', git):
            with self.assertRaisesRegex(ValueError, 'website/index.html'):
                release.verify_headlines(check)


    def test_optional_security_policy_absence_does_not_block_export(self):
        (self.root / 'SECURITY.md').unlink()
        self.capture()
        self.assertFalse((self.rd / 'public/SECURITY.md').exists())
        release.status(self.rd)


if __name__ == '__main__':
    unittest.main()
