#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Complete notes/compliance for one exact TestFlight build using private config.

Requires Python's cryptography package. Keys and JWTs are never printed or saved.
Use --inspect first when establishing a confirmed compliance baseline.
"""
import argparse
import base64
import json
import os
from pathlib import Path
import stat
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, utils

API = 'https://api.appstoreconnect.apple.com'


def private_file(path):
    path = Path(path).expanduser()
    info = path.stat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ValueError('API configuration and key must be owned private files (0600).')
    return path.read_bytes()


def encode(value):
    return base64.urlsafe_b64encode(value).rstrip(b'=')


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        raise ValueError('Refusing to redirect an authenticated API request.')


class APIClient:
    def __init__(self, config):
        self.key_id = config['key_id']
        self.issuer = config['issuer_id']
        if not self.key_id or not self.issuer:
            raise ValueError('App Store Connect Key ID and Issuer ID are required.')
        self.key = serialization.load_pem_private_key(private_file(config['private_key_path']), None)
        if not isinstance(self.key, ec.EllipticCurvePrivateKey) or self.key.curve.name != 'secp256r1':
            raise ValueError('Expected an App Store Connect P-256 private key.')
        self.http = urllib.request.build_opener(NoRedirect())

    def token(self):
        now = int(time.time())
        header = {'alg': 'ES256', 'kid': self.key_id, 'typ': 'JWT'}
        claims = {'iss': self.issuer, 'iat': now, 'exp': now + 300, 'aud': 'appstoreconnect-v1'}
        message = b'.'.join(encode(json.dumps(x, separators=(',', ':')).encode()) for x in (header, claims))
        r, s = utils.decode_dss_signature(self.key.sign(message, ec.ECDSA(hashes.SHA256())))
        return (message + b'.' + encode(r.to_bytes(32, 'big') + s.to_bytes(32, 'big'))).decode()

    def request(self, method, path, query=None, body=None):
        if path.startswith('/v1/'):
            url = API + path
        elif path.startswith(API + '/v1/'):
            url = path
        else:
            raise ValueError('Unexpected API destination.')
        if query:
            url += '?' + urllib.parse.urlencode(query)
        data = None if body is None else json.dumps(body).encode()
        request = urllib.request.Request(url, data=data, method=method, headers={
            'Authorization': 'Bearer ' + self.token(), 'Content-Type': 'application/json'})
        try:
            with self.http.open(request, timeout=30) as response:
                raw = response.read()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as error:
            # Avoid dumping responses, account metadata, JWTs or key contents.
            raise RuntimeError(f'App Store Connect returned HTTP {error.code} for {method}.') from None
        except urllib.error.URLError:
            raise RuntimeError('App Store Connect could not be reached.') from None

    def collection(self, path, query=None):
        result = []
        for _ in range(100):
            page = self.request('GET', path, query)
            result.extend(page['data'])
            path, query = page.get('links', {}).get('next'), None
            if not path:
                return result
        raise RuntimeError('App Store Connect pagination exceeded its bound.')


def find_build(api, config, version, number, wait_seconds):
    apps = api.collection('/v1/apps', {'filter[bundleId]': config['bundle_id'], 'limit': 2})
    if len(apps) != 1 or apps[0]['attributes']['bundleId'] != config['bundle_id']:
        raise ValueError('Expected exactly one app with the configured bundle identifier.')
    app_id = apps[0]['id']
    deadline = time.monotonic() + wait_seconds
    while True:
        builds = api.collection('/v1/builds', {
            'filter[app]': app_id, 'filter[version]': number,
            'filter[preReleaseVersion.version]': version,
            'filter[preReleaseVersion.platform]': config['platform'], 'limit': 2})
        if len(builds) > 1:
            raise ValueError('Build selection is ambiguous; no metadata was changed.')
        if builds:
            build = builds[0]
            attrs = build['attributes']
            if attrs['version'] != number or attrs.get('expired'):
                raise ValueError('Selected build is incorrect or expired.')
            release = api.request('GET', f"/v1/builds/{build['id']}/preReleaseVersion")['data']['attributes']
            if release['version'] != version or release['platform'] != config['platform']:
                raise ValueError('Build version/platform does not match the requested delivery.')
            state = attrs['processingState']
            if state == 'VALID':
                return app_id, build
            if state != 'PROCESSING':
                raise ValueError('Apple rejected this build: ' + state)
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError('Exact build is not processed yet; metadata remains incomplete. Retry later.')
        print('Waiting for the exact uploaded build to finish processing…', flush=True)
        time.sleep(min(20, remaining))


def compliance_data(api, config, app_id, build_id):
    baseline = config.get('compliance')
    if not baseline or type(baseline.get('uses_non_exempt_encryption')) is not bool:
        raise ValueError('A confirmed compliance baseline is required before updating metadata.')
    uses = baseline['uses_non_exempt_encryption']
    result = {'type': 'builds', 'id': build_id, 'attributes': {'usesNonExemptEncryption': uses}}
    declaration = baseline.get('declaration_id')
    if uses and not declaration:
        raise ValueError('Non-exempt encryption requires the confirmed approved declaration.')
    if declaration:
        declarations = api.collection('/v1/appEncryptionDeclarations', {'filter[app]': app_id, 'limit': 200})
        matches = [item for item in declarations if item['id'] == declaration]
        if len(matches) != 1:
            raise ValueError('The configured encryption declaration does not belong to this app.')
        attrs = matches[0]['attributes']
        if attrs['appEncryptionDeclarationState'] != 'APPROVED':
            raise ValueError('The configured encryption declaration is not approved.')
        for field, value in baseline.get('answers', {}).items():
            if attrs.get(field) != value:
                raise ValueError('The encryption declaration differs from the confirmed answers.')
        result['relationships'] = {'appEncryptionDeclaration': {
            'data': {'type': 'appEncryptionDeclarations', 'id': declaration}}}
    return result


def update_metadata(api, config, app_id, build, notes, locale):
    build_id = build['id']
    compliance = compliance_data(api, config, app_id, build_id)
    current = build['attributes'].get('usesNonExemptEncryption')
    expected = compliance['attributes']['usesNonExemptEncryption']
    if current is not None and current is not expected:
        raise ValueError('Existing compliance differs from the saved baseline; review it before updating.')
    localizations_path = f'/v1/builds/{build_id}/betaBuildLocalizations'
    existing = [item for item in api.collection(localizations_path, {'limit': 200})
                if item['attributes']['locale'] == locale]
    if len(existing) > 1:
        raise ValueError('Multiple localizations for the requested locale; no changes made.')
    if existing:
        item = existing[0]
        if item['attributes'].get('whatsNew') != notes:
            api.request('PATCH', '/v1/betaBuildLocalizations/' + item['id'], body={'data': {
                'type': 'betaBuildLocalizations', 'id': item['id'], 'attributes': {'whatsNew': notes}}})
    else:
        api.request('POST', '/v1/betaBuildLocalizations', body={'data': {
            'type': 'betaBuildLocalizations', 'attributes': {'locale': locale, 'whatsNew': notes},
            'relationships': {'build': {'data': {'type': 'builds', 'id': build_id}}}}})
    declaration = config['compliance'].get('declaration_id')
    attached = build.get('relationships', {}).get('appEncryptionDeclaration', {}).get('data')
    if current is not expected or (declaration and (attached or {}).get('id') != declaration):
        api.request('PATCH', '/v1/builds/' + build_id, body={'data': compliance})
    saved_notes = [item for item in api.collection(localizations_path, {'limit': 200})
                   if item['attributes']['locale'] == locale]
    saved_build = api.request('GET', '/v1/builds/' + build_id,
                             {'include': 'appEncryptionDeclaration,buildBetaDetail'})
    attrs = saved_build['data']['attributes']
    if len(saved_notes) != 1 or saved_notes[0]['attributes'].get('whatsNew') != notes:
        raise RuntimeError('Tester notes could not be verified after saving.')
    if attrs.get('usesNonExemptEncryption') is not expected:
        raise RuntimeError('Compliance flag could not be verified after saving.')
    if declaration:
        attached = saved_build['data']['relationships']['appEncryptionDeclaration'].get('data')
        if not attached or attached['id'] != declaration:
            raise RuntimeError('Encryption declaration could not be verified after saving.')
    for item in saved_build.get('included', []):
        if item['type'] == 'buildBetaDetails':
            state = item['attributes'].get('internalBuildState', '')
            if state == 'MISSING_EXPORT_COMPLIANCE':
                raise RuntimeError('Apple still reports missing compliance; retry after propagation.')
            print('Internal TestFlight state:', state)
    print('Test notes and confirmed compliance metadata saved and read back successfully.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, default=Path.home()/'.local/share/plank/private-notes/tablet-setup-asc.json')
    parser.add_argument('--version', required=True)
    parser.add_argument('--build', required=True)
    parser.add_argument('--notes', type=Path)
    parser.add_argument('--locale', default='en-US')
    parser.add_argument('--wait-seconds', type=int, default=600)
    parser.add_argument('--inspect', action='store_true', help='Read-only build and compliance inspection')
    args = parser.parse_args()
    if not 0 <= args.wait_seconds <= 3600:
        parser.error('--wait-seconds must be between 0 and 3600')
    if not args.inspect and not args.notes:
        parser.error('--notes is required when updating metadata')
    notes = args.notes.read_text().strip() if args.notes else None
    if notes is not None and not 1 <= len(notes) <= 4000:
        parser.error('What to Test notes must contain 1–4000 characters')
    config = json.loads(private_file(args.config))
    api = APIClient(config)
    app_id, build = find_build(api, config, args.version, args.build, args.wait_seconds)
    print(f"Found {config['bundle_id']} {args.version} ({args.build}), {config['platform']}.")
    if args.inspect:
        detail = api.request('GET', '/v1/builds/' + build['id'],
                            {'include': 'appEncryptionDeclaration,buildBetaDetail'})
        fields = {'version', 'processingState', 'usesNonExemptEncryption', 'expired',
                  'internalBuildState', 'externalBuildState', 'exempt',
                  'containsProprietaryCryptography', 'containsThirdPartyCryptography',
                  'availableOnFrenchStore', 'appEncryptionDeclarationState'}
        selected = lambda item: {key: value for key, value in item['attributes'].items() if key in fields}
        print(json.dumps({'build': selected(detail['data']),
                          'related': [{'type': x['type'], 'attributes': selected(x)}
                                      for x in detail.get('included', [])]}, indent=2))
    else:
        update_metadata(api, config, app_id, build, notes, args.locale)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, OSError, RuntimeError) as error:
        print('TestFlight metadata incomplete: ' + str(error), file=sys.stderr)
        sys.exit(1)
