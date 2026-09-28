# SPDX-License-Identifier: GPL-3.0-or-later
import sys
from pathlib import Path
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from ble_lab.transport import EchoChannel, Indications
from ble_lab.capture import Capture, SAMPLE


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
