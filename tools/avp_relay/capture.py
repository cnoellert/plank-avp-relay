# SPDX-License-Identifier: GPL-3.0-or-later
"""Read-only, report-preserving evdev input grouped by physical Wacom ancestry."""
from collections import deque
import errno
import fcntl
import hashlib
import os
from pathlib import Path
import selectors
import struct
import time

EVENT = struct.Struct('@llHHi')
SAMPLE = struct.Struct('<BBHIQ12iIIIHH')
assert SAMPLE.size == 80


def bitmap(path):
    words = path.read_text().split()
    width = struct.calcsize('L') * 8
    return sum(int(word, 16) << (index * width)
               for index, word in enumerate(reversed(words)))


def physical_identity(device):
    bus = int((device / 'id/bustype').read_text(), 16)
    vendor = int((device / 'id/vendor').read_text(), 16)
    if vendor != 0x056a or bus not in (3, 5):
        return None
    ancestors = device.resolve().parents
    if bus == 5:
        for parent in ancestors:
            try:
                fields = dict(line.split('=', 1) for line in
                              (parent / 'uevent').read_text().splitlines() if '=' in line)
            except OSError:
                continue
            if 'HID_ID' in fields and fields.get('HID_UNIQ'):
                # Scope to the local controller as well as the remote identity.
                return ('bluetooth:' + fields['HID_UNIQ'].lower(),
                        fields.get('HID_PHYS', ''), bus)
    else:
        for parent in ancestors:
            if (parent / 'idVendor').exists() and (parent / 'idProduct').exists():
                return ('usb:' + str(parent), '', bus)
    return None


def candidates(root=Path('/sys/class/input')):
    groups = {}
    for node in sorted(root.glob('event*')):
        device = node / 'device'
        try:
            identity = physical_identity(device)
            if not identity:
                continue
            keys = bitmap(device / 'capabilities/key')
            axes = bitmap(device / 'capabilities/abs')
            pad = [code for code in (102, 172, *range(0x100, 0x110)) if keys & (1 << code)]
            pen = bool(keys & (1 << 0x140)) and all(axes & (1 << code) for code in (0, 1, 24))
            kind = 'pen' if pen else 'pad' if pad else 'touch'
            groups.setdefault(identity, []).append((node.name, kind, pad))
        except (OSError, ValueError):
            continue
    return {identity: nodes for identity, nodes in groups.items()
            if sum(kind == 'pen' for _, kind, _ in nodes) == 1 and
               sum(kind == 'pad' for _, kind, _ in nodes) <= 1}


def usb_identifier(identity):
    return 'usb:' + hashlib.sha256(identity[0].encode()).hexdigest()[:16]


def usb_details(identity, nodes, root=Path('/sys/class/input')):
    parent = Path(identity[0][4:])
    def read(path, limit):
        try:
            return path.read_text().strip().encode('utf-8')[:limit].decode('utf-8', errors='ignore')
        except OSError:
            return ''
    pen = next(name for name, kind, _ in nodes if kind == 'pen')
    name = read(root / pen / 'device/name', 48).removesuffix(' Pen') or 'Wacom tablet'
    return dict(id=usb_identifier(identity), name=name, serial=read(parent / 'serial', 64) or None,
                port=parent.name[:40])


class Capture:
    def __init__(self, selected=None, on_button=lambda code, value: None, fixed=False):
        self.selected = selected.lower() if selected else None
        self.fixed = fixed
        self.usb_selection = None
        self.usb_tablets = []
        self.identity = None
        self.on_button = on_button
        self.selector = selectors.DefaultSelector()
        self.nodes = {}
        self.axes = {}
        self.ranges = {}
        self.keys = set()
        self.pad_mask = 0
        self.contacts = {}
        self.slot = 0
        self.generation = self.reports = self.dropped = self.sequence = 0
        self.last_scan = 0
        self.dirty = True
        self.frames = {}
        self.pending = deque()
        self.observing = False

    @property
    def attached(self):
        return bool(self.nodes)

    def close_nodes(self):
        for fd in self.nodes:
            self.selector.unregister(fd)
            os.close(fd)
        self.nodes.clear()
        self.frames.clear()
        self.axes.clear()
        self.ranges.clear()
        self.keys.clear()
        self.contacts.clear()
        self.slot = 0
        self.pad_mask = 0
        self.dirty = True

    def choose(self, found):
        if not self.fixed:
            usb = {key: nodes for key, nodes in found.items() if key[2] == 3}
            if usb:
                chosen = next((key for key in usb if usb_identifier(key) == self.usb_selection), None)
                if chosen is None and self.identity in usb:
                    chosen = self.identity
                return {chosen: usb[chosen]} if chosen else usb
        if self.identity is not None and self.identity[2] == 5:
            return {key: nodes for key, nodes in found.items() if key == self.identity}
        if self.selected:
            return {key: nodes for key, nodes in found.items()
                    if key[0].lower() in (self.selected, 'bluetooth:' + self.selected)}
        return {key: nodes for key, nodes in found.items() if key[2] != 3 or not self.fixed}

    def discover(self):
        if time.monotonic() - self.last_scan < 0.5:
            return
        self.last_scan = time.monotonic()
        found = candidates()
        self.usb_tablets = [usb_details(key, nodes) for key, nodes in found.items() if key[2] == 3][:8]
        found = self.choose(found)
        if self.nodes and self.identity in found and len(found) == 1:
            return
        if self.nodes:
            self.close_nodes()
        if len(found) > 1:
            # Remain available so an administrator can select a tablet without
            # losing the headset's saved trust or restarting on every scan.
            if not getattr(self, 'ambiguous', False):
                print('Multiple qualifying tablets; configure tablet selection. Input remains offline.', flush=True)
            self.ambiguous = True
            return
        self.ambiguous = False
        if not found:
            return
        identity, nodes = next(iter(found.items()))
        try:
            for name, kind, pad in nodes:
                fd = os.open('/dev/input/' + name, os.O_RDONLY | os.O_NONBLOCK | os.O_CLOEXEC)
                self.nodes[fd] = (kind, pad)
                self.selector.register(fd, selectors.EVENT_READ)
                # Use the same clock as the relay's heartbeat timestamps.
                fcntl.ioctl(fd, 0x400445a0, struct.pack('=i', time.CLOCK_MONOTONIC))  # EVIOCSCLOCKID
                held = bytearray(96)
                fcntl.ioctl(fd, 0x80000000 | (len(held) << 16) | (ord('E') << 8) | 0x18, held)
                pressed = {code for code in range(len(held)*8) if held[code//8] & (1 << (code%8))}
                if kind == 'pen':
                    self.keys = pressed
                    for axis in (0, 1, 24, 25, 26, 27):
                        value = bytearray(24)
                        try:
                            fcntl.ioctl(fd, 0x80000000 | (24 << 16) | (ord('E') << 8) | (0x40 + axis), value)
                        except OSError as error:
                            if axis in (0, 1, 24):
                                raise
                            if error.errno != errno.EINVAL:
                                raise
                            continue
                        current, minimum, maximum, _, _, _ = struct.unpack('=6i', value)
                        self.axes[axis] = current
                        self.ranges[axis] = (minimum, maximum)
                elif kind == 'pad':
                    self.pad_mask = sum(1 << index for index, code in enumerate(pad) if code in pressed)
        except OSError as error:
            self.close_nodes()
            if error.errno in (errno.ENOENT, errno.ENODEV):
                return
            raise
        self.identity = identity
        self.generation += 1
        self.dirty = True
        print(('USB' if identity[2] == 3 else 'Bluetooth') + ' tablet input attached; pen input available.', flush=True)

    def usb_status(self):
        active = usb_identifier(self.identity) if self.attached and self.identity[2] == 3 else None
        return [dict(tablet, active=tablet['id'] == active) for tablet in self.usb_tablets]

    def use_usb(self, target):
        self.last_scan = 0
        self.discover()
        if self.fixed or not any(tablet['id'] == target for tablet in self.usb_tablets):
            raise ValueError('Select a connected USB tablet from this relay’s list.')
        self.usb_selection = target
        self.last_scan = 0
        self.discover()
        if not any(tablet['id'] == target and tablet['active'] for tablet in self.usb_status()):
            raise ValueError('The USB tablet is no longer ready. Check its cable and retry.')

    def poll(self):
        self.discover()
        for key, _ in self.selector.select(0):
            try:
                data = os.read(key.fd, EVENT.size * 256)
                if not data or len(data) % EVENT.size:
                    raise OSError(errno.ENODEV, 'Input stream ended')
            except BlockingIOError:
                continue
            except OSError as error:
                if error.errno != errno.ENODEV:
                    raise
                self.close_nodes()
                print('Tablet offline; saved enrollment is retained.', flush=True)
                break
            kind, pad = self.nodes[key.fd]
            frame = self.frames.setdefault(key.fd, [])
            for seconds, micros, event, code, value in EVENT.iter_unpack(data):
                if event == 0 and code == 3:
                    self.dropped += 1
                    self.close_nodes()
                    return  # Reopen and query current state after SYN_DROPPED.
                if event == 0 and code == 0:
                    # Commit at SYN_REPORT, even when a report spans reads. Never
                    # send half a position/pressure update or lose a tip edge.
                    for ev, code, value in frame:
                        self.apply_event(kind, pad, ev, code, value)
                    frame.clear()
                    self.reports += 1
                    self.dirty = True
                    if self.observing:
                        self.enqueue(self.sample(seconds * 1000000 + micros))
                else:
                    if len(frame) >= 1024:
                        raise OSError('Tablet input report exceeded its event limit.')
                    frame.append((event, code, value))

    def apply_event(self, kind, pad, event, code, value):
        if kind == 'pen':
            if event == 3:
                self.axes[code] = value
            elif event == 1 and value in (0, 1):
                self.keys.add(code) if value else self.keys.discard(code)
        elif kind == 'pad' and event == 1 and code in pad and value in (0, 1, 2):
            self.on_button(code, value)
            if value != 2:
                index = pad.index(code)
                if value:
                    self.pad_mask |= 1 << index
                else:
                    self.pad_mask &= ~(1 << index)
        elif kind == 'touch' and event == 3:
            if code == 47:
                self.slot = value
            elif code == 57:
                self.contacts[self.slot] = value >= 0

    def observe(self, active):
        if active != self.observing:
            self.observing = active
            self.pending.clear()
            self.dirty = True

    def enqueue(self, sample):
        if len(self.pending) >= 256:
            raise BufferError('Tablet connection cannot keep up with input reports.')
        self.pending.append((time.monotonic(), sample))

    def check_pending(self):
        if self.pending and time.monotonic() - self.pending[0][0] > 0.5:
            raise BufferError('Tablet connection is more than half a second behind input.')

    def take_samples(self):
        self.check_pending()
        # Bound each transport write while retaining report order. Multiple
        # existing encrypted records share one write; no new wire format.
        return [self.pending.popleft()[1] for _ in range(min(32, len(self.pending)))]

    def sample(self, timestamp=None):
        self.sequence += 1
        self.dirty = False
        flags = int(self.attached)
        for bit, code in enumerate((320, 330, 321, 331, 332), 1):
            flags |= int(code in self.keys) << bit
        low_x, high_x = self.ranges.get(0, (0, 0))
        low_y, high_y = self.ranges.get(1, (0, 0))
        low_p, high_p = self.ranges.get(24, (0, 0))
        return SAMPLE.pack(1, flags, self.pad_mask & 0xffff, self.sequence,
            time.monotonic_ns() // 1000 if timestamp is None else timestamp,
            self.axes.get(0, 0), self.axes.get(1, 0), self.axes.get(24, 0),
            low_x, high_x, low_y, high_y, low_p, high_p,
            self.axes.get(26, 0), self.axes.get(27, 0), self.axes.get(25, 0),
            self.generation, self.reports, self.dropped, sum(self.contacts.values()), 0)

    def close(self):
        self.close_nodes()
        self.selector.close()
