# SPDX-License-Identifier: GPL-3.0-or-later
"""Exercise durable changes, lost replies, restart recovery and authorization."""
import json
import os
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from avp_relay.gadget import GadgetController
from avp_relay.gadget_config import GadgetSettings, read_settings
from avp_relay.gadget_system import LinuxGadget, firewall, network_files, install_network_files
from avp_relay.host_setup import configure_usb_subnet
from avp_relay.core import RelayCore


class Backend:
    restart_required = False
    unsupported = ''
    fault = ''

    def __init__(self):
        self.applied = []
        self.fail = None
        self.detached = False

    def prepare(self): return True
    def apply(self, mode):
        self.applied.append(mode)
        if mode == self.fail: raise RuntimeError('simulated configuration failure')
    def sync(self): pass
    def unbind(self): self.detached = True
    def status(self): return dict(ethernet='connected', usb='connected', addresses=['10.20.30.1'])


class GadgetTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name)
        self.now = 0
        self.backend = Backend()
        self.controller = GadgetController(self.backend, self.path, lambda: self.now)
        self.controller.start()

    def command(self, mode='router', request=None):
        return dict(op='network-mode', mode=mode, requestID=request or str(uuid.uuid4()))

    def test_durable_ack_and_idempotency_after_lost_reply(self):
        command = self.command()
        reply = self.controller.request(command)
        self.assertEqual(reply['phase'], 'applying')
        self.assertEqual(json.loads((self.path/'mode.json').read_text())['requestID'], command['requestID'])
        self.assertEqual(self.backend.applied, ['bridge'])
        self.controller.tick()
        self.assertEqual(self.backend.applied, ['bridge'])  # Reply can leave before USB detaches.
        self.now = 3
        self.controller.tick()
        self.assertEqual(self.backend.applied, ['bridge', 'router'])
        self.assertEqual(self.controller.request(command)['mode'], 'router')
        self.assertEqual(self.backend.applied, ['bridge', 'router'])
        with self.assertRaises(ValueError):
            self.controller.request(dict(command, mode='bridge'))

    def test_pending_request_resumes_after_process_restart(self):
        command = self.command()
        self.controller.request(command)
        other = Backend()
        restarted = GadgetController(other, self.path, lambda: self.now)
        restarted.start()
        self.now = 3
        restarted.tick()
        self.assertEqual(other.applied, ['bridge', 'router'])
        self.assertEqual(restarted.snapshot['requestID'], command['requestID'])
        self.assertEqual(restarted.snapshot['phase'], 'idle')

    def test_failed_mode_change_restores_previous_and_remains_reported(self):
        self.backend.fail = 'router'
        command = self.command()
        self.controller.request(command)
        self.now = 3
        self.controller.tick()
        self.assertEqual(self.backend.applied, ['bridge', 'router', 'bridge'])
        self.assertEqual(self.controller.snapshot['phase'], 'failed')
        self.assertEqual(self.controller.snapshot['mode'], 'bridge')
        self.assertEqual(self.controller.snapshot['requestID'], command['requestID'])
        self.assertIn('Previous mode restored', self.controller.snapshot['message'])

    def test_read_only_status_and_command_validation(self):
        self.controller.request(self.command())
        saved = (self.path/'mode.json').read_bytes()
        for _ in range(4): self.controller.request({'op': 'network-status'})
        self.assertEqual(saved, (self.path/'mode.json').read_bytes())
        for command in [self.command(), self.command('wifi'), self.command(request='x'),
                        {'op': 'network-status', 'mode': 'router'}, {'op': 'shell', 'mode': 'bridge'}]:
            with self.assertRaises(ValueError): self.controller.request(command)

    def test_reboot_and_unsupported_never_accept_mode_changes(self):
        self.backend.restart_required = True
        self.controller.refresh()
        with self.assertRaises(ValueError): self.controller.request(self.command())
        self.controller.supported = False
        with self.assertRaises(ValueError): self.controller.request(self.command())

    def test_only_authorized_current_owner_reaches_helper(self):
        core = RelayCore.__new__(RelayCore)
        core.owner = 'approved'
        core.gadget = Mock()
        core.gadget.request.return_value = dict(self.controller.snapshot)
        command = json.dumps(dict(version=1, id=4, **self.command())).encode()
        for owner, authorized, enrolling in [('approved', False, True), ('other', True, False), ('other', False, False)]:
            self.assertFalse(json.loads(core.request(command, owner, authorized, enrolling))['ok'])
        core.gadget.request.assert_not_called()
        self.assertTrue(json.loads(core.request(command, 'approved', True))['ok'])
        core.gadget.request.assert_called_once()

    def test_ethernet_loss_detaches_even_with_usb_configured(self):
        backend = LinuxGadget(GadgetSettings())
        backend.current = 'router'
        backend.wired = 'end0'
        backend.controller = 'udc0'
        with patch('avp_relay.gadget_system.read', side_effect=lambda p, *a: '0' if str(p).endswith('carrier') else 'udc0'), \
             patch('avp_relay.gadget_system.write') as write, patch('avp_relay.gadget_system.run') as run:
            backend.sync()
            write.assert_called_once()
            self.assertEqual(write.call_args.args[1], '')
            run.assert_not_called()  # No Internet or address probe gates disconnection.

    def test_binding_is_not_reported_as_connected_host(self):
        backend = LinuxGadget(GadgetSettings())
        backend.wired = 'end0'; backend.controller = 'udc0'; backend.current = 'bridge'
        def value(path, *args):
            path = str(path)
            if path.endswith('carrier'): return '1'
            if path.endswith('/UDC'): return 'udc0'
            if path.endswith('/state'): return 'not attached'
            return ''
        with patch('avp_relay.gadget_system.read', side_effect=value):
            self.assertEqual(backend.status()['usb'], 'disconnected')

    def test_setup_failure_keeps_live_ethernet_status(self):
        self.backend.prepare = Mock(side_effect=RuntimeError('USB interface failed'))
        self.controller.start()
        self.assertFalse(self.controller.snapshot['supported'])
        self.assertEqual(self.controller.snapshot['phase'], 'failed')
        self.assertEqual(self.controller.snapshot['ethernet'], 'connected')
        self.assertEqual(self.controller.snapshot['usb'], 'error')
        self.backend.status = Mock(return_value=dict(ethernet='disconnected', usb='waiting', addresses=[]))
        self.controller.tick()
        self.assertEqual(self.controller.snapshot['ethernet'], 'disconnected')
        self.assertEqual(self.controller.snapshot['usb'], 'error')

    def test_unsupported_usb_still_reports_ethernet_and_updates_it(self):
        self.backend.prepare = Mock(return_value=False)
        self.backend.unsupported = 'USB networking disabled for this hardware'
        self.controller.start()
        self.assertEqual(self.controller.snapshot['ethernet'], 'connected')
        self.assertEqual(self.controller.snapshot['usb'], 'unavailable')
        self.backend.status = Mock(return_value=dict(ethernet='disconnected', usb='waiting', addresses=[]))
        self.controller.tick()
        self.assertEqual(self.controller.snapshot['ethernet'], 'disconnected')
        self.assertEqual(self.controller.snapshot['phase'], 'unavailable')

    def test_deferred_interface_can_be_used_for_prebind_configuration(self):
        backend = LinuxGadget(GadgetSettings())
        with patch('avp_relay.gadget_system.read', side_effect=lambda path: 'plankusb%d' if str(path).endswith('ifname') else ''), \
             patch.object(Path, 'iterdir', return_value=iter([])), patch.object(Path, 'exists', return_value=False):
            self.assertEqual(backend.usb_interface(), 'plankusb0')
        with patch('avp_relay.gadget_system.read', side_effect=lambda path: 'plankusb%d' if str(path).endswith('ifname') else ''), \
             patch.object(Path, 'iterdir', return_value=iter([])), patch.object(Path, 'exists', return_value=True):
            with self.assertRaisesRegex(RuntimeError, 'already in use'):
                backend.usb_interface()

    def test_usb_bind_happens_only_after_wired_guard_and_config(self):
        backend = LinuxGadget(GadgetSettings())
        backend.wired = 'end0'; backend.controller = 'udc0'; backend.current = 'bridge'
        backend.guard_ready = True
        backend.usb_interface = Mock(return_value='plankusb0')
        events = []
        with patch('avp_relay.gadget_system.read', side_effect=lambda path, *a: '1' if str(path).endswith('carrier') else ''), \
             patch('avp_relay.gadget_system.write', side_effect=lambda path, value: events.append(('bind', value))), \
             patch('avp_relay.gadget_system.run', side_effect=lambda *a, **kw: events.append(a) or 'configured'), \
             patch.object(backend, 'verify_network_files', side_effect=lambda matches: events.append(('verify', matches))):
            backend.sync()
        self.assertIn(('bind', 'udc0'), events)
        self.assertLess(events.index(('bind', 'udc0')), events.index(('networkctl', 'reconfigure', 'plankusb0')))
        self.assertIn(('verify', {'plankusb0': '04-plank-usb-device.network'}), events)
        backend.guard_ready = False
        with patch('avp_relay.gadget_system.read', return_value='0'), \
             patch('avp_relay.gadget_system.write') as write, patch('avp_relay.gadget_system.run') as run:
            backend.sync()
            run.assert_not_called()
            self.assertNotIn('udc0', [call.args[1] for call in write.call_args_list])

    def test_fixed_router_subnet_dhcp_nat_and_wired_only_forwarding(self):
        router = firewall('router', 'end0', 'usb0')
        self.assertIn('ip saddr 10.20.30.0/24 oifname "end0" masquerade', router)
        self.assertIn('iifname "usb0" oifname != "end0" drop', router)
        self.assertIn('iifname "usb0" meta nfproto ipv6 drop', router)
        self.assertIn('table inet plank_usb', router)
        bridge = firewall('bridge', 'end0', 'usb0')
        self.assertIn('iifname "plankbr0" oifname != "plankbr0" drop', bridge)
        self.assertNotIn('masquerade', bridge)
        files = network_files('router', 'end0', '', '02:00:00:00:00:01', {})
        text = next(iter(files.values()))
        self.assertIn('Address=10.20.30.1/24\nDHCPServer=yes', text)
        self.assertIn('PoolSize=0', text)
        self.assertNotIn('PoolSize=20', text)

    def test_warm_restart_does_not_select_own_usb_gadget_as_wired_port(self):
        backend = LinuxGadget(GadgetSettings())
        net = self.path / 'net'
        platform = self.path / 'platform'; platform.mkdir()
        for name, mac in [('end0', '02:01:02:03:04:05'), ('plankusb0', backend.device_mac)]:
            port = net / name
            (port / 'device').mkdir(parents=True)
            (port / 'device/subsystem').symlink_to(platform)
            (port / 'address').write_text(mac)
        backend.select_wired(required=True, net=net)
        self.assertEqual(backend.wired, 'end0')
        # A genuinely second physical Ethernet port must still require config.
        (net / 'end1/device').mkdir(parents=True)
        (net / 'end1/device/subsystem').symlink_to(platform)
        (net / 'end1/address').write_text('02:06:07:08:09:10')
        with self.assertRaisesRegex(RuntimeError, 'ambiguous'):
            backend.select_wired(required=True, net=net)

    def test_networkd_config_is_readable_under_private_service_umask(self):
        directory = self.path / 'networkd'
        files = network_files('bridge', 'end0', '02:01:02:03:04:05', '02:06:07:08:09:10',
                              dict(dhcp=True, addresses=[], dns=[], routes=[]))
        previous = os.umask(0o077)
        try:
            install_network_files(files, directory)
            for name, contents in files.items():
                self.assertEqual((directory / name).stat().st_mode & 0o777, 0o644)
                self.assertEqual((directory / name).read_text(), contents)
            foreign = directory / '04-plank-usb-device.network'
            foreign.write_text('Administrator-owned config')
            with self.assertRaisesRegex(RuntimeError, 'already in use'):
                install_network_files(files, directory)
            self.assertEqual(foreign.read_text(), 'Administrator-owned config')
        finally:
            os.umask(previous)

    def test_fixed_subnet_rejects_overlap_but_allows_own_usb_address(self):
        backend = LinuxGadget(GadgetSettings())
        backend.usb_interface = Mock(return_value='plankusb0')
        own = dict(ifname='plankusb0', addr_info=[dict(family='inet', scope='global', local='10.20.30.1', prefixlen=24)])
        for address, prefix, overlaps in [('10.55.118.104', 24, False), ('172.25.103.102', 22, False),
                                          ('10.20.30.42', 24, True), ('10.20.5.1', 16, True)]:
            other = dict(ifname='end0', addr_info=[dict(family='inet', scope='global', local=address, prefixlen=prefix)])
            with self.subTest(address=address, prefix=prefix), \
                 patch('avp_relay.gadget_system.run', return_value=json.dumps([own, other])):
                if overlaps:
                    with self.assertRaisesRegex(RuntimeError, '10.20.30.0/24 overlaps'):
                        backend.check_subnet()
                else:
                    backend.check_subnet()

    def test_upgrade_removes_retired_subnet_and_retains_custom_settings(self):
        self.controller.request(self.command())
        saved = self.controller.path.read_bytes()
        config = self.path / 'etc/plank-avp-relay/usb-network.conf'
        config.parent.mkdir(parents=True)
        retained = '[usb-network]\nenabled = true\nwired_interface = end0\n'
        original = retained + 'router_address = 10.55.0.1/24\n'
        config.write_text(original)
        config.chmod(0o640)
        self.assertTrue(configure_usb_subnet(self.path))
        self.assertEqual(config.read_text(), retained)
        self.assertEqual(config.stat().st_mode & 0o777, 0o640)
        settings = read_settings(config)
        self.assertEqual((settings.enabled, settings.wired_interface), ('true', 'end0'))
        backup = self.path / 'var/backups/plank-avp-relay/usb-network.before-fixed-subnet'
        self.assertEqual(backup.read_text(), original)
        self.assertEqual(backup.stat().st_mode & 0o777, 0o600)
        self.assertFalse(configure_usb_subnet(self.path))
        self.assertEqual(backup.read_text(), original)
        self.assertEqual(self.controller.path.read_bytes(), saved)

    def test_config_rejects_subnet_override_and_shell_values(self):
        path = self.path / 'settings'
        path.write_text('[usb-network]\n')
        self.assertEqual(read_settings(path).enabled, 'auto')
        for key, value in [('router_address','10.55.0.1/24'), ('wired_interface','eth0;id'),
                           ('otg_node','/a";'), ('unknown','value')]:
            path.write_text(f'[usb-network]\n{key}={value}\n')
            with self.assertRaises(ValueError): read_settings(path)


if __name__ == '__main__': unittest.main()
