# People: one record per key, identities that accumulate

Status on 2026-11-21: steps 1 to 3a done and pushed; the rest open. No
release until the whole plan is in (decided 2026-11-21).

## Why

The only thing that identifies a person is their key, the `npub`. Everything
else a station knows about them was kept in separate tables, keyed by
callsign, each fed from one source:

| Fact | Where it lived | Keyed by |
|---|---|---|
| nick, picture, about, url | `XprsProfiles._deco` | callsign |
| Reticulum identity, destination, key | `RnsService._callIdentity`, `_callsignDest`, `_callPub` | callsign |
| LXMF address and callsign | `_lxmfCallsign`, `_lxmfAlias`, `_lxStation`, `_lxmfDestCache` | both ways, memory |
| Reticulum nodes seen | `observed.zx` | Reticulum identity |
| npub of a callsign | archive identity rows, `XprsGroupKeys.npubFor` | callsign |
| own profile | `IwiProfile`: one `callsign`, one `licenceCallsign` | profile id |

The failure that prompted this: a fresh station had an archiver's LXMF
announce and verified messages from it, but the Reticulum identity of a
callsign was only read from its chat announce, which a hub forwards hourly
and not every time. A 4 kB groups index waited 35 minutes for one announce.

## The model (core `services/people/xprs_people.dart`)

One record per holder. A holder is an `npub`, or, for something heard that
has no key (a Meshtastic node, an unsigned issued callsign), a keyless record
named by its own identity (`~meshtastic:MTA1B2C3D4`), taken over by the key
that claims it.

Identity types (a plain word, so another network is another word):
`callsign` (derived, X1 to X5), `licence` (issued, several per person,
XPRS.md 6.4.2), `reticulum`, `lxmf`, `ble`, `wlan`, `meshtastic`, `meshcore`,
`email`.

Evidence, weakest first: `relayed` (somebody else said it), `observed` (seen
together on a transport), `noted` (the owner of this device wrote it down),
`signed` (the holder's key signed it), `derived` (arithmetic from the key).
Evidence only rises. A reader asks for a minimum.

Each identity also keeps first and last seen, the bearer or station it came
through, and the `scope` the holder allows it to be told on (empty: not to be
told on).

Two keys may hold one issued callsign and both verify (6.4.2): both are kept
and `contested` says so. Nothing is merged.

Kept in `people.zx` inside the profile. Bounded: 8 identities of a type per
holder, 4096 holders. Writes are batched; a re-sighting is written at most
once an hour.

## Decisions (2026-11-21)

1. Keyless records are kept until a key claims them.
2. Telling others one's own extra identities needs wire words that do not
   exist (`mac`, `email`, a claim of a Meshtastic or MeshCore id). OPEN: the
   user was asked whether to add three optional fields to `t:identity` or to
   keep these on the device. Nothing is aired until this is answered.
3. Scope: a MAC is only worth telling at local range; an e-mail address goes
   as far as its owner chooses (local, regional, global).
4. The whole plan before the next release.

## Steps

1. DONE. The store and model, 9 unit tests (`core/test/xprs_people_test.dart`).
2. Feeders.
   - DONE: a verified `t:identity` (`XprsIngest._bindIdentity`) claims the
     callsign for the key; every announce that names its node
     (`RnsService._notePerson`) files the device's Reticulum identity and LXMF
     address; a signed `lx:` (`noteSignedLx`).
   - OPEN: the beacon's `lx:` (`noteStationAddress`), the static Bluetooth or
     WLAN address behind a verified beacon (boards only, never a phone's
     rotating address), a gateway's Meshtastic and MeshCore nodes (3.2), the
     LXMF source of a verified directed packet, a seed from `observed.zx` at
     first start.
3. Readers, one at a time, each deleting the table it replaces.
   - DONE (3a): `RnsService.identityForCallsign`, used by the whole-file
     fetch and the named holder of a piece fetch.
   - OPEN: `_apiIdentity` and station visits, `lxmfDestForCallsign` and the
     `_lxmf*` maps, `npubForCallsign`, `XprsProfiles` re-keyed by npub.
4. OPEN. Own profile: `IwiProfile` gets the same list (several licence
   callsigns, the owner's boards, an e-mail address with its scope); the
   profile page lists them.
5. OPEN. Telling others (decision 2), then the spec text and corpus.
6. OPEN. `architecture.md` section; `reusable.md` entries (core: done).
7. Proof: a fresh station on the public hubs fills its groups list without
   waiting for a hub announce (`temp/xprs-fresh*` runs, see
   `plan-archiver-tests.md`); the suites pass.

The firmware keeps its own small tables; this plan is core, which the app
and the server share.

## Privacy

Addresses of people are in an encrypted store. A MAC and an e-mail address
are never served by the station API or a hosted page, and never aired except
by their owner's signed word within the scope they chose (decision 2).
