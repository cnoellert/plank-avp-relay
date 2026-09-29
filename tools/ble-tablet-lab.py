#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Run the explicit BLE input-observer prototype; no production service install."""
import argparse
from pathlib import Path
from avp_relay.bluez import Server

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--library', type=Path)
parser.add_argument('--state-dir', type=Path)
parser.add_argument('--transport-only', action='store_true', help='Only byte echo; no tablet, crypto library or identity store')
parser.add_argument('--adapter', default='hci0')
parser.add_argument('--disable-controller-address-resolution', action='store_true',
                    help='Opt-in HCI workaround for qualified private-address connection failures')
parser.add_argument('--tablet', help='Selected Bluetooth address or physical identity; required if ambiguous')
args = parser.parse_args()
if args.transport_only and (args.library or args.state_dir or args.tablet):
    parser.error('--transport-only does not use library, state-dir or tablet options')
if not args.transport_only and (not args.library or not args.state_dir):
    parser.error('--library and --state-dir are required for tablet pairing/readings')
if not args.adapter.startswith('hci') or not args.adapter[3:].isdigit():
    parser.error('Expected an adapter such as hci0')
Server(args).run()
