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


if __name__ == '__main__':
    unittest.main()
