# PLANK AVP Relay and Setup app

## Current state — 2026-09-29 UTC

Work is now on `main` in the independent public
[`Instinctual/plank-avp-relay`](https://github.com/instinctual/plank-avp-relay)
repository. The complete ancestry of the previous `visionos-tablet-setup`
branch through `53b1a22313921addaa3b36f59a175dc8336958db` is preserved.
Local `origin` points to this new repository; `fork` retains
`instinctual/plank-tablet-relay` and `upstream` retains
`cnoellert/plank-tablet-relay`. The old local main is retained as
`upstream-main`. Historical CI and fixed-snapshot links continue to point to
the old repository where those records were generated. GPL and third-party
attributions are retained. The original parent main
`465c11a9708bfce0c155502844ca8d53e4370390` is already included. The earlier
requested pull/rebase completed without replay. The new repository preserves
that ancestry; no upstream merge was performed during this migration.
Root PLANK and its unrelated work remain untouched. Machine access, signing
jobs and deployment details belong in the operator's private notes.

Shared release **0.5.5** is delivered from the new repository. Package
homepage/source and CI target `main`; the app displays `0.5.5-main`. Bundle ID,
signing, TestFlight listing, installed state namespaces and the fixed Router
subnet are unchanged. The initial migration source
`accacc1c226a2b1a6c89c9c37bb1ce29edc6717d` is the app's signed source.
The final relay source is `bfbdd91e31922540b94b5c4a4889ed109b310efe`, which
only corrects Debian changelog metadata. Recent changelog timestamps now
reflect the release source commits rather than future-dated entries.

All 30 Linux suites and all four native package / clean-install jobs passed
in [CI 36642639817](https://github.com/instinctual/plank-avp-relay/actions/runs/36642639817).
The initial [CI 36642284123](https://github.com/instinctual/plank-avp-relay/actions/runs/36642284123)
failed lintian because the newest changelog date preceded an older entry;
no package from that run was installed or promoted. Both final installers are
in `artifacts/`, with metadata under `artifacts/deb/0.5.5/<platform>/<arch>/`.
Root and versioned checksums pass. Previous 0.5.4 installers are under
`artifacts/superseded/0.5.4/`. CI artifacts and generated files are excluded
from Git; the README links the new repository's workflow for downloads.

The app passed all 17 Apple suites, macOS build, signed visionOS device archive
and export, bundle/privacy checks and matching executable/dSYM UUID. Simulator
compilation was last checked in 0.5.3. Apple upload **22** is **VALID /
IN_BETA_TESTING**, with notes and Standard / No France compliance saved and
read back. All archive/export/upload jobs are unloaded. Artifacts:
`artifacts/testflight/0.5.5/build-22/`. Next Apple upload identifier: **23**.

**Live host update is pending.** The exact final 0.5.5 arm64 installer and
private upgrade script were transferred, but SSH became unreachable through
both saved endpoints before the checksum/install command could start.
No 0.5.5 installation or pre-install state backup is claimed. Last verified
live version is **0.5.4** with retained pairings, Router mode and gateway
`10.20.30.1`. Resume the verified upgrade when the host returns and compare
identity/headset/tablet/USB-mode files against its private backup. Do not reset
saved authorization. USB forwarding, cable gating and app interaction remain
operator acceptance checks. Access addresses, credentials, staged paths and
private release details belong in operator notes.

## Previous delivery snapshot — 0.5.4

Shared release **0.5.4** uses the fixed Router subnet `10.20.30.0/24`, with
relay/gateway `10.20.30.1`, DHCP and wired-only NAT. There is no subnet override.
Bridge addressing is unchanged. Source is
`f03a367958fee4680b32056c3821650641a9c5e0`. All 30 Linux suites and all four
native package / clean-install jobs passed in
[CI 36640704105](https://github.com/instinctual/plank-tablet-relay/actions/runs/36640704105).
Both installers are directly in `artifacts/`, with versioned metadata under
`artifacts/deb/0.5.4/<platform>/<arch>/`; root checksums pass. The previous
0.5.3 installers are retained under `artifacts/superseded/0.5.3/`.

The exact 0.5.4 arm64 package is installed on the live Zero2 and passes package
verification and all three service configuration checks. All main / USB /
Wi-Fi / Bluetooth services are active. Router mode is idle/supported, physical
Ethernet and USB are connected, and the USB interface has only the new IPv4
address `10.20.30.1/24`. networkd offered the connected USB client a DHCP lease
of `10.20.30.69`. Identity, saved headsets/tablets and USB mode were retained
byte-for-byte. Package upgrades also remove the retired `router_address` option
from customized configuration after a private backup, preserving other settings.
Clean-install CI exercises the actual postinst upgrade of that older option.

The matching app passed all 17 Apple suites, macOS build, visionOS device build,
signed archive/export, privacy/bundle checks and matching executable/dSYM UUID.
Simulator compilation was last checked in 0.5.3; there are no app behavior changes
in this release. Apple upload **21** is **VALID / IN_BETA_TESTING**, with notes and
Standard / No France compliance saved and read back. Signing/export/upload jobs
are unloaded. Artifacts: `artifacts/testflight/0.5.4/build-21/`.
Next Apple upload identifier: **22**. A two-packet ICMP probe to the offered
USB client address received no reply; it does not establish end-to-end data
forwarding. USB data forwarding and physical cable removal/restoration remain
operator acceptance checks. Access details and the
private pre-install backup belong in operator notes.

## Previous delivery snapshot — 0.5.3

Previously delivered shared release **0.5.3** fixes background Network refresh blocking, independent
Ethernet status, missing combo-dongle WLAN firmware and Zero2 USB startup /
warm-start configuration. Relay source
`3f353bc264e8de835d7c8048c9e603645ba49e6b` passed all four native package and
clean-install CI jobs and is installed on the live host. App source
`2ea56f1bbb9cec52a740b4461983cdd9ed789a0f` adds visible Wi-Fi switch progress,
action messages and clearing cached settings when a relay is deselected.
All 17 Apple suites and macOS/device/simulator builds pass. Apple upload **20**
is **VALID / IN_BETA_TESTING**, with notes and Standard / No France compliance
saved and read back. Signing jobs are unloaded. App and relay expose **0.5.3**.
Package verification passes, so no temporary hardware test copy remains on the
host. Ethernet carrier is connected and bridge DHCP works; USB preparation is
idle/supported but no USB host is attached. Wi-Fi is now enabled for the
operator's toggle investigation; a real scan found eight networks in its first
page with more available. The operator then successfully joined Wi-Fi from
the app; the host confirmed connected, an assigned address and a saved profile
for automatic reconnection. Identity,
paired-clients and tablets retained byte-for-byte across the final package
upgrade. Access details and backups remain in private notes.

Platform targets are **Ubuntu Server 26.04 / amd64** on Intel hardware and
**Armbian Minimal, Debian 13 / arm64** on the NanoPi boards. The operator
explicitly selected **6.18.54 current** for Zero2. R28S's published Armbian
image currently uses **6.1.172 vendor**; it remains physically unqualified.
Both use one Debian 13 arm64 relay package, with board-specific OS images,
drivers and hardware acceptance. See [platform matrix](docs/relay-platforms.md).
Automatic USB gadget enablement applies to Zero2 only; R28S needs its wired
uplink and USB controller configuration qualified before enablement.

Next, confirm identity replacement in app 0.5.1 using **Forget saved relay**
after the mismatch error, then pair the tablet to enroll the headset.
Verify readings cannot start with no tablet, allow a saved sleeping tablet,
and disable after removing the last tablet. Validate discovery, TCP/Bluetooth
saved authorization and live pen X/Y/pressure on AVP. Test Wi-Fi join,
wrong-password recovery, saved/hidden
networks, on/off and reboot persistence. Test Bridge and Router, USB attachment
with Ethernet link but no Internet, cable removal/restoration, reconnect after
Apply and tablet sleep/wake. USB must withdraw when Ethernet is removed even
if relay Wi-Fi is connected. Physical Wi-Fi/USB/AVP qualification remains
pending; software tests and package checks do not replace hardware acceptance.

The operator authorized autonomous relay refinement, Debian packaging and app
cleanup. The working readings path now has a managed Linux TCP/BLE service and
a simpler TestFlight app. This remains a diagnostic setup component, separate
from the legacy TCP/raw-HID workstation relay.

The operator requested a shareable implementation brief for the upstream
author's coding agent. See [AVP Bluetooth upstream handoff](docs/avp-bluetooth-upstream-handoff.md)
for the verified address-resolution and battery-plugin fixes, fixed reference
snapshot, implementation/recovery requirements and acceptance tests. Creating
this document changes no runtime code or deployed host configuration.

## Shared release 0.5.3 — final Network delivery and warm-start fix

Final relay source is `3f353bc264e8de835d7c8048c9e603645ba49e6b`; final
app source is `2ea56f1bbb9cec52a740b4461983cdd9ed789a0f` (only Apple UI,
command-encoding tests and tester notes differ). Release 0.5.3 retains the
nonblocking Network controls, independent cable status, missing WLAN firmware
and USB interface/permission fixes described under 0.5.2. It also excludes the
owned gadget MAC from automatic physical Ethernet selection on warm starts,
while requiring explicit configuration when real multiple wired ports exist.
The Zero2 passed **three consecutive USB service restarts** with these changes.
The operator's `IMG_0048.jpeg` screenshot showed the intermediate 0.5.2
ambiguous-Ethernet failure and an available Wi-Fi toggle, corroborating the
host findings. The screenshot remains outside this repository.

All 17 Apple suites passed; macOS/device/simulator builds, signed archive /
export, privacy and matching symbols passed. Simulator compiled, not run.
Final native package/clean-install
[CI 36637549606](https://github.com/instinctual/plank-tablet-relay/actions/runs/36637549606)
passed all four jobs. Apple upload 20 is VALID / IN_BETA_TESTING with notes
and Standard / No France compliance verified; signing jobs are unloaded. Local Linux suites: 30/30 pass, including warm-start physical
port selection, networkd permissions and canceled background connection order.
Final installers are `artifacts/plank-avp-relay_0.5.3_{amd64,arm64}.deb`;
metadata/debug symbols under `artifacts/deb/0.5.3/<platform>/<arch>/`.
Next Apple upload identifier after this submission: **21**.

The operator reported Enable Wi-Fi had no visible response. No accepted Wi-Fi
operation was present at initial inspection; the privileged local controller
successfully enabled the radio and performed a real scan. App controls now
show the requested switch state and adjacent progress immediately, explain
missing authorization or busy state beside the control, and report rejected
action guards. Returning to discovery clears network status/lists instead of
showing stale disabled settings from a deselected relay. The exact reason for
the operator's initial tap is not confirmed. The operator subsequently
confirmed a successful app-driven Wi-Fi join, and the host verified the active
connection / assigned address / saved reconnect profile. The final app's
switch feedback still needs operator acceptance. Mac34 was unreachable for device logs.

The live host is installed from the exact 0.5.3 arm64 package and passes
`dpkg --verify` and config checks. All main/Wi-Fi/USB/Bluetooth services are
active; USB reports idle/supported, Ethernet connected, USB host disconnected.
Core state retained byte-for-byte. Wi-Fi stayed enabled across package upgrade;
its request journal changed through scan operations, so only policy/state
values, not byte identity, are claimed for Wi-Fi. Private pre-install archive
paths and inventory belong in operator notes. Wi-Fi joining was confirmed live; final AVP switch
feedback, USB host enumeration/data transfer and physical Ethernet cable
removal/restoration still need operator acceptance.

Artifacts: `artifacts/testflight/0.5.3/build-20/`.
IPA SHA-256: `5af4c258700927ea03f144e708af85d0a4bd11ba7cd5325ceb06072b2ef5d31c`.
arm64 dSYM UUID: `FC2EA891-B9AA-314D-996E-C103BF020C82`.


## Shared release 0.5.2 — responsive Network controls and hardware startup

- Periodic Network reads no longer call `beginNetworkSettings` or set global
  busy/activity. They are serial read-only background tasks, preferring TCP.
  Each finishes before the ten-second interval starts. The foreground mutation
  path retains its BLE preference and durable single-send request identifiers.
- Foreground operations cancel and await background transport teardown before
  connecting. Opening Wi-Fi entry, leaving the Network tab, changing relay or
  app inactivity cancels background work; stale canceled responses cannot
  overwrite the current view. Passive refresh retains editable controls.
- Ethernet carrier remains independent of unsupported/failed USB setup.
  A supported appliance with carrier down reports **Disconnected** and
  **Waiting for Ethernet**. Actual USB errors remain explicit.
- The tested combo dongle's WLAN probe failed with missing
  `rtw89/rtw8851b_fw.bin`, although Bluetooth firmware loaded successfully.
  The package now bundles original base / `-1` WLAN firmware from the same
  pinned linux-firmware revision and Realtek redistribution license as its
  Bluetooth bundle. Existing OS/admin/compressed firmware takes precedence.
  Recovery probes only an unbound supported WLAN interface; it does not reset
  the parent USB device or Bluetooth. Kernel firmware 0.29.41.5 loaded and the
  helper reports supported, disabled according to the saved default policy.
- Zero2 kernel 6.18.54 registers the NCM netdev on UDC binding. Configfs requires
  a numeric `plankusb%d` name pattern. Reserve the expected free `plankusb0`,
  install networkd files and forwarding guard before binding, then verify the
  resulting USB configuration. With no Ethernet link, UDC stays unbound.
  Non-secret networkd files must be 0644, despite the helper's private umask;
  private credentials/state retain their separate protections.

All **17 Apple suites** pass, including background cancellation/disconnect
ordering, no overlapping connections, retained foreground controls and status
labels. macOS/device/simulator builds, signed archive/export, privacy and
matching dSYM checks pass. Simulator compiled, not run. All 30 local Linux
suites pass; native packages and clean-install CI passed, but the final reinstall exposed
a warm-start interface-selection issue superseded by release 0.5.3.
Initial [CI 36635742190](https://github.com/instinctual/plank-tablet-relay/actions/runs/36635742190)
passed all four jobs, but hardware validation then exposed USB interface-pattern
and networkd permission issues. Those binaries are quarantined under
`artifacts/rejected/36635742190`; use only the rebuilt final packages.
Final [CI 36636601807](https://github.com/instinctual/plank-tablet-relay/actions/runs/36636601807)
passed all four jobs for `3de031f0c94acc7147ab4b9f57ca8874cadf24ff`; these
Linux binaries are quarantined under `artifacts/rejected/36636601807`.
App 0.5.2 source `316ed631ca55b9acc65bb6638233dd535831e1ad` differs only in Linux
hardware corrections and their docs/tests/changelog. Both exposed version 0.5.2. Apple upload 19 is VALID / IN_BETA_TESTING with
notes and Standard / No France compliance saved; signing jobs unloaded.
App release artifacts: `artifacts/testflight/0.5.2/build-19/`.
Next Apple upload identifier after this submission was **20**, reserved for 0.5.3.
Physical AVP Network interaction, final app Wi-Fi switch feedback, USB host enumeration, Ethernet
cable removal/restoration and pen readings remain operator acceptance work.

## Shared release 0.5.1 — tablet availability and identity recovery

- Local headset trust alone no longer enables **Start live readings**.
  The app checks Noise-authenticated tablet status on selection and again
  before observing. A selected paired tablet may be asleep; an attached USB
  tablet also qualifies. No tablet / no selection disables readings while
  retaining network management and headset ownership.
- Availability is invalidated when switching relays or reopening management;
  stale status callbacks cannot enable readings. The authorization heading
  says **Saved headset pairing** until the relay confirms current approval.
- A fresh OS creates a new relay identity. On a mismatch, **Forget saved relay**
  asks for explicit replacement confirmation and removes the selected relay's
  pending pins, canonical records and Bluetooth/TCP aliases. It retains other
  relays and the headset private key, then reopens tablet setup. Normal
  ownership transfer of an unchanged relay continues through SSH recovery.
- Live inspection of the fresh-install Zero2 showed no saved tablet and no
  approved headset. Public local TCP status confirmed initial setup and a
  current public identity. The existing app's cached authorization offered
  observation despite this. BLE logs showed authentication followed by closure;
  the changed identity is consistent with the reported write rejection.
  Physical AVP recovery/reading acceptance remains pending.

Validation: all **16 Apple suites** pass, including stale availability,
last-tablet removal, sleeping tablet, USB input and targeted Keychain-record
selection. macOS and visionOS device/simulator compile; signed archive/export,
privacy and matching dSYM checks pass. Simulator compiled, not run.
All four [package CI jobs](https://github.com/instinctual/plank-tablet-relay/actions/runs/36632410225)
pass; each native build passed 30 Linux suites, followed by clean install,
reinstall, retention, removal and migration on Ubuntu 26.04 amd64 / Debian 13
arm64. Sources differ only by the final app authorization-heading refinement.

Installers: `artifacts/plank-avp-relay_0.5.1_{amd64,arm64}.deb` with checksums.
Versioned metadata/debug symbols: `artifacts/deb/0.5.1/<platform>/<arch>/`.
The previous 0.5.0 top-level files are archived under `artifacts/superseded/`.
The host upgrade passed configuration/package verification and preserved
private state. No tablet bond or headset approval was created during inspection.

Apple upload accepted at **2026-09-29T21:28:49Z**. App Store Connect readback:
**VALID / IN_BETA_TESTING**, notes and Standard / No France compliance saved
and verified (`usesNonExemptEncryption=false`). Signing jobs are unloaded.
Artifacts: `artifacts/testflight/0.5.1/build-18/`.
IPA SHA-256: `ef643d769dce502431c33b03ce73d499dc7f6f49c574ec659dea6f34b1aa06d8`.
arm64 dSYM UUID: `D9A745E7-F2FA-3C3E-A1F4-809B492A5A06`.
Next Apple upload identifier: **19**.

## Shared release 0.5.0 — Wi-Fi management

- Network tab now enables/disables Wi-Fi, scans, joins WPA2/WPA3 Personal and
  open networks, accepts hidden SSIDs, reconnects saved profiles, updates
  passwords and forgets networks. Secured rows show only a lock; open rows have
  no security icon/label. Connection and address status remain read-only.
- Persistent manual radio policy is independent of Ethernet carrier. Fresh
  unconfigured supported WLAN starts off; existing configured Wi-Fi remains
  untouched until an authorized action takes ownership. Off retains profiles
  and uses the selected WLAN rfkill index, leaving Bluetooth available.
- `plank-avp-relay-wifi.service` / process `plank-avp-wifi` owns the selected
  WLAN through wpa_supplicant D-Bus and systemd-networkd. The package includes
  wpasupplicant/rfkill; no manual daemon launch. NetworkManager hosts and
  missing/unqualified drivers report unavailable and retain configuration.
- Wi-Fi can carry relay TCP traffic; its DHCP/RA metric prefers normal wired
  routes. USB remains wired-Ethernet-only in Bridge and Router. No Wi-Fi AP,
  web UI, USB Wi-Fi uplink or old workstation transport was added.
- Wi-Fi commands require the current approved Noise identity. Requests are
  durably accepted before apply and continue after connection loss. Status is
  bound to the same UUID and relay key; the app does not resend mutations.
  Failed joins restore prior native profiles; interrupted operations resume.
- Configuration `/etc/plank-avp-relay/wifi.conf`; private profiles, rollback,
  ownership and operation journal `/var/lib/plank-avp-relay/wifi/` (0700/0600);
  root-only socket `/run/plank-avp-relay/wifi/control.sock`. Main relay cannot
  read the Wi-Fi state directory. No passwords in status/discovery/logs/app
  persistence. Native supplicant credentials and original backups stay private.
- Wi-Fi takes over only its selected interface on networkd appliances, preserves
  native profiles and original unit/configuration metadata, and releases its
  networkd file/unmasks prior units on removal. Removal retains private state.
  See [Wi-Fi behavior and acceptance](docs/wifi-management.md) for limits.

Validation: 30 Linux suites and 15 Apple suites pass. New tests include
16 controller/ownership/privacy cases, real isolated supplicant D-Bus profile
persistence/rollback with WPA2 raw keys, WPA3, open/hidden and raw SSID bytes,
and real authenticated TCP rejection of provisional Wi-Fi management. macOS,
visionOS device/simulator builds, signed archive/export and bundle/privacy/
dSYM checks passed. Simulator compiled, not run. Wi-Fi offscreen previews
were inspected; secured/open rows follow the requested presentation.

Apple upload accepted at 2026-09-29T20:23:55Z. Archive/export/upload GUI jobs
are unloaded. IPA/dSYMs/logs/provenance: `artifacts/testflight/0.5.0/build-17/`;
previews: `artifacts/previews/0.5.0/`.
IPA SHA-256: `99e5361ab580764f5d9e55c9e153ffdbdf4d243639db228b626df6446f5acafd`.
arm64 dSYM UUID: `B34B666D-BFEA-3502-B130-932CD2C92F94`.
That release used Apple upload **17**; see the current release above for the next identifier.

[Final package CI](https://github.com/instinctual/plank-tablet-relay/actions/runs/36629621596)
passed all four jobs: native Ubuntu 26.04 amd64 and Debian 13 arm64 builds,
plus clean install, reinstall, private-state retention, removal and
old-namespace migration on both distributions. Each native build passed all
30 Linux suites. Artifact hashes and source provenance were verified locally.
The operator requested removal of the old branch suffix from package naming.
Debian package version is now exactly **0.5.0**, matching `VERSION`; the
builder rejects branch suffixes and build counters. This sorts after the
previous `0.5.0~visionos-tablet-setup` package, so apt treats it as an upgrade.
Internal package name/version, architecture, source and checksums were checked.
Regular installers are directly in `artifacts/`:
`plank-avp-relay_0.5.0_amd64.deb` for Intel / Ubuntu Server 26.04 and
`plank-avp-relay_0.5.0_arm64.deb` for NanoPi / Armbian Debian 13. Both provide
the same features. Future builds also copy the main installer and checksum
to that directory. Optional `dbgsym` files contain crash-debugging symbols;
they stay with build metadata under `artifacts/deb/0.5.0/ubuntu-26.04/amd64/`
and `artifacts/deb/0.5.0/debian-13/arm64/`. Previous top-level copies are
archived in `artifacts/superseded/0.5.0~visionos-tablet-setup/`.
The generated artifacts directory is excluded from Git; CI provides downloads.
CI logs/downloads are in `artifacts/ci/36629621596/`; additional Debian 13
userspace and real isolated supplicant checks are in
`artifacts/validation/0.5.0/`. Containers do not qualify the board kernels.

Two earlier CI issues were corrected: removal must not regenerate Python
bytecode after Debian cleanup, and the retention test's dummy Wi-Fi profile
must be moved out before preparing the separate namespace-migration fixture.
Do not install the first failed-run packages retained under
`artifacts/rejected/36625702966/`. Subsequent changes from app source
`27bd518` affect Linux packaging, CI and documentation only; Apple build 17
needs no replacement. Apple readback is **VALID / IN_BETA_TESTING**, with notes
and saved Standard / No France compliance verified (`usesNonExemptEncryption=false`).

## Shared release 0.4.0 — USB Ethernet and product naming

- Linux package, command and main unit: `plank-avp-relay`;
  USB unit: `plank-avp-relay-usb.service`; admin: `plank-avp-relay-admin`.
  Configuration `/etc/plank-avp-relay/`, identity `/var/lib/plank-avp-relay/`,
  USB state in its `usb/` subdirectory. Main process label `plank-avp-relay`;
  USB process label `plank-avp-usb` fits Linux's 15-byte limit.
- `apt` replaces the old package. Post-install migration copies private state,
  config and backups before service startup, retains original copies and
  refuses conflicting identities. BlueZ tablet bonds remain in place. A
  migration stamp prevents later reinstalls from copying old settings again.
- Bonjour is now `_plank-avp-relay._tcp`; update both components. BLE UUIDs,
  wire authentication and Keychain identity namespace remain unchanged.
- Dedicated appliance uses Bridge by default, Router when selected. Physical
  wired carrier gates the USB adapter in both modes; Internet reachability is
  irrelevant. Wi-Fi is never an upstream path. Router provides IPv4 NAT and
  blocks forwarded IPv6; Bridge carries the wired LAN directly.
- Gadget support enables automatically only on Armbian NanoPi Zero2. x86
  Ubuntu Server 26.04 reports unavailable and retains its network settings.
  The package includes required networking tools. A separately privileged
  service owns networkd/configfs/boot configuration, with root-only IPC.
- Network tab separates an editable mode selector/Apply from read-only
  Ethernet and USB connection statuses. USB status uses the actual controller
  state. Status refreshes every four seconds when idle and active onscreen.
- Only a previously authorized headset can manage networking over encrypted
  TCP/BLE. Provisional setup cannot. Mode requests are durable and idempotent;
  accepted changes finish independently of the app. App reconnects across
  verified endpoints and checks the request result without replaying mutation.
- The supplied parent-folder `install-usb-gadget.sh` is unchanged. Recognized
  standalone installations are backed up and retired by the new controller,
  retaining Bridge/Router choice. Unknown installations are not overwritten.
  Non-default private subnets require explicit configuration before migration.

Software validation: all 28 Linux CTest suites and 14 Apple suites pass.
Linux includes real native identity/approval migration tests, authenticated
network-management socket tests and a real-kernel isolated nftables test.
macOS plus visionOS device/simulator compilation, signed archive/export,
bundle/privacy checks and executable/dSYM matching passed. The simulator was
compiled, not executed. Network-tab offscreen previews were inspected.

App upload was accepted at 2026-09-29T19:22:41Z. The displayed app name changed;
its App Store Connect application record and bundle identifier are unchanged.
Archive/export/upload GUI jobs are unloaded. IPA, dSYMs, previews, logs and
source provenance are retained in `artifacts/testflight/0.4.0/build-16/`.
IPA SHA-256: `ed8ef1c9970258aa1a87d0c68058d7b73d5289bdaa3dc980d3ef41e4c8fe7aef`.
arm64 dSYM UUID: `A103DE26-D5C4-39B6-932E-08E24267F72E`.

Apple API readback is **VALID / IN_BETA_TESTING**. Notes and saved Standard /
No France compliance were saved and verified (`usesNonExemptEncryption=false`).
That release used Apple upload **16**; see the current release above for the next identifier.

All four [Ubuntu 26.04 CI jobs](https://github.com/instinctual/plank-tablet-relay/actions/runs/36619511923)
pass: native amd64/arm64 builds plus clean installation/reinstallation/removal
and old-package replacement on both architectures. The upgrade fixture proves
its original native state is valid, installs the previous package namespace,
then verifies the actual new postinst preserved identity, saved approval and
custom configuration. Each native build passed all 28 relay suites, 101
libsodium tests, installed-package checks and lintian. The real-kernel nftables
check ran locally; CI can skip that subtest without the required privileges.
Final checksummed packages and source provenance are retained under
`artifacts/deb/0.4.0~visionos-tablet-setup/ubuntu-26.04/{amd64,arm64}/`;
complete CI records are in `artifacts/ci/36619511923/`. The app source predates
three Linux-only packaging/test fixes; Apple source is otherwise identical.
No host installation or physical USB/AVP testing was performed.

## Shared release 0.3.0 — previous delivery, never installed on unavailable host

App and relay source is `5e2a402c83a5573512b2524f46b0e72736a62a9f`. The visible
app version is `0.3.0-visionos-tablet-setup`; Debian uses
`0.3.0~visionos-tablet-setup`. Apple's separate upload identifier is 15.

- The new TCP adapter uses the current tablet capture, encrypted Noise codec,
  identity store and enrollment rules. It does not reuse the older standalone
  TCP/raw-HID service. One shared core admits one owning setup/readings session.
- Avahi publishes `_plank-tablet._tcp` only while the listener is running.
  The `.deb` installs its dependencies and starts the service automatically.
  TCP defaults to port 28991 on IPv4/IPv6, including upgrades retaining older
  configuration. A radio restart does not stop the network listener.
- The app browses Bonjour and BLE concurrently, checks network reachability,
  and prefers TCP. Public keys join known identities; a unique matching name
  can group unverified candidates but cannot authorize operations. Fallback
  must prove the selected/saved key. Existing headset keys and trust survive
  transport and network-address changes; no second headset enrollment is added.
- Current tablet setup is restricted until tablet verification commits the
  initiating headset. Readings can recover with a fresh authenticated session
  on an alternate endpoint. Interrupted setup mutations are never replayed.
- Network permission denial leaves Bluetooth usable. Discovery withdrawal,
  probe expiry and BLE advertisement expiry remove unavailable list entries.

Validation: all 25 Linux CTest suites and 13 Apple suites pass, including real
socket tests of Noise, authorization, input snapshots, read-only status,
competing owners, bounds, cancellation and TCP fragmentation. macOS and
visionOS device/simulator SDK compilation passed; simulator was not executed.
Signed archive/export, bundle/privacy and matching executable/dSYM checks pass.

An isolated Linux fixture using the real Avahi publisher and TCP server was
discovered and resolved by a separate Mac on the LAN. All three TCP echo round
trips (64, 512 and 1,024 bytes) passed. The fixture used temporary identity
state and no physical tablet; it has stopped. AVP TCP readings, physical
transport recovery and the host upgrade remain untested/pending.

All four [Ubuntu 26.04 CI jobs](https://github.com/instinctual/plank-tablet-relay/actions/runs/36594697071)
pass: native amd64/arm64 builds and clean install/reinstall/removal on both
architectures. Each native build passed 25 relay suites, 101 libsodium tests,
package checks and lintian. Checksums and exact source provenance were verified;
packages are retained under
`artifacts/deb/0.3.0~visionos-tablet-setup/ubuntu-26.04/{amd64,arm64}/`.
No installation was attempted on the unavailable host.

Apple accepted upload at 2026-09-29T16:13:29Z. Exact API readback is
**VALID / IN_BETA_TESTING**. Build notes and the saved Standard / No France
compliance baseline were saved and verified. Archive, export and upload GUI
jobs are unloaded. IPA, dSYMs, logs and provenance are retained under
`artifacts/testflight/0.3.0/build-15/`.
IPA SHA-256: `4710ef529a512c7570c149802bcb968da2707e195c07b34a106cd6ef5ff9d6c0`.
arm64 dSYM UUID: `812995FC-ADF2-3209-99A5-E3B55A2D442F`.

See [network/package details](docs/linux-ble-package.md) and
[app discovery, trust and recovery](apps/tablet-setup/README.md).

## Shared release 0.2.1 — previous delivery, still installed on host

The operator requires identical `Major.Minor.Ancillary` numbers for the app and
relay. Both now take release `0.2.1` from `VERSION`; the Debian changelog is
checked against that file before packaging. Keep the branch description, but
do not append a build counter. The app displays `0.2.1-visionos-tablet-setup`;
the package uses Debian's prerelease separator, `0.2.1~visionos-tablet-setup`.
Apple's internal upload identifier remains separate (this upload uses 14).
Increment the shared release for delivered updates to either component.

This release also keeps each tablet's MAC address below its name in discovery
and saved connected/offline rows, and includes it in removal confirmation.
Source `560327b2b0de5e297488a7634bbf13a338f8a6ea` passed all 12 Apple suites,
macOS and visionOS device/simulator compilation, signed archive/export,
bundle/privacy checks, and matching executable/dSYM checks. The simulator was
compiled, not executed. Identical-name tablet previews were inspected using
the same UI source in the preceding 0.1.1 archive. Physical acceptance of the
new display and current live pen readings remains pending.

The earlier 0.1.1 upload was already underway when matching release numbers
were requested. Its notes/compliance were completed, but 0.2.1 supersedes it.
Retained app artifacts: `artifacts/testflight/0.2.1/build-14/`.
Retained earlier upload: `artifacts/testflight/0.1.1/build-13/`.
Apple accepted 0.2.1 at 2026-09-29T07:40:33Z; final API readback is
**VALID / IN_BETA_TESTING**. Notes and the confirmed Standard / No France
compliance baseline were saved and read back. All GUI signing jobs are unloaded.
IPA SHA-256: `a5a8d2e3174c2bb7f4b0f54d6a255780a5a07ca86cc6f425ccaad48f5eb129d0`.
arm64 dSYM UUID: `A29AEBDA-4FC5-3DCC-B893-4FAD5AC303E4`.
This app delivery is superseded by 0.3.0 above; the host upgrade is pending.

Package `0.2.1~visionos-tablet-setup` is installed on the NanoPi and advertising
as of 2026-09-29T07:43:29Z. The stock extracted-package smoke passed on the
board. Relay identity, headset approvals, tablet metadata, pairing budget and
configuration are byte-identical to the private pre-upgrade backup; the one
tablet Bluetooth bond is retained. The active BlueZ daemon still excludes the
battery plugin. The only package checksum difference is the expected retained
administrator configuration. No ownership reset or tablet removal was run.
All four Ubuntu 26.04 jobs pass: native amd64/arm64 build and package checks,
and clean install/reinstall/removal checks on both architectures. Both native
builds passed 24 relay suites and 101 libsodium tests; lintian passed.
Checksummed packages, provenance and CI logs are retained under
`artifacts/deb/0.2.1~visionos-tablet-setup/`.
[Shared-release package build](https://github.com/instinctual/plank-tablet-relay/actions/runs/36537727000).

## Combined setup — build 12 and package revision 14 (previous delivery)

The operator approved combining initial tablet pairing and headset ownership.
Build 12 and package revision 14 implement a restricted encrypted Noise setup
session, successful tablet verification commits its initiating headset, and the
app goes directly to readings. Tablet removal retains ownership. A retained
headset private key can restore a lost local relay pin through the existing
allowlist; unknown keys cannot take over an owned relay. App-side local forget
and the three-circle UI are removed. SSH ownership reset retains tablet bonds.
See [current enrollment design](docs/bluetooth-tablet-pairing.md). Earlier
three-press descriptions below document prior builds, not the new normal flow.
The user confirmed that they removed the tablet and also used the old local-
forget control. The relay retained one approved headset and no tablets. No
ownership reset was needed or run: the new app can recover with its retained
headset private key, then add the tablet again. Live recovery/enrollment and
pen-position/pressure acceptance remain pending.

App source `d8fc638977706f73c805360e6163481246e078ea` passed all 12 Apple suites
and macOS/visionOS device/simulator SDK builds. The simulator was compiled,
not executed. Empty/replacement tablet pages were inspected in offscreen
previews. Signed archive/export, bundle/privacy and dSYM checks passed.
Apple accepted build 12 at 2026-09-29T07:16:18Z; final API readback is
**VALID / IN_BETA_TESTING** with notes and Standard / No France compliance
saved/read back. All GUI signing jobs are unloaded. Artifacts are retained at
`artifacts/testflight/0.1.0/build-12/`.
IPA SHA-256: `dc232f23095103814b57d0510988371fed6b54a989e49f6c8dcc395bb013f368`.
arm64 dSYM UUID: `678F33A8-D10A-38A3-B3E3-0D0A29E388A1`.
This delivery is superseded by the shared-release work above.

Package source `1f14bd26b995f5188ae9ad421dd085fee7f46e1c` adds only a changelog
line-wrap fix to that implementation. Revision 14 was installed on the NanoPi;
the service was advertising, and the extracted stock-package smoke passed on
that board. Identity, headset approvals, tablet metadata, pairing budget and
live relay configuration are byte-identical to the private pre-upgrade backup.
The active BlueZ daemon still excludes the battery plugin. Only the expected
administrator-modified config differs from the packaged checksums.
All four Ubuntu 26.04 CI jobs pass: native amd64/arm64 builds and fresh
installation/reinstallation/removal checks on both architectures. Both native
builds pass 24 relay suites and 101 libsodium tests; lintian is clean.
Checksummed packages and CI logs are retained under
`artifacts/deb/0.2.0~visionos-tablet-setup.14/`.
[Revision 14 build](https://github.com/instinctual/plank-tablet-relay/actions/runs/36535681897).
The original build passed functional tests but failed lintian on long changelog
lines; the corrected source above was the package installed for that delivery.

## Linux package

The x86-64 host OS is **Ubuntu Server 26.04**. Packages use Ubuntu 26.04 as
the native **amd64 and arm64** build baseline; the current NanoPi hardware
check uses Armbian/Debian 13. Version `0.2.1~visionos-tablet-setup`, source
`560327b2b0de5e297488a7634bbf13a338f8a6ea`, is installed on the NanoPi.
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
This historical build is superseded by the current delivery at the top.

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
upload identifier is recorded with the current delivery at the top. Physical availability-list acceptance remains pending.

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
