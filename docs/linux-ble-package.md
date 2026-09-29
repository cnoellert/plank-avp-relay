# Linux Bluetooth relay package

`plank-tablet-relay-ble` installs the relay used by PLANK Tablet Setup: discover
the relay, pair a tablet to authorize the initiating headset automatically, and
view authenticated position, pressure and button readings. It is separate from the
legacy `plank-tablet-relay` TCP/raw-HID workstation daemon. The two services
should not capture the same tablet at the same time.

## Hardware baseline

For new hardware, target **Bluetooth 5.0 or newer**, with both BR/EDR (Classic)
and Bluetooth LE, Linux firmware support, LE peripheral advertising, and
simultaneous tablet and headset connections. The version label alone does not
qualify an adapter. USB-connected tablets need only the relay's BLE link.

The tested Intel Wireless-AC 7265 is Bluetooth 4.2
([Intel specifications](https://www.intel.com/content/www/us/en/products/sku/83635/intel-dual-band-wirelessac-7265/specifications.html)).
It has carried concurrent Bluetooth Wacom input and authenticated AVP readings
with the compatibility settings below. The current protocol does not require
Bluetooth 5's optional 2M PHY. Bluetooth 4.0 could carry its basic BLE traffic,
but has not been qualified; do not promise support based on the version alone.
Qualification includes repeated discovery, pairing, reconnect, sleep/wake,
reboot, concurrent input and sustained readings on the exact chipset/firmware.

Tablet discovery uses Wacom vendor ancestry and pen/pad input capabilities,
not a tablet model or product-ID allowlist. With multiple matching tablets,
input stays offline until a tablet is selected in configuration. Once attached,
the running service retains that physical identity across sleep/wake.

## Install and configure

Use the package matching `dpkg --print-architecture`: `arm64` for 64-bit ARM
Linux, or `amd64` for x86-64. **Ubuntu Server 26.04 is the x86-64 host OS**.
Ubuntu 26.04 remains the package build baseline for both architectures; the
current NanoPi ARM64 hardware test uses Armbian. Automated builds use Ubuntu 26.04 containers on native ARM64
and x86-64 runners. Bluetooth operation still requires
qualification on the board's kernel, radio and firmware. The existing physical
qualification is Ubuntu 26.04 amd64 with Intel 7265. There is no 32-bit `armhf`
build. The `.deb` format does not imply Debian or older Ubuntu compatibility;
OpenWrt/FriendlyWrt cannot install this package.

```sh
sudo apt install ./plank-tablet-relay-ble_*.deb
sudo editor /etc/plank-tablet-relay-ble/relay.conf
sudo plank-tablet-relay-ble --check-config
sudo systemctl restart plank-tablet-relay-ble
systemctl status plank-tablet-relay-ble
journalctl -u plank-tablet-relay-ble -b
```

On Armbian (detected by `/etc/armbian-release`), installation and upgrades set
`GOVERNOR="powersave"` and `ENABLED="true"` in `/etc/default/cpufrequtils`.
Other settings, including minimum/maximum frequency and boost, are preserved.
The first changed file is backed up to
`/var/backups/plank-tablet-relay/cpufrequtils.before-powersave`. Armbian applies
the governor at boot; the installer does not restart its broader hardware
optimization service. Package removal retains this host setting and backup.
Non-Armbian hosts are unaffected.

### USB radio preparation

The package installs `usb-modeswitch` and its udev rules. The dongle may be
present during installation or plugged in later. Realtek `0bda:1a2b` driver
CD-ROM devices switch into radio mode at installation/boot, and udev handles
later hotplug. Bluetooth firmware is prepared before switching or starting the
relay; no manual eject command or firmware download is needed.

The package includes the unmodified RTL8851BU Bluetooth firmware and config
from a pinned linux-firmware commit, with SHA-256 checks and its Realtek
redistribution license. When the OS lacks a file, preparation creates a fallback
link under `/lib/firmware/updates/rtl_bt/` to the bundled copy. Existing OS or
administrator firmware, including compressed files, takes precedence. If an OS
update later supplies a file, the next preparation removes its fallback link.
Removal deletes only links still owned by this package; bonds, identities and
other firmware remain untouched. It never downloads firmware during install.

On the tested `3625:010b` RTL8851BU (and the Realtek `0bda:b851` identity), a
previously failed firmware probe can be retried by rebinding just the Bluetooth
interface. Initialized controllers are never rebound, even when powered off.
Other Bluetooth adapters and the dongle's Wi-Fi interface are not reset. This
requires an existing kernel `btusb`/`btrtl` driver supporting the chipset; the
package does not install a replacement kernel or USB Wi-Fi driver.

The helper runs as `plank-tablet-relay-hardware.service` before the relay. Inspect
its journal if hardware preparation fails. Dedicated-adapter management also
supports Python before 3.14 by using Linux's native HCI control-channel address.
Ubuntu 26.04 remains the build/installation target; operation on the test
Armbian/Debian image is an additional hardware check, not universal Debian support.

By default, discovery uses the relay hostname (shortened with a distinguishing
suffix if it exceeds 26 UTF-8 bytes). Omit `name` in configuration to use that
default; an explicit `name` remains an override, including in an older retained
configuration. Renaming does not change Bluetooth identity or saved approval.

Installation enables and starts the service. Defaults do not take ownership
of the adapter or apply chipset workarounds. Power the adapter on before use,
or explicitly set `exclusive_adapter = true` on a dedicated relay. That option
powers on the adapter, disables new OS-level bonding, and removes orphan kernel
advertisements only when BlueZ reports no active advertisements or discovery.
It retains existing tablet bonds. Do not run another advertising service on
an adapter configured as exclusive.

To pair a tablet, use **Find tablets to pair** in the headset app. See
[headless tablet pairing and SSH recovery](bluetooth-tablet-pairing.md).
Headset approval happens inside the app; it does not need OS-level Bluetooth
pairing to the relay. The tablet can sleep without forgetting its bond or the
headset's saved approval. Wake it to resume input.

The service retries missing adapters/startup failures and re-registers after
BlueZ restarts. `active (running)` means GATT registration and advertising have
completed; it does not claim a tablet or headset is currently connected.

## AVP Bluetooth compatibility

The package disables BlueZ's optional `battery` plugin. Its unsolicited read
of the headset's Battery Level characteristic can trigger OS-level pairing,
authentication failure and a local disconnect, interrupting the relay app's
independent approval/Noise connection. This was observed on both the Intel
7265/BlueZ 5.85 host and the RTL8851BU/BlueZ 5.82 Armbian host.

Starting with revision 13, installation includes this vendor systemd drop-in:

```ini
# /usr/lib/systemd/system/bluetooth.service.d/10-plank-tablet-relay-ble.conf
[Service]
ExecStart=
ExecStart=/usr/libexec/bluetooth/bluetoothd --noplugin=battery
```

It uses the stock BlueZ executable on the supported Ubuntu Server 26.04 and
tested Armbian image. Installation/upgrades reload systemd and restart an
already-running Bluetooth service, honoring `policy-rc.d`; connected devices
briefly disconnect. The relay restarts automatically, retaining saved bonds.
This policy disables optional GATT battery reporting for all devices on that
BlueZ instance. Package removal removes the vendor drop-in and restarts an
active BlueZ instance with the remaining host policy. Administrator overrides
under `/etc/systemd/system/bluetooth.service.d/` remain administrator-owned;
if they replace `ExecStart`, retain `--noplugin=battery` alongside custom
arguments/plugin exclusions. Inspect `systemctl cat bluetooth.service`.

The older Intel 7265 also requires a separate opt-in controller workaround:
`disable_controller_address_resolution = true` in `relay.conf`. It is applied
before advertising and reapplied when the relay restarts. This does not remove
BlueZ bonds or change saved-key authentication. The Realtek radio established
an AVP link with this option disabled; do not infer that every adapter needs it.

## Saved state, updates and removal

The root-owned `0700` directory `/var/lib/plank-tablet-relay-ble` stores the
relay identity, approved headset public keys and pairing attempt budget.
Systemd and package updates retain it. Package removal and purge also retain
it deliberately. Back it up securely; deleting it changes the relay identity
and requires enrolling headsets again. BlueZ tablet bonds are stored separately
by BlueZ and are never removed by this package.

When migrating a foreground lab, stop it before copying its state into this
directory. Preserve ownership and `0600` file permissions; do not copy keys
into the source checkout. Never run two processes against the same state.
The native store locks itself and refuses unsafe ownership/permissions.

Use `sudo apt remove plank-tablet-relay-ble` to stop and remove the service.
The packaged BlueZ battery-policy drop-in is removed automatically. Explicit
administrator BlueZ overrides remain under administrator control.

## Build and validation

The app and relay share the `Major.Minor.Ancillary` release in `VERSION` and
advance together. The package retains the branch description using Debian's
prerelease separator, for example `0.2.1~visionos-tablet-setup`, with no trailing
build counter. `debian/changelog` must match that shared release; the builder
rejects a mismatch. Apple keeps its required upload identifier separately.
This version sorts after the earlier `0.2.0~visionos-tablet-setup.14` package,
so upgrades do not need a downgrade override.

Install `build-essential cmake ninja-build pkg-config libudev-dev python3
python3-dbus python3-gi debhelper dh-python curl ca-certificates git` in an Ubuntu 26.04
builder. From a clean committed checkout run `scripts/build-relay-deb.sh`.
The script snapshots that commit, verifies the pinned libsodium 1.0.22 archive,
builds it statically with PIC, runs its tests and the relay's assertions-enabled
tests, and creates `.deb`, `.buildinfo`, `.changes` and SHA-256 artifacts in
`artifacts/deb/<software-version>/<distribution>-<version>/<architecture>/`,
for example `artifacts/deb/0.2.1~visionos-tablet-setup/ubuntu-26.04/arm64/`.
The package version comes from `debian/changelog`, checked against `VERSION`;
the exact Git commit is
retained in `source-commit.txt` and `provenance.json` with compiler/OS metadata.
Build natively on the target architecture; the script
rejects cross-builds because the packaged library and its tests must execute.
The prepared source remains under `build/deb`
for inspection. The package includes the libsodium license.

The `Linux relay packages` GitHub Actions workflow builds both architectures
in Ubuntu 26.04 containers, runs the tests, checks the binary with lintian, and
installs it for a configuration/native-library smoke check.
The same binaries are installed, smoke-tested and removed in fresh Ubuntu 26.04
containers on both architectures, including Python bytecode cleanup.
Download the
matching `relay-ubuntu26.04-arm64-<commit>` or `relay-ubuntu26.04-amd64-<commit>` artifact
from the workflow run, then check `sha256sum -c SHA256SUMS` inside its package
directory. CI does not exercise a physical Bluetooth controller or systemd
reboot/recovery; those checks remain part of hardware qualification.

The service runs as root for BlueZ administration, raw controller setup and
read-only input access, with only `CAP_NET_ADMIN` and `CAP_NET_RAW`, restricted
device/address-family access and filesystem protections. It opens no TCP port.
Setup and tablet data use Noise. Initial relay identity pinning is trust on
first use, not out-of-band authentication against a nearby active impersonator.
Existing pins are checked, provisional sessions cannot read input, and owned
relays require an approved headset key. See the enrollment guide for recovery
and the distinction between tablet bonds and persistent headset ownership.
