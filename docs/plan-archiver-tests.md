# Plan: testing archivers, and one file system

Status: **plan, 2026-11-21.** Nothing here is built yet except the spec fixes
of section 6. `spec/XPRS.md` section 12 is normative; `docs/archiver.md` is the
map of the code. This file says how archiver implementations (ESP32 firmware,
server edition, desktop and phone app) are validated against the spec and
against each other, and what the file system has to become for its tests to
have a definition of "correct".

## 1. Why

- The in-process simulators are good (`test/support/mail_relay_sim.dart`,
  `xprs_sim.dart`): the real core, several stations, one process, in CI.
- One suite runs unchanged against every engine: `portal/contract/
  conformance.py` (server, board, board under QEMU, mock). It covers the
  station web API only, one station per run.
- One script drives three implementations together:
  `portal/test/interop_groups.py`. Groups only.
- **Nothing makes two archivers of different implementations exchange
  anything**: no history replay, catch-up, gossip, directory, mail hand-off or
  file. The server exposes no archiver counters. There are no shared vectors
  for archiver behaviour, and the firmware's packet corpus has drifted (349
  packets, the spec has 360).
- File sharing does not work as a whole (section 3), and no test says so.

## 2. Decisions taken (2026-11-21)

1. **One file system.** One door for every fetch, which adapts to the link
   (section 3). Blossom's model for identity (a file is its SHA-256) and
   BitTorrent's for pieces, fitted to XPRS: no central server, holders found
   through the archivers.
2. **Every firmware is a file server.** Storage decides how much a board
   holds, never whether it serves. A board with flash only serves what fits
   its flash.
3. **Piece lists are binary; packets and human listings stay text**
   (in the spec since 2026-11-21, section 4).
4. **Spec contradictions are resolved in the spec** (done, section 6).
5. **The suite lives in `portal/contract/`**, beside the conformance suite
   every engine already runs. (`webchat/` is a second clone of the same
   repository; use `portal/`.)

## 3. The file system the tests will hold us to

Today four systems barely connect: `cmd:file` with the bulk lane, the piece
engine used by folders, BitTorrent, and HTTP by reference. What is broken,
from the code (each becomes a failing test first, section 7 step 1):

| # | Fault | Where |
|---|---|---|
| F1 | The piece engine is never used for `cmd:file` or chat media: the internet lane passes no size, so every fetch is whole-file, the path `docs/torrents.md` 16.4 records as stalling | `mesh_service.dart` `internetFetch`, `rns_service.dart` `fetchContentAddressed` |
| F2 | A large file moves only over a Bluetooth session. A LAN-only peer, a desktop or a server answers `202` and then nothing arrives until a 90-minute timeout | `xprs_files.dart`, `packet_gateway.dart` |
| F3 | Nobody looks up who holds a file: no code sends `q:have`, the holder index is never filled (no `callsign` source is ever written), and a `404 m:try` is logged and not followed | `xprs_files.dart` `onResult`, `mesh_service.dart` `holderIndex` |
| F4 | Two requesters of one file overwrite each other in the spool and in the in-flight table | `mesh_bulk_spool.dart`, `xprs_files.dart` |
| F5 | A finished bulk transfer may never be claimed when the requester's callsign differs from the bare `f:` used as the target (to confirm) | `mesh_bulk_spool.dart` `completeInbound` |
| F6 | Media of unknown size over 32 kB is asked on the packet lane, refused `403`, and nothing falls back | `media_fetch.dart` `decide` |
| F7 | The BitTorrent tier is unreachable from the normal fetch (no `ih` is passed) | `shared_media_fetch.dart` |
| F8 | The firmware has no `cmd:file` responder, no `q:have`, no `serve:files`; it only fetches firmware images | `firmware/common/xprs_fwfetch` |
| F9 | Failures are silent: about a dozen places return null without a log line | `xprs_files.dart`, `mesh_service.dart` |

**The one system.** A fetch is given a reference (hash, and size when known)
and runs three steps, the same on every implementation:

1. **Find holders.** The station that named the file, then `q:have` to the
   chosen archivers, following `404 m:try` (spec 8.1, 12.9.2), then provider
   records. Every answer is kept as a holder of that hash.
2. **Choose lanes by what each link can carry**, several at once:

   | Link | What moves | When |
   |---|---|---|
   | LoRa, Bluetooth adverts | whole small files as text packets (7.7.4, 7.7.6), at most 32 kB | only when a person asks; within the airtime budget |
   | Bluetooth session | binary chunks (the bulk lane), one holder | automatically within the operator's ceiling |
   | LAN, internet (Reticulum) | pieces in parallel from every holder found, rarest first, each verified on arrival | automatically |

   Speed is measured per holder and per lane; a stalled one is dropped and
   its pieces are asked elsewhere. A file that fits one piece needs no piece
   list on any lane.
3. **Verify and become a holder.** Each piece against the piece list, the
   whole against `file:`. A station that verified pieces may serve them
   (7.7.2), and says so to its archivers.

**Progress without traffic.** Progress is what this station has verified
(bytes or pieces of the total, holders in use, the lane), read from local
state. Showing it sends nothing. One `fetch` object per hash, however many
screens or requesters wait on it.

**Firmware.** The same verbs at a smaller scale: answer `q:have` and
`cmd:file` for what the file store holds, serve a byte range (a piece) over a
Reticulum link and over HTTP, report held hashes upward on the publication
push (12.9.2).

## 4. Piece lists: binary (spec 7.7.2)

- **The piece list** is the SHA-256 of each piece, 32 bytes each, in piece
  order, nothing else. It stays a content-addressed file named by `ph:`,
  extension `xpl`. The code already works this way
  (`core/lib/src/services/folders/piece_hashes.dart`), under the extension
  `pieces`, which has to follow the spec.
- **No field for the piece size** (no new wire word): it follows from the
  file's size (65 536 bytes; 262 144 from 4 MiB; 1 048 576 from 64 MiB), and
  the list's length confirms it. `pieceSizeForFile` is already that rule.
- **Why this does not touch radio transparency.** Packets stay text. File
  contents never were: a photograph on the radio is binary in `b:` as base64,
  and so would a piece list be. And a piece list never travels the narrow
  links at all: the packet lane tops out at 32 kB, below the smallest piece
  (64 kB).
- **Why binary.** 32 bytes a piece against about 49 as text; piece *k* is at
  offset 32·k, so a board verifies a piece by reading 32 bytes from flash
  with no parsing; it is BitTorrent's shape.
- **Stay text:** folder listings (XFL1), the archiver directory (XDIR1), the
  groups index (XGRP1). Names, small, read by people, already parsed by the
  firmware.

## 5. The test system: four layers

**Layer 1. Shared vectors.** The spec-derived corpus (`tool/xprs_corpus.py`)
grows behaviour vectors that Dart and C both consume: XDIR1 and XGRP1 files
with their hashes, sketch inputs and expected registers, piece lists, `file:`
references, torrent piece lengths and infohashes, and history exchanges (an
archive, an ask, the expected codes and record order). CI fails on drift in
every repository that holds a copy.

**Layer 2. Archiver conformance, one station at a time.**
`portal/contract/archiver.py`: a test station with its own keys that speaks
real XPRS to the station under test.

- **In:** LAN UDP 4242 (every implementation answers it) and the TCP text
  line where offered. Packets go through the real receive path. A test-only
  inject API is not used: on the firmware `/api/xprs/send` airs a packet and
  does not answer it.
- **Out:** the replies on the wire, plus each implementation's read
  endpoints.
- **Capabilities.** Each implementation declares what it serves
  (`/api/services`). A feature it does not claim is reported "declared
  absent", never passed and never hidden. The table of section 37 of the
  spec is then generated from these runs instead of written by hand.

**Layer 3. Federation.** `portal/test/interop_archivers.py`: a constellation
on one machine, joined by a private Reticulum hub so no public hub is part of
the test: the server edition, a headless desktop app, the board under QEMU,
and a real board when one is attached.

**Layer 4. Bench.** A short scripted checklist for what emulation cannot do:
the Bluetooth bulk lane between two phones, LoRa, a phone on mobile data.
The `interop_groups.py` pattern.

## 6. What is tested

| Group | Checked | Spec |
|---|---|---|
| A. Admission | verbatim storage; forged packets refused; mail never served to a third party; publications off the internet admitted, mail only under a declaration; tiers; store-full order; the out-loud `429` | 12.1, 12.2, 12.11, 12.12.2 |
| B. History | `since`/`until`/`kind`/`only`; `only:` is a callsign, never a type; newest first; `202`, records, `200`/`206`; a continuation strictly older; `404 m:try`; budgets (6 / 2 / 12 an hour) and `429`; the same answer on every bearer; a held ask answered late | 11.2, 11.4, 12.0, 12.6, 30.2 |
| C. Mailbox | signed `hold:`, windows, cancel; `q:mail` with `mail:0`; delivery on hearing; release on a verified receipt, kept across a restart; backlog pages; a held ask handed over once | 9.12, 12.7, 12.8 |
| D. Between archivers | `t:service` fields; XDIR1 format, position of the XGRP1 line, fetch; the four discovery ways, the Reticulum-announce one included; gossip L1/L2/L3 and its walls; per-archiver marks and intervals; one ask in flight; a replay is admitted as if heard, never imported | 12.9 to 12.10 |
| E. Finding | names by `kind:identity`; groups index file, sketch merge, ranking | 12.9.6, 12.9.7 |
| F. Files | references; inline and packet-lane files with `have:`; `cmd:file` codes and the audience gate; `q:have` directed and broadcast, holder redirect; listings and piece lists; pieces from several holders with one lying; resume; two requesters; lane choice by link; progress; file store full; torrent infohash | 7.7, 8.1, 11.2, 12.9.2, 12.11.1 |

Federation scenarios combine them. Three that must pass:

1. A user posts through archiver 1. A reader that knows only archiver 3
   finds the user, the post and its attached file.
2. Mail is deposited with one archiver and delivered by another that hears
   the recipient; one receipt releases both.
3. Two archivers hold a file. One goes away mid-transfer and the fetch
   completes from the other, on a different lane.

## 7. Spec fixes already made (2026-11-21, `spec/XPRS.md`)

- **11.4**: an action is never carried; an ask (`cmd:history`, `cmd:file`)
  may be held and answered late. Was in conflict with 12.1 and 12.8.2.
- **13.4**: off the internet, publications are admitted and only mail needs
  a declaration. Was in conflict with 12.12.2.
- **8.1 and 12.9.2**: a broadcast `q:have` miss is silent; a directed one is
  answered `404`, with `m:try` when holders are known.
- **12.8.3**: its exclusions are about mail; a pushed observation or identity
  is a publication. "Addressed copy" means the transport, not `d:`.
- **12.10.1**: `scope:local` only toward an archiver heard nearby.
- **30.2**: the reference budget is stated (6 known, 2 stranger, 12 in all,
  per hour), and `m:try` is a comma list (readers stay lenient).
- **11.2.1**: the continuation-must-progress rule, which was only in the
  cheat sheet. **11.2**: how a holder learns the requester's hash check.
- **7.7.5**: the torrent piece length is the smallest power of two at least
  size/1024, between 16 384 and 4 194 304 bytes. **7.7.6**: exact byte
  counts, reference cap 32 768. **12.9**: where the XGRP1 line goes.
- 41 stale cross-references (two old numberings) and five rows of section 37
  that contradicted other rows.
- The corpus is regenerated (360 packets; the tool now expands `<U+2029>`).

Still open in the spec: the packet-lane re-send grid when the re-sender's
header differs from the original's (7.7.6), and a full audit of section 37.

## 8. Small product changes the tests need

- **Server:** expose archiver status and counters (`/api/xprs/archiver`,
  files, gossip), as the app does.
- **App:** `/api/xprs/send` accepts a raw signed wire, as the server and the
  board do (`spec/API-HTTP.md` already asks for it).
- **Firmware:** forward UDP 4242 in `tools/qemu_c3.sh`; resync the corpus;
  run in CI the host tests it skips (`common/*/test/`, the ones that only
  mention Dart in a comment).
- **Core:** rename `test/xprs_file_federation_sim.dart` so CI runs it; say
  which lane a file arrived on in status, not only in the log; log every
  silent failure of F9.

## 9. Step 1 results (2026-11-21)

`test/xprs_file_faults_test.dart` holds one test per fault, asserting what
the file system must do. A fault still standing is skipped with its number;
running that file with the `--run-skipped` flag shows them failing. Every
test failed for its stated reason before anything was fixed.

| Fault | Confirmed | Now |
|---|---|---|
| F3: `404 m:try` is not followed | yes | open: part of the fetch door |
| F10 (new): a second fetch of one file re-uses the first waiter and asks no new holder | yes | open: part of the fetch door |
| F4: two requesters of one file | yes, and worse than read: NEITHER got its closing `200` | **fixed**: the spool owes one entry to several targets, the in-flight table is per file and asker |
| F5: the requester's callsign with a device suffix | yes | **fixed**: compared without the suffix |
| F6: unknown size goes to the packet lane, no fallback | yes | open: part of the fetch door |
| F11 (new): chunks re-sent on another grid (an addressed re-send has a longer header) are counted twice; the file looks whole early, fails its hash and is discarded | yes | **fixed**: held bytes are counted per byte |
| F1, F2, F7, F8 | by reading the code only: the machinery is missing, there is no behaviour to drive | open: tested with the fetch door and the firmware responder |

### Step 2, first increments (2026-11-21)

- **Holders (F3, F10 closed).** `XprsFileFetch` is one fetch per file with a
  set of holders (at most six). Asking again for a file being fetched joins
  it and asks the new holder too; a `404`/`429` with `m:try` is followed one
  hop; the fetch ends null only when every holder asked has refused. The
  `m:try` reader is shared (`xprsTryCallsigns`, `xprs_vocab.dart`).
- **Lane for an unknown size (F6 closed).** A tap over a link takes the bulk
  and internet lanes and sends the packet-lane ask beside them; untapped, the
  bounded packet-lane guess stands.
- **F1, part.** A caller that knows the exact length passes it (`exactSize`;
  the updater does, from the release feed) and it reaches
  `fetchContentAddressed`, which is what selects the piece path.

**What F1 still needs**, in this order:

1. **The exact length for any file.** A message's `size:` is rounded
   (`240kB`). The holder's answer to `q:have` already carries `size:`; it has
   to be the exact byte count there, and the fetch has to ask it.
2. **A piece list for every hosted file of more than one piece**, named in
   the holder's provider record (`manifestHash`). Today only folder
   publishing attaches one, so by-hash fetches of chat media find no list
   and fall back to whole-file from one holder.
3. **`ph:` written on `t:file`** (spec 7.7.1), so a reader has the list's
   hash from the description and needs no provider record to find it.
4. **Holders remembered.** A station that served or announced a file is
   written as a source of it, so the holder index (`q:have` misses, `m:try`)
   has something to say. Nothing writes one today.
5. **Progress** as one reading per file across lanes.

## 10. Order of work

1. **Files, as failing tests.** F1 to F9 in the simulators plus one
   two-station run, so each is confirmed or cleared before anything is fixed.
2. **The one fetch door** (section 3) in core, then the firmware responder.
3. **Vectors and the conformance driver**, groups A to C: server, app, QEMU.
4. **The constellation**, groups D to F.
5. **CI:** layers 1 and 2 on every push in core, firmware and portal; layer
   3 nightly or by hand (QEMU faults on about half its runs today,
   `firmware/docs/esp32.md`).
6. **The bench checklist.**
