# Setup-to-PLANK drawing handoff

## Operator flow

Use PLANK AVP Relay Setup to discover, authorize and configure a relay. Test the
pen there, stop the test, then select **Use in PLANK**. The Client opens with the
relay registered by identity and offers it in its Relay picker. Setup owns relay
commissioning; the Client owns the workstation session and drawing connection.

The labels describe three different links:

- **Setup connection:** Bluetooth or network, verified by the current Setup
  operation; discovering a radio does not prove an active Bluetooth connection.
- **Tablet connection:** USB or Bluetooth from the Wacom tablet to Linux.
- **Drawing in PLANK:** the raw tablet service's network route. Bluetooth Setup
  does not select a Bluetooth drawing transport in the Client.

A handoff carries public identities and reachable network routes, not credentials.
The managed Setup identity and raw drawing identity are distinct. The Client
verifies the drawing identity through its existing approval flow before drawing;
changing an address does not itself identify a new relay. An unknown drawing
identity still needs approval. Setup stops and awaits its preview before opening
PLANK, releasing the shared capture lease. A live raw drawing session can report
`service.busy`; wait until that session has ended before requesting another handoff.

## Required source combination

This change builds on Alan's main at `b6e7a9a11ffc0790c2107be14ece427b80b49093`
(0.6.7). It preserves the shared capture lease, authenticated route learning,
`RelayTabletTest` startup without extra preliminary connections, current packaging
and release workflows, and the `la.instinctual.PLANK.AVPrelay` app identity.
No service restriction or release version is changed.

The raw tablet service is a separate repository. It must include the drawing-status
server from [raw Relay PR #3](https://github.com/cnoellert/plank-tablet-relay/pull/3)
(head `e5274229854ac590e661c437c3825be44cc56708`) and use the shared capture lease.
The managed service reads bounded public metadata from the Linux abstract socket
`plank-tablet-drawing-status-v1`, checking the raw service account with peer
credentials. It needs no new capability, filesystem permission or service unit.
The contract and immutable vectors are in
[the raw Relay contract](https://github.com/cnoellert/plank-tablet-relay/blob/e5274229854ac590e661c437c3825be44cc56708/docs/relay-drawing-handoff-contract.md).
The local fixture mirror remains pinned to revision `plank-drawing-handoff-v1+r3`.

The Client needs the matching registration/handoff flow from
[Client PR #3](https://github.com/cnoellert/plank-client/pull/3).
Without a matching raw status server, Setup's existing features remain available
and **Use in PLANK** reports a specific unavailable/unsupported reason rather than
inventing a drawing address or silently trusting an identity.

### Installation requires both services

`plank-avp-relay.deb` packages the managed Setup service. It does **not** bundle
or install `plank-tablet-relay`, the separate raw drawing service. Merging this
PR does not by itself provide a drawing listener. Install the matching raw
Relay package as well, with its drawing-status server and shared capture lease,
and allow the Client to reach its TCP drawing listener. Setup Bluetooth remains
a management/preview transport; PLANK drawing uses TCP.

When the raw service is absent, normal Setup management stays available and
the drawing handoff reports `service.absent`. When the raw service exists but
cannot supply usable metadata, handoff reports the corresponding unavailable
reason. Release qualification must exercise the two installed services together;
the managed package's import smoke test does not establish that combination.

The Setup app registers `plank-relay-setup`; Client handoff uses `plank-vision`.
The 0.6.7 Setup bundle identity is retained. Authorization belonging to an older,
different app bundle is not automatically migrated into this app.

## First-time registration follow-up

The current Client still uses its existing physical ExpressKey approval for an
unknown drawing identity. This is a compatibility path, not the intended final
Setup/Client boundary. Already approved drawing identities continue to use
handoff without repeating that approval.

The intended user journey is: authorize the Relay in Setup, explicitly approve
registering it with PLANK there, then choose that registered Relay in PLANK.
First-time registration must work without tablet-specific ExpressKey gestures.
Separate Setup and Client identities remain separate: the URL's public identity
and route hints alone cannot authorize a new drawing client.

Agree the enrollment mechanism with the raw Relay maintainer before changing the
trust gate. The follow-up needs an authenticated Setup-mediated approval of the
Client's public key, acceptance by the drawing service, and a drawing exchange
that proves the advertised drawing identity before the Client stores a pin.
Any enrollment grant must bind the intended Client key and drawing identity,
expire, and reject replay. Cancel or a mismatching identity must leave existing
approvals and selection intact. Private keys are never transferred between apps.
The existing public-status IPC remains read-only.

This follow-up changes enrollment across the services and Client. It is not
implemented by the reliability fixes in this PR, and does not require bundling
the raw drawing service into the managed package. Its acceptance is one first-time
registration on a tablet without ExpressKeys, followed by reconnect and an
address change without another approval prompt, plus refusal of a canceled,
expired, replayed or wrongly targeted grant.

## Verification and release boundary

Run the existing Apple Setup build/test script, including its bundle checks, and
the Linux package workflow. The extracted-package smoke check imports the new
status module. Tests cover strict contract fixtures, authenticated owner-only
status, response bounds, unavailable services, connection labels, preview release
before handoff, and Bluetooth-only selection alongside the upstream tablet startup
tests. Debug builds keep assertions active.

Preview rate and queue measurements are retained. The rejected Bluetooth movement
merging candidate is excluded. Controller choice and live Bluetooth performance
remain deployment and headset qualification tasks, not claims made by this PR.

A source/build pass does not qualify this new upstream combination on the headset.
After installing matching builds during a disconnected session, verify discovery,
authorization, readings on each intended transport, stop-and-handoff, drawing,
and reconnect with no address entry. Confirm the displayed links match the actual
transports. Preserve identities and pairing during deployment and keep rollback
packages. Do not reset authorization merely to make a test pass.

This is source integration, not a release. Alan owns the next version and matching
Linux/TestFlight publication. Workstation resolution/timing teardown and pen
reattachment issues belong to the Client/Host and are not fixed by this handoff.
