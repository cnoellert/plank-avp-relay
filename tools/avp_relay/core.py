# SPDX-License-Identifier: GPL-3.0-or-later
"""Single owner of tablet input, enrollment and identity across transports."""
import json
import time

from .capture import Capture
from .native import Native, ProtocolError
from .tablets import Tablets
from .gadget_client import GadgetClient, GadgetBusy
from .wifi_protocol import FIELDS as WIFI_FIELDS, unavailable as wifi_unavailable


class RelayCore:
    def __init__(self, args, backend):
        self.native = Native(args.library, args.state_dir)
        self.owner = None
        self.emit = self.busy = self.close_connection = None
        self.capture = Capture(args.tablet, self.button)
        self.gadget = GadgetClient()
        self.wifi = GadgetClient('/run/plank-avp-relay/wifi/control.sock', 'wifi-status', wifi_unavailable, 'Wi-Fi')
        self.tablets = Tablets(backend, args.state_dir, lambda: self.native.has_clients,
            self.select, lambda: self.capture.attached, args.tablet,
            enroll_headset=self.enroll_headset)
        self.native.on_management = lambda data: self.request(data, self.owner,
            self.native.management_authorized, self.native.enrolling)
        self.last_sample = 0
        self.was_observing = False

    def select(self, value):
        self.capture.close_nodes()
        self.capture.identity = None
        self.capture.selected = value.lower() if value else None
        self.capture.last_scan = 0

    def request(self, data, peer, authenticated=False, enrolling=False):
        command = json.loads(data)
        if isinstance(command, dict) and isinstance(command.get('op'), str) and command['op'] in ('network-status', 'network-mode', *WIFI_FIELDS):
            response = {'version': 1, 'id': command.get('id', 0), 'ok': False}
            try:
                if not authenticated or peer != self.owner:
                    raise ValueError('An authorized headset is required to manage network settings.')
                if command.get('version') != 1 or type(command.get('id')) is not int or not 1 <= command['id'] <= 1000000:
                    raise ValueError('Invalid network request envelope.')
                expected = {'version', 'id', 'op'} | (WIFI_FIELDS[command['op']] if command['op'] in WIFI_FIELDS else
                    {'mode', 'requestID'} if command['op'] == 'network-mode' else set())
                if set(command) != expected:
                    raise ValueError('Invalid network command fields.')
                helper = self.wifi if command['op'] in WIFI_FIELDS else self.gadget
                result = helper.request({k: v for k, v in command.items() if k not in ('version', 'id')})
                if 'error' in result:
                    if result.get('code') == 'busy': raise GadgetBusy(result['error'])
                    raise ValueError(result['error'])
                response.update(result, ok=True)
            except GadgetBusy as error:
                response.update(error=str(error), code='busy')
            except (OSError, ValueError) as error:
                response['error'] = str(error)[:512]
            encoded = json.dumps(response, separators=(',', ':'), ensure_ascii=False).encode()
            if len(encoded) > 4096: raise ProtocolError('Management response exceeded its bound.')
            return encoded
        response = json.loads(self.tablets.handle(data, peer, authenticated, enrolling))
        if response.get('ok'):
            response['enrollmentVersion'] = 1
            response['relayKey'] = self.native.public_key
        encoded = json.dumps(response, separators=(',', ':'), ensure_ascii=False).encode()
        while len(encoded) > 4096 and response.get('candidates'):
            response['candidates'].pop()
            encoded = json.dumps(response, separators=(',', ':'), ensure_ascii=False).encode()
        if len(encoded) > 4096:
            raise ProtocolError('Tablet setup response exceeded its bound.')
        return encoded

    def claim(self, owner, transport, emit, busy, close):
        if self.owner is not None:
            raise ProtocolError('The relay already has an active headset connection.')
        self.native.transport(transport)
        self.native.allow_enrollment(self.tablets.initial({}))
        self.owner, self.emit, self.busy, self.close_connection = owner, emit, busy, close
        print(('Network' if transport == 2 else 'Bluetooth') + ' headset connected; authenticating.', flush=True)

    def receive(self, owner, data):
        if owner != self.owner:
            raise ProtocolError('This connection does not own the session.')
        self.capture.poll()
        self.native.tablet(self.capture.attached)
        for reply in self.native.receive(data):
            self.emit(reply)

    def enroll_headset(self, owner):
        if owner != self.owner or not self.native.enrolling:
            raise RuntimeError('The initiating encrypted setup session has ended.')
        try:
            self.native.finish_enrollment()
        except ProtocolError as error:
            raise RuntimeError('Could not save headset ownership.') from error
        print('Tablet verified; initiating headset ownership saved.', flush=True)

    def cancel_setup(self, owner):
        try:
            self.tablets.cancel(owner)
        except (OSError, RuntimeError, ValueError) as error:
            print('Tablet cleanup will retry after Bluetooth returns: ' + str(error), flush=True)

    def release(self, owner):
        if owner != self.owner or owner is None:
            return
        self.cancel_setup(owner)
        self.native.disconnect()
        self.owner = self.emit = self.busy = self.close_connection = None
        self.was_observing = False
        print('Headset link closed; existing trust retained.', flush=True)

    def button(self, code, value):
        if self.owner:
            self.native.tablet(self.capture.attached)
            self.emit(self.native.button(code, value))

    def tick(self):
        try:
            self.tablets.tick()
        except (OSError, RuntimeError, ValueError) as error:
            if self.tablets.owner:
                self.cancel_setup(self.tablets.owner)
            self.tablets.message = 'Bluetooth tablet management is unavailable; reconnect the adapter.'
        self.capture.poll()
        self.native.tablet(self.capture.attached)
        if not self.owner:
            return
        try:
            self.emit(self.native.tick())
            observing = self.native.observing
            if observing and not self.was_observing:
                self.capture.dirty = True
            self.was_observing = observing
            now = time.monotonic()
            if (observing and not self.busy() and now - self.last_sample >= 0.05 and
                    (self.capture.dirty or now - self.last_sample >= 1)):
                self.emit(self.native.sample(self.capture.sample()))
                self.last_sample = now
        except (ProtocolError, BufferError, TimeoutError, OSError) as error:
            print('Headset session ended: ' + str(error), flush=True)
            self.close_connection()

    def close(self):
        self.release(self.owner)
        self.capture.close()
        self.native.close()
