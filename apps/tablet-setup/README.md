# PLANK Tablet Setup — workflow lab

A standalone SwiftUI visionOS app for reviewing tablet-relay onboarding. Also
builds as a macOS UI preview. No workstation, remote desktop, Qt, SDL, FFmpeg or
Rust media transport is required. The app is **not** a full PLANK Client.

The default is **Simulation**, clearly labelled on every page. It never opens
a socket or writes pairing identities. Choose a demo relay, choose USB or
Bluetooth, generate a sequence and press the simulated keys. Test scenarios
cover rejection, timeout and interrupted connections. Successful pairing lets
you simulate reconnection without losing trust. Switching modes clears all
simulated state; simulation is not hardware acceptance.

## Live USB pairing

Explicit Live mode uses the current relay's real C CPace/Noise protocol and OS
Keychain. Enter the relay address/port. The existing daemon must already have
its manual `pair` window open; follow the root README as the service owner.
The existing daemon still selects PTH-660 for pairing. The app does not silently
relax that or pretend to detect other models. Live Bluetooth and automatic
discovery/enrollment are deliberately unavailable until the relay implements
them. Eight usable ExpressKeys remain the planned capability-based contract.

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
trust merely to explore the UI; use Simulation for that exercise.

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

TestFlight is the selected headset delivery method. The current outputs are
unsigned development builds, **not** installable TestFlight packages. The app
currently requires visionOS27; verify the tester's headset OS before submission.

Complete these gates before promising an invitation:

1. Restore usable Xcode developer-account access, or provision an App Store
   Connect API key privately. Installed signing certificates alone do not grant
   access to provisioning or uploads. Never put keys or profiles in this repo.
2. Finish the visionOS icon and distribution metadata, then archive the app
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

Apple references: [uploading builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds)
and [export compliance](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance).

## Acceptance checklist

- Every page remains visibly marked Simulation or Live.
- Simulation needs no network, tablet, Host or permission prompts.
- USB/Bluetooth steps and ExpressKey instructions are clear in the headset.
- Wrong sequence, timeout, interruption, cancel and backgrounding are recoverable.
- No stale callback can save trust after cancellation or mode/relay changes.
- Existing trust survives failed reconnect; identity mismatch does not replace it.
- Real paired reconnect does not attach a tablet or start a workstation session.
- Test button numbering on each supported physical layout before relying on it.

See `docs/visionos-tablet-setup.plan` for the subsequent daemon/Bluetooth work.
