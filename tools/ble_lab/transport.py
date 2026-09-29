# SPDX-License-Identifier: GPL-3.0-or-later
from collections import deque
import time


def write_peer(data, options, adapter, notifying, active_peer):
    peer = str(options.get('device', ''))
    if (not notifying or not peer.startswith(adapter + '/dev_') or
        str(options.get('link', '')) != 'LE' or int(options.get('offset', 0)) != 0 or
        str(options.get('type', 'request')) != 'request' or
        not 1 <= len(data) <= 512 or (active_peer and active_peer != peer)):
        raise ValueError('One selected LE client and sequential writes are required.')
    return peer


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


class EchoChannel:
    """Bounded byte echo only; no tablet, identity store or protocol access."""
    def __init__(self, emit, close_peer):
        self.queue = Indications(emit)
        self.close_peer = close_peer
        self.peer = None
        self.notifying = False
        self.started = self.received = 0

    def receive(self, data, options, adapter, other_peer=None):
        peer = write_peer(data, options, adapter, self.notifying, self.peer)
        if other_peer:
            raise ValueError('The relay is already in use by an authenticated operation.')
        if not self.peer:
            self.peer, self.started = peer, time.monotonic()
            print('Bluetooth transport test connected; no tablet or pairing access.', flush=True)
        if self.received + len(data) > 4096:
            raise BufferError('Bluetooth transport test exceeded its byte limit.')
        self.received += len(data)
        self.queue.mtu_payload = max(20, min(512, int(options.get('mtu', 23)) - 3))
        self.queue.append(data)

    def tick(self):
        self.queue.check_timeout()
        if self.peer and time.monotonic() - self.started > 30:
            raise TimeoutError('Bluetooth transport test reached its time limit.')

    def disconnect(self):
        peer, self.peer = self.peer, None
        self.queue.clear()
        if peer:
            print(f'Bluetooth transport test closed; received {self.received} test bytes.', flush=True)
            self.close_peer(peer)
        self.received = self.started = 0


class SetupChannel:
    """Length-prefixed bootstrap requests; never grants headset trust."""
    def __init__(self, emit, close_peer, request, cancel):
        self.queue = Indications(emit)
        self.close_peer, self.request, self.cancel_operation = close_peer, request, cancel
        self.peer = None
        self.notifying = False
        self.buffer = bytearray()
        self.started = self.last_received = 0
        self.requests = 0

    def receive(self, data, options, adapter, other_peer=None):
        peer = write_peer(data, options, adapter, self.notifying, self.peer)
        if other_peer:
            raise ValueError('Close the other relay operation before tablet setup.')
        if not self.peer:
            self.peer, self.started = peer, time.monotonic()
        self.last_received = time.monotonic()
        self.queue.mtu_payload = max(20, min(512, int(options.get('mtu', 23)) - 3))
        self.buffer.extend(data)
        while len(self.buffer) >= 2:
            size = int.from_bytes(self.buffer[:2], 'little')
            if not 2 <= size <= 512 or len(self.buffer) > 1026:
                raise ValueError('Invalid tablet setup record size.')
            if len(self.buffer) < size + 2:
                break
            self.requests += 1
            if self.requests > 600:
                raise ValueError('Tablet setup request limit reached.')
            reply = self.request(bytes(self.buffer[2:size+2]), self.peer)
            del self.buffer[:size+2]
            if not 2 <= len(reply) <= 4096:
                raise ValueError('Invalid tablet setup reply size.')
            self.queue.append(len(reply).to_bytes(2, 'little') + reply)

    def tick(self):
        self.queue.check_timeout()
        now = time.monotonic()
        if self.queue.busy:
            self.last_received = now  # A bounded response may need many ATT fragments.
        if self.peer and (now - self.started > 300 or now - self.last_received > 15):
            raise TimeoutError('Tablet setup connection timed out.')

    def disconnect(self):
        peer, self.peer = self.peer, None
        self.queue.clear()
        self.buffer.clear()
        self.requests = 0
        if peer:
            self.cancel_operation(peer)
            self.close_peer(peer)
