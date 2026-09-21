# XPRS and Meshtastic on one radio

Status: DECIDED 2026-09-19, and implemented in the ESP32 firmware. XPRS LoRa
runs on Meshtastic's default channel; every LoRa station repeats Meshtastic
traffic and bridges messages both ways. The firmware reference, with the bench
measurements, is `firmware/docs/lora.md`; the protocol is
`spec/XPRS.md` sections 3.2 (callsigns of other networks), 9.11.5 (a gateway
from another network) and 14.8 (the shared channel).

**The rules we follow are listed in `firmware/docs/lora.md`, "The rules
we follow", and section 5 below is the app's half of them.** Read both before
changing anything that touches an `MT` callsign.

**Meshtastic is one LoRa mode, not the LoRa protocol.** A station's radio runs
`xprs` (XPRS's own channel, as before 2026-09-19), `meshtastic` (the default,
this file) or `meshcore`, chosen by its owner and changed live, with no
restart (XPRS.md 14.8,
`firmware/docs/lora.md` "LoRa modes"). The app never assumes one: it
reads the mode a station reports (`lora:` on a setup result) and sets it only
through an owner's `cmd:set lora:` from the Firmwares wapp, through the core's
command courier like every other setting.

This file used to be the evaluation that decided against it. What it found
still holds and is kept below; what changed is the answer to its open
question.

---

## 1. Why one channel

A LoRa receiver is configured for a modulation, not a frequency: an SF7
receiver is deaf to SF11 on the same frequency, and the sync word is compared
in hardware before any software sees a byte. So there is no listening to both
networks and choosing per packet in software; sharing a channel means sharing
the modulation and the sync word.

In Europe there is one sub-band with 10% duty and 500 mW (869.4 to 869.65 MHz,
exactly one 250 kHz channel), and Meshtastic sits in it. Two LoRa modes on it,
each deaf to the other, is the worst of both: the airtime is shared anyway and
nobody can talk to anybody. So XPRS joined Meshtastic's channel.

## 2. The costs, accepted

| | 250-byte packet | silence owed at 10% duty |
|---|---|---|
| XPRS before, SF7/125 kHz | 389 ms | 3.5 s |
| LongFast, SF11/250 kHz, preamble 16 | about 2.1 s | 19 s |

About five times the airtime a packet cost before. What follows from it is in
the firmware reference: LoRa now carries only what somebody is waiting for
(messages, receipts, sos, commands, keys), never other stations' beacons, and
a station listens before it talks.

## 3. What the evaluation got right, and what it got wrong

Right, and built that way:

- **Reimplement, do not link.** Meshtastic is GPL-3.0; XPRS is Apache-2.0.
  The header, the protobuf messages, X25519 and AES-CCM are written from the
  public field numbers and the RFCs.
- **Wrap XPRS in a Meshtastic frame** (the "wrapped" option of the old 5.1):
  a clear `Data` on private portnum `0x158`, channel `XPRS`. Meshtastic nodes
  ignore it and relay it intact; a bare XPRS wire would have been read as a
  garbage header and relayed with bytes 12 to 15 rewritten. One frame holds
  233 bytes of XPRS; 234 to 250 go as two frames.
- **Model the bridge on the tree's foreign-network pattern**: its own state,
  its own dedup, hooks injected by the station.
- **Loop prevention had to be invented**: a translation carries `via:` (the
  bridge) and `zmid:` (the Meshtastic message), and what came from
  Meshtastic never goes back.

Wrong:

- **"The BLE5 bearer already caps at 184 bytes."** It does not. BLE5 extended
  advertising carries the full 250-byte packet (XPRS.md section 4); 184 was one
  low-cost test tablet's controller. The only transport with a smaller frame
  is now LoRa on the shared channel, and it splits rather than refusing.
- **"XPRS runs at 868.000 MHz."** The fleet had already moved to 869.5 MHz;
  it is now 869.525, Meshtastic's slot.
- **"The public channel decrypts with the well-known key", for DMs too.**
  Since Meshtastic 2.5 a DM is public-key encrypted (X25519 then AES-CCM), and
  2.7 refuses to send a DM on the channel key and rejects one on receipt. Every
  XPRS node on Meshtastic therefore carries a key pair, derived from its
  callsign so that every bridge presents the same one (Meshtastic keeps the
  first key it hears for a node).
- **Meshtastic identity as a `z` key on `t:identity`.** Not needed: a
  Meshtastic node IS an address in XPRS, `MT` plus its node number in eight
  hexadecimal digits (`MT0C39F654`), mapped the same way by every bridge.
  A MeshCore node is `MC` plus the first four bytes of its public key.

## 4. MeshCore

MeshCore uses the same modulation with sync word `0x12`, which is what XPRS
was on by accident. A radio holds one sync word, so a station shares a channel
with one network at a time, and which one is the `lora_mode` its owner sets.

Since 2026-09-20 the firmware speaks MeshCore too (`firmware/docs/lora.md`,
"MeshCore"): the same repeater and the same bridge, under the same rules, with
`MC` callsigns for its nodes. **Nothing in the app is Meshtastic-specific
because of it**: the core answers `foreign:meshcore` for those addresses
(section 5), and a wapp that has to name the network reads it from there. Two
differences are worth knowing when reading a translated packet: everything
from MeshCore arrives `scope:local`, because MeshCore asks its users nothing
about the internet and there is no consent to read; and a MeshCore channel
message is unsigned and names its sender only by a name, so it crosses only
under the address of a node whose advert the gateway heard using that name.

## 5. The app

The phone has no LoRa radio; it sees Meshtastic users through a station, as
XPRS packets from `MT…` callsigns. What the app does with them:

- **One kind, decided in core.** `xprsKindOf` returns `XprsKind.foreign`
  (word `foreign`) for `MT`/`MC` and exactly eight uppercase hex digits, and
  `xprsNetworkOf` names the network. The check runs before the licence rule,
  because `MT0C39F654` also has the shape of an amateur callsign. A foreign
  node is not an XPRS device: `classifyXprs` does not count it.
- **The monitor hands the verdict to wapps.** Rows from `hal_xprs_stations`
  and `hal_xprs_station` carry `kind: foreign`, `network: meshtastic` and,
  once heard, `nick`: the name the node's network gave it, from the
  gateway's unsigned `t:identity` (XPRS.md 6.3.1). The nickname is kept only
  for a foreign callsign; an `X` callsign's unsigned nickname is still never
  kept. The row also gets a `via Meshtastic` tag.
- **Never sealed.** `xprsBuildDirect` refuses a sealed body to a foreign
  callsign (`XprsSealRefusal.foreignNetwork`), so every sender path gets
  the rule, not only the chat. `hal_xprs_message` returns `-3` for that
  refusal and `3` for a plain message that leaves through a gateway.
- **What an address names is the core's.** `xprsAddressKind` (user,
  station, device, foreign, closed, open) is the one rule, handed to wapps as
  `hal_xprs_kind`. A foreign address carries its network in the same word,
  `foreign:meshtastic` or `foreign:meshcore`, so a wapp that has to TELL
  somebody where their words are going does not learn the prefixes either;
  a wapp that only wants to know whether this is a group reads the head of
  the word. Give the answer 32 bytes. The chat wapp and the shared finder
  (`hal/people_finder.h`) used to keep prefix tests of their own, which read
  `MTA1B2C3D4` as a group; both now ask the core, and chat remembers the last
  sixteen answers because it asks per rendered row.
- **Chat.** A node of another network is a room like any other. On `-3` the
  room turns plain, the words are not sent, and the room says why. On `3` the
  room says once that the message crosses a public channel. Both sentences
  name the network from the core's kind word (`xprs_network_name`), so a
  MeshCore contact is not told it is on Meshtastic. The finder lists any row
  the core gave a kind, and shows the name that network gave the node.
- **`zmid:` is the second duplicate key, checked at the one receive door.**
  `PacketGateway.receive` and `receiveInternet` drop a packet whose `zmid:`
  (with its part number, since every part of a split translation carries
  the same one) was already let in under a different section 5 identifier:
  two gateways on either side of a minute boundary. Nothing past the door
  (the ingest, the courier, the repeater, the wapps) sees the second copy,
  and `PacketGateway.translatedTwice` counts it.

Tests: `test/xprs_presence_test.dart`, `test/xprs_private_test.dart`,
`test/xprs_monitor_test.dart`, `test/xprs_gateway_dedup_test.dart`,
`test/packet_gateway_test.dart`, and in
the chat harness `a_meshtastic_contact_is_a_room_never_sealed_and_says_so_once`.

### 5.1 Rules for the app (adopted 2026-09-19)

1. **Everything an `MT` packet does goes through the core's doors.** In
   through `PacketGateway` (and nothing else reaches the ingest, the courier
   or the wapps); out through `XprsSend` (`hal_xprs_message`,
   `hal_xprs_broadcast`). No lane of its own, no shortcut in a service, no
   duplicate check or refusal in a wapp, and no wapp code that knows which
   bearer or which gateway carried it (docs/architecture.md 1 and 4).
2. **The core says what an address is**; a wapp asks `hal_xprs_kind` or
   reads `kind` on a row. A prefix test in a wapp is the defect this rule
   removed.
3. **The core refuses what cannot be done, and says so**: a seal to a
   foreign callsign is `foreignNetwork` (-3), never a quiet downgrade.
4. **The sender's consent is the reach.** A `scope:local` translation is not
   carried, deposited or put on the internet by the app either
   (`mesh_custody` already refuses it at admission).
5. **A test drives the path a person uses.** Chat through `POST
   /api/wapp/cmd` (`rooms_send`) or the chat harness; the remote API's
   `/api/xprs/send` builds its own packet and proves nothing about
   `XprsSend`.

### 5.2 Lessons learned (2026-09-19)

- The first `zmid:` check was put in `WappDelivery` and `MeshCourier`,
  where each saw only part of the traffic. A check that exists on two paths
  exists on neither: it moved to the door.
- The chat wapp's own callsign grammar read `MTA1B2C3D4` as an open group,
  because a Meshtastic number has no digit where a licence has one. The rule
  moved into the core (`xprsAddressKind`), which is also where the next
  network's form (`MC`) will be added once.
- A remote API default was changed to make a bench test pass (a DM to `MT`
  defaulted to plain). It was reverted: the core already refused the seal
  correctly, and the test should have gone through the chat wapp.
