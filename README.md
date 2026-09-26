# PLANK tablet Relay

This is the separate Linux Relay for a USB Wacom tablet used with the native
PLANK Vision Pro Client. The Relay will read the tablet locally and forward its
existing raw-HID frames to a paired Client. The Client owns the authenticated
Host session; the Relay has no Host credentials.

**Current state:** the bounded `PLTR` frame parser is tested, and the Client's
raw Wacom worker is vendored and build-checked on Linux. The worker is not yet
connected to a daemon or a Vision Pro. There is no listener or pairing service;
do not expose a network port for this prototype. The secure Noise and CPace
link, Bluetooth LE path, and operational packaging remain to be implemented
and qualified.

Build and test:

```sh
cmake -S . -B build
cmake --build build
ctest --test-dir build --output-on-failure
```

The protocol design currently lives in PLANK's
`docs/development/plans/tablet-relay-plan.md`. This repository will pin a
contract revision and add shared test vectors before the link is enabled.

Licensed under GPL-3.0-or-later, consistent with the PLANK Client worker that
will be adapted here.
