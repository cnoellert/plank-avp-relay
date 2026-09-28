# Tablet relay and setup app

## Current state — 2026-09-28 UTC

Work is on `visionos-tablet-setup`; parent main
`465c11a9708bfce0c155502844ca8d53e4370390` is already included. The earlier
requested pull/rebase completed without replay. No merge or public release.
Root PLANK and its unrelated work remain untouched. Machine access, signing
jobs and deployment details belong in the operator's private notes.

The operator authorized autonomous relay refinement, Debian packaging and app
cleanup. The working BLE readings path now has a managed Linux service and a
simpler TestFlight app. This remains a diagnostic setup component, separate
from the legacy TCP/raw-HID workstation relay.

## Linux package

`plank-tablet-relay-ble` version `0.2.0~visionos-tablet-setup.5`, source
`ce62527`, targets Ubuntu 26.04 amd64. See
[installation, configuration and hardware guidance](docs/linux-ble-package.md).
Build from a clean committed checkout with `scripts/build-relay-deb.sh` in a
Debian/Ubuntu builder. It verifies pinned libsodium 1.0.22, runs its tests and
all assertion-enabled relay tests, and collects the package, debug symbols,
build metadata, source commit and SHA-256 manifest.

The service preserves root-owned pairing state, announces readiness only after
GATT/advertising registration, and retries startup failures. A dedicated
adapter policy can power on the controller and clear orphan kernel advertising
instances. That opt-in uses bounded management requests, not the interactive
`btmgmt` shell, which hung with service stdin. A fresh controller has no instance
to remove; attempting unconditional removal was also rejected by the kernel.

The tested host needs both an opt-in controller address-resolution workaround
and a persistent BlueZ override disabling its optional battery plugin. The
package does not silently install that global override on other machines.
Original foreground state has been copied and compared, with the original
retained for rollback. Tablet bonds are unchanged. The controller workaround
is reapplied whenever the managed relay starts.

Hardware checks cover managed startup, BlueZ restart, controller power
off/recovery, process crash/recovery, a deliberate orphan advertisement and a
full host reboot. The final package was installed and its files compared to
the package manifest. It advertised automatically five seconds after the new
boot, with no service restarts. The exact relay state and BlueZ tablet bond
file remained unchanged; the tablet is currently offline. Persistent BlueZ
policy, limited process capabilities and configuration also survived. Package lifecycle checks preserve identity through upgrade,
remove/reinstall and purge; configuration survives upgrades and is removed
only on purge. Debian Python helpers clean installed bytecode on removal, without renaming
the ctypes library. The build smoke-tests extracted package contents before
collecting artifacts. All 22 relay suites and 101 libsodium tests pass; the
final package has no lintian findings.

Package SHA-256:
`92a8e6dd13b18003ce5e97918671719ca1f116833dd2a765ff4de7c3577bd3d0`.
The deliverable and matching symbols/build metadata are retained under ignored
`artifacts/deb/ce6252721d6dbe5a39d4a02fc3ef246b9cb5fa30/`.
Earlier package candidates are superseded; use revision 5.

No physical tablet input or AVP round-trip acceptance has been repeated with
the packaged service while the operator is away. The tablet was last paired
directly to AVP; do not remove bonds or force reconnection unattended.

## TestFlight build 6

Version `0.1.0 (6)`, app source `d476aa7`, is **VALID / IN_BETA_TESTING**.
Apple accepted upload at 2026-09-28T02:46:30Z. Build-specific notes and the
operator's confirmed compliance baseline were saved and read back. One-shot
GUI archive/export/upload jobs are unloaded; the next upload must use build 7.

The app opens directly to relay discovery, with a saved-relay connection
shortcut. Connection diagnostics and pairing management are expandable.
The unsuccessful Local experiment is removed; no Simulation tab is exposed.
Live readings display active input slots across the 16-bit snapshot mask rather
than assuming eight tablet buttons. The protocol and Keychain identities are
unchanged. Once live readings arrive, the footer no longer shows a connection
spinner. Stop readings before running a diagnostic; backgrounding cancels the
active operation and returning requires starting it again.

- Apple 10/10 CTest suites and metadata-helper 8/8 offline tests pass.
- Native macOS and visionOS simulator/device SDK builds pass with SDK27.
  Simulator compilation is not simulator execution.
- Signed archive/export, bundle/privacy resources and executable/dSYM matching
  pass. Relay, authorization, readings and offline layouts were inspected in
  the macOS offscreen preview.
- IPA SHA-256: `7b873b806611ef67aadb80f485b26672f05fc4d90ae584a583cc26f3e6e69a40`.
- arm64 dSYM UUID: `98143214-499F-3FE8-AE0A-026239BCA3DF`.
- IPA and provenance are retained under ignored
  `artifacts/testflight/0.1.0/build-6/`.

## Established hardware findings

The operator confirmed pen position, pressure and ExpressKeys all update on
AVP through the foreground relay in build 4. The same Intel 7265 radio passed
Bumble and BlueZ echo tests. A controlled BlueZ comparison passed with controller
LE address resolution off, failed with it on, and passed again with it off.
A second disconnect during authorization was caused by BlueZ's battery GATT
client: its authenticated battery read provoked SMP and local disconnection.
Disabling that optional plugin allowed three-press enrollment and saved-key
Noise reconnect. See [Bluetooth protocol and investigation](docs/bluetooth-headset-lab.md).

The tested radio is Bluetooth 4.2. New hardware guidance is Bluetooth 5.0 or
newer, BR/EDR plus BLE, Linux firmware support, peripheral advertising and
verified concurrent tablet/headset operation. Bluetooth 4.0 is not qualified;
a version label alone does not establish the required roles or reliability.

The Linux tablet bond previously survived a full host reboot, and physical
input plus tablet-initiated sleep/wake reconnection were observed without new
pairing. The apparent short disconnect was not timed from the final input;
do not claim a measured 15-minute idle cutoff. See
[headless tablet pairing](docs/bluetooth-tablet-pairing.md).

Build 5's direct-tablet experiment found no usable app input despite the
operator confirming the tablet awake and Connected in visionOS Settings.
No Wacom appeared in its BLE scan, and the input readout had no pointer/stylus
or events. This does not disprove every possible direct API; it establishes no
public raw-report path for the tested approach. A Linux decoder alone cannot
supply a missing transport. Build 5 source remains at `606d5bd` in Git history.

## Pairing and delivery contracts

Three short releases of the same supported tablet button approve one pending
request within 60 seconds. No model/PID allowlist, readiness checkbox or manual
SSH signal is used on the BLE path. Holds, mixed buttons, detach and cancellation
cannot carry partial approval into another request. This convenience scheme
retains the documented nearby-attacker risk during initial enrollment; it is
not equivalent to a random authentication challenge. Subsequent sessions use
the saved-key Noise connection and encrypted, coalesced readings (up to 20Hz).
The 80-byte snapshot wire format and reserved bytes remain unchanged.

The operator authorized future build-specific TestFlight notes and compliance
completion with saved answers "Standard and No France". The verified API
baseline is `usesNonExemptEncryption=false`; reuse it only while encryption
and distribution are unchanged. Crypto still includes CPace/Noise/libsodium.
Use `scripts/update-tablet-testflight.py` for exact version/build selection,
bounded processing waits and readback. Signing uses the authorized GUI session;
never reset Keychain permissions or copy credentials into Git.
