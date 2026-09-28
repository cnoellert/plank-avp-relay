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

The operator requested a shareable implementation brief for the upstream
author's coding agent. See [AVP Bluetooth upstream handoff](docs/avp-bluetooth-upstream-handoff.md)
for the verified address-resolution and battery-plugin fixes, fixed reference
snapshot, implementation/recovery requirements and acceptance tests. Creating
this document changes no runtime code or deployed host configuration.

## Linux package

The target OS is **Ubuntu 26.04** for both **arm64 and amd64**, as requested by
the operator. New-install packages are version `0.2.0~visionos-tablet-setup.8`,
source `4f572e1fc8ef3c0addbc265171f9ad8353f3bc7f`, built natively in Ubuntu 26.04
containers. Both pass 22 relay suites, 101 libsodium tests, binary lintian,
extracted/installed native-library smoke checks, configuration and systemd unit
validation. Both also pass install/smoke/remove checks in fresh Ubuntu 26.04
containers, including Python bytecode cleanup.
The ctypes library is excluded from CPython extension inference, so dependencies
use generic Python 3 instead of requiring the builder's Python minor version.

[Successful build and artifacts](https://github.com/instinctual/plank-tablet-relay/actions/runs/36387217564).
Downloaded packages, symbols, metadata, provenance and checksums are retained in
`artifacts/deb/0.2.0~visionos-tablet-setup.8/ubuntu-26.04/{arm64,amd64}/`.
The folder uses the version from `debian/changelog`; the source commit remains
in `source-commit.txt` and `provenance.json`. Existing artifact folders were also
renamed to software versions, with file contents verified unchanged.
Package SHA-256:

- arm64: `46f7536ca1c070c16731ab9d1d7a1ff5df5d2b72de30994de47816c350c814ac`
- amd64: `d0ffd7032d67e8b9bb72848fe7098e0313147f4089ded08d2c222004068643ac`

Earlier revision 7 Debian 12 packages remain under the version 7 directory for
history. Its superseded Python 3.11-dependent candidate is under
`superseded/python311-dependency/`. Use revision 8 for new installations.

There is no physical ARM board qualification yet. Use a 64-bit Ubuntu 26.04
image with the board's Bluetooth firmware and Linux input support, then qualify
concurrent Wacom/AVP operation, pairing, reconnect, sleep/wake and reboot.
The operator canceled the proposed AP and web UI work; neither was implemented.
The later R28S Wi-Fi capability question did not authorize restarting that work.
The live Intel host and TestFlight build remain at the versions below.

### Qualified Intel host

`plank-tablet-relay-ble` version `0.2.0~visionos-tablet-setup.6`, source
`f23e36b`, targets Ubuntu 26.04 amd64. See
[installation, configuration and hardware guidance](docs/linux-ble-package.md).
Build from a clean committed checkout with `scripts/build-relay-deb.sh` in a
Ubuntu 26.04 builder. It verifies pinned libsodium 1.0.22, runs its tests and
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

Revision 5 hardware checks cover managed startup, BlueZ restart, controller power
off/recovery, process crash/recovery, a deliberate orphan advertisement and a
full host reboot. The final package was installed and its files compared to
the package manifest. It advertised automatically five seconds after the new
boot, with no service restarts. The exact relay state and BlueZ tablet bond
file remained unchanged. Persistent BlueZ
policy, limited process capabilities and configuration also survived. Package lifecycle checks preserve identity through upgrade,
remove/reinstall and purge; configuration survives upgrades and is removed
only on purge. Debian Python helpers clean installed bytecode on removal, without renaming
the ctypes library. The build smoke-tests extracted package contents before
collecting artifacts. All 22 relay suites and 101 libsodium tests pass; the
revision 6 binary package has no lintian findings. Ubuntu lintian flags the
private `.changes` file's Debian `experimental` distribution; this package is
installed directly and is not an Ubuntu archive upload.

Package SHA-256:
`83fb4e202224375eef39052cbd96aaecf345e1b306b7594e299070b88d534d82`.
The deliverable and matching symbols/build metadata are retained under ignored
`artifacts/deb/0.2.0~visionos-tablet-setup.6/`.
This is the package retained on the qualified physical host; later revisions
add native ARM packaging and update the build/delivery workflow.

On return, the operator reported “Writing is not permitted.” Echo passed, but
pairing rejected the app's already-approved Client key. This was reproduced
with the installed revision 5 library and an isolated copy of its public
allowlist: a new key reached approval; the existing key failed immediately.
Revision 6 permits full re-approval with fresh physical input and cryptographic
confirmation, retaining the existing entry even on cancellation/failure. Tests
cover a full allowlist, early/invalid confirmation, persistence and subsequent
saved-key authentication. The extracted-package smoke test also exercises a
fragmented request from an existing Client. No app update is required.

Revision 6 is installed, and its package files, state, tablet bond and config
were verified. The operator forgot the direct Wacom pairing on AVP and made
the tablet discoverable. It reconnected to Linux using its existing bond;
no relay-side bond deletion or new tablet enrollment was needed. The journal
then confirmed an existing-headset approval request and authenticated input
observation. User confirmation of displayed position/pressure/button updates
remains pending; do not confuse connection evidence with input acceptance.

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
