# SPDX-License-Identifier: GPL-3.0-or-later
"""Wi-Fi transaction recovery, privacy, authorization and appliance ownership."""
import copy
import json
from pathlib import Path
import socket
import struct
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from avp_relay.wifi import WifiController
from avp_relay.wifi_protocol import public_network, validate, check_password
from avp_relay.wifi_system import LinuxWifi, network_file, private_write, read_settings
from avp_relay.local_service import handle
from avp_relay.core import RelayCore


def network(ssid=b'Example', security='personal', saved=False):
    return dict(public_network(ssid, security, 80, saved, True), ssid=ssid, security=security)


class Backend:
    initial_enabled = False
    unsupported = 'No radio'
    def __init__(self):
        self.enabled = False
        self.profiles = {}
        self.available = {}
        self.calls = []
        self.backup = None
        self.connected = None
        self.addressed = False
        self.scanning = False
    def prepare(self): return True
    def initialize(self, enabled, managed): self.enabled = enabled
    def saved(self): return copy.deepcopy(self.profiles)
    def status(self):
        return dict(connection='disabled' if not self.enabled else 'connected' if self.connected and self.addressed else 'address' if self.connected else 'disconnected',
                    network=self.connected, name=None, addresses=['192.0.2.1'] if self.addressed else [])
    def begin(self):
        self.calls.append('begin')
        self.backup = copy.deepcopy(self.profiles)
    def commit(self): self.backup = None
    def rollback(self):
        self.calls.append('rollback')
        if self.backup is not None: self.profiles = self.backup; self.backup = None
        self.connected = None
    def set_enabled(self, enabled): self.enabled = enabled; self.calls.append(('enabled', enabled))
    def join(self, item, password):
        self.calls.append(('join', item['id']))
        self.profiles[item['id']] = dict(item, password=password, saved=True)
        self.connected = item['id']
    def connect(self, identifier): self.connected = identifier
    def forget(self, identifier): self.profiles.pop(identifier, None)
    def scan(self): self.scanning = True
    def scan_done(self): return not self.scanning
    def results(self): return copy.deepcopy(self.available)


class WifiTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name)
        self.now = 0
        self.backend = Backend()
        self.controller = WifiController(self.backend, self.path, lambda: self.now)
        self.controller.start()
    def command(self, op='wifi-enable', **fields):
        return dict(op=op, requestID=str(uuid.uuid4()), **fields)
    def advance(self, seconds=3): self.now += seconds; self.controller.tick()
    def enable(self):
        self.controller.request(self.command(enabled=True)); self.advance()
    def scan(self, items):
        self.backend.available = {item['id']: item for item in items}
        self.controller.request(self.command('wifi-scan')); self.advance()
        self.backend.scanning = False; self.advance()
    def join(self, item, password='test password'):
        return self.command('wifi-join', network=item['id'], ssid=None, security=None, password=password)
    def test_fresh_off_upgrade_preserved_and_reboot_policy(self):
        self.assertFalse(self.controller.snapshot['enabled'])
        self.enable()
        restarted = WifiController(self.backend, self.path, lambda: self.now)
        restarted.start()
        self.assertTrue(restarted.snapshot['enabled'])
        self.backend.initial_enabled = True
        upgrade = WifiController(self.backend, self.path/'upgrade', lambda: self.now)
        upgrade.start()
        self.assertTrue(upgrade.snapshot['enabled'])
    def test_ack_precedes_apply_and_repeat_does_not_apply_twice(self):
        command = self.command(enabled=True)
        result = self.controller.request(command)
        self.assertEqual(result['phase'], 'applying')
        self.assertEqual(self.backend.calls, [])
        self.assertEqual(json.loads((self.path/'policy.json').read_text())['requestID'], command['requestID'])
        self.advance()
        self.assertEqual(self.controller.request(command)['phase'], 'idle')
        self.assertEqual(self.backend.calls.count('begin'), 1)
        with self.assertRaises(ValueError): self.controller.request(dict(command, enabled=False))
    def test_join_without_address_times_out_and_restores_profiles(self):
        self.enable()
        item = network()
        old = dict(item, password='original secret', saved=True)
        self.backend.profiles[item['id']] = old
        self.scan([item])
        self.controller.request(self.join(item))
        self.advance()
        self.assertEqual(self.controller.snapshot['phase'], 'applying')
        self.advance(61)
        self.assertEqual(self.controller.snapshot['phase'], 'failed')
        self.assertIn('no network address', self.controller.snapshot['message'])
        self.assertEqual(self.backend.profiles[item['id']]['password'], 'original secret')
        self.assertNotIn('password', (self.path/'policy.json').read_text())
    def test_join_resumes_after_restart_and_secret_never_in_reply(self):
        self.enable(); item = network(); self.scan([item])
        command = self.join(item)
        reply = self.controller.request(command)
        self.assertNotIn(command['password'], json.dumps(reply))
        self.assertEqual((self.path/'policy.json').stat().st_mode & 0o777, 0o600)
        self.advance()  # Half-applied profile, followed by a service restart.
        self.controller = WifiController(self.backend, self.path, lambda: self.now)
        self.controller.start()
        self.backend.addressed = True
        self.advance()
        self.assertEqual(self.controller.snapshot['phase'], 'idle')
        self.assertEqual(self.controller.snapshot['requestID'], command['requestID'])
        self.assertEqual(self.backend.profiles[item['id']]['password'], command['password'])
        self.assertNotIn(command['password'], (self.path/'policy.json').read_text())
        reply = self.controller.request(dict(op='wifi-list', kind='saved', offset=0, generation=''))
        self.assertNotIn('password', json.dumps(reply))
    def test_saved_hidden_password_update_and_disabled_forget(self):
        self.enable(); item = network(b'hidden'); self.backend.profiles[item['id']] = item
        self.advance()
        self.backend.addressed = True
        self.controller.request(self.join(item)); self.advance()
        self.assertEqual(self.controller.snapshot['phase'], 'idle')
        self.controller.request(self.command(enabled=False)); self.advance()
        self.assertIn(item['id'], self.backend.profiles)
        self.controller.request(self.command('wifi-forget', network=item['id'])); self.advance()
        self.assertFalse(self.backend.enabled)
        self.assertEqual(self.backend.profiles, {})
    def test_scan_pagination_generation_and_raw_ssid_identity(self):
        self.enable()
        items = [network(bytes([n]) + b'network') for n in range(1, 21)]
        items += [network(b'raw\xff'), network(b'raw\xfe')]
        self.scan(items)
        first = self.controller.request(dict(op='wifi-list', kind='available', offset=0, generation=''))
        self.assertEqual(len(first['networks']), 8)
        second = self.controller.request(dict(op='wifi-list', kind='available', offset=first['next'], generation=first['generation']))
        self.assertEqual(len(second['networks']), 8)
        self.scan(items[:2])
        with self.assertRaises(ValueError):
            self.controller.request(dict(op='wifi-list', kind='available', offset=8, generation=first['generation']))
        self.assertNotEqual(items[-1]['id'], items[-2]['id'])
        self.assertEqual(items[-1]['name'], items[-2]['name'])
    def test_backend_diagnostic_does_not_leak_secret(self):
        self.enable(); item = network(); self.scan([item])
        self.backend.join = Mock(side_effect=RuntimeError('rejected psk=test password'))
        self.controller.request(self.join(item)); self.advance()
        self.assertEqual(self.controller.snapshot['phase'], 'failed')
        self.assertNotIn('test password', json.dumps(self.controller.snapshot))
    def test_scan_failure_timeout_and_restart_never_disconnect(self):
        self.enable()
        item = network(); self.scan([item])
        self.backend.connected = item['id']; self.backend.addressed = True
        self.backend.calls.clear()
        self.controller.request(self.command('wifi-scan')); self.advance()
        self.advance(21)
        self.assertEqual(self.controller.snapshot['phase'], 'failed')
        self.assertEqual(self.controller.snapshot['connection'], 'connected')
        self.assertIn(item['id'], self.controller.available)
        self.assertEqual(self.backend.calls, [])
        self.controller.request(self.command('wifi-scan')); self.advance()
        restarted = WifiController(self.backend, self.path, lambda: self.now)
        restarted.start(); restarted.tick()
        self.assertEqual(self.backend.calls, [])
        self.backend.scan_done = Mock(side_effect=RuntimeError('scan rejected'))
        restarted.tick()
        self.assertEqual(restarted.snapshot['connection'], 'connected')
        self.assertEqual(self.backend.calls, [])

    def test_command_bounds_and_no_raw_configuration(self):
        bad = [dict(op='wifi-status', password='x'), self.command(enabled=1),
               self.command('wifi-forget', network='x'),
               dict(op='wifi-list', kind='saved', offset=True, generation=''),
               self.command('wifi-join', network=None, ssid='a'*33, security='open', password=''),
               self.command('wifi-join', network=None, ssid='hidden', security='personal', password='secret\nupdate_config=1')]
        for command in bad:
            with self.assertRaises(ValueError): validate(command)
        for security, password in [('personal', 'short'), ('sae', ''), ('open', 'password'), ('enterprise', 'password')]:
            with self.assertRaises(ValueError): check_password(security, password)
        with self.assertRaises(ValueError): self.controller.request(self.command('wifi-scan'))
    def test_only_authorized_owner_reaches_wifi_helper(self):
        core = RelayCore.__new__(RelayCore)
        core.owner = 'approved'; core.wifi = Mock()
        core.wifi.request.return_value = dict(self.controller.snapshot)
        command = json.dumps(dict(version=1, id=1, **self.command(enabled=True))).encode()
        for owner, authorized, enrolling in [('approved', False, True), ('other', True, False), ('other', False, False)]:
            self.assertFalse(json.loads(core.request(command, owner, authorized, enrolling))['ok'])
        core.wifi.request.assert_not_called()
        self.assertTrue(json.loads(core.request(command, 'approved', True))['ok'])
        core.wifi.request.assert_called_once()
    def test_radio_switch_is_specific_and_hardware_block_respected(self):
        backend = LinuxWifi('wlan0', self.path)
        backend.rfkill = self.path/'rfkill3'; backend.rfkill.mkdir()
        (backend.rfkill/'soft').write_text('0'); (backend.rfkill/'hard').write_text('0')
        with patch('avp_relay.wifi_system.run') as run:
            backend.radio(False)
            run.assert_called_once_with('rfkill', 'block', '3')
        (backend.rfkill/'hard').write_text('1')
        with self.assertRaises(RuntimeError): backend.radio(True)
    def test_wlan_network_file_and_unowned_removal_are_inert(self):
        value = network_file('wlan0')
        self.assertIn('Name=wlan0', value); self.assertIn('RouteMetric=32760', value)
        for forbidden in ('IPForward', 'IPMasquerade', 'Bridge=', 'DHCPServer', 'usb0', 'end0'):
            self.assertNotIn(forbidden, value)
        with patch('avp_relay.wifi_system.run') as run, patch('avp_relay.wifi_system.dbus.SystemBus') as bus:
            LinuxWifi('wlan0', self.path).remove()
            run.assert_not_called(); bus.assert_not_called()
        config = self.path/'settings'; config.write_text('[wifi]\ninterface=wlan0\n')
        self.assertEqual(read_settings(config), 'wlan0')
        private_write(self.path/'key', b'secret')
        self.assertEqual((self.path/'key').stat().st_mode & 0o777, 0o600)
    def test_disabled_radio_has_no_stale_address_and_dad_must_complete(self):
        backend = LinuxWifi('wlan0', self.path)
        backend.rfkill = self.path/'rfkill3'; backend.rfkill.mkdir()
        (backend.rfkill/'soft').write_text('1'); (backend.rfkill/'hard').write_text('0')
        backend.wp = Mock(path='/interface')
        backend.wp.properties.return_value = {'State': 'completed', 'CurrentNetwork': '/network'}
        item = dict(network(), paths=['/network'])
        backend.wp.saved.return_value = {item['id']: item}
        with patch('avp_relay.wifi_system.run') as run:
            self.assertEqual(backend.status()['addresses'], [])
            run.assert_not_called()
            (backend.rfkill/'soft').write_text('0')
            run.return_value = json.dumps([{'addr_info': [{'local': '2001:db8::1', 'scope': 'global', 'flags': ['tentative']}]}])
            self.assertEqual(backend.status()['connection'], 'address')
            run.return_value = json.dumps([{'addr_info': [{'local': '2001:db8::1', 'scope': 'global', 'flags': []}]}])
            self.assertEqual(backend.status()['connection'], 'connected')
    def test_local_socket_rejects_non_root_before_reading(self):
        connection = Mock()
        connection.getsockopt.return_value = struct.pack('3i', 1, 1000, 1000)
        handle(connection, self.controller)
        connection.recv.assert_not_called(); connection.sendall.assert_not_called()
    def test_takeover_backs_up_profiles_and_remove_restores_original_service(self):
        backend = LinuxWifi('wlan0', self.path/'state')
        source = self.path/'original.conf'
        source.write_bytes(b'update_config=0\nnetwork={\nssid="existing"\npsk="test secret"\n}\n')
        backend.foreign_config = source
        backend.foreign_units = ['netplan-wpa-wlan0.service']
        backend.rfkill = self.path/'rfkill1'; backend.rfkill.mkdir()
        (backend.rfkill/'soft').write_text('0')
        wp = Mock(path=None, config=backend.state/'wpa.conf')
        backend.wp = wp
        owned = self.path/'03-plank-wifi.network'
        def run(*args, **kwargs):
            return str(owned) if args[:2] == ('networkctl', 'status') else ''
        with patch('avp_relay.wifi_system.NETWORK', owned), patch('avp_relay.wifi_system.run', side_effect=run) as commands:
            backend.adopt()
            self.assertEqual((backend.state/'original-wpa.conf').read_bytes(), source.read_bytes())
            self.assertIn(b'update_config=1', wp.config.read_bytes())
            self.assertIn(b'test secret', wp.config.read_bytes())
            self.assertEqual(wp.config.stat().st_mode & 0o777, 0o600)
            self.assertIn((('systemctl', 'mask', '--now', 'netplan-wpa-wlan0.service'),), [(c.args,) for c in commands.call_args_list])
            wp.config.write_bytes(b'update_config=1\n# newer profile\n')
            backend.adopt()
            self.assertIn(b'newer profile', wp.config.read_bytes())  # No replay of original credentials.
            wp.existing.return_value = ('/interface', {'ConfigFile': str(wp.config)})
            with patch('avp_relay.wifi_system.Supplicant', return_value=wp), patch('avp_relay.wifi_system.dbus.SystemBus'):
                backend.remove()
            self.assertFalse(owned.exists())
            self.assertTrue(wp.config.exists())
            commands.assert_any_call('systemctl', 'unmask', 'netplan-wpa-wlan0.service')
            commands.assert_any_call('systemctl', 'start', 'netplan-wpa-wlan0.service')
            self.assertIn(b'test secret', source.read_bytes())
    def test_conflicting_network_file_is_not_overwritten_or_claimed(self):
        backend = LinuxWifi('wlan0', self.path/'state')
        owned = self.path/'03-plank-wifi.network'; owned.write_text('# administrator file\n')
        with patch('avp_relay.wifi_system.NETWORK', owned), patch('avp_relay.wifi_system.run') as run:
            with self.assertRaises(RuntimeError): backend.begin()
            run.assert_not_called()
        self.assertEqual(owned.read_text(), '# administrator file\n')
        self.assertFalse((backend.state/'ownership.json').exists())
    def test_local_socket_reply_has_no_request_secret(self):
        connection = Mock()
        connection.getsockopt.return_value = struct.pack('3i', 1, 0, 0)
        connection.recv.return_value = b'{"op":"wifi-status","password":"private-value"}\n'
        handle(connection, self.controller)
        reply = connection.sendall.call_args.args[0]
        self.assertIn(b'error', reply); self.assertNotIn(b'private-value', reply)


if __name__ == '__main__': unittest.main()
