# SPDX-License-Identifier: GPL-3.0-or-later
"""Persistent USB mode transactions, independent of the headset connection."""
import argparse
import copy
import json
from pathlib import Path
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
                    self.due = self.clock()
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

    poll_interval = 1.0  # Preserve Ethernet cable gating cadence.

    def stop(self): self.backend.unbind()

    def public_state(self): return copy.deepcopy(self.snapshot)

    @staticmethod
    def read_cached(command, cache):
        if command.get('op') == 'network-status' and set(command) == {'op'}:
            return cache
        return None

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
        self.due = self.clock()
        self.snapshot.update(self.saved, message=self.message)
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
    from .local_service import serve
    return serve(SOCKET, controller)
