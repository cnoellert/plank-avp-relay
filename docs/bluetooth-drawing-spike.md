# Bluetooth raw drawing development bridge

LE L2CAP channel 3 follows the existing `PLTRLEC1` preface. Channels 0, 1 and 2
keep their Setup, discovery and echo meanings. Plain TCP Setup rejects channel 3.
No GATT service, dynamic PSM format or Bluetooth adapter setting changes.

Channel 3 bridges opaque bytes to the raw drawing daemon's abstract local socket
`plank-tablet-drawing-ble-v1`. The bridge resolves the raw service account using
the established status reader and verifies `SO_PEERCRED` before sending any
bytes. The raw listener accepts only uid 0; the remote Noise handshake still
uses the selected Relay's existing drawing approval. No keys are copied into
the managed service, no Setup capture is claimed, and no reports are coalesced.

Each direction has a bounded 16 KiB user buffer. Reads pause when the next whole
L2CAP packet or local read cannot fit. LE MTU segmentation preserves the byte
stream. Startup and stalled writes have finite deadlines. Raw EOF drains output
already received before closing the Bluetooth channel. Peer failure closes both
sides. Existing device capture arbitration stays in the raw session dispatcher.

Linux CTest runs `raw_drawing_test` for bidirectional bytes beyond the MTU,
fragmented channel selection, peer refusal before writes, pause/resume, bounds,
stall teardown and buffered EOF. Real AVP Bluetooth-only drawing is still pending.

The initial bridge slice did not add enrollment or package the raw daemon.
This branch now includes a pinned raw daemon in the complete-package candidate;
see [installation status](complete-relay-installation.md). Enrollment and a
versioned Bluetooth handoff remain separate work. Immutable fixtures are unchanged.
