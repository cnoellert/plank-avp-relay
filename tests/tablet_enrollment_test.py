# SPDX-License-Identifier: GPL-3.0-or-later
import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from ble_lab.tablets import HID, Tablets, save
from ble_lab.admin import remove_tablet
from ble_lab.transport import SetupChannel
from ble_lab.tablet_bluez import TabletAgent, Denied

FIRST = 'AA:BB:CC:DD:EE:01'
SECOND = 'AA:BB:CC:DD:EE:02'
UUID = sorted(HID)[0]


class Backend:
    def __init__(self):
        self.items = {FIRST: {'Name': 'Tablet', 'Class': 0x0500}}
        self.bondable = False
        self.calls = []
        self.pair_done = self.connect_done = None
        self.ready = True
    def devices(self): return copy.deepcopy(self.items)
    def pairable(self): return self.bondable
    def set_pairable(self, value): self.bondable = value
    def start_scan(self): self.calls.append('scan')
    def stop_scan(self): self.calls.append('stop')
    def pair(self, target, done): self.calls.append(('pair', target)); self.pair_done = done
    def connect(self, target, done): self.calls.append(('connect', target)); self.connect_done = done
    def cancel_pair(self, target): self.calls.append(('cancel', target))
    def remove(self, target): self.calls.append(('remove', target)); self.items.pop(target, None)
    def trust(self, target): self.calls.append(('trust', target)); self.items[target]['Trusted'] = True
    def input_ready(self, target): return self.ready
    def close(self): self.calls.append('close-agent')


class EnrollmentTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.backend = Backend()
        self.clients = False
        self.enrolled = []
        self.selected = []
        self.now = 100
        self.manager = self.create()
        self.request = 0

    def create(self):
        return Tablets(self.backend, self.directory, lambda: self.clients,
                       self.selected.append, lambda: False, clock=lambda: self.now,
                       enroll_headset=self.enroll)

    def enroll(self, owner):
        self.assertFalse(self.clients)
        self.enrolled.append(owner)
        self.clients = True

    def call(self, op='status', target=None, authenticated=False, owner='headset', enrolling=True):
        self.request += 1
        payload = {'version': 1, 'id': self.request, 'op': op}
        if target: payload['tablet'] = target
        return json.loads(self.manager.handle(json.dumps(payload).encode(), owner, authenticated, enrolling))

    def start(self, authenticated=False):
        self.assertTrue(self.call('scan', authenticated=authenticated)['ok'])
        self.assertTrue(self.call('pair', FIRST, authenticated)['ok'])

    def finish(self):
        self.backend.items[FIRST].update(Modalias='usb:v056Ap9999d0001', UUIDs=[UUID],
            Paired=True, Bonded=True, Connected=True, ServicesResolved=True)
        self.backend.pair_done()
        self.backend.connect_done()
        self.now += 1
        self.manager.tick()

    def test_first_tablet_setup_verifies_input_and_approves_initiating_headset(self):
        self.assertTrue(self.call()['initialSetup'])
        self.start()
        self.assertTrue(self.backend.bondable)
        self.finish()
        self.assertEqual(self.manager.phase, 'ready')
        self.assertEqual(self.selected, [FIRST])
        self.assertTrue(self.clients)
        self.assertEqual(self.enrolled, ['headset'])
        self.assertFalse(self.backend.bondable)
        self.assertIn(('trust', FIRST), self.backend.calls)
        self.assertFalse(self.call()['canManage'])
        self.assertFalse(self.call('scan')['ok'])
        self.manager.cancel('headset')
        self.create()
        self.assertEqual(self.selected, [FIRST, FIRST])
        self.assertEqual((self.directory/'tablets.json').stat().st_mode & 0o777, 0o600)

    def test_existing_headset_or_bond_blocks_unauthenticated_mutations(self):
        self.clients = True
        self.assertFalse(self.call('scan')['ok'])
        self.assertTrue(self.call()['ok'])
        self.clients = False
        self.backend.items[FIRST].update(Modalias='usb:v056Ap1234', UUIDs=[UUID], Paired=True)
        self.assertFalse(self.call('scan', enrolling=False)['ok'])
        self.assertFalse(self.call('remove', FIRST)['ok'])
        self.assertNotIn(('remove', FIRST), self.backend.calls)

    def test_sleep_does_not_reopen_initial_setup(self):
        self.start(); self.finish(); self.manager.cancel('headset')
        self.backend.items = {}
        status = self.call()
        self.assertFalse(status['initialSetup'])
        self.assertEqual(status['tablets'][0]['id'], FIRST)
        self.assertFalse(status['tablets'][0]['connected'])
        self.assertFalse(self.call('scan')['ok'])

    def test_plaintext_bootstrap_is_read_only_even_when_unowned(self):
        self.assertTrue(self.call(enrolling=False)['ok'])
        self.assertFalse(self.call(enrolling=False)['canManage'])
        for operation in ('scan', 'pair', 'connect', 'select', 'remove'):
            self.assertFalse(self.call(operation, FIRST, enrolling=False)['ok'])
        self.assertEqual(self.backend.calls, [])
        self.assertFalse(self.clients)

    def test_remove_last_tablet_retains_owner_and_allows_replacement(self):
        self.start(); self.finish()
        self.assertTrue(self.call('remove', FIRST, True)['ok'])
        status = self.call(authenticated=True)
        self.assertEqual(status['tablets'], [])
        self.assertTrue(status['canManage'] and status['headsetAuthorized'])
        self.assertFalse(status['initialSetup'])
        self.assertFalse(self.call('scan', owner='stranger')['ok'])
        self.backend.items[FIRST] = {'Name': 'Replacement tablet', 'Class': 0x0500}
        self.start(authenticated=True); self.finish()
        self.assertEqual(self.enrolled, ['headset'])
        self.assertEqual(self.manager.phase, 'ready')

    def test_ownership_reset_can_reuse_retained_bond(self):
        self.start(); self.finish(); self.manager.cancel('headset')
        self.clients = False  # Explicit administrator reset, never automatic.
        self.assertTrue(self.call()['initialSetup'])
        self.assertTrue(self.call('connect', FIRST, owner='replacement')['ok'])
        self.backend.connect_done(); self.now += 1; self.manager.tick()
        self.assertEqual(self.enrolled, ['headset', 'replacement'])
        self.assertEqual(self.manager.phase, 'ready')
        self.assertEqual(self.backend.calls.count(('pair', FIRST)), 1)

    def test_ownership_write_failure_does_not_strand_new_bond(self):
        def fail(owner): raise RuntimeError('disk unavailable')
        self.manager.enroll_headset = fail
        self.start(); self.finish()
        self.assertEqual(self.manager.phase, 'failed')
        self.assertFalse(self.clients)
        self.assertNotIn(FIRST, self.backend.items)
        self.assertIsNone(self.manager.state['pending'])

    def test_failed_new_device_removed_but_existing_bonds_preserved(self):
        self.backend.items[SECOND] = {'Modalias': 'usb:v056Ap1111', 'UUIDs': [UUID], 'Paired': True}
        self.clients = True
        self.start(authenticated=True)
        self.backend.pair_done(RuntimeError('failed'))
        self.assertEqual(self.manager.phase, 'failed')
        self.assertNotIn(FIRST, self.backend.items)
        self.assertIn(SECOND, self.backend.items)
        self.assertFalse(self.backend.bondable)

    def test_spoofed_name_or_missing_input_never_becomes_trusted(self):
        self.backend.items[FIRST]['Name'] = 'Wacom'
        self.start()
        self.backend.items[FIRST].update(Modalias='usb:v1234p0001', UUIDs=[UUID],
            Paired=True, Bonded=True, ServicesResolved=True)
        self.backend.pair_done(); self.backend.connect_done(); self.manager.tick()
        self.assertEqual(self.manager.phase, 'failed')
        self.assertNotIn(('trust', FIRST), self.backend.calls)
        self.assertFalse(self.clients)
        self.assertEqual(self.enrolled, [])

    def test_real_vendor_still_requires_persistent_bond_and_pen_pad_input(self):
        self.start()
        self.backend.ready = False
        self.finish()
        self.assertEqual(self.manager.phase, 'verifying')
        self.now += 16; self.manager.tick()
        self.assertEqual(self.manager.phase, 'failed')
        self.assertNotIn(('trust', FIRST), self.backend.calls)
        self.assertFalse(self.clients)
        self.assertEqual(self.enrolled, [])

    def test_cancel_timeout_and_stale_callback_cannot_commit_enrollment(self):
        self.start()
        callback = self.backend.pair_done
        self.call('cancel')
        callback()
        self.assertEqual(self.manager.phase, 'idle')
        self.assertEqual(self.selected, [])
        self.assertEqual(self.enrolled, [])
        self.assertIsNone(self.manager.state['pending'])
        self.backend.items[FIRST] = {'Name': 'Tablet', 'Class': 0x0500}
        self.start()
        self.now += 61; self.manager.tick()
        self.assertEqual(self.manager.phase, 'failed')
        self.assertFalse(self.backend.bondable)

    def test_reconnect_failure_preserves_existing_tablet(self):
        self.clients = True
        self.backend.items[FIRST].update(Modalias='usb:v056Ap1234', UUIDs=[UUID], Paired=True)
        self.assertTrue(self.call('connect', FIRST, True)['ok'])
        self.backend.connect_done(RuntimeError('offline'))
        self.assertIn(FIRST, self.backend.items)
        self.assertNotIn(('remove', FIRST), self.backend.calls)

    def test_cross_peer_and_unselected_target_are_rejected(self):
        self.call('scan')
        self.assertFalse(self.call('pair', SECOND)['ok'])
        self.assertFalse(self.call('pair', FIRST, owner='stranger')['ok'])
        self.call('cancel', owner='stranger')
        self.assertEqual(self.manager.owner, 'headset')
        self.assertFalse(any(isinstance(call, tuple) and call[0] == 'pair' for call in self.backend.calls))

    def test_restart_cleans_only_journaled_provisional_device(self):
        self.start()
        self.backend.items[SECOND] = {'Paired': True}
        recovered = self.create()
        self.assertNotIn(FIRST, self.backend.items)
        self.assertIn(SECOND, self.backend.items)
        self.assertIsNone(recovered.state['pending'])
        self.assertFalse(self.backend.bondable)

    def test_scanning_is_bounded_even_with_status_polling(self):
        self.call('scan')
        for _ in range(60):
            self.now += 1
            self.call()
        self.manager.tick()
        self.assertFalse(self.manager.scanning)
        self.assertEqual(self.manager.phase, 'failed')

    def test_recovery_command_refuses_unrelated_devices(self):
        self.backend.items[SECOND] = {'Name': 'Keyboard', 'Paired': True}
        with self.assertRaises(ValueError):
            remove_tablet(self.backend, SECOND, self.directory)
        self.assertIn(SECOND, self.backend.items)
        self.backend.items[FIRST].update(Modalias='usb:v056Ap1234', UUIDs=[UUID], Paired=True)
        remove_tablet(self.backend, FIRST, self.directory)
        self.assertNotIn(FIRST, self.backend.items)
        self.assertIn(SECOND, self.backend.items)

    def test_agent_rejects_other_devices_services_and_pin_methods(self):
        agent = object.__new__(TabletAgent)
        agent.backend = SimpleNamespace(pairing_path='/org/bluez/hci0/dev_SELECTED')
        agent.RequestAuthorization('/org/bluez/hci0/dev_SELECTED')
        agent.AuthorizeService('/org/bluez/hci0/dev_SELECTED', UUID)
        with self.assertRaises(Denied): agent.RequestAuthorization('/org/bluez/hci0/dev_OTHER')
        with self.assertRaises(Denied): agent.AuthorizeService('/org/bluez/hci0/dev_SELECTED', 'battery')
        with self.assertRaises(Denied): agent.RequestConfirmation('/org/bluez/hci0/dev_SELECTED', 123456)
        with self.assertRaises(Denied): agent.RequestPinCode('/org/bluez/hci0/dev_SELECTED')

    def test_failure_to_enable_bonding_cleans_provisional_journal(self):
        original = self.backend.set_pairable
        def fail(value):
            if value: raise RuntimeError('controller unavailable')
            original(value)
        self.backend.set_pairable = fail
        self.call('scan')
        self.assertFalse(self.call('pair', FIRST)['ok'])
        self.assertIsNone(self.manager.state['pending'])
        self.assertFalse(self.backend.bondable)
        self.assertEqual(self.manager.phase, 'failed')

    def test_restart_during_saved_reconnect_keeps_bond(self):
        self.backend.items[FIRST].update(Modalias='usb:v056Ap1234', UUIDs=[UUID], Paired=True)
        self.assertTrue(self.call('connect', FIRST, True)['ok'])
        self.create()
        self.assertIn(FIRST, self.backend.items)
        self.assertNotIn(('remove', FIRST), self.backend.calls)

    def test_bootstrap_fragmentation_and_disconnect_cancel_its_owner(self):
        emitted, canceled, closed = [], [], []
        channel = SetupChannel(emitted.append, closed.append,
                               lambda data, peer: b'{"ok":true}', canceled.append)
        channel.notifying = True
        peer = '/org/bluez/hci0/dev_AA'
        options = {'device': peer, 'link': 'LE'}
        payload = b'{"version":1,"id":1,"op":"status"}'
        record = len(payload).to_bytes(2, 'little') + payload
        for part in record:
            channel.receive(bytes([part]), options, '/org/bluez/hci0')
        while channel.queue.busy: channel.queue.confirm()
        self.assertEqual(b''.join(emitted)[2:], b'{"ok":true}')
        with self.assertRaises(ValueError):
            channel.receive(b'xx', {**options, 'device': peer+'B'}, '/org/bluez/hci0')
        channel.disconnect()
        self.assertEqual(canceled, [peer]); self.assertEqual(closed, [peer])


if __name__ == '__main__':
    unittest.main()
