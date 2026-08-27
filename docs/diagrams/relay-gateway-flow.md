# Relay, gateway, carrier — what repeats a packet and what holds it

APRS had two roles that moved somebody else's packet: the **digipeater**, which
repeats what it hears, and the **iGate**, which puts it on the internet. XPRS
keeps both and adds a third — the **carrier**, which holds a packet for a station
that is not there.

This is where each of them actually runs, which is not where you would guess.

> `../XPRS.md` §1.1 names all three, and the distinction is load-bearing:
> a relay *"repeats a packet on the medium it heard it, within the hop budget,
> appending itself to `via:`"*; a carrier *"holds a message in custody for a
> station that is absent"*; a gateway *"republishes packets onto something that
> is not XPRS"*.

---

## Fig. 1 — The three roles, and where each one lives

The surprise is that no single piece of software does all three, and the
Flutter app — the thing most people run — does exactly one of them.

```mermaid
flowchart TB
    subgraph APRS["what APRS had"]
        direction LR
        A1["digipeater<br/><i>repeat what you hear, now</i>"]
        A2["iGate<br/><i>put it on the internet</i>"]
    end

    subgraph XPRS["what XPRS has"]
        direction LR
        X1["relay §13.1–13.2.1<br/><i>repeat, with via: and a hop budget</i>"]
        X3["carrier §13.3, §36.7<br/><b>hold it until they turn up</b>"]
        X2["gateway §13.11.3<br/><i>republish off-protocol</i>"]
    end

    A1 --> X1
    A2 --> X2
    NEW(["new in XPRS"]) --> X3

    X1 --> W1["ESP32 firmware<br/>LAN · LoRa · ESP-NOW"]
    X3 --> W3["the Flutter app<br/>every bearer"]
    X2 --> W2["the chat wapp — APRS-IS<br/>ESP32 firmware — APRS-IS"]

    classDef none fill:#F7DEDE,stroke:#A33A3A,color:#3F1414
    classDef some fill:#DCEFE3,stroke:#2E7D4F,color:#14351F
    class W1,W2,W3 some
```

| role | in the Flutter app? | where it is |
|---|---|---|
| **relay** (digipeat) | **no** | ESP32 firmware, on LAN, LoRa and ESP-NOW |
| **carrier** (store & forward) | **yes** | `MeshStore` + `MeshCourier` + `XprsForwarder` |
| **gateway** (iGate) | **no** | the chat wapp (wasm, over the app's socket HAL) and the ESP32 |

**Nobody digipeats BLE.** The firmware's relay engine is wired into LAN, LoRa and
ESP-NOW; `xprs_bearer_ble` does not include it. The app does not relay on any
bearer. So on the busiest off-grid lane there is no digipeater at all — a packet
travels one radio hop, and everything past that is custody.

**Which is enough to bridge bearers, and does.** §36.12: *"It can cross the
internet on one hop and a LoRa hill on the next; every hop is a holder."* A
BLE-only phone reaches a LAN-only desktop because a station that hears both
takes custody and hands it on — and §36.8.1 makes that hand-off a relay in every
respect that matters: the author's bytes and signature travel untouched, `via:`
gains the carrier, and the §13.1 budget and §13.2 loop check apply. Measured:

```
sent from TANK2 (Bluetooth only), arrived at the desktop (LAN only) in under 20s
t:message f:X1VCVM d:X16JK8 ts:… sig:… via:X3ARK m:…      bearer=lan
```

`f:` is still the author (§13: *"A relay never rewrites `f:`"*), `via:` names the
carrier, and the signature still verifies because §5 and §9.1 both exclude `via:`.

Two things had to be true for that to happen automatically rather than by luck,
and neither was:

- **The carrier has to say what it hears.** The BLE beacon built `hears:` from
  `MeshTable.neighbors`, a table nothing fills, so this station had never told
  anyone who it could reach. §36.9.4's gossip resolves "who can reach X" from
  exactly that field. It now reads the monitor, like the LAN beacon.
- **And sign it.** Gossip refuses an unsigned claim outright, so a populated
  `hears:` on an unsigned beacon still fed nothing. The BLE beacon is signed
  now, with room reserved before the neighbour list is fitted.

Before: the sender's gossip named only itself as a gateway to the desktop, and
mail for it had nowhere to go but the hope that a carrier happened to overhear
the one advert.

---

## Fig. 2 — What a relay is supposed to do (§13.1, §13.2, §13.2.1)

```mermaid
flowchart TD
    H["packet heard from somebody else"] --> LOOP{"our callsign<br/>already in via:?"}
    LOOP -- yes --> D1["drop — §13.2<br/><i>it went round in a circle</i>"]
    LOOP -- no --> BUDGET{"via: shorter than<br/>the type's limit?"}
    BUDGET -- no --> D2["drop — §13.1 budget spent<br/><i>sos/warning 9 · everything else 3</i>"]
    BUDGET -- yes --> WAIT["wait a RANDOM 200–1200 ms<br/>§13.2.1"]
    WAIT --> HEARD{"heard the same packet<br/>again while waiting?"}
    HEARD -- yes --> D3["drop — somebody was closer<br/>to the front of the queue"]
    HEARD -- no --> APPEND["append our callsign to via:"]
    APPEND --> AIR["re-air"]

    NOTE["§5 identifier and §9.1 signature<br/>both EXCLUDE via:, so relaying<br/>renames nothing and breaks no signature"]
    APPEND -.-> NOTE

    classDef drop fill:#F7DEDE,stroke:#A33A3A,color:#3F1414
    classDef go fill:#DCEFE3,stroke:#2E7D4F,color:#14351F
    class D1,D2,D3 drop
    class AIR go
```

The random wait is not politeness, it is the whole mechanism: every station in
range hears the packet in the same instant and every willing relay is ready to
transmit in the same instant. Without the jitter they collide; without the
cancel they all transmit anyway.

---

## Fig. 3 — Who implements that, and who does not

```mermaid
flowchart LR
    subgraph CODEC["the rules exist in both codebases"]
        C1["Dart: xprsMayRelay<br/>xprsWouldLoop · xprsAppendVia"]
        C2["C: xprs_append_via<br/><i>budget + loop in one call</i>"]
    end

    subgraph DART["Flutter app"]
        D1["xprsMayRelay — <b>0 callers</b>"]
        D2["xprsWouldLoop — <b>0 callers</b>"]
        D3["xprsAppendVia — 1 caller<br/>XprsForwarder"]
        D4["§13.2.1 jitter + cancel<br/><b>not implemented</b>"]
    end

    subgraph FW["ESP32 firmware"]
        F1["xprsbearer.c<br/>200–1200 ms jitter · 8 slots<br/>cancel-on-hear · cross-bearer cancel"]
        F2["LAN ✓ · LoRa ✓ · ESP-NOW ✓"]
        F3["BLE ✗ — does not use the engine"]
    end

    C1 --> D1 & D2 & D3
    C2 --> F1 --> F2
    F1 -.-> F3

    classDef dead fill:#F7DEDE,stroke:#A33A3A,color:#3F1414
    classDef live fill:#DCEFE3,stroke:#2E7D4F,color:#14351F
    classDef part fill:#FBEFD6,stroke:#A9701A,color:#4A3208
    class D1,D2,D4,F3 dead
    class F1,F2 live
    class D3 part
```

`xprsMayRelay` and `xprsWouldLoop` are **exercised only by unit tests**. The app
says so itself, and calls it a decision rather than a gap
(`lib/services/xprs/xprs_lan.dart`):

> This station does not relay. It airs what it composed and it ingests what it
> hears… a desktop is an endpoint on this bearer, and the digipeaters on the
> segment are the stations built to be one. Adding relaying here means
> implementing section 13.2.1 in full (the 200–1200 ms jitter AND the
> cancel-on-hearing), so it is a **deliberate omission rather than an oversight**.

**One deviation worth naming.** `XprsForwarder` is the single path that appends
`via:`, and it checks the loop by hand but **never checks the hop budget** —
while §36.8.1 says of exactly this hand-off that *"the section 13.1 budget and
the section 13.2 loop check apply"*. Half the rule is applied.

---

## Fig. 4 — The carrier: what XPRS adds over APRS

APRS loses a message addressed to a station that is not listening. XPRS holds it.
This is the role that has no APRS ancestor, and it is the one the app implements
fully.

```mermaid
sequenceDiagram
    autonumber
    participant S as sender
    participant H as this station<br/>(a carrier)
    participant R as recipient<br/>(not here yet)
    participant O as other custodians

    S-->>H: t:message d:R — overheard, not for us
    Note over H: §36.12.1 — the sender parked its own copy too;<br/>an airing is an ATTEMPT, not a delivery
    H->>H: park in custody §13.3<br/>bounded: 7-day TTL + byte quota, evict ORDER BY urg, ts

    Note over H,R: …hours pass. The recipient is somewhere else…

    R-->>H: any packet from R, heard DIRECTLY (no via:)
    Note over H: §36.8.1 — the trigger is the packet itself.<br/>NOT a poll: "a station that checks every ten seconds<br/>spends its battery asking a question the air already answered"
    H->>R: release held mail, on the bearer R was heard on
    R-->>H: t:receipt s:ack §13.7
    H->>H: purge our copy
    O-->>O: every OTHER holder that hears the receipt<br/>releases its copy too
```

That last line is why a receipt is worth repeating after the sender has seen it:
it is what drains a chain of custodians instead of delivering the same message
five times.

---

## Fig. 5 — Handing mail toward where the recipient actually is (§36.8.1)

Waiting is not the only option. A holder may move the mail closer while both
parties sleep.

```mermaid
flowchart TD
    M["held mail for X"] --> SENT{"already forwarded<br/>this packet once?"}
    SENT -- yes --> STOP1["stop — once per holder"]
    SENT -- no --> LOOPQ{"our callsign in via:?"}
    LOOPQ -- yes --> STOP2["stop — it passed through us already §13.2"]
    LOOPQ -- no --> L1{"L1 · X's own declaration<br/>t:mailbox hold: §13.12"}
    L1 -- found --> PICK
    L1 -- none --> L3{"L3 · freshest sighting<br/>gossip, 8 per callsign, 24 h TTL"}
    L3 -- found --> PICK
    L3 -- none --> L2{"L2 · visit history<br/>100-ring, never expires,<br/>RADIO sightings only"}
    L2 -- found --> PICK
    L2 -- none --> MISS["ask a super-archiver §36.9.4<br/>and meanwhile DEPOSIT with one<br/><i>rather than sitting on it</i>"]

    PICK["append our callsign to via:"] --> LANE{"can the network<br/>name this gateway?"}
    LANE -- yes --> LX["LXMF, addressed<br/><b>a deliberate crossing</b>"]
    LANE -- "no — e.g. an ESP32 gateway<br/>has no LXMF letterbox" --> BC["broadcast re-air, verbatim<br/>via: already carries us,<br/>so it cannot come back"]

    classDef stop fill:#E4E8EA,stroke:#64717A,color:#2A2E33
    classDef act fill:#DCEBED,stroke:#0F6E7B,color:#08343B
    class STOP1,STOP2 stop
    class LX,BC act
```

The recipient's own word outranks every observation — this is the one place
`hold:`'s preference order is consumed rather than merely stored.

---

## Fig. 6 — How a packet crosses bearers

The question this document exists to answer: a packet arrives on Bluetooth —
what puts it on the LAN, or on the internet?

**Almost always: nothing decided to.** There are exactly three places that re-air
somebody else's packet, all of them go through the publisher, and the publisher
fans out to every active bearer.

```mermaid
flowchart TD
    BLE["heard on BLE"] --> FUN["XprsIngest.heard"]

    FUN --> C{"third-party 1:1?"}
    C -- yes --> PARK["park in custody"] --> FWD["XprsForwarder"]
    FUN --> DH{"heard directly,<br/>and we hold mail for them?"}
    DH -- yes --> REL["release-on-hearing<br/>30 s throttle · max 4 · paced 1500 ms"]
    FUN --> CMD{"cmd:history for us?"}
    CMD -- yes --> REP["archive replay, verbatim"]

    FWD -- "gateway nameable" --> LXA["LXMF, addressed<br/><b>DELIBERATE</b>"]
    FWD -- otherwise --> PUB
    REL -- "recipient on BLE" --> MSP["MSP session — BLE only,<br/>no air at all"]
    REL -- "recipient elsewhere" --> PUB
    REP --> LXB["LXMF copy to the asker<br/><b>DELIBERATE</b>"]
    REP --> PUB

    PUB["XprsPublisher._fanOut"] --> G1{"scope:local<br/>and bearer is long-range?"}
    G1 -- yes --> BLOCK["blocked — the ONLY thing<br/>that stops the internet"]
    G1 -- no --> G2{"bearer disabled or inactive?"}
    G2 -- yes --> SKIP["skipped"]
    G2 -- no --> OUT["ble5 · lan · reticulum<br/><i>the crossing is a SIDE EFFECT</i>"]

    classDef del fill:#DCEBED,stroke:#0F6E7B,color:#08343B
    classDef side fill:#FBEFD6,stroke:#A9701A,color:#4A3208
    classDef blk fill:#F7DEDE,stroke:#A33A3A,color:#3F1414
    class LXA,LXB del
    class OUT side
    class BLOCK blk
```

Two crossings in the whole app are *addressed*: the forwarder's LXMF to a chosen
gateway, and the history server's LXMF copy to whoever asked. Everything else
reaches the internet because `_fanOut` puts the wire on every bearer that is up,
and `scope:local` is the only brake.

That is not necessarily wrong — §36.0 says a station that cannot tell which path
reaches the asker *"answers on every bearer it can transmit on"* — but it is
worth knowing that it is the fallback doing the work, not a routing decision.

---

## Fig. 7 — The gate on the way in from the internet (§36.3)

Radio traffic is bounded by radio range. Internet traffic is not, so the internet
lane has an admission rule the radio lanes do not.

```mermaid
flowchart TD
    IN["XPRS packet off Reticulum"] --> A["t:command / t:result → answered<br/><i>the gate governs what we SPOOL,<br/>not what we will say</i>"]
    A --> B["t:identity → bind the key"]
    B --> C["hears: → gossip<br/><i>L2 stays radio-only: link is 'rns'</i>"]
    C --> D{"addressed to us?"}
    D -- yes --> KEEP["archive it — our own mail"]
    D -- no --> CARRY["onCarry → custody + forwarder<br/><i>this already happened</i>"]
    CARRY --> E{"admitted to the archive?"}
    E -- "super-archiver keeping observation/identity/service" --> KEEP
    E -- "a publication: t:status, t:reaction,<br/>or a t:message with NO d:" --> KEEP
    E -- "an active t:mailbox hold: names us" --> KEEP
    E -- otherwise --> REF["refusedRns++<br/>rate-logged once a minute"]

    classDef ref fill:#F7DEDE,stroke:#A33A3A,color:#3F1414
    class REF ref
```

**The asymmetry is deliberate and worth seeing on a diagram:** `refusedRns` gates
the **archive only**. By the time a packet is refused it has already been offered
to custody and already been answered as a command. Refusing to *spool* a
stranger's traffic is not refusing to *carry* it.

---

## Where this disagrees with the specification

| §  | rule | state |
|---|---|---|
| 13.1 | relay budget by packet type | **applied** on the custody hand-off — the release and `XprsForwarder` both call `xprsMayRelay` now. Still not applied to a general digipeat, because there is none |
| 13.2 | loop check | **applied** on the same two paths |
| 13.2.1 | random wait, cancel on hearing | **not implemented in the app at all**; complete in firmware for LAN, LoRa, ESP-NOW |
| 13.11.3 | a gateway treats `scope:` as binding | honoured — `scope:local` is checked in the fan-out and in the chat wapp's APRS path |
| 36.8.1 | release on hearing, forward toward a gateway, once per holder | implemented |
| 9.4.1 | no self-generated callsign onto licensed spectrum | **violated**: the ESP32 iGate computes an APRS-IS passcode for an `X3` callsign |

The last row is the one that matters outside this codebase, because it is the
only one that puts traffic somewhere a regulator cares about.
