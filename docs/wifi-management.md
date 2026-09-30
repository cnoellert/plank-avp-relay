# Relay Wi-Fi management

Use the Setup app's **Network → Wi-Fi** controls after authorizing the headset
through tablet setup. Enable Wi-Fi, refresh the nearby networks, select a name
and join. Secured rows show a lock; open rows have no security label or icon.
Signal strength is shown separately. Saved networks offer Connect, Update
password and Forget; hidden networks can be entered by name.

WPA2 Personal, WPA3 Personal, open networks and hidden SSIDs are supported.
Enterprise sign-in, WEP/WPA1 and captive portal login are not provided by this
flow. A captive portal network may supply a local address without Internet;
the status means local network connectivity, not Internet access.

The on/off choice is persistent and independent of the Ethernet cable. A new,
unconfigured supported radio starts disabled. Existing configured connections
are preserved at upgrade until an authorized Wi-Fi action takes ownership.
Disabling retains profiles; Forget removes the selected SSID/security profile.
Wi-Fi rfkill uses only the selected WLAN switch, never `rfkill block all` or
the Bluetooth switch. Hardware radio blocks are respected.

The relay may use joined Wi-Fi for its TCP service. DHCP/RA routes installed
by this controller have metric 32760, below ordinary wired routes in routing
preference. Bluetooth management remains available when IP connectivity
changes. **USB Ethernet still uses only the wired Ethernet port** in both
Bridge and Router modes and is withdrawn when that port loses carrier. Wi-Fi
management adds no forwarding, bridge membership, NAT or DHCP server.

## Appliance installation

The `.deb` installs `wpasupplicant`, `rfkill` and the existing network
dependencies. `plank-avp-relay-wifi.service` starts with the relay; its process
name is `plank-avp-wifi`. No manual supplicant launch is needed. Ubuntu Server
26.04 amd64 and Debian 13 arm64 (Armbian) are the package targets. See the
[board/kernel matrix](relay-platforms.md). A working in-kernel WLAN driver,
its firmware and active systemd-networkd are prerequisites. Version 0.5.2
includes missing RTL8851BU WLAN firmware offline and reprobes only a failed
WLAN interface on that supported dongle, without resetting Bluetooth. The package does
not replace kernel WLAN drivers. NetworkManager-managed hosts are reported as
unsupported and left unchanged.

`/etc/plank-avp-relay/wifi.conf` selects the WLAN interface. Blank means detect
the unique WLAN interface; with multiple radios, select one explicitly. A
missing adapter is retried automatically. The helper does not claim Ethernet,
USB or other wireless interfaces.

On the first authorized Wi-Fi action, the controller preserves the existing
native supplicant configuration and records any active netplan or per-interface
supplicant unit. Those units are masked while the controller owns the selected
adapter. The original files remain intact. Runtime-only profiles without a
persistent source are not taken over. The owned networkd file
`/etc/systemd/network/03-plank-wifi.network` uses DHCP and IPv6 RA on that WLAN
interface; this action replaces its prior address policy with DHCP/RA. Static
WLAN address management is outside this flow. Conflicting controller filenames
or earlier networkd rules fail instead of being overwritten.

Private state, profiles and original backups live under
`/var/lib/plank-avp-relay/wifi/` (directory 0700, files 0600). The main relay
service cannot read this directory. Its root-only helper socket is
`/run/plank-avp-relay/wifi/control.sock`. Passwords travel within the existing
authenticated Noise channel and are not put in status replies, discovery,
command-line arguments, logs, app preferences or app Keychain entries. The
supplicant stores the native profile needed for automatic reconnection;
WPA3 requires a recoverable credential. SSH root access can read these files.

Removing the package releases its supplicant interface and networkd file,
unmasks/restarts the original units if present, and retains private profiles
and the current radio policy for reinstall. Existing host files and unrelated
network services are not removed. Restore the original WLAN radio choice
explicitly if abandoning the appliance configuration.

## Requests and recovery

Only the currently authenticated approved headset may use Wi-Fi operations.
Provisional tablet setup and public discovery cannot read Wi-Fi details or
change settings. Commands use the existing bounded management frames, not the
older workstation protocol. `wifi-status` returns public metadata;
`wifi-list` pages available/saved networks eight at a time with a generation
token. Raw SSID bytes and security determine the stable network ID; a display
name alone never selects the target. Unsupported security appears with a lock
and requires a different sign-in flow.

`wifi-enable`, `wifi-scan`, `wifi-join`, `wifi-connect` and `wifi-forget` accept
one UUID operation at a time. The owner-only journal is synced before the
reply, then applies independently of the app. A repeated current UUID returns
the same receipt; different contents with that UUID are rejected. The pending
join secret is removed from the journal after success/failure. A service
restart restores a partially applied profile and resumes the accepted request.
Scans have no profile transaction: an existing scan is shared and the helper
waits for the supplicant's ScanDone signal. Scan errors/timeouts retain the
connection, profiles and previous results; they do not reset the interface.
Failed joins restore the previous native profiles and enabled choice.

The app prefers TCP for reads and scans, and Bluetooth for changes that can
interrupt networking. It retains one authenticated connection across preflight,
command, completion polling and list retrieval. A failed route gets a short
cooldown; confirmation stays on a working route instead of alternating with a
dead endpoint. The app sends a mutation once and confirms the
same UUID on the same authenticated relay. A lost reply or IP change causes
status checks, not a repeated mutation. Stop waiting stops monitoring only.
Refresh checks the relay's result after app inactivity. Connection success
requires supplicant completion and a global IPv4/IPv6 address; no Internet
probe is used. Scan and join deadlines are 20 and 60 seconds respectively.

## Hardware acceptance still required

Software checks include real isolated wpa_supplicant D-Bus profile creation,
WPA2 raw keys, WPA3, open/hidden and non-UTF-8 SSID persistence, replacement,
removal and restart; transaction failure/reboot/lost-reply tests; authenticated
TCP authorization; package installation; and app build/model/UI checks. These
do not exercise a real RF association or DHCP lease. When the relay is back:

1. Upgrade app and relay together and check Bluetooth tablet readings.
2. Enable, scan, join WPA2/WPA3/open networks and a hidden SSID. Confirm lock
   presentation, signal, saved profile and the acquired address.
3. Try a wrong password, update a saved password and forget a profile. Confirm
   the prior working profile returns after failure and no key appears in logs.
4. Disable/re-enable and reboot. Confirm profiles and manual radio choice
   survive, including while Ethernet is unplugged/reconnected.
5. Confirm TCP discovery over joined Wi-Fi and management recovery over BLE.
6. In Bridge and Router, remove wired Ethernet while Wi-Fi remains joined.
   USB must withdraw; it must never forward traffic through Wi-Fi.

Network status refreshes use a separate read-only background task. They never
mark the foreground workflow busy. Opening Wi-Fi entry, leaving Network,
becoming inactive or starting a foreground operation cancels the refresh; a
foreground connection waits for transport teardown before starting. Polls
prefer the LAN and wait ten seconds after completion before polling again.
Changes that can interrupt networking retain their BLE preference and durable
request identity. Active completion checks run every half second on the retained
connection; the app downloads lists once after completion.

Both local helpers serve cached public snapshots independently of backend work.
One worker serializes configuration and backend access, with a bounded request
queue and four bounded socket handlers. A durable receipt is sent before apply
begins; abandoned replies still allow the accepted operation to complete. There
is no fixed two-second apply delay. Idle Wi-Fi refreshes run every two seconds,
active ones every half second; USB retains its one-second cable-check interval.
Saved profile details are cached until the profile paths change or the helper
changes a profile. Verified Wi-Fi ownership is reused until backend recovery.
Unknown/temporarily unavailable status never changes the persisted radio choice.

## Relay communication after Ethernet removal

Authenticated `wifi-status` replies include `tcpPort`, the currently listening
relay TCP port, or null when TCP is disabled. The app combines it with the
connected Wi-Fi interface’s literal addresses to retain a separate route to the
same pinned relay identity. It tries that route before Bluetooth when Bonjour
still returns the withdrawn wired address. These routes are held only for the
selected relay, refreshed with its status and discarded on a confirmed Wi-Fi
disconnect. Failed status requests retain the last confirmed UI settings and
report reconnection instead of implying that Wi-Fi has been disabled.

No command is replayed because of this route fallback. Read-only preflight may
try another route; after an ambiguous mutation reply, only its existing request
UUID is checked. USB remains Ethernet-only in both Bridge and Router modes.
