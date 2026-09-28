# SPDX-License-Identifier: GPL-3.0-or-later
"""Explicit lab workaround for controller private-address resolution failures."""
import socket
import struct
import time


def disable_address_resolution(adapter):
    """Send one filtered, bounded HCI command; require its successful completion.

    Call before advertising, with no scan in progress. This is an opt-in
    controller workaround, not a change to host privacy or saved bonding keys.
    The kernel may re-enable resolution later; a controller restart requires
    restarting the lab so the command is applied again.
    """
    if not adapter.startswith('hci') or not adapter[3:].isascii() or not adapter[3:].isdigit():
        raise ValueError('Expected a Linux HCI adapter name')
    opcode = 0x202d  # LE Set Address Resolution Enable.
    # struct hci_filter: event packets; Command Complete/Status; this opcode.
    packet_filter = struct.pack('<IIIH2x', 1 << 4, (1 << 14) | (1 << 15), 0, opcode)
    with socket.socket(socket.AF_BLUETOOTH, socket.SOCK_RAW, socket.BTPROTO_HCI) as channel:
        channel.bind((int(adapter[3:]),))
        channel.setsockopt(0, 2, packet_filter)  # SOL_HCI, HCI_FILTER.
        deadline = time.monotonic() + 3
        channel.settimeout(3)
        channel.sendall(b'\x01' + struct.pack('<HB', opcode, 1) + b'\x00')
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError('Controller address-resolution command timed out')
            channel.settimeout(remaining)
            try:
                event = channel.recv(260)
            except socket.timeout as error:
                raise TimeoutError('Controller address-resolution command timed out') from error
            if len(event) < 3 or event[0] != 4 or len(event) != 3 + event[2]:
                raise RuntimeError('Malformed controller command response')
            if event[1] == 14 and len(event) == 7:
                response_opcode = int.from_bytes(event[4:6], 'little')
                status = event[6]
            elif event[1] == 15 and len(event) == 7:
                response_opcode = int.from_bytes(event[5:7], 'little')
                status = event[3]
            else:
                continue
            if response_opcode != opcode:
                continue
            if status:
                raise RuntimeError(f'Controller rejected address-resolution workaround (0x{status:02x})')
            if event[1] == 14:
                return
