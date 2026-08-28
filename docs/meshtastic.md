# XPRS and Meshtastic on one radio

Whether one ESP32 can be a Meshtastic node and a full XPRS station at the same
time, on one frequency, deciding per packet which stack should handle it.

Status: EVALUATION. Nothing here is implemented and no decision has been taken.
This is the record of an investigation so it does not have to be repeated.

---

## 1. The idea, and the one fact that constrains it

The shape people reach for is: the radio is always receiving, it does not know
or care what arrives, and software looks at the bytes and routes them to the
XPRS handler or the Meshtastic handler.

Above the physical layer that is exactly right, and the firmware is already
built that way — see section 5. Below it, it does not hold.

**A LoRa receiver is configured for a modulation, not for a frequency.** The
SX1262 demodulator correlates against chirps of one specific spreading factor
and bandwidth. A receiver on SF7/125 kHz is deaf to an SF11/250 kHz
transmission on the identical frequency: no correlation, no preamble detection,
no `RX_DONE`, no bytes. Then, after preamble detection, the chip compares a
**sync word in hardware** and discards a mismatch before anything reaches
software.

So there is no promiscuous mode to fall back on. A frame the silicon rejected
cannot be inspected, because it was never demodulated. Sharing a channel means
matching the modulation *and* the sync word — it is not a software decision.

## 2. What the three networks actually run

Every row below is from source, not from documentation.

| | frequency (EU) | SF | BW | CR | sync word | preamble |
|---|---|---|---|---|---|---|
| XPRS today | 868.000 MHz | 7 | 125 kHz | 4/5 | **0x12** | 8 |
| MeshCore | 869.525 MHz | 11 | 250 kHz | 4/5 | **0x12** | 16 |
| Meshtastic LongFast | 869.525 MHz | 11 | 250 kHz | 4/5 | **0x2B** | 16 |

- **XPRS**: `xprs-esp32/common/xprs_bearer_lora/xprslora.c:148-158`. The sync
  word is never written anywhere in `common/xprs_sx1262/sx1262.c` — the only
  register write in the driver is OCP (`:70`) — so it sits at the SX1262 reset
  default, which is 0x12. The SX1276 driver does not even define
  `REG_SYNC_WORD` (0x39).
- **MeshCore**: `src/helpers/radiolib/CustomSX1262.h:56` calls
  `begin(LORA_FREQ, LORA_BW, LORA_SF, cr, RADIOLIB_SX126X_SYNC_WORD_PRIVATE, LORA_TX_POWER, 16, …)`.
  RadioLib defines that constant as 0x12 (`src/modules/SX126x/SX1262.h:49`).
- **Meshtastic**: sync word 0x2B (`RadioLibInterface.h:84`), preamble 16
  (`RadioInterface.h:98`), LongFast SF11/250 kHz/CR4:5.

### 2.1 The two findings that matter

**MeshCore and Meshtastic are identical on air except one byte.** Same
frequency, same spreading factor, same bandwidth, same coding rate, same
preamble. They separate themselves on the sync word alone, deliberately. A radio
holds one sync word per configuration, so **XPRS can share a channel with one of
them or the other, never both.**

**XPRS is already on MeshCore's sync word** — by accident, not intent. Nothing in
the driver writes the register, so the chip default happens to be the value
MeshCore asks RadioLib for. Joining Meshtastic means moving off it.

## 3. What it would cost

Airtime, computed from the standard LoRa formula for a 250-byte packet:

| configuration | airtime | silence owed at 10% duty | vs XPRS today |
|---|---|---|---|
| XPRS today — SF7, 125 kHz | 389 ms | 3.5 s | 1.0× |
| [spectrum.md](spectrum.md) proposal — SF9, 250 kHz | 615 ms | 5.5 s | 1.6× |
| Meshtastic / MeshCore — SF11, 250 kHz | 2116 ms | 19.0 s | **5.4×** |

The model reproduces [spectrum.md](spectrum.md) section 2.1's own 615 ms figure
for SF9 exactly, so it is sound. Its SF11 row says 2050 ms where this says 2116:
the difference is 66 ms, which is precisely eight preamble symbols at 8.192 ms —
that table assumed preamble 8, and Meshtastic actually sends 16.

**In Europe there is nowhere else to go.** EU_868 defines a single Meshtastic
slot, 869.525 MHz. Joining it does not mean sharing *a* channel with them; it
means sharing *the* channel, at more than five times the airtime XPRS spends
today, on a band [spectrum.md](spectrum.md) already describes as crowded. That
document's own argument — "sharing a channel politely means being on it
briefly" — points the other way once XPRS is the one being slow.

If this is ever done, `XPRSLORA_PACE_DEFAULT_MS` (currently 6000,
`xprslora.h:87`) has to be re-derived from the new airtime rather than carried
over.

## 4. Three parameter sets, none deployed

Worth stating plainly, because it is why this is cheap to revisit:

- the shipping firmware runs SF7/125 kHz at 868.000 MHz;
- [spectrum.md](spectrum.md) proposes SF9/250 kHz at 869.525 MHz, and argues for
  SF9 *specifically* to avoid Meshtastic's airtime while sharing the band;
- `spec/XPRS.md` uses 433.775 / 433.900 MHz in its `t:channel` examples.

None of them is in the field beyond bench validation, and
[spectrum.md](spectrum.md)'s status line says as much. Nothing has to be
migrated, so the decision stays cheap until XPRS LoRa ships to users.

## 5. What the work would be

The dispatch layer is the easy part, and most of it exists.

- **PHY constants** — `xprslora.c:148-158`.
- **An explicit sync-word write** — SX1262 register `0x0740/0x0741`, currently
  never touched; and `REG_SYNC_WORD` for the SX1276 driver. Whichever value is
  chosen should be deliberate rather than inherited from a chip default.
- **Dispatch — the seam already exists.** `xprslora.c:82-86` calls
  `xprs_looks_like()` (`common/xprs_codec/xprs.c:29-33`: first two bytes `t:`,
  no 0x1F byte) and logs-and-drops everything else. Replacing that drop with a
  handoff is the whole change. Discrimination is unambiguous — XPRS is ASCII
  beginning `t:`, a Meshtastic frame opens with a binary header.
- **Reimplement, do not link.** Meshtastic firmware is GPL-3.0; XPRS is
  Apache-2.0. Work from `meshtastic/protobufs`. The public channel decrypts with
  the well-known `AQ==` PSK (AES256-CTR), and headers are cleartext regardless.
- **Model the bridge on `xprs_aprsis`**, the tree's existing foreign-network
  pattern: its own task, its own dedup ring, content policy enforced at the call
  site, and function-pointer hooks injected by the board's `main.c`
  (`common/xprs_aprsis/aprsis.h:44-47`). No bearer-layer changes.
- **Loop prevention has to be invented.** `spec/XPRS.md` section 13.11.3 puts
  gatewaying explicitly *outside* the section 13.1 hop budget and the section
  13.2 `via:` rules, so a bridge inherits none of it. The APRS-IS iGate in
  `wapps/chat/main.c` shows the discipline required: never re-originate own
  traffic, drop self-callsign echoes, never bridge control frames, content-hash
  dedup.

### 5.1 Raw frames, or wrapped in a MeshPacket

Two ways to put XPRS on a shared channel, and the choice is not obvious.

**Raw** — send the XPRS ASCII wire as the LoRa payload, as the firmware does
today. Simple, keeps the full 250-byte packet. But every Meshtastic node in
range preamble-detects it, fails to parse it, and discards it: their receive
time spent on something that could never have been for them.

**Wrapped** — carry XPRS as the payload of a Meshtastic `Data` packet on a
private portnum (256–511 is their range for unregistered applications). Two
advantages:

- **Their nodes relay it.** Meshtastic rebroadcasts on the header alone and
  floods packets whose payload it cannot decode, including unknown portnums. The
  existing Meshtastic infrastructure becomes XPRS digipeaters at no cost. *This
  should be tested rather than assumed.*
- It is the neighbourly option: a well-formed packet with an unfamiliar portnum
  is ignored cleanly instead of looking like interference.

The price is their hop limit, 16 bytes of header, and a `DATA_PAYLOAD_LEN` cap
of 233 bytes against the XPRS ceiling of 250. That cap is worth putting in
perspective: the BLE5 bearer already caps at **184 bytes**
([ble5.md](ble5.md) section 3), which is stricter, and the format already lives
with it — it is why `nick:` was dropped from the identity key binding
(`lib/services/xprs/xprs_publisher.dart:520-522`). A 233-byte ceiling is looser
than a constraint XPRS already accommodates.

## 6. Attaching a Meshtastic identity to an XPRS one

This part is independent of the radio question, cheap either way, and could be
done without any PHY change at all.

**On the radio lane**, the extension mechanism already exists and is mandatory.
`spec/XPRS.md` section 4.9 reserves **`z`-prefixed keys** for private and
experimental use, never assigned by the specification; section 2 rule 8 requires
an unknown key to be skipped without error; and section 9.1.2 signs the whole
packet minus `sig:` and `via:`, so an added key is authenticated for free. A
`zmn:!a1b2c3d4` field would therefore be a *signed* claim by the key holder.

It needs its **own** `t:identity` packet rather than riding on the key binding.
The key-binding form is 171 bytes; adding ` zmn:!a1b2c3d4` reaches 185, one byte
over the 184-byte smallest measured BLE5 advertisement. Section 9.3.2 makes
`t:identity` a per-field last-write-wins register — "a receiver keeps, for each
field, the value from the newest verifiable announcement that carried it" — so a
standalone ~121-byte announcement is exactly what the format expects.

**On the internet lane**, kind-30078 (NIP-78 app-data) already carries two
foreign-identifier namespaces, `d:<CALLSIGN>` and `d:mailto:<email>`, with a
store → mesh → internet resolution ladder
(`lib/services/reticulum/rns_service.dart:7388`,
`lib/services/social/email_resolve_service.dart`). A `d:meshtastic:!id`
namespace drops into that machinery with almost no new plumbing.

**`NodeProfile` is the wrong layer.** It describes physics — power source,
uplink, radios, geohash — not naming, and it rides only in the Reticulum
announce, so no LoRa or BLE station ever sees it.

**One mistake not to repeat.** `lib/wapp/shared_media_fetch.dart:53-64` scrapes a
peer's I2P address out of message text as `dest:<b32>.b32.i2p`. That token
collides with the specification's assigned `dest:` key (section 4.1, typed
`coord`), and survives only because it is read from `m:` text rather than parsed
as a field. A Meshtastic binding wants a `z` key, per section 4.9.

## 7. The open question

Is more than five times the airtime worth sharing a channel?

Everything else here has an answer. This does not, and it is the only one that
matters: it decides whether XPRS spends its LoRa budget being a good neighbour
on somebody else's channel, or being fast on its own. [spectrum.md](spectrum.md)
section 2.1 already argued one way; this document is the measurement that makes
the trade explicit.

Also unresolved, and cheaper: whether to keep the accidental MeshCore
compatibility (sync word 0x12) rather than move to Meshtastic (0x2B). XPRS has
that compatibility today without having chosen it, and would give it up.
