# SPDX-License-Identifier: GPL-3.0-or-later
"""Wi-Fi association through the current wpa_supplicant D-Bus API."""
from pathlib import Path

import dbus

from .wifi_protocol import network_id, public_network, MAX_NETWORKS

BUS = 'fi.w1.wpa_supplicant1'
ROOT = '/fi/w1/wpa_supplicant1'
IFACE = BUS + '.Interface'
PROPS = 'org.freedesktop.DBus.Properties'


def ssid_bytes(value):
    if isinstance(value, (bytes, bytearray, dbus.ByteArray, dbus.Array)):
        return bytes(value)
    value = str(value)
    if value.startswith('"') and value.endswith('"'):
        # Network.Properties uses wpa_config_get: printable SSIDs are literal
        # quoted bytes (including interior quotes/backslashes), not C escapes.
        return value[1:-1].encode('utf-8')
    try:
        return bytes.fromhex(value)
    except ValueError:
        return b''


def saved_security(properties):
    key = str(properties.get('key_mgmt', '')).strip('"').split()
    if 'WPA-PSK' in key or 'WPA-PSK-SHA256' in key: return 'personal'
    if 'SAE' in key: return 'sae'
    if key == ['NONE'] and not any(str(k).startswith('wep_key') for k in properties): return 'open'
    return 'unsupported'


def bss_security(properties):
    keys = {str(k).lower() for k in properties.get('RSN', {}).get('KeyMgmt', [])}
    if 'wpa-psk' in keys or 'wpa-psk-sha256' in keys: return 'personal'
    if 'sae' in keys: return 'sae'
    if not properties.get('Privacy') and not keys and not properties.get('WPA', {}).get('KeyMgmt'): return 'open'
    return 'unsupported'


class Supplicant:
    def __init__(self, bus, interface, config, driver='nl80211'):
        self.bus, self.interface, self.config, self.driver = bus, interface, Path(config), driver
        self.path = None

    def call(self, path, interface, method, *args):
        # Never expose D-Bus exception text: rejected parameters can contain a key.
        try:
            obj = self.bus.get_object(BUS, path, introspect=False)
            return obj.get_dbus_method(method, interface)(*args, timeout=3)
        except dbus.DBusException:
            raise RuntimeError('The Wi-Fi service could not complete the operation.') from None

    def properties(self, path=None, interface=IFACE):
        return self.call(path or self.path, PROPS, 'GetAll', interface)

    def existing(self):
        root = self.properties(ROOT, BUS)
        for path in root.get('Interfaces', []):
            props = self.properties(path)
            if str(props.get('Ifname')) == self.interface:
                return str(path), props
        return None, {}

    def open(self):
        path, props = self.existing()
        if path:
            if str(props.get('ConfigFile', '')) != str(self.config):
                raise RuntimeError('Another Wi-Fi configuration owns this adapter.')
            self.path = path
        else:
            self.path = str(self.call(ROOT, BUS, 'CreateInterface', dbus.Dictionary({
                'Ifname': self.interface, 'Driver': self.driver, 'ConfigFile': str(self.config)}, signature='sv')))

    def close(self):
        if self.path:
            self.call(ROOT, BUS, 'RemoveInterface', dbus.ObjectPath(self.path))
            self.path = None

    def saved(self):
        result = {}
        for path in self.properties().get('Networks', []):
            props = self.properties(path, BUS + '.Network').get('Properties', {})
            ssid = ssid_bytes(props.get('ssid', ''))
            if not 1 <= len(ssid) <= 32: continue
            security = saved_security(props)
            item = public_network(ssid, security, saved=True, hidden=str(props.get('scan_ssid', '0')) == '1')
            item.update(path=str(path), paths=[str(path)], ssid=ssid, security=security)
            if item['id'] in result: result[item['id']]['paths'].append(str(path))
            else: result[item['id']] = item
            if len(result) == MAX_NETWORKS: break
        return result

    def scan(self):
        self.call(self.path, IFACE, 'Scan', dbus.Dictionary({'Type': 'active', 'AllowRoam': False}, signature='sv'))

    def scan_results(self):
        saved = self.saved()
        result = {}
        for path in list(self.properties().get('BSSs', []))[:1024]:
            props = self.properties(path, BUS + '.BSS')
            ssid = bytes(props.get('SSID', []))
            if not 1 <= len(ssid) <= 32: continue
            security = bss_security(props)
            signal = max(0, min(100, 2 * (int(props.get('Signal', -100)) + 100)))
            item = public_network(ssid, security, signal, network_id(ssid, security) in saved)
            item.update(ssid=ssid, security=security)
            previous = result.get(item['id'])
            if not previous or signal > previous['signal']: result[item['id']] = item
        return dict(sorted(result.items(), key=lambda pair: -pair[1]['signal'])[:MAX_NETWORKS])

    def join(self, item, password):
        # Replace only this exact SSID/security profile, preserving other networks.
        current = self.saved().get(item['id'])
        if current:
            for path in current['paths']: self.remove(path)
        values = {'ssid': dbus.ByteArray(item['ssid']), 'scan_ssid': dbus.Int32(int(item.get('hidden', False)))}
        security = item['security']
        if security == 'open': values['key_mgmt'] = 'NONE'
        elif security == 'personal':
            key = dbus.ByteArray(bytes.fromhex(password)) if len(password) == 64 else password
            values.update(key_mgmt='WPA-PSK', psk=key, ieee80211w=dbus.Int32(1))
        elif security == 'sae':
            values.update(key_mgmt='SAE', sae_password=password, ieee80211w=dbus.Int32(2))
        else: raise ValueError('This network requires another sign-in method.')
        path = str(self.call(self.path, IFACE, 'AddNetwork', dbus.Dictionary(values, signature='sv')))
        self.select(path)

    def select(self, path): self.call(self.path, IFACE, 'SelectNetwork', dbus.ObjectPath(path))
    def remove(self, path): self.call(self.path, IFACE, 'RemoveNetwork', dbus.ObjectPath(path))
    def save(self):
        self.call(self.path, IFACE, 'SaveConfig')
        self.config.chmod(0o600)
