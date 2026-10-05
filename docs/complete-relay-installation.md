# Complete Relay package candidate

Status: package candidate; clean native builds and installation checks pass on
Ubuntu 26.04 amd64 and Debian 13 arm64. Hardware deployment remains pending.
This is the packaging slice of the Bluetooth drawing implementation plan.
The older package CI results below predate Setup-mediated enrollment and
registered transport selection. Enrollment passed the development-device check;
the registered transport candidate is implemented and awaiting its live pass.
The complete package must be rebuilt from the current pin before release.

## One package, two services

The managed `plank-avp-relay.deb` builds and installs both executables:

| Service | Account | Purpose |
| --- | --- | --- |
| `plank-avp-relay` | root, existing restricted capabilities | Setup management, preview and the opaque L2CAP drawing bridge |
| `plank-tablet-relay` | plank-relay | Authenticated raw HID drawing, reverse Host control, shared capture lease and public status |

The raw executable is package-owned at `/usr/libexec/plank-tablet-relay`.
The package creates its service account, installs scoped Wacom USB/Bluetooth
permissions, enables both services through debhelper and retains raw state in
`/var/lib/plank-tablet-relay` with mode 0700. It does not add a capability to the
managed service or consolidate the two daemons. Both implementations already
use the same exclusive capture lease.

An unconfigured installation listens on local IPv4 interfaces at TCP 28990.
The drawing service requires its existing authenticated approval; listening does
not grant access. The existing `/etc/default/plank-tablet-relay` operator choice
is a conffile and remains authoritative on upgrade. Set `PLANK_RELAY_BIND` to a
specific local address or loopback to restrict TCP. Bluetooth drawing has its
own local socket and does not depend on this network bind. Firewall policy is
administrator-owned; this package changes no router or firewall rules.

## Reproducible source

`packaging/drawing-source.json` pins raw commit
`029721f9b60833d36aa31f4da558cf8325e111ca` and the SHA-256 of its Git archive.
`build-relay-deb.sh` prepares only that commit, checking the archive before
extraction. `PLANK_DRAWING_SOURCE_REPOSITORY` can name a local Git repository
for an offline build; working files and other commits are never substituted.
The public pin must be published before a clean remote build can fetch it.

The raw build uses the same private, checked libsodium as the managed build.
Both CTest suites run with assertions enabled. Avahi is a required build input,
so automatic raw listener discovery cannot silently disappear. Package
provenance includes the raw pin and archive hash; its license and vendored
Client worker attribution ship with the installer.

## Existing hand-installed raw service

The package refuses installation **before unpacking** if it sees a raw unit in
`/etc/systemd/system` or `/run/systemd/system`, or an executable in
`/usr/local/libexec/plank-tablet-relay`. Such a unit shadows the package unit.
The installer never stops or removes those unowned files automatically.

Migration is a separate, reviewed maintenance step while drawing and Setup
preview are stopped: retain a rollback bundle of the exact existing unit,
executable, operator configuration and private state; stop the old service;
move only the backed-up local unit/executable aside; reload systemd; then install
the candidate package. Keep the same `plank-relay` account and existing state.
Do not reset identities, approvals, bonds or configuration to make installation
pass. If any destination, ownership or symlink differs, inspect it before
migration. This source slice does not authorize that live maintenance step.

Removal stops/removes package-owned programs and services. Raw private state,
service account and approvals are retained, including on purge, so a later
installation does not silently create a different Relay identity.

## Verification scope

Focused source checks exercise exact source preparation, a wrong archive hash,
working-tree independence, Wacom-only permission refresh and refusal of an
unmanaged installation. The existing extracted-package smoke additionally
requires the raw executable, unit, permissions, bind conffile and provenance.
The Linux package workflow builds both suites, checks systemd units and installs
and removes the full package in disposable amd64/arm64 environments.

[Workflow 37177939662](https://github.com/cnoellert/plank-avp-relay/actions/runs/37177939662)
passed both native builds, all 35 managed and 25 raw tests on each architecture,
package lint and extracted/installed smoke checks, and independent clean-install,
reinstall and removal checks with raw state retention. The tested functional
source is managed commit `89df07fcbf4b3330e73a2d38a08a582122703aae`; this status
update changes documentation only. These disposable install environments prevent
service startup and do not prove hardware capture, live service behavior or
migration of a hand-installed Relay. A hardware deployment remains a separate
step with rollback. Bluetooth-only drawing, fresh Setup-mediated enrollment without
ExpressKeys, and the final registered-Relay transport UI are separate remaining
slices; this package does not claim their acceptance.
