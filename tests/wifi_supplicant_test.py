# SPDX-License-Identifier: GPL-3.0-or-later
"""Exercise the real supplicant API without touching a host radio or system bus."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from avp_relay.wifi_supplicant import Supplicant, ssid_bytes
from avp_relay.wifi_protocol import public_network
from avp_relay.wifi_system import LinuxWifi, private_write


def inside():
    import dbus
    with tempfile.TemporaryDirectory() as directory:
        config = Path(directory) / 'wpa.conf'
        config.write_text('update_config=1\n')
        config.chmod(0o600)
        subprocess.run(['ip', 'link', 'add', 'testwifi', 'type', 'veth', 'peer', 'name', 'testpeer'], check=True)
        subprocess.run(['ip', 'link', 'set', 'testwifi', 'up'], check=True)
        bus_process = subprocess.Popen(['dbus-daemon', '--session', '--nofork', '--print-address=1'], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        try:
            address = bus_process.stdout.readline().strip()
            env = dict(os.environ, DBUS_SYSTEM_BUS_ADDRESS=address)
            # The wired test driver provides a real interface and profile API;
            # association/radio behavior still requires physical acceptance.
            daemon = subprocess.Popen(['wpa_supplicant', '-u'], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            try:
                bus = dbus.bus.BusConnection(address)
                wp = Supplicant(bus, 'testwifi', config, 'wired')
                for attempt in range(50):
                    try: wp.open(); break
                    except RuntimeError:
                        if attempt == 49: raise
                        time.sleep(0.1)
                inputs = [(b'example', 'personal', 'test password'), (b'hex-key', 'personal', 'a' * 64),
                          ('caf\u00e9'.encode(), 'sae', 'test passphrase'), (b'open network', 'open', ''),
                          (b'raw\xff\x00ssid', 'personal', 'test password'), (b'quote"\\name', 'personal', 'test password')]
                expected = {}
                for ssid, security, password in inputs:
                    item = dict(public_network(ssid, security, hidden=True), ssid=ssid, security=security)
                    try: wp.join(item, password)
                    except RuntimeError:
                        raise AssertionError(f'Profile rejected: {security}, key length {len(password)}') from None
                    expected[item['id']] = ssid
                wp.save()
                assert config.stat().st_mode & 0o777 == 0o600
                saved = wp.saved()
                assert {key: item['ssid'] for key, item in saved.items()} == expected, f'SSID bytes/security changed: {[item["ssid"] for item in saved.values()]}'
                assert all(item['hidden'] for item in saved.values())
                assert all('password' not in item and 'psk' not in item for item in saved.values())
                wp.close(); wp.open()
                assert {key: item['ssid'] for key, item in wp.saved().items()} == expected, 'Profiles did not survive daemon interface restart'
                item = dict(public_network(b'example', 'personal'), ssid=b'example', security='personal')
                wp.join(item, 'updated password')
                wp.save()
                assert len(wp.saved()) == len(inputs), 'Password update duplicated a profile'
                wp.remove(wp.saved()[item['id']]['path']); wp.save()
                assert item['id'] not in wp.saved()
                # Apply a bad candidate profile and use the production rollback
                # against the real API, including reopening its native config.
                before = config.read_bytes()
                backend = LinuxWifi('testwifi', Path(directory))
                backend.wp = wp
                private_write(Path(directory)/'before-operation.conf', before)
                wp.join(item, 'candidate password'); wp.save()
                backend.rollback()
                assert config.read_bytes() == before
                assert item['id'] not in wp.saved()
                wp.close()
                print('PASS: real D-Bus WPA2/WPA3/open/hidden/raw SSID profiles, private persistence, replace and forget')
            finally:
                daemon.terminate(); daemon.wait(timeout=5)
        finally:
            bus_process.terminate(); bus_process.wait(timeout=5)


class SupplicantTest(unittest.TestCase):
    def test_real_api(self):
        if not all(shutil.which(name) for name in ('wpa_supplicant', 'dbus-daemon', 'ip', 'unshare')):
            self.skipTest('supplicant/private bus/network namespace tools unavailable')
        probe = subprocess.run(['unshare', '--user', '--map-root-user', '--net', 'true'], capture_output=True)
        if probe.returncode: self.skipTest('builder prohibits isolated network namespaces')
        subprocess.run(['unshare', '--user', '--map-root-user', '--net', sys.executable, __file__, '--inside'], check=True)


if __name__ == '__main__':
    if '--inside' in sys.argv: inside()
    else: unittest.main()
