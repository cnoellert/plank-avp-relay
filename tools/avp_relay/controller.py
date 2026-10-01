# SPDX-License-Identifier: GPL-3.0-or-later
"""Bounded Linux Bluetooth controller configuration for the relay."""
import ctypes
import os
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


class _SockaddrHCI(ctypes.Structure):
    _fields_ = [('family', ctypes.c_ushort), ('device', ctypes.c_ushort),
                ('channel', ctypes.c_ushort)]


def bind_control(channel):
    """Bind Linux HCI_CHANNEL_CONTROL, including on Python before 3.14.

    Older Python socket.bind only accepts a device, silently defaulting to the
    raw channel. Use the kernel sockaddr_hci ABI explicitly; never fall back to
    sending management commands on a raw HCI channel.
    """
    address = _SockaddrHCI(socket.AF_BLUETOOTH, 0xffff, 3)
    bind = ctypes.CDLL(None, use_errno=True).bind
    bind.argtypes = (ctypes.c_int, ctypes.POINTER(_SockaddrHCI), ctypes.c_uint)
    bind.restype = ctypes.c_int
    if bind(channel.fileno(), ctypes.byref(address), ctypes.sizeof(address)) != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))


def controller_indexes():
    """Return initialized kernel controllers, without changing their state."""
    with socket.socket(socket.AF_BLUETOOTH, socket.SOCK_RAW, socket.BTPROTO_HCI) as channel:
        bind_control(channel)
        result = management_command(channel, 0xffff, 0x0003)
    if len(result) < 2:
        raise RuntimeError('Malformed controller index list')
    count, = struct.unpack_from('<H', result)
    if len(result) != 2 + count * 2:
        raise RuntimeError('Malformed controller index list')
    return set(struct.unpack_from(f'<{count}H', result, 2))


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
        bind_control(channel)
        features = management_command(channel, index, 0x003d)
        if len(features) < 8 or len(features) != 8 + features[7] or features[7] > features[6]:
            raise RuntimeError('Malformed advertising feature response')
        if features[7] == 0:
            return  # Removing all instances when none exist can be rejected.
        result = management_command(channel, index, 0x003f, b'\x00')
        if result != b'\x00':
            raise RuntimeError('Malformed advertising removal response')


def _system_configuration(payload):
    values = {}
    offset = 0
    while offset < len(payload):
        if len(payload) - offset < 3:
            raise RuntimeError('Malformed controller system configuration')
        kind, length = struct.unpack_from('<HB', payload, offset)
        offset += 3
        if kind in values or offset + length > len(payload):
            raise RuntimeError('Malformed controller system configuration')
        values[kind] = payload[offset:offset + length]
        offset += length
    return values


def configure_le_connection_parameters(adapter):
    """Prefer 15 ms LE links before advertising, without resetting the radio.

    Linux requests these defaults when a new peripheral connection arrives
    outside the preferred interval. The central decides whether to accept;
    successful configuration alone does not establish the negotiated timing.
    These defaults affect new LE links on this adapter, not BR/EDR tablets.
    """
    index = adapter_index(adapter)
    # MGMT Read/Set Default System Configuration (kernel 5.8+).
    # Intervals use 1.25 ms units; supervision uses 10 ms units. Zero latency
    # and 720 ms supervision match the measured AVP link during the 15 ms trial.
    wanted = {0x0017: 12, 0x0018: 12, 0x0019: 0, 0x001a: 72}
    wanted = {kind: struct.pack('<H', value) for kind, value in wanted.items()}
    with socket.socket(socket.AF_BLUETOOTH, socket.SOCK_RAW, socket.BTPROTO_HCI) as channel:
        bind_control(channel)
        current = _system_configuration(management_command(channel, index, 0x004b))
        if any(len(current.get(kind, b'')) != 2 for kind in wanted):
            raise RuntimeError('Controller LE connection parameters unavailable')
        if all(current[kind] == value for kind, value in wanted.items()):
            return
        # Write only these four preferences; retain every other system setting.
        parameters = b''.join(struct.pack('<HB', kind, len(value)) + value
                              for kind, value in wanted.items())
        management_command(channel, index, 0x004c, parameters)
        actual = _system_configuration(management_command(channel, index, 0x004b))
        if any(actual.get(kind) != value for kind, value in wanted.items()):
            raise RuntimeError('Controller LE connection parameter readback mismatch')


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
