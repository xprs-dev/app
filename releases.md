# Releases & distribution

How XPRS ships updates, and how the wapp store gets its catalog.

The guiding constraint: **the running app never depends on github.com.** There
is not one github.com string in `lib/`. What the app knows is a feed on
**https://xprs.dev** and, for the bytes, a sha256.

---

## 1. The shape: the web announces, Reticulum carries

```
  xprs-dev/xprs-flutter                      xprs-dev/wapps
        │  release.yml on tag vX.Y.Z               │ build-archive.sh commits binaries/
        │   build android/linux/windows            │
        │   attach as GitHub RELEASE ASSETS        │
        ▼                                          ▼
  Release assets (never committed to git)      wapps/binaries/
        │                                          │
        └──────────────┬───────────────────────────┘
                       │ xprs-dev.github.io · sync.yml (cron 3h + manual)
                       │  • read the release, hash each artifact
                       │  • write updates/{stable,beta}.json  ← JSON ONLY
                       ▼
              https://xprs.dev/updates/stable.json      (a ~1 KB document)
                       │
        ┌──────────────┴───────────────────────────────┐
        │                                              │
   a super-archiver reads it,               every other phone reads it,
   downloads each artifact ONCE             then fetches the bytes BY SHA256
   over HTTPS, verifies the sha,            over Reticulum from that station
   and seeds it by content address          and never makes an HTTPS request
                                            for a binary at all
```

**No binaries are ever committed to the website repo.** It holds three static
files and two JSON documents, and that is all it will ever hold — Pages is not
asked to serve a 60 MB APK, and its git history does not grow by 230 MB a
release.

### Three lanes, one digest

The sha256 in the feed is the address on every one of them, so a phone that has
read the feed can take whichever lane it can reach:

| lane | when | cost |
|---|---|---|
| **XPRS + the bulk lane** | a station is in Bluetooth range | ~10 kB/s measured phone-to-phone, resumes across sessions |
| **Reticulum** | the device has a Reticulum path | fast; the internet overlay |
| **HTTPS** | neither, and the device has internet | the URL in the feed; only the mirror normally uses it |

The first is the one that works with no internet at all. `cmd:file` on the
advert channel opens it, MSP carries the bytes, and `code:200` closes it once
the receiver has hashed what it holds (XPRS.md §25.2.2). See `docs/ble5.md` §9.

### Why the sha256 is the important field

`folderFetchBytes` ignores the folder id it is given and calls
`fetchContentAddressed(sha)`. A station that mirrors a release publishes a DHT
provider record **keyed on each artifact's sha256** — the very value the feed
already handed every phone. So the feed does not need to name a folder, an
npub, or a station: publishing the hash *is* publishing the location.

The download URL in the feed is used by exactly two parties: the mirror, once
per artifact, and any device that cannot reach a mirror at all.

---

## 2. The feed

`updates/stable.json` and `updates/beta.json`:

```json
{
  "version": "1.2.0-beta.1",
  "tagName": "v1.2.0-beta.1",
  "name": "XPRS 1.2.0-beta.1",
  "body": "release notes (markdown)",
  "publishedAt": "2026-08-26T09:15:04Z",
  "prerelease": true,
  "assets": [
    {
      "name": "xprs-1.2.0-beta.1-android-arm64-v8a.apk",
      "url": "https://…/xprs-1.2.0-beta.1-android-arm64-v8a.apk",
      "size": 56830740,
      "sha256": "ae7acaee…"
    }
  ]
}
```

- Asset `url`s are **absolute**. The feed announces; it hosts nothing.
- `sha256` is required in practice — an artifact without one cannot be fetched
  over Reticulum and cannot be verified after an HTTPS download.
- `beta.json` always points at the newest build; `stable.json` only at
  non-pre-release versions. A stable publish writes BOTH, so beta users get
  stable releases too.
- Written by `tool/publish_release.dart`, which is the **only** implementation
  of this format. `sync.yml` runs that script rather than re-deriving the JSON.

### Wapp catalog — `wapps/index.json`

```json
[{"file":"maps/maps-1.0.1.wapp","id":"tools.xprs.maps","version":"1.0.1","size":13128,"title":"Maps"}]
```

One entry per wapp; `file` resolves against `https://xprs.dev/wapps`.

---

## 3. Artifact names carry the version

```
xprs-<version>-android-arm64-v8a.apk
xprs-<version>-android-armeabi-v7a.apk
xprs-<version>-android-x86_64.apk
xprs-<version>-linux-x64.tar.gz
xprs-<version>-windows-x64-setup.exe
xprs-<version>.apk                     (universal; NOT mirrored — twice the size)
```

`versionFromAssetName()` parses that shape, and the mirror groups files by the
parsed version to decide what to retain. This is not cosmetic: CI once emitted
versionless names like `xprs-android-arm64-v8a.apk`, which parsed as version
`"android-arm64-v8a"` and made the folder path offer a release that did not
exist. `test/update_mirror_test.dart` pins every name the workflow publishes.

---

## 4. Cutting a release

```sh
./release.sh 1.2.0            # stable
./release.sh 1.2.0-beta.1     # beta (pre-release; beta channel only)
./release.sh                  # auto-bump patch, or the prerelease counter
```

`release.sh` bumps `pubspec.yaml`, regenerates `lib/version.dart`, commits,
tags and pushes. Pushing the tag is what triggers everything else.

1. **`release.yml`** (this repo, on `v*`) builds the three platforms and
   attaches the artifacts to a GitHub Release. `prerelease` is set when the tag
   contains a `-`. Nothing is committed.
2. **`sync.yml`** (the site repo, cron every 3 h or manual) resolves the newest
   release and the newest stable one, downloads the artifacts, hashes them, and
   commits the two JSON documents. It skips when the feed is already current, so
   the cron does not produce an empty commit every three hours.
3. **A super-archiver with the mirror enabled** picks the release up within six
   hours and seeds it.
4. **Every other phone** sees it at its next check and fetches over Reticulum.

---

## 5. The mirror

Opt-in, off by default, `update.mirror` (`POST /api/update/mirror/config
{"enabled":true}`). Only an always-on station should say yes.

Per artifact it does not already hold: hand the URL to the system
DownloadManager, poll it, verify size + sha256, then **rename** the file into
the channel directory and ask the folder to rescan. It retains the newest **5
stable** and **5 beta** versions; older files are deleted from the directory,
and the folder differ turns that into signed `rmFile` ops on its own.

Memory is the whole design, because the station is usually the device under the
most pressure (`docs/performance.md` §8.7):

- DownloadManager streams to disk in its own process — no APK in the Dart heap;
- verification hashes in 64 KiB chunks on a worker isolate;
- retention reads **filenames**, never bytes, and never browses the folder to
  count (that would reduce and re-verify the whole signed op-log to learn a
  number — `arch_guard: no-page-fetch-to-count`);
- the move-in is a rename on the same volume, so the differ can never observe a
  half-written APK and sign it.

A file whose version cannot be parsed is never deleted — `.folder.json` holds
the folder's master key, and deleting it would orphan the folder.

---

## 6. The versionCode trap

Android's `versionCode` is `git rev-list --count HEAD` **plus a per-ABI
offset** that `--split-per-abi` adds, so one release ships several:

| artifact | versionCode for build 109 |
|---|---|
| `xprs-<v>.apk` (universal) | 109 |
| `-android-armeabi-v7a.apk` | 1109 |
| `-android-arm64-v8a.apk` | 2109 |
| `-android-x86_64.apk` | 4109 |

`fetch-depth: 0` is required in every job because a shallow clone counts 1 —
which is how v1.1.0 shipped versionCode 1. Note `buildNumber` in
`/api/update/status` is the base number (109), not the installed versionCode:
`adb shell dumpsys package com.xprs.app | grep versionCode` is the number
Android actually compares.

Nothing compares it. "Is this newer?" is decided by the version **name**, by
`compareSemver`. `versionCode` only decides whether Android will *install*
what was offered — and it refuses anything not strictly greater.

So a device carrying a hand-built APK (`--build-number=994039`, as both bench
phones did in August 2026) will **detect** every future release and be unable to
install a single one, because CI stamps ~2100. There is no in-app symptom: the
download succeeds and the installer declines. `adb install -d` does not rescue
it either -- the downgrade flag only applies to debuggable builds, and a release
build refuses. A phone in that state has to be uninstalled and reinstalled. Do not hand-pass large build numbers to
`launch-android.sh` on a device you intend to keep updating.

---

## 7. Checking a device without a screenshot

The local API answers the whole question read-only, with no side effect:

```sh
adb forward tcp:3499 tcp:3456
curl -s localhost:3499/api/update/status | jq
```

```
currentVersion, buildNumber, betaEnabled, autoCheck, feedBase,
stable/beta/selected, updateAvailable, status, progress,
downloadedPath, source, canInstall, error
```

`source` is `reticulum` or `https` — that is how you prove the bytes did not
come off the web. The rest of the surface:

| | |
|---|---|
| `POST /api/update/check` | run a check now (has a side effect; status does not) |
| `POST /api/update/config` | `{"betaEnabled":true}`, `{"feedBase":"…"}` — aim a device at a staging feed |
| `POST /api/update/download` | fetch the selected release |
| `POST /api/update/install` | apply it |
| `GET /api/update/mirror` | what this station holds and seeds |
| `POST /api/update/mirror/config` | `{"enabled":true}` — be a mirror |
| `GET /api/xprs/files` | the `cmd:file` server, the fetch, and the bulk spool |
| `POST /api/xprs/hold` | `{"path":…,"sha256":…}` — offer one file by digest |
| `POST /api/xprs/file` | `{"from":"X3ARK","sha256":…}` — ask for one, and wait |

---

## 8. CI workflows

| Workflow | Repo | Trigger | Does |
|---|---|---|---|
| `release.yml` | this repo | tag `v*` | build 3 platforms → attach as Release assets |
| `build-*.yml` | this repo | push to `main` | build verification only |
| `test.yml` / `arch.yml` | this repo | push, PR | `flutter test`; `dart tool/arch_guard.dart` |
| `sync.yml` | site repo | cron 3 h + manual | hash the release artifacts → write the two JSON docs |

---

## 9. Decisions worth keeping

- **No secrets.** `sync.yml` reads a public repo and commits to itself with its
  own `GITHUB_TOKEN`. Making a source repo private would break that.
- **The site repo holds no binaries.** Not because of Pages' 100 MB file cap
  (though the universal APK exceeds it), but because git history is forever:
  committing 230 MB per release would be irreversible.
- **Not Git LFS.** Pages does not serve LFS-tracked files — they 404.
- **`.nojekyll` is required** at the site root.
- **The self-update path has a compile-time kill switch.** Build the store
  variant with `--dart-define=SELF_UPDATE=false`: F-Droid builds from source and
  is the only updater for what it ships, so every check, download and install
  short-circuits and the Update Center hides itself. A build with the switch off
  also refuses to act as a mirror.
- **Runtime is configurable.** Both the feed base and the wapp store source can
  be repointed at runtime, which is how a staging feed is tested.
