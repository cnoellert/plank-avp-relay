# PLANK tablet Relay

This is the separate Linux Relay for a USB Wacom tablet used with the native
PLANK Vision Pro Client. The Relay will read the tablet locally and forward its
existing raw-HID frames to a paired Client. The Client owns the authenticated
Host session; the Relay has no Host credentials.

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
Relay key and up to 16 approved Client public keys. No service is installed or
running on the NUC yet; the development binary can bind a LAN address only
when explicitly requested.
The pairing engine now covers a 120-second window, five tablet keys, CPace
confirmation, a 60-second attempt deadline, and a 10-minute lockout after
three failures. It persists a Client key only after verifying the Client's
confirmation tag. Its framed pairing state machine and the Client counterpart
pass an end-to-end test: the Client pins the Relay key only after verifying the
Relay's confirmation tag. The physical key reader is implemented but still
needs the tablet's physical key order confirmed. Bluetooth LE and production
packaging remain to be implemented.
The NUC's Wacom Pad evdev node is readable by the `plank-relay` service user;
the provisional ExpressKey mapping and 5/15-second hold detector are compiled
and simulated, pending a physical key-order check.
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
DNS-SD, Bluetooth LE, production service packaging, physical ExpressKey order
confirmation, and the live tablet-to-Vision-Pro test remain.

Development service entry points (use the Relay service account that owns the
0700 state directory, and confirm the Pad key order before physical pairing):

```sh
plank-tablet-relay pair --state-dir /var/lib/plank-tablet-relay
plank-tablet-relay serve --state-dir /var/lib/plank-tablet-relay
```

Both default to `127.0.0.1:28990`. `--bind IPv4` explicitly selects a LAN
address for a local-network trial. Pairing and serving are separate commands
for this development build; a live session is not replaced by a second Client.

Build and test:

```sh
cmake -S . -B build
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

The protocol design currently lives in PLANK's
`docs/development/plans/tablet-relay-plan.md`. This repository will pin a
contract revision and add shared test vectors before the link is enabled.

The identity store requires an existing owner-only `0700` directory. It
creates `identity.key`, `paired-clients.json`, and `store.lock` as `0600` files.
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
