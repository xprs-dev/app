# Communication flow — diagrams

The decision flows behind [transports.md](../transports.md), drawn. Same rules, same
section references; this file is the picture and that one is the prose.

Mermaid renders on GitHub and in most editors.

---

## Fig. 1 — Where a packet enters and leaves

Four bearers, two directions, one funnel in and one fan-out out. The subtypes
matter: **XPRS airs on `0x58`**, and the custody tap that used to own carrying was
wired to `0x41`, which is how a station came to carry mail for nobody.

```mermaid
flowchart LR
    subgraph RADIO["bearers"]
        direction TB
        BLE["BLE5 advert<br/><code>0x58 xprs · 0x41 aprs</code>"]
        LAN["LAN<br/><code>UDP/TCP 4242</code>"]
        RNS["Reticulum<br/><code>LXMF + datagram</code>"]
        LORA["LoRa<br/><code>slot only, no radio yet</code>"]
    end

    subgraph CORE["core"]
        direction TB
        FUNNEL["XprsIngest.heard<br/><b>the one door in</b>"]
        FAN["XprsPublisher._fanOut<br/><b>the one door out</b>"]
        ARCH[("XprsArchive<br/>§5 identifier dedup")]
        STORE[("MeshStore<br/>custody")]
    end

    BLE  -- in  --> FUNNEL
    LAN  -- in  --> FUNNEL
    RNS  -- in  --> FUNNEL
    FUNNEL --> ARCH
    FUNNEL -- "ours" --> DEL["deliver to inbox"]
    FUNNEL -- "somebody else's" --> STORE

    FAN -- out --> BLE
    FAN -- out --> LAN
    FAN -- out --> RNS
    FAN -. inactive .-> LORA
    STORE -- "retry when a lane returns" --> FAN
```

---

## Fig. 2 — Sending a 1:1

`§36.0` allows choosing **one** path when there is recent evidence of several to
the same station. When there is no evidence, it fans out — that is the same
section's own fallback, not a shortcut.

```mermaid
sequenceDiagram
    autonumber
    participant App as Wapp / API
    participant Pub as XprsPublisher
    participant Mon as XprsMonitor
    participant Fan as _fanOut
    participant Best as chosen bearer
    participant Rest as other bearers
    participant Arc as XprsArchive

    App->>Pub: publishWire("t:message d:X16JK8 …")
    Pub->>Pub: parse · sign (§9.1)
    Pub->>Mon: declaredBearersFresh(X16JK8)
    Note right of Mon: what the STATION said it is on<br/>(its own link:, §10.6.1)<br/>aged on the packet's ts: (§4.8)
    Mon-->>Pub: ["lan"]
    Pub->>Fan: _fanOut(prefer: "lan")

    Fan->>Best: send(part, slot, ttl)
    alt carried
        Best-->>Fan: sent
        Fan->>Rest: (not used)
        Note over Rest: reported "unused"
    else not carried
        Best-->>Fan: refused / inactive / disabled
        Note over Fan: §36.0 — "it does not give up"
        Fan->>Rest: send on every bearer
        Rest-->>Fan: sent / queued / refused
    end

    Fan-->>Pub: per-bearer report + carriedBy
    Pub->>Arc: own(wire, bearer: carriedBy ?? "none")
```

> A packet the fan-out could not place is still filed, under bearer `none`. A
> period where a station reached nobody is a fact worth having.

---

## Fig. 3 — What one bearer does with one wire

The four verdicts are not decoration. `disabled`, `inactive` and `refused` mean
three different things to whoever reads the report, and `queued` exists because
the report was caught calling an arriving packet `refused`.

```mermaid
flowchart TD
    A["wire offered to this bearer"] --> D{"switched off?"}
    D -- yes --> DZ["<b>disabled</b><br/><i>operator or test</i>"]
    D -- no --> S{"scope:local<br/>and this bearer is long-range?"}
    S -- yes --> SZ["<b>scope</b><br/><i>§13.11.1 names bearers</i>"]
    S -- no --> AC{"radio up this second?"}
    AC -- no --> IZ["<b>inactive</b><br/><i>the radio is off</i>"]
    AC -- yes --> TX["send every part<br/><i>worst answer wins</i>"]
    TX --> R{"what did the medium say?"}
    R -- "on the air" --> SENT["<b>sent</b>"]
    R -- "taken by a store-and-forward lane" --> Q["<b>queued</b><br/><i>outcome not known yet</i>"]
    R -- "no" --> REF["<b>refused</b>"]

    SENT --> CB["names the archive bearer<br/>· satisfies a path preference"]
    Q --> CB2["names the archive bearer<br/>· does <b>not</b> satisfy a preference"]

    classDef good fill:#DCEFE3,stroke:#2E7D4F,color:#14351F
    classDef warn fill:#FBEFD6,stroke:#B7791F,color:#4A3208
    classDef bad  fill:#F7DEDE,stroke:#A33A3A,color:#3F1414
    classDef off  fill:#E6E8EA,stroke:#6B7280,color:#2A2E33
    class SENT good
    class Q warn
    class REF bad
    class DZ,IZ,SZ off
```

---

## Fig. 4 — Receiving: demux, then the funnel

One owner per form. An XPRS packet goes to the funnel whatever subtype carried
it; the legacy compact frame goes to the custody tap, which is the only thing
that understands it. Both used to run for every frame.

```mermaid
sequenceDiagram
    autonumber
    participant Air as BLE5 bus
    participant Dx as subtype demux
    participant Tap as MeshCustody tap
    participant Fun as XprsIngest.heard
    participant Arc as XprsArchive
    participant Cou as MeshCourier
    participant Fwd as XprsForwarder

    Air->>Dx: frame + subtype
    alt 0x58 xprs
        Dx->>Fun: heard(packet, bearer:"ble")
    else 0x41 aprs
        Dx->>Dx: does it parse as XPRS?
        alt yes
            Dx->>Fun: heard(packet, bearer:"ble")
        else no — legacy compact frame
            Dx->>Tap: onAirFrame(inbound)
        end
    else 0x55/0x56 rns · 0x4D beacon · 0x57 wfd
        Dx->>Dx: other planes, not XPRS
    end

    Fun->>Arc: admit (queues; flush writes and drops forged)
    Arc-->>Fun: onStored → catch-up watermark
    alt addressed to us
        Fun->>Cou: onDeliver — verify, unseal, inbox
    else somebody else's 1:1
        Fun->>Cou: onCarry — park in custody
        Fun->>Fwd: maybeForward toward their mailbox
    end
```

> The watermark moves from `onStored`, not from `admit`. `admit` only queues, and
> the flush drops forged packets — so a watermark advanced at admit time stepped
> over history the station never stored.

---

## Fig. 5 — What the funnel owes an arriving packet

Every bearer enters here, so this is the only place these questions are asked.

```mermaid
flowchart TD
    IN["XPRS packet + bearer label"] --> MON["monitor.offer<br/><i>sighting · link: evidence</i>"]
    MON --> ECHO{"f: is our own callsign?"}
    ECHO -- yes --> DROP["stop — our own echo"]
    ECHO -- no --> MBX{"t:mailbox?"}
    MBX -- yes --> REC["record the declaration §13.12"]
    MBX -- no --> VIA{"carries via:?"}
    REC --> VIA
    VIA -- "no — heard directly" --> GOS["gossip noteDirect<br/>+ release-on-hearing §36.8.1"]
    VIA -- yes --> IDT{"t:identity?"}
    GOS --> IDT
    IDT -- yes --> BIND["bind callsign → key §9.3"]
    IDT -- no --> ARCH["archive.admit"]
    BIND --> ARCH
    ARCH --> FORUS{"d: is us?<br/><i>base callsign — §3.1.3 accepts -N</i>"}

    FORUS -- yes --> ISMSG{"t:message?"}
    ISMSG -- yes --> DELIVER["<b>deliver</b><br/>verify · unseal · inbox"]
    ISMSG -- no --> CMD

    FORUS -- no --> CARRY{"t:message to a STATION?<br/><i>a group is aired, not couriered §6.3</i>"}
    CARRY -- yes --> PARK["<b>carry</b><br/>park in custody · forward §36.7"]
    CARRY -- no --> RCPT
    DELIVER --> ACK["<b>acknowledge</b><br/>signed t:receipt s:ack §13.7.1"]
    ACK --> RCPT
    PARK --> RCPT{"t:receipt s:ack?"}
    RCPT -- verified --> REL["<b>release</b><br/>purge the held copy — ours AND<br/>anyone else's we overhear §13.3"]
    RCPT -- "unsigned / unverifiable" --> NOOP["changes nothing §13.7.1"]
    RCPT -- no --> CMD["onCommand · onResult"]
    REL --> CMD
    NOOP --> CMD

    classDef act fill:#D9EAED,stroke:#0F7B8A,color:#08343B
    classDef bad fill:#F7DEDE,stroke:#A33A3A,color:#3F1414
    class DELIVER,PARK,ACK,REL act
    class NOOP bad
```

**The carry branch is the one that was missing.** It was reached only from the
Reticulum lane, so a station carried mail that arrived over the internet and
nothing at all that arrived over a radio.

**And the receipt branch is what ends it.** Nothing composed a `t:receipt`, so a
carried copy had no terminal state — measured at 1,739 parked, 0 purged, 0
delivered. The release fires on a receipt for **anybody**, not only for us:
§13.3 has a carrier discard its copy on *overhearing* the acknowledgement, which
is the only way a chain of custodians drains instead of delivering five times.
An unverifiable one changes nothing, because §13.7.1 makes a forged `s:ack` a
way to delete a message from the whole mesh.

---

## Fig. 6 — Life of a 1:1 message

```mermaid
stateDiagram-v2
    direction TB
    [*] --> Composed

    Composed --> Sealed: private — the default for a direct message §9.4
    Composed --> Clear: switched to plain, per packet §9.2
    note right of Sealed
        no recipient key ⇒ REFUSE
        never silently downgrade §36.8
    end note

    Sealed --> Parked
    Clear --> Parked
    Parked: parked in custody — a sender is its own first holder §36.12.1

    Parked --> Aired: fan-out places it
    Parked --> Waiting: no bearer took it

    Aired --> Queued: a store-and-forward lane has it
    Aired --> Arrived: receiver's funnel delivers
    Queued --> Arrived

    Waiting --> Aired: lane returns · retry ladder · peer comes back

    Arrived --> Acked: recipient composes a SIGNED t:receipt §13.7.1
    Acked --> Released: every holder that hears it purges §13.3
    Acked --> Held: an unverifiable receipt changes nothing
    Released --> [*]
```

---

## Fig. 7 — Taking a lane away, on purpose

The switchboard exists because none of the fallback behaviour is observable
while four healthy bearers are up.

```mermaid
sequenceDiagram
    autonumber
    actor T as bench
    participant C61 as C61 (X3ARK)
    participant TK as TANK2 (X1VCVM)<br/>Wi-Fi off — BLE only

    T->>C61: POST /api/xprs/bearers {"disable":["ble5"]}
    T->>C61: send 1:1 to X1VCVM
    C61-->>T: ble5 disabled · lan sent · reticulum queued
    Note over C61,TK: the only lane that reaches TANK2 is gone;<br/>the copy stays parked in custody

    T->>C61: POST /api/xprs/bearers {"reset":true}
    C61->>TK: held mail moves over BLE
    TK-->>T: ingested 14 → 18
```

---

## What these diagrams do not show

The [§31.1](../XPRS.md) airtime budget, because it is not built: a station should
transmit unsolicited traffic no more often than the **strictest bearer** it is
transmitting on allows, and **a retry is not a new packet**. Both are cross-lane
rules. There are eleven independent retry schedulers and no shared budget between
them, so there is no box to draw.
