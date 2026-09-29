# SPDX-License-Identifier: GPL-3.0-or-later
"""Ask the real kernel to load/reload both policies in an isolated net namespace."""
from pathlib import Path
import shutil
import subprocess
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from ble_lab.gadget_system import firewall


def inside():
    def nft(*args, input=None):
        result = subprocess.run(['nft', *args], input=input, capture_output=True, text=True)
        assert result.returncode == 0, result.stderr
        return result.stdout
    nft('add', 'table', 'inet', 'unrelated')
    for mode in ('router', 'bridge', 'router'):
        nft('-f', '-', input=firewall(mode, 'end0', 'usb0', '10.55.0.0/24'))
        rules = nft('list', 'table', 'inet', 'plank_usb')
        assert ('meta nfproto ipv6 drop' in rules) == (mode == 'router')
        assert ('oifname != "end0" drop' in rules) == (mode == 'router')
        assert 'unrelated' in nft('list', 'tables')
    nft('delete', 'table', 'inet', 'plank_usb')
    nft('delete', 'table', 'ip', 'plank_usb')
    assert nft('list', 'tables').strip() == 'table inet unrelated'
    print('PASS: real kernel firewall install, mode changes, reload and owned-table cleanup')


class FirewallTest(unittest.TestCase):
    def test_real_kernel_policy(self):
        if not shutil.which('nft') or not shutil.which('unshare'):
            self.skipTest('nft/unshare unavailable in this builder')
        probe = subprocess.run(['unshare', '--user', '--map-root-user', '--net', 'true'], capture_output=True)
        if probe.returncode:
            self.skipTest('builder prohibits isolated user/network namespaces')
        subprocess.run(['unshare', '--user', '--map-root-user', '--net', sys.executable, __file__, '--inside'], check=True)


if __name__ == '__main__':
    if '--inside' in sys.argv: inside()
    else: unittest.main()
