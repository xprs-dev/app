# Receiving a 1:1 — from the air to the bubble

What this is for: to answer *where did the message go* without a debugger. Every
bearer a 1:1 can arrive on, the core it is supposed to converge in, the handoff
into the chat wapp, the point a notification is raised, and the last gate before
a bubble appears.

[transports-flow.md](transports-flow.md) draws the same territory as far as the
funnel and stops at *"deliver — verify · unseal · inbox"* (its Fig. 5). **This
document is the half after the inbox**, plus the lanes that never reach the
funnel at all.

Drawn against the tree on **2026-09-01**, and every figure is annotated with
what the code does rather than what the design intends. Where the two disagree
the box is red and the disagreement is named — those are collected, ranked and
costed in [../message-receive.md](../message-receive.md).

---

## Fig. 1 — Every way a 1:1 can arrive

The four inputs, drawn honestly: **LoRa is not a lane on this device.**
`LoraConnection.status` returns `unavailable` unconditionally
(`lib/connections/lora/lora_connection.dart`) and there is no KISS/serial
Reticulum interface in either repo, so LoRa reaches a phone only re-aired by a
station and enters as one of the other three. `lora` survives downstream as a
*label* on a peer's `link:` claim, nothing more.

```mermaid
flowchart LR
    subgraph BLE["BLE5"]
        direction TB
        B58["extended advert <code>0x58</code><br/><i>XPRS wire</i>"]
        B41["extended advert <code>0x41</code><br/><i>legacy compact + wapp broadcast</i>"]
        MSP["GATT · MSP session<br/><i>custody handover</i>"]
        PARCEL["GATT · BLEQueue parcels<br/><i>0x41 lane</i>"]
        XBL["GATT · XBLOB <code>0x42</code><br/><i>bulk files only</i>"]
    end

    subgraph LAN["LAN"]
        direction TB
        UDP["XprsLan · UDP 4242"]
        TCP["XprsTcp · text port"]
    end

    subgraph RNS["Reticulum"]
        direction TB
        LXMF["LXMF delivery<br/><i>the ordinary 1:1</i>"]
        WAPPD["wapp datagram<br/><code>tag: xprs</code>"]
        RELAY["NOSTR kind-4 backstop"]
    end

    LORA["LoRa<br/><i>no radio on this device</i>"]
    ST["a station<br/><i>bridges LoRa to BLE / LAN / RNS</i>"]

    LORA -. "only via" .-> ST
    ST --> B58
    ST --> UDP
    ST --> LXMF

    B58  --> F["core"]
    B41  --> F
    MSP  --> F
    UDP  --> F
    TCP  --> F
    LXMF --> F
    WAPPD --> F

    PARCEL -- "never reaches the core" --> W["chat wapp"]
    RELAY  -- "renders in the Mail wapp" --> M["mail wapp"]
    XBL --> SPOOL["MeshBulkSpool<br/><i>not a text lane</i>"]

    classDef good fill:#DCEFE3,stroke:#2E7D4F,color:#14351F
    classDef warn fill:#FBEFD6,stroke:#B7791F,color:#4A3208
    classDef bad  fill:#F7DEDE,stroke:#A33A3A,color:#3F1414
    classDef off  fill:#E6E8EA,stroke:#6B7280,color:#2A2E33
    class F good
    class PARCEL,RELAY bad
    class LORA,XBL,SPOOL off
    class ST warn
```

> **LoRa gets a dotted line and no box of its own.** `diagrams/README.md`:
> anything not built gets no box, because drawing one says the opposite.

---

## Fig. 2 — One door, and everything now goes through it

Audited 2026-09-02, re-checked after the gateway, the permission gate and the
Reticulum fix. **Green is through the door. Amber is fenced but still open.
Red is open and unfenced.**

```mermaid
flowchart TD
    subgraph THROUGH["through the door — every bearer that carries XPRS"]
        direction TB
        G["<b>PacketGateway</b><br/><i>demux · provenance · route by type</i>"]
        GATT["GATT — 4 roles"] --> G
        A58["BLE5 0x58 · 0x41 adverts"] --> G
        PARC["reassembled parcels"] --> G
        LANU["LAN UDP · TCP"] --> G
        RNS["Reticulum — LXMF router"] --> G
        DGX["Reticulum — <code>xprs</code> datagram tag"] --> G
        RV2["Reticulum — rendezvous"] --> G
        G --> FUN["XprsIngest · MeshCourier<br/><i>reassemble 6.6 · unseal · dedup</i>"]
        FUN --> BUS["event bus<br/><i>xprs.&lt;type&gt; · xprs.status.tx</i>"]
        G --> BUS
    end

    subgraph TEE["a copy, taken after the door"]
        direction TB
        RAW["hal_ble_scan_read<br/><i>compact frames only now</i>"]
    end

    subgraph PRIV["a wapp's own protocol — not XPRS"]
        direction TB
        DGRAM["circles: hal_rns_recv<br/><i>k:msg/ks/key… JSON</i>"]
        DM["mail: hal_relay_dm_recv<br/><i>kind-4 DM plaintext</i>"]
        SOCK["chat: hal_socket_recv<br/><i>APRS-IS TNC2 lines</i>"]
    end

    BUS --> W["a wapp"]
    RAW --> W
    DGRAM --> W
    DM --> W
    SOCK --> W

    classDef good fill:#DCEFE3,stroke:#2E7D4F,color:#14351F
    classDef warn fill:#FBEFD6,stroke:#B7791F,color:#4A3208
    classDef neut fill:#E4E8EA,stroke:#64717A,color:#22292E
    class G,FUN,BUS,RNS,DGX,RV2,GATT,A58,PARC,LANU good
    class RAW warn
    class DGRAM,DM,SOCK neut
    class W warn
```

> **Every XPRS packet now enters through one door.** There is no red tier left
> on this figure.
>
> **The bearers.** BLE (four GATT roles, both advert subtypes, reassembled
> parcels), LAN UDP, TCP, and all three Reticulum entrances — the LXMF router,
> the `xprs` datagram tag, and the rendezvous destination — reach
> `PacketGateway` and nothing else. WiFi Direct carries no packets of its own;
> it forms an IP group and the RNS interfaces run over it. LoRa is not a lane on
> a phone. The HTTP API composes and sends: it has no receive door.
>
> **The two that were left were both chat's, and both are closed.**
>
> `hal_rns_recv` on the tag `chat` was a complete XPRS lane inside a wapp:
> `ble_pack` composed a wire (which is XPRS), `hal_rns_broadcast` aired it, and
> the far side drained it straight into `ble_handle`. Transmit is now one
> `hal_xprs_send` — and everything the wapp did by hand around it, a per-device
> table with its own staleness TTL and a broadcast backstop for a peer behind
> NAT, is `XprsPublisher`'s §36.0 bearer ranking, for every bearer rather than
> for Reticulum alone. Receive is the bus.
>
> `hal_lxmf_recv` was a cursor over every private message on the device, with no
> recipient test. It is deleted rather than gated: a permission is the wrong
> answer to a door that should not exist. Foreign LXMF — a NomadNet or Sideband
> peer writing plain text — is refused at the host's inbox door, which ends that
> interop deliberately.
>
> **`hal_ble_scan_read` stopped being a door twice over.** Its feed is a copy
> taken after `PacketGateway`, and `ble_handle` now returns on an XPRS wire
> outright, so what it still reads is the compact frame: what the ESP32 airs,
> and the control frames (`?PING`, `?MAIL`, `?IGATE`, HELLO) that have no XPRS
> form. That also removed a second digipeater which repeated packets while
> appending nothing to `via:`.
>
> **Three doors carry a wapp's own protocol, not XPRS** — circles' `k:msg`/`k:ks`
> JSON, mail's kind-4 Nostr DM plaintext, chat's APRS-IS socket. A wapp owning a
> foreign protocol is the arrangement working.

## Fig. 3 — Inbox to bubble: the half nobody had drawn

Two doors into one UI. Lane A is the core's; lane B is the wapp reading the
radio itself.

```mermaid
sequenceDiagram
    autonumber
    participant Core as core
    participant Inbox as _lxmfInbox
    participant HAL as hal_lxmf_recv
    participant Wapp as chat wapp
    participant Host as ConversationStore
    participant UI as screen

    Note over Core,Inbox: LANE A — through the core
    Core->>Inbox: injectLxmf(source, content, hash:"")
    Wapp->>HAL: poll on tick
    HAL-->>Wapp: one row, cursor++
    Note right of HAL: cursor is per-engine and starts at 0<br/>a new engine re-drains the whole inbox
    Wapp->>Wapp: lxmf_drain — gseen(hash)
    Note right of Wapp: injected rows carry hash:""<br/>gseen_add("") is a no-op — no dedup
    Wapp->>Wapp: strip am: · answer ?ACK · thread_parse
    Wapp->>Host: ui.convo.msg  (id = "lxmf:<dest>")
    Wapp->>Host: notify
    Host->>UI: bubble + unread++

    Note over Core,UI: LANE B — the wapp reads the radio itself
    Core->>Wapp: hal_ble_scan_read (raw 0x41 frame)
    Wapp->>Wapp: ble_handle — fseen · digipeat · reassemble
    Wapp->>Wapp: convo_deliver — decrypt · verify signature
    Wapp->>Core: send_receipt(from, am, 'd')
    Note right of Wapp: the sender is now told "delivered"
    Wapp->>Wapp: convo_msg(id = "<CALLSIGN>")
    Wapp--xUI: dropped — id is not #group / room / lxmf:
    Note right of UI: nothing rendered, nothing counted,<br/>no log — after a receipt was already sent
```

> **The tick that lies.** On lane B the wapp does the whole job — reassembly,
> decryption, signature check — emits its own `trc("delivered")`, **transmits a
> delivery receipt to the sender**, and only then reaches `convo_msg`, which
> returns because the conversation id is a bare callsign. The sender sees one
> tick. The recipient sees nothing at all.
>
> The filter is deliberate (`convo_msg` says so: the Mail wapp owns kind-4 1:1).
> The receipt sent before it is not.

---

## Fig. 4 — Where a notification fires, and where it cannot

```mermaid
flowchart TD
    ARR["message rendered by the wapp"] --> NM["notify_msg"]
    NM --> G1{"id is #group / room / lxmf: ?"}
    G1 -- no --> X1(["no notification"])
    G1 -- yes --> G2{"60 s duplicate ring"}
    G2 -- dup --> X2(["dropped"])
    G2 -- new --> SEND["hal_msg_send<br/><i>no scope field is emitted</i>"]

    SEND --> WHERE{"which engine is running?"}
    WHERE -- "page engine · foreground" --> APP["scope defaults to <b>app</b><br/>in-app card only"]
    WHERE -- "headless · autostart ON" --> BOTH["scope forced to <b>both</b><br/>OS notification"]
    WHERE -- "page closed · autostart OFF" --> NONE(["<b>no engine · no drain</b><br/>message sits in _lxmfInbox"])

    APP --> TAG{"tag already announced?"}
    BOTH --> TAG
    TAG -- yes --> X3(["suppressed <b>permanently</b><br/>persisted across restarts"])
    TAG -- no --> SHOW["NotificationService.show"]
    SHOW --> LIFE{"app lifecycle resumed?"}
    LIFE -- yes --> INAPP["in-app only — tray suppressed"]
    LIFE -- no --> TRAY["system tray"]

    classDef good fill:#DCEFE3,stroke:#2E7D4F,color:#14351F
    classDef bad  fill:#F7DEDE,stroke:#A33A3A,color:#3F1414
    classDef warn fill:#FBEFD6,stroke:#B7791F,color:#4A3208
    class TRAY,SHOW good
    class X1,X2,X3,NONE bad
    class APP,NONE warn
```

> **Three ways a 1:1 arrives with no notification.** The wapp never emits a
> `scope`, so a message that arrives while the page is open is an in-app card
> and nothing else. With chat autostart off and the page closed there is no
> engine to drain the inbox, and **nothing in the core notifies on its own** —
> `NotificationService.show` is never called from `RnsService`, `MeshCourier`
> or `MeshCustody`. And the announced-tag guard is permanent and persisted:
> chat's tag is `chat:<convo>:<mid>` where `mid` derives from *sender + text*,
> so **the same person sending the same words again is never notified again.**
>
> Unread counts come from `ui.convo.msg`, not from `notify` — so a badge and a
> notification can disagree, and both can disagree with the thread.

---

## Fig. 5 — What stays the same about a message (fixed 2026-09-02)

Everything downstream — dedup, receipts, custody release, reassembly — assumes
a message keeps one identity. Sealing is per attempt, so it does not.

```mermaid
flowchart TD
    TXT["the words the user typed"] --> A1["attempt 1: seal"]
    TXT --> A2["attempt 2: seal"]
    TXT --> A3["attempt N: seal"]

    A1 --> C1["ciphertext 1"] --> I1["§5 identifier 1"]
    A2 --> C2["ciphertext 2"] --> I2["§5 identifier 2"]
    A3 --> C3["ciphertext N"] --> I3["§5 identifier N"]

    I1 --> D{"dedup · receipts · custody release<br/><i>all key on the identifier</i>"}
    I2 --> D
    I3 --> D
    D --> OUT(["N messages, not one"])

    STABLE["stable: sender · <code>ts:</code> · plaintext"] -.-> D
    NOTE["reassembly keys on <code>(f, ts)</code><br/><i>so parts from different attempts mix</i>"] -.-> D

    classDef bad  fill:#F7DEDE,stroke:#A33A3A,color:#3F1414
    classDef good fill:#DCEFE3,stroke:#2E7D4F,color:#14351F
    classDef off  fill:#E6E8EA,stroke:#6B7280,color:#2A2E33
    class OUT,D bad
    class STABLE good
    class NOTE off
```

**Measured on the bench, TANK2 `X1VCVM`, 2026-09-01** — the last 400 archived
packets:

| | |
|---|---|
| logical 1:1 messages | **40** |
| packets they produced | **394** |
| distinct §5 identifiers | **394** |
| `am:` correlation ids present | **0** |
| distinct ciphertexts for one message's part 1 | **up to 11** |

> A `t:receipt` names one identifier, so an ack releases one copy of thirty.
> The other twenty-nine stay parked and keep being re-aired, and every further
> retry mints more identifiers. `receipts.released: 1`, `purged: 1129`,
> `delivered: 351`, `sessionsAbrupt: 31` against `sessionsClean: 7`. **Custody
> cannot drain, so the store overflows, and the row cap sheds real mail.**
>
> This is why `transports-flow.md` Fig. 6 — `Aired → Arrived → Acked →
> Released` — does not describe the running system. It draws one identity for a
> whole life.

---

## Fig. 6 — Where a 1:1 dies

Every branch below discards a message the user believes was sent or received.
Red is silent: no log, no counter, nothing on screen.

```mermaid
flowchart TD
    S["a 1:1 exists"] --> SEND{"sending"}

    SEND --> S1["rooms_send with a bare callsign id<br/><b>bare return</b>"]
    SEND --> S2["hal_lxmf_send2 returns -1<br/><i>no XPRS key for this peer</i>"]
    SEND --> S3["sendLxmf: RNS not up<br/><b>nothing sent, nothing queued</b>"]
    SEND --> S4["courier _air: BLE off · no callsign<br/>· cannot seal · too long"]
    SEND --> S5["retry ladder: unreachable peer<br/><i>re-scheduled forever, no rung spent</i>"]

    S --> RECV{"receiving"}
    RECV --> R1["XPRS over Reticulum, addressed to us<br/><b>archived, never delivered</b>"]
    RECV --> R2["raw lane: convo_msg id filter<br/><b>dropped after a receipt was sent</b>"]
    RECV --> R3["post-join dedup asks for a key<br/>that is never written"]
    RECV --> R4["part set incomplete<br/><i>expires at 10 min, silently</i>"]
    RECV --> R5["sender's key unknown<br/><i>held 24 h, then dropped, no log</i>"]
    RECV --> R6["channel toggle off<br/><i>continue AFTER the dedup ring was marked</i>"]

    S1 --> D1(["the composer clears<br/>and nothing happens"])
    S2 --> D2(["toast, no bubble,<br/>text unrecoverable"])
    S3 --> D3(["bubble says sealed;<br/>nothing left the device"])
    R1 --> D4(["never seen"])
    R2 --> D5(["sender sees a tick,<br/>recipient sees nothing"])

    classDef bad  fill:#F7DEDE,stroke:#A33A3A,color:#3F1414
    classDef warn fill:#FBEFD6,stroke:#B7791F,color:#4A3208
    class S1,S3,R1,R2,R3,R4,R5,R6,D1,D3,D4,D5 bad
    class S2,S4,S5,D2 warn
```

> **The UI has three renderable states for eighteen real ones** — nothing, one
> tick, two ticks. Everything from *composed* through *on the air* is a single
> indistinguishable blank, which is why "did it send?" has never been
> answerable from the screen.

---

---

## Fig. 7 — Who decides which wapp gets a packet

Only **one** route is addressed. The rest are shared pools a wapp reads at will,
and a wapp gets a route by importing its symbol — there is no permission gate.

```mermaid
flowchart LR
    subgraph ADDRESSED["the core decides"]
        DG["wapp datagram<br/><code>[tagLen][tag][payload]</code>"] --> Q["_wappInbox[tag]<br/><i>private per wapp</i>"]
        Q --> MB[("WappMailbox<br/><i>durable · wakes the wapp</i>")]
    end

    subgraph POOLS["the wapp pulls"]
        LX[("_lxmfInbox<br/><b>one flat list</b><br/><i>no recipient test</i>")]
        AR[("XprsArchive<br/><i>wapp writes its own WHERE</i>")]
        RING[("XprsMonitor ring<br/><i>whole ring</i>")]
        BLE[("BleService._inbound<br/><i>every frame, every engine</i>")]
    end

    LX --> CHAT["chat"]
    AR --> CHAT
    AR --> SOC["social"]
    RING --> XW["xprs"]
    BLE --> CHAT
    Q --> CHAT
    Q --> CIR["circles"]

    RV["rendezvous"] -. "hardcoded" .-> CIR

    classDef good fill:#DCEFE3,stroke:#2E7D4F,color:#14351F
    classDef bad  fill:#F7DEDE,stroke:#A33A3A,color:#3F1414
    classDef warn fill:#FBEFD6,stroke:#B7791F,color:#4A3208
    class DG,Q,MB good
    class LX,BLE bad
    class AR,RING,RV warn
```

> **`_admitToInbox` tests two things: content is non-empty, content is not an
> XPRS wire.** It never looks at the recipient. The decision "this belongs to
> chat" is made nowhere in the core — chat is simply the only wapp that asks.
> Verified against the shipped wasm import tables: chat reads the LXMF inbox,
> BLE frames, the datagram lane, NOSTR and the archive; circles reads the
> datagram lane; mail reads NOSTR and relay DMs; social reads the archive.
> Nothing abuses it today. Nothing prevents it either — `wapp_engine` offers
> every HAL import to every module and swallows the failure when the module
> does not declare it, so a route is claimed by importing its symbol.
>
> **The datagram lane is the model.** Tag on the wire, core reads it, private
> queue per wapp, durable mailbox, absent wapp started on demand. That is what
> the other routes should look like.

---

## Fig. 8 — Rebroadcast, and whether `via:` is told the truth

Five paths put a packet back on the air. Four append `via:` and pay the hop
budget. One does not.

```mermaid
flowchart TD
    H["a packet arrives"] --> D{"which re-air path?"}

    D --> DIGI["digipeater §13.2.1<br/><i>jitter · cancel-on-hearing</i>"]
    D --> REL["custody release §36.8.1"]
    D --> SUP["suppressed re-air<br/><code>sweepSuppressed</code>"]
    D --> FWD["XprsForwarder<br/><i>mail migration</i>"]
    D --> HIST["history replay<br/><i>author's packet, by design</i>"]

    DIGI --> V1["via: ✓ · budget ✓ · loop ✓"]
    REL --> V1
    FWD --> V1
    SUP --> V2["<b>via: ✗ · budget ✗ · loop ✗</b><br/>goes out as if direct"]
    HIST --> V3["via: — not a relay"]

    V1 --> B{"onto which bearer?"}
    B --> BLE5["<b>BLE only</b>"]
    B -. "never" .-> LANX["LAN"]
    B -. "never" .-> RNSX["Reticulum"]

    classDef good fill:#DCEFE3,stroke:#2E7D4F,color:#14351F
    classDef bad  fill:#F7DEDE,stroke:#A33A3A,color:#3F1414
    classDef warn fill:#FBEFD6,stroke:#B7791F,color:#4A3208
    classDef off  fill:#E6E8EA,stroke:#6B7280,color:#2A2E33
    class V1 good
    class V2,SUP bad
    class B,BLE5 warn
    class V3,LANX,RNSX off
```

> **The digipeater throws the bearer away.** `heard()` is given the packet but
> not the bearer it arrived on, and its only transmit path skips every bearer
> whose name is not `ble5`. So a packet heard on **LAN is repeated on BLE** —
> an unlabelled LAN→BLE gateway — and a packet heard on LAN is never repeated
> on LAN. §13.1 says a station "repeats a packet on the medium it heard it".
>
> **The suppressed re-air airs the stashed bytes verbatim**, with no
> `xprsAppendVia`, no budget and no loop check, so a carried message can go out
> claiming to be a direct transmission. This is the same ambiguity the other
> release path documents as having been fixed; it was never fixed here.
>
> **The digipeater's own re-air is off-ledger airtime** — no `owedBy` check and
> no `XprsAirtime.charge`, so every repeat is spend nobody counted (§31.1).
>
> And the app has **no `bridge_out`**. The firmware has one: every arrival is
> offered to every other bearer, with four named operator switches. In the app,
> only 1:1 mail crosses bearers (via the forwarder). A `t:sos` heard on LAN
> reaches BLE only by the accidental digipeat above; heard on Reticulum it
> reaches nothing.

---

## Fig. 9 — What the polling costs

The event bus exists — `WappEventBroker`, `HostEventBridge`, `system.*` topics.
A subscribed wapp is CALLED — the broker delivers straight into
`module_handle_event`. What was left burning the battery was everything the bus
did not carry: core state had no topic, so a wapp that drew it had to ask.

```mermaid
flowchart LR
    subgraph WAS["before"]
        direction TB
        T["host timer<br/><i>every 0.2–5 s, per wapp</i>"] --> TICK["module_tick"]
        TICK --> P1["re-encode the traffic ring"]
        TICK --> P2["re-encode the RNS graph"]
        TICK --> P3["re-read the archive"]
        TICK --> P4["ask: any datagram?"]
        TICK --> P5["ask the host for the task list"]
        P1 --> N{"anything changed?"}
        P2 --> N
        P3 --> N
        P4 --> N
        P5 --> N
        N -- "almost always" --> NO["no — CPU spent anyway"]
    end

    subgraph NOW["after"]
        direction TB
        CH["something actually changes<br/><i>a packet, an announce, a flush</i>"]
        CH --> CS["CoreState.changed<br/><i>coalesced 250 ms · silent with no subscriber</i>"]
        CS --> BUS2["core.&lt;topic&gt;"]
        BUS2 --> HE["module_handle_event<br/><i>read it, once, with a reason</i>"]
    end

    classDef bad  fill:#F7DEDE,stroke:#A33A3A,color:#3F1414
    classDef warn fill:#FBEFD6,stroke:#B7791F,color:#4A3208
    classDef good fill:#DCEFE3,stroke:#2E7D4F,color:#14351F
    class NO,N bad
    class TICK warn
    class CH,CS,BUS2,HE good
```

| wapp | before | after | how |
|---|---|---|---|
| `archiver` | 5000 ms | **0** | `core.archive` |
| `mesh` | 2000 ms | **0** | `core.rns.graph` |
| `xprs` | 3000 ms | **0** | `core.monitor` |
| `social` | 700 ms | **0** | `core.archive` |
| `tasks` | 1000 ms | **0** | `core.tasks` |
| `atm`, `wallet`, `maps`, `terminal`, `widget_demo` | 0.5–60 s | **0** | empty tick — no clock needed |
| `circles` | 1000 ms | 15000 ms | `core.datagram.circles`; the clock left is a key retry |
| `bluetooth` | 2000 ms | 10000 ms | `core.mesh.topology`; the clock left is the "seen 40s ago" chips |
| `forum`, `movies` | **`Duration.zero`** | **0** | 0 now means no timer, not a hot loop |
| `chat`, `mail`, `files`, `torrents`, `install`, `app-creator`, `tester` | unchanged | unchanged | still polling — see below |

> **1252 wake-ups a minute across the wapps, down to 830** — and the two that
> were unbounded are gone with them. `forum` and `movies` declared `return 0;`,
> which passed straight into `Timer.periodic(Duration.zero, …)`, a hot loop for
> a function with an empty body; the power-tier throttle is `interval × 5` and
> zero times five is zero, so no battery tier could save it. Zero means no timer
> at all now, and a positive value is clamped to 200 ms, because a wapp is
> somebody else's code.
>
> **What CoreState publishes is a revision, not the data.** The wapp reads what
> it always read — `hal_xprs_traffic`, `hal_rns_nodes`, `hal_rns_recv` — just
> when there is a reason to. Two properties carry it: changes coalesce inside a
> 250 ms window, because a reader re-reads its whole view on each notification
> and one-per-packet would cost more than the poll it replaces; and nothing is
> armed for a topic nobody watches, so silence costs nothing.
>
> **What still polls, and why it is a different problem.** `chat` and `mail`
> poll transports the core does not own (a propagation pull, Nostr relays).
> `files`, `torrents`, `install` and `app-creator` poll the PROGRESS of a
> host-side job — a download, a compile, a folder scan. That needs a
> job-progress event with a shape of its own, not another state topic, and
> guessing at it here would just be a fifth pattern.

---

## What these figures do not show

The **send** path is drawn only where it explains a receive-side failure; it has
its own map in [transports-flow.md](transports-flow.md) Fig. 2 and prose in
[../private-messages.md](../private-messages.md). Groups and `#rooms` share most
of the inbound hops but diverge at the roster gate and carry no receipts.
Nothing here is a proposal — the findings and their ranking live in
[../message-receive.md](../message-receive.md).
