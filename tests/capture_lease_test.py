# SPDX-License-Identifier: GPL-3.0-or-later
"""Portable coverage for the Linux abstract-socket capture contract."""
import errno
import json
from pathlib import Path
import socket
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from avp_relay.capture import Capture, usb_identifier
from avp_relay.capture_lease import ADDRESS, CaptureBusy, CaptureLease
from avp_relay.core import RelayCore
from avp_relay.tablets import Tablets


class FakeSocket:
    bound = set()

    def __init__(self, family, kind):
        self.family, self.kind = family, kind
        self.address = None
        self.nonblocking = False

    def setblocking(self, enabled):
        self.nonblocking = not enabled

    def bind(self, address):
        if address in self.bound:
            raise OSError(errno.EADDRINUSE, 'Address in use')
        self.address = address
        self.bound.add(address)

    def connect(self, address):
        if address not in self.bound:
            raise OSError(errno.ENOENT, 'No owner')

    def close(self):
        if self.address is not None:
            self.bound.remove(self.address)
            self.address = None


class FakeLease:
    def __init__(self):
        self.allowed = False
        self.held = False

    def acquire(self):
        self.held = self.held or self.allowed
        return self.held

    def release(self):
        self.held = False

    def busy(self):
        return not self.held and not self.allowed


class Backend:
    available = True

    def __init__(self):
        self.calls = []
        self.items = {'AA:BB:CC:DD:EE:01': {'Name': 'Wacom tablet', 'Class': 0x0500,
                                            'Paired': True, 'Modalias': 'usb:v056Ap0001',
                                            'UUIDs': ['00001812-0000-1000-8000-00805f9b34fb']}}

    def devices(self):
        return self.items

    def start_scan(self):
        self.calls.append('scan')


class CaptureLeaseTests(unittest.TestCase):
    def test_same_abstract_address_contends_and_reacquires_after_close(self):
        FakeSocket.bound.clear()
        first, second = CaptureLease(), CaptureLease()
        with patch('avp_relay.capture_lease.socket.socket', side_effect=FakeSocket):
            self.assertTrue(first.acquire())
            self.assertTrue(first.acquire())  # Same lease object never binds twice.
            self.assertEqual(FakeSocket.bound, {ADDRESS})
            self.assertEqual(ADDRESS, b'\0plank-tablet-capture-v1')
            self.assertEqual((first.socket.family, first.socket.kind),
                             (socket.AF_UNIX, socket.SOCK_DGRAM))
            self.assertTrue(first.socket.nonblocking)
            self.assertFalse(second.acquire())
            self.assertFalse(second.held)
            self.assertTrue(second.busy())
            first.release()
            self.assertFalse(second.busy())
            self.assertTrue(second.acquire())
            second.release()
        self.assertEqual(FakeSocket.bound, set())

    def test_idle_metadata_never_opens_evdev_and_busy_activation_fails_closed(self):
        lease = FakeLease()
        capture = Capture(lease=lease)
        self.addCleanup(capture.close)
        identity = ('usb:/sys/devices/usb1/1-2', '', 3)
        tablet = {'id': usb_identifier(identity), 'name': 'Wacom', 'serial': None, 'port': '1-2'}
        with patch('avp_relay.capture.candidates', return_value={identity: [('event7', 'pen', [])]}), \
                patch('avp_relay.capture.usb_details', return_value=tablet), \
                patch('avp_relay.capture.os.open') as opener:
            capture.discover()
            self.assertTrue(capture.available)
            self.assertFalse(capture.attached)
            self.assertTrue(capture.capture_busy)
            self.assertTrue(capture.usb_status()[0]['active'])
            opener.assert_not_called()
            with self.assertRaises(CaptureBusy):
                capture.poll(active=True)
            opener.assert_not_called()
            lease.allowed = True
            with patch('avp_relay.capture.os.open', side_effect=OSError(errno.ENOENT, 'unplugged')) as opened:
                capture.poll(active=True)
                opened.assert_called_once()
            self.assertTrue(lease.held)
            capture.deactivate()
            self.assertFalse(lease.held)

    def test_busy_service_rejects_scan_pair_and_selection_without_mutation(self):
        with tempfile.TemporaryDirectory() as directory:
            backend = Backend()
            allowed = False
            selected = []
            usb_used = []

            def require():
                if not allowed:
                    raise CaptureBusy('Tablet input is in use by PLANK.')

            manager = Tablets(backend, directory, lambda: True, selected.append,
                lambda: True, require_capture=require,
                usb_status=lambda: [{'id': 'usb:0123456789abcdef'}], select_usb=usb_used.append,
                capture_active=lambda: False, capture_busy=lambda: not allowed)
            manager.discovered.add('AA:BB:CC:DD:EE:01')
            status = json.loads(manager.handle(b'{"version":1,"id":1,"op":"status"}',
                'headset', authenticated=True))
            self.assertTrue(status['attached'])  # Physical metadata remains visible.
            self.assertFalse(status['captureActive'])
            self.assertTrue(status['captureBusy'])
            for op, tablet in [('scan', None), ('pair', 'AA:BB:CC:DD:EE:01'),
                               ('connect', 'AA:BB:CC:DD:EE:01'),
                               ('select', 'AA:BB:CC:DD:EE:01'),
                               ('remove', 'AA:BB:CC:DD:EE:01'),
                               ('use-usb', 'usb:0123456789abcdef')]:
                with self.subTest(op=op):
                    request = {'version': 1, 'id': 1, 'op': op}
                    if tablet:
                        request['tablet'] = tablet
                    result = json.loads(manager.handle(json.dumps(request).encode(),
                        'headset', authenticated=True))
                    self.assertFalse(result['ok'])
                    self.assertIn('in use', result['error'])
                    self.assertIsNone(manager.owner)
                    self.assertEqual(manager.state['pending'], None)
            self.assertEqual(backend.calls, [])
            self.assertEqual(selected, [])
            self.assertEqual(usb_used, [])
            allowed = True
            result = json.loads(manager.handle(b'{"version":1,"id":2,"op":"scan"}',
                'headset', authenticated=True))
            self.assertTrue(result['ok'])
            self.assertFalse(result['captureBusy'])
            self.assertEqual(backend.calls, ['scan'])

    def test_usb_enrollment_requires_open_input_even_when_metadata_is_present(self):
        lease = FakeLease()
        lease.allowed = True
        capture = Capture(lease=lease)
        self.addCleanup(capture.close)
        identity = ('usb:/sys/devices/usb1/1-2', '', 3)
        target = usb_identifier(identity)
        with patch('avp_relay.capture.candidates', return_value={identity: [('event7', 'pen', [])]}), \
                patch('avp_relay.capture.usb_details', return_value={
                    'id': target, 'name': 'Wacom', 'serial': None, 'port': '1-2'}), \
                patch('avp_relay.capture.os.open', side_effect=OSError(errno.ENOENT, 'unplugged')):
            with self.assertRaisesRegex(ValueError, 'no longer ready'):
                capture.use_usb(target)
        self.assertIsNone(capture.usb_selection)
        self.assertFalse(capture.attached)

    def test_wrong_setup_owner_cannot_release_capture(self):
        core = object.__new__(RelayCore)
        core.tablets = Mock(owner='headset', phase='scanning')
        core.capture = Mock()
        core.owner = None
        core.native = Mock(observing=False, approval_pending=0)
        core.cancel_setup('stranger')
        core.tablets.cancel.assert_not_called()
        core.capture.deactivate.assert_not_called()

    def test_capture_activation_covers_legacy_button_proof_and_live_readings(self):
        core = object.__new__(RelayCore)
        core.owner = 'headset'
        core.tablets = Mock(phase='idle')
        core.capture = Mock(available=True, attached=True)
        core.native = Mock(observing=False, approval_pending=0)
        core.sync_capture()
        core.capture.poll.assert_called_with(active=False)
        core.capture.require_lease.assert_not_called()
        core.capture.deactivate.assert_called_once()
        for observing, approval in ((False, 1), (True, 0)):
            core.capture.reset_mock()
            core.native.observing, core.native.approval_pending = observing, approval
            core.sync_capture()
            core.capture.require_lease.assert_called_once()
            core.capture.poll.assert_called_once_with(active=True)
            core.capture.deactivate.assert_not_called()


if __name__ == '__main__':
    unittest.main()
