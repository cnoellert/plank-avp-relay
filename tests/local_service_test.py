# SPDX-License-Identifier: GPL-3.0-or-later
"""Exercise cached reads, serialized durable mutations and reply-before-apply."""
from pathlib import Path
import threading
import time
import unittest
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from avp_relay.local_service import ControllerWorker


class Controller:
    poll_interval = 0.02
    def __init__(self):
        self.snapshot = dict(phase='idle', enabled=True)
        self.in_tick = threading.Event()
        self.release_tick = threading.Event()
        self.applied = threading.Event()
        self.thread_ids = set()
        self.pending = False
        self.accepted = 0
        self.stopped = False
    def start(self): self.thread_ids.add(threading.get_ident())
    def stop(self): self.stopped = True
    def public_state(self): return dict(self.snapshot)
    @staticmethod
    def read_cached(command, cache): return cache if command['op'] == 'status' else None
    def request(self, command):
        self.thread_ids.add(threading.get_ident())
        self.accepted += 1
        self.pending = True
        self.snapshot['phase'] = 'applying'
        return dict(self.snapshot)
    def tick(self):
        self.thread_ids.add(threading.get_ident())
        self.in_tick.set()
        self.release_tick.wait(3)
        if self.pending:
            self.pending = False
            self.snapshot['phase'] = 'idle'
            self.applied.set()


class WorkerTests(unittest.TestCase):
    def setUp(self):
        self.controller = Controller()
        self.worker = ControllerWorker(self.controller)
        self.worker.start()
        self.assertTrue(self.controller.in_tick.wait(1))
    def tearDown(self):
        self.controller.release_tick.set()
        self.worker.close()
        self.assertTrue(self.controller.stopped)
        self.assertEqual(len(self.controller.thread_ids), 1)
    def test_slow_backend_does_not_block_or_change_public_status(self):
        start = time.monotonic()
        for _ in range(20):
            status = self.worker.request({'op': 'status'})
            self.assertTrue(status['enabled'])
            status['enabled'] = False
        self.assertLess(time.monotonic() - start, 0.25)
        self.assertFalse(self.controller.release_tick.is_set())
    def test_durable_receipt_sent_before_apply_without_fixed_delay(self):
        self.controller.release_tick.set()
        sent = threading.Event()
        reply = self.worker.request({'op': 'change', 'password': 'private-test-secret'}, sent)
        self.assertEqual(reply['phase'], 'applying')
        self.assertFalse(self.controller.applied.is_set())
        self.assertNotIn('private-test-secret', repr(self.worker.cache))
        sent.set()
        self.assertTrue(self.controller.applied.wait(0.4), 'No fixed two-second delay after acknowledgment')
        self.assertEqual(self.controller.accepted, 1)
    def test_lost_reply_keeps_one_queued_operation_and_cached_reads_work(self):
        sent = threading.Event(); sent.set()
        result = self.worker.request({'op': 'change'}, sent)
        self.assertEqual(result['code'], 'busy')
        self.assertTrue(self.worker.request({'op': 'status'})['enabled'])
        self.controller.release_tick.set()
        self.assertTrue(self.controller.applied.wait(1))
        self.assertEqual(self.controller.accepted, 1)


if __name__ == '__main__': unittest.main()
