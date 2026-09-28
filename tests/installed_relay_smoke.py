# SPDX-License-Identifier: GPL-3.0-or-later
"""Exercise extracted package files, not the source/build directory."""
from pathlib import Path
import sys
import tempfile

root = Path(sys.argv[1]).resolve()
private = root / 'usr/lib/plank-tablet-relay-ble'
library = private / 'libplank_ble_lab.so'
assert library.is_file(), 'Packaged ctypes library missing or renamed'
launcher = root / 'usr/bin/plank-tablet-relay-ble'
assert launcher.read_text().splitlines()[0] == '#!/usr/bin/python3 -I'
sys.path.insert(0, str(private))
from ble_lab.config import read_settings
from ble_lab.native import Native
from ble_lab.bluez import Server  # Check installed imports and dependencies.

settings = read_settings(root / 'etc/plank-tablet-relay-ble/relay.conf')
assert not settings.exclusive_adapter and not settings.disable_controller_address_resolution
with tempfile.TemporaryDirectory() as directory:
    state = Path(directory)
    native = Native(library, state)
    native.close()
    key = (state / 'identity.key').read_bytes()
    native = Native(library, state)
    native.tablet(False)
    assert not native.observing
    native.close()
    assert (state / 'identity.key').read_bytes() == key
    assert (state / 'identity.key').stat().st_mode & 0o777 == 0o600
print('PASS: extracted package imports, native library, identity persistence and default policy')
