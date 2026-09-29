# SPDX-License-Identifier: GPL-3.0-or-later
"""One-time package namespace migration; never regenerate or overwrite trust."""
import os
from pathlib import Path
import tempfile

from .gadget_config import atomic_json


def migrate_namespace(root=Path('/')):
    destination = root / 'var/lib/plank-avp-relay'
    stamp = destination / 'namespace-migration.json'
    if stamp.exists():
        return False
    mappings = [
        (root/'var/lib/plank-tablet-relay-ble', destination),
        (root/'var/lib/plank-tablet-relay-gadget', destination/'usb'),
        (root/'var/backups/plank-tablet-relay', root/'var/backups/plank-avp-relay'),
    ]
    copies = []
    for old, new in mappings:
        if not old.exists():
            continue
        if old.is_symlink():
            raise ValueError('Previous relay state directory is a symlink; migration stopped.')
        for source in old.rglob('*'):
            if source.is_symlink() or not (source.is_dir() or source.is_file()):
                raise ValueError('Previous relay state contains a non-regular file; migration stopped.')
            if source.is_file():
                copies.append((source, new / source.relative_to(old), False))
    for name in ('relay.conf', 'usb-network.conf'):
        old = root/'etc/plank-tablet-relay-ble'/name
        if old.is_file():
            if old.is_symlink():
                raise ValueError('Previous relay configuration is a symlink; migration stopped.')
            copies.append((old, root/'etc/plank-avp-relay'/name, True))
    if not copies:
        return False
    # Check every conflict before copying any private state. Existing fresh
    # package defaults may be replaced; another live identity never may be.
    for source, target, config in copies:
        if target.is_symlink():
            raise ValueError('New relay path is a symlink; migration stopped.')
        if target.exists() and source.read_bytes() != target.read_bytes():
            default = root/'usr/share/plank-avp-relay/defaults'/target.name
            if not config or not default.is_file() or target.read_bytes() != default.read_bytes():
                raise ValueError('New relay data conflicts with previous state; nothing was overwritten.')
    destination.mkdir(parents=True, exist_ok=True, mode=0o700)
    for source, target, config in copies:
        target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        fd, temporary = tempfile.mkstemp(prefix='.migrate-', dir=target.parent)
        try:
            with os.fdopen(fd, 'wb') as output:
                output.write(source.read_bytes())
                os.fchmod(output.fileno(), 0o644 if config else 0o600)
                output.flush()
                os.fsync(output.fileno())
            os.replace(temporary, target)
        finally:
            if os.path.exists(temporary): os.unlink(temporary)
    # Earlier controller builds used the same owned fragments with the old
    # service label. This changes only that label, not the network settings.
    for path in (root/'etc/systemd/network').glob('04-plank-usb*'):
        if path.is_file() and path.read_text().startswith('# Managed by plank-tablet-relay-gadget\n'):
            path.write_text(path.read_text().replace('# Managed by plank-tablet-relay-gadget\n',
                                                    '# Managed by plank-avp-relay-usb\n', 1))
    atomic_json(stamp, {'version': 1, 'files': len(copies), 'sourcePreserved': True})
    print('Migrated relay configuration and saved identity to PLANK AVP Relay; original data retained.')
    return True
