# SPDX-License-Identifier: GPL-3.0-or-later
"""Explicit lab workaround for controller private-address resolution failures."""
import socket
import struct
import time


def adapter_index(adapter):
    if not adapter.startswith('hci') or not adapter[3:].isascii() or not adapter[3:].isdigit():
        raise ValueError('Expected a Linux HCI adapter name')
    index = int(adapter[3:])
    if index >= 0xffff:
        raise ValueError('HCI adapter index is out of range')
    return index


def management_command(channel, index, opcode, parameters=b''):
    """Bounded request on Linux's documented HCI_CHANNEL_CONTROL interface."""
    deadline = time.monotonic() + 3
    channel.settimeout(3)
    channel.sendall(struct.pack('<HHH', opcode, index, len(parameters)) + parameters)
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError('Controller management command timed out')
        channel.settimeout(remaining)
        try:
            packet = channel.recv(65541)
        except socket.timeout as error:
            raise TimeoutError('Controller management command timed out') from error
        if len(packet) < 6:
            raise RuntimeError('Malformed controller management event')
        event, controller, length = struct.unpack_from('<HHH', packet)
        if len(packet) != 6 + length:
            raise RuntimeError('Malformed controller management event')
        if controller != index or event not in (1, 2):
            continue
        if length < 3:
            raise RuntimeError('Malformed controller management response')
        response_opcode, status = struct.unpack_from('<HB', packet, 6)
        if response_opcode != opcode:
            continue
        if status:
            raise RuntimeError(f'Controller management command rejected (0x{status:02x})')
        if event == 1:
            return packet[9:]


def clear_advertisements(adapter):
    """Recover kernel-retained advertisements on an explicitly dedicated adapter.

    The caller must first verify BlueZ reports zero active advertisements and no
    discovery. This must never be used on a shared adapter without that policy.
    """
    index = adapter_index(adapter)
    # Avoid btmgmt's interactive shell: it can wait forever with stdin=/dev/null.
    # https://github.com/bluez/bluez/wiki/MGMT#read-advertising-features
    with socket.socket(socket.AF_BLUETOOTH, socket.SOCK_RAW, socket.BTPROTO_HCI) as channel:
        channel.bind((0xffff, 3))  # HCI_DEV_NONE, HCI_CHANNEL_CONTROL.
        features = management_command(channel, index, 0x003d)
        if len(features) < 8 or len(features) != 8 + features[7] or features[7] > features[6]:
            raise RuntimeError('Malformed advertising feature response')
        if features[7] == 0:
            return  # Removing all instances when none exist can be rejected.
        result = management_command(channel, index, 0x003f, b'\x00')
        if result != b'\x00':
            raise RuntimeError('Malformed advertising removal response')


def disable_address_resolution(adapter):
    """Send one filtered, bounded HCI command; require its successful completion.

    Call before advertising, with no scan in progress. This is an opt-in
    controller workaround, not a change to host privacy or saved bonding keys.
    The kernel may re-enable resolution later; a controller restart requires
    restarting the lab so the command is applied again.
    """
    index = adapter_index(adapter)
    opcode = 0x202d  # LE Set Address Resolution Enable.
    # struct hci_filter: event packets; Command Complete/Status; this opcode.
    packet_filter = struct.pack('<IIIH2x', 1 << 4, (1 << 14) | (1 << 15), 0, opcode)
    with socket.socket(socket.AF_BLUETOOTH, socket.SOCK_RAW, socket.BTPROTO_HCI) as channel:
        channel.bind((index,))
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
