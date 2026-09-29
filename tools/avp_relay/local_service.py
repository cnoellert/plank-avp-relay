# SPDX-License-Identifier: GPL-3.0-or-later
"""Bounded, root-only local management IPC. No request or secret logging."""
import json
import os
from pathlib import Path
import signal
import socket
import struct
import time


def serve(path, controller):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    path.unlink(missing_ok=True)
    running = True
    def stop(*_):
        nonlocal running
        running = False
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
        listener.bind(str(path))
        os.chmod(path, 0o600)
        listener.listen(4)
        listener.settimeout(0.2)
        try:
            controller.start()
            last = 0
            while running:
                if time.monotonic() - last >= 1:
                    controller.tick()
                    last = time.monotonic()
                try: connection, _ = listener.accept()
                except socket.timeout: continue
                with connection:
                    try: handle(connection, controller)
                    except (OSError, ValueError): pass
        finally:
            path.unlink(missing_ok=True)
    return 0


def handle(connection, controller):
    _, uid, _ = struct.unpack('3i', connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize('3i')))
    if uid != 0: return
    connection.settimeout(0.5)
    data = bytearray()
    try:
        while not data.endswith(b'\n'):
            part = connection.recv(1025 - len(data))
            if not part or len(data) + len(part) > 1024: raise ValueError('Invalid management request length.')
            data.extend(part)
        command = json.loads(data)
        if not isinstance(command, dict): raise ValueError('Expected a management request.')
        reply = controller.request(command)
    except ValueError as error:
        reply = {'error': str(error)[:512]}
    except (KeyError, TypeError, RuntimeError):
        reply = {'error': 'The Wi-Fi request could not be completed. Refresh its status.'}
    encoded = json.dumps(reply, separators=(',', ':'), ensure_ascii=False).encode() + b'\n'
    if len(encoded) > 4000: encoded = b'{"error":"The management response exceeded its limit."}\n'
    connection.sendall(encoded)
