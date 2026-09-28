# SPDX-License-Identifier: GPL-3.0-or-later
import socket
import sys
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from ble_lab.controller import disable_address_resolution


class ControllerTests(unittest.TestCase):
    def invoke(self, events):
        channel = MagicMock()
        channel.recv.side_effect = events
        with patch('ble_lab.controller.socket.socket') as factory:
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
        with patch('ble_lab.controller.socket.socket') as factory:
            for adapter in ('hci', 'hci-1', 'hci0/other', 'hci١'):
                with self.subTest(adapter=adapter), self.assertRaises(ValueError):
                    disable_address_resolution(adapter)
            factory.assert_not_called()


if __name__ == '__main__':
    unittest.main()
