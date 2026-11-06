# Plan: a Forum on the XPRS station

Status: **proposal, 2026-11-06; Phases 1 and 2 done the same day.** Phase 1:
XPRS.md 18.5 Comments, the shared-room paragraph in 10.10.1 and the section
37 rows; API-HTTP.md room `kind`, the `share`, `mirror` and `unmirror`
actions, the `topics` index and `root=` on history. Phase 2: forum rooms in
the core's `WebChatApi` (`kind`, `t:blog` taken in a forum room, a split post
held and filed as the verified whole, `root=`, the topic index in
`web_chat_forum.dart`), the Forum section in the web chat with topics, threads,
a composer that splits and signs, withdrawal and moderation, the mock and the
conformance suite. Phase 3 (two stations) done the same day, with F2 and F3
taken as recommended: `XprsGroupMirror` in the core keeps each (room, peer)
pair in step with a standing `cmd:history only:<X5>` ask on its own mark,
asks a peer for the key of a signer whose act was parked, and files what
comes back through the receive door; `XprsHistoryServer` serves a hosted room
only to whom `WebChatApi.roomServable` says it is shared with, on the air and
on the inline TCP lane alike; `share`, `mirror`, `unmirror` and `sync` are
`/api/rooms` actions with an administration page for them; the server wires
it all and ticks the mirror once a minute. Verified on two instances on one
machine: a topic posted at A listed at B, a reply made at B counted at A, a
moderator's removal signed at A honoured at B. Phase 4 (directory line,
`m:try`, the per-group ceiling, the adaptive period) is not started.
Decisions marked **(F1)…(F4)** are listed at the end; F2 and F3 were taken as
recommended. Read `XPRS.md` 10.10,
10.10.1, 12.9.3, 18 and `API-HTTP.md` first; this plan adds almost nothing to
them, which is the point.

## 1. What it is

A forum is categories, topics inside a category, replies inside a topic. The
station's administrator creates categories, moderators take posts down and
send people away, and anybody the category admits opens topics and replies.
The web chat shows it as a third section in the left column (Rooms, Feed,
**Forum**), the way Blog and Alerts are shown today.

Stations are not standalone. A category may be **shared**: another station's
owner mirrors it, deliberately, and from then on both stations hold the same
topics, the same replies and the same moderation record, each serving its own
visitors, each accepting posts, converging whenever they can reach each other.
A category that is not shared stays what a hosted room is today: on one
station, never aired.

## 2. On the wire: no new type

| Forum thing | XPRS | State |
|---|---|---|
| category | a closed group the station hosts (10.10.1): an `X5` keypair the station holds, announced by its `t:identity nick:` | implemented (`/api/rooms`, `WebChatRoomKeys`) |
| topic | `t:blog d:<X5> title:<slug> [tag:] m:` — published, kept, listed, titled; a later post with the same title from the same author replaces it (18.1); split over up to 9 parts (18.2); signed (18.4) | type implemented end to end (archive, parts, withdrawal); `blog` must join `WebChatApi.postable` for a room of kind forum |
| reply | `t:blog d:<X5> root:<topic> r:<parent> m:` — a post with no title that names the post it answers: a **comment** | one paragraph in the spec (18.5, below) |
| editing a reply | 7.8.1 `edit:` | implemented |
| author deletes | 7.8.2 `r:<id> remove:blog` | implemented (`XprsArchive._withdrawable` has `blog`) |
| moderator deletes | 10.4.1 `r:<id> remove:message` signed by a `role:mod` | implemented for rooms; keyed on the identifier, so it takes a topic or a reply down as it takes a message (to confirm in `XprsGroups` when built) |
| moderators, sending away, lifting | 10.10 grants and revocations signed by the station as the group | implemented |
| who may post, who may see | the room's `posting` and `visibility` options, off the wire | implemented |
| reactions | `t:reaction` | implemented |
| the category's chat | `t:message d:<X5>` beside the posts, same key, same roster | implemented (that is what a hosted room is today) |

**Why not `t:forum`.** The spec has one test for a new type, written out in
section 16 when `t:status` was added: neither existing type would do, because
a receiver must *file* a status differently from a message (never replaces,
not addressed) and from a post (no title, two statuses are two moments). Run
the same test on a forum topic and it fails to justify a type: a topic is
published rather than spoken, kept and listed, titled, corrected by
republishing under the title, read later by strangers, so it wants a
signature. That is section 18 word for word; the only thing a forum adds is
*where* it goes, and `d:` already says that. A reply is the same thing one
level down.

What a new type would cost is everything a type touches: the vocabulary lists
in the core (`xprs_vocab`, `wapp_delivery`, the archive's talk set and its
withdrawable set), the firmware's C mirror and its 205-example corpus, the
12.9.3 community-kinds filter, the app's routing, and this document's own
section 37 row. What it would buy is that a receiver which does not know
forums *drops* the packet (4.3). With `t:blog` that receiver shows the category
as a group with posts and threaded replies in it, which is a forum read
through a chat client, and is the right outcome.

Where the type genuinely lacks a word, the spec's rule is a key, not a type
(design rule 5): a comment is a `t:blog` that carries `r:`, and that is one
paragraph.

**Why not `t:message` replies.** Considered and rejected. 18 draws the line
between a message (addressed, read once) and a post (kept, listed, read later
by people who were not listening), and a forum reply is on the post side of
it: it should be signed, it is listed under its topic for years, and it is
corrected with `edit:` like a publication. Keeping the whole forum in one kind
also keeps the replication filter and the topic query to one `kind:blog`, and
leaves `t:message d:<X5>` free to be the category's live chat.

### 2.1 Spec text to add

- **18.5 Comments.** "A `t:blog` with no `title:` that carries `r:` is a
  comment on the post it names; `root:` names the post the thread hangs from
  (7.4). A comment is corrected with `edit:` (7.8.1) and withdrawn with
  `remove:blog` (7.8.2); it never replaces anything by title, because it has
  none."
- **10.10.1, one sentence.** "A hosted room MAY be shared: the station then
  answers `cmd:history only:<X5>` for it to the stations its administrator
  named (or to any, for a public room), and a station that mirrors one serves
  it under the same signed record, with no authority of its own in it."
- **37**, two rows: `t:blog` posts and comments; shared rooms.

## 3. Replication: a shared category

The rules already exist, and they are strict for a reason:

- **Archivers never sync stores** (12.9). What crosses is *signed originals*,
  re-aired on a `cmd:history` answer, entering the asker's store through its
  own admission (12.9.3). Nothing is imported on the peer's authority.
- **Hosting is a directory line** (10.9.1): a station that keeps a group says
  so in its XDIR1 and means *ask me about it*.
- **Opt-in, bounded, metered** (12.9.3, 10.9.3, 30.2).

A shared category is exactly 12.9.3's standing neighbour ask, narrowed from
"community kinds near me" to one group:

```
t:command f:X3MIRR d:X3OWNR ts:… cmd:history only:X5F0RM kind:blog,reaction,moderate,identity since:<watermark> sig:…
```

`only:` already matches sender or addressee (11.2, `XprsArchive.query`), so
the answer is the group's whole record: its `t:identity` (the key), the
grants and acceptances, the removals and revocations, the topics, the
comments, the reactions. Every packet verifies on its author's key; the
group's own acts verify on the `X5` key, which only the owner station holds.
Both sides replay the moderation record under 10.4 (authority judged at the
act's moment, newest per signer wins) and arrive at the same verdicts, so
both serve the same thing without ever comparing stores. Copies deduplicate on
the section 5 identifier; a withdrawal purges and leaves a tombstone on both.

**Both directions, every pair.** The mirror asks the owner, and the owner asks
the mirror, each on its own per-peer watermark (12.10.1, `XprsCatchup` is the
asking half, `XprsHistoryServer` the answering half, both in the core). A
visitor who posts at the mirror signs as themselves, the mirror files the
packet (`keep`, never aired, as today), and the owner's next ask pulls it. Two
mirrors converge through the owner, or directly if their administrators list
each other: there is no coordinator, only pairs, and the union is the same
whatever the graph. The owner being offline stops nothing at a mirror; what
needs the owner is a *grant*, because only the `X5` key signs one.

**Moderators across stations.** A person the owner's administrator appoints
(`role:mod`, accepted) moderates from whichever station they proved their key
at: their act is signed by them and travels like any packet. The owner may
also grant `role:mod` to the mirror *station's* `X3` callsign **(F3)**; the
mirror then signs its own administrator's removals as itself
(`signAsStation`), they verify against the key the grant names, and the
mirror's owner moderates the shared category in place, which is what "mods can
manage the posts" means with two stations. A mirror never appoints: it does
not hold the key. It may always stop serving: 10.10 says other stations' rooms
are theirs to run, and a mirror's local hide is a serving decision, not an
act on the wire.

**Opt-in on both sides, explicitly.** The owner sets a category `shared` and,
for a private one, names the peers allowed to ask for it. The mirror's
administrator adds the category by its `X5` callsign and the owner's `X3`
(`mirror X5F0RM from X3OWNR`): the station fetches the group's `t:identity`
first (the key, else nothing verifies), then the record, then the posts. A
public shared category answers any station's ask **(F2)**; a private one only
its listed peers, and the mirror serves it to members only, as the owner does,
from the roster it replicated. Private still means "served to members, not
secret" (10.10.1), now at two operators, and the page must say so when the
switch is turned.

**Transport.** A directed ask travels on whatever lane reaches the peer: the
Reticulum path through the hubs that the server already keeps, the LAN, or a
radio bearer when the two stations are in earshot. The period is 12.10.2's
adaptive ladder with a floor of one minute (a station on mains is bounded by
cost, not battery; `performance.md` §8 forbids a sub-minute poll). A `429`
backs off; a `404 m:try` names another holder (12.9). Per-group byte ceiling
and oldest-first eviction are 10.9.3 as written.

## 4. Where each piece lives (architecture.md §2a: the core decides, hosts wire)

**Core, `WebChatApi` (the visitor API the server and the app share).**
A hosted room gains two off-the-wire options beside `visibility` and
`posting`: `kind: chat | forum` and `shared` (with `peers`). For a forum
room, `blog` joins `postable` (a `t:blog` to the undirected shelf stays
refused: a visitor is not the station). `/api/xprs/history` learns
`root=<id>` (a thread). `/api/rooms` returns, for a forum room, the topic
index: newest 100 topics with `id`, `title`, `from`, `ts`, `replies`, `last`,
computed from the room's rows **(F4)**. Rooms, roles, removal and the roster
are unchanged.

**Core, new `XprsGroupMirror`** (`lib/src/services/xprs/`). One per
(peer, `X5`): the watermark, the ask, the lane choice through the existing
`RnsService.react` seam, and the answer fed through the one receive door
(`PacketGateway.receive`) so admission is the station's own. The exception it
adds to 10.10.1's "a packet for the group heard from elsewhere is somebody
else's traffic": a verified packet for an `X5` this station **mirrors** is the
room's. A mirrored group is a hosted room whose private key the station does
not hold (`XprsGroupKeys` today assumes it does): it files and serves, it
never signs as the group. `XprsHistoryServer` answers `only:<X5>` for a shared
room to the peers the room lists.

**Server** (`station.dart`): wiring only. Constructs the mirror service with
the archive, the groups and the publisher, exactly as it constructs
`WebChatApi`. The share and mirror acts are `/api/rooms` actions, persisted in
the station's store like the rooms, so the config file gains nothing.

**Web chat page.** A "Forum" head in the left column with one entry per forum
room; a mirrored one shows the owner's callsign. A category view lists topics
(title, author, replies, last activity); a topic view shows the opening post
and its comments in order; the message menu moderators already have (remove,
send away) applies to both. Composer: a new-topic form (slug from the first
words, editable; text up to about 1600 characters, split into parts by the
page and signed on the last part per 9.1.1, a `splitParts()` the chat
composer can reuse for long messages) and a reply box. `blogPosts()` (today's
Blog feed) folds parts and editions for topics and comments alike; it was
written for this.

**Firmware and app.** Nothing required. The app shows a shared category as an
`X5` group once it has the key; `t:blog` rendering in the app is a separate
item (section 37 says not implemented).

## 5. Phases

1. **Text.** 18.5, the 10.10.1 sentence, `API-HTTP.md` (room `kind`,
   `shared`, `peers`, `root=`, the topic index). Half a day; the rest builds
   on agreed words.
2. **One station.** Core: forum rooms, `blog` postable in them, `root=`, the
   topic index, tests beside `test/web_chat_api_test.dart`. Page: the Forum
   section, topic list, thread, composer with parts. Result: a working forum
   on one server. The mock station and `test/smoke.py` learn a forum room.
3. **Two stations.** `XprsGroupMirror`, `XprsHistoryServer` answering
   `only:<X5>`, the share and mirror actions, the server wiring. Test on two
   Pis: a topic at A appears at B, a reply at B appears at A, a moderator's
   removal at B is honoured at A, A offline for an hour loses nothing.
4. **Federation polish.** The directory line, `404 m:try`, the per-group
   ceiling, the adaptive period, the page's "mirrored from" and "shared with"
   notes and the warning when a private room is shared.

## 6. Risks

- A hosted room's promise today is "nothing leaves the station". Sharing is a
  per-room switch that changes that promise, so it is off by default, shown
  on the room, and a private room warns before it is shared.
- The topic index is a query over the room's rows on every `/api/rooms`; fine
  at 100 topics, a table if a category grows past what one page shows.
- `only:` answers the group's whole record including `t:identity`; a mirror
  must verify the group's key against the owner it was told, or any station
  could offer an `X5` wearing the same six characters (10.1).

## 7. Decisions

- **F1** Replies as `t:blog` comments (recommended), as `t:message root:`,
  or a new `t:forum` type (argued against in §2).
- **F2** A public shared category answers any station's ask (recommended: it
  is public, and 10.9.2 lets any member deposit) or only listed peers.
- **F3** The owner may grant `role:mod` to a mirror station's `X3`
  (recommended: the mirror's administrator moderates in place) or only to
  people.
- **F4** Topic index computed per request, bounded to 100 (recommended for
  now) or kept as a table in the archive.
