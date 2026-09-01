# The communication coordinator

Which bearer carries a packet, what happens when one is taken away, and what the
receive funnel owes an arriving packet. `docs/XPRS.md` governs; this file says
what is built, how to drive it, and what it cost to learn.

**Drawn:** [diagrams/transports-flow.md](diagrams/transports-flow.md) — the same
flows as seven figures, if you want the shape before the prose.

`architecture.md` §4 says which **lane** carries what — BLE5 adverts carry XPRS
packets, GATT+MSP carries bytes, Reticulum is the internet path. That is a
design-time decision and this file does not touch it. What is decided at runtime
is the **bearer**: given a packet that is already an XPRS packet, which radios
does it go out on.

---

## 1. One fan-out

`XprsPublisher._fanOut` is the single place a wire meets a bearer. Every publish
goes through it — status, identity, mailbox declaration, and any caller-composed
wire.

There used to be four copies of that loop, one per public method, and they had
drifted: two applied the scope gate and two did not, only one supported `ttl`,
only one split into §6.6 parts, and they disagreed three ways about when to file
our own copy. Every cell that differed was a decision made once, in one method,
that the other three never learned. Two of those differences were live faults:

- `publishMailboxDecl` and `publishStatus` both fell through to the advert slot
  `status`. A slot is a rotation key on BLE5 — one frame per slot — so **a
  mailbox declaration evicted the discovery beacon from the air.**
- Scope gating existed in two of the four. Their packets happen to be global, so
  it was a no-op — but the next scoped packet type added would have leaked.

## 2. Three answers, not two

`XprsBearer.send` returns `sent`, `queued` or `refused`.

`queued` is the honest third answer: **handed to a lane that stores and forwards,
whose outcome is not known yet.** It exists because the report was caught lying.
Measured on the bench: a directed wire reported `reticulum: refused` and arrived
at the far station over Reticulum seconds later. That bearer hands the packet to
two lanes — an LXMF copy and a wapp datagram — and could only report one of them.
A report that says "refused" about a packet that arrived is worse than no report,
because the whole point of it is to answer *where did this actually go*.

`queued` names the lane for the archive, but it does **not** satisfy a path
preference: choosing one path is only worth doing if it worked.

## 3. Choosing one path — §36.0

> The one place a bearer legitimately decides anything is choosing among several
> paths to the **SAME station**… the path with the highest usable bandwidth among
> those it has **recent evidence are working**… **Reliability outranks raw
> speed.**

Ranked by bandwidth: **LAN > BLE5 > Reticulum**. A broadcast has no single
station to rank paths for, so it still fans out — that is §36.0's own fallback
for "cannot tell". If the chosen bearer does not carry it, every bearer is tried:
a preference that can become silence is not a preference.

What counts as evidence is in `private-messages.md` §6, and took two bench
failures to get right: **not** the bearer a packet arrived on (that describes the
relay), and stamped with the packet's own `ts:` rather than when it was heard.

## 4. The receive funnel, and the mail nobody was carrying

> This section ends where the funnel hands the packet on. The half after that
> — inbox, wapp, notification, bubble — is drawn in
> [diagrams/message-receive-flow.md](diagrams/message-receive-flow.md) and audited in
> [message-receive.md](message-receive.md), which reports that the Reticulum lane
> archives a 1:1 addressed to us and never delivers it.

`XprsIngest.heard` is the one door every bearer enters by. It shows the packet to
the monitor, files it, delivers it if it is ours — and now **carries it if it is
somebody else's**.

That last part was missing on every bearer but one, and it is the reason this
work happened. `onCarry` was called from `XprsIngest.reticulum` and nowhere else,
so a station carried mail that arrived over the internet and carried **nothing at
all** that arrived over a radio. `mesh_service.dart` asserted the opposite in a
comment, pointing at a BLE custody tap — which is wired to subtype `0x41`, while
XPRS airs on `0x58`. So third-party mail on the XPRS lane was neither parked nor
forwarded, and an overheard `?ACK` never released a copy we were holding.

Nothing errored. Nothing was refused. The station simply did less than it
claimed, which is how custody fails: **it is invisible when it does not happen.**

**One owner per form.** An XPRS packet goes to the funnel, whatever subtype it
arrived on; the legacy compact frame goes to the custody tap, which is the only
thing that understands it. Both used to run for every frame, so an XPRS message
heard on `0x41` was processed twice — two monitor sightings, gossip fired twice,
and `deliverXprs` ran twice, re-doing a signature verify and a sealed-body unseal
before the duplicate was caught. `deliverXprs` is now idempotent on its first
line, before any curve work.

Only a 1:1 to a station is custody material. A group is an address several
stations read (§6.3): no single key to seal to, no mailbox to carry toward.

### A watermark that moved too early

`XprsArchive.admit` only **queues**; the flush drops forged packets. The catch-up
sweep advanced its watermark from `admit`, so it stepped straight over packets
the flush then discarded and believed it held history it had never stored. The
watermark now moves from `XprsArchive.onStored`, which fires from the flush for
rows the transaction actually wrote.

## 5. The switchboard — an instrument, not a feature

Taking a lane away while the station keeps running is the only way to see what it
does about it: whether the fallback fires, whether the message is parked for
custody instead, whether it moves when the lane comes back. All of that is
invisible when all four bearers are healthy, which on a bench they always are.

```sh
curl localhost:3456/api/xprs/bearers                      # state of each
curl -XPOST localhost:3456/api/xprs/bearers -d '{"disable":["lan"]}'
curl -XPOST localhost:3456/api/xprs/bearers -d '{"only":["ble5"]}'
curl -XPOST localhost:3456/api/xprs/bearers -d '{"reset":true}'
```

A disabled bearer reports `disabled`, which is a third thing from `inactive` (the
radio is off) and `refused` (the radio said no), because those mean different
things to whoever reads the report.

**In memory only.** A forgotten switch cannot outlive the process.

Alongside it, `GET /api/xprs/held` answers "is this station actually carrying?" —
held rows grouped by target, with our own outbound (§36.12.1, a sender is its own
first holder) separated from mail we are carrying for other people. Custody had
no observable at all before this, which is precisely why it could be absent for
so long.

## 6. What is bounded

The carry fix means this station now parks third-party mail it previously
ignored, so the custody store grows where it did not. It is bounded by design:
`MeshStore.sweep` enforces a 7-day TTL and a byte quota, evicting
`ORDER BY urg, ts` — archives first, then the oldest in transit, lowest urgency
first. Measured on the bench at ~2000 rows of ≤250 bytes, far inside the quota.

## 7. Checking it on hardware

Three stations: C61 (`X3ARK`, phone, LAN + BLE), TANK2 (`X1VCVM`, phone, **WiFi
off — Bluetooth only**), desktop (`X16JK8`, LAN only).

| # | What | Observed |
|---|---|---|
| 1 | switchboard reads real state | `ble5/lan/reticulum` active, `lora` inactive |
| 2 | 1:1 to a LAN peer | `lan:sent`, everything else `unused` |
| 3 | disable the preferred lane | `lan:disabled`, falls back to `ble5:sent` |
| 4 | 1:1 to a BLE-only peer | `ble5:sent`, `lan/reticulum unused` |
| 5 | disable the only lane that reaches it | `ble5:disabled, lan:sent, reticulum:queued` |
| 6 | give the lane back | held mail moved — receiver's `ingested` 14 → 18 |
| 7 | held mail is visible | `GET /api/xprs/held` |
| 8 | **third-party carry** | C61 holds `sender=X1VCVM target=X16JK8` — mail between two other stations, heard on the XPRS lane. **Always zero before this change.** |

Case 8 is the one to re-run after any change here. It is the whole point, and it
is the one that fails silently.

## 7a. Closing the custody loop

For a day the store carried and never finished: `parked 1739, custodyOut 0,
purged 0, delivered 0`. Three faults, one per file.

**The receipt.** Nothing composed a `t:receipt`, so §36.8.1's only terminal
state had nothing to fire on. `xprs_receipt.dart` composes and reads one under
§13.7.1's exclusions — never for a group, a broadcast, a regional message, a
receipt, or a station never exchanged with — and **always signed**, because a
forged `s:ack` is *"a way to delete a message from the whole mesh, cheaply,
without holding anyone's key"*. One that does not verify, or whose signer we
cannot check, changes nothing.

**The release picked the wrong rows.** It inherited `ORDER BY ts LIMIT 256` and
took four — the four oldest in the whole store, which on a station holding 1,739
of its own stale rows are all its own. `MeshStore.releasableFor` selects for the
target, newest first, **carried mail before own**, bounded in bytes, skipping
anything inside its backoff. A release is an attempt; `relts`/`reln` stop the
recipient's 30-second beacon re-airing the same mail for ever.

**The release was not a relay.** §36.8.1 requires `via:`, the §13.1 budget and
the §13.2 loop check. It re-aired verbatim. `xprsMayRelay` and `xprsWouldLoop`
had zero callers since they were written; they have callers now, here and in
`XprsForwarder`, which appended `via:` while checking only half the rule.

**And one airtime budget** (`xprs_airtime.dart`), consulted by every re-airing
path and charged directly by the beacons, which reach the radio without passing
through the fan-out. `charged` counts every packet offered and `metered` only
those that incurred debt — so on a station with no LoRa the pair reads *96 seen,
0 owed* rather than a bare zero, which would mean both "nothing transmitted" and
"everything was free". It exists for §31.1's two cross-lane
rules: the strictest bearer binds, and a retry is not a new packet. One ledger
keyed on the §5 identifier, so one packet on two lanes is one entry however
often it is tried. Control packets are never deferred (§31.2). BLE is unmetered
on the spec's own word — §31.1 puts Bluetooth under *"range, so traffic is
naturally local and cheap"*; LoRa is the one bound by law.

The receipt then made an older bug audible: `deliverXprs` checked its dedup on
the way in and nothing recorded the delivery, so the same packet was delivered
again on every arrival — three identical `s:ack`s inside 150 ms. Bench after the
fix: **1.0 receipts per delivery**.

    C61      delivered=16   receiptsSent=16   purged=21
    DESKTOP  delivered=157  receiptsSent=157  purged=22
    desktop: t:message f:X1VCVM d:X16JK8 … via=X3ARK, bearer=lan

That last line is the chain: a message TANK2 could not deliver — it is BLE-only,
the desktop LAN-only — carried by C61 across the bearer boundary and delivered
with the carrier's callsign on it.

## 8. What is NOT done

- **Two schedulers still keep their own ladders.** The re-airing paths — the
  45 s `cmd:file` re-ask, the 120 s suppression re-air, the identity ask and the
  release — now consult `XprsRetryLedger`, and the beacons charge `XprsAirtime`
  even though they reach the radio without passing through the fan-out. What has
  **not** moved: `XprsCatchup`'s adaptive poll and `RnsService`'s LXMF ladder.
  Both already implement §13.7.2's reachability gate correctly and are the two
  most tuned loops here; moving them buys consistency, not correctness.
- **`scope:` by country** (§13.11.2) — needs to know which bearers leave the
  country. Not implemented.
- **Whether LoRa is a local bearer is an operator setting** (§13.11.1).
  `shortRange` is still a constant per bearer class.
- ~~`ConnectionRegistry`~~ — **deleted**, and the reasoning is worth keeping.
  Its base class had no `send`, four of its five entries wrapped no
  implementation, Reticulum — the primary transport — had no entry at all, and
  `bluetooth`/`lan` reported *unavailable* while both carried live traffic. One
  string in a boot-task description was its only reference outside its own
  directory. **An inventory that is wrong about the running system is worse than
  no inventory**, because the first person to trust it is misled by it. Reviving
  meant replacing the interface, every stub and the boot wiring — everything but
  the capability vocabulary, which now lives on `XprsBearer`, the abstraction
  packets actually go through. `http_transport` and `LoraConnection` survive;
  the latter decoupled, because `_LoraBearer` asks it one real question.
- The remaining bypass paths named in the analysis — the two beacon builders (of
  which only the LAN one signs), `enqueueAdvert` hardcoding the APRS subtype, and
  the triple-sent history reply — are unfixed.
