# Store-and-forward

**Drawn:** [diagrams/relay-gateway-flow.md](diagrams/relay-gateway-flow.md)
figures 4 and 5 — the carrier lifecycle, and choosing where to hand mail next.

A message to a station that no path reaches is handed to a nearby device, which
carries it and delivers it on meeting the recipient. Any capable device can act
as a carrier: a phone, a tablet, or an ESP32 dongle.

This is a core service. No wapp participates: a wapp sends a message and is
called back when one arrives ([architecture.md](architecture.md)).

Implementation: `lib/services/mesh/mesh_courier.dart` (decision, transmission,
ingest), `mesh_custody.dart` (taps), `mesh_store.dart` (parked mail database),
`common/xprs_blemesh/blemesh_scf.c` in xprs-firmware (firmware side).

---

## 1. Determining that no path exists

Every reachability test available before transmission returns an incorrect
answer. Both were measured against a device with both radios switched off:

| Test | Result returned | Cause |
|---|---|---|
| `hal_rns_nodes`, observed-node list | recently seen | a hub replays its entire announce cache on link-up, timestamping every node it has ever heard |
| transport `hasPath(dest)` | path present | a learned Reticulum path outlives the station that taught it by hours |

Delivery is the reliable signal. A station on the LAN, or reachable through a
hub, acknowledges in well under one second.

[XPRS.md](XPRS.md) section 10.6.3 adds the reading this table is missing.
`hears:` is a station's list of the callsigns it hears **directly** -- not
through a relay, not from a replayed announce cache -- which is the honest
version of what `hal_rns_nodes` claims to be.

It answers a different question from the one above, and the difference matters.
Nothing a stranger publishes tells us whether *we* can reach a station, so
delivery stays the only reliable test of our own path. What `hears:` tells us is
**who else is one hop from the recipient**, which is the question this document
actually has to answer when it picks a carrier -- and the one the two tests above
were being misused to answer. It is a claim rather than a measurement, so it
informs the choice of carrier and never settles it.

```
sendLxmf(dest, text)
  MeshCourier.armLxmf(dest, text)      unconditional
  after 20 s:
    lxmfPendingFor(dest) == 0   delivered, discard
    lxmfPendingFor(dest)  > 0   no path, transmit a carried copy
```

The interval is 20 seconds because `sendLxmf` abandons a direct link at 10
seconds, so the send has definitively failed rather than merely not yet
succeeded. After 15 minutes the courier releases the message to the ordinary
retry ladder.

**The first minute on BLE** is before any of that. A `t:message` -- a 1:1 or a
Local post -- is handed to the BLE5 bearer at 0, +20 s and +40 s
(`XprsSend.repeatAfter`): the identical wire in the same advert slot, so the
rotation entry is refreshed rather than duplicated and the bearer's
register-time airing fires again. [ble5.md](ble5.md) section 1 is why: a frame
transmitted once may not be observed at all, and before this the next thing
that re-aired a 1:1 was the custody ladder, minutes later -- and nothing
re-aired a Local post. A 1:1 stops at its receipt (XPRS.md section 13.7); each
airing is spent on the packet's single retry-ledger entry (section 31.1), so
the ladder that follows counts them. A wire the session lane took is not
repeated: it went over a link.

## 2. Wire format

```
t:message f:FROM d:TO ts:2026-08-08_14:26:40 sig:<60> m:body
t:message f:FROM d:TO ts:2026-08-08_14:26:40 x:<sealed> sig:<60>
```

**XPRS emits XPRS** ([XPRS.md](XPRS.md)). It still *reads* the compact frame
below, because the chat wapp and the ESP32 dongle both still emit one and
custody sees every advert on the air:

```
FROM 0x1F TO 0x1F am:<6hex> [sd:<32hex>] <body> [~<sig>]
```

`lib/services/mesh/mesh_frame.dart` is the seam. Everything above it asks for
from/to/id/body and never learns which format arrived, so the legacy half can be
deleted without touching custody, the store or the courier. The test is
unambiguous and needs no version marker: a compact frame always holds two `0x1F`
bytes, an XPRS packet holds none and starts with `t:`.

Three fields did not survive the change, and none is missed. `am:` because the
identifier is derived from the packet (XPRS section 5), so nothing announces its
own id and a carried copy keeps the one it was born with -- the store column that
held `am` now holds that identifier, unchanged, because both are six hex. `sd:`
because the sender's LXMF address is a pure function of their public key, and
deriving it is safer than trusting an address the sender wrote. `np:` because a
sealed body already proves who the copy is for.

**The stations carry mail too, and differently.** An ESP32 keeps no separate
custody queue: a record with `d:` is flagged mail in the ordinary archive
(`common/xprs_index`), and delivery is triggered by hearing the recipient
directly — §36.8.1, not a poll. It then airs that callsign's newest messages
with itself appended to `via:`, paced, and stops re-airing an id once it has
verified a `t:receipt s:ack` for it. What is held is announced two ways: as
`mail:<n>` on the ten-minute `t:service` beacon (§10.6.5), and as a one-packet
answer to `q:mail only:<call>` (§13.12.3).

Retention when the store fills is XPRS.md §36.11: declared mail last, other
people's mail before it, the spool first. A station signs what it originates,
and dates packets `epoch:<boots>.<uptime>` (§10.7) until it has a clock — a
receiver that has one anchors that epoch and dates the packets from it, so a
clockless station is still reachable by a `since:` window.

The older firmware described here — a store-carry-forward in
`common/xprs_blemesh` and a C mirror at `common/xprs_xprs` — is not what runs:
`xprs_blemesh` is built by no board under `models/`, and `xprs_xprs` no longer
exists.

`FROM` and `TO` are always public. A carrier that cannot read the recipient
cannot determine where to relay the frame, which is what allows custody to
operate between stations that do not trust each other.

`am:` is the receipt identifier and is always first. Both custody layers, the
phone's `MeshCustodyDelegate.onAirFrame` and the ESP32's `blemesh_scf_offer`,
read it at a fixed offset. A frame without one is carried but cannot be handed
over within a session.

`sd:` is the sender's LXMF delivery address, allowing the receiver to key the
conversation by identity. Without it a carried message can only be keyed by
callsign, and a callsign-keyed conversation is not renderable.

The body is `ENC1:<base64url>` sealed to the recipient's key when one is known,
and plaintext otherwise. Refusing to transmit without a key would leave the
message undeliverable, and the envelope is public in both cases.

`~<sig>` is a short-Schnorr signature over `sha256("<FROM>|<text preceding the
signature>")`, base85 encoded. It is verified on arrival when the sender's key
is known, since a carried message has passed through stations outside the
sender's control. Unsigned mail and mail from unknown keys are still delivered,
as most stations have not published a key.

There is no `np:` recipient token. It consumes 66 of the 240 available bytes and
establishes nothing that a sealed body does not, since only the holder of that
key can open the body.

The limit is 240 bytes. Larger frames are refused with a logged reason. See the
budget table in [ble5.md](ble5.md).

## 3. Transmission

Carried copies are transmitted through `BleService.enqueueAdvert`, the same path
used by a wapp broadcast, so the custody tap parks the local copy exactly as it
parks a frame from another station.

Each copy is transmitted three times: at 0, +90 s and +180 s, with a 300 s TTL.
A receiver scans in bursts, so a single advertisement window is unreliable: in
one measurement an ESP32 two metres away parked six frames from one run and none
from the next.

## 4. Carrying

Any device that receives a direct frame addressed to another station parks it.

Mail is stored for any recipient. A carrier that holds mail only for stations it
already knows is of no use to a station that is out of range of everyone.
Prioritisation occurs under storage pressure rather than at admission. Each
parked frame carries an urgency, and the quota sweep evicts in
`ORDER BY urg, ts`:

| `urg` | Given to |
|---|---|
| `low` | a stranger's mail, when the frame states nothing |
| `normal` | mail we originated, or whose target is inside the mesh horizon |
| `high` | the most a stranger's frame may claim |
| `urgent` | ours only |

The four levels are XPRS `urg:` ([XPRS.md](XPRS.md) section 13.5), so a level
stated on the wire needs no translation. **A sender states what it wants and the
carrier decides what it may have**: a stranger's frame is capped below `urgent`,
because stations will mark everything urgent and no device should be able to
push its host's own traffic out of its host's own store.

Storage is bounded at 100 MB or 7 days, whichever is reached first, with
`maxWire` of 480 bytes per frame and `inTransitMax` of 4000 in-transit rows, so
that a busy location cannot fill the disk with mail the device may never
deliver. Local mail is never refused.

[XPRS.md](XPRS.md) section 31.3 cites this policy as the model of a decision the
format deliberately leaves alone: it states no retention period, no minimum and
no eviction order, because a dongle with a microSD card and a home server with a
spare terabyte cannot share one number. The 100 MB, the 7 days and the
`ORDER BY urg, ts` above are this implementation's answer and nobody else's, and
changing them breaks no specification.

Groups, observations, `?` control frames and receipts are never carried.

That covers the closed groups of [XPRS.md](XPRS.md) section 26 as well. An `X5`
group callsign is addressed like a station but is group traffic, and custody is
not how a roster travels: section 26.8 propagates membership by members
rebroadcasting the signed grants they already hold, which needs no carrier
because every grant verifies against the group's key on its own.

The ESP32 implements the same behaviour in 24 slots (`BLEMESH_SCF_MAX`) at 252
bytes per frame, persisted to `/sdcard/mesh/pending.bin` so that a power cycle
does not discard parked mail.

### 4.1 Carrying toward a place, which is not implemented

Everything above carries mail to a **callsign**: a carrier holds a frame until it
meets the station it is addressed to. That works when the two are in the same
region and never completes when they are not, because nothing tells a carrier
which direction helps.

[XPRS.md](XPRS.md) sections 13.4 to 13.10 specify the missing half. A packet
carries `dest:` (where it is bound) and `near:` (how close counts as arrived),
and a carrier accepts a copy **only if it expects to reduce the distance to
`dest:`**. That single rule turns custody from "wait until I happen to meet you"
into a route across a continent, moved by people going that way anyway.

The parts of it this document already provides, and which do not change:

- the quota and eviction policy above, which is why XPRS specifies no copy limit
- `via:`, which prevents a carrier taking the same packet twice
- release on receipt, section 6

The parts that are specified and not built:

| Element | Status |
|---|---|
| `dest:` and `near:` on a carried packet | not implemented; custody is keyed on callsign only |
| the closer-to-destination admission rule | not implemented; admission is currently "park anything for anyone" |
| `urg:` as the eviction key | **implemented**; four levels, capped per source, `ORDER BY urg, ts` |
| `until:` as a carry deadline, capped at a year | not implemented; the 7-day quota is the only bound |
| regional delivery, `dest:` with no recipient | not implemented |
| `route:` copied into a signed receipt | not implemented |
| `t:mailbox`, a recipient's preferred carriers | not implemented; nothing records who tends to see a given station |
| several mailbox declarations, selected by `since:` and `until:` | not implemented; there is no store to select from |
| `scope:local`, which must never be carried | **implemented**; refused at admission in `MeshCustodyDelegate._mayCarry`, which is the right place -- a copy parked now and aired later leaks either way |

Two of those rows change what this document says about admission, so they are
worth naming rather than leaving in a table.

**`t:mailbox` is the half of routing this document does not have.** Section 4
carries mail for anyone, which is right, and then has nothing to say about
*which* carrier is likely to succeed. A mailbox declaration is the recipient
saying so themselves: these stations tend to see me, try them first. It is
signed, and a carrier that cannot verify one must ignore it, because a forged
mailbox declaration collects somebody else's mail from every polite sender.

A station may have several in force at once, so this is a query against time
rather than a single stored value ([XPRS.md](XPRS.md) section 13.12.1). Each
declaration may carry `since:` and `until:`; one without them is open-ended.
Delivering to a recipient means picking the declaration whose window contains
the moment, narrowest first, and falling back to the open-ended one. An
implementation that keeps only the newest declaration per callsign gets this
wrong the moment somebody announces a month away from home in advance, which is
the case the field exists for.

A declaration is withdrawn by a signed `remove:mailbox` naming it, not by being
superseded, so a carrier holds them as a set and deletes by identifier.

**`scope:local` must be refused at admission, not at transmission.** A packet
marked local is for the bearers in range now -- Bluetooth, WiFi Direct, a LAN --
and carrying it to another town is precisely what it excludes. Parking one and
airing it later would be a leak wearing the shape of a feature, and it is the
one case where the "park anything for anyone" rule in section 4 must not
apply.

The carrier already reads `urg:` from a frame that carries one
(`MeshCustodyDelegate._urgOf`). No frame does yet, so the default holds and the
behaviour is identical to the two-level scheme it replaced: ours `normal`, a
stranger's `low`. The moment senders start writing `urg:`, carriers honour it.

## 5. Delivery

Two independent paths complete delivery.

**Re-transmission on sighting.** The carrier receives the target's beacon and
re-transmits the parked frames. The ESP32 sends at most 4 per sighting, with one
re-transmission per frame per 60 seconds.

```
SCF: X1RD89 back in range -> re-airing 4 parked frame(s)
```

**MSP custody handover.** The target opens a GATT and MSP session, the carrier
transfers every frame addressed to it, and then archives its copy.

```
custody of 7b0d6e -> X1RD89 (purged)
```

On the receiving device both paths reach `MeshCourier.ingest`, which verifies
the signature, decrypts, deduplicates by `am` or by content, and injects the
message into the LXMF inbox through `RnsService.injectLxmf`. This is the same
inbox used by directly delivered messages, so the receiving wapp renders the
existing conversation without distinguishing the delivery path.

## 5.1 The always-on archiver in the middle (2026-09-08)

Everything above carries mail between stations that eventually meet. The case
it does not cover is the one people actually hit: **two telephones that are
never awake at the same moment.** A writes, B is asleep, A's screen locks. The
only copy was on A, and A is the station that left.

Reported from the field, and the cause was three missing joins rather than a
broken part. XPRS.md 12.8.3 is the whole loop; here is where each join lives:

| Join | Where |
|---|---|
| adopt an archiver when the operator named none | `XprsArchiverChoice`, applied each minute from the station table |
| leave a copy with it when nothing acknowledges | `XprsMailbox.armDeposit`, armed for every directed packet at `XprsPublisher.publishWire` |
| say where your mailbox is (`t:mailbox hold:`) | `XprsMailbox.declare`, aired when the archiver list changes |
| hold anything that is mail, not only chat | `xprsIsMail` at the carry gate (`XprsIngest.reticulum`) |
| deliver when the recipient becomes REACHABLE | `XprsMailbox.sweepHeld`, once a minute |
| tell the holders they can stop | `XprsMailbox.receiptFanout`, from `MeshCourier._acknowledge` |
| carry the receipt to the sender who is still away | the receipt is mail like anything else |

Four things this got wrong on the way, each of which looked like it worked:

- **Reachable must mean THIS station.** The first version read "a Reticulum
  path, or any LAN peer at all", which makes every callsign on earth reachable
  the moment one neighbour is on the wire. The bench duly re-aired mail to a
  callsign that has never existed, once a minute. `XprsMonitor.heardDirectly`
  is the honest test.
- **Never sweep mail addressed to yourself.** Our own outbound copy sits in the
  same store as the carried ones, so an unguarded sweep puts a packet on the
  air addressed to this station and every neighbour hears us relay to nobody.
- **A receipt is never re-addressed.** `d:` is inside what the signature
  covers, so a receipt readdressed to the holder arrives unverifiable — and
  9.7.1 wants that signature precisely so a stranger cannot delete other
  people's mail. The holder gets the identical wire and releases on
  overhearing it (13.3).
- **One copy per message, however often it is re-aired.** The retry ladder
  re-airs an unacknowledged 1:1 every few seconds, and each re-airing armed a
  fresh deposit: ten copies of one message inside ten seconds on the bench, and
  two archivers handing the same mail back and forth because each re-air
  re-armed the other. `XprsMailbox` remembers the identifiers it has deposited.
- **A failed deposit must be a counter.** The directed lane failing is
  ordinary; without `mailbox.depositFailed` it is indistinguishable from
  "there was nobody to deposit with", which is a different fault with a
  different fix. The deposit now falls through to the ordinary fan-out.

Observables, all in `/api/status` under `mesh`:

```sh
curl -s localhost:3456/api/status | jq '.mesh | {archiver, archiverAdopted, archiverOffers, heldFor, mailbox}'
```

`archiverOffers` empty while a volunteer is on the air means the claim never
reached the station table — a different fault from "nobody offered". That was
real: `serve:` was recorded only at the radio door, so an archiver heard over
Reticulum (which is every always-on archiver) offered nothing as far as any
station could tell.

**Validated on three stations (2026-09-09).** Desktop X16JK8 wrote to the
hotwav X1WATT while it was force-stopped with its radios off; the C61 X1ARKL
held the copy (`/api/xprs/held` showed `am 4bd6b9` for target X1WATT); the
desktop was then killed, so neither party existed. The hotwav woke, and within
twenty seconds it held the message with a verified signature, the archiver's
copy was released, and the hotwav's `receiptsToHolders` recorded that the
holder had been told as well as the sender. The desktop returned and learned
`4bd6b9 is delivered (X1WATT)`. The hotwav had also adopted X1ARKL as its
archiver on first boot and declared it, with nothing configured.

That run exposed one more gap, since closed: the outbox was in memory, so a
sender that RESTARTED had no row for the receipt to advance — `status only, no
outbox row`. The tick was the smaller cost. `stateOf` answering null for a
message that IS delivered makes the mailbox leave ANOTHER copy with an
archiver and leaves the retry ladder with nothing to stop it, which is airtime
rather than a nicety. `XprsOutbox` now keeps its rows in the profile database
(`xprs_outbox.sqlite3`): the pocket holds the hot 500, the file holds 4000, and
a receipt for something older loads its row rather than reporting a status with
nothing behind it. Re-run on the same three stations: `outbox restored 28 sent
message(s)`, then `receipt from X1WATT released 1 held copy of 621c47` and
`621c47 is delivered (X1WATT)` — no status-only line.

The three-station dance is simulated on this machine before it goes near a
radio: `test/xprs_mail_relay_sim_test.dart` on `test/support/mail_relay_sim.dart`
runs the real funnel, store, receipts and mailbox for each station in turn over
an air that drops what is addressed to somebody offline.

## 5.2 A carrier carries mail, not answers (2026-09-15)

X1UDP4 replied to X1WATT while the phone was away. The reply reached X1WATT's
archiver, the C61, and stayed there: the phone polled the C61 every 25 s over
the LAN for an evening and never saw it. Four defects, each invisible alone:

- **The courier minted messages.** `sendLxmf` arms the courier for every
  directed XPRS wire, and with no Reticulum path `_air` sealed whatever it held
  as the text of a new `t:message f:<us> d:<them> ts:now`. Every `t:result` the
  C61 gave the polling phone became a three-part message to it: 474 in fifty
  minutes, which buried the real reply, were replayed on the next poll and
  re-armed the courier. Now an XPRS wire is carried as it is when it is a
  person's mail, and otherwise not at all (`MeshCourier.notMail`, counted as
  `courier.notMail`). A command is dropped by a carrier, never parked (XPRS.md
  11.7); a result or a receipt is nobody's correspondence.
- **The archiver offered other people's mail.** A public archiver's page was
  the twelve newest messages of anybody to anybody. XPRS.md 12.1: mail is held
  for its addressee and never offered to a third party. `XprsArchive.query`
  takes `mailFor`, and the history server always passes the asker:
  publications, the asker's mail both ways, and group traffic.
- **The continuation cursor skipped the reply.** `until:` came from rows the
  archiver itself had written, and an old one of those heard mid-ask moved it
  hours back, over the gap that held the reply. XPRS.md 11.2.1: the requester
  "moves `until:` to the `ts:` of the oldest packet it received". The page is
  now counted at the receive door (`XprsIngest.onHeardAny`): a via-less
  `t:message` older than a minute inside the ask's window, whoever wrote it,
  with one ask out per device at a time so every such packet belongs to it.
  The next `until:` repeats the boundary second, because the parts of one
  message share a `ts:`. Unanswered history is kept as windows, newest first:
  a new window opens ahead of an unfinished backfill, so fresh mail is not
  queued behind a week of somebody's broadcasts, and the mark moves to the
  start of the oldest window still open.
- **A refusal did not slow a continuation.** A `206` chain skipped the earned
  interval, so a `429` was followed by another ask 25 s later, for hours. A
  `429` now holds the archiver back for its interval, continuation or not
  (12.10.2).

A replay is aired and nothing else (2026-09-16): `verbatim` now reaches the
bearer, so a history page is neither handed to the courier nor deposited. An
archiver used to park, re-air and file as its own the correspondence it merely
replayed.

Readable without a debugger: `mesh.catchup.windows` (the cursor per archiver),
`mesh.catchup.marks`, `mesh.catchup.refusedForMs`, `mesh.history` (pages 200
and 206, misses, busy and budget refusals, the caller being served) and
`mesh.courier.notMail`.

(The sealed-set release this section left open is section 5.3's, below: the
set key and the per-part receipts.)

## 5.3 Delivery is not a send (2026-09-16)

The phone that never showed X1UDP4's reply held 234 of its rows in its own
spool, 72 of 87 part-sets complete and every one of them decryptable, with
`courier.ingested` at 0. Nothing was lost on the air. It was thrown away at the
door, and the door is the only chance there is:

**The plaintext of a sealed 1:1 is written nowhere.** The spool keeps the parts
as they were heard, sealed, and the joined packet is never admitted. So
`WappDelivery.deliverMessage` is the single, unrepeatable moment the words can
reach a person, and the courier used to discard its answer: it marked the
message delivered and acknowledged it to the sender whether or not any wapp was
subscribed. The `s:ack` then released every carrier's copy, so a message opened
while the chat engine was still loading was gone from the whole mesh, silently.

What ships:

- **A verdict.** `deliverMessage` returns `delivered`, `noSubscriber` or
  `refused`. Only `delivered` may mark and acknowledge. An undelivered message
  is left unmarked so the next copy, from any lane, delivers it, and is also
  held in memory (64 newest, never on disk: they are somebody's private words)
  and offered again the moment something subscribes to `xprs.message`
  (`WappEventBroker.onFirstSubscriber`). A refusal is not queued: an XPRS wire
  or a non-member's group post would be refused again.
- **Every part of a set is remembered**, not only the one that completed it.
  `XprsReassembled.partIds` carries them and the courier records all of them
  plus the reassembled id. Before this, a replayed set's completing part was
  correctly deduped while its siblings opened sets that could never close: 42
  incomplete sets on the bench phone, still climbing.
- **One key shape for "we have this one".** `received_ams` stores the bare
  identifier, which is what a parked row wears as `am`; the compact lane keeps
  its `am:`/`c:` names. The old `id:`-prefixed rows are rewritten on open. The
  have-bloom this station airs is therefore a true statement, and a custodian's
  `applyPeerBloom` finally drops what we hold instead of re-airing it for ever.
- **A split message is parked as a set.** `mesh_store.setk` is `(f, ts)`
  through `xprsSetKey`, the same derivation the reassembly table uses; both
  fields stay in clear on a sealed packet (12.7). `purgeAm` of any member
  releases the whole set, because a split message is delivered or it is not
  (7.6: a partial message is never displayed).
- **The recipient acknowledges the parts too.** A holder of sealed parts can
  never match the ordinary receipt: it names the reassembled message, whose
  identifier hashes plaintext the holder cannot read. So the recipient also
  composes one signed `t:receipt r:<part id> s:ack` per part and hands those to
  the holders alone (`XprsMailbox.receiptFanout`). The shared air still carries
  exactly one receipt for one message (9.7.2, 30.1).

Readable from outside: `mesh.courier.{undelivered, redelivered}` and
`mesh.delivery.{published, noSubscriber, refusedProtocol, refusedGroupAuthor,
partsHeld, partsJoined}`.

`deliverXprs` needs a live Reticulum stack, so the pieces are unit-tested
(the verdict, the part ids, the set release, the key shape, the part receipt)
and the whole is a bench check.

## 6. Releasing carried copies

The recipient's `?ACK <am>` purges carriers still holding a copy. The have-bloom
in each mesh beacon covers frames the receipt did not reach. A carrier that
completes a handover archives its copy rather than deleting it, so that a
subsequently rejected handover leaves the message owned by a station.

## 7. Instrumentation

```sh
curl -s localhost:3458/api/status | jq '.mesh.courier'
# {"armed":4,"aired":4,"refusedTooLong":0,"refusedNoIdentity":0,
#  "ingested":0,"ingestDropped":0}
```

| Counter | Meaning |
|---|---|
| `armed` | direct sends the courier is tracking |
| `aired` | copies transmitted for carriage, no path existed |
| `refusedNoIdentity` | no callsign available to address a carrier |
| `refusedTooLong` | over 240 bytes, nothing transmitted |
| `ingested` | carried messages unwrapped and delivered to a wapp |
| `ingestDropped` | invalid signature, undecryptable, or addressed elsewhere |

Relevant log lines: `Courier: no path to`, `Courier: delivered a carried
message`, `Mesh: parked ... for custody`, `LXMF: carried message`.

## 8. Validation procedure

A test in which the sender remains in range proves nothing, because a direct
link explains the delivery equally well.

The following procedure was run on 2026-08-06, tablet to T-Dongle to TANK2:

1. Recipient dark: `svc bluetooth disable`, WiFi off. ESP32 store cleared with
   `scfclear`.
2. Send. `courier.aired` increases and the ESP32 logs
   `SCF: parked 129B for X1RD89 (am=...)`. Confirm with the `scf` command rather
   than the `scf=` count in `status`, which is capacity-bound.
3. Switch the sender's Bluetooth off. Only the carrier can now deliver.
4. Enable the recipient's Bluetooth. Expect re-transmission or
   `custody of ... -> ... (purged)`, the ESP32 store returning to 0,
   `courier.ingested` increasing by the number sent, `ingestDropped` at 0, and
   the messages visible in the conversation on the recipient's screen.

Result: 4 transmitted, 4 parked, 4 handed over, `ingested: 4`,
`ingestDropped: 0`, all four rendered. See [validation.md](validation.md): a log
line is not a delivered message until it appears on screen.

## 9. Limits

- Carried payloads are limited to 240 bytes. Longer messages and attachments
  wait for a direct path; the bulk lane transfers the bytes separately once one
  exists.
- A station with no known callsign cannot be addressed on an envelope. The
  courier reports `refusedNoIdentity` rather than transmitting a frame no
  carrier can route. Callsign and LXMF-address pairs are persisted in
  `rns.lxmfDirectory`, because the station requiring a carrier is by definition
  the one that has stopped announcing.
- Custody operates per frame rather than per conversation. Ordering across
  carriers is not guaranteed, and a carried message may arrive after a message
  sent later over a direct path.
