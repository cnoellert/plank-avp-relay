# PLANK AVP Relay Linux package

`plank-avp-relay` installs the relay used by PLANK AVP Relay Setup: discover
the relay, pair a tablet to authorize the initiating headset automatically, and
view authenticated position, pressure and button readings. It is separate from the
legacy `plank-tablet-relay` TCP/raw-HID workstation daemon. The two services
should not capture the same tablet at the same time.

Version 0.3.0 adds a newly written TCP adapter to the current managed service.
It does not import or launch the older TCP/raw-HID implementation. The same
tablet input, saved relay identity, headset approvals and enrollment rules
serve both TCP and Bluetooth. Only one setup/readings session owns the core.

## Automatic network discovery

`apt install ./plank-avp-relay_*.deb` installs Avahi and the other runtime
dependencies. The systemd unit starts Avahi with the relay at boot. The live
listener publishes `_plank-avp-relay._tcp` through an Avahi D-Bus entry group;
there is no hand-edited service XML file or static IP requirement. Publication
ends with the listener/process and is renewed after Avahi restarts. Removing
the package withdraws its service without removing other applications' Avahi
configuration or the shared daemon.

TCP is enabled by default, including upgrades that retain an older config:

```ini
[relay]
tcp_enabled = true
tcp_port = 28991
```

The listener supports IPv4 and IPv6. `tcp_enabled = false` keeps Bluetooth-only
operation. The app browses the LAN and Bluetooth concurrently, checks network
reachability, and prefers TCP. Allow Local Network access on the headset.
Bonjour needs multicast reachability on the local network; guest isolation or
VLAN boundaries can prevent discovery. An existing restrictive firewall must
allow the configured TCP port and mDNS UDP 5353 on the intended LAN. The
installer does not disable an administrator's firewall or create router rules.

Names and discovery TXT records are hints. Noise proves the pinned relay key
and approved headset identity before input or management. Existing Bluetooth
trust can be used over TCP; an IP change does not create a new relay identity.
As before, first setup pins a public identity on first use and permits only
restricted encrypted tablet setup until the selected tablet is verified.
Discovery alone never grants headset authorization.

Bluetooth registration retries without stopping the network listener. A lost
tablet reports offline over the active connection; a missing radio can defer
interrupted pairing cleanup using its durable journal. New tablet mutations
wait for that cleanup. Version 0.4.0 migrates the previous package namespace
while retaining the identity and saved approvals.

## Product and Linux names (0.4.0)

The product is **PLANK AVP Relay**; the companion app displays **PLANK AVP Relay
Setup**. The repository and Apple bundle identifier are unchanged.

| Purpose | Name or location |
| --- | --- |
| Debian package, main command and process | `plank-avp-relay` |
| Main service | `plank-avp-relay.service` |
| USB Ethernet service | `plank-avp-relay-usb.service` |
| USB process name (`ps`/`top`) | `plank-avp-usb` |
| SSH recovery command | `plank-avp-relay-admin` |
| Configuration | `/etc/plank-avp-relay/` |
| Persistent identity and state | `/var/lib/plank-avp-relay/` |
| USB controller state | `/var/lib/plank-avp-relay/usb/` |
| Private implementation and helpers | `/usr/lib/plank-avp-relay/` |
| Root-only USB control socket | `/run/plank-avp-relay/usb/control.sock` |
| LAN discovery type | `_plank-avp-relay._tcp` |

Install the new package normally with `apt`; it replaces
`plank-tablet-relay-ble`. Before startup, its installer copies the old private
state and configuration into the new locations, preserving the original
copies. It refuses conflicting identities rather than replacing them. A
migration marker prevents subsequent reinstalls from overwriting newer
configuration. BlueZ tablet bonds and the headset's saved Keychain identity
remain intact. Upgrade the Setup app as well to discover the renamed LAN
service; Bluetooth service UUIDs are unchanged.

The new TCP wire starts with eight ASCII bytes `PLTRTCP1` and one channel byte:
0 for current framed Noise traffic, 1 for one length-prefixed read-only setup
status request, or 2 for a bounded byte echo. Noise uses transport domain 2;
BLE retains domain 1. Setup status cannot mutate or cancel an operation.
Connections, record sizes, send queues and timeouts are bounded. This path
does not start a raw-HID worker or implement the older TCP pairing protocol.

## USB Ethernet appliance (0.4.0)

The dedicated relay can present its USB device port as an Ethernet adapter.
**Bridge is the default**, joining USB and wired Ethernet on `plankbr0`. Router
mode supplies a private USB subnet (default `10.55.0.1/24`) and IPv4 NAT through
the wired port. Neither mode checks Internet access. Ethernet carrier gates
USB attachment; removing the cable withdraws the USB adapter. Router mode
still provides its local USB address when Ethernet has link but no upstream
DHCP lease yet. Upstream routing becomes usable when the wired network does.
No Wi-Fi interface is selected as an uplink. Router mode blocks forwarded IPv6;
bridge mode carries the LAN's IPv6 directly. The owned inet firewall also
prevents routing from the USB bridge through other interfaces.

The package installs `iproute2`, `nftables`, `device-tree-compiler`, and the
separate `plank-avp-relay-usb.service`. Its default `enabled=auto` activates
only on Armbian NanoPi Zero2 hardware; x86 Ubuntu Server hosts are unaffected.
The board must use systemd-networkd. Explicit enablement on another board
requires USB peripheral support and hardware qualification. Settings are in
`/etc/plank-avp-relay/usb-network.conf`; ambiguous Ethernet/controller
selection requires explicit names there. A validated private `router_address`
can be changed there to avoid an overlapping subnet. DHCP pool sizing follows
the subnet rather than a fixed 20-address pool.

If the supported board has no active USB device controller, the service can
install an Armbian peripheral-mode overlay. It reports that a relay restart is
required; it never reboots the host automatically. On first configuration it
saves the wired addressing/DNS/routes and forwarding setting privately under
`/var/lib/plank-avp-relay/usb/`. It writes only owned `04-plank-usb*`
networkd fragments and checks that networkd actually selects them. The service
is designed for the dedicated appliance, with routing table 155 and rule
priorities 31000–31002 reserved for it. Other networking managers and complex
pre-existing bridge arrangements are not supported.

The supplied standalone `install-usb-gadget.sh` is not used as a runtime
backend. A recognized installation is backed up to `standalone-before.json`,
its Bridge/Router selection is retained, and its service/configuration is
retired before the new controller takes over. Unknown gadget installations
are left untouched and reported as unavailable. The original supplied script
outside this repository is unchanged. Custom settings such as a non-default
private USB subnet should be set in the new configuration before migration.

The app's **Network** tab has an editable **Network mode** section and a
separate **Connection status** section. Ethernet/USB rows are read-only text
and icons. USB reports the UDC's actual configured/suspended state, so binding
the gadget does not falsely claim a connected headset. Visible status is
refreshed every four seconds when no other operation is active.

Only the already authorized headset can issue `network-status` or
`network-mode` commands through the encrypted management channel. Provisional
tablet setup and public discovery cannot change network settings. The relay
forwards these fixed commands to a root-only, bounded local socket; the app
cannot submit shell commands or configuration paths. The separate service
durably records a request UUID and mode before acknowledging it, delays apply
briefly to let the reply leave, and completes it independently of the app.
An interrupted helper resumes a pending request after restart. An apply error
attempts to restore the previous mode and leaves USB disabled if that fails.

The app prefers available Bluetooth control, then polls the same pinned
identity over available transports to confirm the exact request. A lost reply
does not cause mutation replay or a new pairing. **Stop waiting** cancels app
monitoring; an accepted change continues on the relay. Refresh status to learn
its result. Changes retain tablet bonds and headset ownership.

Uninstall withdraws the gadget, removes owned firewall/network configuration,
restores the original forwarding setting and reconfigures the wired port.
An overlay created by this package is removed from Armbian's boot settings;
its live device-tree effect lasts until reboot. Private backups and saved mode
remain available across removal/reinstallation. Physical AVP USB operation,
both modes, cable transitions and migration on the NanoPi require live testing.

## Hardware baseline

For new hardware, target **Bluetooth 5.0 or newer**, with both BR/EDR (Classic)
and Bluetooth LE, Linux firmware support, LE peripheral advertising, and
simultaneous tablet and headset connections. The version label alone does not
qualify an adapter. USB-connected tablets can use TCP without a Bluetooth radio.

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
sudo apt install ./plank-avp-relay_*.deb
sudo editor /etc/plank-avp-relay/relay.conf
sudo plank-avp-relay --check-config
sudo systemctl restart plank-avp-relay
systemctl status plank-avp-relay
journalctl -u plank-avp-relay -b
```

On Armbian (detected by `/etc/armbian-release`), installation and upgrades set
`GOVERNOR="powersave"` and `ENABLED="true"` in `/etc/default/cpufrequtils`.
Other settings, including minimum/maximum frequency and boost, are preserved.
The first changed file is backed up to
`/var/backups/plank-avp-relay/cpufrequtils.before-powersave`. Armbian applies
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

The helper runs as `plank-avp-relay-hardware.service` before the relay. Inspect
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

The service retries missing adapters and re-registers after BlueZ restarts.
`active (running)` means the TCP listener is open, or Bluetooth advertising is
ready when TCP is disabled. It does not claim a tablet or headset is connected,
nor that a firewall permits access or Avahi publication has finished.

## AVP Bluetooth compatibility

The package disables BlueZ's optional `battery` plugin. Its unsolicited read
of the headset's Battery Level characteristic can trigger OS-level pairing,
authentication failure and a local disconnect, interrupting the relay app's
independent approval/Noise connection. This was observed on both the Intel
7265/BlueZ 5.85 host and the RTL8851BU/BlueZ 5.82 Armbian host.

Starting with revision 13, installation includes this vendor systemd drop-in:

```ini
# /usr/lib/systemd/system/bluetooth.service.d/10-plank-avp-relay.conf
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

The root-owned `0700` directory `/var/lib/plank-avp-relay` stores the
relay identity, approved headset public keys and pairing attempt budget.
Systemd and package updates retain it. Package removal and purge also retain
it deliberately. Back it up securely; deleting it changes the relay identity
and requires enrolling headsets again. BlueZ tablet bonds are stored separately
by BlueZ and are never removed by this package.

When migrating a foreground lab, stop it before copying its state into this
directory. Preserve ownership and `0600` file permissions; do not copy keys
into the source checkout. Never run two processes against the same state.
The native store locks itself and refuses unsafe ownership/permissions.

Use `sudo apt remove plank-avp-relay` to stop and remove the service.
The packaged BlueZ battery-policy drop-in is removed automatically. Explicit
administrator BlueZ overrides remain under administrator control.

## Build and validation

The app and relay share the `Major.Minor.Ancillary` release in `VERSION` and
advance together. The package retains the branch description using Debian's
prerelease separator, for example `0.3.0~visionos-tablet-setup`, with no trailing
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
for example `artifacts/deb/0.3.0~visionos-tablet-setup/ubuntu-26.04/arm64/`.
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
