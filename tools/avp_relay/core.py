# SPDX-License-Identifier: GPL-3.0-or-later
"""Single owner of tablet input, enrollment and identity across transports."""
import json
import time

from .capture import Capture
from .capture_lease import CaptureBusy
from . import drawing_status
from .native import Native, ProtocolError
from .tablets import Tablets
from .gadget_client import GadgetClient, GadgetBusy
from .wifi_protocol import FIELDS as WIFI_FIELDS, unavailable as wifi_unavailable


class RelayCore:
    transport = stats = None
    queued = staticmethod(lambda: None)

    def __init__(self, args, backend):
        self.native = Native(args.library, args.state_dir)
        self.tcp_port = None
        self.network_endpoints = lambda: []
        # The drawing handoff is read from the raw drawing service's local
        # public-status socket, at most once per authenticated status request
        # and never on a timer of its own. Injectable for tests.
        self.read_drawing_handoff = drawing_status.read_handoff
        self.owner = None
        self.emit = self.busy = self.close_connection = None
        self.capture = Capture(args.tablet, self.button, fixed=bool(args.tablet))
        self.gadget = GadgetClient()
        self.wifi = GadgetClient('/run/plank-avp-relay/wifi/control.sock', 'wifi-status', wifi_unavailable, 'Wi-Fi')
        self.tablets = Tablets(backend, args.state_dir, lambda: self.native.has_clients,
            self.select, lambda: self.capture.available, args.tablet,
            enroll_headset=self.enroll_headset, usb_status=self.capture.usb_status,
            select_usb=self.capture.use_usb, require_capture=self.capture.require_lease,
            capture_active=lambda: self.capture.attached, capture_busy=lambda: self.capture.capture_busy)
        self.native.on_management = lambda data: self.request(data, self.owner,
            self.native.management_authorized, self.native.enrolling)
        self.last_sample = 0
        self.transport = None
        self.queued = lambda: None
        self.reset_stats()

    def reset_stats(self, now=None):
        # Preview delivery measurements, logged once per second while observing.
        self.stats = dict(started=now, reports=self.capture.reports, records=0, writes=0,
                          bytes=0, oldest=0.0, pending=0, queued=0)

    def record_stats(self, now, force=False):
        stats = self.stats
        if stats is None or stats['started'] is None:
            self.reset_stats(now)
            return
        pending = self.capture.pending
        if pending:
            stats['oldest'] = max(stats['oldest'], now - pending[0][0])
        stats['pending'] = max(stats['pending'], len(pending))
        queued = self.queued()
        if queued is not None:
            stats['queued'] = max(stats['queued'], queued)
        if force or now - stats['started'] >= 1:
            elapsed = max(now - stats['started'], 0.001)
            print('Preview stats: link=%s reports/s=%.0f records/s=%.0f writes/s=%.0f bytes/s=%.0f '
                  'max-oldest-ms=%.0f max-pending=%d max-socket-queue=%d' % (
                      'bluetooth' if self.transport == 1 else 'network',
                      (self.capture.reports - stats['reports']) / elapsed, stats['records'] / elapsed,
                      stats['writes'] / elapsed, stats['bytes'] / elapsed, stats['oldest'] * 1000,
                      stats['pending'], stats['queued']), flush=True)
            self.reset_stats(now)

    def select(self, value):
        self.capture.close_nodes()
        self.capture.identity = None
        self.capture.detected_identity = None
        self.capture.selected = value.lower() if value else None
        self.capture.last_scan = 0

    def sync_capture(self):
        active = bool(self.owner and (self.native.observing or self.native.approval_pending))
        if active:
            self.capture.require_lease()
        self.capture.observe(bool(self.owner and self.native.observing))
        self.capture.poll(active=active)
        self.native.tablet(self.capture.attached if active else self.capture.available)
        if not active and self.tablets.phase not in ('scanning', 'pairing', 'connecting', 'verifying'):
            self.capture.deactivate()

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
                if command['op'] == 'wifi-status':
                    # The authenticated peer can reach the surviving Wi-Fi IP
                    # without a stale Bonjour hostname after Ethernet loss.
                    response['tcpPort'] = getattr(self, 'tcp_port', None)
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
            # Bluetooth is a rendezvous route across subnets that do not carry
            # mDNS. Endpoint hints are sent only to the authenticated owner;
            # connecting to one still requires the same pinned Noise identity.
            if command.get('op') == 'status' and authenticated and peer == self.owner:
                response['tcpPort'] = self.tcp_port
                response['networkAddresses'] = self.network_endpoints()
                # Public drawing metadata for the handoff Setup offers: the
                # drawing identity, its protocol and reachable routes, or an
                # explicit unavailable reason. Owner-only, exactly like the
                # endpoint hints above, whose semantics are unchanged.
                response['drawingHandoff'] = self.read_drawing_handoff()
        encoded = json.dumps(response, separators=(',', ':'), ensure_ascii=False).encode()
        if len(encoded) > 4096 and isinstance(response.get('drawingHandoff'), dict) and \
                response['drawingHandoff'].get('state') == 'ready':
            # Report the bound rather than truncating a descriptor, and shed the
            # convenience before shedding a tablet candidate.
            response['drawingHandoff'] = drawing_status.unavailable('response.tooLarge')
            encoded = json.dumps(response, separators=(',', ':'), ensure_ascii=False).encode()
        while len(encoded) > 4096 and response.get('candidates'):
            response['candidates'].pop()
            encoded = json.dumps(response, separators=(',', ':'), ensure_ascii=False).encode()
        if len(encoded) > 4096:
            raise ProtocolError('Tablet setup response exceeded its bound.')
        return encoded

    def claim(self, owner, transport, emit, busy, close, queued=None):
        if self.owner is not None:
            raise ProtocolError('The relay already has an active headset connection.')
        self.native.transport(transport)
        self.transport, self.queued = transport, queued or (lambda: None)
        self.reset_stats()
        self.native.allow_enrollment(self.tablets.initial({}))
        self.owner, self.emit, self.busy, self.close_connection = owner, emit, busy, close
        print(('Network' if transport == 2 else 'Bluetooth') + ' headset connected; authenticating.', flush=True)

    def receive(self, owner, data):
        if owner != self.owner:
            raise ProtocolError('This connection does not own the session.')
        self.sync_capture()
        replies = self.native.receive(data)
        self.sync_capture()
        for reply in replies:
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
        if owner is None or owner != self.tablets.owner:
            return
        try:
            self.tablets.cancel(owner)
        except (OSError, RuntimeError, ValueError) as error:
            print('Tablet cleanup will retry after Bluetooth returns: ' + str(error), flush=True)
        if self.tablets.phase not in ('scanning', 'pairing', 'connecting', 'verifying') and not (
                self.owner and (self.native.observing or self.native.approval_pending)):
            self.capture.deactivate()

    def release(self, owner):
        if owner != self.owner or owner is None:
            return
        self.cancel_setup(owner)
        self.native.disconnect()
        self.capture.observe(False)
        if self.tablets.phase not in ('scanning', 'pairing', 'connecting', 'verifying'):
            self.capture.deactivate()
        self.owner = self.emit = self.busy = self.close_connection = None
        self.transport, self.queued = None, lambda: None
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
        try:
            self.sync_capture()
            if not self.owner:
                return
            self.emit(self.native.tick())
            observing = self.native.observing
            now = time.monotonic()
            if observing:
                self.record_stats(now)
                self.capture.check_pending()
                if self.capture.dirty or (not self.capture.pending and now - self.last_sample >= 1):
                    self.capture.enqueue(self.capture.sample())
                if not self.busy():
                    samples = self.capture.take_samples()
                    if samples:
                        data = b''.join(self.native.sample(sample) for sample in samples)
                        self.emit(data)
                        self.last_sample = now
                        if self.stats:
                            self.stats['records'] += len(samples)
                            self.stats['writes'] += 1
                            self.stats['bytes'] += len(data)
        except (ProtocolError, BufferError, TimeoutError, OSError, CaptureBusy) as error:
            if not self.owner:
                raise
            if self.stats and self.stats['started'] is not None:
                self.record_stats(time.monotonic(), force=True)
            print('Headset session ended: ' + str(error), flush=True)
            self.close_connection()

    def close(self):
        self.release(self.owner)
        self.capture.close()
        self.native.close()
