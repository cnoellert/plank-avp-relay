# SPDX-License-Identifier: GPL-3.0-or-later
"""LE credit-based socket adapter; the shared session and Noise stay unchanged."""
import ctypes
import fcntl
import itertools
import selectors
import socket
import struct
import termios

from .network import Connection, TCPServer

PREFACE = b'PLTRLEC1'
SOL_BLUETOOTH, BT_SECURITY, BT_SNDMTU, BT_RCVMTU = 274, 4, 12, 13
RECEIVE_MTU = 4096


def listener(address, address_type):
    sock = socket.socket(socket.AF_BLUETOOTH, socket.SOCK_SEQPACKET, socket.BTPROTO_L2CAP)
    try:
        # Only this channel uses application-owned authentication/encryption.
        # Do not initiate an AVP OS bond or change other Bluetooth profiles.
        sock.setsockopt(SOL_BLUETOOTH, BT_SECURITY, bytes([1, 0]))
        # CPython's L2CAP address tuple lacks the LE address-type field on our
        # supported OSes. Pass the fixed Linux sockaddr_l2 layout to bind(2).
        raw_address = bytes.fromhex(address.replace(':', ''))[::-1]
        if len(raw_address) != 6 or address_type not in ('public', 'random'):
            raise ValueError('Invalid local Bluetooth adapter address.')
        endpoint = struct.pack('=HH6sHBx', socket.AF_BLUETOOTH, 0, raw_address, 0,
                               1 if address_type == 'public' else 2)
        libc = ctypes.CDLL(None, use_errno=True)
        libc.bind.argtypes = (ctypes.c_int, ctypes.c_void_p, ctypes.c_uint)
        libc.bind.restype = ctypes.c_int
        if libc.bind(sock.fileno(), endpoint, len(endpoint)):
            raise OSError(ctypes.get_errno(), 'Could not bind LE L2CAP socket')
        # Binding first selects LE mode; before bind the kernel assumes BR/EDR.
        sock.setsockopt(SOL_BLUETOOTH, BT_RCVMTU, struct.pack('H', RECEIVE_MTU))
        sock.listen(8)
        sock.setblocking(False)
        return sock
    except Exception:
        sock.close()
        raise


class L2CAPConnection(Connection):
    preface = PREFACE
    link_type = 1  # Existing Bluetooth CPace/Noise transcript and saved keys.
    owner_prefix = 'l2cap'

    def configure_socket(self):
        self.send_mtu = struct.unpack('H', self.sock.getsockopt(SOL_BLUETOOTH, BT_SNDMTU, 2))[0]
        self.receive_mtu = struct.unpack('H', self.sock.getsockopt(SOL_BLUETOOTH, BT_RCVMTU, 2))[0]
        if not 23 <= self.send_mtu <= 65535 or not 23 <= self.receive_mtu <= RECEIVE_MTU:
            raise OSError('Invalid negotiated LE L2CAP MTU.')
        print(f'Bluetooth L2CAP channel opened; send MTU {self.send_mtu}, receive MTU {self.receive_mtu}.', flush=True)

    def send_chunk(self):
        chunk = self.output[:self.send_mtu]
        count = self.sock.send(chunk)
        if count != len(chunk):
            raise OSError('Incomplete L2CAP packet write.')
        return count

    def socket_queue(self):
        # Bluetooth sockets report free send space from TIOCOUTQ, not queued
        # bytes. Diagnostic only: allocated send memory, including overhead.
        try:
            free = struct.unpack('i', fcntl.ioctl(self.sock.fileno(), termios.TIOCOUTQ, b'\0' * 4))[0]
            return max(0, self.sock.getsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF) - free)
        except Exception:  # Never let a measurement end the session.
            return None

    def read_chunk(self):
        data, _, flags, _ = self.sock.recvmsg(self.receive_mtu)
        if flags & socket.MSG_TRUNC:
            raise OSError('L2CAP input packet exceeded the negotiated MTU.')
        return data

    def flush(self):
        # Credit flow control supplies backpressure through EAGAIN. Drain a
        # bounded amount immediately, rather than waiting for ATT confirmations.
        for _ in range(16):
            before = len(self.output)
            if not before:
                break
            super().flush()
            if len(self.output) == before:
                break


class L2CAPServer(TCPServer):
    connection_type = L2CAPConnection

    def __init__(self, core, address, address_type, busy=lambda: False):
        self.core, self.busy = core, busy
        self.selector = selectors.DefaultSelector()
        self.connections, self.listeners = set(), []
        self.identifiers = itertools.count()
        try:
            sock = listener(address, address_type)
            self.listeners.append(sock)
            self.psm = sock.getsockname()[1]
            if not 0x80 <= self.psm <= 0xff:
                raise OSError('Invalid dynamic LE L2CAP PSM.')
            self.selector.register(sock, selectors.EVENT_READ, None)
        except Exception:
            self.close()
            raise

    def close(self):
        # Closing Bluetooth must not erase the independently running TCP port.
        for connection in list(self.connections):
            connection.close()
        for sock in self.listeners:
            if sock.fileno() in self.selector.get_map():
                self.selector.unregister(sock)
            sock.close()
        self.listeners.clear()
        self.selector.close()
