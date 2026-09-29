# Tablet relay and setup app

## Current state — 2026-09-29 UTC

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

The target OS remains **Ubuntu 26.04**, with native **arm64 and amd64** builds.
Revision `0.2.0~visionos-tablet-setup.10`, source
`02ec24ceb7cd2325aa05b708e52422c7cb973ef5`, adds automatic Realtek USB driver-disk
switching, offline fallback RTL8851BU firmware, and Python 3.13-compatible HCI
management. See [package documentation](docs/linux-ble-package.md).
The helper preserves OS/admin firmware and initialized controllers, retries
only the supported dongle's failed Bluetooth interface, and removes only its
own fallback links. The USB Wi-Fi function is outside this change.

Revision 9 passed both native builds and installation checks, but fresh removal
exposed a helper import recreating bytecode after Debian cleanup. Revision 10
fixes that. Both architectures pass 23 relay suites, 101 libsodium tests,
lintian, installed-library checks and fresh Ubuntu 26.04 install/remove checks.
The same cleanup fix was independently reproduced and verified locally.

[Build and artifacts](https://github.com/instinctual/plank-tablet-relay/actions/runs/36520677972).
Artifacts use `artifacts/deb/<software-version>/ubuntu-26.04/{arm64,amd64}/`,
with the Git commit in `source-commit.txt` and `provenance.json`.
The library remains a private ctypes library with generic Python 3 dependencies.

### NanoPi hardware check

A NanoPi Zero2 on Armbian/Debian 13 with kernel 6.18 recognizes the tested
RTL8851BU Bluetooth 5.3 radio (`3625:010b`) after its Realtek driver-disk identity
(`0bda:1a2b`) is ejected and the two Bluetooth firmware files are supplied.
These manual preparation steps motivated the package automation. The board's
existing PCIe Wi-Fi remains the network connection; USB Wi-Fi is not qualified.
Ubuntu 26.04 remains the product target, independent of this board's test image.

The Wacom is paired, bonded and trusted over Bluetooth Classic. Linux exposes
pen, finger and pad input nodes and the relay attaches to pen/button input.
Concurrent AVP readings, new-board sleep/wake and reboot qualification remain
pending; input-node creation is not proof of physical pen events or AVP delivery.
Revision 10 is installed on the NanoPi. To qualify recovery, the manually
supplied firmware was moved into a private backup and just the Bluetooth
interface reprobed: the kernel reported zero initialized controllers. Package
installation supplied the fallback links, retried that failed interface and
started advertising automatically. The installed-library smoke test passed;
relay identity and tablet bond bytes were unchanged. Repeating preparation
preserved the initialized controller. Dedicated-adapter startup now works with
Python 3.13, and the tablet reattached using its saved bond. Address-resolution
and global battery-plugin workarounds are not enabled on this radio.
Physical dongle unplug/replug, reboot and AVP acceptance remain pending.
The tablet selection logic remains model independent.

The operator canceled the proposed AP and web UI work; neither is implemented.
The qualified Intel host is unchanged by these new-board tests.

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

## TestFlight build 7

Version `0.1.0 (7)`, app source
`5c62b275f6208c9060e475014d60e48dc3ce0919`, removes the obsolete TCP host/port
setup, five-key enrollment workflow, Network framework dependency, local-network
permission, and simulation coordinator. The app now uses only Bluetooth relay
discovery, three-button approval, live readings and diagnostics. Offscreen
preview fixtures remain development tools, not a runtime app mode.

The current `relay-ble-v1:<peripheral UUID>` Keychain accounts and
`client-private-v1` identity are retained for secure reconnect. The old TCP
account lookup is gone; no legacy account migration is needed. Shared C
protocol/crypto and the standalone upstream TCP/raw-HID daemon remain intact.

- Apple 9/9 CTest suites pass; the obsolete TCP fixture suite was removed.
- Native macOS and visionOS simulator/device SDK builds pass with SDK27.
  Simulator compilation is not simulator execution.
- Signed archive/export, bundle/privacy resources and executable/dSYM matching
  pass. Relay, authorization and readings layouts were inspected using the
  macOS offscreen preview.
- IPA SHA-256: `e18ca03a7b42bc070b0555e8a860849e79830ceec7357459f24c183f20ba976c`.
- arm64 dSYM UUID: `0D5794D9-1E77-335A-9982-762FC7C698DE`.
- IPA, symbols, previews and provenance are retained under ignored
  `artifacts/testflight/0.1.0/build-7/`.

Apple accepted upload at 2026-09-29T04:15:23Z. The exact build is
**VALID / IN_BETA_TESTING**; notes and the saved compliance baseline were
written and read back. GUI archive/export/upload jobs are unloaded. The next
upload must use build 8. Physical AVP acceptance remains pending. Build 6
remains documented in Git history.

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
