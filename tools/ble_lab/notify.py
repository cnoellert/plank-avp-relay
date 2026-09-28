# SPDX-License-Identifier: GPL-3.0-or-later
"""Small sd_notify sender; used only by the installed service."""
import os
import socket


def ready():
    address = os.environ.get('NOTIFY_SOCKET')
    if not address:
        return
    if address.startswith('@'):
        address = '\0' + address[1:]
    with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as channel:
        channel.connect(address)
        channel.sendall(b'READY=1\nSTATUS=Bluetooth relay is advertising')
