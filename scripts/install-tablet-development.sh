#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Run on the Mac paired with the headset. Updates in place; never uninstalls.
set -euo pipefail
relay_root=$(cd "$(dirname "$0")/.." && pwd)
if [[ $# != 2 || ! -d "$1" ]]; then
    echo "Usage: $0 signed.app headset-identifier" >&2
    exit 2
fi
app=$1
device=$2
umask 077
work=$(mktemp -d "${TMPDIR:-/tmp}/plank-direct-install.XXXXXX")
trap 'rm -rf "$work"' EXIT
xcrun devicectl device info details --device "$device" --timeout 30 --json-output "$work/device.json" >/dev/null
udid=$(python3 - "$work/device.json" <<'PY'
import json, sys
device = json.load(open(sys.argv[1]))['result']
udid = device['hardwareProperties']['udid']
if not isinstance(udid, str) or not udid:
    raise SystemExit('Could not identify the selected headset.')
print(udid)
PY
)
python3 "$relay_root/scripts/check-tablet-setup-bundle.py" "$app" --platform device
python3 "$relay_root/scripts/check-tablet-development.py" "$app" --udid "$udid"
xcrun devicectl device install app --device "$device" "$app" --timeout 120
printf '\nInstalled directly. Open PLANK AVP Relay Setup on the headset.\nNo TestFlight upload.\n'
