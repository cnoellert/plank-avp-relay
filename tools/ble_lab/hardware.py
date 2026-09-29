# SPDX-License-Identifier: GPL-3.0-or-later
"""Prepare supported USB radios without replacing OS firmware or active links."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time

from .controller import controller_indexes

BUNDLE = Path('/usr/share/plank-tablet-relay-ble/firmware')
FIRMWARE = Path('/lib/firmware')
USB = Path('/sys/bus/usb/devices')
BLUETOOTH = Path('/sys/class/bluetooth')
# USB identities of RTL8851BU radios, not tablet model restrictions.
RADIOS = {('3625', '010b'), ('0bda', 'b851')}


def read(path):
    try:
        return path.read_text().strip()
    except FileNotFoundError:
        return ''


def owned_link(path, source):
    return path.is_symlink() and os.readlink(path) == str(source)


def prepare_firmware(root=FIRMWARE, bundle=BUNDLE, release=None, remove=False, extra=None):
    """Own only fallback symlinks; prefer any existing OS/admin firmware."""
    manifest = json.loads((bundle / 'manifest.json').read_text())
    release = release or os.uname().release
    for name, digest in manifest['files'].items():
        if Path(name).name != name or not name.endswith('.bin'):
            raise ValueError('Invalid bundled firmware filename')
        source = bundle / name
        fallback = root / 'updates/rtl_bt' / name
        ours = owned_link(fallback, source)
        if remove:
            if ours:
                fallback.unlink()
            continue
        if hashlib.sha256(source.read_bytes()).hexdigest() != digest:
            raise ValueError('Bundled firmware checksum mismatch: ' + name)
        bases = [root / 'updates' / release, root / 'updates', root / release, root]
        if extra:
            bases.insert(0, Path(extra))
        candidates = [base / 'rtl_bt' / (name + suffix)
                      for base in bases for suffix in ('', '.xz', '.zst')]
        supplied = any(path.is_file() and not owned_link(path, source) for path in candidates)
        if supplied:
            if ours:
                fallback.unlink()  # An OS package now supplies its own version.
        elif not ours:
            if fallback.exists() or fallback.is_symlink():
                raise RuntimeError('Refusing to replace existing firmware: ' + str(fallback))
            fallback.parent.mkdir(parents=True, exist_ok=True)
            fallback.symlink_to(source)
            print('Installed missing Bluetooth firmware: ' + name, flush=True)
    if remove:
        for directory in (root / 'updates/rtl_bt', root / 'updates'):
            try:
                directory.rmdir()  # Only empty directories; never remove other firmware.
            except OSError:
                pass


def run(arguments, timeout=10):
    result = subprocess.run(arguments, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True, timeout=timeout, check=False)
    if result.returncode:
        raise RuntimeError(f'{arguments[0]} failed: {result.stdout.strip()}')
    return result.stdout


def identity(device):
    return read(device / 'idVendor').lower(), read(device / 'idProduct').lower()


def switch_disks(usb=USB):
    for device in sorted(usb.glob('*')):
        if identity(device) != ('0bda', '1a2b'):
            continue
        interfaces = list(usb.glob(device.name + ':*'))
        if not interfaces or any(read(item / 'bInterfaceClass') != '08' for item in interfaces):
            continue
        bus, address = read(device / 'busnum'), read(device / 'devnum')
        if not bus.isdecimal() or not address.isdecimal():
            raise RuntimeError('USB driver disk has no valid bus/device address')
        print('Switching Realtek driver disk to radio mode: ' + device.name, flush=True)
        # Address this device only. Do not reset the USB bus or unload Wi-Fi.
        run(['usb_modeswitch', '-K', '-v', '0bda', '-p', '1a2b', '-b', bus, '-g', address])


def initialized(interface, bluetooth=BLUETOOTH):
    indexes = controller_indexes()
    return any(int(hci.name[3:]) in indexes and
               (hci / 'device').resolve() == interface.resolve()
               for hci in bluetooth.glob('hci[0-9]*') if hci.name[3:].isdigit())


def wait_initialized(interface, seconds=3):
    deadline = time.monotonic() + seconds
    while True:
        if initialized(interface):
            return True
        if time.monotonic() >= deadline:
            return False
        time.sleep(0.2)


def recover_radios(usb=USB, drivers=Path('/sys/bus/usb/drivers')):
    for device in sorted(usb.glob('*')):
        if identity(device) not in RADIOS:
            continue
        # Only interface zero owns the Bluetooth controller; the second
        # Bluetooth interface is claimed by it. Leave the Wi-Fi interface alone.
        interface = usb / (device.name + ':1.0')
        if (read(interface / 'bInterfaceClass'), read(interface / 'bInterfaceSubClass'),
                read(interface / 'bInterfaceProtocol')) != ('e0', '01', '01'):
            continue
        if not (interface / 'driver').exists():
            run(['modprobe', 'btusb'])
            (drivers.parent / 'drivers_probe').write_text(interface.name)
        if (interface / 'driver').resolve().name != 'btusb':
            raise RuntimeError('Supported radio requires the Linux btusb driver')
        if wait_initialized(interface):
            continue  # Includes powered-off controllers: never reset a valid radio.
        print('Retrying Bluetooth firmware initialization: ' + interface.name, flush=True)
        driver = drivers / 'btusb'
        (driver / 'unbind').write_text(interface.name)
        (driver / 'bind').write_text(interface.name)
        if not wait_initialized(interface):
            raise RuntimeError('Bluetooth firmware initialization failed; inspect the kernel journal')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    options = parser.add_mutually_exclusive_group()
    options.add_argument('--firmware-only', action='store_true')
    options.add_argument('--remove-links', action='store_true')
    args = parser.parse_args()
    try:
        with open('/run/lock/plank-tablet-relay-hardware.lock', 'w') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            prepare_firmware(remove=args.remove_links,
                extra=read(Path('/sys/module/firmware_class/parameters/path')))
            if not args.firmware_only and not args.remove_links:
                switch_disks()
                run(['udevadm', 'settle', '--timeout=10'], timeout=12)
                # A mode-switched radio can enumerate after udev's current queue
                # has drained. Firmware is already available for that hotplug.
                recover_radios()
        return 0
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        print('Bluetooth hardware preparation failed: ' + str(error), flush=True)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
