# SPDX-License-Identifier: GPL-3.0-or-later
"""Real loopback sockets and Noise against the new TCP adapter/current core."""
import ctypes as C
import json
from pathlib import Path
import socket
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch, MagicMock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from avp_relay.core import RelayCore
from avp_relay.network import TCPServer, PREFACE, MAX_PENDING
from avp_relay.native import ProtocolError
from avp_relay.discovery import Publisher
from tablet_enrollment_test import Backend, FIRST, UUID

LIBRARY, CLIENT = sys.argv[1:3]
del sys.argv[1:3]
codec = C.CDLL(CLIENT)
for name, args, result in (
    ('create', [C.c_void_p, C.c_void_p, C.c_uint8], C.c_void_p),
    ('destroy', [C.c_void_p], None),
    ('enable_input_observer', [C.c_void_p], C.c_int),
    ('enable_tablet_management', [C.c_void_p], C.c_int),
    ('peer_version', [C.c_void_p], C.c_char_p),
    ('start', [C.c_void_p, C.c_void_p, C.c_size_t, C.POINTER(C.c_size_t)], C.c_int),
    ('send', [C.c_void_p, C.c_uint16, C.c_void_p, C.c_size_t, C.c_void_p, C.c_size_t, C.POINTER(C.c_size_t)], C.c_int),
    ('receive', [C.c_void_p, C.c_void_p, C.c_size_t, C.POINTER(C.c_size_t), C.c_void_p,
                 C.c_size_t, C.POINTER(C.c_size_t), C.POINTER(C.c_uint16), C.c_void_p,
                 C.c_size_t, C.POINTER(C.c_size_t)], C.c_int)):
    fn = getattr(codec, 'pltr_client_link_' + name)
    fn.argtypes, fn.restype = args, result
codec.crypto_scalarmult_curve25519_base.argtypes = [C.c_void_p, C.c_void_p]


class NetworkTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name)
        self.backend = Backend()
        self.private = bytes(range(32))
        key = C.create_string_buffer(32)
        self.assertEqual(codec.crypto_scalarmult_curve25519_base(key, self.private), 0)
        self.client_public = key.raw.hex()
        self.args = SimpleNamespace(library=LIBRARY, state_dir=self.path, tablet='')
        self.core = RelayCore(self.args, self.backend)
        self.server = TCPServer(self.core, 0, host='127.0.0.1')
        self.addCleanup(lambda: self.core.close())
        self.addCleanup(lambda: self.server.close())
        self.addCleanup(patch.stopall)
        patch.object(self.core.capture, 'poll').start()
        self.request_id = 0

    def approve(self):
        self.core.native.close()
        (self.path / 'paired-clients.json').write_text(json.dumps({'version': 1, 'clients': [self.client_public]}, separators=(',', ':')))
        (self.path / 'paired-clients.json').chmod(0o600)
        self.core.native = __import__('avp_relay.native', fromlist=['Native']).Native(LIBRARY, self.path)
        self.core.native.on_management = lambda data: self.core.request(data, self.core.owner,
            self.core.native.management_authorized, self.core.native.enrolling)

    def pump(self):
        for _ in range(4):
            self.server.poll()
            self.core.tick()

    def socket(self, channel):
        sock = socket.create_connection(('127.0.0.1', self.server.port), timeout=1)
        sock.settimeout(0.05)
        self.addCleanup(sock.close)
        for byte in PREFACE + bytes([channel]):
            sock.sendall(bytes([byte]))
            self.pump()
        return sock

    def read(self, sock):
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            self.pump()
            try: return sock.recv(8192)
            except socket.timeout: pass
        self.fail('Socket did not produce a bounded response')

    def connect(self, transport=2, private=None):
        client = codec.pltr_client_link_create(private or self.private, bytes.fromhex(self.core.native.public_key), transport)
        self.assertTrue(client)
        self.addCleanup(codec.pltr_client_link_destroy, client)
        self.assertEqual(codec.pltr_client_link_enable_input_observer(client), 0)
        self.assertEqual(codec.pltr_client_link_enable_tablet_management(client), 0)
        sock = self.socket(0)
        out, size = C.create_string_buffer(8448), C.c_size_t()
        self.assertEqual(codec.pltr_client_link_start(client, out, len(out), C.byref(size)), 0)
        data = out.raw[:size.value]
        for offset in range(0, len(data), 7):
            sock.sendall(data[offset:offset+7]); self.pump()
        while not codec.pltr_client_link_peer_version(client):
            data = self.read(sock)
            if not data: return sock, client, False
            self.feed(sock, client, data)
        return sock, client, True

    def feed(self, sock, client, data):
        frames = []
        for start in range(0, len(data), 11):
            part = data[start:start+11]
            while part:
                used, size, payload_size, kind = C.c_size_t(), C.c_size_t(), C.c_size_t(), C.c_uint16()
                out, payload = C.create_string_buffer(8448), C.create_string_buffer(8192)
                result = codec.pltr_client_link_receive(client, part, len(part), C.byref(used),
                    out, len(out), C.byref(size), C.byref(kind), payload, len(payload), C.byref(payload_size))
                self.assertGreaterEqual(result, 0)
                self.assertGreater(used.value, 0)
                part = part[used.value:]
                if size.value: sock.sendall(out.raw[:size.value])
                if kind.value == 10: self.send(sock, client, 11, payload.raw[:16] + bytes(16))
                elif kind.value: frames.append((kind.value, payload.raw[:payload_size.value]))
        return frames

    def send(self, sock, client, kind, payload):
        out, size = C.create_string_buffer(8448), C.c_size_t()
        self.assertEqual(codec.pltr_client_link_send(client, kind, payload, len(payload), out, len(out), C.byref(size)), 0)
        sock.sendall(out.raw[:size.value])

    def request(self, sock, client, op='status', tablet=None, **fields):
        self.request_id += 1
        payload = json.dumps({'version': 1, 'id': self.request_id, 'op': op, **({'tablet': tablet} if tablet else {}), **fields}).encode()
        self.send(sock, client, 48, payload)
        for _ in range(10):
            for kind, data in self.feed(sock, client, self.read(sock)):
                if kind == 49: return json.loads(data)
        self.fail('No authenticated management response')

    def test_public_identity_and_no_public_mutations(self):
        for operation in ('status', 'scan', 'cancel', 'remove', 'network-status', 'network-mode'):
            sock = self.socket(1)
            payload = json.dumps({'version': 1, 'id': 1, 'op': operation}).encode()
            record = len(payload).to_bytes(2, 'little') + payload
            for offset in range(0, len(record), 3):
                sock.sendall(record[offset:offset+3]); self.pump()
            reply = self.read(sock)
            if operation == 'status':
                self.assertEqual(json.loads(reply[2:])['relayKey'], self.core.native.public_key)
            else: self.assertEqual(reply, b'')
            self.assertIsNone(self.core.owner)

    def test_three_bidirectional_echo_roundtrips_without_tablet(self):
        sock = self.socket(2)
        for count in (64, 512, 1024):
            data = bytes(n % 256 for n in range(count)); sock.sendall(data)
            result = bytearray()
            while len(result) < count: result.extend(self.read(sock))
            self.assertEqual(result, data)
        self.assertIsNone(self.core.owner)
        self.assertFalse(self.core.native.has_clients)

    def test_authorized_noise_management_and_input(self):
        self.approve()
        sock, client, connected = self.connect()
        self.assertTrue(connected)
        self.assertTrue(self.request(sock, client)['headsetAuthorized'])
        with self.assertRaises(ProtocolError): self.core.native.transport(1)
        self.send(sock, client, 13, b'\x01')
        frames = self.feed(sock, client, self.read(sock))
        for _ in range(5):
            if any(kind == 14 for kind, _ in frames): break
            frames += self.feed(sock, client, self.read(sock))
        self.assertTrue(any(kind == 14 and len(data) == 80 for kind, data in frames))
        # A competing BLE connection never resets the owner or gets input.
        owner = self.core.owner
        with self.assertRaises(ProtocolError):
            self.core.claim('ble:other', 1, lambda _: None, lambda: False, lambda: None)
        self.assertEqual(self.core.owner, owner)
        sock.close(); self.pump()
        self.assertIsNone(self.core.owner)

    def test_network_mode_requires_approved_noise_identity(self):
        from avp_relay.gadget_client import unavailable
        self.core.gadget = MagicMock()
        self.core.gadget.request.return_value = dict(unavailable(), supported=True, phase='applying')
        sock, client, connected = self.connect()
        self.assertTrue(connected)  # Provisional tablet setup is allowed.
        command = dict(mode='router', requestID='0e0f733e-ce3f-4a72-8272-e33cd37d165b')
        self.assertFalse(self.request(sock, client, 'network-mode', **command)['ok'])
        self.core.gadget.request.assert_not_called()
        sock.close(); self.pump()
        self.approve()
        sock, client, connected = self.connect()
        self.assertTrue(connected)
        self.assertTrue(self.request(sock, client, 'network-mode', **command)['ok'])
        self.core.gadget.request.assert_called_once_with(dict(op='network-mode', **command))

    def test_owned_relay_rejects_stranger_and_wrong_transport(self):
        self.approve()
        for transport, private in ((2, bytes(range(1, 33))), (1, self.private)):
            sock, client, connected = self.connect(transport, private)
            self.assertFalse(connected)
            sock.close(); self.pump()
            self.assertTrue(self.core.native.has_clients)

    def test_new_tablet_commits_only_provisional_network_owner(self):
        sock, client, connected = self.connect()
        self.assertTrue(connected)
        self.assertFalse(self.request(sock, client)['headsetAuthorized'])
        self.assertTrue(self.request(sock, client, 'scan')['ok'])
        self.assertTrue(self.request(sock, client, 'pair', FIRST)['ok'])
        self.backend.pair_done()
        self.backend.connect_done()
        self.backend.items[FIRST].update(Modalias='usb:v056Ap1234', UUIDs=[UUID],
            Paired=True, Bonded=True, Connected=True, ServicesResolved=True)
        self.core.tablets.last_poll = 0
        self.core.tick()
        self.assertTrue(self.core.native.has_clients)
        self.assertTrue(self.request(sock, client)['headsetAuthorized'])
        self.assertFalse(self.core.native.observing)
        clients = json.loads((self.path/'paired-clients.json').read_text())
        self.assertEqual(clients['clients'], [self.client_public])

    def test_idle_probe_and_backpressure_release_only_their_connection(self):
        sock = self.socket(1)
        connection = next(iter(self.server.connections))
        with self.assertRaises(BufferError): connection.append(bytes(MAX_PENDING+1))
        connection.started -= 6; self.pump()
        self.assertEqual(sock.recv(1), b'')
        self.assertIsNone(self.core.owner)

    def test_network_listener_does_not_depend_on_bluez_advertising(self):
        self.core.tablets.message = 'Bluetooth unavailable'
        sock = self.socket(2); sock.sendall(b'network remains available')
        self.assertEqual(self.read(sock), b'network remains available')

    def test_avahi_restart_and_removal_cleanup(self):
        bus, server, group = MagicMock(), MagicMock(), MagicMock()
        server.EntryGroupNew.return_value = '/group'
        group.GetState.return_value = 2
        with patch('avp_relay.discovery.dbus.Interface', side_effect=lambda _, name: server if name.endswith('.Server') else group):
            publisher = Publisher(bus, 28991, 'ab'*32, '0.3.0')
            publisher.tick(); group.Commit.assert_called_once()
            publisher.changed('', ':old', ':new'); publisher.tick()
            self.assertEqual(group.Commit.call_count, 2)
            publisher.close(); group.Free.assert_called_once()


if __name__ == '__main__': unittest.main()
