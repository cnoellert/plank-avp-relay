# SPDX-License-Identifier: GPL-3.0-or-later
"""Verify the product rename retains the actual native identity and approvals."""
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from avp_relay.migration import migrate_namespace
from avp_relay.native import Native

LIBRARY = Path(sys.argv.pop(1)).resolve()


class MigrationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.old = self.root/'var/lib/plank-tablet-relay-ble'
        self.old.mkdir(parents=True, mode=0o700)
        native = Native(LIBRARY, self.old)
        self.public = native.public_key
        native.close()
        (self.old/'paired-clients.json').write_text(json.dumps({'version':1,'clients':['12'*32]}, separators=(',',':')))
        (self.old/'paired-clients.json').chmod(0o600)
        (self.old/'tablets.json').write_text('{"saved-tablet":"AA:BB:CC:DD:EE:FF"}')
        (self.old/'pair-budget').write_text('1 0 0\n')
        self.before = {p.name:p.read_bytes() for p in self.old.iterdir() if p.is_file()}
        self.new = self.root/'var/lib/plank-avp-relay'

    def test_native_identity_and_clients_survive_and_reinstall_does_not_recopy(self):
        config = self.root/'etc/plank-tablet-relay-ble/relay.conf'
        config.parent.mkdir(parents=True)
        config.write_text('[relay]\nname=My custom relay\n')
        defaults = self.root/'usr/share/plank-avp-relay/defaults/relay.conf'
        defaults.parent.mkdir(parents=True)
        defaults.write_text('[relay]\n')
        installed = self.root/'etc/plank-avp-relay/relay.conf'
        installed.parent.mkdir(parents=True)
        installed.write_bytes(defaults.read_bytes())
        self.assertTrue(migrate_namespace(self.root))
        for name, value in self.before.items():
            self.assertEqual((self.new/name).read_bytes(), value)
            self.assertEqual((self.new/name).stat().st_mode & 0o777, 0o600)
        native = Native(LIBRARY, self.new)
        self.assertEqual(native.public_key, self.public)
        self.assertTrue(native.has_clients)
        native.close()
        self.assertEqual(installed.read_bytes(), config.read_bytes())
        installed.write_text('[relay]\nname=Changed after migration\n')
        self.assertFalse(migrate_namespace(self.root))
        self.assertIn('Changed after migration', installed.read_text())
        self.assertEqual({p.name:p.read_bytes() for p in self.old.iterdir()}, self.before)

    def test_conflicting_identity_is_rejected_before_copying(self):
        self.new.mkdir(parents=True)
        (self.new/'identity.key').write_bytes(b'another identity')
        with self.assertRaises(ValueError): migrate_namespace(self.root)
        self.assertEqual((self.new/'identity.key').read_bytes(), b'another identity')
        self.assertFalse((self.new/'paired-clients.json').exists())

    def test_symlink_is_not_followed(self):
        (self.old/'link').symlink_to('/etc/passwd')
        with self.assertRaises(ValueError): migrate_namespace(self.root)
        self.assertFalse(self.new.exists())

    def test_saved_usb_mode_moves_to_role_subdirectory(self):
        old = self.root/'var/lib/plank-tablet-relay-gadget'
        old.mkdir(parents=True)
        mode = b'{"mode":"router","targetMode":"router","phase":"idle","requestID":null}'
        (old/'mode.json').write_bytes(mode)
        migrate_namespace(self.root)
        self.assertEqual((self.new/'usb/mode.json').read_bytes(), mode)


if __name__ == '__main__': unittest.main()
