# SPDX-License-Identifier: GPL-3.0-or-later
"""Durable Wi-Fi operations, independent of the headset's control connection."""
import argparse
import json
from pathlib import Path
import time
import uuid

from .gadget_config import atomic_json
from .wifi_protocol import (validate, fingerprint, check_password, public_network,
                            unavailable, PAGE_SIZE, MAX_NETWORKS)
from .wifi_system import LinuxWifi, STATE, read_settings

SOCKET = '/run/plank-avp-relay/wifi/control.sock'
PUBLIC_FIELDS = {'id', 'name', 'secured', 'supported', 'signal', 'saved', 'hidden'}


class WifiFailure(ValueError):
    pass


class WifiController:
    def __init__(self, backend, state=STATE, clock=time.monotonic):
        self.backend, self.state, self.clock = backend, Path(state), clock
        self.path = self.state/'policy.json'
        self.saved = dict(version=1, enabled=False, managed=False, requestID=None,
                          fingerprint=None, phase='idle', pending=None, message='Wi-Fi is disabled.')
        self.had_policy = self.path.exists()
        if self.had_policy:
            data = json.loads(self.path.read_text())
            if data.get('version') != 1 or type(data.get('enabled')) is not bool or data.get('phase') not in ('idle', 'applying', 'failed'):
                raise ValueError('Invalid saved Wi-Fi policy.')
            self.saved.update(data)
            if self.saved['pending']:
                validate({k: v for k, v in self.saved['pending'].items() if k != '_target'})
        self.supported = False
        self.snapshot = unavailable()
        self.available = {}
        self.profiles = {}
        self.lists = {'available': (str(uuid.uuid4()), []), 'saved': (str(uuid.uuid4()), [])}
        self.due = self.deadline = None
        self.stage = None
        self.retry = 0

    def persist(self): atomic_json(self.path, self.saved)

    def start(self):
        try:
            self.supported = self.backend.prepare()
            if not self.supported:
                self.snapshot = unavailable(self.backend.unsupported)
                self.retry = self.clock() + 10
                return
            if not self.had_policy:
                self.saved['enabled'] = self.backend.initial_enabled
                self.persist()
                self.had_policy = True
            self.backend.initialize(self.saved['enabled'], self.saved['managed'])
            if self.saved['pending']:
                # Restore a partially applied profile before resuming the same
                # accepted transaction. The prior config remains private.
                self.backend.rollback()
                self.due = self.clock() + 2
                self.stage = None
            self.refresh()
        except (OSError, ValueError, RuntimeError):
            self.supported = False
            self.snapshot = unavailable('Wi-Fi service is not ready. Existing settings are retained; it will retry.')
            self.retry = self.clock() + 10

    def update_list(self, kind, items):
        result = [{key: value for key, value in item.items() if key in PUBLIC_FIELDS}
                  for item in items[:MAX_NETWORKS]]
        if result != self.lists[kind][1]: self.lists[kind] = (str(uuid.uuid4()), result)

    def refresh(self):
        self.profiles = self.backend.saved()
        self.update_list('saved', sorted(self.profiles.values(), key=lambda p: p['name'].casefold()))
        for item in self.available.values(): item['saved'] = item['id'] in self.profiles
        self.update_list('available', sorted(self.available.values(), key=lambda p: -(p['signal'] or 0)))
        status = self.backend.status()
        self.snapshot = dict(supported=self.supported, enabled=self.saved['enabled'],
            phase=self.saved['phase'], requestID=self.saved['requestID'],
            message=self.saved['message'], **status)

    def request(self, command):
        validate(command)
        op = command['op']
        if op == 'wifi-status': return dict(self.snapshot)
        if op == 'wifi-list':
            generation, rows = self.lists[command['kind']]
            offset = command['offset']
            if offset and command['generation'] != generation:
                raise ValueError('The network list changed. Refresh it before loading another page.')
            end = offset + PAGE_SIZE
            return dict(networks=rows[offset:end], generation=generation, next=end if end < len(rows) else None)
        if not self.supported:
            raise ValueError(self.snapshot['message'])
        digest = fingerprint(command)
        if command['requestID'] == self.saved['requestID']:
            if digest != self.saved['fingerprint']: raise ValueError('Request identifier already used for another operation.')
            return dict(self.snapshot)
        if self.saved['pending']:
            raise ValueError('A Wi-Fi operation is already in progress.')
        if op in ('wifi-scan', 'wifi-join', 'wifi-connect') and not self.saved['enabled']:
            raise ValueError('Enable Wi-Fi before selecting a network.')
        if op in ('wifi-connect', 'wifi-forget') and command['network'] not in self.profiles:
            raise ValueError('This network is no longer saved. Refresh the list.')
        pending = dict(command)
        if op == 'wifi-join':
            item = self.join_item(command)
            check_password(item['security'], command['password'])
            # Bind to the original SSID bytes/security, not a subsequent scan.
            pending['_target'] = dict(ssid=item['ssid'].hex(), security=item['security'], hidden=item['hidden'])
        self.saved.update(requestID=command['requestID'], fingerprint=digest, pending=pending,
                          phase='applying', message='Applying Wi-Fi settings…')
        self.persist()  # Includes a pending password only in the owner-only journal.
        self.due = self.clock() + 2
        self.stage = None
        self.snapshot.update(phase='applying', requestID=self.saved['requestID'], message=self.saved['message'])
        return dict(self.snapshot)

    def join_item(self, command):
        if command['network']:
            item = self.available.get(command['network']) or self.profiles.get(command['network'])
            if not item: raise ValueError('This network is no longer in the scan results. Refresh the list.')
            return item
        ssid = command['ssid'].encode()
        item = public_network(ssid, command['security'], hidden=True)
        return dict(item, ssid=ssid, security=command['security'])

    def finish(self, message, success=True):
        self.saved.update(phase='idle' if success else 'failed', pending=None, message=message)
        self.persist()  # Remove a pending secret after completion or rejection.
        self.stage = self.deadline = self.due = None

    def begin(self):
        command = self.saved['pending']
        self.backend.begin()
        self.saved['managed'] = True
        self.persist()
        op = command['op']
        if op == 'wifi-enable':
            self.backend.set_enabled(command['enabled'])
            self.backend.commit()
            self.saved['enabled'] = command['enabled']
            self.available = {}
            self.finish('Wi-Fi enabled.' if command['enabled'] else 'Wi-Fi disabled. Saved networks are retained.')
        elif op == 'wifi-forget':
            self.backend.forget(command['network'])
            self.backend.commit()
            self.finish('Network forgotten.')
        elif op == 'wifi-scan':
            self.backend.scan()
            self.stage = 'scan'
            self.deadline = self.clock() + 20
            self.saved['message'] = 'Scanning for networks…'
        else:
            self.backend.set_enabled(True)
            if op == 'wifi-connect':
                self.backend.connect(command['network'])
                self.target = command['network']
            else:
                target = command['_target']
                ssid = bytes.fromhex(target['ssid'])
                item = dict(public_network(ssid, target['security'], hidden=target['hidden']),
                            ssid=ssid, security=target['security'])
                self.backend.join(item, command['password'])
                self.target = item['id']
            self.stage = 'join'
            self.deadline = self.clock() + 60
            self.saved['message'] = 'Connecting to the selected network…'

    def tick(self):
        if not self.supported:
            if self.clock() >= self.retry: self.start()
            return
        try:
            if self.due is not None and self.clock() >= self.due:
                self.due = None
                self.begin()
            if self.stage == 'scan':
                if self.backend.scan_done():
                    self.available = self.backend.results()
                    self.backend.commit()
                    self.finish('Network list refreshed.')
                elif self.clock() >= self.deadline:
                    raise WifiFailure('The Wi-Fi scan timed out. Try refreshing the networks again.')
            elif self.stage == 'join':
                status = self.backend.status()
                if status['network'] == self.target and status['connection'] == 'connected':
                    self.backend.commit()
                    self.finish('Connected. Network saved for automatic reconnection.')
                elif self.clock() >= self.deadline:
                    if status['network'] == self.target and status['connection'] == 'address':
                        raise WifiFailure('Joined Wi-Fi, but no network address was assigned.')
                    raise WifiFailure('Could not connect. Check the password and that the network is in range.')
                elif status['connection'] == 'address': self.saved['message'] = 'Obtaining a network address…'
            self.refresh()
        except WifiFailure as error:
            self.fail(str(error))
        except (OSError, ValueError, RuntimeError):
            # Network/driver errors are deliberately not reflected verbatim: a
            # backend diagnostic may include submitted credentials.
            if self.saved['pending']:
                self.fail()
            else:
                self.supported = False
                self.snapshot = unavailable('The Wi-Fi adapter is temporarily unavailable. Saved settings are retained.')
                self.retry = self.clock() + 10

    def fail(self, message='Wi-Fi operation failed. Check the network password, signal and address availability.'):
        try:
            self.backend.rollback()
            self.backend.set_enabled(self.saved['enabled'])
            message += ' Previous settings restored.'
        except (OSError, ValueError, RuntimeError):
            message += ' Reconnect over Bluetooth to check the relay.'
        self.finish(message, False)
        try: self.refresh()
        except (OSError, ValueError, RuntimeError):
            self.supported = False
            self.snapshot = unavailable(message)
            self.snapshot.update(phase='failed', requestID=self.saved['requestID'])
            self.retry = self.clock() + 10


def main():
    from .process import name_process
    from .local_service import serve
    name_process('plank-avp-wifi')
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check-config', action='store_true')
    parser.add_argument('--remove', action='store_true')
    args = parser.parse_args()
    interface = read_settings()
    if args.check_config:
        print('Wi-Fi configuration valid')
        return 0
    backend = LinuxWifi(interface)
    if args.remove:
        backend.remove()
        return 0
    STATE.mkdir(parents=True, exist_ok=True, mode=0o700)
    controller = WifiController(backend)
    return serve(SOCKET, controller)
