# PLANK AVP Relay Setup — workflow lab

A standalone SwiftUI visionOS app for reviewing tablet-relay onboarding. Also
builds as a macOS UI preview. No workstation, remote desktop, Qt, SDL, FFmpeg or
Rust media transport is required. The app is **not** a full PLANK Client.

The app opens directly to concurrent Bonjour and Bluetooth discovery. Network
services appear after a read-only reachability/identity probe and are checked
every three seconds; results expire after eight seconds without a successful
probe. Bluetooth entries expire five seconds after the last advertisement.
These are expiry bounds, not a fixed startup delay. Saved credentials are retained for reconnection, but offline
saved relays are not listed. There are no Local or Simulation tabs. Connection tests and
pairing management are in expandable sections.
Synthetic readout fixtures exist only in the separate offscreen preview executable.
The shipping app supports encrypted TCP and Bluetooth connections.

The tab order is **Select Relay → Tablet → Network**. Select Relay opens
first with its own antenna icon; Tablet and Network are disabled until a relay
is selected. Switching tabs retains the selection. Network identifies the
selected relay and requires tablet setup authorization before showing controls.
Unknown Wi-Fi status is never rendered as an off switch, and an unknown USB
mode is not presented as a selected configuration.
Network mode is an editable Bridge/Router selector with Apply changes. Its
separate Connection status group uses read-only Ethernet and USB labels/icons,
with a Refresh status action and automatic four-second refresh while idle.
An authorized headset can change mode without another pairing step; finish
tablet setup first on a new relay. Stop readings/other tablet operations before
network management. Unsupported gadget hardware is reported without changing
its network configuration.

Bluetooth control is preferred when available. After Apply, the app confirms
the durable request UUID and saved mode on the same authenticated relay,
rediscovering changed network endpoints as needed. It never blindly retries a
mode mutation after a lost connection. Stop waiting only stops monitoring:
accepted changes finish on the relay and can be checked with Refresh status.
USB is withdrawn when Ethernet link disappears; Internet access is irrelevant.
See [USB appliance configuration](../../docs/linux-ble-package.md#usb-ethernet-appliance-040).

Release 0.5.0 adds Wi-Fi on/off, scan/select/join, hidden networks, saved
networks, password updates and Forget in Network. Secured network rows show
only a lock; open rows have no security label. Wi-Fi connection/address status
is a separate read-only group. Profile passwords are cleared from the join
sheet when submitted/dismissed and are never saved in the app. Idle polling
pauses while entering network details. USB and Wi-Fi status share one
authenticated connection per poll; paginated lists refresh separately.
The same durable receipt/reconnection rules apply to Wi-Fi changes. See
[Wi-Fi configuration and acceptance](../../docs/wifi-management.md).

The visible version uses `Major.Minor.Ancillary` followed by the branch
description, for example `0.5.5-main`. The numeric version is
defined once in the repository's `VERSION` file and shared with the relay
package. Increment Ancillary for delivered fixes and
small refinements, Minor for features, and Major for substantial or incompatible
changes. Apple’s separate, increasing upload build number stays in bundle
metadata and build records; it is not appended to the app’s visible version.
App and Linux package versions advance together, including app-only fixes.

Release 0.5.1 checks the selected relay's authorization and tablet status
before enabling **Test Tablet**, then rechecks status before opening
input. A selected paired tablet may be asleep; an attached USB tablet also
qualifies. A saved headset record alone does not enable readings.
If an OS reinstall changes the relay identity at the same address, choose
**Forget saved relay** in the reported identity-change recovery, confirm the
replacement, then set up its tablet again. This clears the old relay's pending,
canonical and transport pins while retaining other relays and the headset key.

## Network and Bluetooth pairing and readings

Allow Local Network access to discover `_plank-avp-relay._tcp` services. A relay
on Ethernet and a headset on Wi-Fi can connect when the LAN permits discovery
and device-to-device traffic. The app prefers reachable TCP endpoints. A known
relay public key joins its network and Bluetooth entries; a unique matching
name can group unverified discovery candidates, but grants no trust. Ambiguous
names or known distinct identities stay separate. Any fallback must prove the
selected relay key before an operation is authorized.

Ownership is shared across transports. Existing BLE Keychain records and the
headset private key are retained; authenticated enrollment also records the
relay key independently of its address. Discovery claims alone are never
written as approved keys. Network address/service-name changes retain trust.

Readings recover through at most three fresh connection attempts after a
transport failure, alternating available endpoints. A working stream is kept;
the app does not switch it just because TCP appears later. Identity/protocol
failures stop recovery. Interrupted setup mutations are not replayed: reopen
Manage tablets to inspect saved state. A read-only preflight can try another
transport before starting setup. See [network service details](../../docs/linux-ble-package.md).

For a tablet-free hardware check, select the discovered relay and choose
**Connection diagnostics → Test relay connection**. The Bluetooth-only lab can run
`python3 tools/ble-tablet-lab.py --transport-only` with no crypto-library,
identity-store or tablet arguments. The test sends three random payloads and
verifies 1,600 returned bytes across three round trips. The tablet may be off;
there is no approval gesture. A passing byte test establishes communication,
without creating or verifying saved pairing trust. Progress/timeout messages
show which connection stage was reached and the last signal strength when
available. See the lab guide for its dedicated, bounded echo channels.

Connection startup recovers once if the previous physical Bluetooth link closes
before the new reply subscription is ready. The fresh attempt uses the original
20-second deadline. This handles a setup/approval transition where CoreBluetooth
briefly reuses a link that Linux is still closing. Recovery happens before any
authorization or input protocol bytes are sent; established sessions and
protocol failures are not replayed. Live readings expose the same progress
messages, and connection-stage logs contain no identifiers, keys or input.

With [relay package revision 14 or newer](../../docs/linux-ble-package.md),
select the relay, choose **Find tablets to pair**, put the tablet into pairing
mode, and select it. Successful bond/vendor/HID/input verification automatically
saves the headset that initiated setup. The app proceeds to live readings with
no three-circle or tablet-button confirmation. Existing owners use **Manage
tablets** to replace a tablet without losing headset authorization.
Discovery and saved tablet rows show the Bluetooth MAC address below the name,
including when a saved tablet is offline. Removal confirmation also includes
the address so tablets with identical names can be distinguished.

The read-only setup endpoint supplies the public relay identity. Mutations use
a restricted Noise session; tablet verification promotes only its initiating
headset key to persistent ownership. Readings open a fresh authenticated
connection. Initial identity pinning is trust on first use, not out-of-band
verification of a nearby relay. Existing pins are never silently replaced.
The same private headset identity can restore a lost local relay key when the
relay still approves it; unknown headset keys require an explicit SSH ownership
reset. See [headless setup and recovery](../../docs/bluetooth-tablet-pairing.md).

The screen shows pen position, pressure, tilt, Pad buttons and touch count.
Tablet sleep retains the bond and headset ownership. Selection uses physical
ancestry and capabilities rather than a product-ID allowlist.

This is a coalesced diagnostic readout, not raw-HID forwarding to a workstation
or a system-wide visionOS pointer. Discovery, setup and readings support both transports.

## Direct tablet experiment

Build 5 explored a tablet paired directly to visionOS. The operator confirmed
Settings showed the tablet connected, but no useful pen, pressure or button
input reached the app, and the tablet was not found in its BLE scan. Build 6
removes that unsuccessful experiment and focuses on the verified Linux relay
path. Its source remains in Git history at `606d5bd`.

## Saved pairing

Setup and readings use the existing C Noise implementation and the app's
Keychain namespace. Updates retain Bluetooth account identifiers and the Client
key. A provisional relay pin is stored before tablet changes, so interruption
after relay-side approval can recover using the same headset identity. The
normal ownership transfer uses an explicit SSH reset. After an identity-change
error, the targeted **Forget saved relay** action recovers a reinstalled or
replaced relay; it does not transfer ownership of an unchanged relay.

Stop readings before using **Check authorization** or **Test Bluetooth
connection**. Cancel, interruption and backgrounding preserve saved identities;
returning to the app does not silently retry an operation. No sequence, private
key or raw tablet report is logged.

The upstream TCP/raw-HID workstation relay remains a separate component. The
Test app no longer includes its address/port controls, TCP client, manual
five-key flow, or local-network permission request. Shared protocol and
cryptographic code remain available to that upstream component.

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
Workflow tests cover canceled/stale operations, retained Bluetooth Keychain account
identifiers, observation and the distinction between byte echo and saved trust.
Connection tests reproduce early link closure, require cleanup before retry,
preserve the original deadline, and cover retry limits and cancellation.
Native C tests cover the shared pairing, framing and Noise implementation.
These tests do not access the app Keychain or Bluetooth devices.
Existing Linux daemon builds and service behavior are unchanged.

Generated Xcode projects live in `build/tablet-setup/{simulator,device,macos}`.
The app is under the configuration's output directory; Xcode may add a platform
suffix, e.g. `Debug-xrsimulator/PLANK AVP Relay Setup.app`. The simulator requires
an installed compatible visionOS runtime; compilation alone does not install
one. Keep the simulator runtime separate from product dependencies.

For a physical headset, open the generated device Xcode project and select
the PLANK AVP Relay Setup target, your Apple development team, and the paired
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
[0.1.0 (6)](TestFlight/0.1.0-6.txt) cover the simplified relay workflow. App Store Connect supports
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
python3 scripts/update-tablet-testflight.py --version 0.1.0 --build 6 --inspect
# After establishing the confirmed private compliance baseline:
python3 scripts/update-tablet-testflight.py --version 0.1.0 --build 6 \
  --notes apps/tablet-setup/TestFlight/0.1.0-6.txt
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
export PLANK_SETUP_BUILD_NUMBER=7
bash scripts/archive-tablet-setup.sh
bash scripts/export-tablet-setup.sh \
  build/tablet-setup/archives/PLANK-Tablet-Setup-7.xcarchive \
  build/tablet-setup/exports/build-7
# Explicit upload, after creating the App Store Connect visionOS app record:
bash scripts/export-tablet-setup.sh --upload \
  build/tablet-setup/archives/PLANK-Tablet-Setup-7.xcarchive \
  build/tablet-setup/uploads/build-7
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
- First-time tablet setup authorizes its initiating headset without a second gesture.
- Removing every tablet preserves ownership and offers replacement pairing.
- Timeout, interruption, cancel and backgrounding are recoverable.
- No stale callback can save trust after cancellation or mode/relay changes.
- Existing trust survives failed reconnect; identity mismatch does not replace it.
- Readings start after pairing, using saved-key authentication and no workstation session.
- Verify pen position, pressure and tablet buttons after combined enrollment.

See `docs/visionos-tablet-setup.plan` for the subsequent daemon/Bluetooth work.

## Headless tablet enrollment

Select the relay hostname to view its tablet setup status. On an unconfigured
relay, **Find tablets to pair** starts bounded discovery; select the intended
tablet in pairing mode. Linux verifies the bond and input capabilities, saves
the initiating headset and allows the app to start readings. An approved
headset can stop readings and use **Manage tablets** to reconnect, select or
remove saved tablets. Sleeping tablets remain saved.

Use package revision 14 or later for combined setup. Older relays remain usable
for saved-key readings but cannot perform the new automatic enrollment.
No hardware button or web UI is required; explicit SSH recovery commands are
in [the tablet enrollment guide](../../docs/bluetooth-tablet-pairing.md).
