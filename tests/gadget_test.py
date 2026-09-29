# SPDX-License-Identifier: GPL-3.0-or-later
"""Exercise durable changes, lost replies, restart recovery and authorization."""
import json
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
from avp_relay.gadget_system import LinuxGadget, firewall, network_files
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
    def status(self): return dict(ethernet='connected', usb='connected', addresses=['10.55.0.1'])


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
        backend.wired = 'end0'; backend.controller = 'udc0'
        def value(path, *args):
            path = str(path)
            if path.endswith('carrier'): return '1'
            if path.endswith('/UDC'): return 'udc0'
            if path.endswith('/state'): return 'not attached'
            return ''
        with patch('avp_relay.gadget_system.read', side_effect=value):
            self.assertEqual(backend.status()['usb'], 'disconnected')

    def test_firewall_blocks_wifi_and_ipv6_forwarding_and_no_tiny_pool(self):
        router = firewall('router', 'end0', 'usb0', '10.55.0.0/24')
        self.assertIn('iifname "usb0" oifname != "end0" drop', router)
        self.assertIn('iifname "usb0" meta nfproto ipv6 drop', router)
        self.assertIn('table inet plank_usb', router)
        bridge = firewall('bridge', 'end0', 'usb0', '10.55.0.0/24')
        self.assertIn('iifname "plankbr0" oifname != "plankbr0" drop', bridge)
        self.assertNotIn('masquerade', bridge)
        files = network_files('router', 'end0', '', '02:00:00:00:00:01', '10.55.0.1/30', {})
        text = next(iter(files.values()))
        self.assertIn('PoolSize=0', text)
        self.assertNotIn('PoolSize=20', text)

    def test_config_rejects_bad_addresses_and_shell_values(self):
        path = self.path / 'settings'
        path.write_text('[usb-network]\n')
        self.assertEqual(read_settings(path).enabled, 'auto')
        for key, value in [('router_address','999.1.1.1/24'), ('router_address','10.0.0.0/24'),
                           ('router_address','10.0.0.1/31'), ('router_address','127.0.0.1/24'),
                           ('router_address','172.16.0.1/8'), ('wired_interface','eth0;id'),
                           ('otg_node','/a";'), ('unknown','value')]:
            path.write_text(f'[usb-network]\n{key}={value}\n')
            with self.assertRaises(ValueError): read_settings(path)


if __name__ == '__main__': unittest.main()
