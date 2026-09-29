# SPDX-License-Identifier: GPL-3.0-or-later
"""BlueZ enrollment adapter and a temporary, selected-device-only agent."""
import dbus
from functools import wraps
import dbus.service

from .capture import candidates
from .tablets import HID, address

PROPERTIES = 'org.freedesktop.DBus.Properties'
DEVICE = 'org.bluez.Device1'
ADAPTER = 'org.bluez.Adapter1'
AGENT = 'org.bluez.Agent1'


def bluez_errors(function):
    @wraps(function)
    def wrapped(*args, **kwargs):
        try:
            return function(*args, **kwargs)
        except dbus.exceptions.DBusException as error:
            raise RuntimeError('Bluetooth operation failed: ' + error.get_dbus_name()) from error
    return wrapped


class Denied(dbus.exceptions.DBusException):
    _dbus_error_name = 'org.bluez.Error.Rejected'


class TabletAgent(dbus.service.Object):
    def __init__(self, backend):
        self.backend = backend
        self.path = '/la/instinctual/plank/tablet_agent'
        super().__init__(backend.bus, self.path)

    def selected(self, device):
        if str(device) != self.backend.pairing_path:
            raise Denied('Only the selected tablet may pair.')

    @dbus.service.method(AGENT, in_signature='o')
    def RequestAuthorization(self, device):
        self.selected(device)

    @dbus.service.method(AGENT, in_signature='os')
    def AuthorizeService(self, device, uuid):
        self.selected(device)
        if str(uuid).lower() not in HID:
            raise Denied('Only the selected tablet HID service is authorized.')

    @dbus.service.method(AGENT, in_signature='o', out_signature='s')
    def RequestPinCode(self, device):
        raise Denied('This setup does not support tablet PIN entry.')

    @dbus.service.method(AGENT, in_signature='o', out_signature='u')
    def RequestPasskey(self, device):
        raise Denied('This setup does not support tablet passkey entry.')

    @dbus.service.method(AGENT, in_signature='ou')
    def RequestConfirmation(self, device, passkey):
        raise Denied('Numeric comparison is not supported by this headless agent.')

    @dbus.service.method(AGENT, in_signature='os')
    def DisplayPinCode(self, device, pin):
        raise Denied('Tablet PIN display is not supported.')

    @dbus.service.method(AGENT, in_signature='ouq')
    def DisplayPasskey(self, device, passkey, entered):
        raise Denied('Tablet passkey display is not supported.')

    @dbus.service.method(AGENT)
    def Cancel(self):
        pass

    @dbus.service.method(AGENT)
    def Release(self):
        self.backend.registered = False


class TabletBlueZ:
    def __init__(self, bus, adapter):
        self.bus, self.adapter = bus, adapter
        self.pairing_path = None
        self.registered = False
        self.scanned = False
        self.agent = TabletAgent(self)

    def interface(self, path, kind):
        return dbus.Interface(self.bus.get_object('org.bluez', path), kind)

    def device_path(self, target):
        return self.adapter + '/dev_' + address(target).replace(':', '_')

    @bluez_errors
    def devices(self):
        try:
            objects = self.interface('/', 'org.freedesktop.DBus.ObjectManager').GetManagedObjects(timeout=2)
        except dbus.exceptions.DBusException as error:
            if error.get_dbus_name() in ('org.freedesktop.DBus.Error.ServiceUnknown',
                    'org.freedesktop.DBus.Error.NameHasNoOwner', 'org.freedesktop.DBus.Error.UnknownObject',
                    'org.freedesktop.DBus.Error.NoReply'):
                return {}
            raise
        return {address(str(values[DEVICE]['Address'])): dict(values[DEVICE])
                for path, values in objects.items()
                if str(path).startswith(self.adapter + '/dev_') and DEVICE in values and
                   str(values[DEVICE].get('Adapter', '')) == self.adapter}

    @bluez_errors
    def pairable(self):
        return bool(self.interface(self.adapter, PROPERTIES).Get(ADAPTER, 'Pairable', timeout=5))

    @bluez_errors
    def set_pairable(self, value):
        self.interface(self.adapter, PROPERTIES).Set(ADAPTER, 'Pairable', dbus.Boolean(value), timeout=5)

    @bluez_errors
    def start_scan(self):
        adapter = self.interface(self.adapter, ADAPTER)
        adapter.SetDiscoveryFilter({'Transport': dbus.String('auto'),
                                   'DuplicateData': dbus.Boolean(False)}, timeout=5)
        adapter.StartDiscovery(timeout=5)
        self.scanned = True

    @bluez_errors
    def stop_scan(self):
        try:
            self.interface(self.adapter, ADAPTER).StopDiscovery(timeout=5)
        except dbus.exceptions.DBusException as error:
            if error.get_dbus_name() not in ('org.bluez.Error.NotReady', 'org.bluez.Error.Failed'):
                raise
        self.interface(self.adapter, ADAPTER).SetDiscoveryFilter({}, timeout=5)

    @bluez_errors
    def pair(self, target, done):
        self.pairing_path = self.device_path(target)
        if not self.registered:
            self.interface('/org/bluez', 'org.bluez.AgentManager1').RegisterAgent(
                self.agent.path, 'NoInputNoOutput', timeout=5)
            self.registered = True
        # The registered agent belongs to our D-Bus sender. Do not become the
        # system default agent or accept pairing for other programs/devices.
        self.interface(self.pairing_path, DEVICE).Pair(
            reply_handler=lambda: done(None), error_handler=lambda error: done(error), timeout=65)

    @bluez_errors
    def connect(self, target, done):
        self.pairing_path = self.device_path(target)
        self.interface(self.pairing_path, DEVICE).Connect(
            reply_handler=lambda: done(None), error_handler=lambda error: done(error), timeout=30)

    @bluez_errors
    def cancel_pair(self, target):
        try:
            self.interface(self.device_path(target), DEVICE).CancelPairing(timeout=5)
        except dbus.exceptions.DBusException as error:
            if error.get_dbus_name() not in ('org.bluez.Error.DoesNotExist',
                    'org.bluez.Error.NotInProgress', 'org.freedesktop.DBus.Error.UnknownObject'):
                raise

    @bluez_errors
    def remove(self, target):
        try:
            self.interface(self.adapter, ADAPTER).RemoveDevice(self.device_path(target), timeout=5)
        except dbus.exceptions.DBusException as error:
            if error.get_dbus_name() != 'org.bluez.Error.DoesNotExist':
                raise

    @bluez_errors
    def trust(self, target):
        self.interface(self.device_path(target), PROPERTIES).Set(
            DEVICE, 'Trusted', dbus.Boolean(True), timeout=5)

    @bluez_errors
    def input_ready(self, target):
        controller = str(self.interface(self.adapter, PROPERTIES).Get(ADAPTER, 'Address', timeout=5)).lower()
        return any(key[0] == 'bluetooth:' + target.lower() and key[1].lower().startswith(controller)
                   for key in candidates())

    @bluez_errors
    def close(self):
        self.pairing_path = None
        if self.registered:
            self.interface('/org/bluez', 'org.bluez.AgentManager1').UnregisterAgent(self.agent.path, timeout=5)
            self.registered = False
