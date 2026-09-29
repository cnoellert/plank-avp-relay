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

## Combined setup update (delivery in progress)

The operator approved combining initial tablet pairing and headset ownership.
Build 12 and package revision 14 implement a restricted encrypted Noise setup
session, successful tablet verification commits its initiating headset, and the
app goes directly to readings. Tablet removal retains ownership. A retained
headset private key can restore a lost local relay pin through the existing
allowlist; unknown keys cannot take over an owned relay. App-side local forget
and the three-circle UI are removed. SSH ownership reset retains tablet bonds.
See [current enrollment design](docs/bluetooth-tablet-pairing.md). Earlier
three-press descriptions below document prior builds, not the new normal flow.
No live ownership reset has been run; the user's current approved key is retained.

## Linux package

The x86-64 host OS is **Ubuntu Server 26.04**. Packages use Ubuntu 26.04 as
the native **amd64 and arm64** build baseline; the current NanoPi hardware
check uses Armbian/Debian 13. Revision `0.2.0~visionos-tablet-setup.13`, source
`155eb0db4d0268b6bac8bd8c652c51cca379417b`, is installed on the NanoPi.
See [package documentation](docs/linux-ble-package.md).

- Revision 11 adds tablet enrollment from the headset app, explicit SSH
  recovery commands, and hostname-based relay discovery.
- Revision 12 sets `GOVERNOR="powersave"` and `ENABLED="true"` in
  `/etc/default/cpufrequtils` on Armbian only. It preserves other settings and
  backs up the original file. Ubuntu Server CPU settings are unaffected.
- Revision 13 packages the required BlueZ battery-plugin exclusion, reloads
  active Bluetooth services during installation/upgrade, and removes its own
  vendor drop-in on uninstall. Manual host preparation is no longer required.
- Automatic Realtek driver-disk switching, offline RTL8851BU Bluetooth firmware,
  Python 3.13 HCI management, and removal cleanup remain included. Firmware
  runs on the radio and is identical for ARM64 and x86-64; the native relay
  library must match the host architecture. USB Wi-Fi is not qualified.

Both native builds pass 24 relay suites, 101 libsodium tests, lintian,
installed-library checks and package checksums. Revision 13's fresh Ubuntu
installation/reinstallation/removal checks also pass on both architectures,
including an Armbian marker fixture to exercise the actual postinst and verify
non-Armbian settings remain unchanged. Revision 11 passed both native and
fresh-install jobs.
[Revision 13 build and artifacts](https://github.com/instinctual/plank-tablet-relay/actions/runs/36524993167).
Artifacts use `artifacts/deb/<software-version>/ubuntu-26.04/{arm64,amd64}/`,
with the Git commit in `source-commit.txt` and `provenance.json`.

### Headless tablet enrollment

Build 8 discovers the relay hostname. For first setup, Add tablet opens a
bounded discovery window, the operator selects a tablet in Bluetooth pairing
mode, and the relay verifies the Wacom vendor, HID service, bond and actual
pen/pad input. Three releases of the same tablet button separately approve
that headset. No tablet model/PID is hardcoded. Saved tablets retain bonds
while offline; Connect differs from new pairing.

Unauthenticated enrollment is limited to an empty relay without saved headset
approvals or an existing/attached tablet. Subsequent tablet management uses the
approved headset's existing Noise connection. A temporary BlueZ agent accepts
only the selected tablet's HID service, never becomes the system default agent,
and cleans up a new bond after failed/canceled enrollment. Ownership, timeouts,
message bounds and crash recovery are covered by tests. Wire message types
48/49 are opt-in; the existing input snapshot and build 7 readings path remain
compatible. Physical acceptance of the new enrollment flow remains pending.

The operator cannot add a hardware button. SSH recovery is explicit:
`sudo plank-tablet-relay-admin reset-headsets --yes` retains the relay identity
and tablet bonds; `remove-tablet AA:BB:CC:DD:EE:FF --yes` removes only the chosen
saved tablet. Recovery was tested with isolated state, not run against live
approvals. No web UI or AP work is implemented.

### NanoPi hardware check

The NanoPi Zero2 on Armbian/Debian 13 with kernel 6.18 recognizes the tested
RTL8851BU Bluetooth 5.3 radio (`3625:010b`). Package automation ejects its
Realtek driver-disk identity (`0bda:1a2b`) and supplies missing firmware before
Bluetooth starts. The board's existing PCIe Wi-Fi remains the network uplink;
USB Wi-Fi is not qualified.

Revision 10 installation was tested after privately backing up the manually
supplied firmware and reproducing a failed Bluetooth probe. The package
supplied fallback links, retried only the failed Bluetooth interface and began
advertising. Repeated preparation preserved the initialized controller.
The user then rebooted the board: driver-disk switching, firmware loading and
advertising completed automatically despite a changed USB bus number. Relay
identity and Wacom bond bytes were unchanged. The tablet's saved bond survives
reboot; an offline saved device does not establish live pen delivery.

Revision 12 upgrades revision 10, preserves the live identity/approvals and
uses the hostname with no explicit name override. The actual service exports
all six data/echo/setup characteristics and advertises successfully. The
package's extracted stock configuration/library smoke test passes on the
board, while the live configuration retains dedicated-adapter mode. The
installer applied the requested Armbian values, retained frequency limits and
boost, and backed up the original configuration. The live governor is
`powersave`. Controller address resolution remains enabled on this radio.

The first live AVP attempt exposed a deployment omission: the earlier host's
manual `--noplugin=battery` override had not been packaged. A captured AVP
connection on the Realtek radio completed the diagnostic exchange, then BlueZ
read Battery Level, received Insufficient Authentication, initiated SMP and
locally disconnected. The same failure was captured on a second connection.
A temporary host override disabled the battery plugin on the NanoPi. Revision
13 then installed the packaged policy; the temporary override was removed, and
the running daemon's actual command line confirms `--noplugin=battery`.
The package's native/extracted smoke checks pass on the NanoPi. Identity and
tablet bonds are retained.

Some later live-readings reconnects still failed. Testing the Intel-specific
controller command returned unsupported-feature status `0x1a` on this Realtek
radio; the option was restored to false. A trace also showed the headset
requesting a previous GATT handle range after relay restarts; possible cache
interaction is not yet a proven cause. No speculative handle-layout or app
transport change was deployed. After installing revision 13, three-press
approval and a saved-key authenticated input observer completed. The operator
reported it working; explicit pen-position/pressure acceptance is still being
confirmed, since the read-only monitor so far showed button/touch reports but
no changing pen axes. Do not equate connection with pen delivery.

Live AVP position/pressure acceptance is requested and remains pending.
A temporary read-only pen monitor is prepared; input-node creation, an active
service or an authenticated connection alone do not count as acceptance.
Physical dongle unplug/replug and new-board sleep/wake qualification also remain
pending. The operator identified the generic “PLANK Tablet Relay” listing as
yesterday's test machine, which was still powered on. Do not hide valid relays
by filtering that name.

A later intermittent timeout occurred when starting readings after approval;
the operator reported that a second attempt worked. A new private radio trace
captured a clean pairing disconnect, followed by link-establishment failures
(`0x3e`) and a connection timeout (`0x08`) before the readings exchange. A later
attempt authenticated successfully. This is evidence of a failed Bluetooth
reconnection, not proof of its underlying cause. The operator subsequently
reported normal operation after restarting their setup. No runtime changes or
new app build were made in response; a proposed bounded startup retry was
deferred. The capture is retained privately for recurrence. Do not claim a
permanent fix or explicit X/Y/pressure acceptance from that report alone.

After a confirmed fresh relay reboot, another attempt failed before the three
approval circles. Boot preparation, firmware, advertising and packaged BlueZ
policy passed; saved relay identity, headset approvals and tablet bond matched
the private backups. The new trace shows successful tablet-setup requests and
replies, followed by a subscription shutdown and a relay-initiated disconnect.
No subsequent authorization connection reached the radio in that failed
attempt. On the same boot with unchanged configuration, the next attempt
completed approval and started authenticated readings at 06:08:58 UTC.

When the nearby Mac became available, an AVP diagnostic archive established
the failed handoff's ordering. The installed app is build 9 and the headset
runs visionOS 27.0.1. The new authorization session attached to the previous
physical link at 06:05:48.571 UTC and was reported ready; about one millisecond
later, visionOS processed the relay's pending disconnect. Service discovery
then failed before an approval request could be sent. The app's earlier local
disconnect callback had not meant the physical link was gone. Both sides'
traces are retained privately. Build 10 below adds bounded recovery for this
specific startup race. It does not establish a cause or complete qualification
for the separate earlier radio `0x3e`/`0x08` failures.

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

## TestFlight build 11

App source `aa12336118445e9035e29ed7fe1dc5c6f700fb92` waits for a nonempty
advertised name before publishing a new relay row. The operator reported that
build 10 briefly showed "Tablet relay" before changing to the hostname; that
was the app's fallback for an advertisement received without LocalName.
There is no added startup timer. A name learned during the current scan is
retained across later nameless advertisements. Expiry, nonconnectable removal,
capacity limits and clearing the list on scan reset remain unchanged. Cached
CoreBluetooth names and saved/offline relays are not used.

All 12 Apple suites pass, including missing/empty/whitespace names, subsequent
name delivery, retained names, current signal, rename, expiry and scan reset.
macOS and visionOS device/simulator SDK builds pass; the simulator was compiled,
not executed. Signed archive/export, bundle/privacy and executable/dSYM checks
pass. The hostname-only startup display still needs physical AVP acceptance.
The build includes build 10's startup connection recovery; no Linux changes.

Apple accepted build 11 at 2026-09-29T06:43:33Z. Exact API readback is
**VALID / IN_BETA_TESTING**; notes and saved Standard / No France compliance
were saved and read back. All GUI signing jobs are unloaded.
Artifacts and provenance are retained under
`artifacts/testflight/0.1.0/build-11/`.
IPA SHA-256: `6b7bf7d80f51ea2ea2653affce1f012738fc909a74d1c87a2b8224ba4efbc89e`.
arm64 dSYM UUID: `14698049-DDE6-3C3F-8523-132164FCD34C`.
The next upload must use build 12.

## TestFlight build 10

App source `c2cb8550acd1e76ce88bdcec59f00114048c1d44` recovers once from a
disconnect before the reply subscription is ready. Each attempt owns separate
CoreBluetooth delegates and uses the original 20-second startup deadline.
Cleanup finishes before creating the replacement attempt. This happens before
the caller can send any pairing/authorization/input bytes; established streams
and other errors are not retried. Cancellation prevents the replacement attempt.
Live readings show connection progress. Stage-only logs now use the persisted
notice level without logging identities, keys or tablet input.

All 12 Apple suites pass, including a fake-transport reproduction of the early
disconnect, deadline retention, retry limit, cancellation during cleanup and
no replay after startup. Native macOS and both visionOS SDK builds pass;
the simulator was compiled, not executed. Signed archive/export and bundle,
privacy and executable/dSYM checks pass. After trying build 10, the operator
reported that it seems to fix the connection issue. Repeated cold-start and
specific pen-position/pressure acceptance remain pending.

Apple accepted build 10 at 2026-09-29T06:26:55Z. Exact API readback is
**VALID / IN_BETA_TESTING**; notes and saved Standard / No France compliance
were saved and read back. All GUI signing jobs are unloaded. Artifacts and
provenance are retained under `artifacts/testflight/0.1.0/build-10/`.
IPA SHA-256: `6c1c1a79b287433cd42dd4a14e7960a65bbe905b178a2cf73f18a3c039ff0798`.
arm64 dSYM UUID: `F305AAA7-D1AD-3CA7-9C87-209B07CCB890`.
Build 11 supersedes this app build. Repeat testing after a fresh relay reboot,
through tablet setup, three-press approval and live pen position/pressure.

## TestFlight build 9

Version `0.1.0 (9)`, app source
`b739f2cc81d76b82cc69f772e71518e1f3101351`, shows only relays advertising during
the current foreground scan. Scanning starts when the relay list opens; the
first advertisement is displayed immediately. Repeated advertisements refresh
presence, and an entry expires about five seconds after its last advertisement.
That is a removal grace period, not a startup delay; actual AVP discovery
latency has not been measured. Nonconnectable advertisements are excluded.
Leaving the list or backgrounding the app stops scanning and clears results.

The old saved-relay shortcut and last-relay-name lookup are removed. Current
advertisement names are used instead of CoreBluetooth's cached peripheral name.
Saved Keychain credentials remain available when the relay is rediscovered.
No relay protocol, controller policy or tablet-reading changes are included.
The operator reported build 8 working with revision 13; a specific confirmation
of changing pen X/Y and pressure remains pending.

- Apple 11/11 CTest suites pass, including deterministic discovery refresh,
  expiry, rename, capacity and reset checks.
- Native macOS and visionOS simulator/device SDK builds pass. Simulator was
  compiled, not executed. The relay-page offscreen preview was inspected with
  scanning disabled by its inactive scene environment.
- Signed archive/export, bundle/privacy resources and executable/dSYM matching
  pass. IPA and symbols are retained under ignored
  `artifacts/testflight/0.1.0/build-9/` with previews and provenance.
- IPA SHA-256: `71804bac85102e5583a84b0e84bd84d759343e0457082f147270b59e3e304845`.
- arm64 dSYM UUID: `DF75E104-D169-3F26-9B9A-0D509C7155E1`.

Apple accepted upload at 2026-09-29T05:32:37Z. Processing completed as VALID;
notes and saved compliance were written and read back. The exact build is
**VALID / IN_BETA_TESTING**. All GUI signing jobs are unloaded. The next
upload after build 11 must use build 12. Physical availability-list acceptance remains pending.

## TestFlight build 8

Version `0.1.0 (8)`, app source
`3757f0b00089746193c882759833c61d56132190`, adds headless tablet discovery,
pairing, connection, selection and removal to the headset app. It checks for
the matching relay feature and waits for the management connection to close
before beginning separate three-press headset approval.

Build 7's cleanup remains: obsolete TCP host/port setup, five-key workflow,
Network framework dependency, local-network permission and runtime simulation
are removed. Current `relay-ble-v1:<peripheral UUID>` Keychain accounts and
`client-private-v1` identity remain for secure reconnect. Shared C protocol and
the standalone upstream TCP/raw-HID daemon remain intact. Offscreen previews
are development tools, not an app simulation mode.

- Apple 10/10 CTest suites pass, including tablet management/state checks.
- Native macOS and visionOS simulator/device SDK builds pass with SDK 27.
  Simulator compilation is not simulator execution.
- Signed archive/export, bundle/privacy resources and executable/dSYM matching
  pass. Tablet scan and saved-tablet layouts were inspected in offscreen previews.
- IPA SHA-256: `c26206e4fcaa0a9759603e5d7e602fbf4eda6b6005dc474560529f6731256099`.
- arm64 dSYM UUID: `A73F6E33-E768-34E4-9505-DFDA97BB89A5`.
- IPA, symbols, previews and provenance are retained under ignored
  `artifacts/testflight/0.1.0/build-8/`.

Apple accepted upload at 2026-09-29T04:56:55Z. The exact build is
**VALID / IN_BETA_TESTING**; notes and the saved compliance baseline were
written and read back. GUI archive/export/upload jobs are unloaded. Build 9 supersedes this app
release. Physical pen-position/pressure acceptance remains pending.

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
