# SPDX-License-Identifier: GPL-3.0-or-later
"""Persistent USB mode transactions, independent of the headset connection."""
import argparse
import json
import os
from pathlib import Path
import signal
import socket
import struct
import time
import uuid

from .gadget_client import SOCKET, unavailable
from .gadget_config import MODES, STATE, atomic_json, read_settings
from .gadget_system import LinuxGadget


class GadgetController:
    def __init__(self, backend, state=STATE, clock=time.monotonic):
        self.backend, self.clock = backend, clock
        self.path = Path(state) / 'mode.json'
        self.saved = {'mode': 'bridge', 'targetMode': 'bridge', 'phase': 'idle', 'requestID': None}
        self.had_saved_mode = self.path.exists()
        if self.path.exists():
            saved = json.loads(self.path.read_text())
            if saved.get('mode') not in MODES or saved.get('targetMode') not in MODES:
                raise ValueError('Invalid saved USB mode.')
            if saved.get('phase') not in ('idle', 'applying', 'failed'):
                raise ValueError('Invalid saved USB operation.')
            self.saved.update(saved)
        self.supported = False
        self.message = ''
        self.due = None
        self.snapshot = unavailable()

    def start(self):
        try:
            self.supported = self.backend.prepare()
            if not self.supported:
                self.message = self.backend.unsupported
                self.refresh()
                return
            if self.backend.restart_required:
                self.message = 'Restart the relay to enable its USB device port.'
            else:
                inherited = getattr(self.backend, 'inherited_mode', None)
                if not self.had_saved_mode and inherited:
                    self.saved.update(mode=inherited, targetMode=inherited)
                    atomic_json(self.path, self.saved)
                # A request accepted before a crash is resumed from durable
                # state. A failed request restores the last applied mode.
                self.backend.apply(self.saved['mode'])
                if self.saved['phase'] == 'applying':
                    self.due = self.clock() + 2
                elif self.saved['phase'] != 'failed':
                    self.message = 'USB networking follows the Ethernet link. Internet access is not required.'
            self.refresh()
        except (OSError, RuntimeError, ValueError) as error:
            self.supported = False
            self.message = str(error)
            self.backend.fault = self.message
            self.refresh()

    def refresh(self):
        status = self.backend.status()
        self.snapshot = dict(self.saved, supported=self.supported, message=self.message, **status)
        if not self.supported:
            self.snapshot.update(phase='unavailable', usb='unavailable')
        if self.backend.restart_required:
            self.snapshot['phase'] = 'reboot'
        elif self.backend.fault:
            self.snapshot['phase'] = 'failed'
            self.snapshot['usb'] = 'error'
            self.snapshot['message'] = self.backend.fault

    def request(self, command):
        if command.get('op') == 'network-status' and set(command) == {'op'}:
            return dict(self.snapshot)
        if command.get('op') != 'network-mode' or set(command) != {'op', 'mode', 'requestID'}:
            raise ValueError('Invalid USB network command.')
        mode, request = command['mode'], command['requestID']
        if mode not in MODES or not isinstance(request, str) or str(uuid.UUID(request)) != request:
            raise ValueError('Invalid network mode or request identifier.')
        if not self.supported or self.snapshot['phase'] in ('unavailable', 'reboot'):
            raise ValueError(self.message or self.snapshot['message'])
        if request == self.saved['requestID']:
            if mode != self.saved['targetMode']:
                raise ValueError('Request identifier was already used for another mode.')
            return dict(self.snapshot)
        if self.saved['phase'] == 'applying':
            raise ValueError('A network mode change is already in progress.')
        updated = dict(self.saved, targetMode=mode, requestID=request, phase='applying')
        atomic_json(self.path, updated)  # Acknowledge only after fsync.
        self.saved = updated
        self.message = 'Changing network mode. The app will reconnect automatically.'
        self.due = self.clock() + 2
        self.refresh()
        return dict(self.snapshot)

    def tick(self):
        if not self.supported or self.backend.restart_required:
            self.refresh()
            return
        if self.due is not None and self.clock() >= self.due:
            self.due = None
            try:
                self.backend.apply(self.saved['targetMode'])
                self.saved['mode'] = self.saved['targetMode']
                self.saved['phase'] = 'idle'
                self.message = 'Network mode saved. Waiting for the USB connection if needed.'
            except (OSError, RuntimeError, ValueError) as error:
                self.saved['phase'] = 'failed'
                self.message = 'Mode change failed: ' + str(error)
                try:
                    self.backend.apply(self.saved['mode'])
                    self.message += ' Previous mode restored.'
                except (OSError, RuntimeError, ValueError):
                    self.backend.unbind()
                    self.message += ' USB is disabled; use Bluetooth or SSH to recover.'
            atomic_json(self.path, self.saved)
        try:
            self.backend.sync()
            self.refresh()
        except (OSError, RuntimeError, ValueError) as error:
            self.backend.unbind()
            self.backend.fault = 'USB networking is disabled: ' + str(error)
            self.snapshot.update(phase='failed', usb='error', message=self.backend.fault)


def handle_socket(connection, controller):
    # The relay service is root with a restricted systemd sandbox. No public
    # port, command execution, arbitrary paths or unauthenticated app access.
    credentials = connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize('3i'))
    _, uid, _ = struct.unpack('3i', credentials)
    if uid != 0:
        return
    connection.settimeout(0.5)
    try:
        data = bytearray()
        while not data.endswith(b'\n'):
            part = connection.recv(1025 - len(data))
            if not part or len(data) + len(part) > 1024:
                raise ValueError('Invalid network request length.')
            data.extend(part)
        request = json.loads(data)
        if not isinstance(request, dict):
            raise ValueError('Expected a network request object.')
        reply = controller.request(request)
    except (ValueError, KeyError, TypeError) as error:
        reply = {'error': str(error)[:512]}
    connection.sendall(json.dumps(reply, separators=(',', ':')).encode() + b'\n')


def main():
    from .process import name_process
    name_process('plank-avp-usb')
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--remove', action='store_true')
    parser.add_argument('--check-config', action='store_true')
    args = parser.parse_args()
    settings = read_settings()
    if args.check_config:
        print('USB network configuration valid')
        return 0
    backend = LinuxGadget(settings)
    if args.remove:
        # Avoid touching routing on a machine where this feature never ran.
        if (STATE / 'wired-before.json').exists() or (STATE / 'armbianEnv.before').exists():
            backend.remove()
        return 0
    STATE.mkdir(parents=True, exist_ok=True, mode=0o700)
    controller = GadgetController(backend)
    path = Path(SOCKET)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    path.unlink(missing_ok=True)
    running = True

    def stop(*_):
        nonlocal running
        running = False

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
        listener.bind(SOCKET)
        os.chmod(SOCKET, 0o600)
        listener.listen(4)
        listener.settimeout(0.2)
        try:
            controller.start()
            last = 0
            while running:
                if time.monotonic() - last >= 1:
                    controller.tick()
                    last = time.monotonic()
                try:
                    connection, _ = listener.accept()
                except socket.timeout:
                    continue
                with connection:
                    try:
                        handle_socket(connection, controller)
                    except (OSError, ValueError):
                        pass
        finally:
            backend.unbind()
            path.unlink(missing_ok=True)
    return 0
