# SPDX-License-Identifier: GPL-3.0-or-later
import json
from pathlib import Path
import socket
import sys
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from avp_relay import drawing_status as status

class DrawingTransportTests(unittest.TestCase):
    def setUp(self):
        self.body = {'version': 2, 'ok': True, 'supported': True, 'state': 'ready', 'bluetooth': True,
            'listener': {'drawingIdentity': 'b4805f947954ddad8645c4a87d1bead9bcd2aceb3cacfa133dcdf10f1048191c',
                'drawingProtocol': dict(status.PROTOCOL), 'boundAddress': '0.0.0.0', 'boundPort': 28990}}
    def read(self, body=None, inventory=None):
        return status.read_handoff_v2(reader=lambda: (json.dumps(body or self.body).encode(), None),
            inventory=[] if inventory is None else inventory, families={socket.AF_INET})
    def test_bluetooth_only_has_no_invented_network_route(self):
        result = self.read()
        self.assertEqual(result['state'], 'ready')
        self.assertEqual(result['descriptor']['routes'], [])
        self.assertEqual(result['descriptor']['bluetooth'], {'linkType': 1})
        self.assertEqual(result['descriptor']['version'], 2)
    def test_no_routes_or_bluetooth_is_unavailable(self):
        self.body['bluetooth'] = False
        self.assertEqual(self.read()['state'], 'unavailable')
    def test_bad_metadata_cannot_offer_bluetooth(self):
        for changed in ({'bluetooth': 1}, {'version': True}, {'unknown': 1}):
            with self.subTest(changed=changed):
                self.assertEqual(self.read(dict(self.body, **changed))['reason'], 'service.invalid')
    def test_duplicate_nested_reply_is_unavailable(self):
        raw = json.dumps(self.body).replace('"linkType": 2', '"linkType": 2, "linkType": 1').encode()
        self.assertEqual(status.read_handoff_v2(reader=lambda: (raw, None))['reason'], 'service.invalid')
    def test_peer_and_busy_refusals_survive(self):
        for reason in ('service.peerUnverified', 'service.busy', 'service.absent'):
            self.assertEqual(status.read_handoff_v2(reader=lambda: (None, reason)), status.unavailable(reason))
    def test_old_ready_reply_cannot_claim_bluetooth(self):
        self.body['version'] = 1
        self.body.pop('bluetooth')
        self.assertEqual(self.read()['reason'], 'service.invalid')
    def test_native_request_is_versioned(self):
        self.assertEqual(status.DrawingStatusClient(version=2).request, b'{"op":"drawing-status","version":2}\n')
        self.assertEqual(status.DrawingStatusClient().request, status.REQUEST)

if __name__ == '__main__': unittest.main()
