# Tablet setup workflow lab

## Current work: Bluetooth headset input, 2026-09-27

Branch: `visionos-tablet-setup`. The operator requested real Bluetooth relay to
headset pairing and Wacom readings in the standalone Test Setup app, following
the tablet bond and wake checks below. This explicitly advances the earlier
simulation-only Bluetooth scope. Parent `cnoellert/plank-tablet-relay` main is
`465c11a9708bfce0c155502844ca8d53e4370390`; a pull with rebase/autostash found it
already included and preserved the current work.

The new foreground Linux BLE lab advertises a custom GATT service. It reuses
the C CPace/Noise and persistent identity/attempt-budget implementation through
an opaque shared-library API; Python owns BlueZ transport and readonly evdev
observation. Discovery groups pen/Pad/touch by physical USB ancestry or Bluetooth
identity and requires Wacom pen axes and at least one Pad button, without a model/PID
allowlist. The selected tablet is retained across sleep and wake. This is a
separate diagnostic process, not an installed boot service or a production
raw-HID daemon replacement.

The operator requested simpler authorization: three short Home/center-button
presses, no manual readiness checkbox/SSH window step, and no Simulation tab.
The app now opens directly to discovery. Select the relay and tap Pair; the
relay reports availability, press count and a 60-second deadline. Three releases
of the same supported Pad button approve that one pending request. Holds,
duplicate input, mixed buttons, long gaps, detach and cancellation cannot carry
partial approval into a new request. Devices without Home/center can use another
supported tablet button; no model-specific selector is hardcoded.

This explicitly accepts weaker first-pairing authentication than the earlier
random challenge: a nearby active attacker can race/intercept enrollment. Mode3
reuses CPace with a public constant and a local physical gate, then confirms
and saves the exchanged keys. It is not secret-code-authenticated enrollment.
Saved-key Noise and encrypted observations remain unchanged. The persistent
physical-attempt budget is reserved only after three completed presses, so
unapproved remote cancellations do not consume it. Successful confirmation
resets that budget. See `docs/bluetooth-headset-lab.md` for the full contract.

After pairing, the app closes its enrollment transport, reconnects using the
saved key and starts readings automatically. Optional authenticated HELLO
capability0x02 gates observation; no workstation session is started. Display
snapshots are coalesced at up to20Hz, so short button transitions can fall between
updates. Full raw-HID workstation forwarding remains separate. Legacy TCP USB
pairing is retained under Connect by network address. Simulated state/input
remain only in developer tests and the offscreen preview.

## Validation and remaining test

- Linux: all20 CTest suites passed, including fragmented CPace/Noise records,
  persisted trust, unauthenticated-client rejection, mutual observer opt-in,
  workstation-session rejection, graceful connection-check closure, indication
  acknowledgement pacing/overflow, and cleared offline state. Button approval
  tests cover two-press rejection, holds/repeats, mixed buttons, cancellation,
  tablet detach, expiry and confirmation after the third release.
- Apple: macOS preview/tests and actual visionOS device/simulator SDK builds
  passed with Xcode27/SDK27, arm64, deployment target27.0. All10 Apple CTest
  suites passed. The updated discovery and three-press approval screens were rendered through
  a native offscreen hierarchy and visually inspected with synthetic state.
- Relay hardware: BlueZ GATT/advertisement registration succeeded on the same
  adapter holding the Wacom connection. This proves peripheral registration,
  not a headset connection or physical radio throughput.
- No new headset pairing or real readings in the app have been accepted yet.
  Simulator compilation is not simulator execution. Physical visionOS UI,
  Bluetooth permissions, GATT indication flow and reconnect remain to test.
- Build0.1.0(2), source `84851e4948df3f7e0d07e6c929950cb585ee3ffc`, passed
  Release archive, signature and bundle checks. Application/dSYM UUIDs match:
  `9F6CCF6B-5A53-3D27-952A-B31A1F442159` (arm64). Symbols are generated and
  copied from CMake's custom output directory into the archive; archive/export
  scripts reject missing or mismatched symbols.
- Apple accepted build2 at22:54:36UTC on2026-09-27; upload completed without
  the previous symbol warning. Apple processing/tester availability is not yet
  confirmed. Retained ignored IPA:
  `artifacts/testflight/0.1.0/build-2/PLANK Tablet Setup.ipa`, SHA256
  `784a2d24ad98f1db7141305b6e009caf14919117df7f012c9a6e19867dfa1ed1`.
  Temporary GUI signing/export/upload jobs were unloaded.

Build0.1.0(3) contains the simplified flow. Apple accepted it at23:30:56UTC
on2026-09-27; processing and tester availability remain unconfirmed. Source:
`5ae78c3b9dc4294cffd7f9fdc39231d9476ae52a`. Archive/signature/bundle checks
passed, with matching arm64 application/dSYM UUID
`F6B8301F-76E5-311A-97B1-1F4B0F3290B1`. The ignored retained IPA is
`artifacts/testflight/0.1.0/build-3/PLANK Tablet Setup.ipa`, SHA256
`032de3a67df1bf934955d9a09f5ce45dd209f404cc2cd574eaab18b671b8df5e`.
GUI signing/export/upload jobs are unloaded. The matching foreground relay lab
is advertising with the tablet connected; saved identity and Wacom bond remain.
No boot service was installed.
Next: install TestFlight0.1.0(3) once available, scan for the advertising lab,
select it and tap Pair. Press/release Home/center three times, then confirm
position/pressure/ExpressKeys on the automatically started readout. Stop/restart
using saved trust and check tablet sleep/wake reporting. No physical headset
pairing/readings have been accepted yet; compilation and previews do not prove it.

## TestFlight delivery context

Future deliveries include build-specific What to Test notes and export
compliance completion under the operator's standing authorization. The
confirmed questionnaire baseline is recorded in private notes. Reuse it only
while encryption/distribution are unchanged; do not convert "standard
encryption" into an unsupported exemption assertion. Build3 tester notes are
prepared in `apps/tablet-setup/TestFlight/0.1.0-3.txt`. Supported App Store Connect
API access for metadata updates is partly configured: the operator provided a
valid team key, now stored privately with0600 permissions. The Issuer ID is
still needed. `scripts/update-tablet-testflight.py` performs exact-build lookup,
bounded processing wait, idempotent notes/compliance updates and readback;
eight offline tests pass. Establish the private compliance baseline from the
operator's confirmed answers and Apple's existing build3 metadata once access
works. Metadata has not been posted or verified by this workflow. Never extract
cached account tokens.

The operator has installed build3 and reports that relay discovery succeeds
but Home-button presses do not authorize. The relay's tablet connection is
present; its log has not shown a headset protocol request. The app remains on
Connecting to your relay, Cancel responds immediately, and the connection
eventually times out back to Pair. Radio capture shows no completed headset LE
connection. A relay-lab restart confirmed connectable undirected advertising,
enabled with an unrestricted connection filter. A brief tablet disconnect was
not a sustained isolation test: the bonded tablet reconnected automatically
after about20seconds. No button-recognition defect or radio fix is established.
The Mac builder has only a simulator listed, not a paired physical headset for
logs. Preserve trust while investigating the pre-authorization connection.
The operator's follow-up center-button test produced seven complete evdev
press/release pairs (code264) in a separate readonly probe. Button delivery to
the relay is working; no headset approval request was active to count them.
The temporary radio-isolation block was removed and the tablet is again
bonded/trusted/connected. Headset connection failure remains unresolved.

Version0.1.0/build1 was uploaded successfully and assigned to the owner's
internal testing group. TestFlight access was confirmed; headset hardware
acceptance was not. Do not upload build1 again. Its signed archive source was
`9f31af8eae35b7e139d76344460f19c47045a2c5`; export/upload tooling was
`a5d7ea15772aa0842835db3d833d1a85d82bbe01`. The retained ignored IPA is
`artifacts/testflight/0.1.0/build-1/PLANK Tablet Setup.ipa`, SHA256
`64733a1eb21e7f6da55d6c80c1030ce9ae5b560df2cd15d628dd57e4cf3fb101`.
Build1 had a non-blocking missing-dSYM warning, addressed for the next archive.

The SSH security session cannot access the GUI-unlocked login keychain. Use a
one-shot job in the existing authorized GUI session for signing/export/upload,
then unload it. No Keychain reset, ACL weakening or password extraction is
needed. Reuse the verified dependency caches with clean Git worktrees.

Live mode uses CPace/Noise/libsodium, not only OS cryptography; no export-exemption
assertion is hardcoded. Distribution geography remains an owner decision.
Do not extract/reuse notarization credentials or commit signing material.
Machine addresses, private staging paths and account diagnostics belong in the
operator's private notes, not Git. Root PLANK and its unrelated ongoing work
remain untouched. No merge or public release has occurred.

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
