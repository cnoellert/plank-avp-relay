# SPDX-License-Identifier: GPL-3.0-or-later
"""Drawing handoff: entry point 1, the section 9 conversion, entry point 2 and
the authenticated status plumbing, driven by the shared fixtures.

Contract revision plank-drawing-handoff-v1+r3.

Test invocation, frozen by contract section 12.2:
    python3 tests/drawing_status_test.py     # never python3 -O

`unittest` assertions only: they are ordinary calls and cannot be optimized away,
unlike `assert`, which `python3 -O` strips.
"""
import errno
import hashlib
import json
import os
from pathlib import Path
import socket
import stat
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from avp_relay import drawing_status
from avp_relay.capture_lease import ADDRESS as CAPTURE_ADDRESS
from avp_relay.core import RelayCore

FIXTURES = Path(__file__).resolve().parents[1] / 'tests/fixtures/plank-drawing-handoff-v1'
MANIFEST_SHA256 = 'dd1125d8257f11431671fe116335c4e3c798c157207bdd576f3c44e724e95954'
REVISION = 'plank-drawing-handoff-v1+r3'
MANIFEST = json.loads((FIXTURES / 'MANIFEST.json').read_text())

IDENTITY = 'b4805f947954ddad8645c4a87d1bead9bcd2aceb3cacfa133dcdf10f1048191c'


def listener_of(address, port=28990):
    return {'drawingIdentity': IDENTITY, 'drawingProtocol': dict(drawing_status.PROTOCOL),
            'boundAddress': address, 'boundPort': port}


class SharedFixtures(unittest.TestCase):
    """A contract revision must break a test, not quietly diverge."""

    def test_manifest_hash_and_revision_are_pinned(self):
        self.assertEqual(
            hashlib.sha256((FIXTURES / 'MANIFEST.json').read_bytes()).hexdigest(),
            MANIFEST_SHA256)
        self.assertEqual(MANIFEST['revision'], REVISION)

    def test_every_fixture_matches_its_recorded_hash(self):
        self.assertEqual(len(MANIFEST['files']), 198)
        for name, meta in MANIFEST['files'].items():
            path = FIXTURES / name
            self.assertTrue(path.is_file(), name)
            data = path.read_bytes()
            self.assertEqual(hashlib.sha256(data).hexdigest(), meta['sha256'], name)
            self.assertEqual(len(data), meta['bytes'], name)

    def test_outcome_names_match_the_contract_vocabulary(self):
        self.assertEqual(set(MANIFEST['outcomes']),
                         {'handoffReady', 'drawingUnavailable', 'handoffUnsupported'})
        self.assertEqual(drawing_status.UNAVAILABLE_REASONS, frozenset({
            'service.absent', 'service.busy', 'service.invalid',
            'service.peerUnverified', 'listener.loopbackOnly',
            'listener.noUsableAddress', 'response.tooLarge'}))
        self.assertEqual(drawing_status.UNSUPPORTED_REASONS, frozenset({
            'relay.tooOld', 'authorization.required', 'authorization.failed',
            'protocol.error'}))
        self.assertEqual(drawing_status.UNAVAILABLE_REASONS &
                         drawing_status.UNSUPPORTED_REASONS, frozenset())
        for reason in drawing_status.UNAVAILABLE_REASONS:
            self.assertEqual(drawing_status.outcome(drawing_status.unavailable(reason)),
                             'drawingUnavailable', reason)
        for reason in drawing_status.UNSUPPORTED_REASONS:
            self.assertEqual(drawing_status.outcome(drawing_status.unavailable(reason)),
                             'handoffUnsupported', reason)
        self.assertEqual(drawing_status.outcome(None), 'handoffUnsupported')


def fixtures_for(prefix):
    return sorted(name for name in MANIFEST['files'] if name.startswith(prefix))


class LocalMetadata(unittest.TestCase):
    """Entry point 1, contract sections 3 and 7.4."""

    def load(self, name):
        data = (FIXTURES / name).read_bytes()
        self.assertEqual(hashlib.sha256(data).hexdigest(),
                         MANIFEST['files'][name]['sha256'], name)
        return data

    def test_every_valid_fixture_is_accepted(self):
        names = fixtures_for('local/valid/')
        self.assertEqual(len(names), 5)
        for name in names:
            listener, declared, failure = drawing_status.validate_local_metadata(
                self.load(name))
            self.assertIsNone(failure, name)
            self.assertEqual(MANIFEST['files'][name]['expect'], 'accept', name)
            if listener is None:
                self.assertIsNotNone(declared, name)
            else:
                self.assertEqual(set(listener), drawing_status.LISTENER_MEMBERS, name)

    def test_every_invalid_fixture_fails_at_exactly_its_named_reason(self):
        names = fixtures_for('local/invalid/')
        self.assertEqual(len(names), 31)
        for name in names:
            listener, declared, failure = drawing_status.validate_local_metadata(
                self.load(name))
            self.assertIsNone(listener, name)
            self.assertIsNone(declared, name)
            self.assertEqual(failure, MANIFEST['files'][name]['expect'], name)

    def test_wildcard_and_loopback_are_legal_only_here(self):
        for address in ('0.0.0.0', '127.0.0.1', '169.254.10.20'):
            self.assertIsNone(drawing_status.check_bound_address(address), address)
        self.assertEqual(drawing_status.check_route_address('0.0.0.0'),
                         'route.address.unspecified')
        self.assertEqual(drawing_status.check_route_address('127.0.0.1'),
                         'route.address.loopback')

    def test_duplicate_members_are_found_in_the_raw_bytes_at_every_depth(self):
        # json.loads collapses these, so a decode-then-inspect check cannot see
        # them at all.
        # The decode has already lost the duplicate before anything can see it.
        self.assertEqual(json.loads('{"version":1,"version":2}'), {'version': 2})
        for text in ('{"version":1,"version":1}',
                     '{"a":{"b":1,"b":2}}',
                     '{"a":[{"b":1,"b":2}]}',
                     '{"a":1,"\\u0061":2}'):
            self.assertTrue(drawing_status.duplicate_member(text), text)
        for text in ('{"ab":1,"a":2}', '{"a":{"b":1},"c":{"b":2}}', '{}', '[]'):
            self.assertFalse(drawing_status.duplicate_member(text), text)
        raw = b'{"version":1,"ok":true,"ok":true,"supported":true,"state":"unavailable","reason":"service.absent"}'
        self.assertEqual(drawing_status.validate_local_metadata(raw)[2],
                         'payload.duplicateMember')

    def test_deterministic_literal_pre_checks(self):
        # Contract section 7.4a: no reason depends on a platform renderer.
        self.assertEqual(drawing_status.check_route_address('192.000.002.010'),
                         'route.address.nonCanonical')
        self.assertEqual(drawing_status.check_route_address('::ffff:192.0.2.10'),
                         'route.address.mapped')
        self.assertEqual(drawing_status.check_route_address('::192.0.2.10'),
                         'route.address.mapped')
        self.assertEqual(drawing_status.check_route_address('2001:DB8::2'),
                         'route.address.nonCanonical')
        self.assertEqual(drawing_status.check_route_address('2001:db8:0:0:0:0:0:2'),
                         'route.address.nonCanonical')
        self.assertEqual(drawing_status.check_route_address('192.0.2.10:28990'),
                         'route.address.notLiteral')
        self.assertEqual(drawing_status.check_route_address('relay.example'),
                         'route.address.notLiteral')
        self.assertEqual(drawing_status.check_route_address('fe80::1%eth0'),
                         'route.address.scoped')
        self.assertEqual(drawing_status.check_route_address('2001:db8::2'),
                         'route.address.familyUnsupported')
        self.assertEqual(drawing_status.check_route_address('ff02::1'),
                         'route.address.multicast')
        self.assertEqual(drawing_status.check_route_address('fe80::1'),
                         'route.address.linkLocal')
        self.assertEqual(drawing_status.check_route_address('::1'),
                         'route.address.loopback')
        self.assertEqual(drawing_status.check_route_address('::'),
                         'route.address.unspecified')
        self.assertEqual(drawing_status.check_route_address('255.255.255.255'),
                         'route.address.broadcast')
        self.assertEqual(drawing_status.check_route_address('240.0.0.1'),
                         'route.address.broadcast')
        self.assertEqual(drawing_status.check_route_address('239.0.0.1'),
                         'route.address.multicast')
        self.assertEqual(drawing_status.check_route_address('a' * 65),
                         'route.address.tooLong')
        self.assertIsNone(drawing_status.check_route_address('203.0.113.30'))


class StatusDescriptor(unittest.TestCase):
    """Entry point 2, contract sections 4 and 7.3."""

    def load(self, name):
        data = (FIXTURES / name).read_bytes()
        self.assertEqual(hashlib.sha256(data).hexdigest(),
                         MANIFEST['files'][name]['sha256'], name)
        return data

    def test_every_valid_fixture_is_accepted(self):
        names = fixtures_for('status/valid/')
        self.assertEqual(len(names), 4)
        for name in names:
            descriptor, declared, failure = drawing_status.validate_status(
                self.load(name))
            self.assertIsNone(failure, name)
            self.assertEqual(MANIFEST['files'][name]['expect'], 'accept', name)
            if descriptor is not None:
                self.assertEqual(set(descriptor), drawing_status.DESCRIPTOR_MEMBERS, name)
            else:
                self.assertIn(declared, drawing_status.UNAVAILABLE_REASONS |
                              drawing_status.UNSUPPORTED_REASONS, name)

    def test_every_invalid_fixture_fails_at_exactly_its_named_reason(self):
        names = fixtures_for('status/invalid/')
        self.assertEqual(len(names), 20)
        for name in names:
            descriptor, declared, failure = drawing_status.validate_status(
                self.load(name))
            self.assertIsNone(descriptor, name)
            self.assertIsNone(declared, name)
            self.assertEqual(failure, MANIFEST['files'][name]['expect'], name)

    def test_link_members_are_forbidden_and_never_required(self):
        # The r1 defect: requiring any of these would make every honest status
        # response invalid.
        for name in ('with-request-id.json', 'with-display-name.json',
                     'with-management-identity.json'):
            data = self.load('status/invalid/' + name)
            self.assertEqual(drawing_status.validate_status(data)[2],
                             'status.unknownMember', name)
        ready = self.load('status/valid/ready.json')
        descriptor = drawing_status.validate_status(ready)[0]
        self.assertNotIn('requestID', descriptor)
        self.assertNotIn('displayName', descriptor)
        self.assertNotIn('managementIdentity', descriptor)

    def test_duplicate_members_are_scanned_from_the_original_response_bytes(self):
        raw = (b'{"supported":true,"state":"unavailable",'
               b'"reason":"service.absent","reason":"service.busy"}')
        self.assertEqual(len(json.loads(raw)), 3)  # the decode has already lost it
        self.assertEqual(drawing_status.validate_status(raw)[2],
                         'payload.duplicateMember')

    def test_route_bounds(self):
        route = {'address': '192.0.2.10', 'port': 28990}
        self.assertEqual(drawing_status.check_routes([])[1], 'routes.count')
        self.assertEqual(drawing_status.check_routes([dict(route, address='192.0.2.%d' % n)
                                                      for n in range(10, 19)])[1],
                         'routes.count')
        eight = [dict(route, address='192.0.2.%d' % n) for n in range(10, 18)]
        self.assertEqual(len(drawing_status.check_routes(eight)[0]), 8)
        self.assertEqual(drawing_status.check_routes([route, dict(route)])[0], [route])
        self.assertEqual(drawing_status.check_routes('nope')[1], 'routes.type')
        self.assertEqual(drawing_status.check_routes(['nope'])[1], 'route.type')
        self.assertEqual(drawing_status.check_routes([{'port': 1}])[1],
                         'route.address.missing')
        self.assertEqual(drawing_status.check_routes([{'address': '192.0.2.10'}])[1],
                         'route.port.missing')
        self.assertEqual(drawing_status.check_routes([dict(route, port=0)])[1],
                         'route.port')
        self.assertEqual(drawing_status.check_routes([dict(route, port=65536)])[1],
                         'route.port')
        self.assertEqual(drawing_status.check_routes([dict(route, kind='fibre')])[1],
                         'route.kind')
        self.assertEqual(drawing_status.check_routes([dict(route, interface='x' * 16)])[1],
                         'route.interface')
        self.assertEqual(drawing_status.check_routes([dict(route, interface=None)])[1],
                         'route.nullMember')
        self.assertEqual(drawing_status.check_routes([dict(route, kind=None)])[1],
                         'route.nullMember')
        self.assertEqual(drawing_status.check_routes([dict(route, extra=1)])[1],
                         'route.unknownMember')
        # Interface metadata is advisory and never changes acceptance.
        self.assertIsNone(drawing_status.check_routes(
            [dict(route, interface='eth0', kind='wired')])[1])

    def test_unknown_members_are_rejected_at_every_level(self):
        base = {'supported': True, 'state': 'ready', 'descriptor': {
            'version': 1, 'drawingIdentity': IDENTITY,
            'drawingProtocol': dict(drawing_status.PROTOCOL),
            'routes': [{'address': '192.0.2.10', 'port': 28990}]}}
        self.assertIsNone(drawing_status.validate_status(
            json.dumps(base).encode())[2])
        wrapper = json.loads(json.dumps(base))
        wrapper['cached'] = True
        self.assertEqual(drawing_status.validate_status(json.dumps(wrapper).encode())[2],
                         'status.unknownMember')
        nested = json.loads(json.dumps(base))
        nested['descriptor']['drawingProtocol']['extra'] = 1
        self.assertEqual(drawing_status.validate_status(json.dumps(nested).encode())[2],
                         'drawingProtocol.unknownMember')
        bluetooth = json.loads(json.dumps(base))
        bluetooth['descriptor']['drawingProtocol']['linkType'] = 1
        self.assertEqual(drawing_status.validate_status(json.dumps(bluetooth).encode())[2],
                         'drawingProtocol.linkType')


class Conversion(unittest.TestCase):
    """Contract section 9. Wildcard expansion is the production path."""

    def test_every_conversion_fixture_matches_its_outcome_and_routes(self):
        names = fixtures_for('conversion/')
        self.assertEqual(len(names), 7)
        for name in names:
            data = (FIXTURES / name).read_bytes()
            self.assertEqual(hashlib.sha256(data).hexdigest(),
                             MANIFEST['files'][name]['sha256'], name)
            case = json.loads(data)
            families = {getattr(socket, family) for family in case['families']}
            self.assertEqual(families, {socket.AF_INET}, name)
            listener, declared, failure = drawing_status.validate_local_metadata(
                json.dumps({'version': 1, 'ok': True, 'supported': True,
                            'state': 'ready', 'listener': case['listener']}).encode())
            self.assertIsNone(failure, name)
            routes, reason = drawing_status.convert(listener, case['hostAddresses'],
                                                    families)
            expected = MANIFEST['files'][name]['expect']
            self.assertEqual(expected, case['expectedOutcome'], name)
            if expected == 'conversion.ok':
                self.assertIsNone(reason, name)
                self.assertEqual(routes, case['expectedRoutes'], name)
                # The descriptor built from them must pass entry point 2.
                wrapper = {'supported': True, 'state': 'ready',
                           'descriptor': drawing_status.build_descriptor(listener, routes)}
                self.assertIsNone(drawing_status.validate_status(
                    json.dumps(wrapper).encode())[2], name)
            else:
                self.assertEqual(reason, expected, name)
                self.assertIsNone(routes, name)
                self.assertEqual(case['expectedRoutes'], [], name)

    def test_wildcard_and_loopback_never_escape_into_a_descriptor(self):
        routes, reason = drawing_status.convert(listener_of('0.0.0.0'),
                                                ['0.0.0.0', '127.0.0.1', '192.0.2.10'])
        self.assertIsNone(reason)
        self.assertEqual(routes, [{'address': '192.0.2.10', 'port': 28990}])
        self.assertEqual(drawing_status.convert(listener_of('127.0.0.1'),
                                                 ['192.0.2.10'])[1],
                         'listener.loopbackOnly')
        self.assertEqual(drawing_status.convert(listener_of('127.9.9.9'),
                                                 ['192.0.2.10'])[1],
                         'listener.loopbackOnly')

    def test_wildcard_expansion_caps_at_eight_in_inventory_order(self):
        inventory = ['192.0.2.%d' % n for n in range(10, 30)]
        routes, reason = drawing_status.convert(listener_of('0.0.0.0'), inventory)
        self.assertIsNone(reason)
        self.assertEqual(len(routes), 8)
        self.assertEqual([route['address'] for route in routes], inventory[:8])

    def test_no_ipv6_route_is_ever_produced(self):
        routes, reason = drawing_status.convert(
            listener_of('0.0.0.0'), ['2001:db8::2', '192.0.2.10'], {socket.AF_INET})
        self.assertIsNone(reason)
        self.assertEqual(routes, [{'address': '192.0.2.10', 'port': 28990}])

    def test_the_conversion_adds_no_interface_metadata(self):
        routes, _ = drawing_status.convert(listener_of('0.0.0.0'), ['192.0.2.10'])
        self.assertEqual(set(routes[0]), {'address', 'port'})

    def test_a_bound_literal_in_a_refused_class_has_no_usable_address(self):
        for address in ('169.254.10.20',):
            self.assertEqual(drawing_status.convert(listener_of(address),
                                                     ['192.0.2.10'])[1],
                             'listener.noUsableAddress')
        self.assertEqual(drawing_status.convert(listener_of('0.0.0.0'), [])[1],
                         'listener.noUsableAddress')


class AccountResolution(unittest.TestCase):
    """Contract section 8.3a. By name, fail closed, corroboration only."""

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.state = Path(self.directory.name) / 'plank-tablet-relay'
        self.addCleanup(self.directory.cleanup)

    def resolve(self, **kwargs):
        return drawing_status.resolve_service_uid(
            kwargs.pop('account', 'plank-relay'),
            kwargs.pop('state_directory', str(self.state)))

    def test_the_name_is_the_authority_and_the_directory_only_corroborates(self):
        self.state.mkdir()
        entry = Mock(pw_uid=998)
        with patch('avp_relay.drawing_status.pwd.getpwnam', return_value=entry) as lookup:
            with patch('avp_relay.drawing_status.os.lstat',
                       return_value=os.stat_result(
                           (stat.S_IFDIR | 0o700, 0, 0, 1, 998, 998, 0, 0, 0, 0))):
                self.assertEqual(self.resolve(), (998, None))
        lookup.assert_called_once_with('plank-relay')

    def test_a_disagreeing_directory_owner_fails_closed(self):
        self.state.mkdir()
        with patch('avp_relay.drawing_status.pwd.getpwnam', return_value=Mock(pw_uid=998)):
            with patch('avp_relay.drawing_status.os.lstat',
                       return_value=os.stat_result(
                           (stat.S_IFDIR | 0o700, 0, 0, 1, 12345, 998, 0, 0, 0, 0))):
                self.assertEqual(self.resolve(), (None, 'service.peerUnverified'))

    def test_a_symlinked_state_directory_is_refused(self):
        with patch('avp_relay.drawing_status.pwd.getpwnam', return_value=Mock(pw_uid=998)):
            with patch('avp_relay.drawing_status.os.lstat',
                       return_value=os.stat_result(
                           (stat.S_IFLNK | 0o777, 0, 0, 1, 998, 998, 0, 0, 0, 0))):
                self.assertEqual(self.resolve(), (None, 'service.peerUnverified'))

    def test_an_unresolvable_account_never_falls_back_to_a_uid(self):
        self.state.mkdir()
        with patch('avp_relay.drawing_status.pwd.getpwnam', side_effect=KeyError('nope')):
            self.assertEqual(self.resolve(), (None, 'service.peerUnverified'))
        with patch('avp_relay.drawing_status.pwd.getpwnam',
                   side_effect=OSError(errno.EIO, 'account database unavailable')):
            self.assertEqual(self.resolve(), (None, 'service.peerUnverified'))

    def test_a_cleanly_absent_installation_is_absent_not_unverified(self):
        with patch('avp_relay.drawing_status.pwd.getpwnam', side_effect=KeyError('nope')):
            self.assertEqual(self.resolve(), (None, 'service.absent'))

    def test_a_present_account_without_its_state_directory_is_absent(self):
        with patch('avp_relay.drawing_status.pwd.getpwnam', return_value=Mock(pw_uid=998)):
            self.assertEqual(self.resolve(), (None, 'service.absent'))

    def test_no_uid_is_compiled_in(self):
        source = (Path(drawing_status.__file__)).read_text()
        self.assertIn("pwd.getpwnam", source)
        self.assertEqual(drawing_status.SERVICE_ACCOUNT, 'plank-relay')


class LocalClient(unittest.TestCase):
    """Contract sections 8.3, 8.4, 8.6 and 8.8, through an injected reader."""

    def ready(self, address='0.0.0.0'):
        return json.dumps({'version': 1, 'ok': True, 'supported': True,
                           'state': 'ready', 'listener': listener_of(address)}).encode() + b'\n'

    def test_a_ready_listener_becomes_a_validated_descriptor(self):
        handoff = drawing_status.read_handoff(lambda: (self.ready(), None),
                                              ['192.0.2.10', '203.0.113.30'])
        self.assertEqual(drawing_status.outcome(handoff), 'handoffReady')
        self.assertEqual(set(handoff), {'supported', 'state', 'descriptor'})
        self.assertEqual(handoff['descriptor']['routes'],
                         [{'address': '192.0.2.10', 'port': 28990},
                          {'address': '203.0.113.30', 'port': 28990}])
        self.assertEqual(handoff['descriptor']['drawingIdentity'], IDENTITY)
        self.assertIsNone(drawing_status.validate_status(
            json.dumps(handoff).encode())[2])

    def test_absence_restart_busy_and_squat_are_distinct(self):
        for reason in ('service.absent', 'service.busy', 'service.peerUnverified'):
            handoff = drawing_status.read_handoff(lambda r=reason: (None, r))
            self.assertEqual(handoff, {'supported': True, 'state': 'unavailable',
                                       'reason': reason}, reason)
            self.assertEqual(drawing_status.outcome(handoff), 'drawingUnavailable')
        # A restart: absent, then ready on the next status request, with no
        # retry in between.
        calls = []

        def reader():
            calls.append(1)
            return (None, 'service.absent') if len(calls) == 1 else (self.ready(), None)

        first = drawing_status.read_handoff(reader, ['192.0.2.10'])
        self.assertEqual(first['reason'], 'service.absent')
        self.assertEqual(len(calls), 1)
        second = drawing_status.read_handoff(reader, ['192.0.2.10'])
        self.assertEqual(second['state'], 'ready')
        self.assertEqual(len(calls), 2)

    def test_invalid_metadata_is_service_invalid_and_never_forwarded(self):
        for raw in (b'{', b'[]', b'{"version":2,"ok":true,"supported":true,"state":"ready"}',
                    b'{"version":1,"ok":false,"supported":true,"state":"ready"}',
                    (FIXTURES / 'local/invalid/oversized.json').read_bytes(),
                    (FIXTURES / 'local/invalid/listener-not-object.json').read_bytes()):
            handoff = drawing_status.read_handoff(lambda r=raw: (r, None), ['192.0.2.10'])
            self.assertEqual(handoff, {'supported': True, 'state': 'unavailable',
                                       'reason': 'service.invalid'}, raw[:32])

    def test_a_declared_unavailable_reason_outside_the_set_is_service_invalid(self):
        raw = json.dumps({'version': 1, 'ok': True, 'supported': True,
                          'state': 'unavailable', 'reason': 'wacom.missing'}).encode()
        self.assertEqual(drawing_status.read_handoff(lambda: (raw, None))['reason'],
                         'service.invalid')
        raw = (FIXTURES / 'local/valid/unavailable.json').read_bytes()
        self.assertEqual(drawing_status.read_handoff(lambda: (raw, None))['reason'],
                         'service.absent')

    def test_a_reader_that_raises_never_escapes(self):
        def explode():
            raise OSError(errno.ETIMEDOUT, 'timed out')
        self.assertEqual(drawing_status.read_handoff(explode)['reason'], 'service.busy')

        def worse():
            raise RuntimeError('unexpected')
        self.assertEqual(drawing_status.read_handoff(worse)['reason'], 'service.invalid')

    def test_malformed_unicode_and_deep_json_leave_normal_status_available(self):
        replies = (
            b'{"version":1,"ok":true,"supported":true,"state":"unavailable",'
            b'"reason":"\\ud800"}',
            b'{"nested":' + b'[' * 1100 + b'0' + b']' * 1100 + b'}',
            b'\xff\n',
        )
        for raw in replies:
            self.assertLessEqual(len(raw), drawing_status.RESPONSE_MAX)
            core = AuthenticatedStatusPlumbing().core(None)
            core.read_drawing_handoff = lambda r=raw: drawing_status.read_handoff(
                lambda: (r, None), ['192.0.2.10'])
            for _ in range(2):
                status = AuthenticatedStatusPlumbing().request(core)
                self.assertTrue(status['ok'])
                self.assertEqual(status['drawingHandoff'],
                                 drawing_status.unavailable('service.invalid'))
                self.assertEqual(status['tcpPort'], 28991)

    def test_one_deadline_covers_connect_send_and_fragmented_reads(self):
        self.check_deadline([0.20, 0.40], 'service.busy', 0.75)

    def test_fragmented_reply_within_the_total_budget_succeeds(self):
        self.check_deadline([0.10, 0.10], None, 0.55)

    def test_a_reply_delivered_after_the_deadline_is_not_accepted(self):
        self.check_deadline([0.10, 0.40], 'service.busy', 0.85,
                            honor_timeout=False)

    def check_deadline(self, reads, reason, elapsed, honor_timeout=True):
        # No wall-clock sleeps: each operation advances a monotonic clock,
        # obeying the timeout exactly as a socket would. The first read may
        # finish before 750 ms while the next exceeds the remaining budget.
        now = [0.0]
        timeouts = []
        closed = []

        class Probe:
            def __enter__(inner): return inner
            def __exit__(inner, *_): closed.append(True); return False
            def settimeout(inner, value):
                inner.timeout = value
                timeouts.append(value)

            def wait(inner, duration):
                if honor_timeout and duration > inner.timeout:
                    now[0] += inner.timeout
                    raise socket.timeout()
                now[0] += duration

            def connect(inner, address): inner.wait(0.25)
            def getsockopt(inner, level, option, size):
                import struct
                return struct.pack('3i', 1, 998, 998)
            def sendall(inner, data): inner.wait(0.10)
            def recv(inner, size):
                inner.wait(reads.pop(0))
                return b'{}\n' if not reads else b' '

        client = drawing_status.DrawingStatusClient()
        with patch.object(client, 'resolve', return_value=(998, None)), \
                patch.object(drawing_status.socket, 'socket', return_value=Probe()), \
                patch('avp_relay.drawing_status.time.monotonic',
                      side_effect=lambda: now[0]):
            raw, result = client.read()
        self.assertEqual(result, reason)
        self.assertEqual(raw, b' {}\n' if reason is None else None)
        self.assertAlmostEqual(now[0], elapsed)
        self.assertTrue(closed)
        self.assertTrue(all(0 < timeout <= 0.75 for timeout in timeouts))
        self.assertAlmostEqual(timeouts[0], 0.75)
        self.assertAlmostEqual(timeouts[1], 0.50)
        self.assertAlmostEqual(timeouts[2], 0.40)

    def test_the_peer_check_runs_before_a_single_byte_is_read(self):
        order = []

        class Probe:
            family = socket.AF_UNIX

            def __enter__(inner): return inner
            def __exit__(inner, *_): return False
            def settimeout(inner, value): order.append(('timeout', value))
            def connect(inner, address): order.append(('connect', address))

            def getsockopt(inner, level, option, size):
                order.append(('peercred', option))
                import struct
                return struct.pack('3i', 1, 4321, 4321)

            def sendall(inner, data): order.append(('send', data))
            def recv(inner, size): order.append(('recv', size)); return b'{}\n'

        client = drawing_status.DrawingStatusClient()
        with patch.object(drawing_status, 'resolve_service_uid', return_value=(998, None)):
            with patch('avp_relay.drawing_status.socket.socket', return_value=Probe()):
                self.assertEqual(client.read(), (None, 'service.peerUnverified'))
        self.assertEqual([step[0] for step in order], ['timeout', 'connect', 'peercred'])
        self.assertGreater(order[0][1], 0)
        self.assertLessEqual(order[0][1], 0.75)
        self.assertEqual(order[1][1], '\0plank-tablet-drawing-status-v1')

    def test_a_matching_peer_is_read_once_with_the_bounded_request(self):
        sent = []

        class Probe:
            def __enter__(inner): return inner
            def __exit__(inner, *_): return False
            def settimeout(inner, value): pass
            def connect(inner, address): pass

            def getsockopt(inner, level, option, size):
                import struct
                return struct.pack('3i', 1, 998, 998)

            def sendall(inner, data): sent.append(data)
            def recv(inner, size): return b'{"version":1,"ok":true,"supported":true,"state":"unavailable","reason":"service.absent"}\n'

        client = drawing_status.DrawingStatusClient()
        with patch.object(drawing_status, 'resolve_service_uid', return_value=(998, None)):
            with patch('avp_relay.drawing_status.socket.socket', return_value=Probe()):
                raw, reason = client.read()
        self.assertIsNone(reason)
        self.assertEqual(sent, [b'{"op":"drawing-status","version":1}\n'])
        self.assertLessEqual(len(sent[0]), drawing_status.REQUEST_MAX)
        self.assertEqual(drawing_status.validate_local_metadata(raw)[1], 'service.absent')

    def test_connect_errors_map_to_their_named_reasons(self):
        for error, reason in ((FileNotFoundError(), 'service.absent'),
                              (ConnectionRefusedError(), 'service.absent'),
                              (socket.timeout(), 'service.busy'),
                              (OSError(errno.ECONNRESET, 'reset'), 'service.busy')):
            client = drawing_status.DrawingStatusClient()
            with patch.object(drawing_status, 'resolve_service_uid',
                              return_value=(998, None)):
                with patch('avp_relay.drawing_status.socket.socket',
                           side_effect=error):
                    self.assertEqual(client.read(), (None, reason), reason)

    def test_an_oversized_response_is_service_invalid(self):
        class Probe:
            def __enter__(inner): return inner
            def __exit__(inner, *_): return False
            def settimeout(inner, value): pass
            def connect(inner, address): pass

            def getsockopt(inner, level, option, size):
                import struct
                return struct.pack('3i', 1, 998, 998)

            def sendall(inner, data): pass
            def recv(inner, size): return b'x' * size

        client = drawing_status.DrawingStatusClient()
        with patch.object(drawing_status, 'resolve_service_uid', return_value=(998, None)):
            with patch('avp_relay.drawing_status.socket.socket', return_value=Probe()):
                self.assertEqual(client.read(), (None, 'service.invalid'))


class CaptureLeaseUnchanged(unittest.TestCase):
    """The drawing handoff never touches the shared capture interlock."""

    def test_the_status_name_is_not_the_capture_name(self):
        self.assertEqual(CAPTURE_ADDRESS, b'\0plank-tablet-capture-v1')
        self.assertEqual(drawing_status.ABSTRACT_NAME, 'plank-tablet-drawing-status-v1')
        self.assertNotEqual(CAPTURE_ADDRESS,
                            b'\0' + drawing_status.ABSTRACT_NAME.encode())

    def test_the_handoff_module_references_no_capture_state(self):
        # No import of, call into, or name from capture, pairing, enrollment or
        # identity material: the interface is a read of four public fields.
        source = ''.join(line for line in
                         Path(drawing_status.__file__).read_text().splitlines(True)
                         if not line.lstrip().startswith('#'))
        for forbidden in ('capture_lease', 'CaptureLease', 'require_lease',
                          'paired-clients', 'private_key', 'identity.key',
                          'enroll_headset', 'allow_enrollment', 'pltr_pairing'):
            self.assertNotIn(forbidden, source, forbidden)
        import ast
        imported = set()
        for node in ast.walk(ast.parse(Path(drawing_status.__file__).read_text())):
            if isinstance(node, ast.Import):
                imported.update(alias.name for alias in node.names)
            elif isinstance(node, ast.ImportFrom):
                imported.add(node.module)
        self.assertEqual(imported, {'json', 'os', 'pwd', 'socket', 'stat',
                                'struct', 'time', 'network_routes'})

    def test_reading_the_handoff_leaves_a_held_lease_alone(self):
        from avp_relay.capture_lease import CaptureLease
        lease = CaptureLease()
        lease.socket = object()  # held, without binding a real abstract name
        self.assertTrue(lease.held)
        drawing_status.read_handoff(lambda: (None, 'service.absent'))
        self.assertTrue(lease.held)
        lease.socket = None


class AuthenticatedStatusPlumbing(unittest.TestCase):
    """Contract sections 4 and 8.6, in `core.py`."""

    def core(self, handoff):
        core = object.__new__(RelayCore)
        core.owner = 'headset'
        core.tcp_port = 28991
        core.network_endpoints = lambda: ['192.0.2.2']
        core.native = Mock(public_key='a' * 64)
        core.read_drawing_handoff = lambda: handoff
        core.tablets = Mock(handle=lambda *_: json.dumps(
            {'version': 1, 'id': 1, 'ok': True, 'hostname': 'relay.example',
             'headsetAuthorized': True}))
        return core

    def request(self, core, peer='headset', authenticated=True):
        payload = json.dumps({'version': 1, 'id': 1, 'op': 'status'}).encode()
        return json.loads(core.request(payload, peer, authenticated=authenticated))

    def test_the_descriptor_travels_only_to_the_authenticated_owner(self):
        ready = drawing_status.read_handoff(
            lambda: (json.dumps({'version': 1, 'ok': True, 'supported': True,
                                 'state': 'ready',
                                 'listener': listener_of('0.0.0.0')}).encode(), None),
            ['192.0.2.10'])
        core = self.core(ready)
        owner = self.request(core)
        self.assertEqual(owner['drawingHandoff'], ready)
        self.assertEqual(owner['tcpPort'], 28991)
        self.assertEqual(owner['networkAddresses'], ['192.0.2.2'])
        for peer, authenticated in (('headset', False), ('stranger', True),
                                    ('stranger', False)):
            other = self.request(core, peer, authenticated)
            self.assertNotIn('drawingHandoff', other)
            self.assertNotIn('tcpPort', other)
            self.assertNotIn('networkAddresses', other)
            self.assertEqual(other['relayKey'], 'a' * 64)

    def test_an_unavailable_reason_still_reaches_the_owner(self):
        core = self.core(drawing_status.unavailable('listener.loopbackOnly'))
        self.assertEqual(self.request(core)['drawingHandoff'],
                         {'supported': True, 'state': 'unavailable',
                          'reason': 'listener.loopbackOnly'})

    def test_a_descriptor_that_will_not_fit_reports_response_too_large(self):
        ready = {'supported': True, 'state': 'ready', 'descriptor': {
            'version': 1, 'drawingIdentity': IDENTITY,
            'drawingProtocol': dict(drawing_status.PROTOCOL),
            'routes': [{'address': '192.0.2.10', 'port': 28990}]}}
        core = self.core(ready)
        # Size the rest of the response so it fits with the short unavailable
        # member and does not fit with the descriptor.
        shape = {'version': 1, 'id': 1, 'ok': True, 'enrollmentVersion': 1,
                 'relayKey': 'a' * 64, 'tcpPort': 28991,
                 'networkAddresses': ['192.0.2.2'],
                 'drawingHandoff': drawing_status.unavailable('response.tooLarge'),
                 'filler': ''}
        room = 4096 - len(json.dumps(shape, separators=(',', ':')).encode())
        core.tablets = Mock(handle=lambda *_: json.dumps(
            {'version': 1, 'id': 1, 'ok': True, 'filler': 'f' * room}))
        reply = json.loads(core.request(
            json.dumps({'version': 1, 'id': 1, 'op': 'status'}).encode(),
            'headset', authenticated=True))
        self.assertEqual(reply['drawingHandoff'],
                         {'supported': True, 'state': 'unavailable',
                          'reason': 'response.tooLarge'})
        self.assertEqual(reply['tcpPort'], 28991)

    def test_the_response_bound_is_still_enforced(self):
        core = self.core(drawing_status.unavailable('service.absent'))
        reply = self.request(core)
        self.assertLessEqual(
            len(json.dumps(reply, separators=(',', ':')).encode()), 4096)


if __name__ == '__main__':
    unittest.main(verbosity=1)
