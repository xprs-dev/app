# Index — what to read before you change something

[README.md](README.md) says **what each document covers**. This one says **which
section to read before touching a given thing, and which paragraph in it will
save you a day**.

The sections called out below are not summaries. Each is a place where the
obvious approach is wrong and somebody already paid for finding out.

---

## Read these three before anything

| | |
|---|---|
| [architecture.md](architecture.md) | Where code belongs, which isolate may run it, and the guard that enforces both. **§4 "Which lane carries what"** — BLE5 advertising carries XPRS packets and nothing else, GATT+MSP carries bytes, Reticulum is the internet path. Confusing them cost a full day. **§5** explains the baseline and the `// arch-ignore:` escape. |
| [performance.md](performance.md) | Where CPU and memory actually go, and every regression that has already shipped here. **§8.5** is the one-line checklist for any new background work. **§8.7–8.10** are the four shapes that put a phone into swap, each of which *reads as free at the call site*. |
| [validation.md](validation.md) | What "done" means. A task is not done when it compiles, not when the tests pass, and not when you believe it works. |

`tool/arch_guard.dart` machine-checks part of the first two. Run it before
committing; it fails only on NEW violations.

---

## By what you are about to touch

### Moving bytes between two devices in radio range

| doc | the sections that matter |
|---|---|
| [architecture.md](architecture.md) | **§4** — name the lane before writing code. A file uses two at once: XPRS packets bracket it, MSP carries it. |
| [ble5.md](ble5.md) | **§1** the 5-seconds-a-minute transmit window and the rotation — *"a frame transmitted once may not be observed at all"*. **§3** the size router and every byte budget. **§4** the scan is never suspended, and why. **§5** the known failure modes. **§9** what was actually measured moving 56 MB. **§9.8** when a 1:1 skips the air entirely and goes point to point — and the gate that shipped dead because it read a table nothing fills. |
| [mesh.md](mesh.md) | **§3 Plane 2** the MSP data plane. **§7** politeness. **§14** the bulk lane under a large file: the two protocol bugs, the honest throughput, and the forty minutes two phones could not hear each other. |
| [store-and-forward.md](store-and-forward.md) | Delivery to someone who is not there, and why every up-front reachability test lies. |

**Before you start**: the bulk lane already exists and is validated. `cmd:file`
+ MSP is the answer to "send a file to that station"; do not build a third
thing.

### Anything over Reticulum

| doc | the sections that matter |
|---|---|
| [reticulum-connections.md](reticulum-connections.md) | The whole file is hard-won. *"The transport is almost never the problem — look before blaming it."* A display list is not a reachability list. Unknown is not empty. MTU discovery that floors itself back up is not discovery. |
| [folders.md](folders.md) / [sync.md](sync.md) | Mutable folders as a signed append-only op-log; collab folders on top. |
| [indexer.md](indexer.md) | What happened while I was not listening — the question a station cannot answer for itself. |
| [lan.md](lan.md) | The bearer that costs nothing when a station is on WiFi or ethernet. |

**Kept in this repo and in `xprs-esp32`, and they must not drift**: `ble5.md`
and `lan.md` describe transports with an end in each.

### Sending and receiving across bearers

| doc | the sections that matter |
|---|---|
| [transports-flow.md](transports-flow.md) | **Start here if you want the shape before the prose.** Seven diagrams: the component map, the send sequence, the per-bearer decision, the receive demux and funnel, the message lifecycle, and the bench instrument. |
| [transports.md](transports.md) | **§2** the three answers a bearer gives, and why `queued` had to exist. **§4** the receive funnel and the third-party mail nobody was carrying — the defect that motivated the whole thing. **§5** the bearer switchboard for testing. **§7** the eight hardware cases. **§8** what is deliberately not done. |

**Before you start**: custody is invisible when it does not happen — nothing
errors and nothing is refused. `GET /api/xprs/held` is the observable.

### Private messages, and which radio carries one

| doc | the sections that matter |
|---|---|
| [private-messages.md](private-messages.md) | **§1** privacy is one field (`x:` replaces `m:`) and therefore per packet — no flag, no negotiation, no mode. **§2** a private send is never quietly downgraded, and why §36.8 makes that correctness. **§4** the half-hour key-discovery hole and its two fixes. **§6** choosing a bearer under §36.0, and the two ways "recent evidence" was got wrong on the bench. **§9** what is validated and what is not. |

**Before you start**: the arrival bearer of a packet is not evidence of a path to
its sender, and `via:` cannot tell you otherwise because nothing transmits it.

### The XPRS protocol itself

| doc | the sections that matter |
|---|---|
| [XPRS.md](XPRS.md) | The specification. **Do not edit it** — it is byte-identical to `xprs-dev/spec` and `test/xprs_packet_test.dart` checks the corpus against it. **§4** the packet grammar and the 250-byte limit on every transport. **§6.7** files. **§25.2** `cmd:file`/`cmd:put`, and **§25.2.2** the transfer drawn end to end. **§31.2** what a station owes a stranger. **§36.9.4** super-archivers. **§37** implementation status — currently understates `cmd:file`, which is built. |
| [aprs.md](aprs.md) / [aprs-xt.md](aprs-xt.md) / [ble.md](ble.md) | The older APRS transport and the conventions layered on it. |
| [spectrum.md](spectrum.md) / [QO-100.md](QO-100.md) | Where packets go on each bearer, and reaching a satellite. Both proposals; nothing implemented. |

### Shipping a release

| doc | the sections that matter |
|---|---|
| [updates.md](updates.md) | **How a phone gets a new version**, end to end: the feed, the super-archiver as mirror, and the three lanes the bytes can take — including Bluetooth with no internet at all. **§7 the versionCode trap**. **§8** driving and checking it by API. **§9** what is validated and what is not. |
| [../releases.md](../releases.md) | The whole publishing chain. **§3** artifact names carry the version — a versionless name parses as a version and offers a release that does not exist. **§6 the versionCode trap** — a device carrying a hand-passed build number can detect every future release and install none of them, with no in-app symptom. **§7** checking a device by API instead of by screenshot. |
| [fdroid.md](fdroid.md) | Every host the built APK can reach, audited from the binary. `--dart-define=SELF_UPDATE=false` is the store variant. |

### Wapps, UI and the launcher

| doc | the sections that matter |
|---|---|
| [architecture.md](architecture.md) | **§1** what belongs in a wapp versus the core. A wapp hands the core a payload; it never decides how bytes travel. |
| [performance.md](performance.md) | **§8.4** wapps are *called on an interval*, they do not run services. |
| [reusable.md](reusable.md) | The libraries in `iwi/` — check here before writing a widget that probably exists. |
| [notifications.md](notifications.md) | How a wapp raises a notification and how it reaches the shade. |

Also: a foreground page engine's `hal_log` never reaches `LogService`, so it
never appears in `/api/log`. Only background-engine logs do. See `CLAUDE.md`.

### Social, chat and NOSTR

[NOSTR.md](NOSTR.md) is the vision; [nostr-client.md](nostr-client.md) the
client and its transport-abstract relay hub; [social.md](social.md) the Social
wapp in practice; [chat.md](chat.md) and [chat-rooms.md](chat-rooms.md) the
governed group chat and its signed moderation op-log; [circles.md](circles.md)
private encrypted groups over Reticulum.

### Files, torrents, media

[torrents.md](torrents.md) — the unit of sharing is a folder, not a file.
[torrent-import.md](torrent-import.md) and
[torrents-as-websites.md](torrents-as-websites.md) are planned, not built.

### Firmware

[esp32.md](../../xprs-esp32/docs/esp32.md) (in the firmware repo, not this one) — read it before firmware work: heap first, pin to core 1,
the FatFs traps, and how to measure without rebooting the board. Note the
ESP32 goes **deaf during an MSP session** (`ble5.md` §5), and GATT file
transfer there is deliberately out of scope for now.

---

## The lessons that generalise beyond their own document

Collected because each was learned expensively and none of them is obvious from
the code:

- **Name the lane first.** BLE5 = XPRS, GATT+MSP = bytes, Reticulum = internet.
  (`architecture.md` §4)
- **A size that is fine for the median case is not a design.** The same
  whole-file read appeared in four places, each correct for the photo it was
  written for. (`performance.md` §8.9, guard rule `no-whole-file-read`)
- **Any per-event log line is a bet that the event is rare.** A ring bounded in
  rows is not bounded in cost, and the component in the loop evicts the history
  that would explain it. (`performance.md` §8.7, §8.10)
- **If the answer is a number, ask for the number.** `.length` on a query is the
  expensive call wearing a cheap suit. (`performance.md` §8.7)
- **A poll interval is a battery setting**, not a freshness setting.
  (`performance.md` §6.5)
- **Unknown is not empty.** An accessor that cannot answer yet must not answer
  "nothing". (`reticulum-connections.md`)
- **Anything that must arrive re-airs until answered.** One transmission on the
  advert channel is a lottery. (`ble5.md` §1, §9.3)
- **A peer that asks again does not have it** — an ask outranks your record of
  having sent it. (`mesh.md` §14.2)
- **Verify on hardware, and say which parts you saw.** Report what was observed
  and what was not, separately. (`validation.md`,
  `reticulum-connections.md`)
- **A gate on a signal nobody transmits is not a gate.** A feature keyed on
  `MeshTable.neighbors` passed every test and was inert on the bench, because
  the beacon that fills that table is deliberately never aired. Before gating on
  a field, check the counter that proves it is on the air. (`ble5.md` §9.8)
- **Where a packet ARRIVED says nothing about where its sender is.** A re-aired
  packet is evidence about the relay. Use what the sender says about itself —
  `link:` — and age it on the packet's own `ts:`, not on when you heard it.
  (`private-messages.md` §6)
- **A fallback that hides a failure is worse than the failure.** Sealing that
  silently sent plaintext, and a sealed packet dropped because it would not
  open, were both "safe" defaults that destroyed the information the operator
  needed. (`private-messages.md` §2, §3)
- **A gate on a signal nobody transmits is not a gate.** A feature keyed on
  `MeshTable.neighbors` passed every test and was inert on the bench, because
  the beacon that fills that table is deliberately never aired. Before gating on
  a field, check the counter that proves it is on the air. (`ble5.md` §9.8)
- **Ask the peer, on the lane that will carry the message.** A capability the
  peer declares in its MSP HELLO beats a device class inferred from a beacon:
  transmitted, proof rather than guess, and wrong device types exclude
  themselves. (`ble5.md` §9.8)
- **Preferring a lane means telling the other one to stop.** A message the radio
  delivered still read as failed to Reticulum, which retried it for half an
  hour. (`ble5.md` §9.8)

---

## Housekeeping

- `plan-*.md` and `nostr-fix.md` are historical plans. `task-update.md` is a
  completed handoff. None describe current behaviour; read them for intent, not
  as documentation.
- Sibling repos assumed checked out beside this one: `../reticulum-dart` (a path
  dependency — the build fails without it), `../wapps`, `../website`, and the
  ESP32 firmware. See `CLAUDE.md`.
