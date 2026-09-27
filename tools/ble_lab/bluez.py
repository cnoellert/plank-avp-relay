# SPDX-License-Identifier: GPL-3.0-or-later
"""BlueZ peripheral for the authenticated PLANK input-observer lab."""
import dbus
import dbus.exceptions
import dbus.mainloop.glib
import dbus.service
from gi.repository import GLib
import signal
import time

from .capture import Capture
from .native import Native, ProtocolError
from .transport import Indications

SERVICE_UUID = '462f3a10-7a31-4ab3-9e7f-c36af495ecf0'
RX_UUID = '462f3a11-7a31-4ab3-9e7f-c36af495ecf0'
TX_UUID = '462f3a12-7a31-4ab3-9e7f-c36af495ecf0'
PROPERTIES = 'org.freedesktop.DBus.Properties'
OBJECTS = 'org.freedesktop.DBus.ObjectManager'
GATT = 'org.bluez.GattCharacteristic1'
SERVICE = 'org.bluez.GattService1'
ADVERTISEMENT = 'org.bluez.LEAdvertisement1'
BASE = '/la/instinctual/plank/tablet_lab'


class Rejected(dbus.exceptions.DBusException):
    _dbus_error_name = 'org.bluez.Error.NotPermitted'


class Object(dbus.service.Object):
    def __init__(self, bus, path, interface, properties):
        super().__init__(bus, path)
        self.path, self.interface, self.properties = path, interface, properties

    @dbus.service.method(PROPERTIES, in_signature='s', out_signature='a{sv}')
    def GetAll(self, interface):
        if interface != self.interface:
            raise Rejected('Unknown interface')
        return self.properties

    @dbus.service.method(PROPERTIES, in_signature='ss', out_signature='v')
    def Get(self, interface, name):
        if interface != self.interface or name not in self.properties:
            raise Rejected('Unknown property')
        return self.properties[name]

    @dbus.service.signal(PROPERTIES, signature='sa{sv}as')
    def PropertiesChanged(self, interface, changed, invalidated):
        pass


class Advertisement(Object):
    def __init__(self, bus):
        super().__init__(bus, BASE + '/advertisement', ADVERTISEMENT, {
            'Type': 'peripheral', 'ServiceUUIDs': dbus.Array([SERVICE_UUID], signature='s'),
            'LocalName': 'PLANK Relay Lab', 'Discoverable': dbus.Boolean(True)})

    @dbus.service.method(ADVERTISEMENT)
    def Release(self):
        pass


class Characteristic(Object):
    def __init__(self, server, transmit):
        self.server, self.transmit = server, transmit
        path = BASE + '/service/' + ('tx' if transmit else 'rx')
        super().__init__(server.bus, path, GATT, {
            'UUID': TX_UUID if transmit else RX_UUID,
            'Service': dbus.ObjectPath(BASE + '/service'),
            'Flags': dbus.Array(['indicate'] if transmit else ['write'], signature='s'),
            **({'Notifying': dbus.Boolean(False)} if transmit else {})})

    @dbus.service.method(GATT, in_signature='aya{sv}')
    def WriteValue(self, value, options):
        if self.transmit:
            raise Rejected('Write to RX')
        self.server.receive(bytes(value), options)

    @dbus.service.method(GATT)
    def StartNotify(self):
        if not self.transmit:
            raise Rejected('Subscribe to TX')
        self.server.notifying = True
        self.properties['Notifying'] = dbus.Boolean(True)
        self.PropertiesChanged(GATT, {'Notifying': dbus.Boolean(True)}, [])

    @dbus.service.method(GATT)
    def StopNotify(self):
        if self.transmit:
            self.server.notifying = False
            self.properties['Notifying'] = dbus.Boolean(False)
            self.server.disconnect()
            self.PropertiesChanged(GATT, {'Notifying': dbus.Boolean(False)}, [])

    @dbus.service.method(GATT)
    def Confirm(self):
        if self.transmit:
            self.server.queue.confirm()


class Server(dbus.service.Object):
    def __init__(self, args):
        dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
        self.bus = dbus.SystemBus()
        super().__init__(self.bus, BASE)
        self.loop = GLib.MainLoop()
        self.adapter = '/org/bluez/' + args.adapter
        self.native = Native(args.library, args.state_dir)
        self.capture = Capture(args.tablet, self.button)
        self.peer = None
        self.notifying = False
        self.queue = Indications(self.emit)
        self.last_sample = 0
        self.was_observing = False
        self.failure = None
        self.service = Object(self.bus, BASE + '/service', SERVICE,
            {'UUID': SERVICE_UUID, 'Primary': dbus.Boolean(True)})
        self.rx, self.tx = Characteristic(self, False), Characteristic(self, True)
        self.advertisement = Advertisement(self.bus)
        self.gatt_registered = self.advertising = False
        self.bus.add_signal_receiver(self.device_changed, dbus_interface=PROPERTIES,
            signal_name='PropertiesChanged', path_keyword='path', arg0='org.bluez.Device1')
        self.bus.add_signal_receiver(self.removed, dbus_interface=OBJECTS,
            signal_name='InterfacesRemoved')

    @dbus.service.method(OBJECTS, out_signature='a{oa{sa{sv}}}')
    def GetManagedObjects(self):
        return {dbus.ObjectPath(obj.path): {obj.interface: obj.properties}
                for obj in (self.service, self.rx, self.tx)}

    def emit(self, data):
        if not self.peer or not self.notifying:
            raise ProtocolError('Bluetooth subscription ended.')
        self.tx.PropertiesChanged(GATT, {'Value': dbus.Array(data, signature='y')}, [])

    def receive(self, data, options):
        peer = str(options.get('device', ''))
        if (not self.notifying or not peer.startswith(self.adapter + '/dev_') or
            str(options.get('link', '')) != 'LE' or int(options.get('offset', 0)) != 0 or
            str(options.get('type', 'request')) != 'request' or
            not 1 <= len(data) <= 512 or (self.peer and self.peer != peer)):
            raise Rejected('One selected LE client and sequential writes are required.')
        self.queue.mtu_payload = max(20, min(512, int(options.get('mtu', 23)) - 3))
        try:
            # Drain before every fragment, including the one completing START.
            # Earlier physical events must not become approval for a new request.
            self.capture.poll()
            self.native.tablet(self.capture.attached)
            if not self.peer:
                self.peer = peer
                print('Headset transport connected; authenticating.', flush=True)
            for reply in self.native.receive(data):
                self.queue.append(reply)
        except (ProtocolError, BufferError, TimeoutError):
            self.disconnect()
            raise Rejected('Protocol rejected; existing trust retained.')

    def button(self, code, value):
        self.native.tablet(self.capture.attached)
        self.queue.append(self.native.button(code, value))

    def disconnect(self):
        peer, self.peer = self.peer, None
        self.queue.clear()
        self.native.disconnect()
        self.was_observing = False
        if peer:
            print('Headset link closed; existing trust retained.', flush=True)
            dbus.Interface(self.bus.get_object('org.bluez', peer), 'org.bluez.Device1').Disconnect(
                reply_handler=lambda: None, error_handler=lambda error: None)

    def device_changed(self, interface, changed, invalidated, path):
        if str(path) == self.peer and 'Connected' in changed and not changed['Connected']:
            self.disconnect()

    def removed(self, path, interfaces):
        if str(path) == self.peer and 'org.bluez.Device1' in interfaces:
            self.disconnect()

    def tick(self):
        try:
            self.capture.poll()
            self.native.tablet(self.capture.attached)
            self.queue.check_timeout()
            self.queue.append(self.native.tick())
            observing = self.native.observing
            if observing and not self.was_observing:
                self.capture.dirty = True
                print('Authenticated input observer started.', flush=True)
            self.was_observing = observing
            now = time.monotonic()
            if (observing and not self.queue.busy and now - self.last_sample >= 0.05 and
                (self.capture.dirty or now - self.last_sample >= 1)):
                self.queue.append(self.native.sample(self.capture.sample()))
                self.last_sample = now
        except (ProtocolError, BufferError, TimeoutError) as error:
            print(str(error), flush=True)
            self.disconnect()
        except (OSError, RuntimeError, ValueError) as error:
            self.failure = str(error)
            self.loop.quit()
            return False
        return True

    def run(self):
        adapter = self.bus.get_object('org.bluez', self.adapter)
        gatt = dbus.Interface(adapter, 'org.bluez.GattManager1')
        advertising = dbus.Interface(adapter, 'org.bluez.LEAdvertisingManager1')

        def failed(error):
            self.failure = 'BlueZ registration failed: ' + str(error)
            self.loop.quit()

        def advertised():
            self.advertising = True
            print('PLANK Relay Lab is advertising. Use the app to discover it.', flush=True)

        def registered():
            self.gatt_registered = True
            advertising.RegisterAdvertisement(self.advertisement.path, {},
                reply_handler=advertised, error_handler=failed)

        signal.signal(signal.SIGINT, lambda *_: self.loop.quit())
        signal.signal(signal.SIGTERM, lambda *_: self.loop.quit())
        self.capture.discover()
        gatt.RegisterApplication(BASE, {}, reply_handler=registered, error_handler=failed)
        GLib.timeout_add(10, self.tick)
        try:
            self.loop.run()
        finally:
            self.disconnect()
            for enabled, function, path in (
                (self.advertising, advertising.UnregisterAdvertisement, self.advertisement.path),
                (self.gatt_registered, gatt.UnregisterApplication, BASE)):
                if enabled:
                    try:
                        function(path)
                    except dbus.exceptions.DBusException:
                        pass
            self.capture.close()
            self.native.close()
        if self.failure:
            raise RuntimeError(self.failure)
