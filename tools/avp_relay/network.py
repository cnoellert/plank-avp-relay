# SPDX-License-Identifier: GPL-3.0-or-later
"""Fresh bounded TCP adapter for the current relay core; no raw-HID service."""
import itertools
import json
import selectors
import socket
import time

from .native import ProtocolError

PREFACE = b'PLTRTCP1'
SERVICE_TYPE = '_plank-avp-relay._tcp'
MAX_PENDING = 16384


class Connection:
    def __init__(self, server, sock):
        self.server, self.sock = server, sock
        self.owner = 'tcp:' + str(next(server.identifiers))
        self.channel = None
        self.input, self.output = bytearray(), bytearray()
        self.started = self.last_progress = time.monotonic()
        self.closed = self.claimed = False
        self.received = self.requests = 0
        sock.setblocking(False)
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
        server.selector.register(sock, selectors.EVENT_READ, self)

    def append(self, data):
        if not data:
            return
        if self.closed or len(self.output) + len(data) > MAX_PENDING:
            raise BufferError('Network peer is not consuming the bounded stream.')
        if not self.output:
            self.last_progress = time.monotonic()
        self.output.extend(data)
        self.server.selector.modify(self.sock, selectors.EVENT_READ | selectors.EVENT_WRITE, self)
        self.flush()

    def flush(self):
        # A writable socket can accept newly captured input immediately. A
        # partial/nonblocking write stays queued for the existing selector.
        if not self.output:
            return
        try:
            count = self.sock.send(self.output)
        except BlockingIOError:
            return
        if count:
            del self.output[:count]
            self.last_progress = time.monotonic()
        if not self.output:
            self.server.selector.modify(self.sock, selectors.EVENT_READ, self)

    def receive(self, data):
        if self.channel is None:
            self.input.extend(data)
            if len(self.input) < 9:
                return
            if self.input[:8] != PREFACE or self.input[8] not in (0, 1, 2):
                raise ProtocolError('Unsupported network relay protocol.')
            self.channel = self.input[8]
            data = bytes(self.input[9:])
            self.input.clear()
        if self.channel == 0:
            if not data:
                return
            if not self.claimed:
                if self.server.busy():
                    raise ProtocolError('Relay setup is already in use.')
                self.server.core.claim(self.owner, 2, self.append, lambda: bool(self.output), self.close)
                self.claimed = True
            self.server.core.receive(self.owner, data)
        elif self.channel == 1:
            self.input.extend(data)
            if len(self.input) > 514:
                raise ProtocolError('Oversized discovery request.')
            if len(self.input) < 2:
                return
            size = int.from_bytes(self.input[:2], 'little')
            if not 2 <= size <= 512 or len(self.input) > size + 2:
                raise ProtocolError('Invalid discovery request.')
            if len(self.input) != size + 2:
                return
            # Bootstrap is strictly read-only, including no cancel operation.
            payload = bytes(self.input[2:])
            request = json.loads(payload)
            if not isinstance(request, dict) or request.get('op') != 'status' or self.requests:
                raise ProtocolError('Discovery supports one status request only.')
            reply = self.server.core.request(payload, self.owner)
            self.requests += 1
            self.input.clear()
            self.append(len(reply).to_bytes(2, 'little') + reply)
        else:
            self.received += len(data)
            if self.received > 4096:
                raise ProtocolError('Network byte test exceeded its limit.')
            self.append(data)

    def ready(self, events):
        try:
            if events & selectors.EVENT_READ:
                data = self.sock.recv(4096)
                if not data:
                    self.close()
                    return
                self.receive(data)
            if events & selectors.EVENT_WRITE and self.output:
                self.flush()
        except BlockingIOError:
            pass
        except (OSError, ValueError, ProtocolError, BufferError, TimeoutError):
            self.close()

    def tick(self, now):
        if ((not self.claimed and now - self.started > (30 if self.channel == 2 else 5)) or
                (self.output and now - self.last_progress > 10)):
            self.close()

    def close(self):
        if self.closed:
            return
        self.closed = True
        if self.claimed:
            self.server.core.release(self.owner)
        self.server.selector.unregister(self.sock)
        self.sock.close()
        self.server.connections.discard(self)


class TCPServer:
    def __init__(self, core, port, busy=lambda: False, host=None):
        self.core, self.busy = core, busy
        self.selector = selectors.DefaultSelector()
        self.connections = set()
        self.identifiers = itertools.count()
        self.listeners = []
        try:
            addresses = [(socket.AF_INET, host)] if host else [(socket.AF_INET6, '::'), (socket.AF_INET, '0.0.0.0')]
            for family, address in addresses:
                sock = socket.socket(family, socket.SOCK_STREAM)
                try:
                    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                    if family == socket.AF_INET6:
                        sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
                    sock.bind((address, port))
                    if port == 0:
                        port = sock.getsockname()[1]
                    sock.listen(8)
                    sock.setblocking(False)
                    self.selector.register(sock, selectors.EVENT_READ, None)
                    self.listeners.append(sock)
                except OSError:
                    sock.close()
                    if family != socket.AF_INET6:
                        raise
            self.port = port
            self.core.tcp_port = port
        except Exception:
            self.close()
            raise

    def poll(self):
        for key, events in self.selector.select(0):
            if key.data:
                key.data.ready(events)
            else:
                # Bounded accept/read work keeps tablet capture responsive.
                for _ in range(8):
                    try:
                        sock, _ = key.fileobj.accept()
                    except BlockingIOError:
                        break
                    if len(self.connections) >= 8:
                        sock.close()
                    else:
                        try:
                            self.connections.add(Connection(self, sock))
                        except OSError:
                            sock.close()
        now = time.monotonic()
        for connection in list(self.connections):
            connection.tick(now)

    def close(self):
        self.core.tcp_port = None
        for connection in list(self.connections):
            connection.close()
        for sock in self.listeners:
            self.selector.unregister(sock)
            sock.close()
        self.listeners.clear()
        self.selector.close()
