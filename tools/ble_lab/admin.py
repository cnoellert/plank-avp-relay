# SPDX-License-Identifier: GPL-3.0-or-later
"""Explicit SSH recovery; never remove an identity or unrelated Bluetooth bond."""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import shutil
import subprocess

from .config import read_settings
from .native import Native
from .tablets import address, hid, save, wacom

STATE = Path('/var/lib/plank-tablet-relay-ble')
CONFIG = Path('/etc/plank-tablet-relay-ble/relay.conf')
LIBRARY = Path('/usr/lib/plank-tablet-relay-ble/libplank_ble_lab.so')


def remove_tablet(backend, target, state):
    """Only a saved/verified Wacom device; never an arbitrary Bluetooth peer."""
    target = address(target)
    path = state / 'tablets.json'
    data = json.loads(path.read_text()) if path.exists() else {
        'version': 1, 'selected': None, 'tablets': [], 'pending': None}
    properties = backend.devices().get(target, {})
    if target not in data['tablets'] and not (wacom(properties) and hid(properties)):
        raise ValueError('The address is not a saved Wacom tablet on this relay.')
    backend.remove(target)
    data['tablets'] = [key for key in data['tablets'] if key != target]
    if data['selected'] == target:
        data['selected'] = None
    if (data.get('pending') or {}).get('id') == target:
        data['pending'] = None
    save(path, data)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=('reset-headsets', 'remove-tablet'))
    parser.add_argument('tablet', nargs='?')
    parser.add_argument('--yes', action='store_true', help='Confirm the selected recovery operation')
    args = parser.parse_args()
    if os.geteuid() != 0:
        parser.error('Run this command with sudo.')
    if not args.yes:
        parser.error('Add --yes to confirm. Relay identity and unrelated bonds will be retained.')
    if (args.operation == 'remove-tablet') != bool(args.tablet):
        parser.error('remove-tablet requires a Bluetooth address; reset-headsets takes no address.')
    target = address(args.tablet) if args.tablet else None
    was_active = subprocess.run(['systemctl', 'is-active', '--quiet', 'plank-tablet-relay-ble']).returncode == 0
    subprocess.run(['systemctl', 'stop', 'plank-tablet-relay-ble'], check=True, timeout=20)
    native = None
    try:
        native = Native(LIBRARY, STATE)  # Hold the same exclusive store lock as the service.
        backup = Path('/var/backups/plank-tablet-relay') / datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S.%fZ')
        backup.mkdir(parents=True, mode=0o700)
        for name in ('paired-clients.json', 'tablets.json'):
            if (STATE / name).exists():
                shutil.copy2(STATE / name, backup / name)
        if args.operation == 'reset-headsets':
            native.reset_clients()
            print('Headset approvals revoked. Relay identity and tablet bonds retained.')
            print('Open tablet setup in the app and pair or reconnect a tablet to authorize the replacement headset.')
        else:
            import dbus
            import dbus.mainloop.glib
            from .tablet_bluez import TabletBlueZ
            dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
            settings = read_settings(CONFIG)
            backend = TabletBlueZ(dbus.SystemBus(), '/org/bluez/' + settings.adapter)
            remove_tablet(backend, target, STATE)
            if settings.tablet.lower() in (target.lower(), 'bluetooth:' + target.lower()):
                shutil.copy2(CONFIG, backup / 'relay.conf')
                lines = CONFIG.read_text().splitlines(keepends=True)
                CONFIG.write_text(''.join('tablet =\n' if line.strip().startswith('tablet') and '=' in line else line for line in lines))
            print('Selected tablet bond removed. Other tablet bonds and headset approvals retained.')
        print('Previous enrollment metadata saved in ' + str(backup))
        return 0
    finally:
        if native:
            native.close()
        if was_active:
            subprocess.run(['systemctl', 'start', 'plank-tablet-relay-ble'], check=True, timeout=40)


if __name__ == '__main__':
    raise SystemExit(main())
