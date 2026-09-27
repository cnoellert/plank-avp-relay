#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Run the explicit BLE input-observer prototype; no production service install."""
import argparse
from pathlib import Path
from ble_lab.bluez import Server

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--library', required=True, type=Path)
parser.add_argument('--state-dir', required=True, type=Path)
parser.add_argument('--adapter', default='hci0')
parser.add_argument('--tablet', help='Selected Bluetooth address or physical identity; required if ambiguous')
args = parser.parse_args()
if not args.adapter.startswith('hci') or not args.adapter[3:].isdigit():
    parser.error('Expected an adapter such as hci0')
Server(args).run()
