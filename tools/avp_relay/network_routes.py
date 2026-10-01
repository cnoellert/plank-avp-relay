# SPDX-License-Identifier: GPL-3.0-or-later
"""Read local listener routes without changing interfaces or using a shell."""
import fcntl
import ipaddress
from pathlib import Path
import socket
import struct


def usable_addresses(values, families):
    result = []
    for value in values:
        try:
            address = ipaddress.ip_address(value)
        except ValueError:
            continue
        family = socket.AF_INET if address.version == 4 else socket.AF_INET6
        if (family not in families or address.is_unspecified or address.is_loopback or
                address.is_multicast or address.is_link_local or
                (address.version == 4 and (int(address) >> 24 == 0 or int(address) >> 24 >= 224)) or
                (address.version == 6 and address.ipv4_mapped is not None)):
            continue
        literal = str(address)
        if literal not in result:
            result.append(literal)
        if len(result) == 8:
            break
    return result


def local_addresses(families):
    values, active = [], set()
    # glibc's if_nameindex opens AF_NETLINK, which the main relay service
    # deliberately excludes. Enumerate the kernel's read-only interface list
    # instead; address reads still use the already permitted AF_INET socket.
    try:
        names = [entry.name for entry in Path('/sys/class/net').iterdir()]
    except OSError:
        return []
    try:
        channel = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    except OSError:
        return []
    with channel:
        for name in sorted(names):
            request = struct.pack('256s', name.encode()[:15])
            try:
                flags = fcntl.ioctl(channel, 0x8913, request)  # SIOCGIFFLAGS
                if not struct.unpack_from('H', flags, 16)[0] & 1:  # IFF_UP
                    continue
                active.add(name)
                record = fcntl.ioctl(channel, 0x8915, request)  # SIOCGIFADDR
                values.append(socket.inet_ntop(socket.AF_INET, record[20:24]))
            except OSError:
                continue
    try:
        for line in Path('/proc/net/if_inet6').read_text().splitlines():
            address, _, _, scope, flags, name = line.split()
            if name in active and scope == '00' and not int(flags, 16) & 0x48:
                values.append(str(ipaddress.IPv6Address(int(address, 16))))
    except (OSError, ValueError):
        pass
    return usable_addresses(values, families)
