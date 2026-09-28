#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 OUTPUT_DIRECTORY" >&2
    exit 2
fi
source_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
mkdir -p "$1"
output_root=$(CDPATH= cd -- "$1" && pwd)
probe_bundle="$output_root/PLANK Bluetooth Probe.app"
mkdir -p "$probe_bundle/Contents/MacOS"
cat > "$probe_bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>la.instinctual.PLANK.BluetoothProbe</string>
<key>CFBundleName</key><string>PLANK Bluetooth Probe</string>
<key>CFBundleExecutable</key><string>plank-ble-echo</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>2</string>
<key>LSMinimumSystemVersion</key><string>27.0</string>
<key>NSBluetoothAlwaysUsageDescription</key><string>Test a nearby PLANK relay by exchanging generated diagnostic bytes over Bluetooth.</string>
</dict></plist>
PLIST
xcrun swiftc -swift-version 6 -target arm64-apple-macos27.0 \
    "$source_root/tools/macos-ble-echo/main.swift" \
    "$source_root/tools/macos-ble-echo/Peripheral.swift" \
    -framework AppKit -framework CoreBluetooth \
    -o "$probe_bundle/Contents/MacOS/plank-ble-echo"
codesign --force --sign - "$probe_bundle"
codesign --verify --strict "$probe_bundle"
echo "$probe_bundle"
