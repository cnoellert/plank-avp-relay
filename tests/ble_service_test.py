# SPDX-License-Identifier: GPL-3.0-or-later
import configparser
import os
from pathlib import Path
import socket
import sys
import tempfile
import unittest
from unittest.mock import MagicMock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from avp_relay.capture import Capture, SAMPLE, candidates, usb_identifier
from avp_relay.config import hostname_name, read_settings
from avp_relay.controller import clear_advertisements
from avp_relay.notify import ready
from avp_relay.bluez import Server, PROPERTIES, L2CAPEndpoint
from avp_relay.core import RelayCore


class ServiceTests(unittest.TestCase):
    def test_enrollment_commit_requires_same_active_provisional_session(self):
        server = MagicMock()
        server.owner = 'initiating-headset'
        server.native.enrolling = True
        with self.assertRaises(RuntimeError):
            RelayCore.enroll_headset(server, 'other-headset')
        server.native.finish_enrollment.assert_not_called()
        server.native.enrolling = False
        with self.assertRaises(RuntimeError):
            RelayCore.enroll_headset(server, 'initiating-headset')
        server.native.finish_enrollment.assert_not_called()
        server.native.enrolling = True
        RelayCore.enroll_headset(server, 'initiating-headset')
        server.native.finish_enrollment.assert_called_once()

    def test_hostname_default_and_explicit_override(self):
        with patch('avp_relay.config.socket.gethostname', return_value='plank-tablet-relay-02.local'):
            self.assertEqual(self.read('[relay]\n').name, 'plank-tablet-relay-02')
            self.assertEqual(self.read('[relay]\nname=Studio tablet\n').name, 'Studio tablet')
        with patch('avp_relay.config.socket.gethostname', return_value='tablet-relay-' + 'a' * 40):
            first = hostname_name()
        with patch('avp_relay.config.socket.gethostname', return_value='tablet-relay-' + 'a' * 39 + 'b'):
            self.assertNotEqual(first, hostname_name())
            self.assertLessEqual(len(hostname_name().encode()), 26)

    def read(self, content):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'relay.conf'
            path.write_text(content)
            return read_settings(path)

    def test_default_configuration_does_not_take_over_controller(self):
        settings = self.read('[relay]\n')
        self.assertFalse(settings.exclusive_adapter)
        self.assertFalse(settings.disable_controller_address_resolution)
        self.assertEqual(settings.tablet, '')

    def test_opt_in_and_tablet_selection(self):
        settings = self.read('[relay]\nadapter=hci2\ntablet=AA:BB:CC:DD:EE:FF\n'
                             'exclusive_adapter=yes\ndisable_controller_address_resolution=true\n')
        self.assertTrue(settings.exclusive_adapter)
        self.assertTrue(settings.disable_controller_address_resolution)
        self.assertEqual(settings.adapter, 'hci2')
        self.assertEqual(settings.tablet, 'AA:BB:CC:DD:EE:FF')

    def test_rejects_typos_and_invalid_values(self):
        for content in ('', '[other]\n', '[DEFAULT]\nadapter=hci0\n[relay]\n',
                        '[relay]\n[other]\n', '[relay]\nexclusive_adaptor=yes\n',
                        '[relay]\nadapter=hci-1\n', '[relay]\nadapter=hci١\n',
                        '[relay]\nexclusive_adapter=maybe\n', '[relay]\ntablet=/dev/input/event0\n',
                        '[relay]\nname=' + 'é' * 14, '[relay]\nname=\n',
                        '[relay]\nadapter=hci0\nadapter=hci1\n'):
            with self.subTest(content=content), self.assertRaises((ValueError, configparser.Error)):
                self.read(content)

    def test_readiness_notification_reaches_systemd_socket(self):
        with tempfile.TemporaryDirectory() as folder:
            path = str(Path(folder) / 'notify')
            with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as receiver:
                receiver.bind(path)
                receiver.settimeout(1)
                with patch.dict(os.environ, {'NOTIFY_SOCKET': path}):
                    ready()
                self.assertIn(b'READY=1\n', receiver.recv(256))

    def test_ambiguous_tablets_stay_offline_without_opening_either(self):
        capture = Capture()
        candidates = {('bluetooth:a', '', 5): [], ('bluetooth:b', '', 5): []}
        with patch('avp_relay.capture.candidates', return_value=candidates), \
                patch('avp_relay.capture.os.open') as opener:
            capture.discover()
            self.assertFalse(capture.attached)
            self.assertIsNone(capture.identity)
            opener.assert_not_called()
        capture.close()

    def test_sleep_clears_readings_but_retains_physical_identity(self):
        capture = Capture()
        capture.identity = ('bluetooth:a', 'local-controller', 5)
        capture.axes = {0: 99, 1: 80, 24: 4000}
        capture.ranges = {0: (0, 100), 1: (0, 100), 24: (0, 8191)}
        capture.keys = {320, 330}
        capture.contacts = {0: True}
        capture.pad_mask = 511
        capture.close_nodes()
        snapshot = SAMPLE.unpack(capture.sample())
        self.assertEqual(snapshot[1:3], (0, 0))
        self.assertEqual(snapshot[5:17], (0,) * 12)
        self.assertEqual(capture.identity, ('bluetooth:a', 'local-controller', 5))
        capture.close()

    def test_usb_overrides_saved_bluetooth_and_returns_to_it_after_unplug(self):
        bluetooth = ('bluetooth:aa:bb:cc:dd:ee:01', 'controller', 5)
        usb = ('usb:/sys/devices/usb1/1-2', '', 3)
        other = ('bluetooth:aa:bb:cc:dd:ee:02', 'controller', 5)
        capture = Capture('AA:BB:CC:DD:EE:01')
        self.addCleanup(capture.close)
        capture.identity = bluetooth
        self.assertEqual(set(capture.choose({bluetooth: [], usb: [], other: []})), {usb})
        capture.identity = usb
        self.assertEqual(set(capture.choose({bluetooth: [], other: []})), {bluetooth})
        self.assertEqual(capture.selected, 'aa:bb:cc:dd:ee:01')
        capture.selected = 'none'  # Removing the last Bluetooth bond must not block USB.
        self.assertEqual(set(capture.choose({usb: [], other: []})), {usb})
        self.assertEqual(capture.choose({other: []}), {})

    def test_usb_selection_and_explicit_config_do_not_pick_an_arbitrary_tablet(self):
        first = ('usb:/sys/devices/usb1/1-1', '', 3)
        second = ('usb:/sys/devices/usb1/1-2', '', 3)
        capture = Capture()
        self.addCleanup(capture.close)
        self.assertEqual(len(capture.choose({first: [], second: []})), 2)
        capture.usb_selection = usb_identifier(second)
        self.assertEqual(set(capture.choose({first: [], second: []})), {second})
        capture.identity = second
        self.assertEqual(set(capture.choose({first: []})), {first})  # Replugged in another port.
        fixed = Capture(first[0], fixed=True)
        self.addCleanup(fixed.close)
        self.assertEqual(set(fixed.choose({first: [], second: []})), {first})
        self.assertEqual(fixed.choose({second: []}), {})
        with patch.object(capture, 'discover'), self.assertRaises(ValueError):
            capture.use_usb('usb:invented-by-client')

    def test_usb_inventory_accepts_pen_only_wacom_without_a_product_allowlist(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            device = root / 'devices/usb1/1-2'
            device.mkdir(parents=True)
            (device / 'idVendor').write_text('056a')
            (device / 'idProduct').write_text('ffff')
            input = device / '1-2:1.0/hid/input/input0'
            (input / 'id').mkdir(parents=True)
            (input / 'capabilities').mkdir()
            for name, value in [('bustype', '0003'), ('vendor', '056a')]:
                (input / 'id' / name).write_text(value)
            # sysfs represents bitmaps as native-word chunks, high word first.
            import struct
            width = struct.calcsize('L') * 8
            def bits(codes):
                value = sum(1 << code for code in codes)
                return ' '.join(format((value >> offset) & ((1 << width)-1), 'x')
                                for offset in reversed(range(0, value.bit_length(), width)))
            (input / 'capabilities/key').write_text(bits([0x140]))
            (input / 'capabilities/abs').write_text(bits([0, 1, 24]))
            event = root / 'class/input/event0'
            event.mkdir(parents=True)
            (event / 'device').symlink_to(input)
            found = candidates(root / 'class/input')
            self.assertEqual(len(found), 1)
            self.assertEqual(next(iter(found.values()))[0][1], 'pen')
            (input / 'id/vendor').write_text('1234')
            self.assertEqual(candidates(root / 'class/input'), {})

    def test_bluetooth_failure_retries_without_stopping_network(self):
        for event in ('daemon', 'power', 'removed'):
            server = MagicMock()
            server.adapter = '/org/bluez/hci0'
            server.failure = None
            if event == 'daemon':
                Server.bluez_changed(server, 'org.bluez', ':1.10', '')
            elif event == 'power':
                Server.adapter_changed(server, 'org.bluez.Adapter1', {'Powered': False}, [])
            else:
                Server.removed(server, server.adapter, ['org.bluez.Adapter1'])
            server.bluetooth_unavailable.assert_called_once()
            server.loop.quit.assert_not_called()

    def test_missing_adapter_skips_registration_and_keeps_tcp_and_input_polling(self):
        server = MagicMock()
        server.adapter = '/org/bluez/hci0'
        server.advertising = server.registering = server.adapter_missing = False
        server.next_registration = 0
        server.controller_workaround = False
        server.echo = server.setup = None
        with patch('avp_relay.bluez.Path.exists', return_value=False), \
                patch('avp_relay.bluez.time.monotonic', return_value=100):
            Server.tick(server)
            server.next_registration = 0
            Server.tick(server)
        server.register_bluetooth.assert_not_called()
        server.bluetooth_unavailable.assert_called_once()
        self.assertEqual(server.network.poll.call_count, 2)
        self.assertEqual(server.core.tick.call_count, 2)

    def test_busy_adapter_is_rejected_before_controller_changes(self):
        server = MagicMock()
        server.exclusive_adapter = True
        properties = MagicMock()
        properties.Get.return_value = True  # Discovery already running.
        with patch('avp_relay.bluez.dbus.Interface', return_value=properties), \
                patch('avp_relay.bluez.clear_advertisements') as clear, \
                patch('avp_relay.bluez.disable_address_resolution') as workaround:
            with self.assertRaisesRegex(RuntimeError, 'no scan'):
                Server.register_bluetooth(server)
            properties.Set.assert_not_called()
            clear.assert_not_called()
            workaround.assert_not_called()

    def test_ready_after_advertisement_without_a_network_listener(self):
        server = MagicMock()
        server.controller_workaround = server.exclusive_adapter = False
        server.registration_generation = 0
        gatt, advertising, properties = MagicMock(), MagicMock(), MagicMock()
        properties.Get.return_value = True
        gatt.RegisterApplication.side_effect = lambda *a, **k: k['reply_handler']()
        advertising.RegisterAdvertisement.side_effect = lambda *a, **k: k['reply_handler']()
        interfaces = {'org.bluez.GattManager1': gatt,
                      'org.bluez.LEAdvertisingManager1': advertising, PROPERTIES: properties}
        with patch('avp_relay.bluez.dbus.Interface', side_effect=lambda _, kind: interfaces[kind]):
            Server.register_bluetooth(server)
        self.assertTrue(server.advertising)
        server.notify_ready.assert_called_once()

    def test_l2cap_listener_registered_after_controller_policy_and_before_gatt(self):
        server = MagicMock()
        server.exclusive_adapter = False
        server.controller_workaround = True
        server.registration_generation = 0
        server.l2cap = None
        server.peer = server.echo.peer = None
        server.setup = None
        properties = MagicMock()
        properties.Get.side_effect = lambda kind, field: {
            'Discovering': False, 'ActiveInstances': 0, 'Powered': True,
            'Address': 'AA:BB:CC:DD:EE:FF', 'AddressType': 'public'}[field]
        order = []
        gatt = MagicMock()
        gatt.RegisterApplication.side_effect = lambda *a, **k: order.append('gatt')
        def listening(*args, **kwargs):
            order.append('listen')
            return MagicMock(psm=128)
        with patch('avp_relay.bluez.dbus.Interface', side_effect=lambda _, name:
                   gatt if name == 'org.bluez.GattManager1' else properties), \
                patch('avp_relay.bluez.disable_address_resolution', side_effect=lambda _: order.append('policy')), \
                patch('avp_relay.bluez.L2CAPServer', side_effect=listening) as listener:
            Server.register_bluetooth(server)
        self.assertEqual(order, ['policy', 'listen', 'gatt'])
        listener.assert_called_once()
        self.assertEqual(listener.call_args.args, (server.core, 'AA:BB:CC:DD:EE:FF', 'public'))
        self.assertFalse(listener.call_args.kwargs['busy']())
        endpoint = MagicMock(server=server)
        self.assertEqual(bytes(L2CAPEndpoint.ReadValue(endpoint, {})), b'\x01\x80\x00')
        with self.assertRaises(Exception): L2CAPEndpoint.ReadValue(endpoint, {'offset': 1})
        active = server.l2cap
        Server.unregister_bluetooth(server)
        active.close.assert_called_once()
        self.assertIsNone(server.l2cap)
        server.network.close.assert_not_called()

    def test_tcp_configuration_and_port_bounds(self):
        self.assertTrue(self.read('[relay]\n').tcp_enabled)
        self.assertEqual(self.read('[relay]\n').tcp_port, 28991)
        self.assertFalse(self.read('[relay]\ntcp_enabled=false\n').tcp_enabled)
        for port in ('0', '-1', '80', '65536', 'invalid'):
            with self.assertRaises(ValueError): self.read('[relay]\ntcp_port=' + port)


if __name__ == '__main__':
    unittest.main()
