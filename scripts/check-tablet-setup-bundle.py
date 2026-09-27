#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Check the built bundle, not merely its source templates."""
import argparse
import plistlib
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("bundle", type=Path)
parser.add_argument("--platform", choices=("device", "simulator", "macos"), required=True)
args = parser.parse_args()
contents = args.bundle / "Contents" if args.platform == "macos" else args.bundle
resources = contents / "Resources" if args.platform == "macos" else contents
with (contents / "Info.plist").open("rb") as source:
    info = plistlib.load(source)
assert info["CFBundleIdentifier"] == "la.instinctual.PLANK.TabletSetup"
assert f'({info["CFBundleVersion"]})' in info["PLANKSetupVersion"]
assert "visionos-tablet-setup" in info["PLANKSetupVersion"]
with (resources / "PrivacyInfo.xcprivacy").open("rb") as source:
    privacy = plistlib.load(source)
assert privacy["NSPrivacyTracking"] is False
assert privacy["NSPrivacyAccessedAPITypes"][0]["NSPrivacyAccessedAPITypeReasons"] == ["CA92.1"]
for name in ("LICENSE", "NOTICE.md", "libsodium-LICENSE.txt"):
    assert (resources / "licenses" / name).stat().st_size > 0
if args.platform != "macos":
    assert (resources / "Assets.car").stat().st_size > 0
    assert "UIApplicationSceneManifest" in info
    assert info["UIDeviceFamily"] == [7]
    assert info["MinimumOSVersion"] == "27.0"
    assert info["CFBundleSupportedPlatforms"] == ["XROS" if args.platform == "device" else "XRSimulator"]
print(f"PASS: {args.platform} bundle metadata, privacy declaration and resources")
