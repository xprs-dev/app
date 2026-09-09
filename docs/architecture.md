# XPRS architecture

This is the governing document. Where another document, a comment or a habit
disagrees with it, this document takes precedence.

It exists because two mistakes recur:

1. **Transport logic placed in a wapp.** Store-and-forward was first built
   inside `wapps/chat/main.c` as `bh_arm`, `bh_pump` and `best_hope_wire`. It
   functioned, but every other wapp had no offline delivery, and the wapp
   required HAL endpoints added solely so that it could estimate reachability.
2. **Work placed on the UI isolate.** Reticulum crypto and transport formerly
   ran on the main isolate and the application froze under load. They were moved
   out (see [performance.md](performance.md)); calling a service directly
   remains the shortest available patch, so the pressure to move them back is
   continuous.

Neither is visible in review, because the feature works in both cases. Both are
now checked mechanically: see section 5.

---

## 1. Layers

```
  +--------------------------------------------------------------+
  | wapps (.wapp, WASM)        chat, social, files, torrents      |
  |   presentation and domain rules for one application           |
  |   calls hal_* only; owns no radio, no key, no store           |
  +----------------^---------------------------+-----------------+
                   | events in                 | hal_* calls out
  +----------------+---------------------------v-----------------+
  | core (lib/)                                                   |
  |   identity and keys   profiles, nsec, signing, encryption     |
  |   transports          Reticulum, BLE5, LAN, WiFi-Direct, I2P  |
  |   delivery            LXMF, MeshCourier, custody, retries     |
  |   storage             sqlite, media archive, folders, spool   |
  +--------------------------------------------------------------+
```

A wapp is an event-driven consumer. It hands the core a message and is called
back when one arrives. It is not told which radio carried the message, whether
another station held it, or how many delivery attempts were made.

### Allocation of responsibility

| Question | Owner | Location |
|---|---|---|
| Should this message go over BLE, Reticulum, or both? | core | `lib/services/` |
| Is the recipient reachable? | core; a wapp does not ask | `RnsService`, `MeshService` |
| Who carries a message for an absent peer? | core | `MeshCourier`, `MeshStore` |
| What does a message mean (a like, a room post, a moderation rule)? | wapp | `wapps/<name>/` |
| How is a conversation rendered? | wapp | `wapps/<name>/` |
| Which key signs or encrypts? | core; a wapp requests, never holds | `hal_identity_sign`, `hal_encrypt` |

### Test for misplacement

> If a wapp requires a new `hal_*` endpoint in order to make a transport
> decision, the logic is on the wrong side of the boundary.

`hal_encrypt` is correct usage: the wapp asks the core to act with a key the
wapp does not hold. `hal_lxmf_pending` and `hal_rns_has_path` were added so that
a wapp could decide whether to transmit a redundant copy, which is the case that
prompted this document. They remain only as read-only diagnostics.

---

## 2. Isolates

Measured layout and rationale: [performance.md](performance.md).

| Isolate | Permitted | Not permitted |
|---|---|---|
| main / UI | widgets, `setState`, wapp page engines, MethodChannel calls | crypto over large buffers, sqlite scans, file hashing, blocking I/O, unbounded loops |
| rns-crypto | Reticulum sign, verify, encrypt | UI, platform channels |
| rns-transport | packet routing, links, resources | UI, platform channels |
| wapp background engines | `module_tick` for background wapps | anything requiring a UI |

Two rules are absolute.

**Platform channels are main-isolate only.** This covers `Ble5Bus`,
`MethodChannel` and plugin calls. A background isolate calling them fails
silently or throws. `MeshCourier` therefore transmits from the main isolate, and
its heavy work is encryption over payloads of about 200 bytes.

**Nothing blocking runs on the UI isolate.** No `*Sync` file I/O, no `sleep`, no
unbounded loop in a widget or in a service the UI awaits. Work that can exceed a
few milliseconds belongs in an isolate or a `compute` call.

---

## 3. Placing a new feature

Evaluate in order:

1. Does it move bytes between devices? Core, without exception. This covers
   transports, retries, custody, encryption in transit and addressing.
2. Does it require a key, the profile, or the databases? Core, exposed to wapps
   through a single narrow `hal_*` verb.
3. Is it about what a message means to one application? Wapp.
4. Is it a screen? Wapp, or `lib/ui/` for a core surface such as Settings, the
   launcher or the profile.

A core service does not know that any particular wapp exists. A special case for
chat in `lib/` indicates the wrong shape: the core should provide a generic
capability that the wapp uses. `MeshCourier` therefore carries payloads, not
chat messages.

---

## 4. Transports

See [ble5.md](ble5.md) for transmission budgets and
[store-and-forward.md](store-and-forward.md) for delivery to absent stations.

- Reticulum is the primary transport on every platform. LXMF is the message
  layer.
- BLE5 connectionless advertising is the off-grid broadcast plane: small frames,
  one-to-many, no pairing.
- GATT and MSP form the bulk and custody plane: a transient link for payloads
  too large for an advertisement, and for transferring parked mail to its
  recipient.
- Store-and-forward is a core service, `MeshCourier`, armed by the core on every
  direct send. Arrivals are returned through the ordinary LXMF inbox.

### Which lane carries what — get this right first

The lanes are not interchangeable, and confusing them costs days. Established
the hard way (2026-08-26), and the answer is short:

| lane | carries | limit |
|---|---|---|
| **BLE5 extended advertising** | **XPRS packets only**, subtype `0x58` | 250 B, one packet per advert, never fragmented |
| **GATT + MSP** | file bytes and parked mail | ~10 kB/s, offset resume, sha-verified |
| **Reticulum** | the internet path: LXMF, folders, DHT | not a radio lane |
| **Reticulum datagram** | one connectionless packet to one destination, no link — the packet-lane file (XPRS.md §7.7.6) and anything else sent many times and verified whole | 383 B plaintext, 250 B XPRS wire; forwarded by every transport node on the path |

**BLE5 carries XPRS. Reticulum is the internet path.** Pushing a Reticulum
resource through the advert channel does not work and cannot be made to work: a
resource is sized to a link MTU and the advert channel carries 250-byte packets
on a 5-second-a-minute transmit window. A whole day went into "fixing" MTU
negotiation, advert TTLs and path-request throttles before the premise was
questioned.

**How a file moves between two stations** is specified — XPRS.md §25.2.2 — and
it uses two of the three lanes at once:

```
->  t:command cmd:file file:<ref> [off:]   (advert channel: XPRS)
<-  t:result  code:202
    FILE_OFFER / ACCEPT / CHUNK / WIN_ACK / DONE / OK   (bulk lane: MSP)
<-  t:result  code:200                     (advert channel again)
```

The XPRS packets open and close it; MSP carries the bytes; the `200` is aired
only after the receiver has hashed what it holds. The same two packets bracket
the transfer whatever the bearer — only the middle block changes, which is why
the specification leaves it out.

**Test for a transport question**: name the lane before writing code. If the
answer is "bytes between two stations in radio range", it is MSP with an XPRS
bracket, and both halves already exist — see `docs/mesh.md` §14.

**How a small file crosses a public hub** (2026-09-08) is the second way, and
it uses the packet grammar itself, because the shared hubs pass directed
packets and drop the bulk link. XPRS.md §7.7.6 chunks the raw bytes into
ordinary `t:file ... off: b:` packets, one fixed chunk length per transfer:

```
->  t:file off:0 b:…   t:file off:96 b:…   …      (datagrams, paced 80 ms, unsigned)
    [silence ~10 s at the receiver]
<-  t:command cmd:file file:<ref> have:<bitfield>   (§8.1's map: bit k = chunk k)
->  the chunks the map lacks, again as datagrams; t:result 202 / 200 / 404
```

Three core pieces, none of them a wapp's: `XprsInlineSender` (split, store —
the sender self-hosts what it sent — pace, re-send the gaps),
`XprsInlineAsm` (assemble, learn the grid, report after silence, hand the
verified whole to the media archive), and `XprsBearer.send(datagram: true)`
through `publishWire`, which on Reticulum is `RnsService.sendDatagramTo`: one
LXMF wapp datagram, unsigned, encrypted under one ephemeral key per peer, one
connectionless packet on the path's interface. No link, no retry ladder, no
courier, no chat row, not archived. A chunk costs no curve operation; that
sentence is the whole difference between 38 minutes and 26 seconds for the same
file ([performance.md](performance.md) §8.13).

**The receive door is the same door.** A chunk enters through `PacketGateway`
like every packet, is fed to the assembler in `XprsIngest`, and is filed
nowhere: three hundred of them per meme are not history.

### The station as a Reticulum transport node

Reticulum forwards by announce-taught paths keyed on the destination hash, not
by address: a station that only ever dialled out is a full transport node for
everything attached to it (XPRS.md §12.12.3). The core takes that role on the
same capacity gate that makes a node an indexer — mains power plus Wi-Fi or
Ethernet, `CapacityProfile.unlimited` — in `RnsService._applyHubRole`:

| | leaf (default) | promoted |
|---|---|---|
| rebroadcast | `edgeBridge`: BLE-heard announces up to the hubs, nothing back down | `edgeQuiet`: everything onward, never onto an edge bearer |
| path requests | answered for our own destinations only | answered for every destination held, from the stored announce (`RnsTransport._answerPathRequestForOthers`) |
| forwarding | for links we bridge | for anything addressed through us |
| LAN | UDP discovery + unicast data | plus a TCP hub on :4242 for standard Reticulum clients |

Four rules hold in both roles and each one is a measured defect:
`RnsInterface.uplink` — an announce from one shared hub is never re-aired to
another; a relayed announce is unicast to LAN peers and dropped with none
(`RnsLanInterface.planTx`); our own frame coming back is dropped at the
interface and, failing that, at the transport (`selfEchoDropped`) — a path
whose next hop is ourselves once routed a peer on another network into
nothing; and `announce()` collapses requests inside 30 s, because a hub
answers a burst with hours of silence. `/api/rns/status` reports `hubRole`,
`pathAnswers`, `selfEcho`, `lanSelfDropped`, `lanNobodyDropped` and
`datagrams{sent,noPath,tooBig,opened}` so the role can be read off a device
rather than asserted.

### Who is on the mesh, decided once (2026-09-09)

"Is this an XPRS device" was answered in three places by three rules: the live
graph asked whether a node announced any service that was not LXMF, the
persisted counter asked the same thing minus one word, and the Mesh header
bucketed whatever was on the canvas by the first two characters of a label.
None required a CALLSIGN, so a Reticulum destination that merely announced on
one of our service hashes was counted as a device and listed as a person with a
Follow button that could never work. The screen said 715 XPRS devices on a
network of six.

`lib/services/xprs/xprs_presence.dart` is the one rule, and it is pure: facts
in, `XprsDevice?` out, `null` for anything that is not one of ours.
**A device is XPRS when we can name it with a callsign we are entitled to
believe** — heard as an XPRS wire (evidence by construction: only a parsed
packet with `f:` reaches `XprsMonitor`), paired in a beacon, verified against
the key that announced it, or derived from that key. Services are a property of
a device already identified; they never identify one. Callsign decides class:
`X1` a person, `X2`/`X3` a station, `X4` equipment, `X5` an address and not a
device at all.

`RnsService.xprsPresence()` applies it to live state, merging announces with
both halves of the monitor — including the stations heard only over Reticulum,
which the graph had never shown because it walked the air-heard table alone.
Every surface reads that: the snapshot's per-node `class`/`mobility`/
`meta.bearers`/`meta.reachable`, its `counts`, the watchdog, and the row written
to `ObservedStore`. The widget renders and derives nothing.

Two lessons worth keeping:

- **One column cannot answer two questions.** `xprs` in the observed store was
  read both by a person ("how many of my devices") and by the DHT warm start
  ("every peer running our software, named or not"). Splitting it into `xprs`
  and `svc_xprs` is what let the person-facing count fall to the truth without
  shrinking the warm start.
- **A verdict that can only go up is not a verdict.** That column was merged
  with `MAX(old, new)`, so no node could ever stop being counted. The count
  could not have fallen even after the rule was fixed.

### The archiver in the middle (2026-09-08)

A message is not delivered by the sender trying harder. Two people who are
never awake at the same moment need a third station that is, and the core owns
every part of that: choosing it, leaving a copy with it, holding other
people's copies, delivering them, and ending the obligation.

**The wapp is not told any of this exists.** Chat sends a message and is called
back when one arrives; the deposit, the hold, the retry and the receipt fan-out
happen underneath it, for `t:message` and for everything else the core carries
on a person's behalf (docs/store-and-forward.md 5.1, XPRS.md 12.8.3). A wapp
that had to know which archiver held its mail would be a wapp making a
transport decision, which is the rule this file exists to state.

The logic sits in `XprsMailbox` and `XprsArchiverChoice` with their sends
INJECTED, so the whole loop runs in a simulation against a virtual air
(`test/xprs_mail_relay_sim_test.dart`) — three stations, real funnel, real
store, no radio. That is how the dance was made to work before any of it
reached a device, and it is the pattern for anything whose failure only shows
up between machines.

### How a file is shared in chat (2026-09-08)

A picture in a conversation is the case that touches every lane at once, so it
is the case where "the wapp asks, the core decides" has to be exact. What ships:

**One door in, one door out.** `MediaFetch.want(ref)` is the only way to ask
for bytes. The Flutter thumbnail, the wapp verb `hal_media_fetch`, the remote
API and the chat view all call it, and every one of them used to carry a
different, worse ladder of its own — the wapp verb scanned the LAN and the
torrent swarm with no Reticulum, no packet lane and no bulk lane at all. The
door checks the store first (a file obtained once is never fetched again), keeps
one in-flight request per hash, and reports through `core.media`.

**The lane is a pure function of size and reachability**, `MediaFetch.decide`,
and it is a test table rather than a comment:

| size | what reaches a holder | lane |
|---|---|---|
| ≤ 32 kB (or unknown) | anything, including a public hub | packet lane, `cmd:file … have:AA` |
| larger, within the operator's ceiling | a LAN peer or a Reticulum path | bulk lane, racing the internet ladder |
| larger, within the ceiling | nothing local | the internet ladder alone |
| larger | only BLE, LoRa or another shared radio | **wait for a tap** |

The last row is the rule that matters on a radio: ten megabytes on a shared
channel is not a download, it is an outage for everyone in earshot.

**The reference leaves the caption.** `xprsLiftFile` moves the token out of `m:`
into the `file:` field and adds `size:` and, if it fits, `name:` (XPRS.md
7.7.7). It runs BEFORE the packet is built, because a sealed 1:1 hides `m:`
inside `x:` and a lift done later would never see the token. A picture too big
for the packet lane goes out as a ~24 kB preview the message carries, plus a
companion `t:file r:<message id>` describing the original; the preview is made
with `package:image` on a worker isolate, never on the UI isolate.

**Every sender owes the same three things**, so they are three shared
functions rather than three copies: `xprsLiftOntoHead` writes the fields before
the body is built, `XprsSend.airFileCompanion` describes the original a preview
stands for, and `XprsSend.onFileShared` advertises the hash and pushes the
bytes where a lane exists. The remote API had its own version of all three and
each one was subtly wrong — a reference sealed inside `x:` where nobody could
read it, no companion, and a file shared without telling the network it
existed. `xprsBuildWithFile` is the fourth: it drops `name:` and rebuilds
rather than refuse a five-word message because the FILENAME did not fit.

**The wapp's whole surface is three things**: a token in the text it sends,
`hal_media_state` for what the core is doing about a reference, and
`hal_media_open` to hand a held file to the system viewer. It never receives
bytes, never names a bearer, and cannot ask for one. Attaching is capped at
16 MB at both doors, because attaching copies bytes into a database blob; above
that the answer is to share it from a folder, where the bulk lane streams off
disk.

---

## 5. Enforcement

`tool/arch_guard.dart` checks the rules above on every push, via
`.github/workflows/arch.yml`, and on every commit once the hook is installed.

```sh
dart tool/arch_guard.dart            # check; exit 1 on a new violation
dart tool/arch_guard.dart --list     # all violations, including the baseline
dart tool/arch_guard.dart --baseline # re-record the baseline
./tool/install-hooks.sh              # install the pre-commit + pre-push hooks
```

The guard is a baseline checker. Violations recorded in
`tool/arch_baseline.txt` do not fail the build; new violations do. A guard that
fails on first use is disabled shortly afterwards, so the baseline exists to
keep it in service.

The baseline is keyed on the offending line rather than the file. Keying on the
file would also forgive the next violation added to that file, which was
observed during the guard's own self-test before release.

The baseline currently holds 89 entries, and the guard reports them on every
run (`arch_guard: clean (89 known, 89 baselined)`). Thirty-one of them are the
`no-native-import-outside-io-file` rule's: the native-only services (sockets,
I2P, torrents, bulk spool, video) and reticulum-dart's socket interfaces and
isolate workers, which compile for web and throw when reached ([web.md](web.md)
lists what a browser cannot do). A new violation still fails the build
immediately; the baseline is what the rules found already in the tree when each
was added, not a clean bill of health.

### What the pre-push hook refuses, and why

`./tool/install-hooks.sh` also installs a **pre-push** hook, and it enforces
something the architecture rules cannot: that CI is compiling the same code you
compiled.

It refuses a push while anything under `lib/`, `test/` or `assets/` is
uncommitted, and warns (without refusing) when the `../reticulum-dart` sibling
has uncommitted work or sits ahead of its remote.

The reason is a failure that has happened repeatedly and always looks the same:
a commit names a symbol whose definition is still unstaged, `flutter test`
passes here because this machine has both halves, and the build is the first
thing to find out. The sibling is the sharper version — aurora depends on
reticulum-dart by path, so it resolves to your working tree locally and to
`xprs-dev/reticulum-dart@main` in CI, which means an uncommitted change there is
invisible to every local check at the same time as it is invisible to CI.

Both checks are pure git, so the hook costs milliseconds and says nothing at all
when the tree is clean. Skip it with `git push --no-verify` when you mean to.

Rules enforced:

| Rule | Detects |
|---|---|
| `no-blocking-io-on-ui` | `*Sync` file I/O and `sleep()` on the UI isolate |
| `one-receive-door` | anything but `PacketGateway` reaching the receive funnel, the courier or the inbox — every bearer enters through one door |
| `no-transport-in-wapp-layer` | `lib/wapp/**` reaching into radio or transport internals instead of a service facade |
| `no-app-logic-in-core` | `lib/services/**` and `lib/connections/**` naming a specific wapp |
| `no-transport-logic-in-wapps-repo` | wapp C source reimplementing custody, retry or reachability |
| `no-platform-channel-off-main` | `MethodChannel` or `Ble5Bus` in isolate entry points |
| `hal-budget` | a `hal_*` endpoint whose name describes a transport decision (reach, path, pending, custody, forward) rather than a capability |
| `no-native-import-outside-io-file` | an unconditional `dart:io`, `dart:ffi`, `dart:isolate` or FFI `package:sqlite3` import outside a `*_io.dart` file, in `lib/` and in the reticulum-dart sibling: the web build compiles `lib/` with dart2js, where FFI is a compile error and the rest throw at runtime ([web.md](web.md)) |

To add a rule, extend the table in `tool/arch_guard.dart`. It is a single Dart
file with no dependencies, which is deliberate.

### Exceptions

Two mechanisms exist, both leaving a record.

An inline annotation, which requires a stated reason:

```dart
// arch-ignore: no-blocking-io-on-ui reads a 40-byte flag at startup, before the first frame
```

Or re-recording the baseline with `--baseline`, with the reason given in the
commit message.

Deleting a rule is not an accepted response to it firing. Each rule encodes a
defect that has already occurred.

---

## 6. Testing a wapp feature

A wapp touches nothing but the HAL (§1), so a wapp feature is fully testable
without a device: the HAL is the only surface it has, and the HAL can be mocked.
**Test chat features in the internal, on-machine test environment — do not reach
for a phone or a built bundle to prove a chat flow works.**

Because transports are the core's (§4), the mock HAL is where a network
connection is simulated: one instance's `hal_xprs_send` / `hal_xprs_message` /
`hal_xprs_broadcast` / `hal_xprs_read` becomes a delivery into another instance's
event queue, shaped exactly as the core shapes it. That is a stand-in core, not
a wapp shortcut — the wapp under test still decides nothing about how bytes
travel, and closed-group membership is still enforced at the core's door.

For chat this environment already exists:

- `wapps/chat/tests/native/` — many instances of the real wapp
  (`main.c`/`room.c`/`db.c`/`thread.c`/`xprs.c`) in one process. `hal_mock.c`
  carries the mock HAL and NULL-default network hooks; `run.sh` drives one node,
  `run-sim.sh` (`sim.c`) drives a network of them.
- 1:1, closed-group and Local flows — delivery, read receipts, reactions with
  the sender's own echo, the membership door, emoji, and survival of a restart —
  run there in seconds, no build lock, no install.

A new chat feature ships with its scenario in that harness. A feature that
genuinely cannot be reached through the HAL is a sign the feature is in the
wrong layer (§3), not a reason to test it only on a device.
