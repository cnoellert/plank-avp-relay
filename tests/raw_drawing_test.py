# SPDX-License-Identifier: GPL-3.0-or-later
import errno
import itertools
import os
from pathlib import Path
import selectors
import socket
import sys
import time
import unittest
from unittest.mock import Mock, patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from avp_relay.l2cap import L2CAPConnection
from avp_relay.network import Connection, MAX_PENDING
from avp_relay.native import ProtocolError
from avp_relay.raw_drawing import RawDrawingBridge


class SimulatedLE(L2CAPConnection):
    def configure_socket(self):
        self.send_mtu = 247
        self.receive_mtu = 4096
    def read_chunk(self):
        return self.sock.recv(4096)


@unittest.skipUnless(sys.platform == 'linux', 'abstract sockets and SO_PEERCRED require Linux')
class BridgeTests(unittest.TestCase):
    def setUp(self):
        self.name = 'plank-raw-test-' + str(os.getpid()) + '-' + str(time.monotonic_ns())
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.listener.bind('\0' + self.name); self.listener.listen(1)
        self.server = Mock()
        self.server.selector = selectors.DefaultSelector()
        self.server.identifiers = itertools.count()
        self.server.connections = set()
        self.core = self.server.core
        self.left, peer = socket.socketpair(socket.AF_UNIX, socket.SOCK_SEQPACKET)
        self.left.settimeout(1)
        self.owner = SimulatedLE(self.server, peer)
        self.server.connections.add(self.owner)
        self.bridge = RawDrawingBridge(self.owner, name=self.name, resolve=lambda: (os.getuid(), None))
        self.owner.channel = 3; self.owner.raw_bridge = self.bridge
        self.raw, _ = self.listener.accept(); self.raw.settimeout(1)
        self.addCleanup(self.cleanup)
    def cleanup(self):
        self.owner.close(); self.left.close(); self.raw.close(); self.listener.close()
        self.server.selector.close()
    def pump(self, rounds=20):
        for _ in range(rounds):
            for key, events in self.server.selector.select(0.001):
                key.data.ready(events)
    def test_bidirectional_bytes_and_no_capture(self):
        incoming = bytes(range(256)) * 32  # larger than either MTU
        for offset in range(0, len(incoming), 1024):
            self.left.send(incoming[offset:offset+1024])
        self.pump()
        output = bytearray()
        while len(output) < len(incoming): output.extend(self.raw.recv(16384))
        self.assertEqual(bytes(output), incoming)
        reply = incoming[::-1]; self.raw.sendall(reply); self.pump()
        output.clear()
        while len(output) < len(reply): output.extend(self.left.recv(4096))
        self.assertEqual(bytes(output), reply)
        self.core.claim.assert_not_called(); self.core.receive.assert_not_called()
        self.core.release.assert_not_called()
    def test_fragmented_l2cap_preface_selects_raw_not_setup_or_echo(self):
        self.owner.channel = None; self.owner.raw_bridge = None
        with patch('avp_relay.l2cap.RawDrawingBridge', return_value=self.bridge) as factory:
            self.owner.receive(b'PLTR')
            factory.assert_not_called()
            self.owner.receive(b'LEC1\x03opaque-noise')
            factory.assert_called_once_with(self.owner)
        self.pump()
        self.assertEqual(self.raw.recv(4096), b'opaque-noise')
        self.core.claim.assert_not_called()

    def test_eof_drains_already_received_output_before_close(self):
        self.bridge.ready(selectors.EVENT_WRITE)
        self.owner.output.extend(b'final-status')
        self.raw.close()
        self.bridge.ready(selectors.EVENT_READ)
        self.assertFalse(self.owner.closed)
        self.assertFalse(self.bridge.readable())
        self.owner.flush()
        self.assertEqual(self.left.recv(4096), b'final-status')
        self.bridge.tick(time.monotonic())
        self.assertTrue(self.owner.closed)

    def test_wrong_server_uid_receives_no_authenticated_bytes(self):
        self.bridge.uid = os.getuid() + 1
        self.bridge.append(b'private-handshake')
        self.pump()
        self.assertTrue(self.owner.closed)
        self.assertEqual(self.raw.recv(4096), b'')
    def test_input_backpressure_and_resumption(self):
        self.bridge.pending.extend(bytes(MAX_PENDING))
        self.owner.update_events()
        self.assertNotIn(self.owner.sock.fileno(), self.server.selector.get_map())
        self.bridge.ready(selectors.EVENT_WRITE)
        self.assertIn(self.owner.sock.fileno(), self.server.selector.get_map())
        self.assertEqual(self.raw.recv(MAX_PENDING), bytes(MAX_PENDING))
    def test_output_backpressure_and_resumption(self):
        self.bridge.ready(selectors.EVENT_WRITE)
        self.owner.output.extend(bytes(MAX_PENDING))
        self.bridge.update_events()
        self.assertNotIn(self.bridge.sock.fileno(), self.server.selector.get_map())
        self.owner.output.clear(); self.bridge.update_events()
        self.assertEqual(self.server.selector.get_key(self.bridge.sock).events, selectors.EVENT_READ)
    def test_bound_and_stall_close_both_sides(self):
        self.bridge.append(bytes(MAX_PENDING))
        with self.assertRaises(BufferError): self.bridge.append(b'x')
        self.bridge.tick(self.bridge.progress + 11)
        self.assertTrue(self.owner.closed); self.assertTrue(self.bridge.closed)
    def test_eof_closes_bluetooth(self):
        self.raw.close(); self.pump(); self.assertTrue(self.owner.closed)
    def test_tcp_rejects_raw_channel(self):
        # Preserve the published TCP setup protocol. Raw bridge is LE-only.
        with self.assertRaises(ProtocolError):
            self.reject_tcp()
    def reject_tcp(self):
        a, b = socket.socketpair()
        class PlainTCP(Connection):
            def configure_socket(self): pass
        connection = PlainTCP(self.server, b)
        try: connection.receive(b'PLTRTCP1\x03')
        finally: connection.close(); a.close()

if __name__ == '__main__': unittest.main()
