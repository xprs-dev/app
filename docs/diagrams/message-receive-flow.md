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

## Fig. 2 — The core is supposed to be the only door. It is not.

The rule: everything converges on the core, and the core hands finished text to
a wapp. Green is the rule working. **Red is a lane that reaches a person without
passing it.**

```mermaid
flowchart TD
    B58["BLE5 0x58"] --> HEARD
    B41x["BLE5 0x41"] --> HEARD
    UDP["LAN UDP"] --> HEARD
    TCPl["LAN TCP · local peer"] --> HEARD
    HEARD["<b>XprsIngest.heard</b><br/><i>the intended funnel</i>"]

    HEARD --> FORUS{"addressed to us<br/>and renders to a person?"}
    FORUS -- yes --> DELIV["MeshCourier.deliverXprs<br/><i>verify · unseal · rejoin</i>"]
    FORUS -- no --> OTHER["carry · command · receipt"]
    DELIV --> INJ["RnsService.injectLxmf"]

    LXMFin["Reticulum · LXMF"] --> ADMIT["_admitToInbox<br/><i>the real single door</i>"]
    INJ --> ADMIT
    ADMIT --> INBOX[("_lxmfInbox<br/><i>in memory · unbounded · not persisted</i>")]
    INBOX --> WAPP["chat wapp"]

    MSPin["GATT · MSP custody"] --> ING["MeshCourier.ingest"]
    ING --> DELIV

    RNSX["Reticulum · XPRS wire<br/>addressed to us"] --> RET["XprsIngest.reticulum"]
    RET --> ARCHONLY["archive.admit<br/><b>then return</b>"]
    ARCHONLY --> NOWHERE(["never delivered<br/><i>no onDeliver · no log · no counter</i>"])

    PARC["GATT · BLEQueue parcels"] --> RAW
    B41raw["BLE5 0x41<br/><i>the same frame again</i>"] --> RAW
    RAW["BleService._inbound"] --> SCAN["hal_ble_scan_read"]
    SCAN --> BH["ble_handle<br/><i>the wapp parses it a second time</i>"]

    classDef good fill:#DCEFE3,stroke:#2E7D4F,color:#14351F
    classDef bad  fill:#F7DEDE,stroke:#A33A3A,color:#3F1414
    classDef warn fill:#FBEFD6,stroke:#B7791F,color:#4A3208
    class HEARD,ADMIT,DELIV good
    class RET,ARCHONLY,NOWHERE,RAW,SCAN,BH bad
    class MSPin,ING warn
```

> **The Reticulum branch is the one to read twice.** An XPRS `t:message`
> addressed to this station that arrives over Reticulum is filed in the archive
> and returned from — `XprsIngest.reticulum`, `lib/services/xprs/xprs_ingest.dart`.
> It is never delivered, never rendered and never notified, and nothing counts
> it. Any peer whose bearer chose Reticulum can send you a message you will
> never see.
>
> **And the raw lane is a second door into the same screen.** Every `0x41`
> frame is handed to the funnel *and* pushed onto `BleService._inbound`, where
> the wapp parses it again with its own dedup, its own digipeat and its own
> receipt.

---

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

## Fig. 5 — What stays the same about a message, and what does not

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

## What these figures do not show

The **send** path is drawn only where it explains a receive-side failure; it has
its own map in [transports-flow.md](transports-flow.md) Fig. 2 and prose in
[../private-messages.md](../private-messages.md). Groups and `#rooms` share most
of the inbound hops but diverge at the roster gate and carry no receipts.
Nothing here is a proposal — the findings and their ranking live in
[../message-receive.md](../message-receive.md).
