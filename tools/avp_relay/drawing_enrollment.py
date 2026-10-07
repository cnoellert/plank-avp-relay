# SPDX-License-Identifier: GPL-3.0-or-later
"""Authenticated Setup delegates one Client enrollment to the raw daemon.

The public status socket stays read-only. This distinct mutation endpoint
accepts uid 0, and this client verifies the explicitly resolved raw account.
No tablet access, capture lease, private-key read or service reconfiguration.
"""
import json
import pwd
import re
import socket
import struct
import time

NAME = '\0plank-tablet-drawing-enrollment-v1'
PREFIX = b'PLEN\x01'
FIELDS = {'version', 'id', 'op', 'action', 'requestID', 'clientIdentity', 'drawingIdentity'}


def unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('Duplicate registration field.')
        result[key] = value
    return result


def decode(data):
    if not isinstance(data, bytes) or len(data) > 1024:
        raise ValueError('Invalid registration request.')
    command = json.loads(data, object_pairs_hook=unique)
    if not isinstance(command, dict) or set(command) != FIELDS or \
            type(command['version']) is not int or command['version'] != 1 or \
            type(command['id']) is not int or not 1 <= command['id'] <= 1000000 or \
            command['op'] != 'drawing-enrollment' or command['action'] not in ('prepare', 'cancel'):
        raise ValueError('Invalid registration request.')
    for name, size in (('requestID', 32), ('clientIdentity', 64), ('drawingIdentity', 64)):
        value = command[name]
        if not isinstance(value, str) or not re.fullmatch('[0-9a-f]{%d}' % size, value) or not int(value, 16):
            raise ValueError('Invalid registration identity or request id.')
    if command['clientIdentity'] == command['drawingIdentity']:
        raise ValueError('Client and drawing identities must be distinct.')
    return command


def exchange(command):
    expected_uid = pwd.getpwnam('plank-relay').pw_uid
    request_id = bytes.fromhex(command['requestID'])
    request = PREFIX + bytes([1 if command['action'] == 'prepare' else 2]) + request_id + \
        bytes.fromhex(command['clientIdentity']) + bytes.fromhex(command['drawingIdentity'])
    deadline = time.monotonic() + 0.75
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        def remaining():
            left = deadline - time.monotonic()
            if left <= 0:
                raise TimeoutError('Drawing registration service did not reply in time.')
            connection.settimeout(left)
        remaining()
        connection.connect(NAME)
        peer = connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize('3i'))
        _, uid, _ = struct.unpack('3i', peer)
        if uid != expected_uid:
            raise ValueError('Drawing registration service could not be verified.')
        remaining()
        connection.sendall(request)
        reply = bytearray()
        while len(reply) < 22:
            remaining()
            chunk = connection.recv(22 - len(reply))
            if not chunk:
                raise ValueError('Drawing registration service closed without approval.')
            reply.extend(chunk)
    if reply[:5] != PREFIX or reply[6:] != request_id:
        raise ValueError('Invalid drawing registration response.')
    if reply[5]:
        raise ValueError({1: 'Invalid drawing registration request.',
                          2: 'Drawing identity changed; nothing was approved.',
                          3: 'Registration expired, canceled or was already used.',
                          4: 'Drawing registration is busy; try again.'}.get(reply[5],
                          'Drawing registration was refused.'))
    return {'requestID': command['requestID'], 'state': 'pending' if command['action'] == 'prepare' else 'canceled',
            'expiresIn': 120 if command['action'] == 'prepare' else 0}


def handle(data, peer, owner, authenticated, enrolling, send=exchange):
    response = {'version': 1, 'id': 0, 'ok': False}
    try:
        command = decode(data)
        response['id'] = command['id']
        if not authenticated or enrolling or owner is None or peer != owner:
            raise ValueError('An authorized Setup connection is required to register PLANK.')
        response.update(send(command), ok=True)
    except (OSError, KeyError, ValueError, RecursionError) as error:
        response['error'] = str(error)[:256]
    return json.dumps(response, separators=(',', ':')).encode()
