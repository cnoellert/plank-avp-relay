# SPDX-License-Identifier: GPL-3.0-or-later
import ctypes
import errno
import socket
import struct
import sys
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from avp_relay.controller import clear_advertisements, disable_address_resolution, bind_control, controller_indexes


class ControllerTests(unittest.TestCase):
    def invoke(self, events):
        channel = MagicMock()
        channel.recv.side_effect = events
        with patch('avp_relay.controller.socket.socket') as factory:
            factory.return_value.__enter__.return_value = channel
            disable_address_resolution('hci2')
        return channel

    def test_requires_matching_complete_not_success_for_another_command(self):
        channel = self.invoke([
            bytes.fromhex('04 0e 04 01 0a 20 00'),  # Advertising completion.
            bytes.fromhex('04 0f 04 00 01 2d 20'),  # Command accepted, not complete.
            bytes.fromhex('04 0e 04 01 2d 20 00'),
        ])
        channel.bind.assert_called_once_with((2,))
        channel.sendall.assert_called_once_with(bytes.fromhex('01 2d 20 01 00'))
        self.assertEqual(channel.recv.call_count, 3)

    def test_controller_refusal_is_not_reported_as_applied(self):
        for response in ('04 0e 04 01 2d 20 0c', '04 0f 04 0c 01 2d 20'):
            with self.subTest(response=response), self.assertRaisesRegex(RuntimeError, '0x0c'):
                self.invoke([bytes.fromhex(response)])

    def test_truncated_response_and_timeout_fail(self):
        with self.assertRaisesRegex(RuntimeError, 'Malformed'):
            self.invoke([bytes.fromhex('04 0e 04 01 2d 20')])
        with self.assertRaises(TimeoutError):
            self.invoke([socket.timeout()])

    def test_invalid_adapter_does_not_open_controller(self):
        with patch('avp_relay.controller.socket.socket') as factory:
            for adapter in ('hci', 'hci-1', 'hci0/other', 'hci١', 'hci65535'):
                with self.subTest(adapter=adapter), self.assertRaises(ValueError):
                    disable_address_resolution(adapter)
            factory.assert_not_called()

    @staticmethod
    def management_reply(opcode, value=b'', status=0, index=2, event=1):
        return struct.pack('<HHHHB', event, index, 3 + len(value), opcode, status) + value

    def clear(self, events):
        channel = MagicMock()
        channel.recv.side_effect = events
        with patch('avp_relay.controller.socket.socket') as factory, \
                patch('avp_relay.controller.bind_control') as bind:
            factory.return_value.__enter__.return_value = channel
            clear_advertisements('hci2')
            bind.assert_called_once_with(channel)
        return channel

    def test_fresh_controller_does_not_remove_nonexistent_advertisements(self):
        channel = self.clear([self.management_reply(0x3d, bytes.fromhex('ff0000001f1f0100'))])
        channel.bind.assert_not_called()
        channel.sendall.assert_called_once_with(bytes.fromhex('3d0002000000'))

    def test_orphaned_instance_removed_after_valid_matching_reply(self):
        channel = self.clear([
            self.management_reply(0x3d, b'', index=1),
            self.management_reply(0x3c),
            self.management_reply(0x3d, bytes.fromhex('ff0000001f1f010101')),
            self.management_reply(0x3f, b'\x00'),
        ])
        self.assertEqual(channel.sendall.call_count, 2)
        channel.sendall.assert_called_with(bytes.fromhex('3f000200010000'))

    def test_management_failure_timeout_and_truncation_fail_closed(self):
        for events in ([self.management_reply(0x3d, status=0x14, event=2)],
                       [socket.timeout()], [b'\x01'],
                       [self.management_reply(0x3d, bytes.fromhex('ff0000001f1f0101'))]):
            with self.subTest(events=events), self.assertRaises((RuntimeError, TimeoutError)):
                self.clear(events)

    def test_native_control_bind_has_exact_linux_abi_on_older_python(self):
        channel = MagicMock()
        channel.fileno.return_value = 17
        with patch('avp_relay.controller.ctypes.CDLL') as library:
            bind = library.return_value.bind
            def capture(fd, pointer, size):
                self.assertEqual(fd, 17)
                self.assertEqual(size, 6)
                self.assertEqual(ctypes.string_at(pointer, size),
                    struct.pack('=HHH', socket.AF_BLUETOOTH, 0xffff, 3))
                return 0
            bind.side_effect = capture
            bind_control(channel)
        channel.bind.assert_not_called()

    def test_native_bind_failure_preserves_errno(self):
        with patch('avp_relay.controller.ctypes.CDLL') as library, \
                patch('avp_relay.controller.ctypes.get_errno', return_value=errno.EACCES):
            library.return_value.bind.return_value = -1
            with self.assertRaises(OSError) as raised:
                bind_control(MagicMock())
        self.assertEqual(raised.exception.errno, errno.EACCES)

    def test_kernel_index_list_is_validated(self):
        with patch('avp_relay.controller.socket.socket'), patch('avp_relay.controller.bind_control'), \
                patch('avp_relay.controller.management_command') as command:
            command.return_value = bytes.fromhex('020000000200')
            self.assertEqual(controller_indexes(), {0, 2})
            command.return_value = bytes.fromhex('0000')
            self.assertEqual(controller_indexes(), set())
            for invalid in (b'', bytes.fromhex('0100'), bytes.fromhex('00000000')):
                command.return_value = invalid
                with self.assertRaisesRegex(RuntimeError, 'Malformed'):
                    controller_indexes()


if __name__ == '__main__':
    unittest.main()
