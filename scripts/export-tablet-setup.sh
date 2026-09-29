#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Uses the archive's team and Xcode account; no credentials are passed in argv.
set -euo pipefail
relay_root=$(cd "$(dirname "$0")/.." && pwd)
destination=export
if [[ ${1:-} == --upload ]]; then destination=upload; shift; fi
if [[ $# != 2 || ! -d "$1/Products/Applications/PLANK AVP Relay Setup.app" ]]; then
    echo "Usage: $0 [--upload] archive.xcarchive new-output-directory" >&2
    exit 2
fi
archive_path=$1
export_path=$2
[[ ! -e "$export_path" ]] || { echo "Output directory already exists." >&2; exit 1; }
python3 "$relay_root/scripts/check-tablet-setup-bundle.py" \
    "$archive_path/Products/Applications/PLANK AVP Relay Setup.app" --platform device
codesign --verify --deep --strict "$archive_path/Products/Applications/PLANK AVP Relay Setup.app"
python3 "$relay_root/scripts/check-tablet-setup-symbols.py" "$archive_path"
mkdir -p "$export_path"
options="$export_path/ExportOptions.plist"
cp "$relay_root/apps/tablet-setup/ExportOptions.plist" "$options"
plutil -replace destination -string "$destination" "$options"
xcodebuild -exportArchive -archivePath "$archive_path" -exportPath "$export_path" \
    -exportOptionsPlist "$options" -allowProvisioningUpdates
if [[ $destination == upload ]]; then
    echo "Upload completed. Check App Store Connect processing, encryption compliance and tester availability."
else
    echo "Export completed. This does not upload or invite TestFlight testers."
fi
