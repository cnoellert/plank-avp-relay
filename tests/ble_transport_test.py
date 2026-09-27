# SPDX-License-Identifier: GPL-3.0-or-later
import sys
from pathlib import Path
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from ble_lab.transport import Indications
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


if __name__ == '__main__':
    unittest.main()
