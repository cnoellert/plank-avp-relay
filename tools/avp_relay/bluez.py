# SPDX-License-Identifier: GPL-3.0-or-later
"""BlueZ peripheral for the authenticated PLANK input-observer lab."""
import dbus
import dbus.exceptions
import dbus.mainloop.glib
import dbus.service
import json
from pathlib import Path
from gi.repository import GLib
import signal
import time

from .core import RelayCore
from .network import TCPServer
from .l2cap import L2CAPServer
from .discovery import Publisher
from .controller import clear_advertisements, configure_le_connection_parameters, disable_address_resolution
from .notify import ready
from .native import ProtocolError
from .transport import EchoChannel, Indications, SetupChannel, write_peer
from .tablet_bluez import TabletBlueZ

SERVICE_UUID = '462f3a10-7a31-4ab3-9e7f-c36af495ecf0'
RX_UUID = '462f3a11-7a31-4ab3-9e7f-c36af495ecf0'
TX_UUID = '462f3a12-7a31-4ab3-9e7f-c36af495ecf0'
ECHO_RX_UUID = '462f3a13-7a31-4ab3-9e7f-c36af495ecf0'
ECHO_TX_UUID = '462f3a14-7a31-4ab3-9e7f-c36af495ecf0'
SETUP_RX_UUID = '462f3a15-7a31-4ab3-9e7f-c36af495ecf0'
SETUP_TX_UUID = '462f3a16-7a31-4ab3-9e7f-c36af495ecf0'
L2CAP_PSM_UUID = '462f3a17-7a31-4ab3-9e7f-c36af495ecf0'
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
    def __init__(self, bus, name):
        super().__init__(bus, BASE + '/advertisement', ADVERTISEMENT, {
            'Type': 'peripheral', 'ServiceUUIDs': dbus.Array([SERVICE_UUID], signature='s'),
            'LocalName': name, 'Discoverable': dbus.Boolean(True)})

    @dbus.service.method(ADVERTISEMENT)
    def Release(self):
        pass


class Characteristic(Object):
    def __init__(self, server, transmit, diagnostic=False, setup=False):
        self.server, self.transmit, self.diagnostic = server, transmit, diagnostic
        self.setup = setup
        self.endpoint = server.setup if setup else server.echo if diagnostic else server
        path = BASE + '/service/' + ('setup_' if setup else 'echo_' if diagnostic else '') + ('tx' if transmit else 'rx')
        uuid = (ECHO_TX_UUID if transmit else ECHO_RX_UUID) if diagnostic else (TX_UUID if transmit else RX_UUID)
        if setup:
            uuid = SETUP_TX_UUID if transmit else SETUP_RX_UUID
        super().__init__(server.bus, path, GATT, {
            'UUID': uuid,
            'Service': dbus.ObjectPath(BASE + '/service'),
            'Flags': dbus.Array(['indicate'] if transmit else ['write'], signature='s'),
            **({'Notifying': dbus.Boolean(False)} if transmit else {})})

    @dbus.service.method(GATT, in_signature='aya{sv}')
    def WriteValue(self, value, options):
        if self.transmit:
            raise Rejected('Write to RX')
        if self.setup:
            self.server.receive_setup(bytes(value), options)
        elif self.diagnostic:
            self.server.receive_echo(bytes(value), options)
        else:
            self.server.receive(bytes(value), options)

    @dbus.service.method(GATT)
    def StartNotify(self):
        if not self.transmit:
            raise Rejected('Subscribe to TX')
        self.endpoint.notifying = True
        print('Bluetooth test replies subscribed.' if self.diagnostic else 'Relay replies subscribed.', flush=True)
        self.properties['Notifying'] = dbus.Boolean(True)
        self.PropertiesChanged(GATT, {'Notifying': dbus.Boolean(True)}, [])

    @dbus.service.method(GATT)
    def StopNotify(self):
        if self.transmit:
            self.endpoint.notifying = False
            self.properties['Notifying'] = dbus.Boolean(False)
            self.endpoint.disconnect()
            self.PropertiesChanged(GATT, {'Notifying': dbus.Boolean(False)}, [])

    @dbus.service.method(GATT)
    def Confirm(self):
        if self.transmit:
            self.endpoint.queue.confirm()


class L2CAPEndpoint(Object):
    def __init__(self, server):
        self.server = server
        super().__init__(server.bus, BASE + '/service/l2cap', GATT, {
            'UUID': L2CAP_PSM_UUID, 'Service': dbus.ObjectPath(BASE + '/service'),
            'Flags': dbus.Array(['read'], signature='s')})

    @dbus.service.method(GATT, in_signature='a{sv}', out_signature='ay')
    def ReadValue(self, options):
        if not self.server.l2cap or int(options.get('offset', 0)) != 0:
            raise Rejected('Bluetooth L2CAP is unavailable.')
        return dbus.Array(b'\x01' + self.server.l2cap.psm.to_bytes(2, 'little'), signature='y')


class Server(dbus.service.Object):
    def __init__(self, args):
        dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
        self.bus = dbus.SystemBus()
        super().__init__(self.bus, BASE)
        self.loop = GLib.MainLoop()
        self.adapter = '/org/bluez/' + args.adapter
        self.controller_workaround = args.disable_controller_address_resolution
        self.exclusive_adapter = getattr(args, 'exclusive_adapter', False)
        self.notify_systemd = getattr(args, 'notify_systemd', False)
        self.core = None if args.transport_only else RelayCore(args, TabletBlueZ(self.bus, self.adapter))
        self.native = self.core.native if self.core else None
        self.capture = self.core.capture if self.core else None
        self.tablets = self.core.tablets if self.core else None
        self.peer = None
        self.notifying = False
        self.queue = Indications(self.emit)
        self.echo = EchoChannel(self.emit_echo, self.close_peer)
        self.setup = SetupChannel(self.emit_setup, self.close_peer,
            self.tablet_request, self.cancel_tablet_setup) if self.core else None
        self.network = self.publisher = None
        self.l2cap = None
        self.tcp_enabled = getattr(args, 'tcp_enabled', False) and self.core is not None
        self.tcp_port = getattr(args, 'tcp_port', 28991)
        self.version = getattr(args, 'version', 'development')
        self.next_registration = 0
        self.registering = False
        self.registration_generation = 0
        self.notified = False
        self.failure = None
        self.adapter_missing = False
        self.service = Object(self.bus, BASE + '/service', SERVICE,
            {'UUID': SERVICE_UUID, 'Primary': dbus.Boolean(True)})
        self.rx = Characteristic(self, False) if self.native else None
        self.tx = Characteristic(self, True) if self.native else None
        self.echo_rx, self.echo_tx = Characteristic(self, False, True), Characteristic(self, True, True)
        self.setup_rx = Characteristic(self, False, setup=True) if self.setup else None
        self.setup_tx = Characteristic(self, True, setup=True) if self.setup else None
        self.l2cap_endpoint = L2CAPEndpoint(self) if self.core else None
        self.advertisement = Advertisement(self.bus, getattr(args, 'name', 'PLANK Relay Lab'))
        self.gatt_registered = self.advertising = False
        self.bus.add_signal_receiver(self.device_changed, dbus_interface=PROPERTIES,
            signal_name='PropertiesChanged', path_keyword='path', arg0='org.bluez.Device1')
        self.bus.add_signal_receiver(self.removed, dbus_interface=OBJECTS,
            signal_name='InterfacesRemoved')
        self.bus.add_signal_receiver(self.adapter_changed, dbus_interface=PROPERTIES,
            signal_name='PropertiesChanged', path=self.adapter, arg0='org.bluez.Adapter1')
        self.bus.add_signal_receiver(self.bluez_changed, dbus_interface='org.freedesktop.DBus',
            signal_name='NameOwnerChanged', arg0='org.bluez')

    @dbus.service.method(OBJECTS, out_signature='a{oa{sa{sv}}}')
    def GetManagedObjects(self):
        return {dbus.ObjectPath(obj.path): {obj.interface: obj.properties}
                for obj in (self.service, self.rx, self.tx, self.echo_rx, self.echo_tx, self.setup_rx, self.setup_tx, self.l2cap_endpoint) if obj is not None}

    def cancel_tablet_setup(self, peer):
        if self.core:
            self.core.cancel_setup(peer)
            if self.controller_workaround and self.tablets.backend.scanned:
                self.tablets.backend.scanned = False
                self.bluetooth_unavailable('Restoring controller policy after tablet discovery.')

    def tablet_request(self, data, peer, authenticated=False, enrolling=False):
        return self.core.request(data, peer, authenticated, enrolling)

    def emit_setup(self, data):
        if not self.setup.peer or not self.setup.notifying:
            raise ProtocolError('Tablet setup subscription ended.')
        self.setup_tx.PropertiesChanged(GATT, {'Value': dbus.Array(data, signature='y')}, [])

    def receive_setup(self, data, options):
        # A competing peer cannot cancel the current owner's pairing attempt.
        try:
            write_peer(data, options, self.adapter, self.setup.notifying, self.setup.peer)
        except ValueError as error:
            raise Rejected(str(error))
        try:
            self.setup.receive(data, options, self.adapter, (self.core.owner if self.core else None) or self.echo.peer)
        except (OSError, ValueError, ProtocolError, BufferError, TimeoutError) as error:
            self.setup.disconnect()
            raise Rejected(str(error))

    def emit_echo(self, data):
        if not self.echo.peer or not self.echo.notifying:
            raise ProtocolError('Bluetooth test subscription ended.')
        self.echo_tx.PropertiesChanged(GATT, {'Value': dbus.Array(data, signature='y')}, [])

    def receive_echo(self, data, options):
        try:
            self.echo.receive(data, options, self.adapter, (self.core.owner if self.core else None) or (self.setup.peer if self.setup else None))
        except ValueError as error:
            raise Rejected(str(error))
        except (ProtocolError, BufferError, TimeoutError) as error:
            self.echo.disconnect()
            raise Rejected(str(error))

    def emit(self, data):
        if not self.peer or not self.notifying:
            raise ProtocolError('Bluetooth subscription ended.')
        self.tx.PropertiesChanged(GATT, {'Value': dbus.Array(data, signature='y')}, [])

    def receive(self, data, options):
        if not self.core or self.echo.peer or (self.setup and self.setup.peer):
            raise Rejected('Another relay operation is active.')
        try:
            peer = write_peer(data, options, self.adapter, self.notifying, self.peer)
            if self.core.owner is not None and self.core.owner != peer:
                raise ValueError('The relay already has an active headset connection.')
        except ValueError as error:
            raise Rejected(str(error))
        self.queue.mtu_payload = max(20, min(512, int(options.get('mtu', 23)) - 3))
        try:
            if not self.peer:
                self.core.claim(peer, 1, self.queue.append, lambda: self.queue.busy, self.disconnect)
                self.peer = peer
            self.core.receive(peer, data)
        except (OSError, ValueError, ProtocolError, BufferError, TimeoutError) as error:
            self.disconnect()
            raise Rejected(str(error) if isinstance(error, ValueError) else
                           'Protocol rejected; existing trust retained.')

    def disconnect(self):
        peer, self.peer = self.peer, None
        self.queue.clear()
        if self.core:
            self.core.release(peer)
        if peer:
            self.cancel_tablet_setup(peer)
            self.close_peer(peer)

    def close_peer(self, peer):
        try:
            dbus.Interface(self.bus.get_object('org.bluez', peer), 'org.bluez.Device1').Disconnect(
                reply_handler=lambda: None, error_handler=lambda error: None)
        except dbus.exceptions.DBusException:
            pass  # The adapter or BlueZ may already have disappeared.

    def device_changed(self, interface, changed, invalidated, path):
        if self.setup and str(path) == self.setup.peer and 'Connected' in changed and not changed['Connected']:
            self.setup.disconnect()
        if str(path) == self.peer and 'Connected' in changed and not changed['Connected']:
            self.disconnect()
        if str(path) == self.echo.peer and 'Connected' in changed and not changed['Connected']:
            self.echo.disconnect()

    def removed(self, path, interfaces):
        if self.setup and str(path) == self.setup.peer and 'org.bluez.Device1' in interfaces:
            self.setup.disconnect()
        if str(path) == self.adapter and 'org.bluez.Adapter1' in interfaces:
            self.bluetooth_unavailable('Bluetooth adapter removed.')
        if str(path) == self.peer and 'org.bluez.Device1' in interfaces:
            self.disconnect()
        if str(path) == self.echo.peer and 'org.bluez.Device1' in interfaces:
            self.echo.disconnect()

    def adapter_changed(self, interface, changed, invalidated):
        if 'Powered' in changed and not changed['Powered']:
            self.bluetooth_unavailable('Bluetooth controller powered off.')

    def bluez_changed(self, name, previous, current):
        if previous and previous != current:
            self.bluetooth_unavailable('BlueZ restarted.')
            if self.tablets:
                self.tablets.backend.registered = False

    def bluetooth_unavailable(self, reason):
        print(reason + ' Network service remains available.', flush=True)
        self.registration_generation += 1
        self.registering = False
        self.unregister_bluetooth()
        self.disconnect()
        self.echo.disconnect()
        if self.setup:
            self.setup.disconnect()
        self.next_registration = time.monotonic() + 5

    def unregister_bluetooth(self):
        if self.l2cap:
            self.l2cap.close()
            self.l2cap = None
        for enabled, kind, method, path in (
            (self.advertising, 'org.bluez.LEAdvertisingManager1', 'UnregisterAdvertisement', self.advertisement.path),
            (self.gatt_registered, 'org.bluez.GattManager1', 'UnregisterApplication', BASE)):
            if enabled:
                try:
                    getattr(dbus.Interface(self.bus.get_object('org.bluez', self.adapter), kind), method)(path, timeout=2)
                except dbus.exceptions.DBusException:
                    pass
        self.gatt_registered = self.advertising = False

    def tick(self):
        if self.l2cap:
            self.l2cap.poll()
        if self.network:
            self.network.poll()
            self.publisher.tick()
        if (self.tablets and self.controller_workaround and self.tablets.backend.scanned
                and not self.tablets.owner):
            self.tablets.backend.scanned = False
            self.bluetooth_unavailable('Restoring controller policy after tablet discovery.')
        if not self.advertising and not self.registering and time.monotonic() >= self.next_registration:
            if not (Path('/sys/class/bluetooth') / self.adapter.rsplit('/', 1)[1]).exists():
                if not self.adapter_missing:
                    self.bluetooth_unavailable('No Bluetooth adapter available.')
                self.adapter_missing = True
                self.next_registration = time.monotonic() + 5
            else:
                self.adapter_missing = False
                try:
                    self.register_bluetooth()
                except (OSError, RuntimeError, dbus.exceptions.DBusException) as error:
                    self.bluetooth_unavailable(str(error))
        for channel in (self.echo, self.setup):
            if channel:
                try:
                    channel.tick()
                except (ProtocolError, BufferError, TimeoutError):
                    channel.disconnect()
        try:
            self.queue.check_timeout()
        except TimeoutError:
            self.disconnect()
        if self.core:
            try:
                self.core.tick()
            except (OSError, RuntimeError, ValueError) as error:
                self.failure = 'Relay input failed: ' + str(error)
                self.loop.quit()
                return False
        return True

    def register_bluetooth(self):
        adapter = self.bus.get_object('org.bluez', self.adapter)
        gatt = dbus.Interface(adapter, 'org.bluez.GattManager1')
        advertising = dbus.Interface(adapter, 'org.bluez.LEAdvertisingManager1')
        properties = dbus.Interface(adapter, PROPERTIES)
        if self.controller_workaround or self.exclusive_adapter:
            if (properties.Get('org.bluez.Adapter1', 'Discovering') or
                    properties.Get('org.bluez.LEAdvertisingManager1', 'ActiveInstances')):
                raise RuntimeError('Adapter setup requires no scan or advertisement active.')
        if self.exclusive_adapter:
            properties.Set('org.bluez.Adapter1', 'Powered', dbus.Boolean(True))
            properties.Set('org.bluez.Adapter1', 'Pairable', dbus.Boolean(False))
        if not properties.Get('org.bluez.Adapter1', 'Powered'):
            raise RuntimeError('Bluetooth adapter is powered off.')
        if self.exclusive_adapter:
            clear_advertisements(self.adapter.rsplit('/', 1)[1])
        if self.controller_workaround:
            disable_address_resolution(self.adapter.rsplit('/', 1)[1])
            print('Controller address-resolution workaround applied.', flush=True)

        configure_le_connection_parameters(self.adapter.rsplit('/', 1)[1])
        print('Bluetooth LE connection preference configured: 15 ms, latency 0, supervision 720 ms.', flush=True)

        if self.core and self.l2cap is None:
            self.l2cap = L2CAPServer(self.core,
                str(properties.Get('org.bluez.Adapter1', 'Address')),
                str(properties.Get('org.bluez.Adapter1', 'AddressType')),
                busy=lambda: bool(self.peer or self.echo.peer or (self.setup and self.setup.peer)))
            print('Bluetooth L2CAP listening on PSM ' + str(self.l2cap.psm) + '.', flush=True)

        self.registering = True
        self.registration_generation += 1
        generation = self.registration_generation
        def failed(error):
            if generation == self.registration_generation:
                self.bluetooth_unavailable('BlueZ registration failed: ' + str(error))

        def advertised():
            if generation != self.registration_generation:
                return
            self.advertising = True
            self.registering = False
            print('Bluetooth relay is advertising. Use the app to discover it.', flush=True)
            self.notify_ready()

        def registered():
            if generation != self.registration_generation:
                return
            self.gatt_registered = True
            advertising.RegisterAdvertisement(self.advertisement.path, {},
                reply_handler=advertised, error_handler=failed)

        gatt.RegisterApplication(BASE, {}, reply_handler=registered, error_handler=failed)

    def notify_ready(self):
        if self.notify_systemd and not self.notified:
            ready()
            self.notified = True

    def run(self):
        signal.signal(signal.SIGINT, lambda *_: self.loop.quit())
        signal.signal(signal.SIGTERM, lambda *_: self.loop.quit())
        try:
            if self.tcp_enabled:
                self.network = TCPServer(self.core, self.tcp_port,
                    busy=lambda: bool(self.echo.peer or (self.setup and self.setup.peer)))
                self.publisher = Publisher(self.bus, self.network.port, self.native.public_key, self.version)
                self.publisher.tick()
                print('Network tablet relay listening on TCP ' + str(self.network.port) + '.', flush=True)
                self.notify_ready()
            if self.capture:
                self.capture.discover()
            self.tick()
            GLib.timeout_add(10, self.tick)
            self.loop.run()
        finally:
            if self.publisher:
                self.publisher.close()
            if self.network:
                self.network.close()
            self.disconnect()
            self.echo.disconnect()
            if self.setup:
                self.setup.disconnect()
                if self.tablets.owner:
                    self.core.cancel_setup(self.tablets.owner)
                try:
                    self.tablets.backend.close()
                except (RuntimeError, dbus.exceptions.DBusException):
                    pass
            self.unregister_bluetooth()
            if self.core:
                self.core.close()
        if self.failure:
            raise RuntimeError(self.failure)
