# Complete Bluetooth drawing and installation

Status: implementation brief, not an implemented or qualified capability.
Separate follow-up to the current TCP drawing handoff PR.

## Required outcome

One operator installation provides Setup management and raw drawing. Setup
registers the Relay with PLANK without a tablet-specific ExpressKey ceremony.
The operator can choose that Relay in PLANK and draw over Bluetooth even when
the Relay's Ethernet and Wi-Fi links are disabled. The AVP still needs its own
network path to the workstation.

Preserve raw HID in both directions: device descriptors, pen/touch/pad reports,
Host control requests and responses, generation checks, suspend and reattach.
Decoded Setup preview samples are not a substitute for that channel. Preserve
the shared exclusive capture lease across Setup tests and drawing sessions.

## What the source establishes

- `tools/avp_relay/l2cap.py` already implements Linux LE credit-based L2CAP,
  negotiated-MTU writes, truncation detection and bounded nonblocking draining.
  `network.Connection` currently accepts channels 0, 1 and 2 for management,
  bootstrap status and echo. It has no raw drawing channel.
- `apple/RelaySetupKit/RelayBluetooth.swift` and `RelayL2CAPStream.swift` supply
  the Apple discovery and stream implementation to reuse. PLANK Client has no
  corresponding CoreBluetooth drawing implementation today.
- Client `PlankRelayLiveLink` handles raw HID and authenticated session frames,
  but hard-wires `NWConnection(.tcp)` and Noise link type 2. Raw Relay
  `src/tcp_session.cpp` also hard-wires type 2. `src/noise.c` supports types 1
  and 2 and authenticates that distinction in its prologue.
- The managed `.deb` installs only management/Setup components. The separate
  raw repo supplies an executable and sample service/permission rules; it is
  not installed by the managed package.

The successful L2CAP echo and Setup preview runs establish transport feasibility
on the qualified controller. They do not qualify raw drawing over Bluetooth.

## Implementation order

### 1. Prove one authenticated raw session over L2CAP

Preferred spike: reuse the managed service's L2CAP listener and add an explicit
raw drawing channel that forwards opaque bytes to a local raw-service entry
point. The drawing service retains its own identity, client allowlist, raw worker
and capture lease. The managed bridge neither decodes pen samples nor grabs the
tablet for this channel.

The local entry point must explicitly select the Bluetooth Noise prologue
(type 1), verify the intended local peer, and be unavailable to arbitrary local
clients. Do not simply forward into the existing TCP/type-2 listener and label
it Bluetooth. Evaluate a credential-checked local Unix stream so the path has
no dependency on a LAN listener. Reuse existing peer-credential conventions;
do not widen service capabilities.

Keep both bridge directions bounded and propagate L2CAP backpressure and close.
L2CAP packets are not TCP writes: honor negotiated send/receive MTUs and detect
truncation. No motion merging or loss of control records. A full/stalled bridge
must release its session cleanly rather than leave a held contact or capture.

Spike success: an approved Client completes the type-1 handshake and exchanges
raw frames and a Host control response over the real AVP L2CAP stream. Refuse an
unapproved key and mismatched transport prologue. If the bridge cannot preserve
those semantics, document the concrete blocker before considering a direct
raw-service L2CAP listener. Do not implement both architectures.

### 2. Register once in Setup

Implement the authenticated Setup-mediated enrollment described in
[the handoff guide](plank-drawing-handoff.md#first-time-registration-follow-up).
Approve PLANK's distinct public key with the drawing service; prove the drawing
identity before saving a Client pin. Cancel, expiry, replay or the wrong target
must not authorize a Client. Keep private keys in their owning app/service.

This is required for a complete fresh installation on tablets without eight
ExpressKeys. Transport success with pre-existing approvals is only spike
evidence and must not be called the completed registration journey.

### 3. Integrate Client selection and handoff

Generalize the existing raw-session byte transport to TCP and L2CAP while keeping
one codec, generation gate and Host forwarding path. Reuse the proven Apple
L2CAP implementation, including cancellation and bounded stream buffering.
Discover the current PSM; never pin a transient PSM or treat a radio address as
the drawing identity.

Add an explicitly versioned Bluetooth endpoint representation and negotiated
support to handoff. Keep the current TCP-only contract and fixtures intact for
older consumers; unsupported versions fail clearly. Setup releases and awaits
its preview before drawing can claim capture. PLANK shows the actual drawing
transport separately from the tablet's connection and Setup's transport.

### 4. Make one installation complete

Preferred delivery is one managed `.deb` containing both service executables,
with raw source pinned and its license/provenance retained. Keep two daemons:
management owns Setup; the unprivileged drawing daemon owns raw capture. Avoid
a daemon consolidation during this feature.

Package the raw binary, service, service account, scoped USB/Bluetooth Wacom
permissions, persistent state directory and startup configuration. Install files
in package-owned paths, and preserve existing identities, client approvals,
bonding and operator configuration on upgrade. Detect an existing unmanaged raw
installation and handle migration explicitly; never launch a second drawing
daemon against the same state.

The Bluetooth drawing path needs no external network binding. For TCP drawing,
configure the supported listener automatically without overriding an existing
operator choice; the current loopback-only unconfigured default is insufficient
for a fresh network drawing installation.

A separate raw package dependency is acceptable only if the distribution makes
it resolvable from the same one-step installation and versions are constrained.
Downloading/configuring another daemon by hand does not meet this outcome.

## Focused verification and completion

Use existing protocol, raw worker, capture-lease, L2CAP and package checks. Add
only coverage for the new enrollment, endpoint and bridge boundaries. No new
general-purpose qualification harness.

Then qualify the installed packages on amd64 and arm64, including a clean
installation and an upgrade preserving identities. On AVP, use the qualified
controller, keep the workstation connection available, and disable only the
Relay's Ethernet/Wi-Fi links. Verify:

1. First-time Setup registration on a tablet without the ExpressKey ceremony.
2. Wireless Wacom to Relay to AVP to workstation drawing: sustained curves,
   tip/pressure/buttons/dragging, and bidirectional raw control traffic.
3. Stop preview, hand off, disconnect/reconnect, tablet sleep/wake and Relay
   restart without overlapping capture or stale held controls.
4. Honest transport labels, throughput/delay compared with the TCP baseline,
   and clean cancellation/failure recovery.

Completion requires that whole installed journey. Existing Bluetooth preview,
TCP drawing and a source build remain useful baselines, not substitute passes.
