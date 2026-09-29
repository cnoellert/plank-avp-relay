#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Archives only. Export/upload needs a separate explicit invocation and account
# access; no private team, credential, tester or provisioning profile is stored.
set -euo pipefail
relay_root=$(cd "$(dirname "$0")/.." && pwd)
: "${PLANK_DEVELOPMENT_TEAM:?Set your Apple development team outside Git}"
: "${PLANK_SETUP_BUILD_NUMBER:?Set the next TestFlight build number}"
[[ $PLANK_SETUP_BUILD_NUMBER =~ ^[1-9][0-9]*$ ]] || exit 2
build_root=${PLANK_TABLET_BUILD_ROOT:-"$relay_root/build/tablet-setup"}
archive_path="$build_root/archives/PLANK-Tablet-Setup-$PLANK_SETUP_BUILD_NUMBER.xcarchive"
[[ ! -e "$archive_path" ]] || { echo "Archive already exists; choose a new build number." >&2; exit 1; }
bash "$relay_root/scripts/build-tablet-setup.sh" device
"${CMAKE_COMMAND:-cmake}" -S "$relay_root/apps/tablet-setup" -B "$build_root/device" \
    -DPLANK_DEVELOPMENT_TEAM="$PLANK_DEVELOPMENT_TEAM" \
    -DPLANK_SETUP_BUILD_NUMBER="$PLANK_SETUP_BUILD_NUMBER"
mkdir -p "$build_root/archives"
xcodebuild archive -project "$build_root/device/PlankTabletSetup.xcodeproj" \
    -scheme PlankTabletSetup -configuration Release \
    -destination 'generic/platform=visionOS' -archivePath "$archive_path" \
    -allowProvisioningUpdates
# CMake places dSYMs in its configuration output directory. Xcode's archive
# collector does not include that custom location, so stage the companion here;
# the UUID check below rejects stale symbols or a mismatched executable.
symbols="$build_root/device/Release-xros/PLANK AVP Relay Setup.app.dSYM"
[[ -d "$symbols" ]] || { echo "Application dSYM was not generated." >&2; exit 1; }
ditto "$symbols" "$archive_path/dSYMs/PLANK AVP Relay Setup.app.dSYM"
python3 "$relay_root/scripts/check-tablet-setup-symbols.py" "$archive_path"
printf '\nArchived: %s\nNot uploaded to TestFlight.\n' "$archive_path"
