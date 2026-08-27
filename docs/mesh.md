# BLE Street Mesh — design & implementation plan

Status: **partly implemented** — gossip beacons, DV routing, MSP sessions, GATT
custody transfer and store-and-forward are live and device-validated; the wider
congestion/politeness work in this document is not.
Scope: street / small-village scale (100s of phones), text messages and small
bursts, no infrastructure. Cellphones are the primary devices; battery matters.

**Owner planes (corrected 2026-08-06).** Everything on the wire belongs to the
core: the BLE bus, GATT/MSP, custody storage, routing AND the store-and-forward
decision. A wapp is an event-driven consumer and owns none of it — see
[architecture.md](architecture.md). Where this document says the chat wapp owns
routing or gossip, it is describing the original plan, not the code:
`lib/services/mesh/` owns it, and [store-and-forward.md](store-and-forward.md)
describes what shipped.

---

## 1. Problem

Today's BLE-for-APRS is a 1-hop digipeater flood: every station that hears a
message re-airs it once (`wapps/chat/main.c` `rq_push`, dedup rings). Cost per
message is O(N) transmissions — at 100 devices in range, ~100 rebroadcasts of
*every* message, all contending for each phone's single advertising set. The
compact wire format has no hop/TTL field; loop control is only content-hash
dedup. This cannot scale to a crowded street.

Goal: any two people within ~6 BLE hops can exchange messages reliably, with
messages surviving devices that move out of range and return later, while the
radio stays quiet enough to actually work in a crowd.

## 2. Constraints (measured from the codebase, keep in mind throughout)

| Constraint | Value | Where |
|---|---|---|
| Advertising sets per phone | 1, multiplexed round-robin | `Ble5.kt` (`ROTATE_MS=1200`) |
| Distinct frames a phone can present | ~0.83/s | same |
| BLE5 extended advert payload | ~450–500 B usable | `ble5_bus.dart maxFrame=450` |
| Legacy advert payload | 31 B (~42 with scan-rsp); 13–17 B/chunk | `ble_reassembler.dart` |
| Primary advertising channels | 3 (37/38/39), no CSMA — collisions rise with density | BLE spec |
| GATT (point-to-point) | MTU 512, auto-pair transient link exists (FFE0/FFF1/FFF2); hops 37 data channels w/ AFH | `Ble5.kt`, `ble5_bus.dart` |
| GATT concurrency | ~4–7 practical; connect costs 1–2 s | Android reality |
| Connectable advertisers | scarce — extended broadcast set must stay NON-connectable (status-147 starvation); GATT discovery uses the separate legacy connectable beacon | `Ble5.kt` |
| Android scan behaviour | batched bursts, gaps tens of s to ~2 min; ~5 scan-starts/30 s throttle; unfiltered (company-id 0xFFFF demux in software) | `ble_service_io.dart` |
| Devices that can't extended-advertise | scan-only leaves (e.g. C61) — can hear + GATT-dial out, can't beacon | `Ble5.kt isSupported()` |
| Battery | scanning dominates drain, advertising is cheap | Android reality |

Two consequences drive the whole design:

1. **Radio is scarce, storage is free.** Multicast only tiny control traffic at
   a low, load-adaptive rate. Bulk data moves over GATT unicast, which uses the
   37 frequency-hopped data channels — most robust exactly when the street is
   crowded, which is when the 3 primary advert channels collapse.
2. **Hearing is eventual, not instant.** Any per-advert signal can be missed
   for up to ~2 min. All reachability must integrate over tens of seconds;
   delivery must tolerate per-hop latencies of seconds to tens of seconds
   (6 hops ≈ 30 s–3 min end-to-end — acceptable for messaging, absorbed by
   store-and-forward).

## 3. Architecture — two planes

### Plane 1: Gossip (connectionless broadcast, control only)

Each advertising-capable node airs a periodic **route beacon** on the shared
BLE5 bus (new subtype, e.g. `0x4D` MESH, alongside 0x41 APRS / 0x55 RNS / 0x47
presence). It carries *only* control state — never message payloads:

```
[ver1][callsign≤9][cond1][class1][ dv: (hash3, cost·4bits)×K ][ have: bloom ]
```

- **callsign** — sender, plain (same identity as APRS/chat).
- **class byte** — device type, self-declared: phone / tablet / computer /
  router-hub / ESP32-dongle / base-station appliance / other. Shown in the
  Bluetooth wapp (§12) and an input to custodian scoring (a router or dongle
  is stationary and powered by definition; a phone is not).
- **cond byte** — node conditions:
  - bit 0: powered/charging → may scan continuously, accept many GATT sessions
  - bits 1–3: uptime, log bucket (<10 min … >3 days) → stability
  - bits 4–5: mobility: stationary / semi / moving (position variance over
    ~30 min via existing GPS HAL, or significant-motion) → base-station signal
  - bits 6–7: storage headroom bucket → custodian eligibility
- **dv digest** — distance-vector routing table export: 3-byte callsign hash +
  4-bit cost per entry (~3.5 B/entry → ~110 destinations per 450 B advert; a
  200-node village = 2 rotating beacon frames). 2-byte hashes collide too often
  at this scale (~30% birthday at 200 nodes); 3 bytes makes collisions
  negligible.
- **have digest** — small rotating Bloom filter (~128 B) of `am` message ids
  this node has *received* recently. Purge signal for store-and-forward (§6).

Beacons supersede (one bus key, latest wins) — never queue-flood.

### Plane 2: Data (GATT unicast, per-hop custody)

Messages move node→node in **short auto-paired GATT sessions** (<5 s,
serialized) to the chosen next hop. Custody transfer per hop:

```
open GATT → hand over queued message(s) for/via that peer → in-session ack
→ custody transferred; my copy demotes to archive
```

One session flushes *everything* pending for that neighbor: messages in
transit, parked mail for targets it reaches, receipts, and (see below) a full
gossip exchange. The auto-pair GATT path already exists (the >450 B size-router
branch); it needs a mesh service channel on top.

**GATT peering (two-tier gossip):** whenever two nodes connect anyway, they
also swap full neighbor tables, contact histories, and have-digests — far
richer than what fits in adverts. Adverts carry the compressed digest; peering
carries the full map.

Broadcast **cost-gradient forwarding** (re-air only if strictly closer to the
target, TTL-limited) is retained only as a *fallback* when GATT to the chosen
next hop fails repeatedly.

## 4. Routing — lightweight distance-vector

Classic RIP-style DV with the standard guards, seeded by the beacons:

- **Learn:** for each `(dest, cost)` in a neighbor N's beacon: if
  `cost+1 < myCost[dest]` → route `dest → via N, cost+1`.
- **Hop cap 6.** Cost is 4 bits; 7 = infinity. Kills count-to-infinity fast and
  matches street geometry (~1 km at 50–100 m per hop).
- **Split horizon:** never advertise a route back to the neighbor it came from.
- **Bidirectional check:** N is usable as next-hop only if N's beacon lists
  *me* among its neighbors (asymmetric links are common on BLE; a one-way
  neighbor is a black hole). Free to verify — the digest carries it.
- **Aging:** a route expires when its via-neighbor's beacon goes silent past
  the reach window (reuse `REACH_WINDOW`-style aging, integrate over ≥60 s to
  ride out scan gaps).
- **Triggered updates:** beacon immediately (subject to politeness, §7) when a
  route changes; otherwise periodic.

Per-neighbor **contact ratio** is tracked continuously: fraction of recent
hours the neighbor's beacon was heard (EWMA per hour-bucket). Input to
custodian scoring (§6).

## 5. Node roles

Roles are emergent from the condition byte — no manual configuration:

- **Leaf** (default battery phone, and all scan-only devices): hears gossip,
  originates/receives, dials GATT outbound. Doesn't relay broadcast, minimal
  beacon (presence only when battery-constrained).
- **Relay:** advertising-capable node with headroom; exports DV digest, accepts
  custody transfers.
- **Base station:** powered + stationary + long uptime + storage headroom. The
  street's natural mailboxes (a plugged-in shop tablet, not a passing
  pedestrian). Scan continuously, accept more concurrent GATT sessions, act as
  preferred custodians. Score is computed by *others* from the beaconed
  condition byte — self-claims only raise how often you're *chosen*, not what
  you can see (limits abuse until beacons are signed, §9).

## 6. Store-and-forward (SCF)

Every custody node archives what it carries. Persistent sqlite store (must
survive restarts — 7-day retention outlives any process):

```
mesh_store(am TEXT PK, target TEXT, sender TEXT, wire BLOB, ts INT,
           size INT, prio INT, state INT)   -- state: in-transit | archive
```

- **Quota: 7 days OR 100 MB, whichever first.** TTL sweep drops >7-day rows;
  above 100 MB evict oldest-first (then lowest-prio). At ~200 B/message the
  quota holds ~500 k messages — for text it is effectively TTL-bound. SCF
  carries messages and small bursts only; large media stays sender-side or
  goes via the internet edge-bridge.
- **Custodian selection** when the target is currently unreachable: hand the
  message via GATT to the reachable node with the best
  `contactRatio(target) × stability(powered, uptime, stationary)` — the node
  that most often sees the target, weighted by how likely it is to still be
  there. Replicate to the top 1–2 custodians, bounded by their advertised
  storage headroom.
- **Delivery on return:** custodians watch beacons; when the target (or a
  route to it) reappears, deliver via GATT. Only the best-scored/cost-1
  custodians initiate (hash-staggered) — everyone else waits for the purge
  signals.
- **Purge — never resend what was already received** (three layers):
  1. **In-session GATT ack** — custody transfer is confirmed inside the
     session; sender's copy demotes to archive immediately.
  2. **Live `?ACK <am> d`** end-to-end receipt (already built and validated on
     hardware) rides the gossip plane — every archiver in earshot purges that
     `am` at once.
  3. **Have-digest** in the target's beacon — any custodian that missed the
     ack (was away, archived off-path) purges matches and *skips sending*
     anything already in the target's have-set. Bloom false positives only
     suppress an occasional resend, which end-to-end retransmit covers.
- **End-to-end reliability:** unchanged receipts semantics (`am:` correlation
  id, ✓ sent / ✓✓ delivered / ✓✓ read). No delivered-ack within timeout →
  retransmit along the current route or re-park with a custodian.

## 7. Politeness — don't jam the street

Load-adaptive backoff, same shape as the RNS transport's proven auto-passive:

- Each node counts distinct adverts/s heard in a sliding window.
- **Quiet:** beacon every ~30 s (topology changing) stretching to 2–5 min
  (stable/idle).
- **Busy:** stretch beacon interval further, defer forwards with
  load-proportional stagger (generalize the existing `1+(h%3)` s digipeat
  stagger).
- **Saturated:** presence-only minimal beacon; hold everything else. Powered
  base stations back off *last* (they're the useful chatter); battery phones
  go quiet *first*.
- Battery scan policy: charging/screen-on → continuous scan; on battery in
  background → balanced/opportunistic scan (bigger miss window — SCF absorbs
  it). Reuse the existing foreground-service hold.

**Each node measures this privately, and [XPRS.md](XPRS.md) section 10.6 lets it
say so.** `busy:` is the proportion of the last hour a named bearer was occupied by
anybody and `txtime:` the proportion this node was transmitting on it, both on an
ordinary `t:observation` carrying `link:ble` for this plane -- the bearer is
required precisely because a node here is not one radio on one channel. The quiet/busy/saturated tiers above are exactly that
measurement, computed from one vantage point and shared with nobody — so every
node has to rediscover the congestion for itself, and a node in a quiet pocket
next to a saturated one never learns it is about to make things worse.

Publishing the number does not replace local backoff and should not: a node acts
on what it hears, not on what it is told. What it adds is warning. And `txtime:`
is the row that makes the table above auditable — a node claiming to back off
last while contributing most of the traffic is visible for what it is.

## 8. Privacy

Custody nodes hold messages for up to 7 days, so carried content must not be
readable by carriers:

- Encrypted 1:1 (ENC1, already built) — carriers hold ciphertext. Fine.
- **Key-unknown 1:1: encrypt-or-don't-carry.** Do not park plaintext 1:1 on
  strangers' phones; hold at the sender until the target's key beacon arrives
  (key beacons already propagate), then encrypt and hand off.
- Public geochat/bulletins are public by definition — carried as-is.
- Gossip metadata (who hears whom) is inherently visible; equivalent to what
  any passive scanner already learns today.

## 9. Trust (staged)

- M1–M3: unsigned beacons. A malicious node can advertise false routes/
  conditions and black-hole traffic. Accepted for rollout; mesh is cooperative.
- M4: **Ed25519-signed route beacons** (pubkey-beacon infrastructure already
  exists) — a node cannot forge routes or a base-station identity it doesn't
  own. Costs ~64 B + one verify per beacon.

## 10. What is reused (don't rebuild)

| Existing piece | Role in the mesh |
|---|---|
| `Ble5Bus` shared advert set + subtype demux | gossip plane carrier |
| Auto-pair GATT (size-router >450 B path) | data plane carrier |
| Legacy connectable discovery beacon | GATT reachability (extended set stays non-connectable) |
| `?HELLO` + `g_sdev` seen-device registry | seed for neighbor table + contact ratios |
| `am:` + `?ACK d/r` receipts (validated) | end-to-end acks + SCF purge |
| `mailbox_add` / `?MAIL` | conceptual ancestor of SCF (replaced by sqlite store) |
| Dedup rings (`fseen`/`rpt`) | fallback broadcast path loop control |
| RNS auto-passive pattern | politeness backoff shape |
| Reticulum internet edge-bridge | off-street reach (unchanged; the on-street mesh replaces RNS *BLE* transport plans) |
| GPS HAL / position | mobility classification |

## 11. What changes where

**Host (aurora):**
- `lib/connections/bluetooth/`: MESH subtype on the bus; mesh GATT service
  (custody transfer + peering exchange protocol); beacon assembly/parse.
- New `lib/services/mesh/`: DV table, contact-ratio tracker, custodian scorer,
  politeness governor, sqlite SCF store (quota sweep), have-digest bloom.
- HAL: expose mesh send/receive + route/neighbor queries to wapps (keep host
  generic — mesh is a transport service, chat semantics stay in the wapp).

**Chat wapp (`wapps/chat`):**
- Replace the blind BLE digipeater for 1:1 with mesh routing (send → host mesh
  service). Keep the broadcast path for geochat bulletins + as gradient
  fallback.
- TTL byte in the compact wire format (foundational even for the fallback).
- Read receipts / `?ACK` unchanged.

**Bluetooth wapp (`wapps/bluetooth`, new):** devices/mesh/settings UI (§12);
owns the mesh preferences (quota, retention, roles, battery, politeness).

**ESP32 (later):** dongles can join as fixed base stations (always powered,
stationary by definition) — out of scope for M1–M3.

## 12. Bluetooth wapp

A new **Bluetooth** wapp (`wapps/bluetooth`), the mesh's face — same pattern as
the Reticulum wapp (observed-only registry surfaced by the host, native
rendering, no webview, layout off the UI thread):

**Devices view** — everything within reach, live from the gossip plane:
- Per device: callsign, **device-type icon** (phone / tablet / computer /
  router / ESP32 / base station / other, from the beacon class byte),
  condition chips (⚡ powered, uptime, 📍 stationary/moving, storage headroom),
  hop count/cost, last-heard recency, contact ratio, link quality (RSSI,
  bidirectional-confirmed or one-way), and current role (leaf / relay / base
  station).
- Tap a device → detail panel: its advertised DV digest (who *it* reaches),
  neighbors in common, SCF state (messages we hold for it / it holds for us).
- **Actions**: send message (opens the existing 1:1 chat for that callsign),
  ping/reach-test, "prefer as custodian", forget.

**Mesh view** — street-level picture: neighbor graph (nodes = devices with
type icons, edges = confirmed links weighted by contact ratio), channel-load
meter (adverts/s heard → the politeness governor's input, §7), and counters:
routes known, messages in transit / archived, store usage vs quota.

**Settings** — the mesh's preferences live HERE (host mesh service reads them;
single source of truth):
- SCF retention: max age (default **7 days**) and store quota (default
  **100 MB**), current usage + a purge-now action.
- Device class override (auto-detected from platform, user-correctable — e.g.
  a plugged-in tablet on a wall declares itself a base station).
- Role cap: allow/deny base-station promotion; relay on/off (leaf-only mode).
- Battery policy: scan aggressiveness on battery (balanced / opportunistic),
  beacon interval bounds.
- Politeness thresholds (advanced): busy / saturated adverts-per-second cutoffs.
- Privacy: encrypt-or-don't-carry toggle (default on, §8).

Host stays generic (mesh service exposes registry/stats/prefs via HAL; all
Bluetooth-specific presentation lives in the wapp) — same split as the
Reticulum wapp.

## 13. Milestones

- **M1 — see the street.** Condition/class-byte + DV beacon, neighbor table,
  bidirectional check, contact tracking, and the **Bluetooth wapp devices
  view** (it doubles as M1's verification instrument). 3 phones: each shows
  correct 2-hop routes, conditions, device types. No data plane yet.
- **M2 — move a message. [BUILT + phone-validated 2026-07-03]** The Mesh
  Session Protocol (MSP v1, `4D 01` magic on FFE0/FFF1/FFF2, mirrored in
  Dart `mesh_session.dart` and C `blemesh_session.c` with shared fixtures)
  carries message custody (MSG/ACK = handover), gossip and a BULK FILE
  lane (FILE_OFFER/ACCEPT with offset resume, CHUNK windows, sha-verified
  FILE_OK custody). sqlite SCF + have-digest bloom + `[pending]` beacon
  trailer shipped. Validated: 5 MB image phone→phone through two floors at
  27 kB/s, sha-verified into the receiver's media archive; custody park +
  overheard-`?ACK` purge; ESP32 dongle as MSP GATT server with SD spool
  (RAM-first index) + console `sendfile`. Hard lessons now encoded:
  controller dup-scan filters must be OFF, session slots must reap on
  timer-closes, notify bursts need a TX ring, and every gate needs a
  visible decision (scheduler logs + failsafe).
  **Re-validated 2026-08-26 carrying a 56 MB app update** (see section 14):
  throughput is 7-19 kB/s, not the 27 kB/s above; resume is solid across
  five sessions; two protocol bugs found and fixed.
- **M3 — behave in a crowd. [IN PROGRESS]** Done: load-adaptive beacon
  (30 s quiet → 90 s busy → 5 min presence-only saturated; powered nodes
  back off last), battery dial policy (low+discharging = no pulling for
  others), custodian scoring (contact × stability, path-claim dominates)
  with mule handoff of own unreachable mail, foreign-central defense (a
  silent GATT central is dropped after 10 s and ignored 10 min), Bluetooth
  wapp Node/Transfers sections + `hal_mesh_scf_status`/`hal_mesh_transfers`
  /`hal_mesh_set_pref`. Remaining: settings UI, mesh view w/ channel-load
  meter, broadcast fallback, soak test.
- **M4 — harden.** Signed beacons, encrypt-or-don't-carry for key-unknown 1:1,
  quota tuning, village-scale field test.

Validation rules that apply throughout: device tests on different networks
where reachability claims are made; never trust a single scan burst; measure
airtime (adverts/s heard) before/after — the whole point is that the number
stays flat as N grows.

---

## 14. The bulk lane carrying a large file (2026-08-26)

M2 was validated on a 5 MB image. Carrying a **56,830,760-byte app update**
between two phones, one of them with no internet at all, found things a 5 MB
image never could. The transfer completed and verified; what follows is what it
cost and what had to be fixed.

### 14.1 A complete `.part` could never finish

The worst of the two, because it looked like success on the sending side.

`MeshBulkSpool.offered` answered `accept(have)` where `have` is the length of
the partial on disk. When a previous session had already delivered every byte,
that is `accept(size)` — and the sender reads `offset >= size` as *"peer already
has it"* and declares custody handed over without a byte moving or a hash being
checked (`mesh_session.dart` `_onAccept`).

So a transfer interrupted at the very end left the receiver holding the whole
file in state `rx` **forever**, while the sender recorded `done` and a handover.
Every retry re-confirmed the lie in milliseconds. Observed across three attempts
before the cause was found.

**A receiver that already holds every byte must FINISH the transfer — verify,
complete, land the file — and only then say it has it.** "I already have it" is
a statement about a verified file, not about a byte count.

### 14.2 A peer that asks again does not have it

A `done` spool entry plus a `MeshStore` handover record together meant a repeat
request was accepted and then never offered: the scheduler skips `done` entries
and `nextFor` skips anything already handed over.

Both are now cleared when the peer asks again. **An ask outranks our record of
having sent it** — the peer is the authority on what the peer has.

### 14.3 Serving a file that is not in the archive

The spool knew two kinds of entry: an archive blob and a `.part` it was
relaying. An artifact that simply lives on disk — the update mirror's channel
directory — fitted neither, and the archive path caches the whole file to serve
one window.

A third kind (`src: 'file'`, an absolute path) serves with the same seek+read
the `.part` branch already used. The file stays where its owner put it and is
never copied. Symmetrically, `inboundClaim` lets a caller take the finished
`.part` by rename instead of having it read into memory and stored as a sqlite
BLOB. See `docs/performance.md` §8.9 — four places read a whole file, and all
four were correct for a photo.

### 14.4 Numbers, honestly

| | |
|---|---|
| file | 56,830,760 B, sha-verified on arrival |
| sessions | 5, resuming to the byte every time; nothing re-sent |
| sustained rate | **7-19 kB/s** (not 27) |
| wall clock | ~3 h, of which ~40 min was a dead stall (14.5) |
| plan for | ~10 kB/s, ~1.5 h for a per-ABI APK |

`MSP_SESSION_CAP` (300 s) ends a session politely and the receiver's `.part`
length **is** the resume offset. That part of the design is sound and needed no
change.

### 14.5 Two phones can lose sight of each other for a long time

Mid-transfer both phones reported `neighbors: 0` for nearly forty minutes and
heard only the ESP32, while both scanned healthily and the sender dialled every
tick into silence. The transfer did not advance one byte.

The ESP32 **advertises continuously** (160 ms, no duty cycle); a phone transmits
**five seconds a minute** and shares even that between frames. So a phone is
reliably *heard*, and two phones must catch each other inside a window neither
controls. Restarting both apps restored contact at once.

That is a workaround. Two things it argues for, both open:

- a pending bulk transfer is a reason to widen the transmit window, and nothing
  currently does that;
- dialling a peer we cannot currently hear should be *said*, not repeated
  silently — `neighbors: 0` while dialling every tick is a diagnosable state.

### 14.6 Other XPRS traffic keeps flowing — on phones

A phone in a bulk session **does not go deaf**. The extended scan is never
suspended (`docs/ble5.md` §4: pausing it was measured as 10-of-10 versus
0-of-10 messages delivered), and during this transfer the receiver logged 199
beacons from a third XPRS node and reached `2 of 2 peers`.

The **ESP32 is different and does go deaf**: frames aired at a dongle during an
MSP session are not received (`ble5.md` §5). Anything that must reach one has to
be re-aired afterwards. GATT-based file transfer on the ESP32 is deliberately
out of scope for now, so this matters only for a dongle acting as a server.

## 15. A 1:1 to a peer in the room (2026-08-27)

§3 describes two planes: gossip beacons for control, GATT/MSP unicast for data.
This is what happened when a *message* was routed onto the second one.

**Plane 1 is not what the code thinks it is.** §3 specifies the 0x4D route
beacon with a class byte and a DV digest. `MeshService._sendBeacon` airs only
the XPRS beacon, on purpose: the advert window is five seconds a minute and two
beacons halve the chance either is heard, while the DV digest and the have-bloom
are exchanged *in full* over MSP whenever two stations connect anyway — which
§3 already anticipated as "two-tier gossip". The consequence is easy to miss and
expensive: **`MeshTable.neighbors` is empty between two phones**, `bidirectional`
is never set, `deviceClass` is never learned, and `gossipReceived` cannot seed
the table because it only updates a neighbour that already exists.

Anything that needs "is this peer an Android in range, both ways?" must
therefore ask elsewhere. It asks the transport:

- **Can we reach it?** `BleService._meshPeers` — callsign → BLE address, fresh
  within 150 s. Only the legacy connectable presence advert and a live link file
  a *dialable* address there; a beacon sighting files the extended-advert MAC,
  which is deliberately not connectable.
- **Will it take the message?** `MspCaps.msgCustody` from the peer's own MSP
  HELLO, kept past the end of the session. A dongle goes deaf during a session
  (`ble5.md` §5) and never offers it, so it keeps overhearing broadcasts, which
  is what a relay is for.

Both live in `MeshCustodyDelegate.pointToPointOk`, reported at `/api/status`
`mesh.custody`, and the full account with bench numbers is `ble5.md` §9.8.

**Custody to the target is delivery, and the other lane must be told.** When
`custodyTransferred` hands a message to the callsign it was addressed to — not
to a carrier — `RnsService.retireLxmfRetriesFor` cancels the pending internet
retries. Without it the sender kept pushing a delivered message into hubs for
half an hour and showed it as unsent.
