#!/usr/bin/env python3
import json
from pathlib import Path
import sys
import unittest
import struct
from types import SimpleNamespace
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from avp_relay import drawing_enrollment as e


class EnrollmentTests(unittest.TestCase):
    def setUp(self):
        self.command = dict(version=1, id=1, op='drawing-enrollment', action='prepare',
                            requestID='11' * 16, clientIdentity='22' * 32, drawingIdentity='33' * 32)
        self.calls = []

    def run_command(self, data=None, peer='owner', owner='owner', authenticated=True, enrolling=False):
        def send(command):
            self.calls.append(command)
            return dict(requestID=command['requestID'], state='pending', expiresIn=120)
        return json.loads(e.handle(data or json.dumps(self.command).encode(), peer, owner,
                                   authenticated, enrolling, send))

    def test_exact_authorized_owner_only(self):
        for args in (dict(authenticated=False), dict(peer='other'), dict(owner=None), dict(enrolling=True)):
            self.assertFalse(self.run_command(**args)['ok'])
        self.assertEqual(self.calls, [])
        self.assertTrue(self.run_command()['ok'])
        self.assertEqual(self.calls, [self.command])

    def test_invalid_requests_never_reach_mutation(self):
        original = self.command.copy()
        for field, value in [('version', True), ('id', False), ('id', 0), ('action', 'commit'),
                             ('requestID', '0' * 32), ('requestID', '../path'),
                             ('clientIdentity', 'A' * 64), ('clientIdentity', []),
                             ('drawingIdentity', '0' * 64), ('extra', 'value')]:
            self.command = {**original, field: value}
            self.assertFalse(self.run_command()['ok'])
        self.assertEqual(self.calls, [])

    def test_peer_binding_reply_and_one_deadline(self):
        command = self.command
        reply = e.PREFIX + bytes([0]) + bytes.fromhex(command['requestID'])
        clock = [100.0]
        class Connection:
            uid = 321
            malformed = False
            def __enter__(self): return self
            def __exit__(self, *args): pass
            def settimeout(self, value): self.timeout = value
            def connect(self, name): pass
            def getsockopt(self, *args): return struct.pack('3i', 1, self.uid, 1)
            def sendall(self, data):
                self.sent = data
                self.offset = 0
            def recv(self, size):
                clock[0] += 0.30
                if self.timeout < 0.30: raise TimeoutError()
                data = reply if not self.malformed else reply[:-1] + bytes([255])
                chunk = data[self.offset:self.offset + min(size, 8)]
                self.offset += len(chunk)
                return chunk
        connection = Connection()
        with patch.object(e.pwd, 'getpwnam', return_value=SimpleNamespace(pw_uid=321)), \
                patch.object(e.socket, 'socket', return_value=connection), \
                patch.object(e.socket, 'SO_PEERCRED', 17, create=True), \
                patch.object(e.time, 'monotonic', side_effect=lambda: clock[0]):
            # Three fragments each fit a reset 750 ms timeout, but the whole
            # exchange exceeds one deadline. No grant result can escape it.
            with self.assertRaises(TimeoutError): e.exchange(command)
            self.assertEqual(connection.sent, e.PREFIX + bytes([1]) + bytes.fromhex(command['requestID']) +
                             bytes.fromhex(command['clientIdentity']) + bytes.fromhex(command['drawingIdentity']))
            connection.uid = 999
            with self.assertRaisesRegex(ValueError, 'verified'): e.exchange(command)
            connection.uid = 321
            connection.recv = lambda size: reply[:-1] + bytes([255])
            with self.assertRaisesRegex(ValueError, 'Invalid'): e.exchange(command)
            connection.recv = lambda size: reply
            self.assertEqual(e.exchange(command)['state'], 'pending')

    def test_duplicate_and_deep_json_refused(self):
        payload = json.dumps(self.command).replace('"action": "prepare"', '"action":"cancel","action":"prepare"').encode()
        self.assertFalse(self.run_command(payload)['ok'])
        self.assertFalse(self.run_command(b'[' * 600 + b'0' + b']' * 600)['ok'])
        self.assertFalse(self.run_command(b'\xff')['ok'])
        self.assertEqual(self.calls, [])


if __name__ == '__main__': unittest.main()
