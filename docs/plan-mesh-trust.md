# Plan: alerts, posts and forums across a mesh of stations, under the administrator's trust

Status: **Phase 1 done, 2026-11-06**, decisions T1 to T5 taken as
recommended. `XprsMeshPolicy` and `xprsMeshAdmits` in the core, asked by the
receive door (`XprsIngest.mesh`), the digipeater (`XprsDigipeater.admits`)
and the history server (`XprsHistoryServer.trusted`); the six settings on
`/api/admin`, validated, with `onSettings` for the host; the server rebuilds
the snapshot on boot and on every change; the Mesh card in Administration;
the mock, the conformance suite and the spec rows. One finding from the
two-instance run shaped the rest: a server never repeats onto Reticulum and
the room catch-up asks for `kind:message` only, so between two stations an
alert or a post has no path at all until Phase 3's standing ask, and an
answer to that ask is kept by design. The reach cap therefore governs what
arrives unasked over the internet lane (a phone's broadcast, a hub's
replay), which the unit test covers and a two-server bench cannot produce.
**Phase 3 done, 2026-11-07**, with the end state the operator asked for:
stations that trust each other share the same forum categories, posts and
alerts. A forum category can be shared with the mesh (`share mesh:true`):
it is served to every trusted peer, and a peer that meets it in its
neighbour answer mirrors it on its own and names it from the room's
identity. Neighbour sync (12.9.3) runs with each trusted peer on the
mirror's ladder (`MirrorPair` without a group, `kind:info,warning,blog,
identity`). A trusted peer is not metered by the history budget, and a
replay channel busy with another asker answers `429 m:busy`, retried after a
minute. Named mode governs records from other stations; a visitor on the
station's own network is its own community. Verified on three instances on
one machine (A and B trusting each other, C trusted by nobody): B mirrored
A's mesh category in 57 s and named it, listed its topic, and kept A's alert
and post over the Reticulum lane; A counted B's reply and kept B's alert; C
got no room and A kept nothing C aired. The bench shares one LAN, so C still
heard A's alert locally, which the policy treats as its own network by
design. Following (Phase 2's fetch from afar) is the remaining piece: the
`follow` list is applied at the door, the standing ask to a followed author's
own station is not yet made.
**Mesh groups done, 2026-11-07**: twenty stations are not twenty lists. With
`peers_mode: mesh` the trusted set is the roster of one closed group (a room
of kind `mesh`). One station creates it and holds its key; it invites
stations and appoints co-administrators, who invite and remove with their
own station's signature; a station joins by mirroring the mesh from any
member and accepts its invitation with its own signature. The record
reaches every member through the members' standing asks, and each station
asks only `WebChatApi.syncFanout` (4) of them, a different few each week,
since every record is a signed original that every member keeps and serves.
Verified on three instances: A created the mesh, appointed B and invited C;
B and C joined and saw their invitations within two minutes, accepted, and
A had both on its roster a minute later; a category A shared with the mesh
was mirrored by B and C; B, as co-administrator, removed C and A learned it
from B's act in two minutes.
Decisions marked **(T1)…(T5)** are listed at the end. Read `XPRS.md` 9.11, 12, 12.9.3, 13.3,
24 and `docs/plan-forum.md` first.

## 1. The problem

A person with several stations wants them to be one mesh. Chat already is:
an undirected `t:message` is digipeated within its scope (13.1, 13.2) and the
three rooms refill from any archive in reach. Alerts, posts and forum topics
are different in two ways:

- **They are kept and read later** (18, 24, 10.10.2). A chat message that
  came through a bad gateway scrolls away; an alert or a post stays on the
  station as a noticeboard, so spam and abuse that arrive over the internet
  or a satellite stay too.
- **A relay in reach is a source of record.** A rogue station parked within
  LoRa range of a mesh can air alerts and posts that every neighbour keeps,
  relays and shows as if the area had said them.

The operator wants, per station, to decide: how far away an alert or a post
may come from and still be kept; whose words are fetched from anywhere
because the operator follows them; and which stations this one exchanges
records with at all, so a stranger's station cannot join the mesh by
proximity alone. All of it from Administration, because the right answer
differs between a hilltop relay, a town hub and a home station.

## 2. What the format already gives

Nothing here needs a new packet type or a new field. Four existing things
carry the whole design; the plan is to apply them to stations, under settings.

**Reach classes (9.11).** Every bearer is `local`, `regional` or `global`,
and a scope "binds at both ends of every hop": a station relays, serves or
keeps-as-the-room's only what it heard on a bearer the scope admits. The
author's `scope:` is signed. What is missing is the *station's own* reach
rule for a kind: "whatever the author wrote, I keep an alert only if it came
to me on a local or regional bearer". That rule is the same check the core
already makes in `XprsHistoryServer` (`xprsReachAdmits`), applied at
admission and keyed on the kind.

**The followed tier (12, `xprs_archive_policy.dart`).** "A pocket phone
archives its operator's own words and those of the callsigns they follow."
The archive policy is already three tiers (mine, followed, strangers) and
the ingest shelves a followed author's packets on every lane. A followed
author is the one exception to a reach cap: the operator consented to their
words from anywhere.

**Fetching from afar (12.10.1, 12.12).** `XprsCatchup` asks stations in
reach `cmd:history since:<mark>` on a watermark; `XprsGroupMirror`
(plan-forum.md Phase 3) does the same for one group with `only:<X5>` and
`kind:`. Asking a followed station for `only:<call> kind:blog,warning,info`
is the same ask with a callsign in `only:`, and 12.12 says a directed ask
reaches a station across the internet. The answer re-airs originals that
verify on their author's key; nothing enters on the peer's authority.

**Neighbours and trust (12.9.3, 13.3).** Two archivers MAY keep each other's
community publications alive with a standing `cmd:history kind:info,warning,
event,status,blog,message` ask; it is opt-in and the asker names the peer.
13.3: an advertisement "is never evidence of good faith". So the mesh of
record is a list of named stations, and "in reach" is never enough to be on
it. The shared-room design already works this way: a room is served only to
the peers its owner named (`WebChatApi.roomServable`).

## 3. The three settings

All three are station settings on `/api/admin` (not `page_<name>`: they
govern what the station keeps, serves and relays, so the station must know
them). Each is one small rule, so a firmware station implements the same.

### 3.1 Reach: how far away a kind may come from and still be kept

| Setting | Values | Default | Governs |
|---|---|---|---|
| `reach_alerts` | `local`, `regional`, `global` | `regional` | `t:warning`, `t:info` |
| `reach_posts` | `local`, `regional`, `global` | `regional` | `t:blog` to everybody |
| `reach_chat` | `local`, `regional`, `global` | `global` | undirected `t:message`, `t:status`, `t:reaction` |

The rule at the receive door: a packet of that kind heard on a bearer whose
class is wider than the setting is **not kept, not shown in the feed, not
relayed and not served**, exactly as 9.11 treats an out-of-scope packet. It
may still be delivered to its addressee (a directed packet is 12.7's
business) and a `sos` is never dropped (10.7). Forum topics need no setting:
a `t:blog` to an `X5` room enters only through a hosted room's share
(10.10.1), and the room's peers are already named by hand.

Exceptions, in order: the author is followed (3.2); the packet was asked
for by this station (a reply to our own `cmd:history`, `XprsIngest.askedFor`),
because the ask was ours and went to a station we named (3.3).

### 3.2 Following: whose words are fetched from anywhere

| Setting | Values | Default |
|---|---|---|
| `follow` | a list of callsigns (`X1…`) or `npub1…` keys, at most 64 | empty |

A followed author's packets of every kind are kept and shown whatever bearer
they arrived on (the followed tier), and the station **goes and gets them**:
a standing ask, on the mirror's cadence ladder (a minute after news, ten
minutes when quiet), to

1. the author's own station when it is reachable (12.12: a directed ask
   crosses the internet), and
2. the archivers the author declared (`t:mailbox hold:` and the directory
   lines the station has heard, 12.9), and, failing both,
3. the station's own trusted peers (3.3), which may hold them.

```
t:command f:<us> d:<peer> ts:<now> cmd:history only:X1ALIC kind:blog,warning,info since:<mark>
```

One pair (author, peer) per mark, 12.10.1's watermark, `206` continued
before the oldest row, `429` honoured: `XprsGroupMirror` already does all of
this for `only:<X5>` and becomes `XprsFollowSync` by letting `only:` name a
callsign and `kind:` vary. The page marks such a post or alert "followed" in
the feed so a visitor sees why something from far away is here.

A visitor's own follows stay in their browser as a filter (the page can
already fold the Blog feed); only the administrator's list makes the station
spend bandwidth, because the station pays for it **(T3)**.

### 3.3 Trusted stations: who this station exchanges records with

| Setting | Values | Default |
|---|---|---|
| `peers_mode` | `open`, `named` | `open` |
| `peers` | a list of station callsigns (`X3…`), at most 32 | empty |

`open` is today: records are exchanged with any station in reach, under the
reach caps of 3.1. `named` closes the mesh of record to the list:

- **Neighbour sync (12.9.3)** runs only with named peers: the standing ask
  `cmd:history kind:info,warning,blog since:<mark>` to each, on the mirror's
  cadence, so a mesh of three stations converges on one noticeboard. In
  `open` mode there is no neighbour sync at all: what arrives, arrives.
- **Serving**: `cmd:history` from a station not on the list is answered with
  this station's own publications only (`XprsArchive.query ownOnly`, which is
  what a stranger gets today), never with what it holds for others.
- **Keeping, in named mode**: an alert or a post heard on a regional or global bearer is
  kept only when it is this station's own, its author is followed, its
  author or a station in its `via:` is a named peer, or it answered our ask.
  That is the rule that stops the rogue relay: its packets are heard,
  delivered if addressed, and otherwise go no further **(T4)**.

Chat is not touched by `peers_mode`: the rooms stay digipeated and refilled
as today, within `reach_chat`.

The list is symmetric by convention, not by protocol: A names B and B names
A, as two room-sharing stations do. A station that names a peer which does
not name it back asks and is answered with own publications only; the page
shows "not answering as a peer" on the card after the first such answer.

## 4. What the station does with it

One pure function decides admission, where the three tiers are decided
today (`xprs_archive_policy.dart`), so it is tested without a radio:

```
xprsMeshAdmits(packet, bearerClass, {reach, followed, peersMode, peers, askedFor})
  -> keep | deliverOnly | drop
```

and three callers ask it: the receive funnel (`XprsIngest`), the digipeater
(`relayable`) and the history server (`roomVerdict` already sits there). The
settings arrive as the same immutable snapshot the archive policy takes, so
the hot path reads no preference store (performance.md 4.2).

The standing asks are the mirror generalised: `MirrorPair{only, kinds, peer}`
instead of `{group, peer}`, with the pairs listed by the host from the three
settings (neighbour pairs, follow pairs, room pairs). One ticker, one cadence
ladder, one `429` rule, one `askedFor`.

The web chat page: a card per setting in Administration; "followed" and
"from <peer>" marks on feed cards (the history rows already carry `bearer`
and `via:`); a "Follow" entry in a callsign's menu for the administrator;
and the Station view listing the peers with when each last answered.

## 5. Phases

**Phase 1, reach caps (page, core, mock, spec).** The three `reach_*`
settings, the admission function, the Administration card, the feed marks.
A warning over the internet to a station with `reach_alerts: regional`
is delivered to its addressee and otherwise vanishes; the conformance suite
checks it through the mock's `/__row` with `bearer: 'rns'`.

**Phase 2, following.** `follow` setting and card; `XprsFollowSync` from
`XprsGroupMirror`; the followed exception at the door; the "followed" mark.
Verified on two instances: A follows an author whose station is B, on
different networks, and A's Blog shows B's author's post within two minutes.

**Phase 3, trusted stations.** `peers_mode` and `peers`; neighbour sync in
named mode; serving only own publications to strangers; the keep rule for
regional bearers in named mode. Verified on three instances: A and B named,
C in reach of both and unnamed; an alert aired by C is shown at neither A nor
B, an alert posted at A appears at B.

**Phase 4, the text.** A short XPRS.md section under 12.9 (a station's own
reach for a kind; the named mesh) and the API-HTTP.md rows; a note for the
firmware with the one admission rule. Each phase ends with a two-instance or
three-instance run on one machine, as the forum plan's did.

## 6. Decisions

- **(T1) Defaults.** Alerts and posts `regional`, chat `global`, as above.
  The alternative is alerts `local` for a home station; the administrator
  can set it, and a hilltop relay would want `regional`.
- **(T2) Where a reach cap applies to a followed author's packet.** As
  proposed, following overrides the cap (the operator consented). The
  alternative is cap first, follow second, which makes following useless
  across the internet, the very case it is for.
- **(T3) Visitors' follows.** As proposed, a visitor's follow is a filter in
  their browser; only the administrator's list makes the station fetch. The
  alternative, every visitor's follow fetched by the station, is an open
  invitation to spend the station's bandwidth.
- **(T4) The keep rule in named mode.** As proposed, author-or-`via:` on the
  named list. `via:` is unsigned (9.2.2), so a rogue station can forge a
  named peer into `via:`; the rule still removes the cheap attack (airing
  under one's own name) and the forged case is bounded by the hop budget.
  The stricter alternative, author on the list or followed only, would keep
  no visitor's alert at all; a middle way, counting only a packet that a
  named peer *re-aired to us* (heard on the lane that peer is on), is
  possible on the TCP lane and not on LoRa.
- **(T5) Neighbour sync in open mode.** As proposed, none: an open station
  takes what reaches it and asks nobody. The alternative, asking every
  archiver in reach as the phone does, is what makes a rogue archiver's
  store contagious.
