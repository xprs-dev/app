# Plan: the Check-in wapp

Status: built (2026-11-11): wapp `../apps/checkin` 0.1.0, bundled as
`assets/wapps/checkin.wapp`; the core gap of section 7 (item 4) closed in
`XprsPublisher`. Sections 2.4 and 7 below are updated to what shipped. The spec (`../spec/XPRS.md`) is not changed:
everything below uses packets, keys and mechanisms it already has, and the
check-in is a meaning agreed between two copies of this wapp. Layering follows
[architecture.md](architecture.md).

## 1. What it is

A logbook of meetings over the air, in the spirit of the radio amateur QSL
card, turned into a game of chasing stations. A person goes near a station, in
person over Bluetooth, WiFi or the LAN, or within LoRa range, and asks it for a
check-in. The station answers with a signed certificate saying it heard that
person's signed request, on which radio, where and when, and which badge it
handed out. The two packets together are evidence nobody can alter afterwards.
The chaser's logbook keeps them, counts them over days, months and years, and
shows the badges on a wall.

One wapp, two roles:

- **Chaser:** checks in at stations nearby, keeps the logbook and the badge wall.
- **Station:** the bot. It answers check-ins from stations in local or regional
  reach, greets the visitor with the owner's message, keeps a guestbook, and
  runs events with their own badge.

## 2. The packets, all ordinary

### 2.1 The ask: one operator-defined command

XPRS.md 11 leaves the meaning of a `cmd:` word to the two stations that use
it, so `cmd:checkin` needs no assignment anywhere. It is an ordinary signed
command: it expires after 300 s, is never carried, and a repeat names the same
identifier (11.4), which is exactly what proof of presence needs.

```
t:command f:X1QZ3N d:X3RLY7 ts:2026-08-08_14:26:40 cmd:checkin scope:local sig:<60 characters>
```

`scope:local` asks for an in-person check-in; `scope:regional` also allows
LoRa. The chaser's position is not sent.

### 2.2 The certificate: the command's result

```
t:result f:X3RLY7 d:X1QZ3N ts:2026-08-08_14:26:41 r:747ae8 code:200 scope:local link:ble rssi:-61dBm file:<badge digest>.png sig:<60 characters>
```

Every key already exists in the format. Under the station's signature it binds:

- `r:` the identifier of the chaser's signed ask (chaser, time, scope);
- `link:` and `rssi:` how the station heard it, copied from the `bearer` and
  `rssi` the core reports with the delivered packet;
- `route:` the relays the ask came through, only when there were any;
- `pos:` the station's position, from the host's GPS sensor or the position the
  owner set;
- `title:` during an event, naming the station's own `t:event`;
- `file:` **the hash of the badge, and nothing else**. The bytes never travel
  with the check-in.

Refusals use the codes 11.1 already has: `403` unsigned, unverified or heard
out of its scope's range (the core's `inRange` verdict), `408` too old, `429`
already checked in today or over budget, `404` bot paused. A station without
the wapp stays silent, because the core ignores command words it does not own.

### 2.3 The greeting

The owner's message goes as an ordinary direct message through
`hal_xprs_message`, with `r:` naming the ask. It shows up in Chat as well, and
the logbook shows it on the entry.

### 2.4 Events

A station announces an event with the existing `t:event` (XPRS.md 26), marked
with a sender-chosen topic label (`tag:`, 4.5) so the wapp can tell its own
events from others:

```
t:event f:X3RLY7 ts:2026-06-27_09:00:00 title:field-day-2026 tag:checkin until:2026-07-04_09:00:00 file:<event badge digest>.png pos:38.7810,-9.2043 sig:<60 characters> m:on the hill
```

A signed event with a badge hash and a position leaves little room: `since:`
is left out when the event starts at its `ts:`, `kind:` is not sent, and the
description takes what is left.

It is a publication, so the core deposits it with the archivers (12.1) and
chasers far away can see it before they set out. Between `since:` and
`until:` the bot puts `title:` and the event badge's hash on every
certificate.

## 2.5 Every check-in is a place (0.2.0)

A certificate without `pos:` is not a check-in: the chaser's wapp refuses to
log one, and a station that does not know where it stands gives none (it
answers `code:500`, and its owner cannot turn it on). The position is the
station's GPS fix, or the one its owner set (My station, or "Set my station
here" on the map), written with four decimals. `pos:` goes right after
`link:`, then `route:` when the ask came through relays (required then, since
it decides the grade), then the badge, the event and the signal as far as
they fit signed.

## 2.6 The map (0.2.0)

The first tab is a black-and-white map (`tile-style: mono`) with a pin for
every check-in (white) and every check-in event still running (amber); a pin
opens its evidence. The map centres on the check-ins. The region around them
is saved for off-grid use at zooms 3 to 9, once per new area
(`ui.map.prefetch`, at most 500 tiles); "Save this area offline" saves the
area on screen three levels closer, at most 1500 tiles. The host paces and
caps both, because OpenStreetMap's tile server, the default, refuses bulk
downloads: a self-hosted or licensed tile source belongs in `tile-url` for
heavier use.

## 3. Badges: a hash, fetched through the core

The badge is an ordinary file in the media store, referenced by hash:

- **Station side:** the owner picks a picture. The wapp imports it with
  `hal_media_put_file`, which returns the `file:<digest>.<ext>` token, and
  stores that token as its badge, or as an event's badge. When a packet
  carrying `file:` goes out, the core advertises the hash (`XprsSend.onFileShared`,
  DHT), and the station serves the bytes on `cmd:file` like any holder.
- **Chaser side:** for each badge hash in the logbook the wapp calls
  `hal_media_fetch(token)` once. The core looks in the local store first, then
  asks the holders and archivers over Reticulum or whichever lane its own
  decision picks, and caches the result. The wapp follows `core.media` events
  and `hal_media_state`, and draws the badge once it is `ready`. It never
  receives bytes and never names a lane (architecture.md, "How a file is
  shared in chat").
- A badge already held is never fetched again, so the wall works offline.

## 4. Who does what

Following architecture.md §1 and §3: the wapp owns what a check-in **means**
and how it is shown; the core owns every delivery, retry, signature and file
transfer.

| Concern | Owner | How |
|---|---|---|
| Sending the ask, retrying it on other bearers, giving up | core | `hal_xprs_send` hands the command to `XprsCommandCourier`, which re-airs and reports `unanswered` on `xprs.status.tx` |
| Signing the ask and the certificate | core | `hal_xprs_send` signs what the wapp composed |
| Keeping the ask and the certificate inside their scope | core | scope rules at both ends of every hop (9.11) |
| Which radio the ask came in on, its signal, signature and scope verdicts | core reports, wapp reads | fields on the delivered packet row |
| Deciding to certify, refuse, or stamp an event | wapp | rules: once per day, local only or regional too, event window |
| Badge bytes | core | `hal_media_put_file`, `hal_media_fetch`, `hal_media_state` |
| Logbook, guestbook, events, counts | wapp | `hal_db` (a zx store under the wapp's data dir) |

**Subscriptions, and only while needed** (architecture.md, "A command is the
core's to deliver"):

- The chaser listens to `xprs.result` and `xprs.status.tx` only while a
  check-in is out, then unsubscribes.
- The bot, while turned on, listens to `xprs.command`, which only carries
  commands addressed to this station, a rare event. It declares no tick.
- Nearby stations are read with `hal_xprs_stations` when the screen is drawn,
  following `core.monitor`, never by subscribing to beacons.

**What the wapp must not do:** ask archivers itself, re-send the ask on a timer,
choose a bearer, keep its own copy of other stations' beacons, or receive badge
bytes.

## 5. What the evidence proves

**Proves:** the holder of the chaser's key asked at a given time; the holder of
the station's key says it heard that exact signed ask on a given radio, at a
given strength, through given relays, and handed out a given badge. Anyone
holding the two public keys can check both signatures offline, years later.
The logbook exports as the raw packets.

**Does not prove beyond the station's word:** a station can certify a friend
who was never there, so every entry shows who issued it. The 300 s window,
`route:` and the signal strength make a relayed or bridged ask visible.

**Grades shown on each entry:** local (Bluetooth, WiFi, LAN: in person),
regional direct (LoRa, no relays), regional relayed.

## 6. The wapp

`tools.xprs.checkin`, folder `checkin`, in `../apps/checkin`, C to WASM.

**Screens**

1. **Nearby:** stations heard now, marking the ones known to give check-ins
   (they answered before, or announced a check-in event) and the ones already
   in the logbook. One button: Check in.
2. **Events:** check-in events known from the archive (`hal_xprs_history`,
   `kind:event`, filtered on the `checkin` tag), running now or coming up,
   with distance.
3. **Logbook:** entries by date and by station; unique stations, total
   check-ins, events, streaks, first and latest visit; the greeting on each
   entry.
4. **Badge wall:** a grid of badges; event badges with title and date; a badge
   earned several times shows a count.
5. **My station:** turn the bot on, greeting, badge, rules, events, guestbook.

Discovery of ordinary stations is by trying: a station that answers is
remembered as a check-in station. Nothing new is announced on the air for it.

## 7. Host capabilities, as verified

1. Confirmed: every heard command reaches wapps on `xprs.command` with
   `bearer`, `rssi`, `via`, `sig`, `inRange` and `forUs`
   (`PacketGateway` -> `WappDelivery.deliverPacket`).
2. Confirmed: `hal_xprs_send` signs a wapp-composed `t:result` and airs it
   ahead of the queue (results are never held back).
3. The identifier comes from the wire the wapp built (`al_id`, as Alerts
   does): a signature changes nothing it covers. The signed copy of the ask is
   read back from the archive by id (`hal_xprs_history {"id":...}`); results
   are never archived, so the wapp keeps each certificate itself.
4. Was missing, now in the core: `publishWire` advertises a referenced file,
   and `depositArchivers` places the bytes behind a publication's `file:` with
   the archivers (`XprsPublisher.depositFileTo`, `_placeFile`). A badge thus
   reaches archivers through its `t:file` description, and a chaser's
   `hal_media_fetch` finds it there over Reticulum.

The original list, kept for the record:

1. A `t:command` addressed to this station is delivered to a wapp on
   `xprs.command` with `bearer`, `rssi`, `via`, `sig` and `inRange`.
2. `hal_xprs_send` accepts and signs a wapp-composed `t:result`.
3. The chaser can obtain the identifier and the signed copy of its own ask, to
   match `r:` and to keep as evidence. Architecture.md says the core hands back
   the identifier synchronously; `hal_xprs_send` returns only 0 or an error
   today. If that is missing, the fix is in the core's verb, generic for every
   wapp, not a hash computed in the wapp.
4. A wire sent through `hal_xprs_send` that carries `file:` triggers the same
   hash advertising as the other send paths. If not, that is a core gap, fixed
   generically in the core.

Each gap found is fixed in the core as a capability every wapp can use, never
as a special case for this wapp (architecture.md §3).

## 8. Testing

Like Chat (architecture.md §6): several instances of the real wapp in one
process over a mock HAL, where one instance's `hal_xprs_send` becomes a
delivery into another's event queue, shaped as the core shapes it. Scenarios:
local check-in, regional relayed check-in, refusal out of scope, stale ask,
second check-in on the same day, event window edges, badge fetch states, and
survival of a restart.

## 9. Phases

1. Bot, Nearby, Check in, Logbook, without badges.
2. Badges: put on the station side, fetch and Badge wall on the chaser side.
3. Events: `t:event` with the tag, event badge, once-per-event or once-per-day.
4. Logbook export, map of check-ins and events, and the same command answered
   by station firmware, so a solar LoRa box on a summit can be an unattended
   check-in cache.

## 10. Defaults, open to change

- One check-in per chaser per station per day.
- The chaser's position is not sent.
- Nothing is public unless the chaser shares it: certificates are addressed to
  the chaser.
