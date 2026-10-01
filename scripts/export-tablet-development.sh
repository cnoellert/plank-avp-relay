#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Local development export only; never uploads to App Store Connect.
set -euo pipefail
relay_root=$(cd "$(dirname "$0")/.." && pwd)
if [[ $# != 2 || ! -d "$1/Products/Applications/PLANK AVP Relay Setup.app" ]]; then
    echo "Usage: $0 archive.xcarchive new-output-directory" >&2
    exit 2
fi
archive_path=$1
export_path=$2
[[ ! -e "$export_path" ]] || { echo "Output directory already exists." >&2; exit 1; }
python3 "$relay_root/scripts/check-tablet-setup-bundle.py" \
    "$archive_path/Products/Applications/PLANK AVP Relay Setup.app" --platform device
codesign --verify --deep --strict "$archive_path/Products/Applications/PLANK AVP Relay Setup.app"
python3 "$relay_root/scripts/check-tablet-setup-symbols.py" "$archive_path"
umask 077
mkdir -p "$export_path"
python3 - "$export_path/ExportOptions.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'wb') as output:
    plistlib.dump({'method': 'debugging', 'destination': 'export',
                  'signingStyle': 'automatic', 'stripSwiftSymbols': False}, output)
PY
xcodebuild -exportArchive -archivePath "$archive_path" -exportPath "$export_path" \
    -exportOptionsPlist "$export_path/ExportOptions.plist" -allowProvisioningUpdates
shopt -s nullglob
packages=("$export_path"/*.ipa)
[[ ${#packages[@]} == 1 ]] || { echo "Expected exactly one exported IPA." >&2; exit 1; }
ditto -x -k "${packages[0]}" "$export_path/unpacked"
app="$export_path/unpacked/Payload/PLANK AVP Relay Setup.app"
python3 "$relay_root/scripts/check-tablet-development.py" "$app"
printf '\nDevelopment app: %s\nNo TestFlight upload.\n' "$app"
