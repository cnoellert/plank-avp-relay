# SPDX-License-Identifier: GPL-3.0-or-later
"""Strict appliance settings; app commands can change only the saved mode."""
import configparser
from dataclasses import dataclass
import ipaddress
import json
import os
from pathlib import Path
import re
import tempfile

MODES = ('bridge', 'router')
STATE = Path('/var/lib/plank-avp-relay/usb')
CONFIG = Path('/etc/plank-avp-relay/usb-network.conf')


@dataclass(frozen=True)
class GadgetSettings:
    enabled: str = 'auto'
    wired_interface: str = ''
    controller: str = ''
    otg_node: str = ''
    function: str = 'ncm'
    router_address: str = '10.55.0.1/24'


def read_settings(path=CONFIG):
    parser = configparser.ConfigParser(interpolation=None)
    with Path(path).open() as file:
        parser.read_file(file)
    if parser.defaults() or parser.sections() != ['usb-network']:
        raise ValueError('Expected only a [usb-network] section.')
    values = dict(parser['usb-network'])
    if set(values) - set(GadgetSettings.__dataclass_fields__):
        raise ValueError('Unknown USB network setting.')
    result = GadgetSettings(**values)
    if result.enabled not in ('auto', 'true', 'false') or result.function not in ('ncm', 'ecm'):
        raise ValueError('Invalid USB network enable/function setting.')
    if result.wired_interface and not re.fullmatch(r'[a-zA-Z0-9_-]{1,15}', result.wired_interface):
        raise ValueError('Invalid wired interface name.')
    if result.controller and not re.fullmatch(r'[a-zA-Z0-9_.:-]{1,100}', result.controller):
        raise ValueError('Invalid USB controller name.')
    if result.otg_node and not re.fullmatch(r'/[a-zA-Z0-9_/@.,+-]{1,200}', result.otg_node):
        raise ValueError('Invalid OTG device-tree node.')
    address = ipaddress.IPv4Interface(result.router_address)
    if not 8 <= address.network.prefixlen <= 30 or address.ip in (
            address.network.network_address, address.network.broadcast_address):
        raise ValueError('Router address must be a usable IPv4 host address with prefix /8 through /30.')
    if not any(address.network.subnet_of(ipaddress.IPv4Network(network))
               for network in ('10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16')):
        raise ValueError('Use a private, non-link-local router subnet.')
    return result


def atomic_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, temporary = tempfile.mkstemp(prefix='.' + path.name, dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as output:
            json.dump(value, output, separators=(',', ':'))
            output.write('\n')
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
