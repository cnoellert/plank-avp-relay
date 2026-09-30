# SPDX-License-Identifier: GPL-3.0-or-later
import socket
import sys
from pathlib import Path
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from avp_relay.network_routes import usable_addresses, local_addresses


class RouteTests(unittest.TestCase):
    def test_literals_are_bounded_deduplicated_and_match_listener_families(self):
        values = ['192.0.2.2', '192.0.2.2', '2001:db8::2', '::ffff:127.0.0.1',
                  '127.0.0.1', '0.0.0.0', '0.1.2.3', '169.254.1.2', '224.0.0.1',
                  '255.255.255.255', '::', '::1', 'fe80::1', 'ff02::1', 'host.example']
        self.assertEqual(usable_addresses(values, {socket.AF_INET, socket.AF_INET6}),
                         ['192.0.2.2', '2001:db8::2'])
        self.assertEqual(usable_addresses(values, {socket.AF_INET}), ['192.0.2.2'])
        self.assertEqual(len(usable_addresses(['192.0.2.' + str(n) for n in range(1, 20)],
                                             {socket.AF_INET})), 8)

    def test_interface_reader_ignores_down_links_and_requires_no_subprocess(self):
        def ioctl(_socket, operation, request):
            name = request.split(b'\0', 1)[0]
            result = bytearray(256)
            if operation == 0x8913:
                result[16:18] = (0 if name == b'down0' else 1).to_bytes(2, sys.byteorder)
            else:
                result[20:24] = socket.inet_pton(socket.AF_INET,
                    '127.0.0.1' if name == b'lo' else '192.0.2.2')
            return bytes(result)
        with patch('avp_relay.network_routes.socket.if_nameindex', return_value=[(1, 'lo'), (2, 'lan0'), (3, 'down0')]), \
             patch('avp_relay.network_routes.fcntl.ioctl', side_effect=ioctl), \
             patch('avp_relay.network_routes.Path.read_text', return_value='20010db8000000000000000000000002 02 40 00 80 lan0\n'):
            self.assertEqual(local_addresses({socket.AF_INET, socket.AF_INET6}),
                             ['192.0.2.2', '2001:db8::2'])


if __name__ == '__main__':
    unittest.main()
