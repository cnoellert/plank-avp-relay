# SPDX-License-Identifier: GPL-3.0-or-later
from collections import deque
import time


class Indications:
    """One acknowledged ATT fragment at a time; never discard stream bytes."""
    def __init__(self, emit, limit=16384):
        self.emit, self.limit = emit, limit
        self.pending = deque()
        self.total = 0
        self.mtu_payload = 20
        self.inflight = False
        self.sent_at = 0

    @property
    def busy(self):
        return self.inflight or bool(self.pending)

    def clear(self):
        self.pending.clear()
        self.total = 0
        self.inflight = False
        self.mtu_payload = 20

    def append(self, data):
        if not data:
            return
        if self.total + len(data) > self.limit:
            raise BufferError('Bluetooth peer is not consuming the bounded stream.')
        self.pending.append(data)
        self.total += len(data)
        self.pump()

    def pump(self):
        if self.inflight or not self.pending:
            return
        data = self.pending.popleft()
        fragment = data[:self.mtu_payload]
        if len(data) > len(fragment):
            self.pending.appendleft(data[len(fragment):])
        self.total -= len(fragment)
        self.inflight = True
        self.sent_at = time.monotonic()
        self.emit(fragment)

    def confirm(self):
        if not self.inflight:
            return
        self.inflight = False
        self.pump()

    def check_timeout(self):
        if self.inflight and time.monotonic() - self.sent_at > 10:
            raise TimeoutError('Bluetooth indication was not acknowledged.')
