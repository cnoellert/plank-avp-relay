# SPDX-License-Identifier: GPL-3.0-or-later
"""Bounded Wi-Fi commands and public metadata. Passwords never enter status."""
import hashlib
import json
import re
import uuid

SECURITY = ('open', 'personal', 'sae')
FIELDS = {
    'wifi-status': set(),
    'wifi-list': {'kind', 'offset', 'generation'},
    'wifi-scan': {'requestID'},
    'wifi-enable': {'requestID', 'enabled'},
    'wifi-join': {'requestID', 'network', 'ssid', 'security', 'password'},
    'wifi-connect': {'requestID', 'network'},
    'wifi-forget': {'requestID', 'network'},
}
PAGE_SIZE = 8
MAX_NETWORKS = 256


def unavailable(message='Wi-Fi management is unavailable on this relay.'):
    return dict(supported=False, enabled=False, phase='unavailable', connection='unavailable',
                message=message, network=None, name=None, addresses=[], requestID=None)


def network_id(ssid, security):
    return hashlib.sha256(ssid + b'\x00' + security.encode()).hexdigest()[:32]


def public_network(ssid, security, signal=None, saved=False, hidden=False):
    # Preserve the original bytes for joining; the display name is only a label.
    name = ''.join(c if c.isprintable() else '\ufffd' for c in ssid.decode('utf-8', 'replace'))
    return dict(id=network_id(ssid, security), name=name, secured=security != 'open',
                supported=security in SECURITY, signal=signal, saved=saved, hidden=hidden)


def validate(command):
    op = command.get('op')
    if op not in FIELDS or set(command) != FIELDS[op] | {'op'}:
        raise ValueError('Invalid Wi-Fi command fields.')
    if 'requestID' in command:
        value = command['requestID']
        if not isinstance(value, str) or str(uuid.UUID(value)) != value:
            raise ValueError('Invalid Wi-Fi request identifier.')
    if op == 'wifi-list':
        if command['kind'] not in ('available', 'saved') or type(command['offset']) is not int or not 0 <= command['offset'] < MAX_NETWORKS:
            raise ValueError('Invalid network list page.')
        if not isinstance(command['generation'], str) or len(command['generation']) > 36:
            raise ValueError('Invalid network list generation.')
    if op == 'wifi-enable' and type(command['enabled']) is not bool:
        raise ValueError('Expected a Wi-Fi on/off choice.')
    if 'network' in command and command['network'] is not None:
        if not isinstance(command['network'], str) or not re.fullmatch('[0-9a-f]{32}', command['network']):
            raise ValueError('Invalid saved or discovered network identifier.')
    if op in ('wifi-connect', 'wifi-forget') and command['network'] is None:
        raise ValueError('Select a saved network.')
    if op == 'wifi-join':
        if not isinstance(command['password'], str) or len(command['password'].encode()) > 128 or any(ord(c) < 32 or ord(c) == 127 for c in command['password']):
            raise ValueError('Invalid network password.')
        if command['network'] is None:
            if not isinstance(command['ssid'], str) or not 1 <= len(command['ssid'].encode()) <= 32 or any(ord(c) < 32 for c in command['ssid']):
                raise ValueError('Enter a network name of 1–32 UTF-8 bytes.')
            if command['security'] not in SECURITY:
                raise ValueError('This network requires a different sign-in method.')
        elif command['ssid'] is not None or command['security'] is not None:
            raise ValueError('A discovered network determines its own name and security.')
    return command


def check_password(security, password):
    if security == 'open':
        if password:
            raise ValueError('This network does not use a password.')
    elif security == 'personal':
        if not (8 <= len(password.encode()) <= 63 or re.fullmatch('[0-9a-fA-F]{64}', password)):
            raise ValueError('The network password must contain 8–63 bytes or a 64-digit key.')
    elif security == 'sae':
        if not 1 <= len(password.encode()) <= 63:
            raise ValueError('Enter a password of 1–63 bytes for this network.')
    else:
        raise ValueError('This network requires a sign-in method that is not supported yet.')


def fingerprint(command):
    return hashlib.sha256(json.dumps(command, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
