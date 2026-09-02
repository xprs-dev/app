# Receiving a 1:1: the path, and where it breaks

## 1. Why this document exists

Three rounds of fixes each removed a real defect and left phone-to-phone
messaging no more trustworthy: messages still vanish, arrive twice, or never
leave the composer. That is the signature of a path nobody had drawn end to
end — every fix aimed at a hop, while the failures live in the seams.

So the path is drawn first, in
[diagrams/message-receive-flow.md](diagrams/message-receive-flow.md), and this
document is what the drawing found when it was held against the code. It covers
the **receive** direction for all four bearer inputs, the core, the handoff into
the chat wapp, the notification, and the last gate before a bubble.

It extends rather than repeats: [transports.md](transports.md) §4 owns the
funnel, [notifications.md](notifications.md) owns the notification pipeline from
the wapp's outbox onward, [chat.md](chat.md) §1 owns the host↔wapp contract, and
[private-messages.md](private-messages.md) owns the send side.

**Nothing here is fixed.** This is a survey, ranked by how much traffic each
finding destroys, so the order of work can be chosen deliberately.

How each finding was established is marked: **measured** on the bench,
**verified** by reading the named code directly, or **read** as part of the full
path trace and cited so it can be checked.

## 2. The path, in one paragraph

A 1:1 arrives on BLE5 (`0x58` XPRS advert, `0x41` legacy/compact, or a GATT
session carrying MSP custody), on LAN (`XprsLan` UDP, `XprsTcp`), or over
Reticulum (LXMF). **It cannot arrive on LoRa**: `LoraConnection.status` is
`unavailable` unconditionally and no serial or KISS Reticulum interface exists,
so LoRa reaches a phone only re-aired by a station and enters as one of the
other three. The radio lanes converge on `XprsIngest.heard`, which decides
whether the packet is ours, archives it, and hands a message addressed to us to
`MeshCourier.deliverXprs` — dedup, signature, unseal, §6.6 reassembly, sender
identity — which calls `RnsService.injectLxmf`. That, and the LXMF router, both
end at `_admitToInbox`, the only door into what a person reads. The chat wapp
polls that inbox on its tick (`hal_lxmf_recv` → `lxmf_drain`), strips `am:`,
answers the receipt, and emits `ui.convo.msg` plus `notify`. The host's
`ConversationStore` renders the bubble and counts the unread;
`NotificationService` raises the notification.

That is the design. Sections 3–10 are where the running code departs from it.

## 3. A message has no stable identity, so nothing that counts on one works

**measured + verified. Fixed 2026-09-02 — and the mechanism was not what this
section first said, which is worth correcting rather than quietly editing.**

It is not primarily a *retry* problem. `RnsService.sendLxmf` arms
`MeshCourier` with whatever it was asked to send, and on the publisher's path
that is **already a finished XPRS wire**: `_ReticulumBearer.send` is called
once per part (§6.6) and hands each part's own encoded packet.
`MeshCourier._air` then sealed that wire as the **body of a fresh
`t:message`** — a packet wrapped inside a packet, once per part. One 3-part
message became nine or more on the air, each with fresh ciphertext, a fresh
timestamp, and therefore a **fresh §5 identifier**.

A smaller multiplier sat on top: `sendLxmf` arms **twice** for one send (an
eager arming when the recipient is in earshot, then an unconditional one), and
each arming sealed again.

The give-away was already in the tree. `deliverXprs` unwraps nested wires
recursively, `depth < 4`, and its comment says "unwrapping is how the message
is found at all" — the receive side was repairing what the send side broke,
which is why this never surfaced as an error anywhere.

Measured on TANK2 `X1VCVM`, 2026-09-01, over the last 400 archived packets:

| | |
|---|---|
| logical 1:1 messages | **40** |
| packets they produced | **394** |
| distinct §5 identifiers | **394** |
| `am:` correlation ids present | **0** |
| distinct ciphertexts for one message's part 1 | **up to 11** |

Every downstream mechanism keys on the identifier. A `t:receipt` names one, so
an acknowledgement releases **one copy of thirty**; the remaining twenty-nine
stay parked, keep being re-aired, and every further retry mints more. The same
station reported `receipts.released: 1`, `purged: 1129` against
`delivered: 351`, and `sessionsAbrupt: 31` against `sessionsClean: 7`.

**Custody cannot drain, so the store overflows, so the row cap sheds real
mail — and the air stays busy enough to keep chopping the sessions that would
have delivered it.** This is the amplifier that makes every other finding
worse, and it is why the lifecycle in
[diagrams/transports-flow.md](diagrams/transports-flow.md) Fig. 6 — `Aired →
Arrived → Acked → Released` — does not describe the running system.

Ranked first because it is the only finding that *manufactures* traffic.

**The fix (2026-09-02).** A finished packet is carried unchanged.
`MeshCourier.carriableAsIs` names what qualifies — a `t:message` addressed to
a station, since a group post is aired rather than couriered (§6.3) — and both
routes into the store share one `_park`, so they cannot drift apart. Duplicate
armings of one message collapse. §31.1 says a retry is not a new packet;
neither is a carried copy. The receiver's unwrapping stays as recovery for
peers still on the old build, but nothing depends on it now.

## 4. A 1:1 that arrives over Reticulum is archived and never delivered

**verified.** In `XprsIngest.reticulum`
(`lib/services/xprs/xprs_ingest.dart`), the branch for a packet addressed to us
is:

```dart
if (toC.isNotEmpty && toC == self ||
    XprsGroups.instance.concernsUs(p, self)) {
  XprsArchive.instance.admit(p, bearer: bearer);
  return;
}
```

`onDeliver` is never called. There is no log line and no counter. An XPRS
`t:message` addressed to this station that arrives over Reticulum is filed in
the archive and disappears — and `_ReticulumBearer` is a bearer the sender's
fan-out will choose whenever it looks best.

**A whole bearer receives and discards, and says nothing.** The archive is the
proof: the message is on the device, in the spool, and was never shown.

## 5. The raw lane acknowledges messages it never renders

**verified.** Every `0x41` frame is handed to the funnel *and* pushed onto
`BleService._inbound`, which the chat wapp reads directly through
`hal_ble_scan_read` → `ble_poll` → `ble_handle`. That second path does the full
job: reassembly, `ENC1:` decryption, signature verification, its own dedup, its
own digipeat — and then `convo_deliver` **transmits a delivery receipt** to the
sender before calling `convo_msg`, which begins:

```c
if (!is_group(id) && !room_is_room(id) && !s_pre(id, "lxmf:")) return;
```

A 1:1 keyed by callsign — which is everything this lane produces — is dropped
there with no log, no counter and no trace.

The filter is deliberate; its comment explains that the Mail wapp owns kind-4
1:1 and chat must not rebuild a second inbox. **The receipt sent immediately
before it is not deliberate.** The sender is told *delivered*, draws its tick,
and stops worrying about a message the recipient will never see.

This is the most literal form of "messages disappear", and it is invisible from
both ends: the sender has positive confirmation, the receiver has nothing.

## 6. The post-join dedup asks for a key that is never written

**verified.** In `MeshCourier`, the check after §6.6 reassembly is

```dart
if (_alreadyDelivered('id:${xprsIdentifier(p)}')) return false;   // the joined packet
```

while the only writes are `_noteDelivered('id:${f.id}')` — the identifier of the
*arriving frame*, i.e. of whichever part completed the set. The joined key is
never stored, so on a re-airing of a split message:

- a **different** part completes the set → the message is delivered **twice**;
- the **same** part completes it → that part is bounced by the entry check and
  the set **never completes**, then expires silently after ten minutes.

Sealed 1:1s split early (a sealed body is ~40% larger), so this is the normal
case for a private message, not an edge one.

## 7. Sending to a bare callsign returns without a word

**verified.** The chat screen is a `$type:"rooms"` group, so every send emits
`rooms_send`. In `do_rooms_send`, a conversation id that is not `lxmf:`, not a
NOSTR room and not `#group` reaches:

```c
if (rid[0] == '#') convo_send_core(buf, rid, text);
return;
```

A bare `return`. No send, no bubble, no notification. The composer has already
cleared itself unconditionally (`chat_view_field.dart`, `_input.clear()` runs
before the wapp has even seen the text), so the message is gone from the screen
and from the device.

**This is exactly the "I type, the field clears, nothing happens" failure** —
and it depends only on which id shape the thread was opened with.

## 8. A notification often cannot fire at all

**read**, cited for checking.

- `notify_msg` never emits a `scope` field, so the foreground page defaults it
  to `app`: an in-app card, **no OS notification**, whenever the app is open.
- With chat autostart **off** and the page closed there is no engine, so
  nothing drains the inbox — and **nothing in the core notifies on its own**.
  `NotificationService.show` is never called from `RnsService`, `MeshCourier`
  or `MeshCustody`.
- `AnnouncedTagsStore` suppresses an already-announced tag **permanently, and
  persisted across restarts**. Chat's tag is `chat:<convo>:<mid>` where `mid`
  derives from *sender + text*, so **the same person sending the same words
  again is never notified again.**
- Unread counts are incremented by `ui.convo.msg`, never by `notify`, so the
  badge, the notification and the thread are three independent truths.

## 9. The inbox is in memory, unbounded, and not persisted

**read.** `RnsService._lxmfInbox` is a plain `List` with `add` as its only
writer. The wapp's read cursor (`_lxmfCursor`) is **per-engine and starts at
zero**, so every page-open ⟷ background handoff builds a fresh engine that
re-drains the whole inbox; courier-injected rows carry `hash: ''`, and
`gseen_add("")` is a no-op, so the wapp's envelope dedup cannot suppress the
repeat. Everything received while backgrounded is lost when the process dies.

## 10. Eighteen real states, three the screen can show

**read.** A message can be composed, refused before send, refused silently,
echoed, handed to LXMF, unconfirmed, queued in the ladder, parked for an
unreachable peer, ladder-exhausted, armed for the courier, refused by the
courier, parked in custody, suppressed for handover, handed to a carrier, on the
air, delivered, read, or released by an XPRS receipt. The UI renders **nothing,
one tick, or two ticks**, and `"sent"` draws nothing at all.

**Everything from *composed* to *on the air* is one indistinguishable blank.**
That is why none of the last three rounds could be evaluated without a
screenshot and a log tail — the screen genuinely does not carry the information.

## 11. The four lists

### (a) Double doors — one message, two ways in

1. **Funnel + raw lane** for every `0x41` frame — handed to `XprsIngest.heard`
   *and* pushed to `BleService._inbound`. Today the second copy dies at
   `convo_msg`'s id filter, so it does not double-render — but it **does**
   double-digipeat and double-acknowledge (§5). Widen that filter and it becomes
   two visible bubbles.
2. **Aired copy + MSP custody handover** — collapsed by `_alreadyDelivered`,
   but the two lanes write different key spaces: custody records `m.am` /
   `contentKey`, the courier records `id:<f.id>`, and only the courier's key is
   checked.
3. **Split message re-aired** — §6 above: delivered twice, or stuck forever.
4. **GATT parcel + broadcast re-air** — linked only by the wapp's whole-frame
   `fseen` hash, which a re-encoded copy misses.
5. **Direct LXMF + propagation mailbox** — guarded by a 1024-entry in-memory
   ring; a delayed mailbox copy after 1024 envelopes reappears.
6. **Cursor reset** — §9 above.
7. **Two live engines** — page engine and headless engine can both drain the
   same inbox into the same DB; only the claim handshake prevents it.
8. **Chat + Mail** — the same 1:1 is pushed directly *and* backed up as a
   kind-4 relay DM. Chat renders one, Mail renders the other, with separate
   unread stores and separate notifications.

### (b) Silent drops — no log, no counter, nothing on screen

The full enumeration is long; these are the ones that discard a *person's
message* rather than machine traffic:

- `XprsIngest.reticulum` — addressed to us, archived, returned (§4).
- `convo_msg` / `convo_touch` id filter — every callsign-keyed 1:1 (§5).
- `do_rooms_send` bare `return` for an unrecognised id shape (§7).
- `deliverXprs`: entry dedup, `xprsRendersToPerson`, post-join dedup, empty body.
- `XprsPartTable`: malformed `n:`, missing `f:`/`ts:`, unopenable sealed part,
  64-set cap eviction, 10-minute expiry.
- `lxmf_drain`: empty content, `xprs_is_wire`, the `g_chan_nomad` toggle and the
  per-channel toggle — both of which `continue` **after** the dedup ring has
  been marked, making the message permanently unrecoverable.
- `hal_lxmf_recv`: an oversized row is skipped **with the cursor already
  advanced**, and the `0` return makes the wapp stop draining for that tick.
- `_admitToInbox` / `injectLxmf`: empty source or content.
- `sendLxmf`: RNS not up, or a malformed destination — nothing sent, nothing
  queued, nothing armed, while the bubble already says *sealed*.
- `MeshCourier._air`: BLE off, or no self callsign.
- Notification: muted/undeclared convo, and the permanent tag guard (§8).

### (c) Held with no bound and no indication

- `MeshCourier._unresolved` — sender's key unknown; retried every 5 s, dropped
  at 24 h with no log and nothing on screen.
- `XprsPartTable` — incomplete sets die at 10 minutes, silently.
- `MeshCourier._armed` — dropped at 15 minutes, no log.
- `refusedNoSeal` — a private message that cannot be sealed is never aired,
  indefinitely, waiting on a `t:identity` that may never come.
- **Sealed-unreadable body** — this one *does* surface, as
  `[sealed — no key for X yet]`, but the placeholder is **never replaced when
  the key arrives**. There is no re-open pass.
- `MeshStore` custody rows — evicted by quota with no notice to anyone.
- The LXMF retry ladder — an unreachable peer's entry is re-scheduled every
  60 s **without spending a rung**, so it can sit indefinitely; and the queue
  evicts its oldest entry once past 100, silently.

### (d) Identity breaks

- Re-seal per attempt → new identifier per retry (§3). *The root one.*
- The joined-packet dedup key that is never written (§6).
- Custody's `am`/`contentKey` versus the courier's `id:<f.id>` (list (a) 2).
- Reassembly keyed on `(f, ts)` while each attempt re-seals: parts from
  *different* attempts land in one set. The plaintext is identical so they
  rejoin, which is luck rather than design.
- Courier-injected rows carry `hash: ''`, defeating the wapp's envelope dedup.

## 12. What this survey does not claim

The send path was traced only far enough to explain receive-side failures; it
deserves the same treatment. Group and `#room` inbound share most hops but
diverge at the roster gate and carry no receipts, and were not audited. The
findings marked **read** were established by tracing the code rather than by
reproducing each on the bench — they are cited by symbol and path so each can be
confirmed or dismissed on its own.

No fix is proposed here on purpose. §3 is the one that manufactures the traffic
the others drown in, and §4, §5 and §7 are each a complete disappearance of a
message with no trace at either end; that is the natural order of work, but it
is a decision, not a conclusion.
