# SPDX-License-Identifier: GPL-3.0-or-later
"""Exercise extracted package files, not the source/build directory."""
from pathlib import Path
import json
import re
import struct
import sys
import tempfile

root = Path(sys.argv[1]).resolve()
private = root / 'usr/lib/plank-avp-relay'
library = private / 'libplank_avp_relay.so'
assert library.is_file(), 'Packaged ctypes library missing or renamed'
launcher = root / 'usr/bin/plank-avp-relay'
assert launcher.read_text().splitlines()[0] == '#!/usr/bin/python3 -I'
sys.path.insert(0, str(private))
from avp_relay.config import read_settings
from avp_relay.native import Native
from avp_relay.bluez import Server  # Check installed imports and dependencies.
from avp_relay.drawing_status import read_handoff  # New module must ship in the package.
from avp_relay.network import TCPServer
from avp_relay.discovery import Publisher
from avp_relay.hardware import prepare_firmware
from avp_relay.host_setup import configure_armbian
from avp_relay.gadget_config import read_settings as read_gadget_settings
from avp_relay.gadget_system import firewall, network_files
from avp_relay.gadget import GadgetController
from avp_relay.wifi import WifiController
from avp_relay.wifi_system import read_settings as read_wifi_settings

settings = read_settings(root / 'etc/plank-avp-relay/relay.conf')
assert not settings.exclusive_adapter and not settings.disable_controller_address_resolution
assert settings.tcp_enabled and settings.tcp_port == 28991
assert read_gadget_settings(root / 'etc/plank-avp-relay/usb-network.conf').enabled == 'auto'
assert 'router_address' not in (root / 'etc/plank-avp-relay/usb-network.conf').read_text()
assert 'Address=10.20.30.1/24' in next(iter(network_files('router', 'end0', '', '02:00:00:00:00:01', {}).values()))
assert 'ip saddr 10.20.30.0/24' in firewall('router', 'end0', 'plankusb0')
assert (private / 'plank-avp-relay-usb').is_file()
assert (root / 'usr/lib/systemd/system/plank-avp-relay-usb.service').is_file()
assert read_wifi_settings(root / 'etc/plank-avp-relay/wifi.conf') == ''
assert (private / 'plank-avp-relay-wifi').is_file()
assert (root / 'usr/lib/systemd/system/plank-avp-relay-wifi.service').is_file()
assert re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+',
    (root / 'usr/share/plank-avp-relay/version').read_text().strip())
raw = root / 'usr/libexec/plank-tablet-relay'
assert raw.is_file() and raw.stat().st_mode & 0o111, 'Packaged raw executable missing'
assert raw.read_bytes()[:4] == b'\x7fELF', 'Raw executable is not a Linux binary'
raw_unit = (root / 'usr/lib/systemd/system/plank-tablet-relay.service').read_text()
assert 'User=plank-relay' in raw_unit and 'Group=plank-relay' in raw_unit
assert 'ExecStart=/usr/libexec/plank-tablet-relay serve' in raw_unit
assert 'StateDirectoryMode=0700' in raw_unit and 'UMask=0077' in raw_unit
assert 'PLANK_RELAY_BIND=0.0.0.0' in raw_unit
assert 'PLANK_RELAY_BIND=0.0.0.0' in (root / 'etc/default/plank-tablet-relay').read_text()
assert (private / 'plank-drawing-permissions').is_file()
permissions = (root / 'usr/lib/udev/rules.d/70-plank-tablet-relay.rules').read_text()
assert '056a' in permissions and '0005:056A:*' in permissions
assert 'GROUP="plank-relay"' in permissions
pin = json.loads((root / 'usr/share/plank-avp-relay/drawing-source.json').read_text())
assert re.fullmatch(r'[0-9a-f]{40}', pin['commit'])
assert re.fullmatch(r'[0-9a-f]{64}', pin['archive_sha256'])
license_file = root / 'usr/share/doc/plank-avp-relay/drawing-LICENSE'
assert license_file.is_file() or license_file.with_name(license_file.name + '.gz').is_file()
assert (root / 'usr/share/doc/plank-avp-relay/drawing-worker-provenance.md').is_file()
unit = (root / 'usr/lib/systemd/system/plank-avp-relay.service').read_text()
assert 'avahi-daemon.service' in unit and 'AF_INET AF_INET6' in unit
assert 'PartOf=bluetooth.service' not in unit
assert 'InaccessiblePaths=-/var/lib/plank-avp-relay/wifi' in unit
assert (private / 'plank-avp-relay-hardware').is_file()
assert (private / 'plank-avp-relay-configure-host').is_file()
assert (root / 'usr/lib/systemd/system/plank-avp-relay-hardware.service').is_file()
bluez_policy = root / 'usr/lib/systemd/system/bluetooth.service.d/10-plank-avp-relay.conf'
assert 'ExecStart=/usr/libexec/bluetooth/bluetoothd --noplugin=battery' in bluez_policy.read_text()
with tempfile.TemporaryDirectory() as directory:
    firmware = Path(directory)
    prepare_firmware(firmware, root / 'usr/share/plank-avp-relay/firmware')
    assert (firmware / 'updates/rtl_bt/rtl8851bu_fw.bin').stat().st_size == 49760
    assert (firmware / 'updates/rtw89/rtw8851b_fw.bin').stat().st_size == 1164440
    assert (firmware / 'updates/rtw89/rtw8851b_fw-1.bin').stat().st_size > 1000000
    prepare_firmware(firmware, root / 'usr/share/plank-avp-relay/firmware', remove=True)
    assert not (firmware / 'updates/rtl_bt/rtl8851bu_fw.bin').is_symlink()
with tempfile.TemporaryDirectory() as directory:
    state = Path(directory)
    native = Native(library, state)
    assert len(bytes.fromhex(native.public_key)) == 32
    native.allow_enrollment(True)
    assert not native.enrolling and not native.management_authorized
    native.close()
    key = (state / 'identity.key').read_bytes()
    # A previously approved app can rediscover the same relay under a new
    # peripheral identifier. Its retained client key must reach local approval.
    client_key = bytes(range(32))
    clients = json.dumps({'version': 1, 'clients': [client_key.hex()]}, separators=(',', ':'))
    (state / 'paired-clients.json').write_text(clients)
    native = Native(library, state)
    native.tablet(False)
    assert not native.observing
    def record(kind, sequence, payload):
        body = struct.pack('<IHHII', 0x504c5452, 1, kind, sequence, len(payload)) + payload
        return struct.pack('<H', len(body)) + body
    start = record(16, 1, b'\x03') + record(32, 2, bytes(48) + client_key + b'\x05smoke')
    replies = []
    for offset in range(0, len(start), 20):
        replies.extend(native.receive(start[offset:offset+20]))
    assert native.approval_pending == 2
    assert len(replies) == 1 and replies[0][18:22] == bytes([1, 0, 0, 3])
    native.disconnect()
    assert native.approval_pending == 0
    native.close()
    assert (state / 'paired-clients.json').read_text() == clients
    assert (state / 'identity.key').read_bytes() == key
    assert (state / 'identity.key').stat().st_mode & 0o777 == 0o600
    native = Native(library, state)
    assert native.has_clients
    native.reset_clients()
    native.close()
    assert (state / 'identity.key').read_bytes() == key
    native = Native(library, state)
    assert not native.has_clients
    native.close()
print('PASS: extracted package imports, native re-approval, retained trust and default policy')
