# Tablet setup workflow lab

## Current work: tablet-free Bluetooth test, 2026-09-28 UTC

Branch `visionos-tablet-setup`; parent main
`465c11a9708bfce0c155502844ca8d53e4370390` is already included. The requested
pull with rebase completed without replay. Work is pushed, not merged or
publicly released. Root PLANK and its unrelated work remain untouched.

Build0.1.0(4), source `6e71fa93b3fc8556802f91fdafd534839b1a82f1`, adds
**Test Bluetooth connection** after selecting a discovered relay. It sends
three fresh random payloads of64,512 and1024bytes, and requires byte-for-byte
replies: three round trips and1600bytes in each direction. This test uses
separate write/indication characteristics, with bounded queues and timeouts.
It does not pair, grant trust or access tablet input. The larger payload tests
fragmentation and indication acknowledgements. No Simulation tab was restored.

The foreground relay is now running `--transport-only`. This registers only
the echo channels and does not instantiate tablet capture, the native pairing
library or identity storage. Runtime checks confirmed no input-device file
descriptors and no native pairing library mapped. The Wacom bond and persistent
relay identities are retained. No boot service was installed. Normal Pair and
readings require restarting the lab with its regular library/state/tablet
arguments after transport qualification; do not use Pair in transport-only mode.

The app now discovers the selected peripheral afresh using the central manager
that owns its connection, retains it, rejects explicitly nonconnectable
advertisements and reports connection stages and last RSSI. These are diagnostic
improvements, not a proven fix for the original connection stall.

### Physical result and next investigation

The operator installed build4 and tested the Bluetooth-only path. Screenshots
confirm discovery at -61dBm, followed by **Timed out while establishing the
Bluetooth link**. It never reached service discovery or byte exchange. This
failure occurs before tablet authorization. No successful physical headset
connection to the Linux relay, pairing or tablet readings have been accepted
yet. The same headset app subsequently passed against the Mac echo endpoint.

Build3 also discovered the relay and stalled before authorization; Cancel
worked immediately. Turning off the headset's keyboard, mouse and AirPods made
no difference. A readonly tablet probe recorded seven complete Home/center
press/release pairs (code264), but no headset approval request was active.
Earlier controller captures showed no completed headset LE connection and
confirmed connectable undirected advertising with an unrestricted filter.
A temporary tablet radio block was removed; its bond remains intact.

A fresh build4 retry and a further retry with the Wacom powered off both failed.
The bounded controller traces show no headset LE connection-complete event or
ATT exchange. A lab restart captured accepted ADV_IND advertising on all three
channels, unrestricted scan/connect filtering and a1280ms advertising interval.
This verifies controller configuration, not over-the-air connection requests.
The temporary tablet block is removed; the tablet remains powered off by the
operator. Captures are closed.

A nearby Apple Silicon laptop running macOS27 passed two physical tests:
- Independent Core Bluetooth probe, source `7f2cfd2`: all three round trips,
  1600 matching bytes each direction, at00:32:41UTC. Relay controller trace
  confirms LE connection, ATT writes, indications and confirmations.
- The Mac build of Test Setup from the same source as TestFlight4 (`6e71fa9`):
  operator confirmed a pass at about00:34:39UTC. The relay received1600bytes;
  app stage logs confirm service/channel discovery and reply subscription.

This establishes working relay-to-Mac communication and the shared app path on
macOS. It does not establish AVP compatibility or identify the AVP failure's
cause. The operator power-cycled the Vision Pro and the same test still timed out.
Its Settings > Privacy & Security > Bluetooth entry is listed and enabled.
A temporary20ms advertising experiment was accepted by the relay controller,
but the AVP still timed out without a completed LE link or ATT exchange. The
relay was restored to its original1280ms advertising, still in transport-only
mode. Wacom remains off; Mac central comparison apps are closed.

The independent probe's `--peripheral` role (source `d0b27ac`) advertised
**PLANK Mac Echo** on the nearby laptop. Compilation and signature checks
passed. The operator confirmed the existing AVP build4 passed; the Mac log
records two subscriptions with1600bytes each at00:46:27 and00:47:06UTC.
The Mac peripheral app is now closed. This confirms the headset app's Bluetooth
data path against another peripheral, but does not identify the Linux link
failure's cause.

A temporary LE-only relay experiment also timed out. The controller accepted
advertising with BR/EDR Not Supported, but recorded no completed headset LE
link or ATT exchange. Dual-mode operation, SSP, secure connections and the
original advertising interval were restored; the fallback timer and captures
are stopped. Tablet bond/trust remain intact. Transport-only advertising stays
active. No replacement Bluetooth adapter is available for comparison.

AVP-side diagnostics were retrieved through the nearby laptop with Xcode27.
Developer pairing initially failed
before the PIN exchange: the IPv4 control connection timed out and the
advertised IPv6 address had no route. The operator changed the headset's Wi-Fi;
pairing then succeeded and developer tools confirm it is available/paired,
running visionOS27.0. This resolves developer pairing, not the BLE relay issue.
The operator enabled Developer Mode and restarted; remote sysdiagnose then
completed. Its archive and filtered logs are retained privately outside Git.

The fresh failed test's headset logs show the app's connection request accepted,
with zero existing app connections and a limit of two. Five controller-level
connection-complete reports are followed within0.36–0.39seconds by a failed
remote-version read (internal status762) and disconnect before link readiness.
visionOS retries internally and suppresses app disconnect notifications while
the link is unready; the app cancels after its20second timeout. A simultaneous
relay capture overlaps the final three attempts and has no LE completion/ATT.
The same archive includes earlier successful Mac echo tests: remote-version
reads succeed and GATT discovery follows. Encryption-status4803 appears in
both passing and failing cases, so it does not establish an authentication
problem. Do not assign a standard HCI meaning to internal status762 without
evidence, or infer that a controller-level completion means a usable link.

A retry within about one metre with a clear radio path also timed out. Its
bounded relay capture has no LE completion/ATT and is now closed. This makes
a simple range explanation less likely, but does not identify which controller
or stack is responsible. After refreshing package indexes, installed BlueZ and
firmware versions match the configured repositories' candidates; no packages
were installed. Next qualification needs another meaningful controller/role
comparison or detailed radio capture, rather than another identical retry.
No adapter configuration changes or new TestFlight binary were made during
diagnostic collection. No fix for AVP-to-Linux interoperability is established.

At the operator's request, repeated the independent Mac-central test against
the unchanged live relay. It passed again at01:16:52UTC, RSSI-63dBm: three
verified round trips and1600bytes each direction. The relay received1600bytes;
its controller trace confirms a successful LE connection (public peer address,
30ms interval,720ms supervision), ATT writes, indications and confirmations.
The probe exited and the capture is closed. Current matrix: Mac-to-Linux passes,
AVP-to-Mac passes, AVP-to-Linux fails. This isolates the failing combination,
without proving which controller or stack causes the incompatibility.
Preserve trust and distinguish advertising reception from connection success.
Private screenshots, raw captures and machine details stay outside Git.

## Build4 delivery and validation

Apple accepted build4 at2026-09-28T00:17:14Z. API verification confirms VALID
processing and IN_BETA_TESTING internal availability. The exact What to Test
notes in `apps/tablet-setup/TestFlight/0.1.0-4.txt` and the confirmed compliance
flag were saved and read back successfully. The operator's screenshots confirm
build4 installation. No tester invitations or external review were submitted.

- Linux:20/20 CTest suites passed, including bounded echo transport and existing
  pairing/Noise/button approval checks.
- Apple:10/10 CTest suites passed, including no trust from an echo pass, saved
  trust retention and cancellation/stale-result handling. Native macOS and
  visionOS simulator/device SDK builds passed with Xcode27/SDK27. Simulator
  compilation is not simulator execution.
- Signed Release archive, signature, bundle and privacy/resource checks passed.
  Matching arm64 application/dSYM UUID:
  `C4411ED9-E4C1-379D-ACE2-03FC910CC8F0`. Upload had no symbol warning.
- Retained ignored IPA: `artifacts/testflight/0.1.0/build-4/PLANK Tablet Setup.ipa`.
  SHA256: `ae7ad26349a3af19e5ab3d8a5c41369c60206a9d1c453947cfec4ffcb31d9f0b`.
  Provenance is retained beside the IPA. One-shot GUI signing/export/upload jobs
  are unloaded. Next binary build must5; do not upload build4 again.

## Tablet pairing/readings contract

The regular foreground Linux BLE lab advertises a custom GATT service. Python
owns BlueZ transport and readonly evdev observation; the native library reuses
CPace/Noise and persistent identities/attempt budgets. Discovery groups Wacom
pen/Pad/touch by physical ancestry or Bluetooth identity and capabilities,
without a model/PID allowlist. Selected tablets survive sleep/wake in the lab.

The operator requested three short Home/center-button presses, no readiness
checkbox/manual SSH signal, and no Simulation tab. In regular mode, select the
relay and tap Pair; three releases of the same supported Pad button approve one
pending request within60seconds. Tablets without Home/center can use another
supported button. Holds, duplicates, mixed buttons, long gaps, detach and
cancellation cannot carry partial approval into another request.

This explicitly accepts weaker initial authentication than a random challenge:
a nearby active attacker can race/intercept enrollment. Mode3 uses CPace with a
public constant and local physical gate. Saved-key Noise and encrypted readings
remain authenticated. Attempt budget is reserved only after three presses;
successful confirmation resets it. See `docs/bluetooth-headset-lab.md`.

After pairing, the app reconnects with its saved key and begins readings.
Authenticated HELLO capability0x02 gates observation; no workstation session
starts. Snapshots are coalesced at up to20Hz and may miss short button transitions.
Full raw-HID workstation forwarding remains separate. Legacy TCP USB pairing
remains available through Connect by network address.

## TestFlight workflow

The operator authorized build-specific What to Test notes and export compliance
completion for future uploads, with saved answers "Standard and No France".
Supported App Store Connect API access is configured privately with0600 files.
`scripts/update-tablet-testflight.py` performs exact version/build/platform
selection, bounded processing wait, idempotent updates and readback; eight
offline tests pass. Run it after each future upload with that build's notes.

The baseline is Apple's observed `usesNonExemptEncryption=false` after the
operator completed build3's questionnaire. Reuse only while encryption and
distribution are unchanged. Live mode uses CPace/Noise/libsodium, not only OS
cryptography; do not infer a blanket exemption or hardcode one into the app.
Build3 and4 metadata are verified; build4 also has operator install evidence.
Historical build1-3 IPAs and provenance remain in the ignored artifact catalog.

The SSH security session cannot access the GUI-unlocked login keychain. Use
one-shot jobs in the authorized GUI session for signing/export/upload, then
unload them. Reuse verified dependencies from clean Git worktrees. Never reset
Keychain permissions, extract cached tokens, reuse notarization credentials or
commit private machine/account/signing information. Machine paths, addresses
and API configuration belong only in the operator's private notes.

## Headless Bluetooth hardware check, 2026-09-27

The operator requested tablet-to-relay Bluetooth pairing as the next step,
using a PTH-660 for testing while retaining capability-based support across
Wacom generations. BlueZ pairing over SSH now has hardware evidence: a
persistent bond, pen/pressure/touch input, all eight physical ExpressKeys and
reconnection using saved trust. A full relay reboot also retained the bond and
trust, and the tablet reconnected without pairing again. A subsequent 90-second
capture verified pressure from 0 to 8191, motion, tilt, touch and all eight
ExpressKey press/releases, without evdev `SYN_DROPPED` notifications. This does
not constitute acceptance of the headset workflow or Bluetooth support in the
PLANK daemon.

See `docs/bluetooth-tablet-pairing.md` for the repeatable procedure, observed
bondable-state requirement, Bluetooth HID grouping and remaining qualification.
No product-ID allowlist or production daemon/capture change was added. The pairing agent
and scan were closed after the check; the tablet bond and trust were retained.

The operator subsequently reported apparent short-idle disconnects. A six-minute
passive observation found the Bluetooth link and HID node continuously present,
with no HCI/ACL traffic. Battery was 100%, BlueZ input idle timeout was disabled,
and the adapter remained runtime-active. A subsequent longer observation caught
a real disconnect at 22:01:55 UTC: the tablet initiated L2CAP disconnection and
the controller reported reason `0x13` (remote termination). The adapter suspended
only afterward; bond and trust persisted. This is consistent with tablet-side
sleep, and the operator confirmed the tablet was untouched when it happened.
No power settings were changed. The tested model's blue Bluetooth
indicator normally lights for only five seconds, so LED state alone cannot
confirm a dropped link. See the pairing document for diagnostic guidance.

A brief Touch Ring center-button press then restored the connection using the
existing bond, without a host-side connect or pairing command. Post-wake pen
motion, tilt, pressure from 0 through 7709 and touch input were captured, with
no `SYN_DROPPED` notifications. The disconnect/wake cycle supports automatic
tablet sleep followed by normal reconnection. Its exact idle threshold was not
timed from the last pen event; do not report a measured 15-minute cutoff.
