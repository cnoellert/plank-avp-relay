# SPDX-License-Identifier: GPL-3.0-or-later
"""Bounded root-local transport to the USB network appliance service."""
import json
import socket

SOCKET = '/run/plank-tablet-relay-gadget/control.sock'


class GadgetBusy(RuntimeError):
    pass


def unavailable(message='USB networking is unavailable on this relay.'):
    return dict(supported=False, mode='bridge', targetMode='bridge', phase='unavailable',
                message=message, ethernet='unknown', usb='unavailable', addresses=[],
                requestID=None)


class GadgetClient:
    def request(self, command):
        payload = json.dumps(command, separators=(',', ':')).encode() + b'\n'
        if len(payload) > 1024:
            raise ValueError('Network command is too large.')
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
                client.settimeout(0.75)
                client.connect(SOCKET)
                client.sendall(payload)
                reply = bytearray()
                while not reply.endswith(b'\n'):
                    data = client.recv(4097 - len(reply))
                    if not data or len(reply) + len(data) > 4096:
                        raise ValueError('Invalid USB network service response.')
                    reply.extend(data)
                result = json.loads(reply)
                if not isinstance(result, dict):
                    raise ValueError('Invalid USB network service response.')
                return result
        except (FileNotFoundError, ConnectionRefusedError):
            if command.get('op') == 'network-status':
                return unavailable()
            raise ValueError('USB network service is unavailable. Refresh its status.') from None
        except OSError:
            # An apply may temporarily block the helper. Never convert that to
            # unsupported or assume a lost reply means the mutation failed.
            raise GadgetBusy('USB network service is busy; reconnect to check its status.') from None
