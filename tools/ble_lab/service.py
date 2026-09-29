# SPDX-License-Identifier: GPL-3.0-or-later
"""Installed service entry point; no shell interpolation or dynamic config code."""
import argparse
import configparser
from pathlib import Path
import sys
from types import SimpleNamespace

from .config import read_settings


def main():
    parser = argparse.ArgumentParser(description='PLANK network and Bluetooth tablet relay')
    parser.add_argument('--config', type=Path, default=Path('/etc/plank-tablet-relay-ble/relay.conf'))
    parser.add_argument('--check-config', action='store_true')
    args = parser.parse_args()
    try:
        settings = read_settings(args.config)
        if args.check_config:
            print('Relay configuration is valid.')
            return 0
        from .bluez import Server
        Server(SimpleNamespace(**vars(settings),
            library=Path('/usr/lib/plank-tablet-relay-ble/libplank_ble_lab.so'),
            state_dir=Path('/var/lib/plank-tablet-relay-ble'), transport_only=False,
            version=Path('/usr/share/plank-tablet-relay-ble/version').read_text().strip(),
            notify_systemd=True)).run()
        return 0
    except (OSError, ValueError, RuntimeError, configparser.Error) as error:
        print('Relay startup failed: ' + str(error), file=sys.stderr, flush=True)
        return 1


if __name__ == '__main__':
    sys.exit(main())
