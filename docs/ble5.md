# BLE5 transmission

The off-grid plane is Bluetooth 5 extended advertising: connectionless,
one-to-many, no pairing and no connection. The remaining Bluetooth machinery
(GATT links, MSP sessions, file transfer) exists for payloads that do not fit in
an advertisement.

Related documents: [ble.md](ble.md) (earlier transport overview),
[mesh.md](mesh.md) (routing), [store-and-forward.md](store-and-forward.md)
(delivery to absent stations), [architecture.md](architecture.md) (component
boundaries).

---

## 1. One radio, one advertising set, and it cannot listen while it talks

**The radio is half duplex.** One antenna, time-shared: every millisecond spent
advertising is a millisecond not receiving. A device that advertises
continuously is deaf for roughly half of every second, and on a mesh that is the
wrong trade — a beacon only has to say "I am here", while everything that
carries a message has to be HEARD.

So transmission is a WINDOW, not a state:

| | |
|---|---|
| `ADV_WINDOW_MS` | 5 000 — the beacon is on air |
| `ADV_PERIOD_MS` | 60 000 — how often that window opens |
| Rest of the minute | receiving |

(`android/app/src/main/kotlin/com/xprs/app/Ble5.kt`.) The window is enforced
by the controller itself — `AdvertisingSet.enableAdvertising(true, duration, 0)`
— so a missed callback cannot leave the device transmitting for a whole minute.
Registering a frame while the radio is listening opens the window immediately
rather than waiting for the next minute: somebody just asked for that to go out.

**The advertising set is created once and kept.** Only its enable state cycles.
Stopping and restarting a set is what makes Android hand out a fresh random
address, and that address churn is what filled peers' address books with several
addresses for one device — and got the same address attributed to two different
callsigns seconds apart. One set, one address, a window that opens and closes.

Within the window, frames still share the set in rotation at `ROTATE_MS = 1200`.
Consequences:

- With N frames registered, each is on air approximately 1/N of the window — so
  N matters far more than it used to. Section 2 explains why only one beacon is
  aired.
- A receiver observes a frame only when its scan overlaps that frame's slot
  inside somebody else's window.
- A frame transmitted once may not be observed at all. This is the most common
  cause of behaviour that differs between a desk test and a field test. See
  section 5. **Anything that must arrive takes a link, not the air.**

Frames are keyed and carry a TTL:

```dart
Ble5Bus.instance.advertiseFrame(key, subtype, payload, ttl: ..., prio: false)
```

Re-registering an existing key refreshes its TTL and replaces its data. `prio`
places traffic such as a handshake or a message ahead of presence beacons in the
rotation.

## 2. Framing

All frames are carried in manufacturer data under company id `0xFFFF`, marker
`0x3E`, followed by a one-byte subtype (`Ble5Subtype`):

| Subtype | Name | Contents |
|---|---|---|
| `0x55` | `rns` | one Reticulum packet |
| `0x56` | `rnsChunk` | a fragment of a Reticulum packet exceeding one advertisement |
| `0x41` | `aprs` | the compact direct or group text frame, and carried XPRS mail |
| `0x47` | `presence` | **declared and never transmitted.** Nothing airs this subtype and nothing handles it; the real presence beacon is the legacy connectable advertisement below |
| `0x4D` | `mesh` | **no longer aired.** The route beacon's distance-vector costs and have-bloom are exchanged in full over an MSP session instead, where they are acknowledged. Still read, so an un-updated peer is understood |
| `0x57` | `wfd` | WiFi-Direct negotiation |
| `0x58` | `xprs` | the XPRS discovery beacon (`docs/XPRS.md` section 10.6) |

### The discovery beacon, subtype `0x58`

```
t:observation f:X1A67X link:ble peers:12 mail:3 hears:X1RD89,X32DVA,CT1ABC-9
```

76 bytes, readable without a decoder, aired on the same cadence as the binary
beacon. `peers:` is how many stations are reachable in total and `hears:` the
ones that fitted, so a truncated list is honest rather than silently short;
`mail:` says how many messages this station holds for other people.

`mail:` is why a carried message no longer needs a broadcast of its own. It used
to be registered on the bus for five minutes and refreshed twice inside that, so
a passer-by might catch a copy -- spending the channel on a message almost every
listener had no use for, and stealing rotation slots from the beacons that make
the mesh work. Now the beacon says there is mail, a neighbour that can reach the
recipient opens a session, and everybody else spends nothing.

**Two frames, because two things do not fit in one.** The DV digest is 4 bytes
per destination and the have-bloom is a flat 128; as XPRS text a DV entry costs
about 10 characters and the bloom base85s to 160, so at the ceilings below the
text fits either the routing table or the bloom and never both. The binary
beacon keeps them; everything a person would read moved to `0x58`.

### Compact frame, subtype `0x41`

```
FROM 0x1F TO 0x1F TEXT
```

Three ASCII fields delimited by the unit separator. `TO` is a callsign,
`#group`, `!` for an observation, or a `?` control word. Receipt identifiers,
signatures, ciphertext and the courier's `sd:` address are carried inside
`TEXT`, so any station can read the envelope without interpreting the payload.
A station that cannot determine the intended recipient cannot decide where to
relay the frame.

**This is what the code transmits today, not the specification.**
[XPRS.md](XPRS.md) defines the payload XPRS stations are to carry, and it is a
different shape: `key:value` fields separated by single spaces, a packet type in
the first field, no unit separators, and no positional fields at all.

```
t:msg f:X1QZ3N d:X1RD89 ts:2026-08-08_14:26:40 q:ack m:meet at the bridge at six
```

Nothing in this document changes when that lands. The subtype, the rotation, the
size router and every budget below are properties of the radio and the
controller; the payload rides on top of them. XPRS.md section 36 lists what is
still outstanding.

## 3. Size routing

`BleService.enqueueAdvert(owner, payload, ttl:)` is the single entry point for
outbound broadcast and routes by size:

```
payload.length <= maxPayload   ->  BLE5 extended advertisement
payload.length >  maxPayload   ->  GATT transient link
```

### Controller ceilings, not protocol limits

The observed values are small relative to the BLE5 specification, which invites
an incorrect conclusion:

- BLE5 extended advertising permits up to 1650 bytes of advertising data across
  chained AUX PDUs. That is the protocol limit.
- The controller determines how much it will carry. Android reports this as
  `BluetoothAdapter.leMaximumAdvertisingDataLength`. `Ble5.kt` reads it and
  returns that value minus 8 bytes of envelope as `maxPayload`.
- Measured on two devices, both running genuine extended advertising
  (`setLegacyMode(false)`, non-connectable, non-scannable, `ble5: true`, zero
  advertisement refusals): TANK2 reports 304 bytes, 296 usable; the test tablet
  reports 192 bytes, 184 usable. Low-cost chipsets report small ceilings.
- Neither figure indicates legacy 31-byte advertising. That path exists only as
  `kBleBcastMax = 300` chunked broadcast parcels for devices without extended
  advertising, and as the separate legacy connectable presence beacon used for
  GATT discovery.
- `Ble5Bus.maxFrame = 450` is a local limit, not a protocol limit, and would
  bind first on a device reporting 1650. No device in use does; raise it when
  one appears.

Two consequences, each of which has caused a debugging session:

- An oversized frame is refused, not truncated. The native call returns false
  and `enqueueAdvert` reroutes to GATT. Code that ignores the return value
  transmits nothing while continuing to report BLE5 as operational.
- The custody tap runs before the size router
  (`MeshCustodyDelegate.onAirFrame`), so an oversized frame is parked locally
  and sent point-to-point, and the mesh does not observe it. The log line
  `routing point-to-point` indicates this case.

### Budgets

| Limit | Value | Defined by | Type |
|---|---|---|---|
| BLE5 extended advertising data | 1650 B | specification | protocol |
| Controller advertisement payload | 184 B and 296 B measured | runtime `leMaximumAdvertisingDataLength - 8` | hardware |
| Local frame ceiling | 450 B | `Ble5Bus.maxFrame` | local |
| Chunked parcel, no extended advertising | 300 B | `kBleBcastMax` | fallback path |
| Phone custody store, per frame | 480 B | `MeshStore.maxWire` | local |
| ESP32 custody store, per frame | 252 B | `BLEMESH_SCF_FRAME_MAX` | one un-chained AUX PDU |
| Courier transmission | 240 B | `MeshCourier.maxWire` | mesh interoperability |

For carried mail the courier's 240 bytes is the binding limit. It is an
interoperability figure rather than a radio limit, set below the ESP32's 252 so
that a frame accepted by the phones is not discarded by the station expected to
carry it. Direct phone-to-phone broadcast may use the full `maxPayload`.

## 4. Reception

`_onBle5Aprs` in `lib/connections/bluetooth/ble_service_io.dart` is the inbound
path for subtype `0x41`:

Before any of that, the native side has already filtered twice. `onScanResult`
in `Ble5.kt` drops an advert that carries no `0xFFFF` manufacturer data or whose
first byte is not the `0x3E` marker, and then suppresses a repeat of the same
`(address, subtype, payload)` within `SCAN_EVENT_MIN_MS = 750 ms` — a shorter
window underneath the 130 s one below. Each of those branches increments a
counter (section 6); none of them logs, because that path runs for every advert
in the room.

1. Deduplication by payload hash within `kBleBcastDedup = 130 s`. A sender
   re-transmits identical bytes for the duration of the TTL and the receiver
   presents the frame once.
2. Counted into the `perf: ble5-rx` summary, and logged per frame only under the
   `ble.debug` preference. It used to be one unconditional log line per frame,
   which was affordable only because the path was dead — see section 5.
3. Custody tap, `MeshCustodyDelegate.onAirFrame`: receipts purge parked copies,
   mail for other stations is parked, mail for this station is delivered.
4. The frame is placed on the `inbound` stream that wapps read through
   `hal_ble_scan_read`.

The scan is never suspended. Pausing the extended scan while a GATT link is
active was measured as the difference between 10 of 10 and 0 of 10 messages
delivered: stations stop receiving announces, Reticulum paths expire, and the
resulting failures appear unrelated to Bluetooth. `_scanWatchdog` re-arms the
scan every 2 seconds, off the native `BgService` heartbeat, so it keeps healing
with the screen off. It is deliberately NOT ref-counted: the BLE5 broadcast lane
carries the mesh, Reticulum and every XPRS beacon, and is not a wapp-owned
resource that can be released.

## 5. Known failure modes

**A stopped scan is not a paused scan.** `Ble5Bus.stopScan()` used to cancel the
scan EventChannel subscription. Cancelling fires `onCancel` on the native side,
which nulls the sink `onScanResult` writes to — so adverts kept arriving, kept
incrementing `scanResults`, and were discarded one line later with nothing
logged anywhere. Both resume paths (`_resumeBle5Scan`, `_scanWatchdog`) were
gated on `_scanRefs`, a counter only a wapp's `hal_ble_scan_start` raises, and
the bus's own 150 s silence watchdog was disabled by the same call clearing
`_wantScan`. One GATT link — an ESP32 dialling in is enough — therefore left the
phone deaf for the life of the process while `/api/status` still reported
`advertising: true`, `ble5: true` and a fresh `dialable` peer, because the
legacy discovery scan is a separate scan on a separate channel. Symptom to
recognise: `xprsBeaconsHeard`, `beaconsHeard` and `neighbors` pinned at 0 while
the phone's own beacons go out and stations reply to them. `rxNoSink` in
section 6 names this state directly.

**The endpoint that makes 1:1 possible is three things, and they came up from
the wrong place.** `Ble5.startServer()` opens the GATT server, starts the legacy
connectable presence advert and starts the legacy discovery scan — all three or
none. It used to be reachable only through `BleService.startScan()`, whose only
production caller is a wapp's `hal_ble_scan_start`, and which returned early on
`_central == null` before reaching it. A phone whose chat wapp had Bluetooth off
therefore aired only the extended set, which is deliberately
`setConnectable(false)`: no server to dial, no advert to dial it by, and no scan
to learn anyone else's dialable address. Measured on C61 (nothing) against TANK2
(all three) on the same build, with both sitting at `custodyIn: 0`,
`custodyOut: 0` and no session ever formed. It is now armed from `_initBle5` and
healed on the service heartbeat by `_armGattEndpoint`, for the same reason
`_scanWatchdog` is not gated on `_scanRefs`: this is core transport, not
something a wapp asks for. The re-arm is idempotent and must stay that way —
restarting a healthy advert is what rotates the address (section 2).

**A beacon address is not a dialable address.** The address in an XPRS beacon is
the extended advertising set's MAC, and that set is non-connectable, so a GATT
connect to it cannot complete — Android takes thirty seconds to answer
`GATT_CONNECTION_TIMEOUT(147)`, into logcat, where the app never looks.
`MeshService.onPeerSighting` filed exactly that address as dialable, so every
tick dialled an unreachable peer and armed a backoff with no reason recorded.
Only an address proven by the peer's own connectable presence advert or by a
completed MSP HELLO (`_verifiedAddr`) is dialled now; the rest are reported
under `.mesh.undialable` with the reason, and `BleService.meshDial` says why it
refused instead of returning a bare false into a backoff.

**A frame transmitted once may not arrive.** Register it for minutes and
refresh. The courier transmits at 0, +90 s and +180 s with a 300 s TTL. The
earlier wapp-side path appeared reliable because its repeater re-transmitted at
+75 s and +150 s.

**An ESP32 in a GATT session does not scan.** Frames transmitted during an MSP
session are not received. This is not a sender fault.

**`scf=24` on the ESP32 indicates a full store, not 24 frames for the
observer.** The store holds 24 entries and evicts the oldest, so the count stops
changing under load. Use the `scf` console command to list held entries (target,
`am`, size, age) and `scfclear` to begin a test from empty.

**Asymmetric links are normal.** A device receiving from the ESP32 does not
imply the reverse. Check `neigh=` on the ESP32 and `.mesh.neighbors` on the
phone before attributing a failure to software.

**Android deduplicates scan results.** A station is reported once and then
suppressed, so a peer that appears once and never again is a stack behaviour
rather than a departure. The dial registry therefore retains the last verified
address instead of requiring fresh discovery.

**`hal_log` from a foreground page engine does not reach LogService.** Use the
wapp's own log panel, or the host's `wapp <name>: cmd` lines, rather than adding
`hal_log` and reading `/api/log`.

## 6. Observation

```sh
adb -s <device> forward tcp:3458 tcp:3456
curl -s localhost:3458/api/status | jq '.mesh'   # neighbours, custody, courier
curl -s localhost:3458/api/log?n=200             # perf: ble5-rx, Courier, Mesh
```

ESP32 console at 115200 baud: `status`, `scf`, `scfclear`, `msg <to> <text>`,
`ack <am>`, `beacon`, `transfers`.

`Ble5Bus.radioStatus()` reports transmission attempts, refusals, the interval
since any advertisement was last received, and **where the inbound adverts
went**. It is surfaced under `.mesh.gatt`, refreshed on the 2 s service tick and
cached (a status request must not cost a platform-channel round trip):

| Field | Reads |
|---|---|
| `scanResults` | every advert the radio delivered, before any filtering |
| `rxEmitted` | how many of those reached Dart |
| `rxNoSink` | **arrived while nothing was listening** — deaf, not alone |
| `rxNoMfg` / `rxMarker` | not ours: no `0xFFFF` data, or not the `0x3E` marker |
| `rxDedup` | suppressed by the 750 ms native window |
| `scanning` / `wantScan` / `busScanning` | asked-for vs actually registered |
| `msSinceLastFrame` | silence, in ms |
| `gattServerUp` | the native FFE0 server is open |
| `legacyAdvOnAir` | **the connectable presence advert is transmitting** |
| `legacyAdvFailures` / `legacyAdvLastError` | it was refused, and the `AdvertiseCallback` code (3 = `TOO_MANY_ADVERTISERS`) |
| `legacyScanning` | the legacy discovery scan that hears other peers' presence adverts |

The last four report the GATT endpoint, and until they existed the fields above
described the extended broadcast set only — so a phone with no connectable
advert, no server and no discovery scan looked exactly like a phone in an empty
room. `legacyAdvOnAir: false` with `advOnAir: true` is the state where this
device transmits to everyone and can be dialled by nobody.

The composition is the diagnosis. `scanResults` climbing with `rxEmitted` flat
and `rxNoSink` climbing is a radio that hears perfectly and an app that stopped
listening — which is exactly what a `stopScan` that cancelled the EventChannel
subscription produced, silently, for a whole session (section 5). Without these,
a radio receiving nothing and an environment containing no stations are
indistinguishable.

---
## 9. Which lane carries what, measured on the bench 2026-08-26

Both phones on a desk, TANK2 with **no internet at all** — WiFi off, every DNS
lookup failing. The question: can a device with only Bluetooth fetch a file from
a super-archiver?

**Yes.** 64 KB crossed in 140 s, and a 56 MB app update over the same path.
Nothing was ever paired.

### 9.1 The lanes are not interchangeable, and that is the whole point

The mistake that cost a day was pushing **Reticulum resources through the advert
channel**. They do not go there. The division is:

| what | lane | limit |
|---|---|---|
| XPRS packets | BLE5 extended advertisement, subtype `0x58` | 250 B, one packet per advert, never fragmented |
| file bytes | MSP over a short auto-paired GATT session | ~27 kB/s, offset resume, sha-verified |
| Reticulum | the internet path | not this radio |

XPRS.md §25.2.2 draws the transfer, and it is two XPRS packets around a binary
middle:

```
->  t:command cmd:file file:<ref> [off:]     (advert channel)
<-  t:result  code:202
    FILE_OFFER / ACCEPT / CHUNK / WIN_ACK / DONE / OK   (bulk lane)
<-  t:result  code:200                       (advert channel again)
```

Observed, in that order:

```
XPRS: asking X3ARK for d194663d
XPRS: X3ARK accepted (202)
Mesh: MSP< session with X3ARK caps=0xf pending=0/1
Mesh: MSP< accept xprs-1.2.0-beta.3-android-arm64-v8a.apk from X3ARK at 0/56830760
MeshBulk: received bletest.bin -> .../files/updates/bletest.bin (claimed)
```

### 9.2 "Auto-paired" does not mean bonded

`mesh.md` calls these auto-paired GATT sessions and the BLE status reports
`autoPair`. Both mean the link is **dialled automatically and lives seconds** —
not that anything is bonded. Bonding only happens when a characteristic demands
encrypted access, and ours are plain (`Ble5.kt:1019`, `:1030`). There is no
`createBond()` in the native code and `Ble5.kt:935` says why: *"this transport
must pair with nobody, ever."*

Checked after the transfers: TANK2's paired list held the operator's headset,
watch and car, and nothing from the session. **A pairing dialog is a stop-work
bug**, not a nuisance — it once came from the `ble_peripheral` plugin's GATT
server callback, which is why that plugin is refused on a BLE5 device.

### 9.3 An ask sent once is an ask often lost

The advert channel is fire-and-forget on a half-duplex radio, and §1 already
says a frame transmitted once may not be observed at all. A `cmd:file` sent
once simply vanished some of the time: one six-minute attempt ended with the
holder's `served` counter still at 0.

**Anything that must arrive re-airs until it is answered.** `XprsFileFetch`
re-publishes the same wire every 45 s — the same wire, so `ts:` and therefore
the §5 identifier are unchanged and the answer still correlates. `XprsCatchup`
has done the same for history all along. This is the rule §1 states as
"anything that must arrive takes a link, not the air", applied to the one
packet that opens the link.

### 9.4 A stuck scanner needs a reboot, and the app never says so

TANK2 heard **nothing** for a whole session — `scanResults: 0` against 3769
clean advert attempts — with every permission granted and location on:

```
BleService: scan toggle failed: PlatformException(IllegalStateException,
  Start discovery failed with error code: 2
```

Code 2 is `SCAN_FAILED_APPLICATION_REGISTRATION_FAILED`. A Bluetooth toggle did
not clear it, nor a force-stop, nor both together. **Only a reboot did.** The
registration is stuck below the app, somewhere the app cannot reach.

Two defects followed. **Both fixed 2026-08-31** (`Ble5.kt`):

- the retry had no backoff and no ceiling — every 2 s for the whole session,
  filling the log ring with the one line that explains nothing else. It now
  backs off 60 s, 2 min, 4 min … capped at 15 min, and the scan watchdog
  performs the retry itself: a failed registration left no callback behind and
  nothing was re-arming it, so on a headless phone the scan waited for a Dart
  call that might never come;
- nothing surfaced "this radio is unrecoverably deaf". `radioStatus()` now
  answers with a verdict — `scanDead` (the scan is WANTED, is not running, and
  has failed at least twice), alongside `scanFailures` and `scanLastFailCode` —
  so the deaf device stops looking like a device in an empty room.

The scan MODE is also a dial now (`setScanMode`, 0 LOW_POWER / 1 BALANCED /
2 LOW_LATENCY), driven by the app's power tier: BALANCED with the screen on or
on a charger, LOW_POWER on battery in the background. It is a mode change and
never a stop — §4 above is why — and it is rate-limited by a 60 s dwell,
because a mode change restarts the scan and Android counts scan starts.

### 9.5 What an app update over Bluetooth actually costs

**Measured, 2026-08-26: the whole 56,830,760-byte arm64 APK, C61 to TANK2, with
TANK2 offline the entire time.**

```
Mesh: MSP< accept xprs-1.2.0-beta.3-android-arm64-v8a.apk from X3ARK at 0/56830760
Mesh: MSP< accept ... at 5212068/56830760      (session 2, resumed)
Mesh: MSP< accept ... at 28924836/56830760     (session 3)
Mesh: MSP< accept ... at 49790040/56830760     (session 4)
MeshBulk: received xprs-1.2.0-beta.3-android-arm64-v8a.apk -> .../files/updates/…
```

Five resumed sessions, ~3 hours wall clock. The rate is **not** the 27 kB/s this
document used to quote from the July run: sustained throughput measured between
**7 and 19 kB/s**, and about 40 minutes of that wall clock was a dead stall (9.6
below). Quote 10 kB/s and an hour and a half for a per-ABI APK, and treat
anything better as luck.

The resume is the part that matters and it worked every time: `MSP_SESSION_CAP`
ends a session politely at 300 s, the receiver's `.part` length **is** the resume
offset, and the next session carries on to the byte. Nothing was re-sent.

`size:` on a `t:file` (§6.7.1) exists for exactly this: at 10 kB/s a station
should decline before starting something it cannot finish.

### 9.6 Two phones lose sight of each other; a continuously-advertising node does not

Mid-transfer both phones reported `neighbors: 0` and heard only the ESP32
(`X3GSLC`), for nearly forty minutes, while both were scanning healthily
(`scanResults` climbing, `advOnAir: true`) and C61 was dialling TANK2 every tick
with bulk to move. The transfer sat at 87.61% and did not advance by one byte.

The asymmetry is the clue. **The ESP32 advertises continuously** — one kept
advertising set at a 160 ms interval, no duty cycle at all (`xprsble.c`). **A
phone transmits five seconds a minute** and shares even that window between
every registered frame at `ROTATE_MS`. So a phone is reliably heard by anything
listening, but two phones have to catch each other inside a narrow window that
neither controls, and they can miss each other for a very long time.

Restarting both apps restored contact immediately and the transfer finished at
~19 kB/s. That is a workaround, not a fix. What it points at:

- a bulk transfer with work pending is a reason to widen the transmit window,
  and nothing currently does that;
- `neighbors: 0` while a dial is being attempted every tick is a state the
  scheduler could notice and say out loud, instead of dialling into silence.

### 9.7 Does a bulk transfer make the phone deaf to everyone else? No

Asked during the 56 MB run, and answerable from that run's own logs: the
receiver logged **199 beacons from a third XPRS node** while the transfer was in
flight, and reached `2 of 2 peers`.

It holds because bulk rides a **GATT connection**, which the controller services
on its own connection events, while advertising and scanning continue on the
advertising channels. Different radio time, not the same. And §4's rule is
absolute for a reason: the scan is never suspended, because pausing it during a
GATT link measured as 10-of-10 versus 0-of-10 messages delivered.

What a transfer *does* cost the advert channel is share: the transmit window is
still five seconds a minute, and a phone busy with bulk has more frames
competing for it. Third-party traffic keeps flowing; a single-shot ask into that
window is likelier to be missed. That is why `cmd:file` re-airs (9.3) rather
than trusting one transmission.

**The ESP32 is the exception and it is a hard one**: a dongle in an MSP session
does not scan (§5), so frames aired at it during a transfer are simply lost.
GATT-based file transfer on the ESP32 is deliberately out of scope for now, so
this bites only a dongle acting as an MSP server for something else.


### 9.8 A 1:1 to the phone in the room, measured 2026-08-27

A DM from C61 to TANK2 — one desk apart, TANK2 with no internet — took **ten
minutes**, because an LXMF destination is a Reticulum address and Reticulum
found a path: `via tcp:use.inertia.chat:4242, hops 18`, refreshed three seconds
earlier. Eighteen hops to a phone that has no internet at all.

The fix is two decisions, and neither puts Reticulum on BLE:

1. **Address an XPRS peer as an XPRS peer.** `RnsService.sendLxmf` arms
   `MeshCourier` when the destination belongs to a callsign we can reach by
   radio, packing the same text as a signed XPRS 1:1. The LXMF send still goes
   ahead; whichever arrives first wins and the other deduplicates.
2. **Hand that 1:1 over point to point.** `MeshCustodyDelegate.onAirFrame`
   parks it and returns *"do not air"*, the scheduler dials, and it crosses on
   the MSP MSG lane.

Measured, TANK2 offline:

```
11:44:49.362  Mesh: parked 7316d3 X3ARK -> X1VCVM for custody
11:44:49.363  Mesh: X1VCVM is next to us — handing 7316d3 over, not airing it
11:44:50.537  Mesh: custody of 7316d3 -> X1VCVM (archived)
11:44:50.350  (TANK2) LXMF: carried message from 2dc5d2c0 (via custody)
```

**1.2 s**, against ten minutes. Reverse direction 1.8 s.

#### The mistake that shipped first: gating on a signal nobody transmits

The first version asked `MeshTable.neighbors[peer]` for a **device class** and a
**bidirectional** flag — "is this an Android that hears me back?". Both fields
exist, both are documented, and both are *structurally always absent between two
phones*: that table is filled only by the 0x4D mesh beacon, and
`MeshService._sendBeacon` deliberately airs only the XPRS one. Two beacons
competing for a five-second-a-minute window halve the chance either is heard,
and the DV digest is exchanged in full over MSP anyway.

The feature passed its tests and was **dead on the bench** — `neighbors: 0`
against 466 XPRS beacons heard. Reviving the 0x4D beacon to feed it would have
paid airtime to re-learn something already known.

**Ask the peer, on the lane that will carry the message.** The MSP HELLO already
declares `caps`, and `MspCaps.msgCustody` is exactly the question:

```
Mesh: MSP< session with X3ARK caps=0xf pending=0/1
```

It beats a device class on every count that matters — it is transmitted, it is
proof rather than inference (a completed HELLO means a session with this peer
demonstrably opens), and an **ESP32 excludes itself**: a dongle goes deaf during
a session and relaying is what dongles are for, so it never offers custody and
keeps getting the broadcast it needs to overhear. No new wire field, no beacon.

A peer we have never held a session with has no caps recorded, so the **first**
1:1 is aired normally and the session it provokes records them. Suppressing on a
guess costs 120 s of silence; an unnecessary broadcast costs one advert.

#### Preferring the radio means the internet must be told to stop

`sendLxmf` returns Reticulum's verdict. With the radio delivering, that verdict
is `false` for messages that **already arrived** — so the sender showed the DM
as unsent and spent all seven rungs of the retry ladder, roughly half an hour,
pushing the same bytes into hubs that could not reach the recipient. Observed: a
path request every two seconds, minutes after the message had been read.

`MeshCustodyDelegate.custodyTransferred` now calls
`RnsService.retireLxmfRetriesFor(peer)` when custody went to the **target
itself** (a relay proves nothing about arrival). On the bench it retired a
nine-message backlog at the moment of delivery, and the churn stopped dead:

```
11:44:50.537  RNS/lxmf: X1VCVM took 9 message(s) over the radio —
              retiring the internet retries
```

#### Suppression must never become silence

A frame aired once may not be observed (§1), and suppressing a broadcast also
gives up *passive* redundancy — no third device overhears it and parks a backup.
So a suppressed frame is re-aired **once** at 120 s if the session lane has not
delivered it, from the scheduler's existing tick. 120 s because a dial alone is
allowed 110 s; anything shorter re-airs a message still being delivered.

Verified by killing the target's Bluetooth two seconds after the send:

```
11:56:36.364  suppressed e13b46
11:58:36.400  Mesh: e13b46 not handed over in 120s — airing it once
```

120.036 s, once. When the radio came back, both re-aired frames were received.
`reAired` is reported in `/api/status` `mesh` — it is the only external evidence
this half works, so it is published even though it is normally zero.

**Degrading is the common case, so it must be the cheap one.** When the peer is
not dialable the gate simply says no and nothing changes: no suppression, the
old broadcast path, unchanged timing. Confirmed after a Bluetooth toggle left
C61 unable to see TANK2's connectable advert — the DM parked for custody with no
suppression line, exactly as before this feature existed.
