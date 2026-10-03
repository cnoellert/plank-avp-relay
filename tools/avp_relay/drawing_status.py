# SPDX-License-Identifier: GPL-3.0-or-later
"""Read the raw drawing service's public listener metadata and publish it.

Contract: `docs/relay-drawing-handoff-contract.md` in `cnoellert/plank-tablet-relay`,
revision `plank-drawing-handoff-v1+r3`. Entry point 1 is validated here (section
7.4), converted into reachable routes (section 9), and re-validated as entry
point 2 (section 7.3) before it is placed in the authenticated status response.

Stdlib only and pure apart from `DrawingStatusClient`, in the style of
`network_routes.py`, so the validator and the conversion run on macOS. The
address inventory is injected in tests; production reuses
`network_routes.local_addresses({AF_INET})` and writes no new address-collection
code.

Nothing here reads a private key, the paired-client allowlist, a tablet sample,
capture state or a pairing window, and nothing here mutates anything.
"""
import json
import os
import pwd
import socket
import stat
import struct
import time

from .network_routes import local_addresses, usable_addresses

# Contract section 8.2. The capture interlock name is a different name and is
# never touched.
ABSTRACT_NAME = 'plank-tablet-drawing-status-v1'
SERVICE_ACCOUNT = 'plank-relay'
STATE_DIRECTORY = '/var/lib/plank-tablet-relay'
REQUEST = b'{"op":"drawing-status","version":1}\n'
REQUEST_MAX = 256
RESPONSE_MAX = 4096
CLIENT_BUDGET = 0.75

PROTOCOL = {'name': 'pltr-raw-hid', 'version': 1, 'rawHID': 1, 'linkType': 2}

# Contract section 11. The three outcomes and their exact reason sets.
HANDOFF_READY = 'handoffReady'
DRAWING_UNAVAILABLE = 'drawingUnavailable'
HANDOFF_UNSUPPORTED = 'handoffUnsupported'
UNAVAILABLE_REASONS = frozenset({
    'service.absent', 'service.busy', 'service.invalid', 'service.peerUnverified',
    'listener.loopbackOnly', 'listener.noUsableAddress', 'response.tooLarge'})
UNSUPPORTED_REASONS = frozenset({
    'relay.tooOld', 'authorization.required', 'authorization.failed',
    'protocol.error'})

ENVELOPE_MEMBERS = {'version', 'ok', 'supported', 'state', 'listener', 'reason'}
LISTENER_MEMBERS = {'drawingIdentity', 'drawingProtocol', 'boundAddress', 'boundPort'}
WRAPPER_MEMBERS = {'supported', 'state', 'descriptor', 'reason'}
DESCRIPTOR_MEMBERS = {'version', 'drawingIdentity', 'drawingProtocol', 'routes'}
ROUTE_REQUIRED = {'address', 'port'}
ROUTE_OPTIONAL = {'interface', 'kind'}
ROUTE_KINDS = {'wired', 'wireless', 'other'}
INTERFACE_CHARACTERS = frozenset(
    'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-')


# --- raw-byte duplicate member detection (contract section 7.2) --------------
# json.loads collapses duplicate member names before anything can observe them,
# so the scan runs over the original bytes, at every depth, comparing names
# after unescaping.

class _Scan:
    def __init__(self, text):
        self.text = text
        self.at = 0
        self.duplicate = False

    def space(self):
        while self.at < len(self.text) and self.text[self.at] in ' \t\r\n':
            self.at += 1

    def string(self):
        if self.text[self.at] != '"':
            raise ValueError('Expected a JSON string.')
        self.at += 1
        out = []
        while True:
            if self.at >= len(self.text):
                raise ValueError('Unterminated JSON string.')
            character = self.text[self.at]
            if character == '"':
                self.at += 1
                return ''.join(out)
            if character != '\\':
                out.append(character)
                self.at += 1
                continue
            self.at += 1
            if self.at >= len(self.text):
                raise ValueError('Unterminated JSON escape.')
            escape = self.text[self.at]
            self.at += 1
            if escape in '"\\/':
                out.append(escape)
            elif escape in 'bfnrt':
                out.append({'b': '\b', 'f': '\f', 'n': '\n', 'r': '\r', 't': '\t'}[escape])
            elif escape == 'u':
                point = self.text[self.at:self.at + 4]
                if len(point) != 4:
                    raise ValueError('Truncated JSON escape.')
                out.append(chr(int(point, 16)))
                self.at += 4
            else:
                raise ValueError('Unknown JSON escape.')

    def obj(self):
        self.at += 1
        names = set()
        self.space()
        if self.at < len(self.text) and self.text[self.at] == '}':
            self.at += 1
            return
        while True:
            self.space()
            name = self.string()
            if name in names:
                self.duplicate = True
            names.add(name)
            self.space()
            if self.at >= len(self.text) or self.text[self.at] != ':':
                raise ValueError('Expected a JSON member separator.')
            self.at += 1
            self.value()
            self.space()
            if self.at >= len(self.text):
                raise ValueError('Unterminated JSON object.')
            if self.text[self.at] == ',':
                self.at += 1
                continue
            if self.text[self.at] == '}':
                self.at += 1
                return
            raise ValueError('Expected a JSON object separator.')

    def array(self):
        self.at += 1
        self.space()
        if self.at < len(self.text) and self.text[self.at] == ']':
            self.at += 1
            return
        while True:
            self.value()
            self.space()
            if self.at >= len(self.text):
                raise ValueError('Unterminated JSON array.')
            if self.text[self.at] == ',':
                self.at += 1
                continue
            if self.text[self.at] == ']':
                self.at += 1
                return
            raise ValueError('Expected a JSON array separator.')

    def value(self):
        self.space()
        if self.at >= len(self.text):
            raise ValueError('Truncated JSON value.')
        character = self.text[self.at]
        if character == '{':
            self.obj()
        elif character == '[':
            self.array()
        elif character == '"':
            self.string()
        else:
            start = self.at
            while self.at < len(self.text) and self.text[self.at] not in ',}] \t\r\n':
                self.at += 1
            if self.at == start:
                raise ValueError('Empty JSON value.')


def duplicate_member(text):
    """True when any object in `text` repeats a member name, at any depth."""
    scan = _Scan(text)
    scan.value()
    scan.space()
    if scan.at != len(scan.text):
        raise ValueError('Trailing JSON content.')
    return scan.duplicate


# --- deterministic literal pre-checks (contract section 7.4a) ---------------

def _dotted_quad(text):
    """('ipv4', bytes) for a canonical dotted quad, or a bare failure kind."""
    groups = text.split('.')
    if len(groups) != 4:
        return 'notLiteral'
    octets = []
    for group in groups:
        if not 1 <= len(group) <= 3 or not group.isdigit():
            return 'notLiteral'
        value = int(group)
        if value > 255:
            return 'notLiteral'
        octets.append(value)
    for group in groups:
        if len(group) > 1 and group[0] == '0':
            return 'nonCanonical'
    return 'ipv4', bytes(octets)


def _literal(text):
    """Classifies a literal exactly as contract section 7.4a specifies.

    Returns ('ipv4', 4 bytes), ('ipv6', 16 bytes), or one of the bare strings
    'notLiteral', 'nonCanonical', 'mapped'. None of it depends on how a platform
    renders an address.
    """
    if text and all(character in '0123456789.' for character in text):
        return _dotted_quad(text)
    if ':' not in text:
        return 'notLiteral'
    if any('A' <= character <= 'Z' for character in text):
        return 'nonCanonical'
    try:
        packed = socket.inet_pton(socket.AF_INET6, text)
    except (OSError, ValueError, UnicodeEncodeError):
        return 'notLiteral'
    if packed[:10] == b'\x00' * 10 and packed[10:12] == b'\xff\xff':
        return 'mapped'
    if packed[:12] == b'\x00' * 12 and int.from_bytes(packed[12:], 'big') > 1:
        return 'mapped'
    try:
        rendered = socket.inet_ntop(socket.AF_INET6, packed)
    except (OSError, ValueError):
        return 'notLiteral'
    if rendered != text:
        return 'nonCanonical'
    return 'ipv6', packed


def check_bound_address(value):
    """Contract section 7.5. Returns a reason identifier, or None when accepted.

    Wildcard, loopback and 169.254/16 are accepted: they are honest binds and
    they are refused later, at conversion, with a specific reason.
    """
    if value is None:
        return 'metadata.boundAddress.missing'
    if not isinstance(value, str):
        return 'metadata.boundAddress.type'
    if len(value.encode()) > 15:
        return 'metadata.boundAddress.tooLong'
    result = _literal(value)
    if isinstance(result, str):
        return 'metadata.boundAddress.' + result
    family, packed = result
    if family == 'ipv6':
        return 'metadata.boundAddress.familyUnsupported'
    if packed[0] == 0:
        return None if packed == b'\x00\x00\x00\x00' else 'metadata.boundAddress.invalid'
    if packed[0] >= 224:
        return 'metadata.boundAddress.invalid'
    return None


def check_route_address(value):
    """Contract section 7.6. Returns a reason identifier, or None when accepted."""
    if value is None:
        return 'route.address.missing'
    if not isinstance(value, str):
        return 'route.address.type'
    if len(value.encode()) > 64:
        return 'route.address.tooLong'
    if '%' in value:
        return 'route.address.scoped'
    result = _literal(value)
    if isinstance(result, str):
        return 'route.address.' + result
    family, packed = result
    if family == 'ipv4':
        if packed[0] == 0:
            return 'route.address.unspecified'
        if packed[0] == 127:
            return 'route.address.loopback'
        if packed[0] == 169 and packed[1] == 254:
            return 'route.address.linkLocal'
        if 224 <= packed[0] < 240:
            return 'route.address.multicast'
        if packed[0] >= 240:
            return 'route.address.broadcast'
        return None
    if packed == b'\x00' * 16:
        return 'route.address.unspecified'
    if packed == b'\x00' * 15 + b'\x01':
        return 'route.address.loopback'
    if packed[0] == 0xfe and packed[1] & 0xc0 == 0x80:
        return 'route.address.linkLocal'
    if packed[0] == 0xff:
        return 'route.address.multicast'
    return 'route.address.familyUnsupported'


# --- shared field checks (contract sections 5.1, 5.2, 5.3) ------------------

def _check_identity(value, prefix='drawingIdentity'):
    if not isinstance(value, str):
        return prefix + '.type'
    if len(value) != 64 or any(character not in '0123456789abcdef' for character in value):
        return prefix + '.invalid'
    return None


def _check_protocol(value):
    if not isinstance(value, dict):
        return 'drawingProtocol.type'
    for member in ('name', 'version', 'rawHID', 'linkType'):
        if member not in value:
            return 'drawingProtocol.' + member + '.missing'
    if set(value) - set(PROTOCOL):
        return 'drawingProtocol.unknownMember'
    if value['name'] != PROTOCOL['name']:
        return 'drawingProtocol.name'
    for member in ('version', 'rawHID', 'linkType'):
        if not _is_integer(value[member]) or value[member] != PROTOCOL[member]:
            return 'drawingProtocol.' + member
    return None


def _is_integer(value):
    return type(value) is int and not isinstance(value, bool)


def _check_route(route):
    if not isinstance(route, dict):
        return 'route.type'
    for member in ROUTE_OPTIONAL:
        if member in route and route[member] is None:
            return 'route.nullMember'
    if set(route) - (ROUTE_REQUIRED | ROUTE_OPTIONAL):
        return 'route.unknownMember'
    if 'address' not in route:
        return 'route.address.missing'
    reason = check_route_address(route['address'])
    if reason:
        return reason
    if 'port' not in route:
        return 'route.port.missing'
    if not _is_integer(route['port']) or not 1 <= route['port'] <= 65535:
        return 'route.port'
    if 'interface' in route:
        name = route['interface']
        if (not isinstance(name, str) or not 1 <= len(name.encode()) <= 15 or
                any(character not in INTERFACE_CHARACTERS for character in name)):
            return 'route.interface'
    if 'kind' in route and route['kind'] not in ROUTE_KINDS:
        return 'route.kind'
    return None


def check_routes(routes):
    """Contract section 7.6. Returns (surviving routes, reason)."""
    if not isinstance(routes, list):
        return None, 'routes.type'
    if not 1 <= len(routes) <= 8:
        return None, 'routes.count'
    for route in routes:
        reason = _check_route(route)
        if reason:
            return None, reason
    surviving, seen = [], set()
    for route in routes:
        key = (route['address'], route['port'])
        if key in seen:
            continue
        seen.add(key)
        surviving.append(route)
    if not surviving:
        return None, 'routes.count'
    return surviving, None


# --- entry point 1: local listener metadata (contract section 7.4) ----------

def validate_local_metadata(raw):
    """Returns (listener, declared reason, failure).

    Exactly one of the three is not None: a validated `listener` object, the
    reason a well-formed response declared with `state: unavailable`, or the
    identifier of the first ordered check that failed.
    """
    if not isinstance(raw, (bytes, bytearray)):
        return None, None, 'payload.length'
    if not 2 <= len(raw) <= RESPONSE_MAX:
        return None, None, 'payload.length'
    try:
        text = bytes(raw).decode()
    except UnicodeDecodeError:
        return None, None, 'payload.utf8'
    stripped = text[:-1] if text.endswith('\n') else text
    try:
        body = json.loads(stripped)
    except ValueError:
        return None, None, 'payload.json'
    if not isinstance(body, dict):
        return None, None, 'payload.notObject'
    try:
        if duplicate_member(stripped):
            return None, None, 'payload.duplicateMember'
    except ValueError:
        return None, None, 'payload.json'
    # Version is privileged: presence, then type, then value, all before the
    # member-set check.
    if 'version' not in body:
        return None, None, 'metadata.envelope.version.missing'
    if not _is_integer(body['version']):
        return None, None, 'metadata.envelope.version.type'
    if body['version'] != 1:
        return None, None, 'metadata.envelope.version.unsupported'
    if set(body) - ENVELOPE_MEMBERS:
        return None, None, 'metadata.unknownMember'
    if 'ok' not in body:
        return None, None, 'metadata.envelope.ok.missing'
    if body['ok'] is not True:
        return None, None, 'metadata.envelope.ok'
    if 'supported' not in body:
        return None, None, 'metadata.envelope.supported.missing'
    if not isinstance(body['supported'], bool):
        return None, None, 'metadata.envelope.supported.type'
    if 'state' not in body:
        return None, None, 'metadata.envelope.state.missing'
    if body['state'] not in ('ready', 'unavailable'):
        return None, None, 'metadata.envelope.state'
    ready = body['state'] == 'ready'
    if ready and 'listener' not in body:
        return None, None, 'metadata.envelope.listener.missing'
    if not ready and 'listener' in body:
        return None, None, 'metadata.envelope.listener.unexpected'
    if not ready and 'reason' not in body:
        return None, None, 'metadata.envelope.reason.missing'
    if ready and 'reason' in body:
        return None, None, 'metadata.envelope.reason.unexpected'
    if not ready:
        reason = body['reason']
        if (not isinstance(reason, str) or not 1 <= len(reason.encode()) <= 64 or
                any(not (character.isascii() and (character.isalpha() or character == '.'))
                    for character in reason)):
            return None, None, 'metadata.envelope.reason'
        return None, reason, None
    listener = body['listener']
    if not isinstance(listener, dict):
        return None, None, 'metadata.envelope.listener.type'
    if set(listener) - LISTENER_MEMBERS:
        return None, None, 'metadata.unknownMember'
    if 'drawingIdentity' not in listener:
        return None, None, 'drawingIdentity.missing'
    if 'drawingProtocol' not in listener:
        return None, None, 'drawingProtocol.missing'
    if 'boundAddress' not in listener:
        return None, None, 'metadata.boundAddress.missing'
    if 'boundPort' not in listener:
        return None, None, 'metadata.boundPort.missing'
    reason = _check_identity(listener['drawingIdentity'])
    if reason:
        return None, None, reason
    reason = _check_protocol(listener['drawingProtocol'])
    if reason:
        return None, None, reason
    reason = check_bound_address(listener['boundAddress'])
    if reason:
        return None, None, reason
    if not _is_integer(listener['boundPort']) or not 1 <= listener['boundPort'] <= 65535:
        return None, None, 'metadata.boundPort'
    return listener, None, None


# --- entry point 2: managed status descriptor (contract section 7.3) --------

def validate_status(raw):
    """Returns (descriptor, declared reason, failure).

    `raw` is the original `drawingHandoff` bytes. The duplicate scan runs over
    them, because a tolerant envelope decode collapses duplicates before
    anything can observe them.
    """
    if not isinstance(raw, (bytes, bytearray)):
        return None, None, 'payload.notObject'
    try:
        text = bytes(raw).decode()
    except UnicodeDecodeError:
        return None, None, 'payload.utf8'
    try:
        body = json.loads(text)
    except ValueError:
        return None, None, 'payload.json'
    if not isinstance(body, dict):
        return None, None, 'payload.notObject'
    try:
        if duplicate_member(text):
            return None, None, 'payload.duplicateMember'
    except ValueError:
        return None, None, 'payload.json'
    if set(body) - WRAPPER_MEMBERS:
        return None, None, 'status.unknownMember'
    if 'supported' not in body:
        return None, None, 'status.supported.missing'
    if not isinstance(body['supported'], bool):
        return None, None, 'status.supported.type'
    if 'state' not in body:
        return None, None, 'status.state.missing'
    if body['state'] not in ('ready', 'unavailable'):
        return None, None, 'status.state'
    ready = body['state'] == 'ready'
    if ready and 'descriptor' not in body:
        return None, None, 'status.descriptor.missing'
    if not ready and 'descriptor' in body:
        return None, None, 'status.descriptor.unexpected'
    if not ready and 'reason' not in body:
        return None, None, 'status.reason.missing'
    if ready and 'reason' in body:
        return None, None, 'status.reason.unexpected'
    if not ready:
        if body['reason'] not in UNAVAILABLE_REASONS | UNSUPPORTED_REASONS:
            return None, None, 'status.reason'
        return None, body['reason'], None
    descriptor = body['descriptor']
    if not isinstance(descriptor, dict):
        return None, None, 'status.descriptor.type'
    if 'version' not in descriptor:
        return None, None, 'version.missing'
    if not _is_integer(descriptor['version']):
        return None, None, 'version.type'
    if descriptor['version'] != 1:
        return None, None, 'version.unsupported'
    if set(descriptor) - DESCRIPTOR_MEMBERS:
        return None, None, 'status.unknownMember'
    if 'drawingIdentity' not in descriptor:
        return None, None, 'drawingIdentity.missing'
    if 'drawingProtocol' not in descriptor:
        return None, None, 'drawingProtocol.missing'
    if 'routes' not in descriptor:
        return None, None, 'routes.missing'
    reason = _check_identity(descriptor['drawingIdentity'])
    if reason:
        return None, None, reason
    reason = _check_protocol(descriptor['drawingProtocol'])
    if reason:
        return None, None, reason
    routes, reason = check_routes(descriptor['routes'])
    if reason:
        return None, None, reason
    return descriptor, None, None


# --- conversion (contract section 9) ---------------------------------------

def convert(listener, inventory=None, families=None):
    """Listener metadata in, validated reachable routes or a reason out.

    Wildcard and loopback never escape into the managed descriptor. `inventory`
    is the host's address list; production leaves it None, which reuses
    `network_routes.local_addresses`.
    """
    families = {socket.AF_INET} if families is None else set(families)
    address, port = listener['boundAddress'], listener['boundPort']
    result = _literal(address)
    if isinstance(result, str) or result[0] != 'ipv4':
        return None, 'listener.noUsableAddress'
    packed = result[1]
    if packed[0] == 127:
        # The unconfigured default: a clear unavailable state, not an error. A
        # host that happens to have usable addresses does not rescue it.
        return None, 'listener.loopbackOnly'
    if address == '0.0.0.0':
        candidates = (local_addresses(families) if inventory is None
                      else usable_addresses(inventory, families))
    else:
        if check_route_address(address) is not None:
            return None, 'listener.noUsableAddress'
        candidates = [address]
    routes = [{'address': candidate, 'port': port} for candidate in candidates
              if check_route_address(candidate) is None]
    routes, reason = check_routes(routes[:8]) if routes else (None, 'routes.count')
    if reason:
        return None, 'listener.noUsableAddress'
    return routes, None


def build_descriptor(listener, routes):
    return {'version': 1, 'drawingIdentity': listener['drawingIdentity'],
            'drawingProtocol': dict(listener['drawingProtocol']), 'routes': routes}


def unavailable(reason):
    if reason not in UNAVAILABLE_REASONS | UNSUPPORTED_REASONS:
        reason = 'service.invalid'
    return {'supported': True, 'state': 'unavailable', 'reason': reason}


def outcome(handoff):
    """The contract section 11 name for a status wrapper."""
    if handoff is None:
        return HANDOFF_UNSUPPORTED
    if handoff.get('state') == 'ready':
        return HANDOFF_READY
    if handoff.get('reason') in UNSUPPORTED_REASONS:
        return HANDOFF_UNSUPPORTED
    return DRAWING_UNAVAILABLE


# --- the local client (contract sections 8.3, 8.3a) ------------------------

def resolve_service_uid(account=SERVICE_ACCOUNT, state_directory=STATE_DIRECTORY):
    """Resolves the raw drawing service account **by name**, failing closed.

    Returns (uid, None) or (None, reason). The account name is the authority: no
    compiled-in uid, no assumption of 0, and no filesystem object as the primary
    source. `StateDirectory` ownership is corroboration only — a symlink or a
    disagreement is a refusal, never a substitution.
    """
    try:
        uid = pwd.getpwnam(account).pw_uid
    except KeyError:
        uid = None
    except Exception:
        return None, 'service.peerUnverified'
    try:
        info = os.lstat(state_directory)
    except (FileNotFoundError, NotADirectoryError):
        info = None
    except OSError:
        return None, 'service.peerUnverified'
    if uid is None:
        # A cleanly absent installation: neither the account nor the directory.
        return None, 'service.absent' if info is None else 'service.peerUnverified'
    if info is None:
        return None, 'service.absent'
    if stat.S_ISLNK(info.st_mode):
        return None, 'service.peerUnverified'
    if info.st_uid != uid:
        return None, 'service.peerUnverified'
    return uid, None


class DrawingStatusClient:
    """Bounded, root-only, read-only local IPC, the idiom of local_service.py.

    One connect attempt per status request, no retry inside or across requests,
    no timer of its own.
    """

    def __init__(self, name=ABSTRACT_NAME, account=SERVICE_ACCOUNT,
                 state_directory=STATE_DIRECTORY):
        self.name, self.account, self.state_directory = name, account, state_directory

    def resolve(self):
        return resolve_service_uid(self.account, self.state_directory)

    def read(self):
        """Returns (response bytes, None) or (None, reason)."""
        uid, reason = self.resolve()
        if reason:
            return None, reason
        option = getattr(socket, 'SO_PEERCRED', 17)
        layout = '3i'
        deadline = time.monotonic() + CLIENT_BUDGET

        def remaining():
            budget = deadline - time.monotonic()
            if budget <= 0:
                raise socket.timeout('Drawing status deadline expired.')
            return budget

        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
                client.settimeout(remaining())
                client.connect('\0' + self.name)
                # Before reading or trusting a single byte, and against the
                # resolved account uid and nothing else.
                peer = struct.unpack(layout, client.getsockopt(
                    socket.SOL_SOCKET, option, struct.calcsize(layout)))[1]
                if peer != uid:
                    return None, 'service.peerUnverified'
                client.settimeout(remaining())
                client.sendall(REQUEST)
                reply = bytearray()
                while not reply.endswith(b'\n'):
                    client.settimeout(remaining())
                    data = client.recv(RESPONSE_MAX + 1 - len(reply))
                    # Do not accept a final fragment that arrived after the
                    # exchange deadline, even if the socket returned it.
                    remaining()
                    if not data or len(reply) + len(data) > RESPONSE_MAX:
                        return None, 'service.invalid'
                    reply.extend(data)
                return bytes(reply), None
        except (FileNotFoundError, ConnectionRefusedError):
            return None, 'service.absent'
        except OSError:
            # Restarting, slow, or all four handler slots busy. Transient, and
            # never reported as absent or unsupported.
            return None, 'service.busy'


def read_handoff(reader=None, inventory=None, families=None):
    """The optional `drawingHandoff` member of the authenticated status response.

    Total: every local failure becomes an explicit unavailable state. Nothing
    here disconnects the headset, acquires capture, opens an input node, opens a
    pairing window or opens enrollment.
    """
    if reader is None:
        reader = DrawingStatusClient().read
    try:
        raw, reason = reader()
    except OSError:
        return unavailable('service.busy')
    except Exception:
        return unavailable('service.invalid')
    if reason:
        return unavailable(reason)
    try:
        return _validated_handoff(raw, inventory, families)
    except Exception:
        # Optional local metadata must not break the authenticated management
        # connection. This includes JSON recursion and escaped lone surrogates
        # that decode but cannot be encoded by a later validation step.
        return unavailable('service.invalid')


def _validated_handoff(raw, inventory, families):
    listener, declared, failure = validate_local_metadata(raw)
    if failure:
        return unavailable('service.invalid')
    if declared is not None:
        return unavailable(declared)
    routes, reason = convert(listener, inventory, families)
    if reason:
        return unavailable(reason)
    wrapper = {'supported': True, 'state': 'ready',
               'descriptor': build_descriptor(listener, routes)}
    # The assembled descriptor must pass entry point 2 before it is placed in
    # the authenticated status. Unvalidated raw-service bytes never travel.
    encoded = json.dumps(wrapper, separators=(',', ':'), ensure_ascii=False).encode()
    if len(encoded) > RESPONSE_MAX:
        return unavailable('response.tooLarge')
    descriptor, _, failure = validate_status(encoded)
    if failure or descriptor is None:
        return unavailable('service.invalid')
    return wrapper
