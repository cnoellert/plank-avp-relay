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
ordering. The worker is not yet connected to a daemon or a Vision Pro. There
is no listener or pairing service; do not expose a network port for this
prototype. The pairing state machine and storage, the complete secure link,
Bluetooth LE, and operational packaging remain to be implemented and
qualified.

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
