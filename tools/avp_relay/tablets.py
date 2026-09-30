# SPDX-License-Identifier: GPL-3.0-or-later
"""Bounded tablet enrollment; backend operations are scoped to one candidate."""
import json
import os
from pathlib import Path
import re
import socket
import time

ADDRESS = re.compile(r'[0-9A-F]{2}(?::[0-9A-F]{2}){5}\Z')
HID = {'00001124-0000-1000-8000-00805f9b34fb', '00001812-0000-1000-8000-00805f9b34fb'}


def address(value):
    if not isinstance(value, str) or not ADDRESS.fullmatch(value.upper()):
        raise ValueError('Select a tablet from this relay’s list.')
    return value.upper()


def wacom(properties):
    return str(properties.get('Modalias', '')).lower().startswith(('usb:v056a', 'bluetooth:v056a'))


def hid(properties):
    return bool(HID.intersection(str(x).lower() for x in properties.get('UUIDs', [])))


def candidate(properties):
    # Discovery hints only. Verify vendor, HID service and real input after pairing.
    return wacom(properties) or hid(properties) or (int(properties.get('Class', 0)) & 0x1f00) == 0x0500


def save(path, value):
    temporary = path.with_suffix('.tmp')
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(value, stream, separators=(',', ':'))
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        temporary.unlink(missing_ok=True)


class Tablets:
    def __init__(self, backend, directory, has_clients, select, attached, configured='', clock=time.monotonic,
                 enroll_headset=None, usb_status=lambda: [], select_usb=None):
        self.backend, self.has_clients = backend, has_clients
        self.select, self.attached, self.clock = select, attached, clock
        self.configured = configured
        self.enroll_headset = enroll_headset
        self.usb_status, self.select_usb = usb_status, select_usb
        self.enroll_owner = None
        self.path = Path(directory) / 'tablets.json'
        self.state = {'version': 1, 'selected': None, 'tablets': [], 'pending': None}
        if self.path.exists():
            info = self.path.lstat()
            if self.path.is_symlink() or info.st_uid != os.getuid() or info.st_mode & 0o077:
                raise ValueError('Tablet enrollment state must be owned and private.')
            self.state = json.loads(self.path.read_text())
            if (self.state.get('version') != 1 or not isinstance(self.state.get('tablets'), list) or
                    len(self.state['tablets']) > 16):
                raise ValueError('Invalid tablet enrollment state.')
            for item in self.state['tablets']:
                address(item)
            if self.state.get('selected'):
                address(self.state['selected'])
        self.owner = None
        self.phase, self.message = 'idle', 'Choose a tablet operation.'
        self.deadline = self.session_deadline = self.last_poll = 0
        self.target = None
        self.scanning = False
        self.original_pairable = None
        self.generation = 0
        self.discovered = set()
        self.recovery_retry = 0
        self.recover_pending()
        if self.state['selected'] and not configured:
            self.select(self.state['selected'])

    def recover_pending(self):
        pending = self.state.get('pending')
        if pending and self.owner is None:
            if self.clock() < self.recovery_retry:
                return False
            self.recovery_retry = self.clock() + 5
            target = address(pending['id'])
            try:
                if pending['created']:
                    self.backend.cancel_pair(target)
                    self.backend.remove(target)
                self.backend.set_pairable(bool(pending['pairableBefore']))
                self.backend.close()
            except RuntimeError:
                self.message = 'Waiting for Bluetooth to clean up interrupted tablet setup.'
                return False
            self.state['pending'] = None
            save(self.path, self.state)
        return True

    def known(self, devices):
        return set(self.state['tablets']) | {key for key, item in devices.items()
            if item.get('Paired') and wacom(item) and hid(item)}

    def initial(self, devices):
        # An explicit ownership reset retains tablet bonds. An unowned relay
        # may verify one of those tablets in the initiating encrypted session.
        return not (self.has_clients() or self.configured)

    def snapshot(self, authenticated, devices=None, enrolling=False):
        devices = self.backend.devices() if devices is None else devices
        known = self.known(devices)
        def item(key):
            properties = devices.get(key, {})
            name = str(properties.get('Name', 'Wacom tablet')).encode('utf-8')[:40].decode('utf-8', errors='ignore')
            return {'id': key, 'name': name,
                    'connected': bool(properties.get('Connected')), 'paired': key in known}
        candidates = sorted(key for key, props in devices.items() if candidate(props) and key not in known)
        self.discovered.update(candidates if self.scanning else [])
        return {'version': 1, 'hostname': socket.gethostname(), 'phase': self.phase, 'message': self.message,
                'canManage': bool(authenticated or (enrolling and self.initial(devices))),
                'headsetAuthorized': bool(authenticated),
                'initialSetup': self.initial(devices), 'attached': bool(self.attached()),
                'usbTablets': self.usb_status(),
                'bluetoothAvailable': getattr(self.backend, 'available', True),
                'selected': self.configured or self.state['selected'],
                'secondsRemaining': max(0, int(self.deadline - self.clock())) if self.deadline else 0,
                'tablets': [item(key) for key in sorted(known)[:16]],
                'candidates': [item(key) for key in candidates[:16]] if self.scanning else []}

    def handle(self, payload, owner, authenticated=False, enrolling=False):
        request_id = 0
        starting_pair = False
        try:
            if not 2 <= len(payload) <= 512:
                raise ValueError('Invalid tablet request size.')
            request = json.loads(payload)
            if (not isinstance(request, dict) or set(request) - {'version', 'id', 'op', 'tablet'} or
                    request.get('version') != 1 or type(request.get('id')) is not int or
                    not 1 <= request['id'] <= 1000000):
                raise ValueError('Invalid tablet request.')
            request_id = request['id']
            operation = request.get('op')
            if operation not in ('status', 'scan', 'pair', 'connect', 'select', 'remove', 'cancel', 'use-usb'):
                raise ValueError('Unknown tablet operation.')
            if operation not in ('status', 'use-usb') and self.owner is None and not self.recover_pending():
                raise ValueError(self.message)
            devices = self.backend.devices()
            if self.owner and self.owner != owner and operation != 'status':
                raise ValueError('Tablet setup is already open on another connection.')
            if operation not in ('status', 'cancel') and not (authenticated or (enrolling and self.initial(devices))):
                raise ValueError('Use an approved headset to manage tablets. Wake the saved tablet to approve a new headset, or use SSH recovery.')
            if operation == 'cancel':
                self.cancel(owner)
            elif operation != 'status':
                if self.configured:
                    raise ValueError('Tablet selection is fixed in relay.conf. Clear that setting through SSH before managing it in the app.')
                if self.phase in ('pairing', 'connecting', 'verifying'):
                    raise ValueError('Wait for the current tablet operation or cancel it.')
                self.owner = owner
                if not self.session_deadline:
                    self.session_deadline = self.clock() + 300
                if operation == 'use-usb':
                    target = request.get('tablet')
                    if self.select_usb is None or not any(t['id'] == target for t in self.usb_status()):
                        raise ValueError('Select a connected USB tablet from this relay’s list.')
                    self.stop_scan()
                    self.select_usb(target)
                    if not authenticated:
                        if self.enroll_headset is None:
                            raise ValueError('Headset authorization is unavailable.')
                        self.enroll_headset(owner)
                    self.phase, self.message = 'ready', 'USB tablet ready and headset authorized.'
                    self.deadline = 0
                elif not getattr(self.backend, 'available', True):
                    raise ValueError('No Bluetooth adapter available. Connect a USB tablet or reconnect the adapter.')
                elif operation == 'scan':
                    self.stop_scan()
                    self.discovered.clear()
                    self.backend.start_scan()
                    self.scanning = True
                    self.phase, self.message = 'scanning', 'Put your tablet into pairing mode, then select it.'
                    self.deadline = self.clock() + 60
                else:
                    target = address(request.get('tablet'))
                    if operation == 'pair':
                        if target not in self.discovered or target not in devices:
                            raise ValueError('Scan again and select a discovered tablet.')
                        starting_pair = True
                        self.enroll_owner = owner if enrolling and not authenticated else None
                        self.begin_pair(target, devices[target])
                    else:
                        if target not in self.known(devices) or (not authenticated and
                                not (enrolling and self.initial(devices) and operation in ('connect', 'select'))):
                            raise ValueError('Select a saved tablet using an approved headset.')
                        self.stop_scan()
                        if operation == 'remove':
                            self.backend.remove(target)
                            self.state['tablets'] = [key for key in self.state['tablets'] if key != target]
                            if self.state['selected'] == target:
                                self.state['selected'] = None
                                self.select('none')
                            save(self.path, self.state)
                            self.phase, self.message = 'idle', 'Tablet removed. Other saved pairings are unchanged.'
                        else:
                            starting_pair = True
                            self.enroll_owner = owner if enrolling and not authenticated else None
                            self.begin_pair(target, devices.get(target, {}), reconnect=True)
            response = self.snapshot(authenticated, enrolling=enrolling)
            response.update({'id': request_id, 'ok': True})
        except (ValueError, OSError, RuntimeError) as error:
            if starting_pair and self.state.get('pending') and self.owner == owner:
                self.cleanup()
                self.phase, self.message = 'failed', 'Could not start tablet pairing. Retry when Bluetooth is ready.'
            response = {'version': 1, 'id': request_id, 'ok': False, 'error': str(error)[:240]}
        encoded = json.dumps(response, separators=(',', ':'), ensure_ascii=False).encode()
        while len(encoded) > 4096 and response.get('candidates'):
            response['candidates'].pop()
            encoded = json.dumps(response, separators=(',', ':'), ensure_ascii=False).encode()
        while len(encoded) > 3800 and response.get('usbTablets'):
            response['usbTablets'].pop()
            encoded = json.dumps(response, separators=(',', ':'), ensure_ascii=False).encode()
        if len(encoded) > 4096:
            raise ValueError('Tablet response exceeded its bound.')
        return encoded

    def stop_scan(self):
        if self.scanning:
            self.backend.stop_scan()
            self.scanning = False

    def begin_pair(self, target, properties, reconnect=False):
        if len(self.known(self.backend.devices())) >= 16 and target not in self.known(self.backend.devices()):
            raise ValueError('Remove an unused tablet before adding another.')
        self.stop_scan()
        self.target = target
        self.generation += 1
        generation = self.generation
        self.original_pairable = self.backend.pairable()
        created = not bool(properties.get('Paired'))
        if reconnect and created:
            raise ValueError('This tablet no longer has a Bluetooth bond. Remove its saved entry and pair it again.')
        self.state['pending'] = {'id': target, 'created': created, 'pairableBefore': self.original_pairable}
        save(self.path, self.state)
        self.deadline = self.clock() + 60
        self.phase, self.message = 'pairing', 'Pairing the selected tablet…'
        def paired(error=None):
            if generation != self.generation:
                # CancelPairing and RemoveDevice serialize cleanup with BlueZ;
                # a late callback never changes a newer operation's state.
                return
            if error:
                self.fail('Tablet pairing failed. Make it discoverable and try again.')
                return
            self.phase, self.message = 'connecting', 'Connecting and checking tablet input…'
            self.backend.connect(target, connected)
        def connected(error=None):
            if generation != self.generation:
                return
            if error:
                self.fail('Could not connect. Wake the tablet and try again.')
                return
            self.phase = 'verifying'
            self.deadline = self.clock() + 15
        if created:
            self.backend.set_pairable(True)
            self.backend.pair(target, paired)
        else:
            paired()

    def cleanup(self):
        self.generation += 1
        self.stop_scan()
        pending = self.state.get('pending')
        if pending:
            if pending['created']:
                self.backend.cancel_pair(pending['id'])
                self.backend.remove(pending['id'])
            self.backend.set_pairable(bool(pending['pairableBefore']))
            self.state['pending'] = None
            save(self.path, self.state)
        self.backend.close()
        self.target = None
        self.enroll_owner = None
        self.original_pairable = None
        self.deadline = 0

    def fail(self, message):
        self.cleanup()
        self.phase, self.message = 'failed', message

    def cancel(self, owner):
        if self.owner != owner:
            return
        try:
            self.cleanup()
        finally:
            # A durable pending journal must not keep the dead session's owner.
            self.owner = self.enroll_owner = None
            self.deadline = self.session_deadline = 0
            self.phase, self.message = 'idle', 'Tablet setup closed. Saved pairings are retained.'

    def tick(self):
        if not self.recover_pending():
            return
        now = self.clock()
        if self.owner and now >= self.session_deadline:
            self.cancel(self.owner)
            return
        if self.deadline and now >= self.deadline:
            self.fail('Tablet setup timed out. Check pairing mode or wake the tablet, then retry.')
            return
        if self.phase != 'verifying' or now - self.last_poll < 0.5:
            return
        self.last_poll = now
        properties = self.backend.devices().get(self.target, {})
        if not properties.get('ServicesResolved'):
            return
        if not wacom(properties) or not hid(properties):
            self.fail('The selected device is not a supported Wacom input tablet.')
            return
        if not properties.get('Paired') or not properties.get('Bonded'):
            self.fail('The tablet did not create a persistent Bluetooth bond. Try pairing again.')
            return
        if not self.backend.input_ready(self.target):
            return
        if self.enroll_owner is not None:
            try:
                if self.enroll_owner != self.owner or self.enroll_headset is None:
                    raise RuntimeError('The initiating headset is no longer available.')
                self.enroll_headset(self.enroll_owner)
            except RuntimeError:
                self.fail('Could not save headset ownership. Retry tablet setup.')
                return
            self.enroll_owner = None
        self.backend.trust(self.target)
        self.backend.set_pairable(bool(self.original_pairable))
        if self.target not in self.state['tablets']:
            self.state['tablets'].append(self.target)
        self.state['selected'] = self.target
        self.state['pending'] = None
        save(self.path, self.state)
        self.select(self.target)
        self.backend.close()
        self.target = None
        self.original_pairable = None
        self.deadline = 0
        self.phase, self.message = 'ready', 'Tablet paired and headset authorized. Ready for live readings.'
