# Reticulum & APRS-IS connection model (one connection, no duplicates)

Audit note: long-lived network transports must be owned by a single shared
layer, never opened per wapp-engine. A device runs more than one wapp engine for
the same wapp — the foreground `WappPage` engine and the headless background
service engine (and briefly both, during hand-off) — so any connection a wapp
opens directly is at risk of being opened two or three times at once.

## Reticulum (RnsService) — already a singleton, no change needed

`lib/services/reticulum/rns_service.dart` is the one place that talks RNS:

- `RnsService.instance` is a process-wide singleton — one RNS node for the whole
  app, shared by every engine.
- `start()` is idempotent: `if (_up || _starting) return _up;`. Repeated starts
  (and `rns_autostart`, which runs on every launch / network change) cannot spin
  up a second node or a second set of uplinks.
- Hub uplinks are deduped per `host:port` via the `_connectedHubs` set:
  `connectUplink()` returns early if the hub is already held, and `_dropClient()`
  clears it so a reconnect re-adds exactly one. The initial `tcpclient` connect
  registers the same key.
- Wapp engines never open RNS connections. They attach to the singleton through
  per-wapp *channels* (`wappRegister(tag)` → a per-wapp inbox), so N engines
  share one node and one set of hub connections.

Verified on-device: TCP connections to the RNS port (4242) show one connection
per *distinct* hub (the deliberate multi-hub mesh), with no hub appearing twice.

Since Chat v0.2.109, Reticulum is the Chat wapp's **primary** transport (1:1,
groups, geo-chat, Activity feed and manual beacons all ride RNS first); BLE is
the local path and APRS-IS is legacy/opt-in (licensed callsign required).

## APRS-IS — why it duplicated, and the fix

The APRS wapp did NOT go through a singleton: it opened a raw TCP socket itself
via `hal_socket_*`, so the foreground engine, the background engine, and leaked
reconnect sockets each opened their own connection to APRS-IS — all logging in
with the same callsign. APRS-IS allows one login per callsign and kicks the
duplicates, which put the link into a permanent reconnect war (observed: three
simultaneous connections to one service). Outgoing 1:1 messages frequently fell
through to BLE only because the link was rarely stably up.

Fix (`lib/wapp/wapp_engine.dart`): the socket HAL now shares ONE real TCP
connection per `(host, port)` across all engines (`_SharedSocket`, keyed in a
static map). Each `hal_socket` handle is a refcounted *view* with its own RX
buffer; inbound bytes fan out to every view; the duplicate APRS-IS login line is
suppressed (only the first `user …` is sent); the real socket closes when the
last view is released. Result: one connection, one login, no kick war.

## Rule for new transports

Any new always-on/long-lived connection (another internet relay, a second
socket protocol, etc.) must be owned by a singleton host service (like
`RnsService`) or share at the HAL layer (like the APRS-IS socket fix) — never an
unmanaged per-engine `hal_socket_open`/`Socket.connect`. Otherwise the
foreground + background engines will duplicate it.

## Reaching a peer: what is actually true, and how to check it

Three separate attempts to make a fresh install fetch Global chat across the
internet failed, and two of them failed because the transport's behaviour was
*asserted* rather than measured. The conclusions below were each paid for.

### The transport is almost never the problem — look before blaming it

The failing case: C61 on `192.168.178.0/24`, TANK2 on `192.168.107.0/24`,
mutually unreachable at IP level, TANK2 freshly installed. Global chat stayed
empty, no XPRS station appeared on its mesh screen, and neither phone listed the
other. The obvious reading — "announces do not cross a public hub, so discovery
is impossible" — was wrong, and one HTTP call said so:

```sh
adb forward tcp:3461 tcp:3456                       # the app's API, on by default
curl -s 'http://127.0.0.1:3461/api/rns/route?dest=<32hex>'
{"path":{"nextHop":"07d20e92…","via":"tcp:use.inertia.chat:4242","hops":2,"ageMs":22186}}
```

A live two-hop path through a public hub, 22 seconds old, on a device that had
been installed minutes earlier. `/api/xprs/whois?call=X3ARK` resolved the
callsign to an LXMF destination in the same second. Everything needed to send a
directed packet was present; the app just never sent one.

**`/api/rns/route`, `/api/rns/haspath` and `/api/xprs/whois` answer in one
second what a screenshot cannot answer at all.** The mesh screen showing "0
stations" is not evidence about reachability — see the next point for why.

### A display list is not a reachability list

`observedDevices()` answers *"what should the mesh screen draw"*: it hides
nodes without a re-announce span, nodes a hub relays for, and nodes whose
announcement advertised no service. That is right for a screen and wrong for
routing. The phone above listed exactly one XPRS device while holding an
addressable path to another it did not list.

Anything deciding *who can I send to* must read the observed table directly
(`announcedCallsigns()`), never the display helper. When adding a new consumer,
ask which of the two questions it is asking.

### Read every name the transport offers

`lxmfDestForCallsign` matches on `callsign` **or** `lxmfName`. The first
version of `announcedCallsigns()` read only `callsign`, so it returned nothing
for a peer the resolver could resolve — the same bug XPRS.md 36.12.2 warns
about, where address→name and name→address grow apart and the second fails
silently. If two code paths name the same peer, they must read the same fields.

### `announceName` is captured once, at `start()`

The node announces whichever callsign was active when it came up. Switching
profile afterwards leaves it announcing the old one, and a peer can only
address what it heard announced — so the station becomes unreachable under the
name every other layer uses, silently. `rns_autostart.dart` now re-announces on
`activeProfileNotifier`. Any other value read once at start and expected to
track a setting has the same shape of bug.

### The two lanes, and what follows from them

36.12.1: a shared transport reliably carries **identity announcements** and
**directed messages**, nothing else. Everything built on top has to be one of
those two. In practice that means:

- Discovery rides announcements. A station's callsign is on its announcement,
  and section 3 makes the prefix meaningful: `X1` person, `X3` station or
  unattended equipment, `X4` automated device, `X5` group. **A node looking for
  an archiver needs no configuration, no directory and no lookup — it asks the
  `X3` callsigns it has heard announced.**
- Exchange rides directed packets. `d:` on the wire, LXMF or an addressed
  single packet underneath; `performance.md` 6.2 proved plain addressed packets
  traverse a reference `rnsd` hub multi-hop between these exact two phones.

Do not reach for anything outside those two lanes. A mapping published
elsewhere is a second source of truth that can disagree with the air.

### Unknown is not empty

`XprsArchive.query()` returns `const []` when no database is open, which reads
identically to a genuinely empty archive. A first-run backfill keyed on "the
archive is empty" therefore armed a month-deep, metered ask on every device
whose store had not finished opening. Check `ready` first and treat
un-answerable as "do not act". The same trap exists wherever an accessor
answers with a default instead of an error.

### Verify on hardware, and say which parts you saw

A unit test proves the arithmetic; it cannot prove a packet crossed. The result
that settled this was the archive on the receiving phone:

```
command | X1MKDH -> X3ARK | cmd:history kind:message since:2026-07-27
message | X3ARK  ->  -    | rns | t:message f:X3ARK … m:Hello world!
```

Two devices, two networks, no configuration. Until that line exists, the
feature is not working — it is only expected to work.
