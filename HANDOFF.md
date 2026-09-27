# Tablet setup workflow lab

## Current work

Branch: `visionos-tablet-setup`, based on fork main
`465c11a9708bfce0c155502844ca8d53e4370390`.
Implementation/build source: `d13dd7d8eabc426e631ba3161c22dc7367d3e280`.
Version: `0.1.0-visionos-tablet-setup` (prototype, not a release).

Standalone native SwiftUI visionOS app in `apps/tablet-setup/`, reusable setup
state/network/Keychain code in `apple/RelaySetupKit/`. It links the existing C
CPace/Noise implementation directly; it does not depend on PLANK streaming.
Existing Linux daemon, tablet capture and deployed services are unchanged.

Default simulation covers USB/Bluetooth selection, five ExpressKey presses,
errors, cancellation, retry and saved-trust reconnection. Simulation does not
open sockets or save identities. Explicit live mode supports the existing USB
manual-pairing protocol and a pinned Noise connection check only. It never
sends SESSION_READY or starts HID forwarding/a workstation session.

The current daemon's PTH-660 restriction, manual pairing process, lack of
discovery/Bluetooth setup and single connection slot remain. The accepted
future device policy is capability-based Wacom with eight usable ExpressKeys,
not a model allowlist. Automatic headless enrollment is later daemon work,
not something the simulated wizard already implements.

## Validation

- macOS preview and real visionOS device/simulator SDK builds passed on an
  authorized Apple Silicon builder using Xcode27/SDK27, arm64, target27.0.
- Nine CTest suites passed, including 38 pure-state assertions, existing C
  protocol/session/crypto vectors and actual Swift/C TCP exchanges.
- The networking suite passed ten repeated runs: fragmented pairing, pinned
  reconnect without SESSION_READY, wrong identity, wrong sequence and prompt
  cancellation of a stalled socket. Temporary test identities never use the
  app's Keychain or real hardware.
- Native macOS UI previews were visually checked. They do not prove visionOS
  gaze/pinch behavior. An offscreen native hierarchy is required: ImageRenderer
  alone omits AppKit-backed scroll views/controls.
- No headset, physical ExpressKeys, real pairing persistence or Bluetooth
  hardware has been qualified. No simulator runtime is installed on the
  inspected builder; simulator compilation is not simulator execution.
- SDK bundles are unsigned, contain license notices, and are not TestFlight
  packages. No installation, service change, merge or public release occurred.

## Next step: TestFlight

The operator selected TestFlight rather than Xcode device installation.
The inspected builder has Apple Development/Distribution certificates, but
Xcode automatic provisioning failed with `No Accounts` and no matching app
profile. Its saved account credentials must be repaired in Xcode Settings →
Accounts, or a private App Store Connect API credential must be provisioned.
Do not extract/reuse macOS notarization credentials or commit signing material.

Then finish the visionOS icon/distribution metadata, create/verify the app
record, archive/export, complete the account owner's encryption questionnaire,
upload and wait for processing/beta-review requirements before inviting testers.
The bundle ID is `la.instinctual.PLANK.TabletSetup`. Confirm the headset runs
visionOS27; the current prototype requires it. No TestFlight upload has occurred.

Read `apps/tablet-setup/README.md` for build commands and live-pairing caveats,
and `docs/visionos-tablet-setup.plan` for the staged relay follow-up.
Machine addresses, build staging paths and account diagnostics belong in the
operator's private notes, not this public repository. Root PLANK and its
unrelated in-progress work remain untouched.
