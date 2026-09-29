# SPDX-License-Identifier: GPL-3.0-or-later
"""Installed service entry point; no shell interpolation or dynamic config code."""
import argparse
import configparser
from pathlib import Path
import sys
from types import SimpleNamespace

from .config import read_settings


def main():
    from .process import name_process
    name_process('plank-avp-relay')
    parser = argparse.ArgumentParser(description='PLANK AVP Relay')
    parser.add_argument('--config', type=Path, default=Path('/etc/plank-avp-relay/relay.conf'))
    parser.add_argument('--check-config', action='store_true')
    args = parser.parse_args()
    try:
        settings = read_settings(args.config)
        if args.check_config:
            print('Relay configuration is valid.')
            return 0
        from .bluez import Server
        Server(SimpleNamespace(**vars(settings),
            library=Path('/usr/lib/plank-avp-relay/libplank_avp_relay.so'),
            state_dir=Path('/var/lib/plank-avp-relay'), transport_only=False,
            version=Path('/usr/share/plank-avp-relay/version').read_text().strip(),
            notify_systemd=True)).run()
        return 0
    except (OSError, ValueError, RuntimeError, configparser.Error) as error:
        print('Relay startup failed: ' + str(error), file=sys.stderr, flush=True)
        return 1


if __name__ == '__main__':
    sys.exit(main())
