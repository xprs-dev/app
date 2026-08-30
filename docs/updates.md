# Updating the Android app without the internet

How a phone learns a new version exists, and how the bytes reach it — including
a phone that has no internet at all and only Bluetooth.

Related: [architecture.md](architecture.md) §4 (which lane carries what),
[mesh.md](mesh.md) §14 (the bulk lane), [ble5.md](ble5.md) §9 (what it costs),
[../releases.md](../releases.md) (cutting and publishing a release).

---

## 1. The shape: the web announces, the mesh carries

```
   tag v1.2.0-beta.3
        │
        │  release.yml — build android/linux/windows
        ▼
   GitHub Release assets  (xprs-<version>-<platform>)
        │
        │  sync.yml (site repo) — hash each artifact, write the feed
        ▼
   https://xprs.dev/updates/{stable,beta}.json     ~1 KB, JSON only
        │
        ├──────────────► every phone: "is there a newer version?"  (one GET)
        │
        └──────────────► a SUPER-ARCHIVER downloads the artifacts ONCE
                              │
                              │  seeds them
                              ▼
              ┌───────────────┴───────────────┐
              │                               │
     Reticulum (internet/LAN)        XPRS + MSP (Bluetooth)
     content-addressed by sha256      cmd:file, then the bulk lane
              │                               │
              └───────────────┬───────────────┘
                              ▼
                     an ordinary phone installs
```

**The feed announces; it never hosts.** It is a JSON document of a version, its
notes, and per artifact a size, a download URL and a **sha256**. No binary is
committed to the website repo, so that repo stays a few kilobytes for ever and
GitHub Pages is never asked to serve a 56 MB APK.

**The sha256 is the address on every lane.** The same digest identifies the file
over Reticulum (a DHT provider record is keyed on it) and over XPRS
(`cmd:file file:<ref>`). A phone that has read the feed can therefore take
whichever lane it can reach, without anything else being distributed to it —
no folder id, no npub, no station name.

---

## 2. The feed

`updates/stable.json` and `updates/beta.json`:

```json
{
  "version": "1.2.0-beta.3",
  "tagName": "v1.2.0-beta.3",
  "name": "XPRS 1.2.0-beta.3",
  "body": "release notes (markdown)",
  "publishedAt": "2026-08-26T09:45:01Z",
  "prerelease": true,
  "assets": [
    {
      "name": "xprs-1.2.0-beta.3-android-arm64-v8a.apk",
      "url":  "https://…/xprs-1.2.0-beta.3-android-arm64-v8a.apk",
      "size": 56830760,
      "sha256": "928e3176ff054689b5b96951dbdb3cf67923ff2b1d87bf36391ae185f5f1e41a"
    }
  ]
}
```

- `beta.json` always names the newest build; `stable.json` only non-prereleases.
  A stable publish writes BOTH, so beta users get stable releases too.
- Written by `tool/publish_release.dart` — the only implementation of this
  format. `sync.yml` runs that script rather than deriving the JSON again.
- Asset names carry the version. `versionFromAssetName()` parses
  `xprs-<version>-<platform>`; a versionless name parses as a version and offers
  a release that does not exist.

**Checking is cheap and hosting is not.** One ~1 KB GET answers "is there
something newer"; the megabytes are a separate decision on a separate lane.

---

## 3. Deciding that a version is newer

`compareSemver` compares version **names**, pre-release aware (semver §11).
Build metadata is stripped and **the Android versionCode plays no part**.

That matters, because versionCode decides something else entirely: whether
Android will *install* what was offered. See §7.

---

## 4. The super-archiver as the mirror

A station that says yes to `update.mirror` becomes the local source of
binaries. `UpdateMirrorService`:

1. reads the feed (every 6 h — a poll interval is a battery setting, and
   releases ship at most weekly);
2. for each artifact it does not hold, downloads it **over HTTPS** with the
   system DownloadManager;
3. verifies size + sha256 against the feed;
4. moves it into a signed Reticulum folder it owns, and answers `cmd:file` for
   it on the radio;
5. keeps the newest **5 stable** and **5 beta**, pruning older ones.

Opt-in and off by default: an ordinary phone must never spend a byte on this.

**Memory is the whole design.** An artifact is 47–61 MB and the station serving
it usually has the least RAM:

- DownloadManager streams to disk in its own process — nothing in the Dart heap;
- verification hashes in 64 KiB chunks on a worker isolate;
- the finished file is **renamed** into place, never copied through memory;
- serving reads a window with seek+read;
- retention reads **filenames**, never bytes, and never browses the folder to
  count (that would reduce and re-verify the whole signed op-log to learn a
  number).

Each of those replaced a whole-file read that was correct for a chat photo and
wrong for an app update — `performance.md` §8.9.

The digests it holds are written to `.digests.json` beside the artifacts, so a
restart does not leave it answering `404` for files in its own directory until
the next six-hourly tick.

---

## 5. How the bytes reach an ordinary phone

`UpdateService.download()` tries the lanes in order. The first that answers
wins; the sha256 from the feed is the address for all of them.

### 5.1 Over Bluetooth — XPRS + the bulk lane

The lane that works with **no internet at all**. XPRS.md §25.2.2:

```
->  t:command cmd:file file:<ref> [off:]   (advert channel: XPRS, 250 B)
<-  t:result  code:202
    FILE_OFFER / ACCEPT / CHUNK / WIN_ACK / DONE / OK   (bulk lane: MSP)
<-  t:result  code:200
```

The XPRS packets open and close it; **MSP over a short auto-paired GATT session
carries the bytes**. Nothing is bonded — the characteristics are plain and
there is no `createBond()` anywhere (`ble5.md` §9.2).

Reply codes are §25.1's: `404` not held · `403` too large, naming the size ·
`429` over budget · `202` coming · `200` **only after the receiver has hashed
what it holds**. The final receipt is a statement about content, not about
transmission.

Two behaviours that are not optional here:

- **The ask re-airs every 45 s until answered.** The advert channel is
  fire-and-forget on a radio that transmits five seconds a minute; a `cmd:file`
  sent once is lost often enough that a six-minute attempt once ended with the
  holder's counter still at zero. The *same wire* is republished so `ts:` and
  the §5 identifier hold and the answer still correlates.
- **Resume is by offset.** MSP ends a session politely at 300 s and the
  receiver's `.part` length **is** the resume offset. A 56 MB APK crosses in
  several sessions, resuming to the byte.

**Measured**: 56,830,760 bytes, C61 → TANK2, TANK2 offline throughout, five
sessions, sha-verified on arrival. Sustained **7–19 kB/s** — plan for ~10 kB/s
and about an hour and a half for a per-ABI APK.

### 5.2 Over Reticulum

`fetchContentAddressed(sha)` — the DHT resolves providers by the same digest.
Any device that mirrored the artifact answers. Used when the phone has a
Reticulum path (internet, LAN, or a hub).

### 5.3 Over HTTPS

The URL in the feed, via DownloadManager. In normal operation only the mirror
uses this; it is the fallback for a device that has internet but no mesh.

---

## 6. Installing

`UpdateNative.apply` hands the APK to the system package installer through a
FileProvider URI. It needs `REQUEST_INSTALL_PACKAGES`, and on API ≥ O the app
must be allowed to install unknown apps — `canInstall()` reports it and
`openInstallSettings()` takes the user there.

The artifact is verified before the installer ever sees it: size and sha256
against the feed, hashed in chunks off the UI isolate.

**The F-Droid variant does none of this.** Build with
`--dart-define=SELF_UPDATE=false` and every check, download and install
short-circuits and the Updates panel hides itself — F-Droid builds from source
and is the only updater for what it ships. Such a build also refuses to act as
a mirror.

---

## 7. The versionCode trap

`versionCode` is `git rev-list --count HEAD` **plus a per-ABI offset** that
`--split-per-abi` adds, so one release ships several:

| artifact | versionCode for build 109 |
|---|---|
| universal `xprs-<v>.apk` | 109 |
| `-android-armeabi-v7a.apk` | 1109 |
| `-android-arm64-v8a.apk` | 2109 |
| `-android-x86_64.apk` | 4109 |

`fetch-depth: 0` is required in every CI job, because a shallow clone counts 1 —
which is how v1.1.0 shipped versionCode 1.

**Nothing compares versionCode when deciding what is newer.** It only decides
whether Android will install what was offered, and Android refuses anything not
strictly greater. So a device carrying a hand-passed build number
(`--build-number=994039`, as both bench phones did) will **detect every future
release and install none of them**, with no in-app symptom: the download
succeeds and the installer declines. `adb install -d` does not rescue it — the
downgrade flag applies only to debuggable builds. Such a device has to be
uninstalled and reinstalled once.

Do not hand large build numbers to `launch-android.sh` on a phone you intend to
keep updating.

---

## 8. Driving and checking it by API

No screenshots required. Over `adb forward tcp:3499 tcp:3456`:

| | |
|---|---|
| `GET /api/update/status` | the whole read-only picture: version, buildNumber, betaEnabled, feedBase, stable/beta/selected, `updateAvailable`, progress, `source`, canInstall, error |
| `POST /api/update/check` | run a check now (has a side effect; status does not) |
| `POST /api/update/config` | `{"betaEnabled":true}`, `{"feedBase":"…"}` — aim a device at a staging feed |
| `POST /api/update/download` | fetch the selected release |
| `POST /api/update/install` | apply it |
| `GET /api/update/mirror` | what this station holds and seeds |
| `POST /api/update/mirror/config` | `{"enabled":true}` — be a mirror |
| `GET /api/xprs/files` | the `cmd:file` server, the fetch, and the bulk spool (with `have` = bytes on disk = the resume offset) |
| `POST /api/xprs/hold` | `{"path":…,"sha256":…}` — offer one file by digest |
| `POST /api/xprs/file` | `{"from":"X3ARK","sha256":…}` — ask for one and wait |

`source` is `xprs`, `reticulum` or `https` — that is how you prove the bytes did
not come off the web.

---

## 9. What is validated, and what is not

**Validated on hardware (2026-08-26):**

- the feed live at xprs.dev with sha256 per artifact;
- a phone detecting a newer beta — `updateAvailable: true`;
- the mirror pulling both channels (10 artifacts, 456 MB), verifying every
  digest, and seeding them;
- `cmd:file` answered `202` and the whole 56 MB APK crossing to a phone with no
  internet, sha-verified, over five resumed sessions;
- nothing bonded at any point.

**Also validated (2026-08-27), with TANK2 offline and only Bluetooth:**

Chat crosses all three conversation kinds to a phone with no internet.

| kind | direction | result |
|---|---|---|
| Local chat (`#LOCAL`) | TANK2 → C61 | arrived in **27 s**, `bearer: ble`, signed |
| Local chat (`#LOCAL`) | C61 → TANK2 | arrived, `bearer: ble` |
| Global chat (`#GLOBAL`) | C61 → TANK2 | arrived over BLE |
| 1:1 DM (LXMF) | both ways | arrived; the reverse took ~10 min (see below) |

**Why a DM to an offline phone takes minutes.** C61 held a path to TANK2's LXMF
destination `via tcp:use.inertia.chat:4242`, **18 hops**, refreshed 3 seconds
ago — an internet route to a phone with no internet, while `ble5` sat in the
interface list one hop away. That is the stale-pin signature
`reticulum-connections.md` describes: *a `via` naming a medium the peer cannot
be on*. Public hubs keep re-announcing the dead route, so it always looks fresh.

The recovery works and is already wired: a failed delivery calls `pathFailed`,
which drops the route and re-asks —

```
path 0f0871bc via tcp:rns.wisco.network:4242 (12 hops) dropped after failure: lxmf delivery
retry 2 delivered to 0f0871bc over a direct link
```

— but it must fail on each stale hub route in turn before the Bluetooth peer in
the same room wins. **Nothing is broken; the ordering is what costs the
minutes.** Local chat does not suffer this because an XPRS packet is aired on
every bearer rather than routed.

One diagnostic trap worth recording: LXMF-delivered messages land in the chat
store, **not** in the XPRS archive, so `/api/xprs/history` shows nothing and
`/api/rns/inbox` is empty once the wapp has drained it. The conversation list is
the place to look.

**Not yet validated:**

- the in-app **install** of an update that arrived over the mesh (the bench
  phones carry hand-built versionCodes; see §7);
- a second phone fetching from a mirror that is itself a phone, over Reticulum
  rather than Bluetooth;
- the mirror surviving a multi-day soak and its 5+5 retention actually pruning.

**Known limits:**

- Two phones can lose sight of each other for tens of minutes even in the same
  room (`mesh.md` §14.5) — a continuously-advertising ESP32 does not have this
  problem, a five-seconds-a-minute phone does.
- The ESP32 does not participate: it goes deaf during an MSP session, and
  GATT-based file transfer there is deliberately out of scope.
- `XPRS.md` §37's status table still says `cmd:file` is "specified, not
  implemented". It is implemented; that file is byte-identical to the spec repo
  and the correction belongs there.
