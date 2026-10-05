# SPDX-License-Identifier: GPL-3.0-or-later
"""Real loopback sockets and Noise against the new TCP adapter/current core."""
import ctypes as C
import json
import os
from pathlib import Path
import socket
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch, MagicMock, PropertyMock

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
        # Loopback/fake-evdev tests must not claim the installed tablet lease.
        # Keep the real Linux exclusivity behavior in a test-only namespace.
        lease_address = patch('avp_relay.capture_lease.ADDRESS',
            b'\0plank-network-test-' + os.urandom(12).hex().encode())
        lease_address.start()
        self.addCleanup(lease_address.stop)
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
        self.capture_poll = patch.object(self.core.capture, 'poll')
        self.capture_poll.start()
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

    def read(self, sock, allow_closed=False):
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            self.pump()
            try:
                data = sock.recv(8192)
                if not data and not allow_closed:
                    self.fail('Network connection closed before the expected response')
                return data
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
            data = self.read(sock, allow_closed=True)
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
        for operation in ('status', 'scan', 'cancel', 'remove', 'network-status', 'network-mode', 'wifi-status', 'wifi-join', 'use-usb'):
            sock = self.socket(1)
            payload = json.dumps({'version': 1, 'id': 1, 'op': operation}).encode()
            record = len(payload).to_bytes(2, 'little') + payload
            for offset in range(0, len(record), 3):
                sock.sendall(record[offset:offset+3]); self.pump()
            reply = self.read(sock, allow_closed=operation != 'status')
            if operation == 'status':
                status = json.loads(reply[2:])
                self.assertEqual(status['relayKey'], self.core.native.public_key)
                self.assertNotIn('networkAddresses', status)
                self.assertNotIn('tcpPort', status)
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

    def test_handoff_version_status_survives_real_noise_and_tablet_validation(self):
        self.approve()
        sock, client, connected = self.connect()
        self.assertTrue(connected)
        self.core.read_drawing_handoff_v2 = MagicMock(return_value={'supported': True, 'state': 'unavailable',
                                                                  'reason': 'service.absent'})
        self.core.read_drawing_handoff = MagicMock(return_value={'supported': False, 'state': 'unsupported',
                                                               'reason': 'service.absent'})
        reply = self.request(sock, client, drawingHandoffVersion=2)
        self.assertTrue(reply['ok'], reply)
        self.assertTrue(reply['headsetAuthorized'])
        self.assertTrue(reply['drawingHandoff']['supported'])
        self.core.read_drawing_handoff_v2.assert_called_once_with()
        self.core.read_drawing_handoff.assert_not_called()
        self.assertFalse(self.request(sock, client, drawingHandoffVersion=True)['ok'])
        legacy = self.request(sock, client)
        self.assertTrue(legacy['ok'], legacy)
        self.assertFalse(legacy['drawingHandoff']['supported'])
        self.core.read_drawing_handoff.assert_called_once_with()

    def test_route_rendezvous_requires_authenticated_current_owner_without_capture(self):
        self.approve()
        self.core.network_endpoints = lambda: ['192.0.2.2']
        sock, client, connected = self.connect()
        self.assertTrue(connected)
        status = self.request(sock, client)
        self.assertEqual(status['networkAddresses'], ['192.0.2.2'])
        self.assertEqual(status['tcpPort'], self.server.port)
        self.assertFalse(self.core.native.observing)
        self.assertFalse(self.core.capture.attached)
        payload = json.dumps({'version': 1, 'id': 1, 'op': 'status'}).encode()
        other = json.loads(self.core.request(payload, 'other', authenticated=True))
        self.assertNotIn('networkAddresses', other)
        self.server.close()
        self.assertEqual(self.core.network_endpoints(), [])
        self.assertIsNone(self.core.tcp_port)

    def test_burst_of_reports_survives_noise_tcp_in_order(self):
        from avp_relay.capture import SAMPLE
        self.approve()
        sock, client, connected = self.connect()
        self.assertTrue(connected)
        self.send(sock, client, 13, b'\x01')
        frames = self.feed(sock, client, self.read(sock))
        while not any(kind == 14 for kind, _ in frames):
            frames += self.feed(sock, client, self.read(sock))
        expected = []
        for number in range(100):
            self.core.capture.axes = {0: number, 1: number * 2, 24: number * 7}
            self.core.capture.reports += 1
            data = self.core.capture.sample(1000000 + number * 5000)
            expected.append(data)
            self.core.capture.enqueue(data)
        received = []
        while len(received) < len(expected):
            received += [data for kind, data in self.feed(sock, client, self.read(sock)) if kind == 14]
        self.assertEqual(received, expected)
        self.assertEqual([SAMPLE.unpack(data)[4] for data in received],
                         [1000000 + n * 5000 for n in range(100)])

    def test_busy_capture_keeps_management_available_without_stealing_input(self):
        from avp_relay.capture import Capture
        from avp_relay.capture_lease import CaptureLease
        from avp_relay.gadget_client import unavailable
        self.approve()
        drawing = CaptureLease()
        self.addCleanup(drawing.release)
        self.assertTrue(drawing.acquire())
        patch.object(Capture, 'available', new_callable=PropertyMock, return_value=True).start()
        sock, client, connected = self.connect()
        self.assertTrue(connected)
        status = self.request(sock, client)
        self.assertTrue(status['headsetAuthorized'])
        self.assertTrue(status['attached'])
        self.assertTrue(status['captureBusy'])
        self.assertFalse(status['captureActive'])
        self.assertFalse(self.request(sock, client, 'scan')['ok'])
        self.assertIsNone(self.core.tablets.owner)
        self.assertFalse(self.core.capture.lease.held)
        self.core.gadget = MagicMock()
        self.core.gadget.request.return_value = dict(unavailable(), supported=True, phase='idle')
        self.assertTrue(self.request(sock, client, 'network-status')['ok'])
        self.assertTrue(drawing.held)
        drawing.release()
        self.assertFalse(self.request(sock, client)['captureBusy'])

    def test_observation_holds_capture_until_disconnect(self):
        from avp_relay.capture_lease import CaptureLease
        self.approve()
        drawing = CaptureLease()
        self.addCleanup(drawing.release)
        sock, client, connected = self.connect()
        self.assertTrue(connected)
        self.assertFalse(self.core.capture.lease.held)
        self.send(sock, client, 13, b'\x01')
        frames = []
        for _ in range(5):
            frames += self.feed(sock, client, self.read(sock))
            if any(kind == 14 for kind, _ in frames): break
        self.assertTrue(any(kind == 14 for kind, _ in frames))
        self.assertTrue(self.core.capture.lease.held)
        self.assertFalse(drawing.acquire())
        sock.close(); self.pump()
        self.assertIsNone(self.core.owner)
        self.assertFalse(self.core.capture.attached)
        self.assertFalse(self.core.capture.lease.held)
        self.assertTrue(drawing.acquire())

    def test_capture_race_closes_setup_without_releasing_drawing_owner(self):
        from avp_relay.capture_lease import CaptureLease
        self.approve()
        drawing = CaptureLease()
        self.addCleanup(drawing.release)
        sock, client, connected = self.connect()
        self.assertTrue(connected)
        self.assertFalse(self.request(sock, client)['captureBusy'])
        self.assertTrue(drawing.acquire())  # Ownership changes after status.
        self.send(sock, client, 13, b'\x01')
        self.assertEqual(self.read(sock, allow_closed=True), b'')
        self.assertIsNone(self.core.owner)
        self.assertFalse(self.core.capture.lease.held)
        self.assertFalse(self.core.capture.attached)
        self.assertTrue(drawing.held)
        self.assertTrue(self.core.native.has_clients)

    def test_paced_200_report_source_through_capture_and_noise_tcp(self):
        from avp_relay.capture import SAMPLE, EVENT
        self.approve()
        sock, client, connected = self.connect()
        self.assertTrue(connected)
        self.send(sock, client, 13, b'\x01')
        frames = self.feed(sock, client, self.read(sock))
        while not any(kind == 14 for kind, _ in frames):
            frames += self.feed(sock, client, self.read(sock))
        self.capture_poll.stop()
        capture = self.core.capture
        patch.object(capture, 'discover').start()
        reader, writer = os.pipe2(os.O_NONBLOCK | os.O_CLOEXEC)
        self.addCleanup(os.close, writer)
        capture.nodes[reader] = ('pen', [])
        capture.selector.register(reader, 1)
        capture.ranges = {0: (0, 10000), 1: (0, 10000), 24: (0, 8191)}
        start = time.monotonic()
        received, delays = [], []
        for number in range(1, 201):
            time.sleep(max(0, start + number / 200 - time.monotonic()))
            timestamp = time.monotonic_ns() // 1000
            events = [(3, 0, number), (3, 24, number * 10), (0, 0, 0)]
            os.write(writer, b''.join(EVENT.pack(timestamp // 1000000, timestamp % 1000000, *event)
                                      for event in events))
            # Emulate the installed 10ms event-loop cadence, preserving two
            # reports per tick, through actual sockets and Noise encryption.
            if number % 2 == 0:
                for kind, data in self.feed(sock, client, self.read(sock)):
                    if kind == 14:
                        sample = SAMPLE.unpack(data)
                        received.append(sample)
                        delays.append(time.monotonic_ns() / 1000 - sample[4])
        # A byte stream can split the final records across SDUs/reads.
        while len(received) < 200:
            for kind, data in self.feed(sock, client, self.read(sock)):
                if kind == 14:
                    sample = SAMPLE.unpack(data)
                    received.append(sample)
                    delays.append(time.monotonic_ns() / 1000 - sample[4])
        self.assertEqual([sample[5] for sample in received], list(range(1, 201)))
        self.assertEqual([sample[7] for sample in received], [n * 10 for n in range(1, 201)])
        elapsed = time.monotonic() - start
        print(f'Synthetic evdev/Noise {self.core.owner.split(":")[0]}: {len(received)} reports, {len(received)/elapsed:.1f}/s; '
              f'local input-to-decode mean {sum(delays)/len(delays)/1000:.2f} ms, '
              f'max {max(delays)/1000:.2f} ms. Not a hardware/AVP measurement.')

    def test_usb_setup_and_pressure_over_noise_tcp_without_bluetooth(self):
        from avp_relay.capture import Capture, SAMPLE, usb_identifier
        self.backend.available = False
        self.backend.items = {}
        identity = ('usb:/sys/devices/usb1/1-2', '', 3)
        target = usb_identifier(identity)
        self.core.capture.identity = identity
        self.core.capture.usb_tablets = [dict(id=target, name='Wacom USB', serial='sample', port='1-2')]
        patch.object(Capture, 'attached', new_callable=PropertyMock, return_value=True).start()
        def select_usb(value):
            self.assertEqual(value, target)  # Simulated hardware readiness; real Noise/socket below.
        self.core.tablets.select_usb = select_usb
        self.core.capture.axes = {0: 1234, 1: 2345, 24: 4567}
        self.core.capture.ranges = {0: (0, 44800), 1: (0, 29600), 24: (0, 8191)}
        self.core.capture.keys = {320, 330}
        sock, client, connected = self.connect()
        self.assertTrue(connected)
        status = self.request(sock, client)
        self.assertFalse(status['bluetoothAvailable'])
        self.assertTrue(status['usbTablets'][0]['active'])
        self.assertFalse(status['headsetAuthorized'])
        self.assertTrue(self.request(sock, client, 'use-usb', target)['ok'])
        self.assertTrue(self.request(sock, client)['headsetAuthorized'])
        sock.close(); self.pump()
        sock, client, connected = self.connect()
        self.assertTrue(connected)
        self.send(sock, client, 13, b'\x01')
        frames = []
        for _ in range(5):
            frames += self.feed(sock, client, self.read(sock))
            if any(kind == 14 for kind, _ in frames): break
        sample = next(SAMPLE.unpack(data) for kind, data in frames if kind == 14)
        self.assertEqual(sample[5:8], (1234, 2345, 4567))
        self.assertTrue(sample[1] & 1)
        self.assertEqual(json.loads((self.path/'paired-clients.json').read_text())['clients'], [self.client_public])

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

    def test_wifi_commands_require_approved_noise_and_do_not_echo_password(self):
        from avp_relay.wifi_protocol import unavailable
        self.core.wifi = MagicMock()
        self.core.wifi.request.return_value = dict(unavailable(), supported=True, phase='applying')
        command = dict(network=None, ssid='Example', security='personal', password='test-password',
                       requestID='0e0f733e-ce3f-4a72-8272-e33cd37d165b')
        sock, client, connected = self.connect()
        self.assertTrue(connected)
        self.assertFalse(self.request(sock, client, 'wifi-join', **command)['ok'])
        self.core.wifi.request.assert_not_called()
        sock.close(); self.pump(); self.approve()
        sock, client, connected = self.connect()
        self.assertTrue(connected)
        reply = self.request(sock, client, 'wifi-join', **command)
        self.assertTrue(reply['ok'])
        self.assertNotIn(command['password'], json.dumps(reply))
        self.core.wifi.request.assert_called_once_with(dict(op='wifi-join', **command))
        self.core.wifi.request.reset_mock()
        self.assertFalse(self.request(sock, client, 'wifi-status', password='forbidden-extra-field')['ok'])
        self.core.wifi.request.assert_not_called()

    def test_wifi_status_supplies_actual_listener_port_only_after_authorization(self):
        from avp_relay.wifi_protocol import unavailable
        self.core.wifi = MagicMock()
        self.core.wifi.request.return_value = dict(unavailable(), supported=True, enabled=True,
            phase='idle', connection='connected', addresses=['192.0.2.18'])
        sock, client, connected = self.connect()
        self.assertTrue(connected)
        reply = self.request(sock, client, 'wifi-status')
        self.assertFalse(reply['ok'])
        self.assertNotIn('tcpPort', reply)
        self.core.wifi.request.assert_not_called()
        sock.close(); self.pump(); self.approve()
        sock, client, connected = self.connect()
        self.assertTrue(connected)
        reply = self.request(sock, client, 'wifi-status')
        self.assertTrue(reply['ok'])
        self.assertEqual(reply['addresses'], ['192.0.2.18'])
        self.assertEqual(reply['tcpPort'], self.server.port)
        self.assertEqual(self.core.tcp_port, self.server.port)
        self.server.close()
        self.assertIsNone(self.core.tcp_port)

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


class L2CAPTests(unittest.TestCase):
    """Real sequenced-packet sockets, capture and Noise; no radio claim."""
    setUp = NetworkTests.setUp
    approve = NetworkTests.approve
    pump = NetworkTests.pump
    read = NetworkTests.read
    feed = NetworkTests.feed
    send = NetworkTests.send
    request = NetworkTests.request
    test_echo = NetworkTests.test_three_bidirectional_echo_roundtrips_without_tablet
    test_report_order = NetworkTests.test_burst_of_reports_survives_noise_tcp_in_order
    test_paced_reports = NetworkTests.test_paced_200_report_source_through_capture_and_noise_tcp
    test_usb_input = NetworkTests.test_usb_setup_and_pressure_over_noise_tcp_without_bluetooth
    test_authorized_network_controls = NetworkTests.test_network_mode_requires_approved_noise_identity
    test_authorized_wifi_controls = NetworkTests.test_wifi_commands_require_approved_noise_and_do_not_echo_password
    test_tablet_enrollment = NetworkTests.test_new_tablet_commits_only_provisional_network_owner
    test_backpressure = NetworkTests.test_idle_probe_and_backpressure_release_only_their_connection
    test_busy_capture_management = NetworkTests.test_busy_capture_keeps_management_available_without_stealing_input
    test_capture_ownership = NetworkTests.test_observation_holds_capture_until_disconnect
    test_capture_race = NetworkTests.test_capture_race_closes_setup_without_releasing_drawing_owner
    test_authenticated_routes = NetworkTests.test_route_rendezvous_requires_authenticated_current_owner_without_capture

    def socket(self, channel):
        from avp_relay.l2cap import L2CAPConnection, PREFACE, BT_SNDMTU, BT_RCVMTU
        import struct
        # Exercise production SDU boundaries on a real socket. The only stub is
        # the two Bluetooth-specific MTU queries unavailable on AF_UNIX.
        class Socket:
            def __init__(self, sock): self.sock = sock
            def __getattr__(self, name): return getattr(self.sock, name)
            def getsockopt(self, level, option, size):
                assert option in (BT_SNDMTU, BT_RCVMTU) and size == 2
                return struct.pack('H', 255 if option == BT_SNDMTU else 4096)
        client, peer = socket.socketpair(socket.AF_UNIX, socket.SOCK_SEQPACKET)
        self.addCleanup(client.close)
        client.settimeout(0.05)
        connection = L2CAPConnection(self.server, Socket(peer))
        self.server.connections.add(connection)
        self.l2cap_connection = connection
        for byte in PREFACE + bytes([channel]):
            client.sendall(bytes([byte]))
            self.pump()
        return client

    def connect(self, transport=1, private=None):
        return NetworkTests.connect(self, transport, private)

    def test_preserves_bluetooth_noise_identity_and_rejects_wrong_transcript(self):
        self.approve()
        for transport, private in ((1, bytes(range(1, 33))), (2, self.private)):
            sock, client, connected = self.connect(transport, private)
            self.assertFalse(connected)
            sock.close(); self.pump()
        sock, client, connected = self.connect()
        self.assertTrue(connected)
        self.assertTrue(self.core.owner.startswith('l2cap:'))
        self.assertTrue(self.request(sock, client)['headsetAuthorized'])
        with self.assertRaises(ProtocolError):
            self.core.claim('tcp:other', 2, lambda _: None, lambda: False, lambda: None)
        self.assertTrue(self.request(sock, client)['headsetAuthorized'])

    def test_truncated_sdu_closes_only_its_channel(self):
        sock = self.socket(2)
        sock.sendall(bytes(4097))
        self.pump()
        self.assertTrue(self.l2cap_connection.closed)
        self.assertIsNone(self.core.owner)
        self.assertEqual(sock.recv(1), b'')
        self.assertIsNotNone(self.core.tcp_port)

    def test_credit_stall_defers_write_without_loss(self):
        sock = self.socket(2)
        connection = self.l2cap_connection
        with patch.object(connection.sock, 'send', side_effect=BlockingIOError):
            connection.append(bytes(range(256)) * 4)
            self.assertEqual(len(connection.output), 1024)
            self.assertFalse(connection.closed)
        connection.flush()
        received = bytearray()
        while len(received) < 1024:
            received.extend(sock.recv(4096))
        self.assertEqual(received, bytes(range(256)) * 4)
        self.assertFalse(connection.output)


if __name__ == '__main__': unittest.main()
