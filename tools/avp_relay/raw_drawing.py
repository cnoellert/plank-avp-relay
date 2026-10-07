# SPDX-License-Identifier: GPL-3.0-or-later
"""Bounded opaque bridge. Authentication and capture belong to the raw daemon."""
import errno
import selectors
import socket
import struct
import time

from .drawing_status import resolve_service_uid
from .network import MAX_PENDING

ABSTRACT_NAME = 'plank-tablet-drawing-ble-v1'


class RawDrawingBridge:
    # Injection is for isolated tests only; the L2CAP entry uses defaults.
    def __init__(self, owner, *, name=ABSTRACT_NAME, resolve=resolve_service_uid):
        self.owner, self.selector = owner, owner.server.selector
        self.pending = bytearray()
        self.started = self.progress = time.monotonic()
        self.connected = self.closed = self.eof = False
        self.uid, reason = resolve()
        if reason or self.uid is None:
            raise OSError('Raw drawing service account unavailable.')
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            self.sock.setblocking(False)
            result = self.sock.connect_ex('\0' + name)
            if result not in (0, errno.EINPROGRESS, errno.EAGAIN):
                raise OSError(result, 'Raw drawing service unavailable.')
            self.selector.register(self.sock, selectors.EVENT_WRITE, self)
        except Exception:
            self.sock.close()
            raise

    def readable(self):
        # Leave enough room for one entire negotiated inbound L2CAP packet.
        return not self.eof and len(self.pending) <= MAX_PENDING - self.owner.receive_mtu

    def append(self, data):
        if self.closed or self.eof or len(self.pending) + len(data) > MAX_PENDING:
            raise BufferError('Raw drawing input exceeded its bounded buffer.')
        if data:
            if not self.pending:
                self.progress = time.monotonic()
            self.pending.extend(data)
        self.update_events()
        self.owner.update_events()

    def update_events(self):
        if self.closed or self.eof:
            return
        events = 0
        if not self.connected or self.pending:
            events |= selectors.EVENT_WRITE
        if self.connected and len(self.owner.output) <= MAX_PENDING - 4096:
            events |= selectors.EVENT_READ
        registered = self.sock.fileno() in self.selector.get_map()
        if events:
            if registered:
                self.selector.modify(self.sock, events, self)
            else:
                self.selector.register(self.sock, events, self)
        elif registered:
            self.selector.unregister(self.sock)

    def ready(self, events):
        try:
            if not self.connected:
                failure = self.sock.getsockopt(socket.SOL_SOCKET, socket.SO_ERROR)
                if failure:
                    raise OSError(failure, 'Raw drawing connect failed.')
                peer = struct.unpack('3i', self.sock.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))[1]
                if peer != self.uid:
                    raise PermissionError('Raw drawing service peer unverified.')
                self.connected = True
                print('Bluetooth raw drawing bridge connected; identity verification belongs to raw service.', flush=True)
            if events & selectors.EVENT_WRITE and self.pending:
                count = self.sock.send(self.pending)
                if count <= 0:
                    raise OSError('Raw drawing write closed.')
                del self.pending[:count]
                self.progress = time.monotonic()
            if events & selectors.EVENT_READ and len(self.owner.output) <= MAX_PENDING - 4096:
                data = self.sock.recv(4096)
                if not data:
                    self.eof = True
                    if self.sock.fileno() in self.selector.get_map():
                        self.selector.unregister(self.sock)
                    self.owner.update_events()
                    self.tick(time.monotonic())
                    return
                self.owner.append(data)
        except BlockingIOError:
            pass
        except (OSError, ValueError, BufferError):
            self.owner.close()
        if not self.closed:
            self.update_events()
            self.owner.update_events()

    def tick(self, now):
        if ((self.eof and not self.owner.output) or
                (not self.connected and now - self.started > 2) or
                (self.pending and now - self.progress > 10)):
            self.owner.close()

    def close(self):
        if self.closed:
            return
        self.closed = True
        if self.sock.fileno() in self.selector.get_map():
            self.selector.unregister(self.sock)
        self.sock.close()
        self.pending.clear()
