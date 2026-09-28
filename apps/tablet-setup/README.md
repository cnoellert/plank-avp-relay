# PLANK Tablet Setup — workflow lab

A standalone SwiftUI visionOS app for reviewing tablet-relay onboarding. Also
builds as a macOS UI preview. No workstation, remote desktop, Qt, SDL, FFmpeg or
Rust media transport is required. The app is **not** a full PLANK Client.

The app opens to relay discovery in the **Relay** tab. The **Local** tab tests
a tablet paired directly to the headset. There is no Simulation selector.
Synthetic state and input remain available only to developer tests and the
separate offscreen preview executable.

## Bluetooth pairing and readings

For a tablet-free hardware check, select the discovered relay and choose
**Test Bluetooth connection**. The relay can run
`python3 tools/ble-tablet-lab.py --transport-only` with no crypto-library,
identity-store or tablet arguments. The test sends three random payloads and
verifies1600returned bytes across three round trips. The tablet may be off;
there is no approval gesture. A passing byte test establishes communication,
without creating or verifying saved pairing trust. Progress/timeout messages
show which connection stage was reached and the last signal strength when
available. See the lab guide for its dedicated, bounded echo channels.

With the Linux [Bluetooth input lab](../../docs/bluetooth-headset-lab.md) running,
choose **Scan for relays**, select the relay and tap **Pair**. The app reports
actual tablet availability, a countdown and completed presses. Press and release
the tablet's Home/center button three times. If the tablet has no such button,
use the same supported tablet button three times. No manual pairing-window
checkbox or SSH signal is required. Use short presses, no more than two seconds
apart; holds, mixed buttons, sleep or cancellation reset progress.

After approval and key confirmation, the app saves the relay key and starts live
readings automatically. The screen shows pen position, pressure, tilt, Pad
buttons and touch count. Tablet sleep shows an offline state while retaining
trust; waking the same tablet resumes readings. Selection uses physical ancestry
and capabilities rather than a product-ID allowlist.

The three-press gesture authorizes the pending connection, but does not protect
initial enrollment against a nearby active attacker racing or intercepting it.
This is the operator-selected convenience tradeoff; do not describe it as the
same authentication guarantee as the old random challenge. Subsequent sessions
verify the saved key through Noise and encrypt readings. The BLE lab reuses the
existing CPace exchange with an explicitly public constant and a local
physical gate. The protocol and limits are documented in the lab guide.

This is a coalesced diagnostic readout, not raw-HID forwarding to a workstation
or a system-wide visionOS pointer. Legacy TCP pairing remains under
**Connect by network address**.

## Local tablet test

Pair the tablet in visionOS Settings, open **Local**, and choose **Start input
test**. Move the pen, vary pressure and press tablet buttons. This uses public
GameController pointer/stylus APIs and an in-window UIKit input surface. Device
names and event counts distinguish OS-exposed devices from unclassified window
events. Hand interactions and other mice can also produce window events; a
moving pointer does not establish pressure or ExpressKey support. Position on
the test surface is in window coordinates, not raw tablet coordinates. Stylus
and button polling is a diagnostic snapshot, not lossless event capture.

If no useful input arrives, expand **Inspect direct Bluetooth access**, scan,
and choose **Inspect** on the tablet. The probe discovers visible GATT services
and characteristics without reading values or writing tablet control commands.
**Listen** explicitly subscribes to one notification/indication characteristic
for up to60seconds and displays counts only. Reports are not decoded or logged.
A notification may be battery/status data, not a tablet report. Discovery takes
at most20seconds; an idle inspection closes after2minutes. Stop, leaving Local
or backgrounding cancels the probe and closes its app-owned connection.

The scan is not an inventory of all OS-paired devices. Classic HID reports may
be consumed or hidden by visionOS; copying the Linux driver's decoder cannot
make an unavailable transport accessible. The relay currently reads Linux evdev
input after the kernel driver has decoded it. Direct access to useful reports
must be established before porting driver decoding or initialization. No tablet
model, generation, Bluetooth address or proprietary report layout is assumed.

## Existing network/USB pairing

Explicit Live mode uses the current relay's real C CPace/Noise protocol and OS
Keychain. Enter the relay address/port. The existing daemon must already have
its manual `pair` window open; follow the root README as the service owner.
The existing daemon still selects PTH-660 for pairing. The app does not silently
relax that or pretend to detect other models on this legacy TCP path. The BLE lab instead requires a pen and at least one supported tablet button.

Use the **physical tablet** for the displayed sequence in Live mode. Trust is
stored only after the final cryptographic confirmation and after verifying
that the operation was not canceled. The test app uses a separate bundle ID
and Keychain namespace: it does not reuse or overwrite full-Client identities.
Pairing does not immediately create a tablet/Host session.

After pairing, the relay must return to `serve` mode for **Check connection**.
The check authenticates the saved key through Noise, reads the verified version
and closes. It never sends SESSION_READY, claims a tablet or invents Host
feature bits. The relay has one connection slot; do not check while a full
Client uses it. **Forget local pairing** removes only this app's local trust,
not the relay's approved Client key. Relay-side revocation is a future feature.
The current daemon rejects re-enrollment of an already-approved Client key;
after local forgetting or an interrupted final confirmation, relay-side removal
of that approval may be needed before pairing again. Do not forget working live
trust merely to explore the UI; use the developer preview for that exercise.

The app cancels an operation when it becomes inactive. Returning does not
silently retry pairing; saved identities survive and the user may retry.
No sequence, private key or raw tablet report is logged.

## Build

Use an authorized Apple Silicon builder with Xcode/SDK27+, CMake3.30+ and
the command-line tools selected for that Xcode. No personal signing IDs are
checked in. The following builds are unsigned by default:

```sh
bash scripts/build-tablet-setup.sh simulator
bash scripts/build-tablet-setup.sh device
bash scripts/build-tablet-setup.sh macos
```

The script downloads a SHA-256-pinned libsodium1.0.22 source archive, builds it
for the selected SDK and caches the verified library/headers by SDK/compiler
fingerprint under `build/tablet-setup/dependencies`. Jobs default to4; override
with positive `PLANK_BUILD_JOBS`. CMake/CTest paths may be supplied through
`CMAKE_COMMAND`/`CTEST_COMMAND`. `PLANK_TABLET_BUILD_ROOT` relocates all output.
The macOS build also runs pure Swift state and actual C protocol/crypto tests.
Loopback tests exercise the real Swift networking adapter against the C pairing
responder: fragmented records, saved-identity verification, wrong identity,
wrong sequence and cancellation. They never access devices or the app Keychain.
Existing Linux daemon builds and service behavior are unchanged.

Generated Xcode projects live in `build/tablet-setup/{simulator,device,macos}`.
The app is under the configuration's output directory; Xcode may add a platform
suffix, e.g. `Debug-xrsimulator/PLANK Tablet Setup.app`. The simulator requires
an installed compatible visionOS runtime; compilation alone does not install
one. Keep the simulator runtime separate from product dependencies.

For a physical headset, open the generated device Xcode project and select
the PLANK Tablet Setup target, your Apple development team, and the paired
headset. Enable signing for the app target, or reconfigure with
`-DPLANK_DEVELOPMENT_TEAM=YOUR_TEAM_ID` and build with Xcode's automatic
development provisioning. Device registration/provisioning must be available
to that account. macOS Developer ID/notarization cannot sign a visionOS app
for installation. Do not publish keys, certificates or provisioning profiles.

For the local macOS preview, apply an ad-hoc signature to the unsigned app
before opening it if required by the local launcher. This is a UI preview,
not evidence about gaze/pinch, headset behavior or Bluetooth hardware.

## TestFlight delivery

TestFlight is the selected headset delivery method. Ordinary build commands
above produce unsigned SDK bundles; the separate archive/export commands below
produce signed distribution packages. Neither is automatically available in
TestFlight. The app requires visionOS27; verify the tester's headset OS.
The archive command generates and includes application debug symbols. Both
archive and export/upload commands reject missing symbols or executable/dSYM
UUID mismatches before delivery.

Complete these gates before promising an invitation:

1. Configure usable Xcode developer-account access, or provision an App Store
   Connect API key privately. Installed signing certificates alone do not grant
   access to provisioning or uploads. Never put keys or profiles in this repo.
2. Validate the visionOS icon and distribution metadata, then archive the app
   target in Release. The app is included in archives; static libraries are not
   separate installable products. Use Apple distribution provisioning, not
   macOS Developer ID/notarization.
3. Create the visionOS app record for `la.instinctual.PLANK.TabletSetup` and
   complete the account owner's encryption questionnaire accurately. Live mode
   includes CPace/Noise/libsodium; do not claim the binary only uses OS-provided
   encryption or disable encryption to avoid the questionnaire.
4. Validate and upload through Xcode/App Store Connect. Wait for processing;
   external testers may require beta review. Increment the build number for
   every subsequent upload and retain the exact source revision.
5. Enter build-specific **What to Test** notes and complete export compliance
   as part of each delivery. The operator has authorized these metadata updates
   for future uploads. Reuse the confirmed questionnaire baseline in private
   deployment notes while encryption and distribution remain unchanged; do not
   infer an exemption from an answer about standard encryption. Verify the
   exact app, version and build before updating it, and report any incomplete
   metadata separately from successful binary upload.

Prepare tester notes alongside each build's source revision. Keep them focused
on changed behavior, testing steps and known limits. The notes for
[0.1.0 (3)](TestFlight/0.1.0-3.txt) are ready to enter. App Store Connect supports
build-specific notes through beta-build localizations and compliance through
build/encryption-declaration metadata. Automated API updates require separately
configured, supported App Store Connect access; an Xcode GUI account that can
upload does not establish API access. Keep API credentials outside Git and
never extract cached account tokens. Do not claim notes or compliance were
completed until the resulting metadata has been read back and verified.

Use `scripts/update-tablet-testflight.py` for the post-upload step on the
operator's automation machine (Python3 with `cryptography` installed). Its
default configuration is the private file
`~/.local/share/plank/private-notes/tablet-setup-asc.json`; use `--config` to
select another. Required fields are `key_id`, `issuer_id`, `private_key_path`,
`bundle_id` and `platform` (`VISION_OS`). Both config and key must be owned by
the current user with private permissions. Credentials stay on that machine;
they need not be copied to the Apple signing builder.

```sh
# Read only: verify access and inspect the exact build's existing classification.
python3 scripts/update-tablet-testflight.py --version 0.1.0 --build 3 --inspect
# After establishing the confirmed private compliance baseline:
python3 scripts/update-tablet-testflight.py --version 0.1.0 --build 3 \
  --notes apps/tablet-setup/TestFlight/0.1.0-3.txt
```

The private `compliance` object contains the confirmed boolean
`uses_non_exempt_encryption`. Non-exempt encryption also requires a
`declaration_id`; the helper verifies that it belongs to this app and is
approved. Optional `answers` are matched against that declaration. Establish
this baseline from the operator's answers and Apple's resulting metadata,
never by guessing from the cryptography library name. Reassess it if encryption
or distribution changes. The helper refuses to overwrite a conflicting
classification already entered on a build.

For each future upload, prepare the new notes file and run the helper with that
exact version/build once Xcode finishes uploading. It waits up to ten minutes
for processing, updates notes idempotently, and reads back notes and compliance
before reporting success. Retry later if Apple is still processing. This step
does not invite testers, change groups or submit a public release. Offline
verification is `python3 tests/testflight_metadata_test.py`.

```sh
# Team is provided privately; choose a new number for each uploaded build.
export PLANK_SETUP_BUILD_NUMBER=1
bash scripts/archive-tablet-setup.sh
bash scripts/export-tablet-setup.sh \
  build/tablet-setup/archives/PLANK-Tablet-Setup-1.xcarchive \
  build/tablet-setup/exports/build-1
# Explicit upload, after creating the App Store Connect visionOS app record:
bash scripts/export-tablet-setup.sh --upload \
  build/tablet-setup/archives/PLANK-Tablet-Setup-1.xcarchive \
  build/tablet-setup/uploads/build-1
```

The archive script requires `PLANK_DEVELOPMENT_TEAM` from the private build
environment. Export uses the archive's team. Existing output directories are
not overwritten; use a fresh output directory when retrying a failed upload.
Xcode must have access to its account and the signing key in the build session.
An SSH security session can report a locked keychain even after a GUI unlock;
run signing in the authorized logged-in GUI session rather than resetting the
keychain, extracting a password or weakening key access controls. Any temporary
GUI build job must be one-shot and unloaded after it exits, not an installed
autostart service.

The visionOS layered icon is compiled from generated PNGs. Readable SVG sources
stay in `Artwork/`; the native AppKit build helper rasterizes them only into the
ignored build directory. Direct SVG layers are not valid inputs to this asset
compiler. Static libraries are never separately signed/installed in the archive.
Bundle checks verify the actual compiled icon, scene manifest, version, privacy
declaration and licenses before export. Upload completion still does not prove
TestFlight processing, compliance approval or headset qualification.

For internal testing, assign the uploaded build to the same TestFlight group
as the tester. **No Builds Available** on a tester entry can mean this
assignment is missing; creating the tester alone is insufficient. Accept the
invitation on the headset using **View in TestFlight → Accept → Install**.
If an invitation has not arrived, check both group membership and build
assignment before resending it. Start with relay discovery; an installation
or successful invitation is not live tablet/relay qualification.

Apple references: [uploading builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds)
and [export compliance](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance).

## Acceptance checklist

- The app opens directly to relay discovery, with no Simulation selector.
- Pair requests a single bounded approval and shows actual relay status.
- Three completed short presses authorize only the current request.
- Timeout, interruption, cancel and backgrounding are recoverable.
- No stale callback can save trust after cancellation or mode/relay changes.
- Existing trust survives failed reconnect; identity mismatch does not replace it.
- Readings start after pairing, using saved-key authentication and no workstation session.
- Test the actual authorization button on each supported physical layout.

See `docs/visionos-tablet-setup.plan` for the subsequent daemon/Bluetooth work.
