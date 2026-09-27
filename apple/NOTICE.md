# Apple setup component provenance

All new files in this directory and `apps/tablet-setup` are GPL-3.0-or-later,
consistent with the repository license. The existing C relay pairing/Noise
implementation is linked directly from `src/`; it is not copied or replaced.

The Keychain and C pairing integration was informed by cnoellert's native
Vision Pro Client prototype, especially `PlankRelayPairing.swift` at Client
commit `bcb2da43b707e31c332a8948e8f306444309fb97`:
https://github.com/cnoellert/plank-client/tree/bcb2da43b707e31c332a8948e8f306444309fb97/visionos-native

The new standalone app has independent workflow state, operation-generation
guards, no Host/session dependency, and a separate identity namespace. Preserve
this attribution when moving the reusable layer into the production Client.

Build dependency: libsodium1.0.22, ISC license, official release archive SHA-256
`adbdd8f16149e81ac6078a03aca6fc03b592b89ef7b5ed83841c086191be3349`.
The build script checks the immutable archive digest and fingerprints compiler,
SDK and source before reusing a prepared static library.
