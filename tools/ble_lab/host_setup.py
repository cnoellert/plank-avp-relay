# SPDX-License-Identifier: GPL-3.0-or-later
"""Apply the relay's installation settings on Armbian hosts."""
import os
from pathlib import Path
import re
import shutil
import stat
import sys
import tempfile


def configure_armbian(root=Path('/')):
    # Armbian may identify its base OS as Debian or Ubuntu in os-release.
    if not (root / 'etc/armbian-release').is_file():
        return False
    config = (root / 'etc/default/cpufrequtils').resolve()
    original = config.read_text() if config.exists() else ''
    settings = {'GOVERNOR': 'powersave', 'ENABLED': 'true'}
    seen = set()

    def replace(match):
        key = match.group(2)
        seen.add(key)
        return match.group(1) + key + '="' + settings[key] + '"'

    updated = re.sub(r'^(\s*(?:export[ \t]+)?)(GOVERNOR|ENABLED)[ \t]*=[^\n]*',
                     replace, original, flags=re.MULTILINE)
    for key, value in settings.items():
        if key not in seen:
            if updated and not updated.endswith('\n'):
                updated += '\n'
            updated += f'{key}="{value}"\n'
    if updated == original:
        return False
    if config.exists():
        backup = root / 'var/backups/plank-tablet-relay/cpufrequtils.before-powersave'
        backup.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        try:
            descriptor = os.open(backup, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        except FileExistsError:
            pass  # Keep the original across upgrades and reconfiguration.
        else:
            with os.fdopen(descriptor, 'wb') as destination, config.open('rb') as source:
                shutil.copyfileobj(source, destination)
    config.parent.mkdir(parents=True, exist_ok=True)
    previous = config.stat() if config.exists() else None
    descriptor, temporary = tempfile.mkstemp(prefix='.cpufrequtils.', dir=config.parent)
    try:
        with os.fdopen(descriptor, 'w') as output:
            if previous:
                os.fchown(output.fileno(), previous.st_uid, previous.st_gid)
            os.fchmod(output.fileno(), stat.S_IMODE(previous.st_mode) if previous else 0o644)
            output.write(updated)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, config)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    print('Configured Armbian CPU governor: powersave (enabled)', flush=True)
    return True


def main():
    try:
        configure_armbian()
        return 0
    except (OSError, ValueError) as error:
        print('Armbian host configuration failed: ' + str(error), file=sys.stderr)
        return 1
