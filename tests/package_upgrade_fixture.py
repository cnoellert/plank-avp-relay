# SPDX-License-Identifier: GPL-3.0-or-later
"""Exercise apt's package rename and the real postinst in disposable CI only."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

if os.environ.get('GITHUB_ACTIONS') != 'true' or os.geteuid() != 0:
    raise SystemExit('This fixture is restricted to a disposable root CI container.')

scratch = Path('/tmp/plank-namespace-upgrade')
old = Path('/var/lib/plank-tablet-relay-ble')
new = Path('/var/lib/plank-avp-relay')
old_config = Path('/etc/plank-tablet-relay-ble/relay.conf')
new_config = Path('/etc/plank-avp-relay/relay.conf')

if sys.argv[1] == 'prepare':
    assert not old.exists() and not new.exists(), 'Refuse existing relay state'
    scratch.mkdir(mode=0o700)
    extracted = scratch/'extracted'
    subprocess.run(['dpkg-deb', '-x', sys.argv[2], str(extracted)], check=True)
    sys.path.insert(0, str(extracted/'usr/lib/plank-avp-relay'))
    from avp_relay.native import Native
    old.mkdir(mode=0o700)
    native = Native(extracted/'usr/lib/plank-avp-relay/libplank_avp_relay.so', old)
    public = native.public_key
    native.close()
    (old/'paired-clients.json').write_text(json.dumps({'version':1, 'clients':['12'*32]}, separators=(',', ':')))
    (old/'paired-clients.json').chmod(0o600)
    (old/'tablets.json').write_text('{"version":1,"selected":"AA:BB:CC:DD:EE:FF","tablets":["AA:BB:CC:DD:EE:FF"],"pending":null}')
    native = Native(extracted/'usr/lib/plank-avp-relay/libplank_avp_relay.so', old)
    assert native.public_key == public and native.has_clients, 'Previous state must be valid before migration'
    native.close()
    expected = {'public':public, 'files':{p.name:p.read_bytes().hex() for p in old.iterdir()}}
    (scratch/'expected.json').write_text(json.dumps(expected))
    # A minimal previous package supplies its real conffile namespace. apt must
    # remove this conflicting name; postinst must retain its customized config.
    fixture = scratch/'previous'
    (fixture/'DEBIAN').mkdir(parents=True)
    (fixture/'DEBIAN/control').write_text(
        'Package: plank-tablet-relay-ble\nVersion: 0.3.0~visionos-tablet-setup\n'
        'Architecture: all\nMaintainer: PLANK CI <ci@example.invalid>\n'
        'Description: Previous package namespace fixture\n')
    (fixture/'DEBIAN/conffiles').write_text(str(old_config)+'\n')
    packaged = fixture/str(old_config).lstrip('/')
    packaged.parent.mkdir(parents=True)
    packaged.write_text('[relay]\n')
    subprocess.run(['dpkg-deb', '--build', str(fixture), str(scratch/'previous.deb')], check=True)
    subprocess.run(['dpkg', '-i', str(scratch/'previous.deb')], check=True)
    old_config.write_text('[relay]\nname = Upgrade fixture\ntcp_port = 29991\n')
    # An earlier clean install left default conffiles after removal. They must
    # be eligible for migration even though dpkg retains them on this install.
    new_config.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(extracted/'etc/plank-avp-relay/relay.conf', new_config)
elif sys.argv[1] == 'verify':
    sys.path.insert(0, '/usr/lib/plank-avp-relay')
    from avp_relay.native import Native
    expected = json.loads((scratch/'expected.json').read_text())
    for name, value in expected['files'].items():
        assert (old/name).read_bytes().hex() == value
        assert (new/name).read_bytes().hex() == value
        assert (new/name).stat().st_mode & 0o777 == 0o600
    native = Native(Path('/usr/lib/plank-avp-relay/libplank_avp_relay.so'), new)
    assert native.public_key == expected['public'] and native.has_clients
    native.close()
    assert new_config.read_bytes() == old_config.read_bytes()
    assert (new/'namespace-migration.json').is_file()
    result = subprocess.run(['dpkg-query', '-W', '-f=${Status}', 'plank-tablet-relay-ble'],
                            capture_output=True, text=True)
    assert result.stdout != 'install ok installed'
    print('apt replaced the old package; native identity, approval and configuration survived.')
else:
    raise SystemExit('Expected prepare or verify')
