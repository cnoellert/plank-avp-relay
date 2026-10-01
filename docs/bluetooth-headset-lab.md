# Bluetooth headset input lab

## 0.6.5 development build 37 — management startup deadlines

After the September 30 relay reboot, the first Tablet Test found the relay but
the app canceled its pending Bluetooth connection after about 12 seconds.
The management-status preflight wrapped transport startup and authentication
in one 12-second deadline, cutting short Bluetooth's own 20-second budget.
No tablet stream or authorization exchange started during that failed attempt.
The next manual attempt finished setup in 9.57 seconds and the operator
reported smooth drawing. AVP logs confirmed the persisted 15 ms preference.

Management now waits for transport startup with its existing deadline, then
starts the 12-second authentication timer. Cancellation remains explicit in
both phases and cleanup finishes before releasing management ownership.
Request deadlines, retries and the tablet data path are unchanged. Regression
coverage includes a 13-second transport startup followed by encrypted requests
and cancellation during startup without sending protocol bytes. This removes
the conflicting timers; it does not establish why the first radio connection
was slow or guarantee that waiting the full transport budget would succeed.

## Low-latency LE connection preference

The relay configures its selected adapter for a preferred 15 ms LE interval,
zero peripheral latency and 720 ms supervision before advertising. It uses
Linux's bounded MGMT Read/Set Default System Configuration interface, checks
the returned settings, and reapplies them at service startup and adapter
re-registration. The package includes this code; no per-host startup command
is needed. Unrelated controller settings are preserved. This affects new LE
links on that adapter, not the wireless tablet's BR/EDR connection.

Linux requests an interval update when a new peripheral link arrives outside
the preferred range. The headset decides whether to accept: the startup log
reports configured preferences, not measured negotiated timing. The interface
requires kernel 5.8 or newer, within the supported Ubuntu/Armbian targets.
An unavailable or rejected preference prevents Bluetooth registration through
the existing retry path; it does not stop the TCP listener.

September 30 tests on relay02 confirmed the AVP accepted 15 ms and the operator
reported three smooth wireless drawing runs, including Tablet → Relay → Tablet.
Sustained output was about 200 input records/s, with typical controller
completion timing around 25–35 ms and no sustained measured socket backlog.
Two preceding 30 ms runs delivered about 114–132 records/s and hit the relay's
pending-input guard. The return-to-30 ms comparison failed during connection
setup before drawing, so it cannot establish a controlled throughput reversal.
Some earlier 30 ms runs were also smooth. Startup reliability and longer runs
still need acceptance. Controller completion is not pen-to-display latency.

This change preserves all input reports, their format and ordering. It adds
no application pacing, acknowledgement, frame dropping or buffering layer.
The TCP and app rendering paths are unchanged.

References: [BlueZ MGMT system configuration](https://github.com/bluez/bluez/blob/5.82/doc/mgmt-api.txt)
and Linux's `l2cap_le_conn_ready` in
[L2CAP core](https://github.com/torvalds/linux/blob/v6.18/net/bluetooth/l2cap_core.c).

## 0.6.5 development build 36 — direct byte diagnostic

IMG_0068 and the September 30 16:21 captures expose build 35's remaining
channel-close race. Status completes; the app closes its L2CAP streams at
16:21:48.362 and asks the same central to reopen PSM128 at 48.363. CoreBluetooth
rejects the request as already connected at 48.367. The relay receives the
previous channel's disconnect request at 48.389. No echo channel starts.

Test Relay Connection now opens the echo channel directly, sending its three
payloads on that one connection. It needs no preliminary status connection:
the diagnostic tests byte delivery and neither checks nor establishes trust.
Automatic routing tries eligible routes in order, cleaning up before fallback;
the temporary Bluetooth-only setting still forbids TCP fallback. Cancellation
keeps the operation reserved until transport cleanup completes.

The build 35 physical-link sharing experiment is removed, including its extra
link/session classes. Tablet testing returns to its pre-build35 authenticated
status/observer lifecycle. Input transport, Linux protocol/package, radio
settings and startup deadlines are unchanged. Initial radio establishment
failures remain a separate unresolved issue; removing this diagnostic handoff
does not establish that those failures or drawing backlogs are resolved.

Regression tests run the actual three-payload echo loop on one connection,
fragment replies, check corruption, route cleanup and Bluetooth-only failure,
and verify that cancellation completes teardown before return or fallback.

## Superseded 0.6.5 development build 35 — shared physical link

The September 30 paired captures showed another handoff failure: the status
channel succeeded, but the app canceled its peripheral connection and created
a new central for the echo test. CoreBluetooth attached that central while the
previous link was disconnecting. No echo channel reached the relay before the
startup deadline. Tablet testing could recover through its whole-operation
retry, explaining why it sometimes worked after the diagnostic failed.

In build 35, Test Relay Connection and each Test Tablet attempt owned a single physical
BLE link across their preliminary status and final test channels. Each logical
channel closes its streams before the next opens; the central, peripheral and
discovered PSM remain owned until the operation succeeds, fails or is canceled.
Physical failures retire the link. Cancellation during channel startup also
retires it, so a late OS callback cannot be assigned to a later channel.
Operation completion waits for bounded peripheral cleanup before releasing the
UI. The next operation starts with a fresh owner and discovers its current PSM.

Regression tests exercise actual plaintext status decoding followed by all
three echo round trips on one mock physical link, partial stream writes,
corrupt replies, cancellation cleanup and recovery after a physical failure.
Physical testing exposed the PSM close/reopen race described above; the mock
physical link did not model CoreBluetooth's asynchronous channel teardown.
Input timing, buffering, the relay's backlog guard, radio parameters and TCP
transport are unchanged.

## 0.6.5 build 34 connection handoff

IMG_0067 exposed a scan-only handoff problem after the new L2CAP bootstrap.
The radio trace shows successful status request/reply on PSM128, followed by
closure of that channel. The physical connection remained up for another
33 seconds; the relay resumed advertising only after its disconnection. The
app had started a new central manager and waited for an advertisement, so its
20-second discovery deadline expired before it could open the echo channel.
This happens before tablet streaming and is separate from the GATT backlog.

Before scanning, the app now asks CoreBluetooth for system-connected peripherals
with the relay service, matches the selected peripheral identifier, and calls
connect on that peripheral through the manager that will own the new session.
It still reads the current PSM, opens a new L2CAP channel, and performs the
normal identity/authorization checks. If the selected relay is not already
connected, it scans as before. This does not add saved/offline devices to the
discovery list or fall back to TCP in Bluetooth-only mode. The existing bounded
startup-disconnect retry remains for a physical link that closes during handoff.

## 0.6.4 development transport

The Setup app now requires LE credit-based L2CAP for Bluetooth sessions. The
service UUID remains `462f3a10-7a31-4ab3-9e7f-c36af495ecf0`. A read-only
characteristic, `462f3a17-7a31-4ab3-9e7f-c36af495ecf0`, returns three bytes:
endpoint schema 1 and the kernel-allocated PSM as a little-endian uint16.
Read it on each connection; a restart or adapter replacement can change the PSM.

The Linux listener binds the selected adapter's LE address, sets a 4096-byte
receive MTU after binding, and uses the negotiated send MTU for each socket SDU.
CoreBluetooth exposes the resulting channel as input/output byte streams. Both
sides handle partial records; SDU boundaries are not message boundaries. The
app sends `PLTRLEC1` followed by a channel byte: 0 for the existing authenticated
session, 1 for read-only bootstrap status, or 2 for the bounded echo test.
Channel 0 retains the Bluetooth CPace/Noise transcript, saved keys, ownership,
80-byte input messages, full report order and normal authorization rules.
OS credits control delivery; there is no app-level fragment ACK or timer.

The channel uses application authentication/encryption without requesting an
AVP OS bond. Controller address-resolution setup and the battery-client policy
remain necessary and unchanged. TCP still uses its existing transport and
preface. The old GATT channels remain on the relay temporarily for the already
installed app/comparison; the new app never falls back to them. Remove them
once physical AVP L2CAP acceptance is complete. The older GATT investigation
below explains the original hardware findings, not the new data path.

Tests cover actual sequenced-packet sockets, synthetic evdev input, Noise,
report ordering, MTU fragmentation, credit stalls, authentication and session
cleanup. Apple stream tests cover partial writes, backpressure, cancellation,
disconnect and bounded input. These tests and a successful hardware listener
bind do not establish actual AVP radio throughput. Test sustained pressure and
motion on the headset with Bluetooth only selected before claiming this fixes
the reported half-second backlog failure.


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

The same input adapter is also available as a [managed Debian service](linux-ble-package.md).
Use that package for unattended startup/recovery. The foreground commands below
remain useful for diagnosis; stop the installed service before running them.

## Tablet management extension

The installed relay adds setup RX/TX characteristics ending in `3a15` / `3a16`
within the existing service UUID family. Their presence discovers support;
the existing HELLO bits and readings/pairing channels stay compatible. The
setup channel carries a two-byte little-endian length followed by JSON (512-byte
request, 4096-byte response limits). It exposes status plus initial tablet
setup only while no headset/tablet is enrolled. It never returns tablet samples
or grants a Client approval.

Approved-headset management uses new `TABLET_REQUEST` (48) and
`TABLET_RESPONSE` (49) frames inside the existing Noise link. Both sides must
locally opt in; these are valid only after authentication, in the relay's
pre-observation state. The app checks setup characteristic availability before
using this extension. Request JSON has `version:1`, an operation-scoped integer
`id`, `op`, and an optional `tablet` address selected from the relay's list.
Operations are `status`, `scan`, `pair`, `connect`, `select`, `remove`, `cancel`.
Responses echo the request ID; the app rejects mismatches and invalid bounds.

A setup connection owns its bounded scan/enrollment operation. Competing peers
cannot change its selected candidate. Disconnect/backgrounding cancels it.
Discovery and pairing each allow up to 60 seconds; input verification allows
15 seconds; the complete setup connection is capped at five minutes. Saved
connections do not reopen tablet enrollment when the tablet goes offline.
The temporary BlueZ agent is not made the system default. It rejects unrelated
devices/services and pairing methods requiring PIN entry or numeric comparison.
On Intel configurations using the address-resolution workaround, ending a
setup connection that scanned triggers service re-registration to restore the
controller policy before the next headset connection.

## Operator procedure

### Tablet-free Bluetooth test

To isolate headset-to-relay communication, run the foreground lab with only
its byte-echo service. This mode does not load the crypto library, open an
identity store, or discover/open any tablet input nodes:

```sh
python3 tools/ble-tablet-lab.py --transport-only
```

In Test Setup, scan for **PLANK Relay Lab**, select it, then choose **Test
Bluetooth connection**. The Wacom may be powered off; no tablet button press or
pairing is needed. Three fresh random payloads of64,512 and1024bytes are sent
and compared byte-for-byte with the relay's replies. Success reports three
verified round trips and1600bytes in each direction. Larger payloads exercise
ATT fragmentation and indication acknowledgement. This is a real radio test,
not simulated input; its completion does not authenticate a relay or grant
tablet access. Saved trust is neither created nor changed by the test.

The app rediscovers the selected peripheral using its connection manager before
connecting. Progress and timeout messages distinguish discovery, radio link,
service, channels and reply subscription, with last RSSI when available. Record
the last stage and exact error if it fails. A missing test channel means the
relay must be updated. The regular lab also exposes the test, but rejects
overlap with a pairing or authenticated input operation.

For an independent Apple Silicon Mac comparison, build the standalone probe on
the authorized macOS27/SDK27 builder from a clean source checkout:

```sh
scripts/build-macos-ble-echo.sh "$PLANK_PROBE_OUTPUT"
```

Copy `PLANK Bluetooth Probe.app` to a nearby macOS27 test Mac and launch it in
the logged-in desktop. Allow its Bluetooth request if presented. It uses its
own Core Bluetooth implementation, without RelaySetupKit or the app's pairing
flow. The probe selects an advertising **PLANK Relay Lab**, performs the same
three byte echoes, displays its current stage and writes a timestamped result
to standard output. It exits after a pass, failure or bounded timeout; capture
standard output to a private log when launching remotely. The probe requires
no tablet, identity store, pairing approval or persistent service installation.
Its ad hoc signature is for this local diagnostic, not product distribution.
Close other relay tests while it runs. A discovery-only result is not a pass.

Launch the probe with `--peripheral` to make the Mac an alternate echo endpoint
named **PLANK Mac Echo**. In the headset app, scan again, select that name and
run **Test Bluetooth connection**. This compares the same headset/client with
a different peripheral implementation and radio. Only the two unencrypted echo
channels are exposed; there is no tablet, pairing or identity access. It accepts
one subscriber, limits each subscription to4096bytes, bounds queued replies and
automatically closes its advertising/service after ten minutes. The app's
byte-for-byte comparison determines a pass; the Mac's write count alone does not.

For a comparison that changes the Linux host stack while retaining its radio,
`tools/bumble-ble-echo.py` uses [Bumble's HCI socket transport](https://google.github.io/bumble/platforms/linux.html).
Install `bumble==0.0.235` in a separate virtual environment. Stop the foreground
BlueZ lab, record the controller/service state, stop `bluetooth.service`, and
bring the selected HCI interface down before giving the script exclusive access:

```sh
sudo "$PLANK_BUMBLE_VENV/bin/python" tools/bumble-ble-echo.py --adapter 0 --seconds 600
```

Arrange bounded cleanup before taking over the controller: on exit or failure,
restart BlueZ if it was running, restore the recorded controller settings, and
restart the original foreground lab. A transient systemd unit with a runtime
limit and an `ExecStopPost` restoration script can guard against a lost SSH
session. Do not delete bonds, edit saved relay identities or install a boot
service. Other Bluetooth devices cannot use this controller during the test.

The probe advertises **PLANK Relay Lab** with the existing echo UUIDs, its public
controller address, legacy connectable advertising and a1280ms interval. It
uses LE-only advertisement flags, as in the earlier BlueZ LE-only comparison.
Controller initialization and host behavior differ; this is not a comparison
of only the GATT callback. Connections last at most60seconds and accept at most
4096bytes, with one acknowledged indication at a time and a10second ACK limit.
The process lasts at most15minutes. Pairing requests are rejected, key storage
is in memory, and no tablet or native relay library is used. First qualify with
the independent Mac central; then use LightBlue or the existing headset echo
test. A client byte-for-byte pass, rather than server write/ACK counts, determines
echo success: a client can disconnect immediately after receiving its last reply.

### Controller address-resolution workaround

Physical comparison on the test relay isolated its AVP connection failure to
controller LE address resolution: unchanged Test Setup build4 passes with
resolution disabled, times out with it enabled, and passes again when disabled.
Bumble helped identify this difference; replacing the whole host stack is not
required for this radio. This does not establish that every controller has the
same fault or that the firmware rather than kernel behavior is responsible.

The normal BlueZ lab accepts an explicit opt-in:

```sh
python3 tools/ble-tablet-lab.py --transport-only --disable-controller-address-resolution
```

The same option works with the regular library/state/tablet arguments below.
It sends a single LE Set Address Resolution Enable command with value0 before
advertising, and requires a successful completion within three seconds. The
adapter must be powered, with no scan or BlueZ advertisement active. The raw
HCI socket requires the corresponding controller privileges. No tablet model
is hardcoded, saved bonds are untouched, and application CPace/Noise protection
is unchanged. Default behavior is unchanged without the option.

This is a lab workaround, not a persistent kernel fix. The setting remains
disabled after the lab exits, until another controller configuration change or
power cycle restores it. A fresh lab invocation with the option reapplies it;
no boot service is installed. If BlueZ restarts or the adapter powers off, the
lab stops and requires a restart instead of silently retaining an invalid
workaround assumption. The kernel can also re-enable resolution during other
operations; concurrent Bluetooth operations need further qualification.

During the power-cycle check, a stale controller advertisement survived after
BlueZ reported zero active instances. The next command correctly failed with
Command Disallowed, and the lab did not advertise a false ready state. After
confirming no other advertiser was in use, clearing that orphan with
`btmgmt -i hci0 clr-adv` allowed restart. Do not clear unrelated advertisements
automatically on a shared adapter. The managed package's explicit
`exclusive_adapter` policy checks BlueZ ownership and queries kernel instances
before clearing orphans; the foreground lab still requires manual recovery.

### Closing-link reuse during app transitions

With package revision 13 and TestFlight build 9, a post-reboot failure was
captured between tablet setup and headset approval. The setup channel exchanged
and acknowledged status messages successfully. The app canceled that session,
then opened a new CoreBluetooth central for authorization. The AVP attached the
new session to the old physical link and reported it ready about one millisecond
before processing the relay's disconnect. Service discovery then failed before
any approval request reached the relay. A subsequent attempt on the same boot
completed approval and began authenticated input observation.

This differs from both the Intel controller's address-resolution failure and
the unsolicited battery-read failure. CoreBluetooth's
[cancellation callback does not guarantee immediate physical disconnection](https://developer.apple.com/documentation/corebluetooth/cbcentralmanager/cancelperipheralconnection%28_%3A%29).
Waiting for that callback alone cannot prevent this race.

Build 10 makes one fresh attempt when a disconnect occurs before the reply
subscription is ready. Attempts have separate delegates and share the original
20-second startup deadline. Cancellation, missing services, other failures and
established protocol streams are not automatically retried. No authorization
bytes are replayed. Tests cover this ordering, cleanup, deadline retention and
cancellation. After trying build 10, the operator reported that it seems to fix
the connection issue. Repeated cold-start and pen-position/pressure acceptance
remain pending. Earlier radio link-establishment failures remain a separate
qualification item.

### Unrelated BlueZ battery polling during authorization

Deployment update: this failure was also captured on the RTL8851BU radio with
BlueZ 5.82 on Armbian. It is not specific to the older Intel controller.
Package revision 13 includes the required battery-plugin exclusion for relay
hosts; installation no longer relies on remembering a manual host override.
See [the packaged policy and removal behavior](linux-ble-package.md#avp-bluetooth-compatibility).

After resolving the early link failure, longer authorization attempts exposed
a second interaction. BlueZ acts as a GATT client of the connected headset and
its [battery plugin](https://github.com/bluez/bluez/blob/master/profiles/battery/battery.c)
reads Battery Level automatically. On the tested AVP, that read requires
authentication. The trace shows an ATT authentication error, an SMP security
request, a rejected Bluetooth pairing attempt, then a local disconnect while
PLANK's authorization status indications are still flowing. The same failure
occurs without pressing a tablet button.

For this lab, adding `--noplugin=battery` to the existing `bluetoothd` invocation
avoids that optional read. Preserve other daemon arguments and settings; use
a reversible runtime service override for qualification. Stop the foreground
lab before restarting BlueZ, then restart it with the controller workaround.
The tested Wacom uses Classic HID; its existing bond is retained. This disables
the separate GATT battery profile, not the PLANK three-press approval or saved-key
protocol. It may remove battery reporting for other GATT devices, so do not
apply it globally to unrelated machines. No OS-level AVP bond is required by
the application protocol.

With that override, the regular lab completed physical authorization and logged
an authenticated input observer after the app reconnected with its saved key.
The corresponding capture has no SMP exchange or Battery Level read. The
operator confirmed pen position, pressure and ExpressKeys all update on AVP.
That initial runtime override disappeared on reboot. The managed installation
now documents an explicit persistent override and reapplies the controller
workaround on service startup; see the package guide. Other hardware must be
qualified before enabling either workaround.

### Tablet pairing and readings

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

If the app needs to pair again using its retained Client key (for example after
losing local relay trust or discovering a changed peripheral identifier), the
relay permits the same full approval exchange. Three fresh releases and final
confirmation are required. Existing trust remains intact on cancellation or
failure, and successful re-approval does not add a duplicate allowlist entry.
The journal distinguishes a new headset request from an existing headset
request without logging keys or Bluetooth addresses.

After successful pairing, live readings start automatically. The app waits for
the pairing transport to close, reconnects, authenticates the saved relay and
opts into observation. **Test Tablet** can restart a stopped readout. Tablet sleep leaves the headset link
and trust intact, reports the tablet offline, and clears held input state.
Waking the same tablet rediscovers its nodes and resumes snapshots. Leaving the
app or stopping readings closes the headset link; trust remains in Keychain.
The lab is a foreground diagnostic process, not an installed boot service.

## Transport and protocol

Service UUID: `462f3a10-7a31-4ab3-9e7f-c36af495ecf0`.
RX UUID: `462f3a11-7a31-4ab3-9e7f-c36af495ecf0`, write with response.
TX UUID: `462f3a12-7a31-4ab3-9e7f-c36af495ecf0`, indications.
The independent test uses RX `462f3a13-7a31-4ab3-9e7f-c36af495ecf0` and
TX `462f3a14-7a31-4ab3-9e7f-c36af495ecf0` on the same service. It echoes only
received bytes, binds writes to one LE peer, and closes at4096bytes or30seconds.
Only those test characteristics are exposed in transport-only mode. They do
not parse PLTR messages or expose identity, pairing or tablet data. The test is
unencrypted and unauthenticated; send only generated diagnostic data through it.

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
| 8 | u64 | Linux input report timestamp, monotonic microseconds; relay time for idle/status updates |
| 16, 20, 24 | i32 | Pen X, Y, pressure |
| 28, 32, 36, 40 | i32 | X minimum/maximum, Y minimum/maximum |
| 44, 48 | i32 | Pressure minimum/maximum |
| 52, 56, 60 | i32 | Tilt X/Y and distance |
| 64, 68, 72 | u32 | Attachment generation, observed reports, SYN_DROPPED count |
| 76 | u16 | Active touch contacts |
| 78 | u16 | Reserved zero |

Since 0.6.2, one snapshot is retained for every completed Linux input report,
plus an idle status update each second. Partial reports wait for SYN_REPORT;
position, pressure and button transitions are preserved across reads. Input
timestamps use EVIOCSCLOCKID with CLOCK_MONOTONIC. The existing 80-byte schema
and capability are unchanged. Up to 32 individually encrypted records share
one transport write. There is no fixed 20Hz output limit or model-specific rate.
The queue holds at most 256 reports and fails the test connection if its oldest
report waits over half a second. Slow transport is never hidden by dropping
intermediate positions or growing an unlimited queue. Physical throughput over
each Bluetooth adapter still requires qualification. This is not an AVP system
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
