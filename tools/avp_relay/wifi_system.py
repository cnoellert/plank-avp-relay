# SPDX-License-Identifier: GPL-3.0-or-later
"""Own one WLAN interface; never alter Bluetooth, Ethernet or USB forwarding."""
import configparser
import json
import os
from pathlib import Path
import re
import tempfile

import dbus
from dbus.mainloop.glib import DBusGMainLoop

from .gadget_config import atomic_json
from .gadget_system import read, run
from .wifi_supplicant import Supplicant, IFACE, BUS

STATE = Path('/var/lib/plank-avp-relay/wifi')
CONFIG = Path('/etc/plank-avp-relay/wifi.conf')
NETWORK = Path('/etc/systemd/network/03-plank-wifi.network')
MARKER = '# Managed by plank-avp-relay-wifi\n'


def read_settings(path=CONFIG):
    parser = configparser.ConfigParser(interpolation=None)
    with Path(path).open() as source: parser.read_file(source)
    if parser.defaults() or parser.sections() != ['wifi'] or set(parser['wifi']) - {'interface'}:
        raise ValueError('Expected only a [wifi] section and optional interface.')
    interface = parser['wifi'].get('interface', '')
    if interface and not re.fullmatch('[a-zA-Z0-9_-]{1,15}', interface):
        raise ValueError('Invalid Wi-Fi interface name.')
    return interface


def private_write(path, contents):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, temporary = tempfile.mkstemp(prefix='.wifi-', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as output:
            output.write(contents)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
        fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try: os.fsync(fd)
        finally: os.close(fd)
    finally:
        if os.path.exists(temporary): os.unlink(temporary)


def network_file(interface):
    return (MARKER + f'[Match]\nName={interface}\n\n[Link]\nRequiredForOnline=no\n\n'
            '[Network]\nDHCP=yes\nIPv6AcceptRA=yes\nLinkLocalAddressing=ipv6\n'
            '\n[DHCPv4]\nRouteMetric=32760\n\n[DHCPv6]\nRouteMetric=32760\n'
            '\n[IPv6AcceptRA]\nRouteMetric=32760\n')


class LinuxWifi:
    def __init__(self, interface='', state=STATE):
        self.interface, self.state = interface, Path(state)
        self.wp = None
        self.rfkill = None
        self.foreign_units = []
        self.foreign_config = None
        self.unsupported = ''
        self.initial_enabled = False
        self.adopted = False

    def prepare(self):
        if self.wp: self.wp.bus.close()  # Release old signal subscriptions on recovery.
        self.adopted = False
        self.foreign_units = []
        self.foreign_config = None
        devices = [p for p in sorted(Path('/sys/class/net').iterdir()) if (p/'phy80211').exists()]
        if self.interface: devices = [p for p in devices if p.name == self.interface]
        if len(devices) != 1:
            self.unsupported = 'No Wi-Fi adapter is available.' if not devices else 'Select the Wi-Fi interface in the relay configuration.'
            return False
        self.interface = devices[0].name
        if run('systemctl', 'is-active', 'systemd-networkd.service', check=False) != 'active':
            self.unsupported = 'Wi-Fi management requires systemd-networkd on this appliance.'
            return False
        # Preserve an existing NetworkManager installation instead of creating
        # two owners for the same adapter. Our supported appliance uses networkd.
        if run('systemctl', 'is-active', 'NetworkManager.service', check=False) == 'active':
            self.unsupported = 'This host uses NetworkManager; its existing Wi-Fi settings have been preserved.'
            return False
        phy = (devices[0]/'phy80211').resolve()
        switches = [p for p in Path('/sys/class/rfkill').glob('rfkill*')
                    if read(p/'type') == 'wlan' and (p/'device').resolve() == phy]
        if len(switches) != 1:
            self.unsupported = 'The Wi-Fi radio control could not be identified.'
            return False
        self.rfkill = switches[0]
        try: bus = dbus.SystemBus(private=True, mainloop=DBusGMainLoop())
        except dbus.DBusException:
            raise RuntimeError('The system bus is unavailable.') from None
        self.wp = Supplicant(bus, self.interface, self.state/'wpa.conf')
        existing, props = self.wp.existing()
        self.wp.path = existing
        source = str(props.get('ConfigFile', ''))
        if props.get('Networks') and not source:
            self.unsupported = 'Existing Wi-Fi profiles have no persistent configuration. They have been preserved; configure the appliance before taking ownership.'
            return False
        if source and source != str(self.wp.config): self.foreign_config = Path(source)
        for unit, path in (
            (f'netplan-wpa-{self.interface}.service', Path(f'/run/netplan/wpa-{self.interface}.conf')),
            (f'wpa_supplicant@{self.interface}.service', Path(f'/etc/wpa_supplicant/wpa_supplicant-{self.interface}.conf')),
            (f'wpa_supplicant-nl80211@{self.interface}.service', Path(f'/etc/wpa_supplicant/wpa_supplicant-nl80211-{self.interface}.conf')),
        ):
            if run('systemctl', 'is-active', unit, check=False) == 'active':
                self.foreign_units.append(unit)
                if not source: self.foreign_config = path
        configured = bool(self.foreign_config or self.wp.config.exists() or props.get('Networks'))
        self.initial_enabled = configured and read(self.rfkill/'soft') == '0'
        return True

    def adopt(self):
        if self.adopted: return
        metadata = self.state/'ownership.json'
        if NETWORK.exists() and not NETWORK.read_text().startswith(MARKER):
            raise RuntimeError('The relay Wi-Fi configuration filename is already in use.')
        if self.foreign_config and not self.foreign_config.is_file():
            raise RuntimeError('The existing Wi-Fi configuration could not be preserved.')
        if not metadata.exists():
            original = self.foreign_config.read_bytes() if self.foreign_config else b''
            private_write(self.state/'original-wpa.conf', original)
            atomic_json(metadata, dict(interface=self.interface, units=self.foreign_units,
                source=str(self.foreign_config or ''), blocked=read(self.rfkill/'soft') == '1'))
        if not self.wp.config.exists():
            contents = self.foreign_config.read_bytes() if self.foreign_config else b''
            # Only replace a top-level global property; network credentials and
            # existing profiles stay in wpa_supplicant's own file format.
            contents = re.sub(rb'^update_config=.*\n?', b'', contents, flags=re.MULTILINE)
            private_write(self.wp.config, b'update_config=1\n' + contents)
        for unit in self.foreign_units:
            run('systemctl', 'mask', '--now', unit)
        self.foreign_units = []
        if self.wp.path:
            if str(self.wp.properties().get('ConfigFile', '')) != str(self.wp.config): self.wp.close()
        self.wp.open()
        self.foreign_config = None
        if not NETWORK.exists():
            private_write(NETWORK, network_file(self.interface).encode())
            NETWORK.chmod(0o644)
            run('networkctl', 'reload')
            run('networkctl', 'reconfigure', self.interface)
        if str(NETWORK) not in run('networkctl', 'status', self.interface, '--no-pager'):
            raise RuntimeError('An earlier network configuration overrides the relay Wi-Fi settings.')
        self.adopted = True

    def initialize(self, enabled, managed):
        if managed:
            self.adopt()
            self.set_enabled(enabled)
        elif not self.initial_enabled:
            # A fresh radio starts off. Existing configured connections remain
            # untouched until an authorized Wi-Fi operation takes ownership.
            self.radio(False)

    def radio(self, enabled):
        if enabled and read(self.rfkill/'hard') == '1':
            raise RuntimeError('Wi-Fi is disabled by a hardware switch.')
        if read(self.rfkill/'soft') != ('0' if enabled else '1'):
            run('rfkill', 'unblock' if enabled else 'block', self.rfkill.name.removeprefix('rfkill'))

    def set_enabled(self, enabled):
        self.radio(enabled)

    def begin(self):
        previously_owned = (self.state/'ownership.json').exists()
        try: self.adopt()
        except (OSError, ValueError, RuntimeError):
            if not previously_owned and (self.state/'ownership.json').exists():
                self.remove()
                (self.state/'ownership.json').unlink()
                self.prepare()
            raise
        self.wp.save()  # Preserve the exact previous working profiles for rollback.
        private_write(self.state/'before-operation.conf', self.wp.config.read_bytes())

    def rollback(self):
        backup = self.state/'before-operation.conf'
        if backup.exists():
            self.wp.close()
            private_write(self.wp.config, backup.read_bytes())
            self.wp.open()
            backup.unlink()

    def commit(self):
        self.wp.save()
        (self.state/'before-operation.conf').unlink(missing_ok=True)

    def saved(self): return self.wp.saved() if self.wp and self.wp.path else {}
    def scan(self):
        if not self.wp.path: self.adopt()
        self.wp.scan()
    def scan_done(self): return self.wp.scan_done()
    def results(self): return self.wp.scan_results()
    def join(self, item, password): self.wp.join(item, password)
    def connect(self, identifier): self.wp.select(self.saved()[identifier]['path'])
    def forget(self, identifier):
        item = self.saved().get(identifier)
        if item:
            for path in item['paths']: self.wp.remove(path)

    def status(self):
        if not self.rfkill: return dict(connection='unavailable', network=None, name=None, addresses=[])
        if read(self.rfkill/'hard') == '1': state = 'blocked'
        elif read(self.rfkill/'soft') == '1': state = 'disabled'
        else: state = 'disconnected'
        if state in ('blocked', 'disabled'):
            return dict(connection=state, network=None, name=None, addresses=[])
        props = self.wp.properties() if self.wp and self.wp.path else {}
        networks = self.saved()
        item = next((p for p in networks.values() if str(props.get('CurrentNetwork')) in p['paths']), None)
        addresses = []
        info = json.loads(run('ip', '-j', 'address', 'show', 'dev', self.interface))
        for interface in info:
            addresses += [a['local'] for a in interface.get('addr_info', [])
                          if a['scope'] == 'global' and not {'tentative', 'dadfailed'}.intersection(a.get('flags', []))
                          and not a.get('tentative') and not a.get('dadfailed')]
        if state not in ('blocked', 'disabled'):
            if props.get('State') == 'completed': state = 'connected' if addresses else 'address'
            elif props.get('State') in ('authenticating', 'associating', 'associated', '4way_handshake', 'group_handshake'):
                state = 'associating'
            elif not self.wp.path and self.foreign_config and addresses:
                state = 'connected'  # Preserve a pre-existing per-interface supplicant.
        return dict(connection=state, network=item['id'] if item else None,
                    name=item['name'] if item else None, addresses=addresses[:8])

    def remove(self):
        metadata = self.state/'ownership.json'
        if not metadata.exists(): return
        data = json.loads(metadata.read_text())
        self.interface = data['interface']
        wp = Supplicant(dbus.SystemBus(), self.interface, self.state/'wpa.conf')
        path, props = wp.existing()
        if path and str(props.get('ConfigFile')) == str(wp.config):
            wp.path = path
            wp.save()
            wp.close()
        if NETWORK.exists() and NETWORK.read_text().startswith(MARKER):
            NETWORK.unlink()
            run('networkctl', 'reload', check=False)
            run('networkctl', 'reconfigure', self.interface, check=False)
        for unit in data['units']:
            run('systemctl', 'unmask', unit)
            run('systemctl', 'start', unit)
        if data['source'] and not data['units']:
            original = Supplicant(dbus.SystemBus(), self.interface, Path(data['source']))
            original.open()
        # Radio policy is deliberately retained on removal; saved private
        # profiles also survive so reinstalling does not lose enrollment.
