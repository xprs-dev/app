# Archivers

**Archivers are the pillars of XPRS.** They keep communication store-and-forward
in a truly decentralized way: a message reaches somebody who was away, a post is
read by somebody who was not listening, a group is found by somebody who never
heard it announced, and a file is fetched after its author switched off. Each of
those is kept by an archiver and by nothing else. No archiver is required, any
station can be one, each is chosen by the stations that use it, and everything
it holds is signed by somebody else. The network survives losing any of them
and trusts none of them.

`spec/XPRS.md` section 12 is normative. This file is the map: what the role is,
the rules every implementation must keep, where each part lives in the code, and
what is still missing. (Older code comments cite "36.x"; that is section 12
before the spec was renumbered, and 36.N is 12.N.)

## The rule that comes before every feature

> **Anything a person looks for that this device did not hear itself is asked
> of the archivers.**

Search, a stranger's posts, a group's history, where to reach a callsign, who
holds a file: each of these goes to the archivers the station chose plus the
always-on archivers it knows. The answer follows `code:404 m:try` redirects and
the XDIR directory, and what comes back is kept. The heard table (stations in
earshot in the last hour) is the *neighbourhood*. It is never the answer to a
question about the network. Building a finder on what one device heard is the
mistake this file exists to prevent (spec 12, 12.9.6).

## What an archiver is (spec 12)

- **One role, every device (12, 12.0).** A pocket phone keeps its operator's own
  words and those of the callsigns they follow, and announces nothing. A powered
  station keeps everything it hears and announces `serve:archive`. An always-on
  internet machine does the same with bigger budgets. `serve:archive` is the only
  word for it, and the role behaves identically on every bearer.
- **Three settings, named for people:** **mine** (always kept), **people I
  follow** (kept while followed), and **public archiver** (strangers' packets,
  under a byte cap and a maximum age). Only the third announces `serve:archive`.
  **Always on** is a further promise that can only be made on top of the third.
- **Chosen on both ends (12.3).** The publisher picks where it pushes, the reader
  picks whom it asks, and the two lists need not overlap. Zero archivers is a
  valid and private setup. A station with none SHOULD adopt one it can reach and
  keep it (12.8.3, step zero).
- **It holds the signed packet exactly as written (12.1, 12.2).** There is no
  envelope and no summary. An archiver can refuse, lose or decline; it cannot
  alter, retarget or resurrect. A reader verifies against the author's key, never
  the archiver's.

| What it does | Spec |
|---|---|
| Keeps a spool and answers `cmd:history` (by author, type, region, time, `only:`) | 12.5, 12.6, 11.2 |
| Keeps the publications of the stations that chose it | 12.3, 12.4, 12.12.2 |
| Holds mail for absent stations and delivers it when they are heard or reachable | 12.7, 12.8–12.8.3 |
| Forwards held mail toward gateways that recently saw the recipient | 12.8.1, 12.12 |
| Publishes a directory of who keeps what (XDIR1) and redirects a miss | 12.9 |
| Gossips reachability with other archivers (declared / visit history / live) | 12.9.4, 12.9.5 |
| Lets people, stations and groups be found by name | 12.9.6 |
| Seeds files and indexes who holds them | 12.9.2, 12.11.1 |
| Evicts by class (spool, then custody mail, then declared mail), then by age | 12.11, 10.9.3 |

**Publication or mail: `d:` decides.** Without `d:`, a packet is a publication
and is served to anybody. With `d:`, it is mail: held for that one station and
never offered to a third party. `ping`/`pong` are neither. A sealed body (`x:`)
protects the content. The envelope (`f:`, `d:`, `ts:`) stays readable, so
**choosing your archiver is what protects the pattern** of who writes to whom.

## Between archivers (spec 12.9)

**Never on another archiver's authority, but a replay you asked for is not an
import.** An archiver does not take a peer's store because the peer kept it.
It does ask peers `cmd:history` all the time, for the meeting after an absence,
neighbours' community posts, observations, mailbox declarations and identities.
That is allowed because all three of these hold:

- the asker chose the question;
- every record is an original that verifies on its author's key;
- every record passes the asker's own admission, as if it had been heard on the
  air.

What crosses between archivers:

| What | The question it answers |
|---|---|
| `t:service serve:archive count: file:<ref>.xdir [dial:] [room:]` | who offers what, how deep, how to dial it, whether it takes newcomers |
| the XDIR1 file (`call ts` per line) | which callsigns this archiver keeps, and when each was last heard |
| `t:observation hears:` | who is at a gateway's ear now |
| `t:mailbox hold:` | who chose whom to hold their mail |
| `t:identity` (bulk, `kind:identity`) | who is called what: people, stations, groups |

**Gossip** is reachability only. It has three layers, consulted in order:

- **L1, declared:** the station's own `hold:` list.
- **L2, visit history:** the last 100 archivers that heard the station on the
  radio. Only radio evidence is admitted, and it never expires.
- **L3, live sightings:** at most 8 per station, kept for 24 hours.

**Bulk gossip is the history replay; there is no gossip packet.** Small stations
keep only what they need to know and ask an always-on archiver on a miss.

**Always-on archivers** are what the network leans on across the internet:
addressable, deep, budgeted, **concurrent**, complete and awake (12.9.4). On the
internet, public traffic is pushed to them and pulled from them; broadcasts do
not cross shared transports (12.12.2). The radio carries one replay at a time,
but an always-on archiver answers many askers at once on directed lanes.

## How a station asks (spec 12.10–12.10.2)

- Each archiver gets its **own watermark**, which advances on `200` or `404`. A
  `206` asks for the continuation at once, and `429` and silence do not advance
  it.
- Each archiver gets its **own interval**:
  - halve it when the archiver had something new;
  - double it when it had nothing, or answered `429`;
  - leave it alone on silence.
  - The ceiling grows the longer the archiver stays quiet. The floor is 10
    minutes for an ordinary archiver and 15 seconds for an always-on one.
- **`429` is the archiver's authority** over the caller's pace. **One
  unanswered ask per archiver**, and jitter every interval.
- **The poll** covers the archivers heard nearby *plus* the ones chosen and the
  always-on ones, never with `scope:local` toward the internet. Each ask is
  bounded to 7 days.
- **Deliberate fetches** reach further, each run once per archiver with its own
  mark:
  - the first-run backfill: 30 days or 1000 messages;
  - the names fetch: a year of identities;
  - a person opening one callsign's or one group's history.

## The implementation

### Flutter / Dart core (`core/lib/src/services/xprs/`)

| File | Role |
|---|---|
| `xprs_archive.dart` | the zx store. Tables: `packets` (verbatim wire, keyed by the section 5 identifier; indexes on `pts`, `(fromc,pts)`, `(toc,pts)`), `mailbox_decl`, `names` (call, newest nick, ts, search key). `admit()` writes to RAM; a 20 s flush verifies and prunes. At most 4 identity rows per station. 500 MB / 365 days by default. |
| `xprs_ingest.dart` | the single admission point: policy, `scope:`, the mailbox-declaration rule for mail off the internet |
| `xprs_archive_policy.dart` | what is kept for whom: mine, followed, strangers |
| `xprs_history_server.dart` | answers `cmd:history`: `202`, originals newest first, `200`/`206`, `404 m:try`, `429` (`m:busy` when the radio slot is taken). Radio pages of 12, one every 1.5 s. Directed concurrent replays for an always-on archiver. `serveInline` serves the socket lane, 50 a page. Prepends observers' identities to sighting pages. Holds back only an unshared hosted room. |
| `xprs_catchup.dart` | the asking side: per-archiver marks and intervals, the backfill, followed stations and groups, the names pull (`kind:identity`), `askNames()` |
| `xprs_fetch.dart` | deliberate reads of one callsign: `only:` to the archiver that answered last, then the chosen ones; follows `404 m:try` and `206` |
| `xprs_names.dart` | `XprsNames.find`: Search's people / stations / groups from the names table, and pokes the pull (at most once a minute) |
| `xprs_directory.dart` | composes XDIR1 from what this station keeps, announces it, and consumes peers' directories into bounded pointers |
| `xprs_gossip.dart` | L2/L3 tables, caps, per-signer quotas, the miss-path ask |
| `xprs_mailbox.dart`, `xprs_forwarder.dart` | holding mail, release on hearing or on a verified receipt, forwarding toward fresh sightings |
| `xprs_publisher.dart` (`depositArchivers`) | pushes every own publication to each chosen archiver as a directed copy: socket first, else LXMF, else a bounded queue |
| `xprs_archiver_choice.dart` | which archivers this station uses (named, adopted, always-on) |
| `xprs_line_io.dart` | the `dial:` socket lane (13.0.2): at most two sockets; the archiver delivers on it unasked |
| `xprs_observation.dart` | deposits this station's `hears:` observations and identity with its archivers (12.1, 12.8.1) |

### ESP32 station (`firmware/common/xprs_index/`)

Same role, no database. The app fills most of a 1.9 MB partition and the board
has no PSRAM, so the store is plain files.

- **Segments:** 320-byte records holding the packet verbatim, in `seg_*.bin` of
  4096 records, with an epoch letter so a client notices a wiped card.
- **Two derived, rebuildable indexes:**
  - `t/<code>.idx`: record numbers per type, for "the most recent N warnings";
  - `zone.idx`: per segment, the first index, the ts range and a type mask, for
    "what was sent last year".
  - Measured: 20 recent warnings in 28 ms, 50 records from a year-long range in
    123 ms.
- **The mail rule is enforced in the store, not by callers.** A query takes an
  `asker`, and a `d:` record goes only to its addressee. On GATT the asker
  declares itself, so this keeps a stranger's mail from a passer-by but does not
  prove who is asking.
- **Hard-won rules** (`docs/esp32.md`):
  - decide on the caller's thread and write from a task pinned to core 1;
  - drain in bursts;
  - one mutex around FatFs;
  - read the active segment through its writing handle, after an `fsync`.
- **Serves** `GET /api/xprs`, `GET /api/xprs/dir`, an `xprs_query` over GATT,
  and `cmd:history` on the radio.
- **Lacks:**
  - a `file:` on its announcement, because it cannot answer `cmd:file` on the
    radio, so the ask form carries the load;
  - a names table;
  - a forwarder that picks every live gateway (it picks one).

### Files over Reticulum (`reticulum-dart`, `lib/src/services/files/`)

Files are indexed by **pointer**, not content. A file is megabytes, and a signed
`ProviderRecord` (sha256, holder key, capacity class, TTL, signature) is about
176 B. The rule is "send whichever is smaller", which for a ≤250 B XPRS packet is
the packet itself.

- **A Kademlia DHT over Reticulum** (`dht/dht_core.dart`): 128-bit keys, XOR
  distance, replies capped to one link packet.
- **Records age out** unless the holder republishes them, so a holder that
  vanished heals out of the map by itself.
- **Leaves announce once; archivers spread the records among themselves** with a
  pointer log (`dht/pointer_log.dart`, `pointer_sync.dart`):
  - removals travel alongside insertions;
  - a peer resumes at a position `(epoch, seq)`, not a time;
  - a peer answers RESET rather than return a partial answer;
  - every record is verified on merge.
- **A lying record costs one round trip.** The downloaded bytes are hashed and
  must match.

## Known gaps

1. **XDIR is not used by Search** or by the deliberate reads. It is consumed
   only to build `m:try`. A found callsign's posts should be asked of the
   keepers the directory names (12.9.6).
2. **Replayed identities land in the heard table**, so a group found through an
   archiver shows "On Reticulum, seen … ago" rather than "Found by name".
3. **`only:` does not search inside `hold:`, `via:` or `grant:`** yet (12.6).
4. **A station is not pointed at a peer with room** when this one says
   `room:no` (12.9.5).
5. **12.3's per-archiver position in a publication log is not kept.** A lost
   deposit is recovered by the archiver's catch-up and the readers' pull, which
   both deduplicate.
6. **The asking side sends more than one ask at a time to the same archiver**
   from different modules (gossip, key lookups, catch-up). 12.10.2 says one. The
   responder tolerates two different questions per asker, but the client should
   coordinate.

## Being an archiver

- **It is a decision, not a duty.** Disk, bandwidth and whom to carry for are
  the operator's. Refusing is always allowed, out loud (`429`, with `m:try`
  when it can name a peer).
- **You learn metadata.** Sealed contents stay sealed. Who talks to whom, and
  how often, does not. Say so plainly to anyone choosing you.
- **It is cheap at the edges.** A dongle with a microSD is a good archiver for a
  village. Always-on archivers are for machines with a real link and a real
  disk, and they are what makes the internet half of the network work.

## See also

- `spec/XPRS.md` §12 (normative), §9.12 (`hold:`), §11.2 (`cmd:history`),
  §13.0 (`count:`, `dial:`, `room:`), §10.9 (groups at archivers), §30
  (airtime and budgets), §37 (what is implemented)
- `docs/store-and-forward.md`: delivery to absent peers
- `docs/folders.md`, `docs/NOSTR.md`: the file and relay layers on the pointer
  index
- `docs/esp32.md`: the firmware constraints
- `docs/agent-memory/gossip-and-always-on-archivers.md`: the vocabulary
  (gossip, always-on; "super" is retired)
