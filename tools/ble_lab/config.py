# SPDX-License-Identifier: GPL-3.0-or-later
"""Strict configuration for the installed Bluetooth relay service."""
import configparser
from dataclasses import dataclass, field
import hashlib
from pathlib import Path
import re
import socket


def hostname_name():
    name = socket.gethostname().split('.', 1)[0]
    raw = name.encode('utf-8')
    if len(raw) > 26:
        name = raw[:21].decode('utf-8', errors='ignore') + '-' + hashlib.sha256(raw).hexdigest()[:4]
    return name


@dataclass(frozen=True)
class Settings:
    adapter: str = 'hci0'
    tablet: str = ''
    name: str = field(default_factory=hostname_name)
    exclusive_adapter: bool = False
    disable_controller_address_resolution: bool = False


def read_settings(path):
    parser = configparser.ConfigParser(interpolation=None)
    with Path(path).open() as stream:
        parser.read_file(stream)
    if parser.defaults() or parser.sections() != ['relay']:
        raise ValueError('Configuration must contain only a [relay] section')
    values = parser['relay']
    if set(values) - set(Settings.__dataclass_fields__):
        raise ValueError('Unknown relay configuration option')
    settings = Settings(
        adapter=values.get('adapter', 'hci0').strip(),
        tablet=values.get('tablet', '').strip(),
        name=values.get('name', hostname_name()).strip(),
        exclusive_adapter=values.getboolean('exclusive_adapter', False),
        disable_controller_address_resolution=values.getboolean('disable_controller_address_resolution', False))
    if not re.fullmatch(r'hci[0-9]+', settings.adapter):
        raise ValueError('adapter must be a Linux HCI name, such as hci0')
    if not 1 <= len(settings.name.encode('utf-8')) <= 26 or any(ord(c) < 32 for c in settings.name):
        raise ValueError('name must contain 1–26 UTF-8 bytes without control characters')
    if settings.tablet and not (re.fullmatch(r'(?:bluetooth:)?(?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}', settings.tablet)
            or settings.tablet.startswith('usb:/sys/devices/')):
        raise ValueError('tablet must be empty, a Bluetooth address, or a USB physical identity')
    return settings
