# SPDX-License-Identifier: GPL-3.0-or-later
"""Offline checks: exact build targeting, authenticated tokens and safe updates."""
import base64
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import time
import unittest

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, utils

spec = importlib.util.spec_from_file_location('testflight',
    Path(__file__).resolve().parents[1]/'scripts/update-tablet-testflight.py')
testflight = importlib.util.module_from_spec(spec)
spec.loader.exec_module(testflight)


class FakeAPI:
    def __init__(self):
        self.build = {'type': 'builds', 'id': 'build-fixture', 'attributes': {
            'version': '3', 'expired': False, 'processingState': 'VALID',
            'usesNonExemptEncryption': None}}
        self.notes = []
        self.writes = []
        self.queries = []
        self.platform = 'VISION_OS'
        self.persist_compliance = True

    def collection(self, path, query=None):
        self.queries.append((path, query))
        if path == '/v1/apps':
            return [{'id': 'app-fixture', 'attributes': {'bundleId': 'example.test'}}]
        if path == '/v1/builds':
            return [copy.deepcopy(self.build)]
        if path == '/v1/appEncryptionDeclarations':
            return []
        return copy.deepcopy(self.notes)

    def request(self, method, path, query=None, body=None):
        if method == 'GET':
            if path.endswith('/preReleaseVersion'):
                return {'data': {'attributes': {'version': '0.1.0', 'platform': self.platform}}}
            return {'data': copy.deepcopy(self.build)}
        self.writes.append((method, path, body))
        data = copy.deepcopy(body['data'])
        if path == '/v1/betaBuildLocalizations':
            data['id'] = 'notes-fixture'
            self.notes = [data]
        elif path.startswith('/v1/betaBuildLocalizations/'):
            self.notes[0]['attributes'].update(data['attributes'])
        elif self.persist_compliance:
            self.build['attributes'].update(data['attributes'])
        return {'data': data}


class MetadataTests(unittest.TestCase):
    def setUp(self):
        self.api = FakeAPI()
        self.config = {'bundle_id': 'example.test', 'platform': 'VISION_OS',
                       'compliance': {'uses_non_exempt_encryption': False}}

    def test_exact_build_selection_and_platform_recheck(self):
        testflight.find_build(self.api, self.config, '0.1.0', '3', 0)
        query = self.api.queries[1][1]
        self.assertEqual(query['filter[app]'], 'app-fixture')
        self.assertEqual(query['filter[version]'], '3')
        self.assertEqual(query['filter[preReleaseVersion.version]'], '0.1.0')
        self.assertEqual(query['filter[preReleaseVersion.platform]'], 'VISION_OS')
        self.api.platform = 'IOS'
        with self.assertRaises(ValueError):
            testflight.find_build(self.api, self.config, '0.1.0', '3', 0)
        self.assertFalse(self.api.writes)

    def test_unprocessed_build_is_not_updated(self):
        self.api.build['attributes']['processingState'] = 'PROCESSING'
        with self.assertRaises(TimeoutError):
            testflight.find_build(self.api, self.config, '0.1.0', '3', 0)
        self.assertFalse(self.api.writes)

    def test_absent_or_incomplete_baseline_prevents_writes(self):
        for baseline in (None, {'uses_non_exempt_encryption': 'false'},
                         {'uses_non_exempt_encryption': True}):
            self.config['compliance'] = baseline
            with self.assertRaises(ValueError):
                testflight.update_metadata(self.api, self.config, 'app-fixture', self.api.build, 'Test', 'en-US')
            self.assertFalse(self.api.writes)

    def test_declaration_from_another_app_prevents_writes(self):
        self.config['compliance'] = {'uses_non_exempt_encryption': True, 'declaration_id': 'other-app'}
        with self.assertRaises(ValueError):
            testflight.update_metadata(self.api, self.config, 'app-fixture', self.api.build, 'Test', 'en-US')
        self.assertFalse(self.api.writes)

    def test_create_then_idempotent_repeat_then_edit_notes(self):
        testflight.update_metadata(self.api, self.config, 'app-fixture', self.api.build, 'Test one', 'en-US')
        self.assertEqual([x[:2] for x in self.api.writes], [
            ('POST', '/v1/betaBuildLocalizations'), ('PATCH', '/v1/builds/build-fixture')])
        self.api.writes.clear()
        testflight.update_metadata(self.api, self.config, 'app-fixture', self.api.build, 'Test one', 'en-US')
        self.assertFalse(self.api.writes)
        testflight.update_metadata(self.api, self.config, 'app-fixture', self.api.build, 'Test two', 'en-US')
        self.assertEqual(self.api.writes[0][:2], ('PATCH', '/v1/betaBuildLocalizations/notes-fixture'))
        self.assertEqual(len(self.api.writes), 1)

    def test_readback_catches_unsaved_compliance(self):
        self.api.persist_compliance = False
        with self.assertRaises(RuntimeError):
            testflight.update_metadata(self.api, self.config, 'app-fixture', self.api.build, 'Test', 'en-US')

    def test_existing_conflicting_compliance_prevents_writes(self):
        self.api.build['attributes']['usesNonExemptEncryption'] = True
        with self.assertRaises(ValueError):
            testflight.update_metadata(self.api, self.config, 'app-fixture', self.api.build, 'Test', 'en-US')
        self.assertFalse(self.api.writes)

    def test_es256_token_signature_and_lifetime(self):
        key = ec.generate_private_key(ec.SECP256R1())
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)/'fixture.p8'
            path.touch(mode=0o600)
            path.write_bytes(key.private_bytes(serialization.Encoding.PEM,
                serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
            client = testflight.APIClient({'key_id': 'test-key', 'issuer_id': 'test-issuer',
                                          'private_key_path': str(path)})
            header, payload, signature = client.token().split('.')
            decode = lambda value: base64.urlsafe_b64decode(value + '=' * (-len(value) % 4))
            raw = decode(signature)
            self.assertEqual(len(raw), 64)
            key.public_key().verify(utils.encode_dss_signature(int.from_bytes(raw[:32], 'big'),
                int.from_bytes(raw[32:], 'big')), (header+'.'+payload).encode(), ec.ECDSA(hashes.SHA256()))
            claims = json.loads(decode(payload))
            self.assertEqual(claims['aud'], 'appstoreconnect-v1')
            self.assertEqual(claims['exp']-claims['iat'], 300)
            self.assertLessEqual(abs(claims['iat']-time.time()), 2)
            path.chmod(0o644)
            with self.assertRaises(ValueError):
                testflight.private_file(path)


class ExternalAPI:
    def __init__(self):
        self.groups = [{'id': name, 'attributes': {'isInternalGroup': internal}}
                       for name, internal in [('internal', True), ('external-a', False), ('external-b', False)]]
        self.assignments = {item['id']: [] for item in self.groups}
        self.detail = {'id': 'detail', 'attributes': {
            'externalBuildState': 'READY_FOR_BETA_SUBMISSION', 'autoNotifyEnabled': False}}
        self.contact = {key: 'fixture' for key in
                        ('contactFirstName', 'contactLastName', 'contactPhone', 'contactEmail')}
        self.contact['demoAccountRequired'] = False
        self.localizations = [{'attributes': {'description': 'Fixture app', 'feedbackEmail': 'test@example.invalid'}}]
        self.reviews = []
        self.writes = []
        self.persist_assignment = True
        self.persist_review = True

    def collection(self, path, query=None):
        if path == '/v1/apps/app-fixture/betaGroups':
            result = self.groups
        elif path == '/v1/apps/app-fixture/betaAppLocalizations':
            result = self.localizations
        elif path == '/v1/betaAppReviewSubmissions':
            assert query['filter[build]'] == 'build-fixture'
            result = self.reviews
        elif path.startswith('/v1/betaGroups/') and path.endswith('/relationships/builds'):
            result = self.assignments[path.split('/')[3]]
        else:
            raise AssertionError(path)
        return copy.deepcopy(result)

    def request(self, method, path, query=None, body=None):
        if method == 'GET':
            if path == '/v1/builds/build-fixture/buildBetaDetail':
                return {'data': copy.deepcopy(self.detail)}
            if path == '/v1/apps/app-fixture/betaAppReviewDetail':
                return {'data': {'attributes': copy.deepcopy(self.contact)}}
            raise AssertionError(path)
        self.writes.append((method, path, copy.deepcopy(body)))
        if path == '/v1/buildBetaDetails/detail':
            self.detail['attributes'].update(body['data']['attributes'])
        elif path.startswith('/v1/betaGroups/'):
            if self.persist_assignment:
                self.assignments[path.split('/')[3]].extend(body['data'])
        elif path == '/v1/betaAppReviewSubmissions':
            assert body['data']['relationships']['build']['data']['id'] == 'build-fixture'
            if self.persist_review:
                self.reviews = [{'id': 'review', 'attributes': {'betaReviewState': 'WAITING_FOR_REVIEW'}}]
                self.detail['attributes']['externalBuildState'] = 'WAITING_FOR_BETA_REVIEW'
        elif path == '/v1/buildBetaNotifications':
            self.detail['attributes']['externalBuildState'] = 'IN_BETA_TESTING'
        else:
            raise AssertionError(path)
        return {}


class ExternalTests(unittest.TestCase):
    def setUp(self):
        self.api = ExternalAPI()

    def submit(self):
        testflight.submit_external(self.api, 'app-fixture', 'build-fixture')

    def test_every_external_group_and_exact_build_then_idempotent_retry(self):
        self.submit()
        self.assertFalse(self.api.assignments['internal'])
        for group in ('external-a', 'external-b'):
            self.assertEqual(self.api.assignments[group], [{'type': 'builds', 'id': 'build-fixture'}])
        self.assertEqual(len(self.api.reviews), 1)
        self.assertTrue(self.api.detail['attributes']['autoNotifyEnabled'])
        self.api.writes.clear()
        self.submit()
        self.assertFalse(self.api.writes)

    def test_no_groups_or_missing_review_contact_prevents_publication(self):
        for change in (lambda a: setattr(a, 'groups', []),
                       lambda a: a.contact.pop('contactPhone'),
                       lambda a: a.contact.pop('demoAccountRequired'),
                       lambda a: a.contact.update(demoAccountRequired=True),
                       lambda a: setattr(a, 'localizations', [])):
            self.api = ExternalAPI()
            change(self.api)
            with self.assertRaises(ValueError):
                self.submit()
            self.assertFalse(self.api.writes)

    def test_rejected_review_is_not_resubmitted(self):
        self.api.reviews = [{'attributes': {'betaReviewState': 'REJECTED'}}]
        with self.assertRaises(ValueError):
            self.submit()
        self.assertFalse(self.api.writes)

    def test_lost_group_assignment_does_not_submit_review(self):
        self.api.persist_assignment = False
        with self.assertRaises(RuntimeError):
            self.submit()
        self.assertFalse(self.api.reviews)

    def test_lost_submission_is_reported_as_incomplete(self):
        self.api.persist_review = False
        with self.assertRaises(RuntimeError):
            self.submit()

    def test_approved_build_is_released_without_another_review(self):
        self.api.reviews = [{'attributes': {'betaReviewState': 'APPROVED'}}]
        self.api.detail['attributes']['externalBuildState'] = 'READY_FOR_BETA_TESTING'
        self.submit()
        self.assertEqual(self.api.detail['attributes']['externalBuildState'], 'IN_BETA_TESTING')
        self.assertFalse(any(path == '/v1/betaAppReviewSubmissions' for _, path, _ in self.api.writes))
        self.api.writes.clear()
        self.submit()
        self.assertFalse(self.api.writes)


if __name__ == '__main__':
    unittest.main()
