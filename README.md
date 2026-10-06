# PLANK AVP Relay

Development is on `main` in
[`Instinctual/plank-avp-relay`](https://github.com/instinctual/plank-avp-relay).
This independent repository preserves the history and GPL licensing of
[`cnoellert/plank-tablet-relay`](https://github.com/cnoellert/plank-tablet-relay).
The earlier [Instinctual fork](https://github.com/instinctual/plank-tablet-relay)
remains available for upstream collaboration and historical build records.

The current managed Linux relay reads USB or Bluetooth Wacom tablets and
provides encrypted tablet setup and readings to the PLANK AVP Relay Setup app.
Release 0.4.0 also manages USB Ethernet on a supported dedicated relay box,
with Bridge/Router selection and separate connection statuses in the app's
Network tab. Physical Ethernet carrier gates USB attachment; relay Wi-Fi is
never an uplink for the headset. Automatic LAN discovery and TCP communication
run alongside Bluetooth LE with shared identity and headset authorization.
Release 0.5.0 adds [Wi-Fi enable/disable, join and saved-network controls](docs/wifi-management.md)
in the Network tab. Wi-Fi may carry relay TCP traffic; USB continues to use
only wired Ethernet. Secured Wi-Fi rows show a lock and open rows no security label.
The Ubuntu 26.04 amd64 and Debian 13 arm64 `plank-avp-relay` packages install dependencies,
configure startup, and migrate saved state from the previous package name.
Installers are named `plank-avp-relay_<version>_<architecture>.deb` and live in
`artifacts/deb/<version>/<distribution>-<version>/<architecture>/`, alongside
`SHA256SUMS` and build provenance. Package builds produce one installer per
architecture; separate debug-symbol packages are disabled.
Package versions use the shared release number without a branch suffix.
Download the installers from
[Releases](https://github.com/instinctual/plank-avp-relay/releases/latest).
Publish a GitHub release only when delivering the matching TestFlight release.
Routine package builds remain CI artifacts until that joint release.
Native build and clean-install logs remain in the
[Linux relay packages workflow](https://github.com/instinctual/plank-avp-relay/actions/workflows/relay-deb.yml).
Generated installers, symbols and build logs are release/CI artifacts rather than Git files.
See [installation and network behavior](docs/linux-ble-package.md) and
[the current app workflow](apps/tablet-setup/README.md).
The [platform matrix](docs/relay-platforms.md) distinguishes each Armbian
board/kernel image from the shared arm64 relay package.
Release 0.5.1 requires confirmed tablet availability before starting readings
and adds explicit saved-identity recovery for a relay after an OS reinstall.

The [Setup-to-PLANK drawing handoff](docs/plank-drawing-handoff.md) registers an
authorized relay with the Client without typing its address. Setup control and
PLANK drawing use separate authenticated connections. The handoff requires the
matching raw tablet service described in that guide.

The older raw-HID workstation service is a separate implementation described
below for reference. The new managed TCP path does not reuse its transport,
pairing commands or worker. The Client owns the authenticated Host session;
the Relay has no Host credentials.

The [PLANK AVP Relay Setup workflow lab](apps/tablet-setup/README.md) on
`main` exercises onboarding without remote desktop.
It opens directly to relay discovery. An explicit
[Bluetooth headset input lab](docs/bluetooth-headset-lab.md) adds authenticated
BLE relay discovery/pairing and a live diagnostic readout. The working readings path is available as a separate
[managed Debian package](docs/linux-ble-package.md); the production raw-HID
workstation service is unchanged.

The [upstream AVP Bluetooth handoff](docs/avp-bluetooth-upstream-handoff.md)
describes the verified controller address-resolution and BlueZ battery-plugin
fixes, reference code, recovery requirements and physical acceptance tests.

**Current state:** the bounded `PLTR` frame and byte-stream parsers are tested,
and the Client's raw Wacom worker is vendored and build-checked on Linux. The
Noise IK handshake and transport module passes the published Noise-C vector
for the specified cipher suite, including encrypted traffic in both
directions. The CPace ristretto255/SHA-512 core passes the pinned CFRG draft
vector; its direction-specific confirmation tags are independently checked.
A Relay-side session gate enforces `HELLO`, `SESSION_READY`, reconnect and end
ordering. The shared link layer now joins framing, Noise IK, approved-Client
lookup, encrypted `HELLO`, and session frames. A test exercises that flow over
TCP bound to `127.0.0.1` and checks rejection of an unpaired key, a mismatched
link type and altered ciphertext. A locked local identity store persists the
Relay key and up to 16 approved Client public keys. The development binary can
bind a LAN address only when explicitly requested.
The pairing engine now covers a 120-second window, five tablet keys, CPace
confirmation, a 60-second attempt deadline, and a 10-minute lockout after
three failures. It persists a Client key only after verifying the Client's
confirmation tag. Its framed pairing state machine and the Client counterpart
pass an end-to-end test: the Client pins the Relay key only after verifying the
Relay's confirmation tag. The Intuos Pro PTH-660's eight physical ExpressKeys
were checked on the development NUC in order against codes 256 through 263.
Bluetooth LE for the production raw-HID service and production packaging remain
to be implemented; the separate BLE input lab is described above.
An initial [headless Bluetooth tablet check](docs/bluetooth-tablet-pairing.md)
has verified a Linux Bluetooth bond, physical pen/pressure/ExpressKey input and
reconnection on one tablet. Automated Bluetooth enrollment and Bluetooth capture
in this daemon remain future work.
The NUC's Wacom Pad evdev node is readable by the `plank-relay` service user;
the ExpressKey mapping and 5/15-second hold detector are compiled and tested.
The existing raw-Wacom worker now has a bounded, validated output queue for
the network thread. Worker overflow marks the link failed instead of dropping
individual tablet reports. An authenticated session dispatcher routes Client
control frames into that worker and encrypts queued tablet frames. A
single-connection TCP driver has bounded writes, handshake and heartbeat
deadlines, clean end handling, a stop descriptor, and tablet state updates from
the worker's Wacom and Host frames. A real socket test covers
the Noise handshake, initial status, session start and end, and rejection of an
unpaired Client. The `plank-tablet-relay` development command now offers
single-connection `serve` and physical-key `pair` modes over TCP. It binds
loopback by default and accepts a specific IPv4 bind address only when given
explicitly. The pairing mode reserves an attempt in an owner-only, atomically
written state file before opening the window; a ten-minute lockout survives
command restarts. A real socket and simulated Pad-event test covers the full
pairing exchange. The signed native visionOS Client now has a pairing screen,
Keychain identity pinning, and a session link that forwards validated Wacom
frames through the existing Host raw-HID channel. It starts the link only after
Host tablet support is negotiated and closes it with the desktop session.
On the development NUC and a physical Vision Pro, local TCP pairing completed
with the five ExpressKeys. A live PLANK session then carried pen motion, tip and
side buttons, and varying pressure into GNOME Settings and Autodesk Flame.
The tablet stopped controlling Linux when PLANK lost focus and resumed when it
became active. The Client also resumed pen clicks and pressure after the Relay
service restarted during a session. After a full NUC reboot, the service
started automatically and a fresh Vision Pro session again carried pen clicks
and varying pressure. After the headset was removed for one minute, pen
movement and pressure returned immediately on wake. DNS-SD, production BLE, and
production packaging remain. During an active session, unplugging the tablet's
USB cable and reconnecting it also recovered without restarting PLANK: movement
returned first, followed a few seconds later by tip clicks and varying
pressure. Restarting the Relay service while the pen tip was held down in
GNOME's tablet test area ended that stroke cleanly; new pen input worked after
the link reconnected. The Host showed one Wacom device set after recovery.
The Relay now saves each raw-HID attachment generation before sending it.
In a live same-session check, two consecutive service restarts attached as
generations 2 and 3; tip clicks and varying pressure worked after each restart.
Relay software version 0.1.1 reports `STATUS=attached` only after Linux has
successfully claimed every local Wacom event node. If claiming fails, it
suspends the Host tablet and reports attach rejection. The Vision Pro Client
uses this stronger signal in its six-gate Wacom preflight.

Development service entry points (use the Relay service account that owns the
0700 state directory, and confirm the Pad key order before physical pairing):

```sh
plank-tablet-relay pair --state-dir /var/lib/plank-tablet-relay
plank-tablet-relay serve --state-dir /var/lib/plank-tablet-relay
```

Both default to `127.0.0.1:28990`. `--bind IPv4` explicitly selects a LAN
address for a local-network trial. Pairing and serving are separate commands
for this development build; a live session is not replaced by a second Client.

`packaging/plank-tablet-relay.service` is a systemd unit for an unprivileged
`plank-relay` user. It expects the binary at
`/usr/local/libexec/plank-tablet-relay` and an owner-only
`/var/lib/plank-tablet-relay` state directory. Set `PLANK_RELAY_BIND` in
`/etc/default/plank-tablet-relay` to the Relay's LAN IPv4 address; its safe
default is loopback. The tablet's `hidraw` and event nodes must be readable by
the service account, and the firewall must permit TCP 28990 only from the
intended local network. Pairing is run separately with the service stopped.

Build and test:

Linux build dependencies include a C/C++ toolchain, CMake, pkg-config and
libudev development files. The BLE service tests use the system Python with
its D-Bus and GLib bindings (`python3-dbus` and `python3-gi` on Debian/Ubuntu).
Use a Debug build so the C test assertions remain enabled.

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Debug
cmake --build build
ctest --test-dir build --output-on-failure
```

The Noise test is built on Linux when `pkg-config` finds libsodium 1.0.19 or
newer. If libsodium is installed in a private prefix, set `PKG_CONFIG_PATH` to
its `lib/pkgconfig` directory before configuring. A missing or older version
disables the Noise target; it must be present for a Relay build that opens a
link. On the development NUC, libsodium 1.0.22 was built into a temporary
project-local prefix from its immutable source archive after verifying its
Minisign signature with the [publisher's documented key](https://doc.libsodium.org/installation).

The current client integration lives on the
[`codex/visionos-client` branch](https://github.com/cnoellert/plank-client/tree/codex/visionos-client).
The wire format is implemented and exercised by the Relay and Client tests;
a canonical shared contract revision and test vectors remain to be pinned.

The identity store requires an existing owner-only `0700` directory. It
creates `identity.key`, `paired-clients.json`, and `store.lock` as `0600` files.
The worker also reserves each raw-HID attachment generation in
`tablet-generation.bin` as an owner-only `0600` file before sending `DEVICE`.
That counter continues across Relay process restarts, so a reconnect does not
reuse the generation of the tablet still attached to the Host. Unsafe or
malformed counter files prevent attachment.
The allowlist is strict version-1 JSON with lowercase hexadecimal public keys:
`{"version":1,"clients":["<64 hex digits>"]}`. Existing files with unsafe
permissions, links, or malformed content fail closed. Keys enter that list
only after a completed pairing exchange; there is no network pairing endpoint
or manual bypass yet.

`tests/noise_vector.inc` is a subset of the public
[Noise-C test vectors](https://github.com/rweather/noise-c/tree/master/tests/vector)
(MIT licensed). The production Noise prologue is fixed to
`PLANK-TABLET-RELAY/1` plus a one-byte link type, so Bluetooth LE and TCP
sessions cannot be swapped.

The CPace suite is pinned to
[`draft-irtf-cfrg-cpace-21`](https://datatracker.ietf.org/doc/draft-irtf-cfrg-cpace/21/),
Appendix B.3. Its code-derived intermediate key must be confirmed in both
directions before pairing keys are stored. The confirmation construction is
specified in the PLANK plan and tested here; it is a PLANK protocol choice,
not a claim that the CFRG draft defines those tags.

Licensed under GPL-3.0-or-later, consistent with the PLANK Client worker that
will be adapted here.
