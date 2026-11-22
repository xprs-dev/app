# People: one record per key, identities that accumulate

Status on 2026-11-21 (evening): steps 1, 3a, 4 and 5 done and pushed, 2
partly; see Steps. No release until the whole plan is in (decided
2026-11-21).

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
2. Telling others: no key per kind, because the list of kinds is open and
   will grow for decades. Two generic words on the identity packet,
   `idtype:` (the kind, a documented VALUE) and `data:` (the identity, or
   several of that kind, comma-separated). One packet states one kind; the
   newest packet of a kind replaces it; `data:-` withdraws it. Spec 6.3.3.
   (`kind:` and `m:` were rejected for this; `data` was preferred over
   `value` because it reads for one or several and can be reused.)
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
   - DONE: the beacon's `lx:` (`RnsService._wireBeaconAddresses`); a
     gateway's Meshtastic and MeshCore nodes (`XprsIngest.heard`), keyless
     records; a board's Bluetooth address (`PacketGateway.receive` and
     `XprsPeople.noteAddress`, filed after 30 minutes of the same address).
   - OPEN: a WLAN address (no source for it yet), the LXMF source of a
     verified directed packet. (The seed from `observed.zx` is done, 3b.)
3. Readers, one at a time, each deleting the table it replaces.
   - DONE (3a): `RnsService.identityForCallsign`, used by the whole-file
     fetch and the named holder of a piece fetch.
   - DONE (3b): `_callIdentity` and `_callsignDest` are gone. Identity by
     callsign through the record; key material in a bounded cache
     (`_peerIds`) seeded from `observed.zx` (`namedPeers`, `pubkeyOf`);
     `call_peers.json` imported once and removed. `_apiIdentity`, station
     visits and the relay lookups read through `_identityOfCall`.
   - OPEN, each on a critical path, each with a rule the record must
     reproduce exactly before its readers move. One per change, with a
     live check on the phone and the boards:
     - DONE in part (2026-11-22): a DERIVED callsign's key (X1 to X5) is
       answered from the record when this run has not heard it
       (`pubkeyForCallsign`), so a restarted station verifies at once. Safe
       by arithmetic. Issued callsigns still come from this run's table
       only; see the decision below.
     - DECIDED 2026-11-22 (option A) and DONE: an issued callsign verifies
       under ANY key that signed for it (`xprsAlternateKeys`,
       `XprsPeople.signersOfLicence`; spec 6.4.2 says so now). Its key is
       therefore remembered across a restart too. The message info page
       says when a callsign is claimed by more than one key. OPEN: sealing
       TO an issued callsign held by two keys still uses the first key
       (`keyResolver` gives one); opening a sealed message from one tries
       only that key too.
     - `_callPub` is now only this run's cache in front of the record.
       Still reading it directly: the reverse lookups (`callsignForHex`,
       `_identityForPub`), the contacts list and the followed-profile
       sweeps. Moving those onto the record removes the table.
     - `_lxmfCallsign`, `_lxmfAlias`, `_lxStation` (where mail to a
       callsign is written). Rules: one trusted destination per callsign;
       the person's name and the device's X3 share an address, the X3 as
       an alias.
     - `_apiStation` / `_wappStation` (where a station's visitor API
       answers).
     - `XprsProfiles._deco`, re-keyed from callsign to npub.
4. DONE. Own profile: `IwiProfile.identities` (a list of
   `StatedIdentities`: kind, values, scope); the profile page has "Other
   identities", one row per kind with its scope
   (`lib/profile/other_identities_editor.dart`, strings in five languages).
   The issued callsigns stay in `heldLicences` and are stated from there.
   SEEN RUNNING (2026-11-22, Linux desktop on a private display): kinds
   listed, a typed address normalised, a board's address defaulting to
   "Nearby only", both sets saved. Found there: nothing was aired on Save
   (fixed, core: a change is stated five seconds later). On the air: the
   e-mail statement on LAN and Reticulum, the `scope:local` one on the LAN
   only. Not settled: the kind list opened from the keyboard but not from
   a scripted mouse click (another menu did); try by hand.
5. DONE. Telling others: spec 6.3.3 and five corpus packets (365);
   `XprsPublisher.composeIdentityStatement` / `publishIdentities` (aired
   with the decoration, a removed kind withdrawn once);
   `XprsPeople.stated` on receipt, through `XprsProfiles._apply` so it is
   verified like every identity field; `tellable(holder, reach:)` for
   whoever later serves these. OPEN: nothing shows another person's stated
   identities on a screen yet; the firmware does not parse `idtype:`.
6. DONE. `architecture.md` ("A person is a key"); core `reusable.md`.
   The message info page shows what a sender stated of themselves.
7. Proof: a fresh station on the public hubs fills its groups list without
   waiting for a hub announce (`temp/xprs-fresh*` runs, see
   `plan-archiver-tests.md`); the suites pass.

The firmware keeps its own small tables; this plan is core, which the app
and the server share.

## Privacy

Addresses of people are in an encrypted store. A MAC and an e-mail address
are never served by the station API or a hosted page, and never aired except
by their owner's signed word within the scope they chose (decision 2).
