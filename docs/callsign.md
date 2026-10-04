# Callsigns: which name is which

> Part of the XPRS app docs. The protocol is [XPRS.md](../../spec/XPRS.md)
> sections 3 (callsigns), 6.4 (permitted use by band) and 6.4.2 (binding an
> issued callsign to a key). This page is what the app does about them.

Every identity here wears a callsign the app generated: `X1` plus two to five
characters of the bech32 encoding of its own key, four by default. That is the
right label on licence-free spectrum, where nobody issues anything and the
label costs nothing. A licensed radio amateur needs their own callsign
instead: on licensed spectrum an `X1` identifies nobody, which is the exact
thing an identification requirement exists to prevent (XPRS.md 6.4.1).

## 1. Four names, and none of them is interchangeable

A profile (`lib/profile/iwi_profile.dart`) carries:

| | what it is | changes? |
|---|---|---|
| `id` | the folder on disk, `devices/<id>/` | **never** |
| `callsign` | derived from `npub`, self-proving by arithmetic (XPRS.md 3) | **never** |
| `licenceCallsign` | what a radio authority issued, or empty | the operator sets it |
| `wireCallsign` | **what goes in `f:`**: the licence when there is one, else `callsign` | follows the above |

`id` and `callsign` are the same string, and that is why neither can become
the licensed one: renaming them would move every file the profile owns.

Everything that asks "what am I called on the air" reads `wireCallsign`:
every `f:`, the Reticulum announce name, the GATT local name, `hal_identity`
(so every wapp calls itself the same thing), and the signed `t:identity`.
Everything that asks "where do my files live" reads `id`. The avatar colour
and identicon seed stay on `callsign` on purpose, so setting a licence does
not recolour an operator's icon everywhere it has already been seen.

Setting or clearing it fires `ProfileService.wireCallsignNotifier`.
`activeProfileNotifier` cannot do that job: it carries the `id`, which does
not change, so before that notifier existed the one edit that mattered most
to the air was the one edit nothing was listening for.

## 2. One grammar

`lib/services/xprs/xprs_callsign.dart`, with zero imports so the receive
funnel, the packet vocabulary and the profile screen can all read it.

Four files used to answer "is this a callsign" four different ways, and a
licensed operator fell through the gaps: `xprs_presence._shaped` had no `/`
group, so a station announcing `G0XYZ/P` matched nothing and was heard but
left nameless. `xprs_catchup._looksLikeStation` tested two string prefixes, so
a station running under its operator's licence was never asked for history or
for a file at all.

- `xprsIsCallsignShaped` is **recognition**, and deliberately generous: an
  unbounded tail, because XPRS.md 228-235 says "nothing in this format assumes
  a callsign length".
- `xprsIssuedCallsignRefusal` is the **operator entry point**, and strict. It
  cannot check the thing that matters (see §4), so it rejects what certainly
  was not issued: a name this app's own key generated, an `MT`/`MC` node
  number of another network (XPRS.md 3.2), and anything outside the `call`
  value type's charset (XPRS.md 670: uppercase letters, digits, `-` and `/`).
- `xprsLooksIssued` is a **warning and never a refusal**. It tests the ITU
  body shape (prefix, separating numeral, letter suffix), which catches
  `NET21`, but 228-235 forbids making a shape rule binding, so an unusual one
  still saves with a word of doubt beside it.

An `X1` to `X5` prefix is refused outright, and safely: ITU allocates `X` only
as a two-letter prefix series, never a single letter plus a digit, so no
issued callsign can begin that way.

**The ceiling is 15 characters**, and it is a limit of this software rather
than of the format. It is set by the narrowest hop, which is the wapp HAL: the
chat wapp reads `hal_identity` into `char id[16]`.

## 3. Carried whole or not at all

MSP (`mesh_session.dart`), the custody protocol over GATT, capped a callsign
at nine bytes and **silently truncated** anything longer, on the HELLO and on
every carried-mail envelope. A truncated callsign is not a shortened name, it
is a different station: `CT1ABC/PORT` went out as `CT1ABC/PO`, which nobody
holds, and the peer filed our mail under it.

So `_W.cs` still truncates, for a file's extension and name, where a shortened
value is still the same value, and `_W.call` **refuses**: a zero-length field,
which makes the frame fail its own decode check so the session dies with a
line in the log rather than succeeding under the wrong name.

The cost, stated rather than discovered: the field is length-prefixed under a
`u8`, so widening the limit is backward-compatible to **decode** and not to
**encode**. MSP custody with a station whose callsign is over nine characters
needs both ends updated.

## 4. What the binding proves, and what it does not

An operator announces the binding themselves, with the ordinary identity
packet and their own callsign in `f:` (XPRS.md 6.4.2):

```
t:identity f:CT1ABC ts:2026-10-04_14:26:40 k:npub1qz3n7…q7h7k5f sig:<60 characters>
```

`XprsPublisher.publishIdentity` composes and self-signs it, and
`xprs_identity_adopt` airs it the moment the callsign changes rather than
waiting for the 30-minute cadence: under a new name nobody holds a binding
for, every packet we send reads `unverified` until it goes out.

| Question | Answered by |
|---|---|
| does the holder of this key write these packets | the signature |
| was this callsign issued to this person | **nothing in XPRS**; the authority's public register, out of band |

The second row is the honest one, and the profile screen says it at length.
XPRS has no register and issues no credentials, a second station can announce
the same callsign with a different key and both announcements will verify, and
`recordCallsignPubkey` is called with `onlyIfUnknown` so the first speaker for
a name wins locally. **This is a record each node keeps and never a verdict
any node transmits** (XPRS.md 6.4.2), which is why there is no "verified"
badge anywhere in the UI: the UI is fed by those same records.

`t:challenge` / `t:response` (XPRS.md 29) are still not built, so a spoofed
authority-issued callsign remains undetectable.

## 5. Believing a peer's licensed callsign

`RnsService._callsignFor` decides what to call a key. It used to believe an
announced name only when the arithmetic agreed and otherwise replaced it with
the `X1`+4 the key derives, which silently renamed every licensed peer: the
same "a second name for one device, invented by the observer" defect the
function was written to end.

There are now two admissible proofs, and the announcement is still *checked*
either way:

1. **arithmetic** (XPRS.md 3), for a derived callsign; or
2. **a verified `t:identity`**, which is the only proof an issued callsign can
   offer, and is what XPRS.md 3.0.1 means by "what makes a callsign canonical
   is the identity announcement that declares it, which is signed".

`callsignMatchesKey` still returns false for `CT1ABC` and must: claiming
otherwise would be exactly the lie 6.4.2 warns about. Both answers are
memoised, bounded and drop-first, because this runs per node per graph build
and the fallback is itself a bech32 encode (architecture.md, performance.md
4.2).

## 6. One name on the air, two names answered to

XPRS.md 3.0.1 says a holder wears exactly one name, and we do: nothing is ever
*sent* under the old one. But every peer that has met this operator holds a
binding for the callsign their key derives, and a 1:1 in flight is addressed
to it, so the receive side answers to both. `XprsArchive.addressesUs` is the
one place that decides it, replacing four hand-written comparisons.

Two things are deliberately **not** aliased:

- **The echo skip** stays exact and stays on the aired name. A packet bearing
  our old name is not our own echo, because we no longer send under it;
  suppressing it would hide a diagnostic.
- **Closed-group membership** keeps taking the aired name. A roster is a
  verified record of a name (6.4.2) and is not ours to alias.

And one limitation, which is real and is stated to the operator rather than
papered over: **mail a neighbour was already carrying for the old callsign may
not be handed over.** A carrier matches its rows against the callsign in our
MSP HELLO, so once we HELLO as `CT1ABC` its rows targeted `X1ABCD` never
match. There is no fix inside "send under one name" without an MSP wire
change. Those rows expire on `MeshStore.sweep`, and the sender's Reticulum
retry ladder re-delivers under the name it resolves now. The profile screen
tells the operator to ask the sender to resend.

A wapp reads `hal_identity` once at init, so one already running keeps the old
name until it is reopened. The proper fix is a wapp re-reading it on a core
event, in `../apps`.

## 7. Kind, and where an operator appears

`xprsKindOf` is **unchanged**: a licensed callsign classifies as `station`,
never `user`. A licence says nothing about whether its holder is a person or a
mast, and guessing would be worse than saying station. So a licensed amateur
appears in the Stations list rather than in People, the HAL contract
(`hal_xprs_kind`) already documented "station (X2, X3 or a licence)", and the
profile screen warns them before they set it.

## 8. Licensed spectrum

XPRS.md 6.4.1 is the one rule in that document that is not ours to relax: a
packet whose `f:` is `X1` to `X5` must never be **originated** onto a licensed
frequency, and a station bridging licence-free traffic onto licensed spectrum
must **drop** such packets rather than relay them.

**No bearer this app ships reaches licensed spectrum.** The four registered
bearers are BLE5 and LAN (ISM), Reticulum (the internet), and a LoRa bearer
whose `send` already refuses; reticulum-dart has no KISS, serial or AX.25
interface, and `rns_iface_kind` calls `radio`/`aprs`/`kiss` forward-looking
*receive* labels. The rule is enforced where it can bite, in the firmware's
SA818 transmit gate and its iGate (`xprs_is_self_generated`).

The app keeps an inert check anyway, in `XprsPublisher._fanOut`'s `tryOne`,
the one function every outbound frame passes, so the day a KISS interface
lands the rule is already on the door rather than being remembered. See
[spectrum.md](spectrum.md) §8.
