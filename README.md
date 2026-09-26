# PLANK tablet Relay

This is the separate Linux Relay for a USB Wacom tablet used with the native
PLANK Vision Pro Client. The Relay will read the tablet locally and forward its
existing raw-HID frames to a paired Client. The Client owns the authenticated
Host session; the Relay has no Host credentials.

**Current state:** only the bounded `PLTR` frame parser and its tests are
implemented. There is no daemon, listener, pairing service, or tablet capture
here yet. Do not expose a network port for this prototype. The secure Noise and
CPace link, tablet worker, Bluetooth LE path, and operational packaging remain
to be implemented and qualified.

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
