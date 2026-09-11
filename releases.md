# Releases & distribution

How XPRS ships updates, and how the wapp store gets its catalog.

The guiding constraint: **the running app never depends on github.com.** There
is not one github.com string in `lib/`. What the app knows is a feed on
**https://xprs.dev** and, for the bytes, a sha256. The Android APKs are
reproducible builds that F-Droid ships as they are (`docs/f-droid.md`).

---

## 1. The shape: the web announces, Reticulum carries

```
  xprs-dev/app                              xprs-dev/wapps
        │  release.yml on tag vX.Y.Z               │ build-archive.sh commits binaries/
        │   android in F-Droid's buildserver       │
        │   image (signed, reproducible),          │
        │   linux, windows                         │
        │   attach as GitHub RELEASE ASSETS        │
        ▼                                          │
  Release assets (never committed to git) ──► F-Droid compares its own build
        │                                          │
        │ xprs-dev/downloads · publish.yml         │
        │  (cron hourly + manual) deploys the      │
        │  files as a Pages artifact               │
        ▼                                          │
  https://xprs.dev/downloads/<tag>/…               │
        │                                          ▼
        └──────────────┬──────────────────── wapps/binaries/
                       │ xprs-dev.github.io · sync.yml (cron 3h + manual)
                       │  • wait until the files are on xprs.dev/downloads
                       │  • hash each artifact
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

**No binaries are ever committed, anywhere.** The website repo holds three
static files and two JSON documents, and that is all it will ever hold: its git
history does not grow by 230 MB a release. `xprs-dev/downloads` serves the
current release's files, but deploys them to Pages as an artifact on each run;
its git holds a workflow and `tags.txt`.

### Three lanes, one digest

The sha256 in the feed is the address on every one of them, so a phone that has
read the feed can take whichever lane it can reach:

| lane | when | cost |
|---|---|---|
| **XPRS + the bulk lane** | a station is in Bluetooth range | ~10 kB/s measured phone-to-phone: a 56 MB APK took five resumed sessions. Resumes to the byte |
| **Reticulum** | the device has a Reticulum path | fast; the internet overlay |
| **HTTPS** | neither, and the device has internet | the URL in the feed, on xprs.dev/downloads; only the mirror normally uses it |

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
```

There is no universal APK since the reproducible builds (v1.2.17): F-Droid
builds one APK per ABI, and so does the release.

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

`release.sh` bumps `pubspec.yaml`, regenerates `lib/version.dart`, pins
`../reticulum-dart` and `../wapps` by commit (`.reticulum-dart-commit`,
`.wapps-commit`; both must be pushed), adds the F-Droid changelog copies,
commits, tags and pushes. Pushing the tag is what triggers everything else.

1. **`release.yml`** (this repo, on `v*`) builds the three platforms and
   attaches the artifacts to a GitHub Release. `prerelease` is set when the tag
   contains a `-`. Nothing is committed. Android is built by fdroidserver in
   F-Droid's buildserver image, signed with the release key, and checked with
   F-Droid's own `verify_apks` (`docs/f-droid.md` §5).
2. **`publish.yml`** (`xprs-dev/downloads`, hourly or manual) serves the newest
   release and the newest stable one on `https://xprs.dev/downloads/<tag>/`.
3. **`sync.yml`** (the site repo, cron every 3 h or manual) resolves the same
   two releases, waits until their files are on xprs.dev/downloads, hashes
   them, and commits the two JSON documents, with URLs on xprs.dev/downloads.
   It skips when the feed is already current, so the cron does not produce an
   empty commit every three hours.
4. **A super-archiver with the mirror enabled** picks the release up within six
   hours and seeds it.
5. **Every other phone** sees it at its next check and fetches over Reticulum.
   A phone with "Updates only from F-Droid" on waits for F-Droid instead.

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

Each per-ABI APK's `versionCode` is an ABI digit x 1,000,000 plus the build
number N, the `+N` that `release.sh` writes into `pubspec.yaml` (the commit
count). `android/app/build.gradle.kts` sets it, and F-Droid's recipe derives the
same numbers (`VercodeOperation`):

| artifact | versionCode for build 362 |
|---|---|
| `-android-armeabi-v7a.apk` | 1000362 |
| `-android-arm64-v8a.apk` | 2000362 |
| `-android-x86_64.apk` | 4000362 |

Until v1.2.16 it was Flutter's digit x 1,000 + N (2358 for arm64 at v1.2.16),
which would have collided across ABIs once N reached 1,000; every code released
that way is below its successor. Tag builds use N as `pubspec.yaml` has it;
CI no longer rewrites it. Note `buildNumber` in `/api/update/status` is N, not
the installed versionCode: `adb shell dumpsys package com.xprs.app | grep
versionCode` is the number Android actually compares.

Nothing compares it. "Is this newer?" is decided by the version **name**, by
`compareSemver`. `versionCode` only decides whether Android will *install*
what was offered — and it refuses anything not strictly greater.

So a device carrying a hand-built APK with a larger versionCode (the bench
phones carried 1095002 in September 2026) will **detect** every future release
and be unable to install one until the release's code passes it. There is no
in-app symptom: the download succeeds and the installer declines. `adb install
-d` does not rescue it either -- the downgrade flag only applies to debuggable
builds, and a release build refuses. A phone in that state has to be
uninstalled and reinstalled. An arm64 release is 2,000,000 + N, so a hand-passed
`--build-number` far above the commit count keeps a phone off the release track.

The other thing Android compares is the **signature**. Until v1.2.16 each
release was signed by the CI runner's throwaway debug key, so no release could
update the one before it; every phone had to reinstall. From v1.2.17 on, every
release, and F-Droid's copy of it, carries the XPRS release key
(`docs/f-droid.md` §5).

---

## 7. Checking a device without a screenshot

The local API answers the whole question read-only, with no side effect:

```sh
adb forward tcp:3499 tcp:3456
curl -s localhost:3499/api/update/status | jq
```

```
currentVersion, buildNumber, betaEnabled, autoCheck, fdroidOnly, feedBase,
stable/beta/fdroid/selected, updateAvailable, status, progress,
downloadedPath, source, canInstall, error
```

`source` is `reticulum` or `https` — that is how you prove the bytes did not
come off the web. The rest of the surface:

| | |
|---|---|
| `POST /api/update/check` | run a check now (has a side effect; status does not) |
| `POST /api/update/config` | `{"betaEnabled":true}`, `{"feedBase":"..."}` to aim a device at a staging feed; `{"fdroidOnly":true}` |
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
| `release.yml` | this repo | tag `v*` (or manual: build and sign, publish nothing) | build 3 platforms, Android reproducibly, and attach them as Release assets |
| `build-*.yml` | this repo | push to `main` | build verification only |
| `test.yml` / `arch.yml` | this repo | push, PR | `flutter test`; `dart tool/arch_guard.dart` |
| `publish.yml` | `xprs-dev/downloads` | cron hourly + manual | serve the current release files on xprs.dev/downloads |
| `sync.yml` | site repo | cron 3 h + manual | hash the release artifacts → write the two JSON docs |

---

## 9. Decisions worth keeping

- **One secret: the release key.** `release.yml` signs with the keystore in
  this repo's `ANDROID_KEYSTORE_*` / `ANDROID_KEY_*` secrets (`docs/f-droid.md`
  §5). Everything else reads public repos and writes to itself with its own
  `GITHUB_TOKEN`. Making a source repo private would break that.
- **No repo holds binaries.** Not because of Pages' 100 MB file cap, but
  because git history is forever: committing 230 MB per release would be
  irreversible. `xprs-dev/downloads` deploys the files as a Pages artifact.
- **Not Git LFS.** Pages does not serve LFS-tracked files — they 404.
- **`.nojekyll` is required** at the site root.
- **F-Droid ships our APK, so the updater stays in it.** An install from
  F-Droid defaults to "Updates only from F-Droid": no download, and a newer
  version opens the F-Droid client. `--dart-define=SELF_UPDATE=false` still
  compiles the whole path out (and the mirror with it), for anyone who
  repackages XPRS behind an updater of their own.
- **Runtime is configurable.** Both the feed base and the wapp store source can
  be repointed at runtime, which is how a staging feed is tested.
