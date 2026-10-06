# PLANK AVP Relay Setup — workflow lab

A standalone SwiftUI visionOS app for reviewing tablet-relay onboarding. Also
builds as a macOS UI preview. No workstation, remote desktop, Qt, SDL, FFmpeg or
Rust media transport is required. The app is **not** a full PLANK Client.

The app opens directly to concurrent Bonjour and Bluetooth discovery. Network
services appear after a read-only reachability/identity probe and are checked
every three seconds; results expire after eight seconds without a successful
probe. Bluetooth entries expire five seconds after the last advertisement.
These are expiry bounds, not a fixed startup delay. Saved credentials are retained for reconnection, but offline
saved relays are not listed. There are no Local or Simulation tabs.
Connection Diagnostics is a permanent section on the main Tablet page; it is
not repeated inside Manage Tablets. Test progress,
success and failure stay beside their buttons; running a test does not replace
the page or hide its result. Check Headset Authorization reads the relay's
explicit saved approval over the authenticated connection. It never treats a
successful handshake alone as approval. Recovery instructions are in the same
section; there is no separate Headset Authorization section.
Synthetic readout fixtures exist only in the separate offscreen preview executable.
The shipping app supports encrypted TCP and Bluetooth connections.

The tab order is **Select Relay → Tablet → Network**. Select Relay opens
first with its own antenna icon; Tablet and Network are disabled until a relay
is selected. Switching tabs retains the selection. Network identifies the
selected relay and requires tablet setup authorization before showing controls.
Unknown Wi-Fi status is never rendered as an off switch, and an unknown USB
mode is not presented as a selected configuration.

Leaving Tablet for Select Relay or Network automatically stops an active or
connecting tablet test. The destination waits for its connection to close
before relay selection or network refresh becomes available. The same path handles
**Stop Testing**, including a test still connecting. Returning to Tablet does
not restart testing. Relay selection and saved authorization are retained.
Use the Select Relay tab to change relays; there is no duplicate footer button.
Network mode is an editable Bridge/Router selector with Apply changes. Its
separate Connection status group uses read-only Ethernet and USB labels/icons,
with a Refresh status action and automatic refresh ten seconds after each idle
refresh completes. Failed refreshes retain the last confirmed settings and show
that the app is reconnecting.
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

Wi-Fi has one **Join Network…** action alongside its enable toggle. It opens
a picker and starts a fresh scan automatically; old results are cleared while
the scan runs. Nearby networks are selectable rows with signal strength and a
lock for secured networks. Saved networks reuse credentials; new networks open
a Join/password form. The picker contains a small Scan Again icon, pagination
and **Other Network…** for entering a hidden network. Back returns from the
password form without starting another scan. Passwords are cleared on Back,
Cancel, dismissal and submission; background polling stays paused throughout
the picker/form. Only a submitted Join/connect changes the selected network.
If Wi-Fi is off, unknown or unavailable, Join remains visible but disabled and
the current status/reason is shown. A missing adapter is not presented as an
off toggle. Saved-network menus omit Connect for the current network.

Wi-Fi supports on/off, scan/select/join, hidden networks, saved
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

## USB tablets

Connect a supported Wacom tablet to a USB host port on the relay. Linux input
capabilities identify the pen, pressure and optional pad/touch interfaces; no
model or generation is hardcoded. A single USB tablet takes priority over the
saved Bluetooth selection. Its name, USB connection and serial number (or USB
port when no serial is available) appear in Manage Tablets. USB devices have
no invented Bluetooth MAC address or pairing/removal action: unplug to detach.
Multiple USB tablets require selection if none is already active. Explicit
administrator selection in relay.conf remains authoritative.

Existing authorized headsets can test USB input immediately. On first setup,
choose Finish Setup for the connected USB tablet; only its initiating encrypted
session gains authorization after input opens successfully. Existing ownership
still requires the saved headset identity or the documented SSH ownership reset.
The read-only discovery endpoint cannot authorize a headset.

No Bluetooth adapter is required for USB input over TCP. Bluetooth discovery
and saved-tablet actions are unavailable while the adapter is absent, without
resetting the relay identity, network connection or saved Bluetooth bonds.
Unplugging clears the current readings; replugging restores USB capture and
removing USB allows the saved Bluetooth tablet to resume when available.
Use Manage Tablets or Check tablet status to refresh after plugging a tablet
into an idle main Tablet page. During testing, input hotplug is automatic.

On a host also running the raw PLANK tablet relay, discovery and tablet status
remain available while PLANK owns input. Setup reports capture as busy and
defers tablet scan, pairing, selection and live testing until that session
stops. Authorized network controls remain available from the Network tab.
The relay's `attached` status describes physically detected input while
idle; `captureActive` reports open managed input nodes, and `captureBusy`
reports a different service holding input. See the
[shared Linux capture behavior](../../docs/linux-ble-package.md#sharing-a-linux-host-with-the-raw-plank-relay).

## Network and Bluetooth pairing and readings

Allow Local Network access to discover `_plank-avp-relay._tcp` services. A relay
on Ethernet and a headset on Wi-Fi can connect when the LAN permits discovery
and device-to-device traffic. The app prefers reachable TCP endpoints. A known
relay public key joins its network and Bluetooth entries; a unique matching
name can group unverified discovery candidates, but grants no trust. Ambiguous
names or known distinct identities stay separate. Any fallback must prove the
selected relay key before an operation is authorized.

Authenticated tablet status also returns the active TCP port and up to eight
local listener addresses to the authorized headset. The app learns these during
existing tablet management, status refresh and test status requests, including
over Bluetooth. Starting a tablet test adds no discovery probe or extra status
connection. Learned routes are available for subsequent connection selection;
they do not interrupt the current stream. Each new connection verifies the same
relay key. This permits discovery when Bonjour cannot cross subnets; the LAN
must still permit routed TCP traffic. Loopback, link-local, multicast and
nonliteral addresses are rejected.
New status replaces old literal routes after DHCP or interface changes. Older
relays retain the existing Bonjour and authenticated Wi-Fi status behavior.

Address enumeration respects the installed Linux service's restrictions.
Unavailable optional route hints leave authenticated status usable.

Changing addresses never creates new authorization. USB Ethernet still follows
the physical Ethernet cable; relay Wi-Fi is not forwarded to USB. Physical cable
handover needs device acceptance testing.

Ownership is shared across transports. Existing BLE Keychain records and the
headset private key are retained; authenticated enrollment also records the
relay key independently of its address. Discovery claims alone are never
written as approved keys. Network address/service-name changes retain trust.

Tablet startup allows at most four attempts. It prefers known working network
routes, but tries Bluetooth after at most two network candidates when available.
Bluetooth-only testing filters out network candidates before any connection.
After readings begin, up to three stream recoveries have their own bounded
startup attempts, first retrying the route that delivered readings. Initial
failures do not spend this recovery allowance. A working stream is kept; the
app does not switch it just because TCP appears later. Identity/protocol
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
show which connection stage was reached. Discovery also reports signal strength
when available. See the lab guide for its dedicated, bounded echo channels.

The byte diagnostic opens its echo channel directly and sends all three
payloads over that connection. It does not run a preliminary status/identity
lookup or use tablet setup. Automatic routing may try the next available route
after closing a failed one; Bluetooth-only mode remains restricted to Bluetooth.
Cancellation waits for connection cleanup before enabling another operation.
The byte test does not establish saved trust; Check Headset Authorization
performs that separate authenticated check.

Connection startup recovers once if the previous physical Bluetooth link closes
before the new L2CAP channel is ready. The fresh attempt uses the original
20-second deadline. This handles a setup/approval transition where CoreBluetooth
briefly reuses a link that Linux is still closing. Recovery happens before any
authorization or input protocol bytes are sent; established sessions and
protocol failures are not replayed. Live readings expose the same progress
messages, and connection-stage logs contain no identifiers, keys or input.

With [relay package revision 14 or newer](../../docs/linux-ble-package.md),
select the relay, choose **Add Tablet → Find Tablets**, put the tablet into pairing
mode, and select it. Successful bond/vendor/HID/input verification automatically
saves the headset that initiated setup. The app proceeds to live readings with
no three-circle or tablet-button confirmation. Existing owners use **Manage
tablets** to replace a tablet without losing headset authorization.
Discovery and saved tablet rows show the Bluetooth MAC address below the name,
including when a saved tablet is offline. Manage Tablets uses aligned saved
rows with a three-dot menu, matching saved Wi-Fi networks. The selected tablet
is identified in its status; Select Tablet appears only for other tablets and
Reconnect only for the selected offline tablet. A retained tablet can still
finish headset setup after an ownership reset. Remove Tablet requires a
confirmation with the name and MAC address, forgets the tablet bond and retains
headset approval. Removing the last tablet leaves Add Tablet available and
disables testing until a tablet is paired or selected again.

One Done button closes management, including canceling an in-progress setup.
Progress is shown only while opening, scanning, changing or closing setup;
idle monitoring does not show a spinner. Connection Diagnostics stays on the
main Tablet page.

The read-only setup endpoint supplies the public relay identity. Mutations use
a restricted Noise session; tablet verification promotes only its initiating
headset key to persistent ownership. Readings open a fresh authenticated
connection. Initial identity pinning is trust on first use, not out-of-band
verification of a nearby relay. Existing pins are never silently replaced.
The same private headset identity can restore a lost local relay key when the
relay still approves it; unknown headset keys require an explicit SSH ownership
reset. See [headless setup and recovery](../../docs/bluetooth-tablet-pairing.md).

Test Tablet opens a large testing sheet with a pressure-sensitive stroke trail
and a pen area that preserves the tablet coordinate proportions. Stop Testing
or dismissing the sheet ends capture; tab changes and inactivity retain the
existing cancellation/disconnect reservation. A failed connection stays visible
in the sheet until it is closed. Frequent input updates are observed only by
the test surface, rather than the surrounding setup pages.

Reading details show input reports/s and received updates/s. Move the pen
continuously when comparing them. Input reports count all Linux pen, pad and
touch SYN_REPORT events. Receipt rate excludes idle/status snapshots. Source
rate uses the relay clock and receipt rate uses the app clock; these are not
one-way latency measurements. No fixed hardware reporting rate is assumed.

The screen shows pen position, pressure, tilt, Pad buttons and touch count.
Tablet sleep retains the bond and headset ownership. Selection uses physical
ancestry and capabilities rather than a product-ID allowlist.

The readout preserves completed Linux input reports using the existing encrypted
observer protocol. It does not forward raw HID to a workstation or create a
system-wide visionOS pointer. Discovery, setup and readings support both transports.

## Direct tablet experiment

Build 5 explored a tablet paired directly to visionOS. The operator confirmed
Settings showed the tablet connected, but no useful pen, pressure or button
input reached the app, and the tablet was not found in its BLE scan. Build 6
removes that unsuccessful experiment and focuses on the verified Linux relay
path. Its source remains in Git history at `606d5bd`.

## PLANK boundary and connection labels

Setup owns discovery, tablet setup, authorization, network configuration and
testing; PLANK only selects a registered Relay. **Use in PLANK** registers this
Relay in PLANK; a failed launch never suggests adding it by address in PLANK.
PLANK opens Setup with the launch-only `plank-relay-setup://` URL, which carries
and reads no parameters. Four connections are labelled separately and from
evidence: **Setup connection** (last verified management exchange; Connected
only while an operation runs on it), **Tablet → Relay** (USB or Bluetooth),
**Preview transport** (the link that delivered the samples; the requested
transport is shown separately) and **PLANK drawing connection** (PLANK's own
network link). Completed diagnostics read **Last connection test** or **Last
authorization check** with their transport and time.

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

## Direct headset testing

During transport qualification the Tablet page has a **Relay → Headset
connection** selector: Automatic or Bluetooth only. It applies to tablet test
preflight/readings/retries, Test Relay Connection and Check Headset Authorization.
Bluetooth-only fails if the selected relay has no Bluetooth route; it never
falls back to TCP. Selection is saved locally and locked while an operation is
active. The testing sheet reports the actual connection after readings arrive
and clears it on interruption. Discovery, tablet management and the Network tab
retain normal routing. This does not change the tablet-to-relay connection.

This is temporary app-only qualification code. Build with
`PLANK_ENABLE_TRANSPORT_TESTING=OFF bash scripts/build-tablet-setup.sh device`
to hide the selector and ignore even a previously saved Bluetooth-only choice.
The CMake option has the same name. `RelayTestTransport.swift` owns the policy
and single defaults key; `RelayTestTransportView.swift` owns the selector UI.
Removal needs no Linux, wire-protocol or identity migration. The current
Starting with 0.6.4, Bluetooth connections require the relay's LE credit-based
L2CAP endpoint. GATT only discovers its dynamic PSM; input, management and echo
use the socket stream. There is no automatic GATT fallback. Update both app and
relay together. The test sheet identifies the active path as Bluetooth · L2CAP
only after a sample arrives. Physical throughput acceptance is still pending.

Development builds are installed directly through the Mac paired with the AVP.
Build/signing can run on another authorized Mac, then transfer the signed app
to the paired Mac. The headset must be reachable, have Developer Mode enabled,
and be included in the development provisioning profile. Keep the same bundle
identifier and signing team so an update can retain app data and relay trust.
Do not uninstall the existing app as part of this workflow.

Use `scripts/export-tablet-development.sh <archive> <new-output-directory>` to export a development
app from a validated archive, then run
`scripts/install-tablet-development.sh <signed.app> <device-identifier>` on the
paired Mac. These commands do not upload to App Store Connect. Record the source
revision, software version and build number for each installed candidate.

After physical testing and operator approval, distribute that approved source
through TestFlight using the separate workflow below. Direct development builds
still need valid Apple signing/provisioning; they bypass TestFlight processing.

## TestFlight delivery

Publish a GitHub release of the Linux installers only when also delivering the
matching TestFlight release. Routine CI or development builds do not authorize
a GitHub release. Linux packages exclude separate dbgsym downloads.
Every approved TestFlight delivery includes the app's existing external testing
groups, beta review submission when required, and automatic notification after
approval. Internal testing alone does not complete a release. This is the
operator's standing instruction; no separate external-distribution approval is
needed for subsequent approved releases.

TestFlight is used for operator-approved versions. Ordinary build commands
above produce unsigned SDK bundles; the separate archive/export commands below
produce signed distribution packages. Neither is automatically available in
TestFlight. The app requires visionOS27; verify the tester's headset OS.
The archive command generates and includes application debug symbols. Both
archive and export/upload commands reject missing symbols or executable/dSYM
UUID mismatches before delivery.

The current app bundle ID is `la.instinctual.PLANK.AVPrelay`. The earlier
`la.instinctual.PLANK.TabletSetup` TestFlight record remains associated with its
existing builds. Apple locks a record's bundle ID after a build is uploaded, so
the new identity requires its own App Store Connect record and matching signing
profiles. Register the bundle ID in the developer account, then create the
visionOS app record on the App Store Connect website; Apple's public API can
register bundle IDs but cannot create app records. Point the private metadata
configuration's `bundle_id` at the new identifier before the next delivery.

The new identity installs as a separate app with its own preferences and
`la.instinctual.PLANK.AVPrelay.pairing.v1` Keychain service. It does not migrate
the earlier app's saved headset key. When switching the live headset to the new
app, use the documented [SSH ownership reset](../../docs/bluetooth-tablet-pairing.md)
and authorize it again; tablet Bluetooth bonds can remain in place.

Complete these gates before promising an invitation:

1. Configure usable Xcode developer-account access, or provision an App Store
   Connect API key privately. Installed signing certificates alone do not grant
   access to provisioning or uploads. Never put keys or profiles in this repo.
2. Validate the visionOS icon and distribution metadata, then archive the app
   target in Release. The app is included in archives; static libraries are not
   separate installable products. Use Apple distribution provisioning, not
   macOS Developer ID/notarization.
3. Create the visionOS app record for `la.instinctual.PLANK.AVPrelay` and
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
6. Assign the exact build to every existing external group for this app. Ensure
   the beta app description, feedback email and Apple review contact are saved,
   submit for beta review when required, and enable automatic notification.
   Report a pending Apple review as pending; verify external availability
   before claiming that external testers can install it.

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
before assigning the build to all existing external groups. It verifies review
metadata, submits for beta review when required, and enables automatic tester
notification. Repeated runs preserve group members/public links and reuse an
existing review submission. A missing group or review contact is an incomplete
delivery, not an internal-only success. Keep review contacts and any required
demo credentials in App Store Connect or private files. `--inspect` remains
read-only. This workflow does not submit an App Store public release. Retry
later if Apple is still processing; pending beta review is reported separately
from external availability. Offline verification is
`python3 tests/testflight_metadata_test.py`.

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

## Register a drawing relay with PLANK

After authorization and a tablet test, stop the test and select **Use in PLANK**.
Setup shows its own verified control connection separately from the tablet link
and the network drawing route. See [the handoff guide](../../docs/plank-drawing-handoff.md)
for the required raw service and Client versions, trust boundary and acceptance pass.
