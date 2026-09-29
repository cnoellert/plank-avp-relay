# Headless Bluetooth tablet pairing

Starting with app build 12 and relay package revision 14, setup is one flow:
**discover the relay → pair or reconnect the tablet → automatic headset
ownership → live readings**. No separate tablet-button confirmation is needed.

## Pair using the headset app

1. Select the relay hostname in the app.
2. Choose **Find tablets to pair**, put the tablet into Bluetooth pairing mode,
   and select it. Discovery is bounded to 60 seconds.
3. The relay verifies a persistent Bluetooth bond, Wacom vendor identity, HID
   service and matching pen/pad input capabilities. Names are selection hints,
   not verification. A retained saved tablet can instead be selected with
   **Connect** or **Use this tablet**.
4. Successful verification saves the headset that initiated this encrypted
   setup session. The app saves the relay identity and starts live readings.

On an owned relay, **Manage tablets** adds, connects, selects or removes tablets.
Stop live readings first. Removing a tablet requires confirmation and removes
only that tablet's bond. The headset remains authorized and can immediately add
another tablet. Sleep or radio failure does not remove either relationship.

Public setup status and the public relay identity are read-only. All tablet
mutations use Noise. An unowned relay allows one provisional Noise session,
bound to the initiating headset's proven static key, but restricts it to tablet
management, keepalives and disconnect. It cannot start readings or raw HID.
Only successful tablet verification commits that headset key to the allowlist.
The setup connection remains restricted after commit; readings open a fresh
normal authenticated connection. No public status flag alone grants app trust.

The first relay identity is learned from the device selected by the operator
and pinned before changing tablet state. This is trust on first use, not
out-of-band authentication against an active nearby impersonator. Existing
pins must match. Encrypted setup prevents passive disclosure and binds the
completed operation to the initiating headset; it is not a claim that a
Bluetooth name proves human ownership. Normal reconnections use the saved
relay key and the persisted headset allowlist.

If the app loses only its saved relay key, its retained private headset identity
can authenticate again to the relay's existing approval. The app restores the
relay key only after authenticated status confirms that approval. A different
headset key cannot take over an owned relay. A pending relay-identity pin also
allows recovery if setup committed on Linux just before the app was interrupted.

The temporary BlueZ agent accepts only the selected device's HID service and
never becomes the system default. PIN/passkey entry and numeric comparison are
not supported. Pair/connect attempts time out, restore the previous bondable
state, and clean up only newly created provisional bonds. A durable journal
cleans interrupted attempts on restart. Existing bonds and approvals survive
cancellation or failure. A crash after ownership is committed may require
reconnecting or adding the tablet again, but the same headset can authenticate.

## Ownership recovery through SSH

A lost/replaced headset requires an explicit ownership reset:

```sh
# Revoke headset approvals; retain relay identity and tablet bonds.
sudo plank-tablet-relay-admin reset-headsets --yes
# Optional: remove only a chosen obsolete tablet bond.
sudo plank-tablet-relay-admin remove-tablet AA:BB:CC:DD:EE:FF --yes
```

The replacement headset can then select the retained tablet or pair a new one;
successful verification saves its ownership. No bond deletion is needed merely
to reset headset ownership. The confusing app-side local-forget control is
removed. These commands stop the relay, hold its state lock, privately back up
enrollment metadata, perform the operation, and restart the service. No hardware
button or web UI is required. Never delete the identity directory to recover.

An explicit `tablet` selection in `relay.conf` disables app management until
cleared through SSH. The procedure below remains useful for diagnosis.

## Device policy

Do not select by a particular product ID, generation, advertised name, or a
fixed Bluetooth address. Select the intended device during a bounded discovery
window, then check the resolved HID service, Wacom vendor identity and actual
Linux input capabilities. Advertised names are selection hints, not identity
verification.

The relay requires Wacom pen and pad input capabilities, including at least one
usable approval button. Check the tablet’s available keys, pen motion and pressure. Match the
Pad, pen and hidraw nodes to the same physical device. USB and Bluetooth product
IDs can differ for the same tablet; do not reuse a USB product-ID filter for
Bluetooth. A Touch Ring center button can appear as an additional Pad key and
must not silently count as a missing ExpressKey.

## Pair over SSH

On Ubuntu, install `bluez` and make sure `bluetooth.service` is running. The
kernel must provide the Wacom driver and Bluetooth HID support. A graphical
desktop, Wacom desktop utility and NetworkManager are not required.

Put the intended tablet into Bluetooth pairing mode using its own instructions.
For the PTH-660 used in the first hardware check, unplug USB, power it on, then
hold the Touch Ring center button for approximately three seconds. This is an
operator instruction for that test device, not a supported-model restriction.

Run `sudo bluetoothctl` in the SSH terminal. Execute each command after the
previous command has completed; agent registration is asynchronous.

```text
power on
agent off
agent NoInputNoOutput
scan on
```

Inspect candidates with `info <tablet-address>`. A device can advertise more
than one endpoint. On the tested tablet, the BR/EDR endpoint identified itself
as an input tablet and resolved the HID service; a separate LE advertisement
was also visible. Do not assume every LE advertisement is the pen-input
endpoint, or make BR/EDR a requirement for every Wacom generation.

Once the operator has selected the intended tablet:

```text
scan off
pairable on
pair <tablet-address>
info <tablet-address>
```

Require both `Paired: yes` and `Bonded: yes`. In the first hardware check,
pairing while the controller was not bondable reported success but created a
temporary key; the device immediately became unpaired on disconnect. Enabling
pairable/bondable mode during enrollment produced a persistent bond.

Verify the resolved Wacom identity and HID service. A BlueZ Modalias beginning
`usb:v056A` describes the vendor-ID namespace, even for a Bluetooth connection;
it does not mean the tablet is connected by USB. Classic HID uses UUID
`00001124-0000-1000-8000-00805f9b34fb`; HID over GATT uses
`00001812-0000-1000-8000-00805f9b34fb`.

Authorize only the selected tablet's HID service if prompted. For this
operator-controlled procedure, explicitly trust the selected tablet and connect:

```text
trust <tablet-address>
connect <tablet-address>
pairable off
info <tablet-address>
quit
```

Do not remove an existing bond merely to reconnect. A normally awakened tablet
can reconnect using saved trust; `connect <tablet-address>` also requests a
connection. Inspect the final state and Linux input nodes even if an explicit
connect attempt races with a connection initiated by the tablet.

## Verify Linux input

Inspect `/proc/bus/input/devices`, `/sys/bus/hid/devices/`, and
`/sys/class/hidraw/`. For Bluetooth, expect input bus `0005`, Wacom vendor
`056a`, and the selected tablet's address in `uniq` / `HID_UNIQ`.

The tested BlueZ configuration uses UHID. Its pen, touch, Pad and hidraw nodes
share a HID ancestor under `/sys/devices/virtual/misc/uhid/`. This is real local
Bluetooth hardware exposed through UHID, not a USB device. Match both the remote
identity and the local adapter, and verify common device ancestry. Do not join
unrelated tablets just because they have the same vendor/product or names.

Read the selected tablet's evdev capabilities and events without grabbing it:

- Pen: absolute X/Y, tip/buttons and varying pressure.
- Pad: available physical tablet buttons, including releases.
- Verify touch and ring input separately where available.
- On disconnect, close vanished descriptors and rediscover; event numbers and
  HID instance suffixes are not persistent identities.

Device-node permissions matter when this moves into the daemon. Root access
during an SSH check does not prove the `plank-relay` account can read evdev and
read/write hidraw. Scope future permissions to Wacom hardware; do not make all
input devices world-readable.

## Investigate idle disconnects

Check BlueZ's `Connected` property and the selected tablet's input nodes when
the symptom occurs. A dark Bluetooth indicator does not by itself establish
a disconnected link. For the tested PTH-660, Wacom documents that the blue
connection LED lights for only five seconds. A short power-button press puts
the tablet to sleep or wakes it; the Touch Ring center button also wakes it.
These controls are model-specific operator guidance, not enrollment policy.
See the [Wacom user manual](https://cdn.wacom.com/u/support/wiki_migration/b/bb/wacom_intuos_pro_user_help.pdf),
Bluetooth connection and hardware-feature sections.

Wacom's [current Bluetooth help](https://101.wacom.com/UserHelp/en/Wireless_Bluetooth_Full.htm)
describes an automatic shutdown after 15 minutes of pen inactivity. Include an
observation beyond that interval when investigating idle behavior, and record
the last actual input separately from the start of monitoring. Do not assume
that every model or firmware has the same timeout or wake controls.

Record the last physical input and any button presses alongside a passive
`btmon` trace and BlueZ/kernel logs. Distinguish a remote disconnect, a local
disconnect request, a link timeout and a USB adapter reset before changing
power settings. Bluetooth traces can contain bond keys and input data; keep
them private and out of the repository. A retained bond permits reconnection
but does not establish that an idle connection remains up.

## Hardware evidence, 2026-09-27

An Intel Wireless 7265 Bluetooth adapter, BlueZ 5.85 and Linux 7.0 were checked
with one PTH-660. No model-specific pairing code or driver configuration was
added.

- Pairing with a `NoInputNoOutput` agent succeeded over SSH.
- BlueZ reported paired, bonded, trusted and connected.
- Linux bound `wacom` to Bluetooth identity `056a:0360` and created pen, touch,
  Pad and hidraw nodes under one HID device.
- Physical input produced pen events and pressure values from 0 through 7479,
  touch events, all eight ExpressKeys (evdev codes 256–263), and the ring center
  button (264).
- The tablet disconnected near the end of the input check. The temporary
  observer received `ENODEV`; the operator's cause of disconnect was not yet
  confirmed. The saved bond survived and the tablet reconnected without pairing
  again, recreating all input nodes. A later post-reboot capture verified input
  after reconnection as described below.
- The kernel logged `unknown main item tag 0x0` while parsing the descriptor;
  driver binding and the above input events still succeeded.
- A full relay reboot was verified by a changed kernel boot ID. BlueZ started
  automatically and retained `Paired`, `Bonded` and `Trusted`. The tablet later
  reconnected with the existing bond and recreated its Wacom input/hidraw nodes,
  without another pairing operation.
- A 90-second physical input capture after reboot and reconnection completed
  successfully: pen X/Y, pressure from 0 through 8191, tilt, touch, and one
  press/release for each of the eight ExpressKeys and the ring center button.
  None of the three evdev streams reported `SYN_DROPPED`. This checks Linux
  input delivery; it does not measure Bluetooth packet loss or relay latency.
- A subsequent six-minute passive idle observation found no disconnect.
  BlueZ remained connected, the HID node remained present, and the Bluetooth
  trace contained no HCI/ACL traffic during the observation. The observer did
  not hold input devices open or send keepalives. Battery capacity reported
  100%; the adapter stayed runtime-active despite USB autosuspend being
  enabled. BlueZ's input idle timeout was at its disabled default. No power
  settings were changed. This did not reproduce the operator's reported
  short-idle drop or establish its cause; a later observation captured a real
  disconnect as described below.
- During a longer idle observation, at 22:01:55 UTC, the tablet sent two L2CAP
  disconnection requests and the controller reported `Remote User Terminated
  Connection` (`0x13`). There was no host HCI Disconnect command. The adapter
  remained active through the disconnect and suspended about three seconds
  afterward. BlueZ retained the bond and trust while the Wacom input nodes
  disappeared. This identifies a tablet-initiated disconnect; the reason code
  alone does not distinguish automatic sleep from a physical sleep-button
  press. The operator confirmed the tablet was untouched, supporting automatic
  sleep as the cause, consistent with the manufacturer's idle-sleep behavior.
  The disconnect occurred 289 seconds into this second trace; monitoring had
  begun after the tablet was already idle, so this is not its sleep timeout.
- After the operator briefly pressed the Touch Ring center button, BlueZ
  reported connected at 22:08:26 UTC and the Wacom nodes reappeared by the next
  one-second sample. Reconnection used the existing bond without a new pairing,
  trust change or host-side `connect` request. Subsequent strokes produced pen
  X/Y, tilt, pressure from 0 through 7709, four tip press/releases and touch
  events, with no `SYN_DROPPED` notifications. The observation was stopped after
  this successful wake/input check, 724 seconds into the second trace; the
  initially planned 20-minute window was no longer needed after capturing the
  disconnect and recovery. The exact inactivity timeout was not measured from
  a timestamped last pen event.

This qualifies the tested Bluetooth connection and observed inputs only. Other
models, prolonged operation and PLANK raw-HID forwarding over Bluetooth remain
unqualified. Keep machine addresses and bond keys out of this repository.

## Implementation boundaries

The packaged service implements the bounded BlueZ workflow above. Bootstrap
requests use dedicated setup characteristics, while approved-headset management
uses encrypted request/response frames. One setup connection owns an operation;
disconnect and inactivity cancel it. The tablet selection is persisted separately
from the headset allowlist and the BlueZ bond store.

Upstream raw-HID worker forwarding over Bluetooth remains separate work. Do not
edit its vendored snapshot alone: CMake checks source hashes. Headless tablet
enrollment does not claim raw-HID workstation forwarding is qualified.

References: [BlueZ Device API](https://github.com/bluez/bluez/blob/master/doc/org.bluez.Device.rst),
[Agent API](https://github.com/bluez/bluez/blob/master/doc/org.bluez.Agent.rst),
[Adapter API](https://github.com/bluez/bluez/blob/master/doc/org.bluez.Adapter.rst),
[Wacom Bluetooth guidance](https://support.wacom.com/hc/en-us/articles/8495786896791-How-can-I-diagnose-an-issue-with-my-Bluetooth-connection-on-Wacom-device).
