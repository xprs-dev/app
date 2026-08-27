# Private and plain 1:1 messages

How a one-to-one message is sealed, how the operator chooses, and how a station
decides which radio carries it. `docs/XPRS.md` governs; this file says what is
built and what it cost to learn.

**Drawn:** [diagrams/transports-flow.md](diagrams/transports-flow.md) figure 6 is
the life of a 1:1 message, sealed or plain.

---

## 1. The whole mechanism is one field

§9.2, in full:

> `x:` carries the sealed body and replaces `m:`.
>
> ```
> t:message f:X1QZ3N d:X1RD89 ts:2026-08-08_14:26:40 x:pQ4m9xT2vB8kR sig:<60>
> ```
>
> `t:`, `f:`, `d:` and `ts:` stay in cleartext, so an intermediate station can
> route the packet, identify the recipient and release a carried copy on the
> matching receipt, without reading the content.

So the two forms of a 1:1 are:

```
private   t:message f:ME d:PEER ts:<utc> x:<base64url> sig:<60>
plain     t:message f:ME d:PEER ts:<utc> sig:<60> m:<text>
```

**There is no privacy flag anywhere, and adding one would be a bug.** The wire
form *is* the statement. Design rule 6 (§2) says why: *"Nothing is defined out of
band. No receiver requires prior state to read a packet."*

Three things follow, and all three are properties of the format rather than
features anybody wrote:

- **Either side switches on any message.** No negotiation, no handshake, no
  agreed mode, nothing to get out of step. A conversation may alternate freely
  and both ends simply read what arrived.
- **The label is derived, never transmitted.** `x:` present means private, `m:`
  present means plain. A receiver needs nothing else and remembers nothing.
- **Private is the default for a direct message** — §9.4's table: encryption is
  *"permitted, and is the default for direct messages"* on licence-free spectrum
  and the internet.

`XprsBandRule` holds the other half of that table: §9.4 forbids `x:` on amateur
bands (*"An implementation able to reach amateur infrastructure must refuse to
transmit a sealed body onto it"*). No bearer here is amateur spectrum, so the
rule is inert — it lives in `xprs_body.dart` so it is enforced in the one place
that builds a body, rather than remembered by whoever adds an HF bearer.

## 2. A private message is never quietly downgraded

`MeshCourier._seal` used to return the **plaintext** on every failure — no key
for the recipient, no key of our own, any exception. A message the operator
believed was sealed went out readable, and nothing said so.

That is not a weaker message. §36.8:

> **Sealed mail travels on the strength of the seal.** … An archiver releases
> sealed mail to a station whose own published observation currently lists the
> recipient in `hears:`… **Clear mail is released only to a declared holder**
> (`hold:`) or fetched by the recipient itself. **Plaintext is disclosure.**

The two forms are handled differently by every carrier that touches them, so a
downgraded message travels under release rules its author did not choose.

`xprsBuildDirect` now **refuses** and reports which of `noRecipientKey`,
`noOwnKey`, `cipherFailed`, `amateurBand`, `tooLong` stopped it. Callers surface
it: the API answers `409` with the reason, the courier logs
`not airing <call> in the clear — <why>` and leaves the copy held, and the chat
wapp tells the operator rather than sending.

`refusedNoSeal` in `/api/status` `mesh.courier` counts these.

## 3. Not being able to read one is a fact, not a reason to drop it

A sealed packet that would not open was counted and discarded, so a message sent
to this station simply never existed here. It is now shown, marked unreadable,
and counted as `sealedUnreadable`. The usual cause is benign and self-correcting
— see the next section.

## 4. Key discovery, and the half-hour hole

Sealing needs the recipient's published key (`k:` on their `t:identity`, §9.3).
Two faults made that unreliable, and both showed on the bench as
`cannot seal: noRecipientKey` on a peer that had been in the room all day.

**Bindings live in memory; announcements come every thirty minutes.** §18.1 sets
that period, so a station that restarted could not seal to anybody — or verify a
signature, or resolve a nickname — for up to half an hour, *while holding the
archived announcements that say so*. `XprsIngest.rebindFromArchive()` replays
them at startup. They are signed, so the binding is re-derived rather than
trusted, and no airtime is spent. On the bench: `re-bound 200 stored identity
announcement(s)`.

**Nothing ever asked.** §18.1 gives the remedy — *"`q:identity` asks for one
directly rather than waiting for the next period"* — and the responder existed,
but no station sent one, and the responder only read `t:command` while §7 puts
`q:` on a `t:request`. Both fixed. `XprsPublisher.askIdentity` now fires from the
three places that discover a key is missing: a refused seal, a sealed packet that
would not open, and a wapp asking what form a message would take.

## 5. Long messages: each part is sealed on its own

A sealed body is ~40% larger than the text it replaces, so it runs out of packet
sooner. The budget, measured:

| form | plaintext in one 250-byte packet |
|---|---|
| plain `m:` | 133 characters |
| sealed `x:`, signed | **79 characters** |

§13.6 requires splitting (*"A sealed body is longer than the text it replaces, so
a long carried message is split into parts (section 6.6)"*), and §6.6 gives the
procedure: same `ts:`, own `n:`, at most 9 parts, split at spaces only, join with
exactly one space.

**Each part is sealed separately** and carries its own `x:`, so each decrypts
alone. Every part is signed rather than only the last: §9.1.1's economy exists
for when the *signature* is what does not fit, and sealing per part leaves room
for one each, so §9.1's default ("a station signs by default") applies and every
part stays verifiable on its own.

**Receiving them is new.** The app split on the way out and had nothing that
joined on the way in, so any multi-part message was already unreadable.
`XprsPartTable` keys on `(f, ts)` per §6.6, holds an incomplete set 10 minutes,
ignores a repeated part number, accepts any order, and **never displays a partial
message**. A part that cannot be decrypted is not a part that arrived — a hole in
the middle must not close silently.

## 6. Which radio carries it — §36.0, and two ways to get it wrong

§36.0 is the rule, and it is not "prefer a lane":

> The one place a bearer legitimately decides anything is choosing among several
> paths to the **SAME station**… picks one: the path with the highest usable
> bandwidth among those it has **recent evidence are working**… **Reliability
> outranks raw speed** — a fast path that has not carried anything lately is a
> guess, and a slower one that answered a minute ago is knowledge.

with an explicit fallback, which is what the code did everywhere before:

> Where a station cannot tell which path reaches the asker… it answers on every
> bearer it can transmit on.

Ranked by usable bandwidth: **LAN > BLE5 > Reticulum**. A LAN is one operator's
own switch. BLE5 is in the room but has five seconds of transmit a minute
(`ble5.md` §1). Reticulum is the internet path, and eighteen hops through
community hubs to reach a phone on the same desk is the case this ranking exists
to stop. A broadcast has no single station to rank paths for, so it still fans
out. If the chosen bearer does not actually carry the packet, every bearer is
tried — a preference that can become silence is not a preference.

**Getting "evidence" right took two bench failures, and both are worth keeping.**

**First: the arrival bearer is not evidence.** A message to a phone with its WiFi
off went out over the LAN alone and reached nobody, because a third station had
re-aired that phone's packets onto the LAN and the arrival bearer was recorded as
if the phone itself had been there. A sighting on a bearer says the *relay*
works.

`via:` looks like the field that separates them (§13: *"a packet with no `via:`
has taken no hops"*) and cannot be used: **nothing transmits it yet** (§37,
*"`via:` instead of rewriting `f:` | not implemented"*), so a re-aired packet is
byte-identical to a direct one. The signal that does work is the station's own
`link:` (§10.6.1, *"a station reports once per bearer"*) — it describes the
sender, so it survives re-airing with its meaning intact.

**Second: evidence must age on the packet's own clock.** Stamping a `link:lan`
claim with the moment it was *heard* made an hour-old re-aired beacon read as
current, and the same phone was still chosen for the LAN. §4.8: `ts:` is when the
packet was composed. `bearersDeclared` is stamped from `ts:`, newest claim wins,
and a station with no clock (§10.7) falls back to arrival because that is the
best that exists.

Measured after both fixes, with TANK2's WiFi off and the desktop on the LAN:

```
C61 -> X16JK8 (desktop)   lan:sent    ble5:unused  reticulum:unused
C61 -> X1VCVM (TANK2)     ble5:sent   lan:unused   reticulum:unused
```

## 7. The switch and the labels

The switch is a lock in the chat composer, defaulting to private, offered only on
a 1:1 — a group is several stations behind one name (§6.3) and there is no single
key to seal to. It applies to the next message and may be flipped between any
two, because the wire form is per packet.

`hal_lxmf_send2(dest, body, want_private)` sends and returns **the form actually
used**: `1` sealed, `2` plain, `-1` privacy asked for and not possible. One call
rather than "set a mode, then send", because a flag left lying between two calls
is exactly the remembered state the format does not have.

**The bubble is labelled from the answer, never from what was asked for.** A lock
and `private` for a sealed body, an open lock and `plain text` for a readable
one. Both are drawn: an unlabelled bubble means "nothing was recorded", which
reads as private to anyone who has seen the lock elsewhere.

## 8. Checking it from outside the app

```sh
# send private (the default for a direct message) or plain
curl -s -XPOST localhost:3456/api/xprs/send -H 'Content-Type: application/json' \
  -d '{"type":"message","d":"X1VCVM","m":"hello"}'
curl -s -XPOST localhost:3456/api/xprs/send -H 'Content-Type: application/json' \
  -d '{"type":"message","d":"X1VCVM","private":false,"m":"hello"}'
```

The reply carries `form` (`x` or `m`), `parts`, and the per-lane `bearers`
report — which is how "went over the LAN and not the internet" is *checked*
rather than believed.

`GET /api/status` → `mesh.courier`:

| field | meaning |
|---|---|
| `refusedNoSeal` | asked for privacy, could not provide it, refused to send in the clear |
| `sealedUnreadable` | reached us sealed and would not open (usually: their key has not arrived yet) |
| `ingestDropped` | dropped outright — should stay at zero |

`GET /api/xprs/history` shows the archived wire per packet, which is the only
honest test of privacy: **read the row and look for `x:` or `m:`.** A plain body
is readable there; a sealed one is not.

## 9. What is validated, and what is not

Bench, 2026-08-27, three stations: C61 (`X3ARK`, phone), TANK2 (`X1VCVM`, phone,
**WiFi off — Bluetooth only**), desktop (`X16JK8`, LAN).

- **Validated.** Both wire forms byte-exact against §9.2 and §6.2. Private and
  plain 1:1 over BLE with the recipient offline, and over the LAN, with the same
  packet forms on both — the bearer changed and nothing else, which is §36.0's
  point. Switching form on consecutive messages in one conversation. Decryption
  end to end: the desktop ingested 8 sealed messages with `sealedUnreadable`
  unchanged at 0. Multi-part sealed messages on the air
  (`parked for custody (sealed, 3 parts)`). Lane choice as in §6 above. Identity
  rebind at startup (200 announcements) and a refused seal reported rather than
  downgraded.
- **Not validated.** The 10-minute expiry of an incomplete part set (unit-tested
  only). A 9-part sealed message end to end on hardware. The amateur-band refusal
  (no such bearer exists to test against). The composer toggle was exercised
  through the HAL and the API, **not** by tapping it on a screen.
- **Known, unfixed.** TANK2 archives no `t:identity` packets at all, so it has
  nothing to rebind at startup and depends on `q:identity` or the next 30-minute
  announcement. Worth chasing: the other two stations archive them normally.
