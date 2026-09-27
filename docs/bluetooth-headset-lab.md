# Bluetooth headset input lab

The standalone Test Setup app can discover a Linux relay over Bluetooth LE,
authorize the headset using five physical ExpressKey presses, and display pen,
pressure, tilt, button and touch readings. This is an explicit diagnostic mode;
raw-HID forwarding to a workstation remains a separate implementation.

The two radio connections are independent: Wacom to relay uses the tablet's
supported transport; relay to headset uses a custom BLE GATT service. Pair the
headset inside the Test Setup app. The app's saved trust is established by the
existing CPace mutual confirmation and verified on reconnect with Noise IK.
Neither a Bluetooth name nor a system Bluetooth bond authorizes readings.

## Operator procedure

Build the relay project with libsodium available. The target `plank_ble_lab`
produces the shared library used by the Python BlueZ adapter. On the relay,
install BlueZ, Python's D-Bus bindings and PyGObject. Use a private, owned 0700
state directory separate from any running production relay. The operator needs
access to the selected Wacom evdev nodes and permission to register a BlueZ
GATT application and advertisement.

```sh
python3 tools/ble-tablet-lab.py \
  --library "$PLANK_LAB_LIBRARY" --state-dir "$PLANK_LAB_STATE" \
  --tablet "$PLANK_TABLET_ID"
```

The tablet selector is a Bluetooth address or physical USB identity. It is an
operator selection, not a model allowlist. With no selector, exactly one Wacom
device group must expose pen X/Y/pressure and at least eight Pad buttons. Pen,
Pad and touch are grouped by physical USB ancestry or Bluetooth remote identity
and local adapter. As with the earlier pairing check, verify the actual eight
ExpressKeys and their order before enrollment; advertised capabilities alone
do not establish a usable physical layout.

In the app, select **Live relay → Bluetooth → Scan for relays**. Select the
intended relay. With the tablet awake, signal this lab process with `SIGUSR1`
to open one 120-second ExpressKey enrollment window, or launch with `--pair`.
Confirm the window is ready in the app and generate the five-key sequence.
Press those physical tablet keys. Each window reserves a persistent attempt;
the existing three-attempt/ten-minute lockout and 60-second attempt deadline
apply. Do not remove stored trust to work around a timeout.

After successful pairing, choose **Start live readings**. The app authenticates
the saved relay and opts into observation. Tablet sleep leaves the headset link
and trust intact, reports the tablet offline, and clears held input state.
Waking the same tablet rediscovers its nodes and resumes snapshots. Leaving the
app or stopping readings closes the headset link; trust remains in Keychain.
The lab is a foreground diagnostic process, not an installed boot service.

## Transport and protocol

Service UUID: `462f3a10-7a31-4ab3-9e7f-c36af495ecf0`.
RX UUID: `462f3a11-7a31-4ab3-9e7f-c36af495ecf0`, write with response.
TX UUID: `462f3a12-7a31-4ab3-9e7f-c36af495ecf0`, indications.
Records retain the existing length-prefixed PLTR framing and link type **1**
in CPace/Noise. Arbitrary ATT fragments feed the existing bounded record reader.
Only one indication fragment is outstanding at a time, paced by confirmation;
queue overflow or a missing acknowledgement closes the connection. Writes are
bound to one BlueZ Device1 peer. No plaintext tablet readings are advertised.

The optional HELLO capability `INPUT_OBSERVER = 0x02` adds two secure frame types
to PLTR version1. Existing clients and TCP services default to capability0x01.
Both peers must advertise0x02 before observer frames are accepted. The new lab
service UUID identifies this endpoint; a legacy endpoint is not silently upgraded.

- `INPUT_OBSERVE (13)`: one byte, 1 starts observation, 0 stops it. Allowed in
  the pre-session authenticated state. Observation and raw-HID sessions are
  mutually exclusive; this does not fabricate SESSION_READY or Host features.
- `INPUT_SAMPLE (14)`: 80-byte version1 snapshot, relay to authorized observer
  only. All integers are little-endian. Layout below.

| Offset | Type | Meaning |
| --- | --- | --- |
| 0 | u8 | Schema version1 |
| 1 | u8 | Flags: attached, pen proximity, tip, eraser, side1, side2 |
| 2 | u16 | Pad button mask in ascending capability-code order |
| 4 | u32 | Snapshot sequence |
| 8 | u64 | Relay monotonic microseconds |
| 16, 20, 24 | i32 | Pen X, Y, pressure |
| 28, 32, 36, 40 | i32 | X minimum/maximum, Y minimum/maximum |
| 44, 48 | i32 | Pressure minimum/maximum |
| 52, 56, 60 | i32 | Tilt X/Y and distance |
| 64, 68, 72 | u32 | Attachment generation, observed reports, SYN_DROPPED count |
| 76 | u16 | Active touch contacts |
| 78 | u16 | Reserved zero |

Snapshots are coalesced for display at up to20Hz, plus an idle status update
each second. Short button transitions may fall between display updates. This
is not a lossless stroke stream, throughput qualification, or an AVP system
pointer device. The Linux observer does not grab input, modify calibration, or
change tablet power settings. A SYN_DROPPED event closes/reopens input nodes to
query current state and is surfaced in the diagnostic UI.

## Validation boundaries

Portable tests cover fragmented BLE pairing and encrypted records, persistent
trust, rejection of unknown clients, mutual observer opt-in, streaming gates,
workstation-session rejection, ATT acknowledgement pacing, bounded overflow
and cleared offline state. Apple builds and physical headset checks must be
recorded separately; compilation and simulated input are not radio evidence.

References: [Apple Core Bluetooth](https://developer.apple.com/documentation/corebluetooth),
[BlueZ GATT API](https://github.com/bluez/bluez/blob/5.85/doc/org.bluez.GattCharacteristic.rst).
