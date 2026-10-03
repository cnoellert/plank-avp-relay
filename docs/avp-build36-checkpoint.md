# Managed Relay / Setup checkpoint for Vision Client build 36

This clean source snapshot combines Setup picker boundary commit `3d29e3e`
with the measurement-only managed baseline `e8066de`. It retains capture
coordination, authenticated route discovery, the public drawing handoff/status
endpoint, the final shared fixtures, truthful transport labels and the Setup
launch entry. The rejected Bluetooth preview-merging candidate `c489e9f` is
excluded. No deployment, radio selection, bond or identity state is published.

The base is the tested upstream 0.6.6 source `812bae3`; version/changelog stay
at that base. This is a development checkpoint, not a new Debian or Setup
TestFlight release. The installed Setup app was the signed 0.6.6 build 2.

Upstream has since released 0.6.7 and changed its app bundle identity. It also
selectively integrated the original capture-ownership and route-discovery
work. Its older PR #1 was closed without merging its branch wholesale. This
snapshot is preserved separately for review; it must not replace upstream
0.6.7, revert its app identity, or claim qualification on the new main branch.
The remaining handoff and picker changes need a reviewed integration onto
that upstream baseline before an upstream release.

PLANK drawings use the raw Relay network endpoint. Setup owns Bluetooth and
network management, tablet preview and authorization. Bluetooth preview was
retested on the newer controller; complete headset performance qualification
remains open. Measurement logs do not change queueing, pacing or the guard.

Vision Client build 36 still has a mode-change pen issue: tip/buttons may need
an additional reconnect after changing resolution/frame rate. Long sessions,
sleep/wake and repeated recovery remain qualification work. Private deployment
evidence and keys are excluded from Git.
