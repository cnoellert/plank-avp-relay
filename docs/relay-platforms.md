# Relay platform targets

The x86 package targets **Ubuntu Server 26.04 / amd64** on Intel hardware.
The ARM package targets **Debian 13 / arm64**, the userspace base of the
currently selected Armbian NanoPi images. Different board kernels do not
require separate relay binaries: the relay uses userspace Bluetooth, input,
networking and USB configuration interfaces, and ships no kernel module.

## Current board matrix (checked 2026-09-29)

| Hardware | OS image / userspace | Kernel baseline | Qualification |
| --- | --- | --- | --- |
| Standard Intel hardware | Ubuntu Server 26.04, amd64 | Distribution kernel | Existing x86 relay target; USB gadget depends on hardware |
| FriendlyElec NanoPi Zero2 | Armbian Minimal, Debian 13, arm64 | **6.18.54 current**, explicitly selected by the operator | Existing relay board; Wi-Fi/USB acceptance of 0.5.0 pending |
| FriendlyElec NanoPi R28S | Armbian Minimal, Debian 13, arm64 | Published image currently uses **6.1.172 vendor** | New board, physical qualification pending |

Sources: [Zero2 Armbian images](https://armbian.com/boards/nanopi-zero2),
[R28S Armbian images](https://armbian.com/boards/nanopi-r28s).
Both board pages currently label their images community rolling builds.
The operator's existing Zero2 inventory reports Armbian
26.11.0-trunk.62 / Debian 13 with `6.18.54-current-rockchip64`; the board is
currently unavailable, so this is saved inventory, not a new live inspection.

Armbian provides each board's bootloader, device tree, kernel, drivers and
firmware. A Zero2 image must not be flashed onto an R28S just because their
CPU architecture matches. Their Armbian configurations select different
device trees and kernel targets: [Zero2 board configuration](https://github.com/armbian/build/blob/main/config/boards/nanopi-zero2.csc),
[R28S board configuration](https://github.com/armbian/build/blob/main/config/boards/nanopi-r28s.csc).
The common relay package contains its own versioned application and detects
available interfaces; it does not replace the board's kernel.

## What varies with the kernel and board

- **Bluetooth:** controller driver/firmware, simultaneous tablet/headset links,
  privacy/address-resolution behavior, cold boot and reconnection.
- **Wi-Fi:** working WLAN driver/firmware, nl80211 support, a distinct WLAN
  rfkill switch, scan/association and DHCP/IPv6 address acquisition. The R28S's
  onboard radio needs its own acceptance test; testing a USB Realtek adapter
  on Zero2 does not qualify the R28S radio.
- **USB Ethernet:** peripheral-capable port, UDC, configfs, NCM/ECM modules,
  device-role switching and device-tree overlay support. The helper discovers
  the live tree and controller rather than relying only on a kernel number.
  Automatic gadget enablement currently applies to Armbian Zero2 only. R28S
  has two Ethernet ports, so its physical uplink must be selected and its USB
  configuration qualified before enabling it; it is not automatically treated
  as a Zero2. See `usb-network.conf` and the [USB guide](linux-ble-package.md).

Use Armbian **Minimal** for this appliance: it uses systemd-networkd, matching
the relay's Wi-Fi/USB controller. Standard CLI/desktop images normally use
NetworkManager, which the controller deliberately does not take over. See
[Armbian networking documentation](https://docs.armbian.com/user-guide/networking/).

## Builds and acceptance

One Debian 13 arm64 `.deb` serves both NanoPi targets. Keep the Ubuntu 26.04
amd64 package separate because architecture and userspace dependencies differ.
If another ARM board uses an Ubuntu base or a different Debian release, check
the package dependencies and userspace APIs before declaring it supported.
Board-specific driver modules, if ever required, would have to match the kernel;
they belong to the OS/driver package, not a new relay application build.

CI builds natively on amd64 Ubuntu 26.04 and arm64 Debian 13. Package tests
exercise installation, reinstallation, private-state retention, removal and
old-namespace migration. Containers validate userspace compatibility; they do
**not** boot the Armbian kernels or establish real RF/USB compatibility.

For each physical board/image combination, record `/etc/os-release`,
`/etc/armbian-release`, `uname -r`, architecture, radio driver/firmware and USB
controller. Then run saved-headset reconnection, tablet position/pressure,
Wi-Fi join/off/reboot and USB Bridge/Router cable-gating tests. A kernel update
keeps the same relay package but should repeat those hardware checks.
