# SPDX-License-Identifier: GPL-3.0-or-later
import sys
import os
import time
from pathlib import Path
import unittest
from unittest.mock import patch, MagicMock
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from avp_relay.transport import EchoChannel, Indications
from avp_relay.capture import Capture, SAMPLE, EVENT
from avp_relay.core import RelayCore


class CaptureTests(unittest.TestCase):
    def setUp(self):
        # Report-processing fixtures must never claim a real drawing session.
        lease = MagicMock()
        lease.acquire.return_value = True
        self.capture = Capture(lease=lease)
        self.addCleanup(self.capture.close)
        self.read, self.write = os.pipe2(os.O_NONBLOCK | os.O_CLOEXEC)
        self.addCleanup(os.close, self.write)
        self.capture.nodes[self.read] = ('pen', [])
        self.capture.selector.register(self.read, 1)
        self.capture.ranges = {0: (0, 10000), 1: (0, 10000), 24: (0, 8191)}
        self.capture.keys = {320}
        self.capture.observe(True)
        self.discover = patch.object(self.capture, 'discover').start()
        self.addCleanup(patch.stopall)

    def events(self, values, timestamp=1234000):
        os.write(self.write, b''.join(EVENT.pack(timestamp // 1000000, timestamp % 1000000, *event)
                                     for event in values))
        self.capture.poll()

    def test_keeps_positions_pressure_and_tip_edges_within_one_poll(self):
        self.events([(3, 0, 100), (3, 24, 200), (1, 330, 1), (0, 0, 0),
                     (3, 0, 200), (3, 24, 700), (0, 0, 0),
                     (1, 330, 0), (3, 24, 0), (0, 0, 0)])
        samples = [SAMPLE.unpack(data) for data in self.capture.take_samples()]
        self.assertEqual([s[5] for s in samples], [100, 200, 200])
        self.assertEqual([s[7] for s in samples], [200, 700, 0])
        self.assertEqual([bool(s[1] & 4) for s in samples], [True, True, False])
        self.assertEqual([s[4] for s in samples], [1234000] * 3)
        self.assertEqual([s[18] for s in samples], [1, 2, 3])

    def test_partial_report_cannot_leak_into_snapshot(self):
        self.events([(3, 0, 999), (3, 24, 1000)])
        self.assertEqual(self.capture.take_samples(), [])
        self.assertEqual(SAMPLE.unpack(self.capture.sample())[5:8], (0, 0, 0))
        self.events([(3, 1, 777), (0, 0, 0)], timestamp=1235000)
        sample = SAMPLE.unpack(self.capture.take_samples()[0])
        self.assertEqual(sample[4:8], (1235000, 999, 777, 1000))

    def test_inactive_capture_does_not_accumulate_or_replay_reports(self):
        self.capture.observe(False)
        self.events([(3, 0, 100), (0, 0, 0)])
        self.assertFalse(self.capture.pending)
        self.capture.observe(True)
        self.events([(3, 0, 200), (0, 0, 0)])
        self.assertEqual(len(self.capture.pending), 1)
        self.capture.observe(False)
        self.assertFalse(self.capture.pending)

    def test_overflow_and_slow_consumer_fail_without_coalescing(self):
        for _ in range(256): self.capture.enqueue(self.capture.sample())
        with self.assertRaises(BufferError): self.capture.enqueue(self.capture.sample())
        self.assertEqual(len(self.capture.pending), 256)
        with patch('avp_relay.capture.time.monotonic', return_value=time.monotonic() + 1):
            with self.assertRaises(BufferError): self.capture.check_pending()
        self.capture.observe(False)
        self.assertFalse(self.capture.pending)

    def test_syn_dropped_discards_partial_state_and_releases_contacts(self):
        self.events([(3, 0, 99), (0, 3, 0)])
        self.assertFalse(self.capture.attached)
        self.assertEqual(self.capture.dropped, 1)
        self.assertFalse(self.capture.frames)
        self.assertEqual(SAMPLE.unpack(self.capture.sample())[1], 0)

    def test_core_sends_all_reports_without_fifty_millisecond_gate(self):
        self.events([(3, 0, 100), (0, 0, 0), (3, 0, 200), (0, 0, 0)])
        core = RelayCore.__new__(RelayCore)
        core.capture = self.capture
        core.owner = 'test'
        core.tablets = MagicMock()
        core.native = MagicMock()
        core.native.observing = True
        core.native.tick.return_value = b''
        core.native.sample.side_effect = lambda value: value
        core.busy = lambda: False
        core.emit = MagicMock()
        core.close_connection = MagicMock()
        core.last_sample = time.monotonic()  # Previously prevented sending.
        core.tick()
        self.assertEqual(core.native.sample.call_count, 2)
        self.assertEqual(len(core.emit.call_args.args[0]), 160)
        core.close_connection.assert_not_called()


class TransportTests(unittest.TestCase):
    def test_fragment_ack_and_record_order(self):
        emitted = []
        queue = Indications(emitted.append)
        first, second = bytes(range(150)), bytes(range(100))
        queue.append(first)
        queue.append(second)
        self.assertEqual(len(emitted), 1)
        while queue.busy:
            queue.confirm()
        self.assertEqual(b''.join(emitted), first + second)
        self.assertTrue(all(len(fragment) <= 20 for fragment in emitted))

    def test_overflow_fails_without_discarding_pending_records(self):
        queue = Indications(lambda _: None, limit=30)
        queue.append(bytes(30))
        with self.assertRaises(BufferError):
            queue.append(bytes(31))
        self.assertEqual(queue.total, 10)
        queue.clear()
        self.assertFalse(queue.busy)

    def test_disconnected_snapshot_clears_pressed_state(self):
        capture = Capture()
        capture.keys = {320, 330}
        capture.pad_mask = 255
        capture.contacts = {0: True}
        capture.close_nodes()
        sample = SAMPLE.unpack(capture.sample())
        self.assertEqual(sample[1:3], (0, 0))
        self.assertEqual(sample[-2], 0)
        capture.close()

    def test_echo_without_tablet_or_pairing_and_fragment_ack(self):
        emitted, closed = [], []
        echo = EchoChannel(emitted.append, closed.append)
        echo.notifying = True
        options = {'device': '/org/bluez/hci0/dev_TEST', 'link': 'LE', 'type': 'request', 'mtu': 23}
        payload = bytes(range(256)) * 4
        for start in range(0, len(payload), 244):
            echo.receive(payload[start:start + 244], options, '/org/bluez/hci0')
        self.assertEqual(len(emitted), 1, 'Only one indication may be in flight')
        while echo.queue.busy:
            echo.queue.confirm()
        self.assertEqual(b''.join(emitted), payload)
        self.assertTrue(all(len(part) <= 20 for part in emitted))
        self.assertEqual(echo.received, 1024)
        echo.disconnect()
        self.assertEqual(closed, [options['device']])
        self.assertEqual(echo.received, 0)
        self.assertFalse(echo.queue.busy)

    def test_echo_rejects_other_peer_and_active_authenticated_operation(self):
        echo = EchoChannel(lambda _: None, lambda _: None)
        options = {'device': '/org/bluez/hci0/dev_TEST', 'link': 'LE'}
        with self.assertRaises(ValueError):
            echo.receive(b'x', options, '/org/bluez/hci0')  # No subscription.
        echo.notifying = True
        with self.assertRaises(ValueError):
            echo.receive(b'x', options, '/org/bluez/hci0', other_peer=options['device'])
        self.assertIsNone(echo.peer)
        echo.receive(b'x', options, '/org/bluez/hci0')
        for changes in ({'device': '/org/bluez/hci0/dev_OTHER'}, {'link': 'BR/EDR'},
                        {'offset': 1}, {'type': 'command'}):
            with self.assertRaises(ValueError):
                echo.receive(b'x', {**options, **changes}, '/org/bluez/hci0')
        self.assertEqual(echo.received, 1)

    def test_echo_byte_and_time_limits(self):
        echo = EchoChannel(lambda _: None, lambda _: None)
        echo.notifying = True
        options = {'device': '/org/bluez/hci0/dev_TEST', 'link': 'LE'}
        for _ in range(8):
            echo.receive(bytes(512), options, '/org/bluez/hci0')
            while echo.queue.busy:
                echo.queue.confirm()
        with self.assertRaises(BufferError):
            echo.receive(b'x', options, '/org/bluez/hci0')
        echo.started -= 31
        with self.assertRaises(TimeoutError):
            echo.tick()


if __name__ == '__main__':
    unittest.main()
