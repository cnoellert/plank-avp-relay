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
from ble_lab.capture import Capture, SAMPLE
from ble_lab.config import hostname_name, read_settings
from ble_lab.controller import clear_advertisements
from ble_lab.notify import ready
from ble_lab.bluez import Server, PROPERTIES
from ble_lab.core import RelayCore


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
        with patch('ble_lab.config.socket.gethostname', return_value='plank-tablet-relay-02.local'):
            self.assertEqual(self.read('[relay]\n').name, 'plank-tablet-relay-02')
            self.assertEqual(self.read('[relay]\nname=Studio tablet\n').name, 'Studio tablet')
        with patch('ble_lab.config.socket.gethostname', return_value='tablet-relay-' + 'a' * 40):
            first = hostname_name()
        with patch('ble_lab.config.socket.gethostname', return_value='tablet-relay-' + 'a' * 39 + 'b'):
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
        with patch('ble_lab.capture.candidates', return_value=candidates), \
                patch('ble_lab.capture.os.open') as opener:
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

    def test_busy_adapter_is_rejected_before_controller_changes(self):
        server = MagicMock()
        server.exclusive_adapter = True
        properties = MagicMock()
        properties.Get.return_value = True  # Discovery already running.
        with patch('ble_lab.bluez.dbus.Interface', return_value=properties), \
                patch('ble_lab.bluez.clear_advertisements') as clear, \
                patch('ble_lab.bluez.disable_address_resolution') as workaround:
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
        with patch('ble_lab.bluez.dbus.Interface', side_effect=lambda _, kind: interfaces[kind]):
            Server.register_bluetooth(server)
        self.assertTrue(server.advertising)
        server.notify_ready.assert_called_once()

    def test_tcp_configuration_and_port_bounds(self):
        self.assertTrue(self.read('[relay]\n').tcp_enabled)
        self.assertEqual(self.read('[relay]\n').tcp_port, 28991)
        self.assertFalse(self.read('[relay]\ntcp_enabled=false\n').tcp_enabled)
        for port in ('0', '-1', '80', '65536', 'invalid'):
            with self.assertRaises(ValueError): self.read('[relay]\ntcp_port=' + port)


if __name__ == '__main__':
    unittest.main()
