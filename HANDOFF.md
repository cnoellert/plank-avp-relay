# Tablet setup workflow lab

## Current work

Branch: `visionos-tablet-setup`, based on fork main
`465c11a9708bfce0c155502844ca8d53e4370390`.
Signed archive source: `9f31af8eae35b7e139d76344460f19c47045a2c5`.
Export/upload tooling: `a5d7ea15772aa0842835db3d833d1a85d82bbe01`.
Version: `0.1.0-visionos-tablet-setup (1)` (prototype, not a release).

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
- Rechecked device/simulator bundles and macOS preview/tests with Xcode27.0
  build27A266a after replacing the beta toolchain. Dependency caches are keyed
  to the compiler/SDK; CMake refreshes compiler detection without deleting them.
- Release archive, strict signature verification and App Store Connect IPA
  export passed. Compiled layered icon, scene manifest, privacy declaration,
  version and license resources are verified in the actual bundle.
- IPA retained locally at
  `artifacts/testflight/0.1.0/build-1/PLANK Tablet Setup.ipa` (ignored).
  SHA256: `64733a1eb21e7f6da55d6c80c1030ce9ae5b560df2cd15d628dd57e4cf3fb101`.
- No product installation, persistent service change, merge or public release
  occurred. The temporary GUI-session build jobs were unloaded after completion.

## Next step: TestFlight

Account authentication and signing are repaired. An SSH security session could
not access the GUI-unlocked login keychain; a one-shot build in the existing GUI
session succeeded. No password extraction, Keychain reset or ACL weakening was
needed. Do not confuse this session boundary with an invalid certificate.

Upload was attempted, but App Store Connect returned: app record not found for
`la.instinctual.PLANK.TabletSetup`. The owner must create the visionOS app record
(`PLANK Tablet Setup`, English, suggested SKU `plank-tablet-setup`) before retrying
the existing archive with a new upload-output directory. Build1 has not uploaded;
do not rebuild it merely to create the record. No TestFlight invitation exists.

After upload: complete the account owner's encryption questionnaire accurately,
wait for processing/beta-review requirements and select testers. Live mode uses
CPace/Noise/libsodium, not only OS cryptography; no export-exemption assertion
is hardcoded. Confirm the headset runs visionOS27. Do not extract/reuse macOS
notarization credentials or commit signing material. Headset interaction and
physical pairing remain unqualified.

Read `apps/tablet-setup/README.md` for build commands and live-pairing caveats,
and `docs/visionos-tablet-setup.plan` for the staged relay follow-up.
Machine addresses, build staging paths and account diagnostics belong in the
operator's private notes, not this public repository. Root PLANK and its
unrelated in-progress work remain untouched.
