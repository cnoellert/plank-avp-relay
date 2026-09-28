#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Temporary echo peripheral using Bumble's HCI host, independent of BlueZ.

Requires bumble==0.0.235 in a separate virtual environment and exclusive access
to a DOWN Linux HCI controller. See docs/bluetooth-headset-lab.md. No tablet,
persistent keys, enrollment or production relay support.
"""
import argparse
import asyncio
import contextlib
import logging
import signal
import uuid

from bumble import att, hci
from bumble.device import Device, DeviceConfiguration
from bumble.gatt import Characteristic, CharacteristicValue, Service
from bumble.pairing import PairingConfig, PairingDelegate
from bumble.transport import open_transport

SERVICE_UUID = '462f3a10-7a31-4ab3-9e7f-c36af495ecf0'
RX_UUID = '462f3a13-7a31-4ab3-9e7f-c36af495ecf0'
TX_UUID = '462f3a14-7a31-4ab3-9e7f-c36af495ecf0'
LOG = logging.getLogger('plank.echo')


class RejectPairing(PairingDelegate):
    async def accept(self):
        return False


class Echo:
    def __init__(self, device):
        self.device = device
        self.peer = None
        self.subscribed = False
        self.received = self.confirmed = 0
        self.pending = asyncio.Queue(maxsize=4096)
        self.worker = None
        self.deadline = None
        self.tx = Characteristic(TX_UUID, Characteristic.Properties.INDICATE, 0)
        self.tx.on(Characteristic.EVENT_SUBSCRIPTION, self.subscription)
        self.rx = Characteristic(
            RX_UUID, Characteristic.Properties.WRITE, Characteristic.WRITEABLE,
            CharacteristicValue(write=self.write),
        )
        device.add_service(Service(SERVICE_UUID, [self.rx, self.tx]))
        device.on(Device.EVENT_CONNECTION, self.connected)

    def connected(self, peer):
        if self.peer is not None:
            asyncio.create_task(peer.disconnect())
            return
        self.peer = peer
        self.received = self.confirmed = 0
        self.subscribed = False
        peer.on(peer.EVENT_DISCONNECTION, self.disconnected)
        self.worker = asyncio.create_task(self.send(peer))
        self.deadline = asyncio.get_running_loop().call_later(
            60, lambda: asyncio.create_task(self.disconnect(peer)))
        LOG.info('LE link established; waiting for echo subscription')

    async def disconnect(self, peer):
        if self.peer is peer:
            with contextlib.suppress(Exception):
                await asyncio.wait_for(peer.disconnect(), 5)

    def disconnected(self, reason):
        LOG.info('Link closed: reason=%s received=%d confirmed=%d',
                 reason, self.received, self.confirmed)
        self.peer = None
        self.subscribed = False
        if self.deadline:
            self.deadline.cancel()
        if self.worker:
            self.worker.cancel()
        while not self.pending.empty():
            self.pending.get_nowait()

    def subscription(self, peer, _notify, indicate):
        if peer is self.peer:
            self.subscribed = indicate
            LOG.info('Echo indications enabled=%s', indicate)

    def write(self, peer, value):
        if peer is not self.peer or not self.subscribed:
            raise att.ATT_Error(att.ATT_WRITE_NOT_PERMITTED_ERROR)
        if not 1 <= len(value) <= 512:
            raise att.ATT_Error(att.ATT_INVALID_ATTRIBUTE_LENGTH_ERROR)
        if self.received + len(value) > 4096:
            raise att.ATT_Error(att.ATT_INSUFFICIENT_RESOURCES_ERROR)
        # A byte budget bounds both queue memory and the number of tiny writes.
        self.received += len(value)
        self.pending.put_nowait(bytes(value))

    async def send(self, peer):
        try:
            while True:
                value = await self.pending.get()
                size = min(512, peer.att_mtu - 3)
                for offset in range(0, len(value), size):
                    if not self.subscribed:
                        raise RuntimeError('Reply subscription removed')
                    fragment = value[offset:offset + size]
                    await asyncio.wait_for(
                        self.device.indicate_subscriber(peer, self.tx, fragment), 10)
                    self.confirmed += len(fragment)
                LOG.info('Echo progress: received=%d confirmed=%d',
                         self.received, self.confirmed)
        except asyncio.CancelledError:
            raise
        except Exception as error:
            LOG.warning('Echo stopped: %s', error)
            await self.disconnect(peer)


async def run(args):
    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for signum in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(signum, stop.set)
    timer = loop.call_later(args.seconds, stop.set)
    async with await open_transport(f'hci-socket:{args.adapter}') as transport:
        config = DeviceConfiguration(name='PLANK Relay Lab')
        device = Device.from_config_with_hci(config, transport.source, transport.sink)
        device.pairing_config_factory = lambda _: PairingConfig(
            bonding=False, delegate=RejectPairing())
        echo = Echo(device)
        try:
            await asyncio.wait_for(device.power_on(), 15)
            # Match the previous LE-only experiment: public controller address,
            # ADV_IND, unrestricted filtering, all channels, 1280 ms interval.
            advertisement = b'\x02\x01\x06\x11\x07' + uuid.UUID(SERVICE_UUID).bytes[::-1]
            name = b'PLANK Relay Lab'
            scan_response = bytes([len(name) + 1, 0x09]) + name
            await asyncio.wait_for(device.start_advertising(
                own_address_type=hci.OwnAddressType.PUBLIC,
                auto_restart=True, advertising_data=advertisement,
                scan_response_data=scan_response,
                advertising_interval_min=1280, advertising_interval_max=1280,
            ), 15)
            LOG.info('READY: PLANK Relay Lab via Bumble; public address, 1280 ms; %ds window',
                     args.seconds)
            await stop.wait()
        finally:
            timer.cancel()
            with contextlib.suppress(Exception):
                await asyncio.wait_for(device.stop_advertising(), 5)
            if echo.peer:
                await echo.disconnect(echo.peer)
            if echo.worker:
                echo.worker.cancel()
                with contextlib.suppress(asyncio.CancelledError):
                    await echo.worker
            with contextlib.suppress(Exception):
                await asyncio.wait_for(device.power_off(), 5)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--adapter', type=int, default=0, help='HCI index (default: 0)')
    parser.add_argument('--seconds', type=int, default=600, help='Window, 30–900 seconds')
    args = parser.parse_args()
    if args.adapter < 0 or not 30 <= args.seconds <= 900:
        parser.error('Expected a nonnegative HCI index and 30–900 seconds')
    logging.basicConfig(level=logging.WARNING, format='%(asctime)s %(name)s %(message)s')
    LOG.setLevel(logging.INFO)
    asyncio.run(run(args))
