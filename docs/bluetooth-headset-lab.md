# Bluetooth headset input lab

The standalone Test Setup app can discover a Linux relay over Bluetooth LE,
authorize a pending headset using three presses of one tablet button, and display pen,
pressure, tilt, button and touch readings. This is an explicit diagnostic mode;
raw-HID forwarding to a workstation remains a separate implementation.

The two radio connections are independent: Wacom to relay uses the tablet's
supported transport; relay to headset uses a custom BLE GATT service. Pair the
headset inside the Test Setup app. Three short button presses approve the
current connection locally; the app pins the exchanged relay key and verifies
it on reconnect with Noise IK. Neither a Bluetooth name nor a system Bluetooth
bond authorizes readings.

This button approval is deliberately simpler than the earlier random five-key
challenge, as requested by the operator. It does not authenticate the intended
headset against a nearby active attacker during first pairing. A racing peer or
man-in-the-middle can win initial enrollment despite a short window and one
pending request. Do not describe the gesture as equivalent to secret-code or
QR-authenticated enrollment. Saved-key checks and encrypted observations remain.

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
device group must expose pen X/Y/pressure and a Pad button. Pen, Pad and touch
are grouped by physical USB ancestry or Bluetooth remote identity/local adapter.
Recognized button capabilities include Pad BTN_0..BTN_15 and Home/Homepage;
no model/PID table selects a particular button. The first completed press chooses
the authorization button for that request. On a tablet without Home/center,
use any one supported Pad button three times. Capability discovery and the
physical button still need qualification on each new device family.

The app opens directly to relay discovery, with no Simulation selector. Choose
**Scan for relays**, select the intended relay, then tap **Pair**. There is no
readiness checkbox, SIGUSR1 step or `--pair` switch. The relay reports tablet
availability, press count and a 60-second deadline. Wake the tablet first if
shown offline. Press/release the Home or center button three times, using short
presses. Holds longer than one second do not count; gaps longer than two seconds,
a different button, tablet detach or cancellation reset the gesture. A duplicate
down or autorepeat cannot count as multiple presses. Do not hold the PTH-660's
center button: a long hold has a separate tablet Bluetooth-pairing function.

Only events from the selected tablet and current pending request can authorize
it. Earlier queued input is drained before starting a new peer request. Stopping
or leaving the app cancels the request. An unapproved remote request cannot
consume the persistent physical-attempt budget; the three-attempt/ten-minute
budget is reserved only after the third completed press. Successful confirmed
enrollment resets it. Do not remove saved trust to work around a timeout.

After successful pairing, live readings start automatically. The app waits for
the pairing transport to close, reconnects, authenticates the saved relay and
opts into observation. **Start live readings** can restart a stopped readout. Tablet sleep leaves the headset link
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

Button approval explicitly uses `OPEN` mode3 over link type1. Legacy mode2
still requires its secret-code/manual-window flow and is not silently upgraded.
The button client reuses the existing CPace ephemeral exchange and confirmation
with the public constant `11111`; that value is NOT a secret or proof of
identity. The relay withholds its exchange response until local approval, and
persists the submitted client key only after the final confirmation. Record
sequences and the existing transcript bind the exchange to the pending request.

`PAIR_APPROVAL (36)` is a pre-authentication relay-to-client status, valid only
for the explicit mode3 client while waiting for its response. Its eight bytes
are schema1, tablet-ready0/1, completed-press count0..3, target3, remaining seconds
(u16 LE, max60), and chosen evdev button code (u16 LE, zero before selection).
Status is advisory and cannot establish trust. It is sent at request acceptance,
progress changes and once a second while waiting. No response with key material
is released by one/two presses, a held button or a request that has expired.

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
and cleared offline state. Button tests cover pre-request presses, an offline
tablet, cancellation/retry, duplicate/repeated input, long holds, mixed buttons,
sleep/wake, slow gestures, expiry and confirmation after the third release. Apple builds and physical headset checks must be
recorded separately; compilation and simulated input are not radio evidence.

References: [Apple Core Bluetooth](https://developer.apple.com/documentation/corebluetooth),
[BlueZ GATT API](https://github.com/bluez/bluez/blob/5.85/doc/org.bluez.GattCharacteristic.rst).
