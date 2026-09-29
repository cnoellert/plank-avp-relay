# SPDX-License-Identifier: GPL-3.0-or-later
"""Publish only the live TCP listener; Avahi owns mDNS and interface changes."""
import dbus
import socket
import time
from .network import SERVICE_TYPE


class Publisher:
    def __init__(self, bus, port, public_key, version):
        self.bus, self.port, self.public_key, self.version = bus, port, public_key, version
        self.group = None
        self.next_retry = 0
        self.name = socket.gethostname().split('.', 1)[0]
        self.bus.add_signal_receiver(self.changed, dbus_interface='org.freedesktop.DBus',
            signal_name='NameOwnerChanged', arg0='org.freedesktop.Avahi')

    def changed(self, name, previous, current):
        self.group = None
        self.next_retry = 0

    def tick(self):
        if time.monotonic() < self.next_retry:
            return
        self.next_retry = time.monotonic() + 5
        try:
            avahi = dbus.Interface(self.bus.get_object('org.freedesktop.Avahi', '/'),
                'org.freedesktop.Avahi.Server')
            if self.group:
                state = int(self.group.GetState(timeout=2))
                if state == 3:  # Collision: ask Avahi for a distinct instance name.
                    self.name = str(avahi.GetAlternativeServiceName(self.name, timeout=2))
                    self.close()
                elif state != 4:
                    return
                else:
                    self.close()
            path = avahi.EntryGroupNew(timeout=2)
            self.group = dbus.Interface(self.bus.get_object('org.freedesktop.Avahi', path),
                'org.freedesktop.Avahi.EntryGroup')
            txt = [dbus.ByteArray(value.encode()) for value in
                ('protocol=1', 'id=' + self.public_key, 'release=' + self.version,
                 'hostname=' + socket.gethostname().split('.', 1)[0])]
            self.group.AddService(dbus.Int32(-1), dbus.Int32(-1), dbus.UInt32(0),
                self.name, SERVICE_TYPE, '', '', dbus.UInt16(self.port),
                dbus.Array(txt, signature='ay'), timeout=2)
            self.group.Commit(timeout=2)
            print('Network relay discovery registered.', flush=True)
        except dbus.exceptions.DBusException:
            self.close()

    def close(self):
        if self.group:
            try:
                self.group.Free(timeout=2)
            except dbus.exceptions.DBusException:
                pass
            self.group = None
