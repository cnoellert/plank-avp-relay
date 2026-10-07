#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Verify a development-signed app without printing private profile contents."""
import argparse
import datetime
from pathlib import Path
import plistlib
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('app', type=Path)
parser.add_argument('--udid')
parser.add_argument('--bundle-id', default='la.instinctual.PLANK.AVPrelay',
                    choices=('la.instinctual.PLANK.AVPrelay', 'la.instinctual.PLANK.TabletSetup'))
args = parser.parse_args()
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(args.app)], check=True)
info = plistlib.loads((args.app / 'Info.plist').read_bytes())
profile = plistlib.loads(subprocess.check_output([
    'security', 'cms', '-D', '-i', str(args.app / 'embedded.mobileprovision')]))
entitlements = plistlib.loads(subprocess.check_output([
    'codesign', '--display', '--entitlements', ':-', str(args.app)], stderr=subprocess.DEVNULL))
bundle = args.bundle_id
if info.get('CFBundleIdentifier') != bundle or info.get('CFBundleSupportedPlatforms') != ['XROS']:
    parser.error('Expected the PLANK AVP Relay Setup device app.')
if profile.get('ExpirationDate', datetime.datetime.min) <= datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None):
    parser.error('Development provisioning profile has expired.')
if (not profile.get('ProvisionedDevices') or entitlements.get('get-task-allow') is not True
        or profile.get('Entitlements', {}).get('get-task-allow') is not True):
    parser.error('Expected a development-signed app with registered devices.')
identity = entitlements.get('application-identifier', '')
if (identity not in [prefix + '.' + bundle for prefix in profile.get('ApplicationIdentifierPrefix', [])]
        or profile.get('Entitlements', {}).get('application-identifier') not in
        (identity, identity.rsplit('.', 1)[0] + '.*',
         *[prefix + '.*' for prefix in profile.get('ApplicationIdentifierPrefix', [])])
        or entitlements.get('com.apple.developer.team-identifier') not in profile.get('TeamIdentifier', [])):
    parser.error('App and provisioning identity do not match.')
registration_group = info.get('PLANKRegistrationAccessGroup')
if registration_group:
    groups = entitlements.get('keychain-access-groups', [])
    allowed = profile.get('Entitlements', {}).get('keychain-access-groups', [])
    if (not groups or groups[0] != identity or registration_group not in groups or
            any(not any(value == group or (value.endswith('.*') and group.startswith(value[:-1]))
                        for value in allowed) for group in groups)):
        parser.error('Registration Keychain groups do not match app/profile permissions.')
if args.udid and args.udid not in profile['ProvisionedDevices']:
    parser.error('The selected headset is not included in this provisioning profile.')
print(f"PASS: development signature/profile for {info['CFBundleShortVersionString']} "
      f"build {info['CFBundleVersion']}" + (' and selected headset' if args.udid else ''))
