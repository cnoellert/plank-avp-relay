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

The Setup app registers `plank-relay-setup`; Client handoff uses `plank-vision`.
The 0.6.7 Setup bundle identity is retained. Authorization belonging to an older,
different app bundle is not automatically migrated into this app.

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
