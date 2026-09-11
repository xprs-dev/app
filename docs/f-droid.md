# F-Droid

XPRS is submitted to F-Droid. This document holds everything needed to follow
that submission, answer the maintainers, ship updates through F-Droid, and keep
the app acceptable to it: the links, the review workflow, the recipe, how to
test it locally, and the audit that made the app pass.

## Links

| Link | What it is for |
|---|---|
| https://gitlab.com/fdroid/fdroiddata/-/merge_requests/48456 | **The submission thread** ("New app: XPRS"). The F-Droid maintainers review the app here and post their feedback as comments. Everything in section 3 is about reading and answering it. |
| https://gitlab.com/brito500/fdroiddata/-/tree/com.xprs.app | The source branch of that merge request, on the `brito500` fork of fdroiddata. Pushing a commit to this branch updates the merge request. |
| https://gitlab.com/brito500/fdroiddata/-/pipelines?ref=com.xprs.app | The CI pipelines of that branch: lint, schema, `fdroid build`, and the others. They run on every push. |
| https://gitlab.com/fdroid/fdroiddata | The upstream repository of every F-Droid build recipe. Once merged, the XPRS recipe lives at `metadata/com.xprs.app.yml`. |
| https://f-droid.org/packages/com.xprs.app/ | The XPRS page on F-Droid. It exists only after the merge request is merged and the next F-Droid index is published. |
| https://gitlab.com/fdroid/fdroiddata/-/merge_requests/31380 | The earlier geogram submission (closed without merge). Its review comments are why the XPRS recipe pins Flutter in the repository, uses a commit hash, and turns off the DependencyInfoBlock (section 6). |
| https://f-droid.org/docs/Inclusion_Policy/ | The rules an app must meet: free software throughout, built from source, no proprietary dependencies. |
| https://f-droid.org/docs/Anti-Features/ | The warning tags F-Droid attaches to apps (NonFreeNet, NonFreeDep, Tracking and others). Section 7 is how XPRS avoids them. |
| https://f-droid.org/docs/Build_Metadata_Reference/ | The reference for every field of the recipe (`Builds`, `srclibs`, `rm`, `prebuild`, `UpdateCheckMode` and so on). |
| https://gitlab.com/fdroid/fdroiddata/-/blob/master/CONTRIBUTING.md | How to contribute to fdroiddata, including the merge request templates. |
| https://gitlab.com/fdroid/fdroiddata/-/blob/master/templates/build-flutter.yml | fdroiddata's template for Flutter apps. The reviewers point to it. |
| https://f-droid.org/docs/Reproducible_Builds/ | Reproducible builds: F-Droid would ship the developer's own signature. XPRS declined this for now (section 4). |
| https://gitlab.com/-/user_settings/personal_access_tokens | Where the GitLab token used by section 3 is created and revoked. |
| `fastlane/metadata/android/en-US/` (this repository) | The store listing F-Droid shows: title, short and full description, icon, screenshots, and one changelog per versionCode. F-Droid reads it from the tagged release. |
| `tool/fdroid_scan.py`, `tool/build_bundled_wapps.py` (this repository) | The APK audit scanner, and the script that rebuilds every bundled wasm module from source (sections 5 and 7). |

## 1. What F-Droid is, and why XPRS is there

F-Droid is an app store for Android that carries only free and open source
software. It does not take the developer's APK: it builds every app itself,
from the published source, on its own build servers, from a recipe in the
public fdroiddata repository. It then signs the result and distributes it. An
app that needs proprietary libraries (Google Play Services, Firebase), contains
prebuilt binaries, tracks its users, or depends on non-free network services
is either refused or carries a visible anti-feature warning.

For XPRS this matters twice over. Its users are exactly the people who look for
software that works without Google, without accounts and without a server in
the middle, and many of them install only from F-Droid. And F-Droid's rules are
a useful external check: getting through them forced the app to lose Play
Services, a hidden third-party IP lookup, GitHub downloads at build time and at
run time, proprietary AI presets, a non-free audio codec, and every binary
that could not be rebuilt from source.

F-Droid is the updater for what it ships. The F-Droid build of XPRS therefore
has the in-app self-updater compiled out (`--dart-define=SELF_UPDATE=false`),
and F-Droid signs it with its own key. That APK cannot update a direct-download
install, and the reverse is true too.

## 2. Current state

* **Submitted** 2026-09-10 as fdroiddata !48456, for v1.2.15 (versionCode
  353, commit `bc86ce6caa3991f028616898ac56ee93b46adb9a`).
* **Every pipeline job passed** on the first run: fdroid build, check apk,
  lint, rewritemeta, schema validation, checkupdates, check source code, git
  redirect and tools check scripts.
* **Waiting for review.** As of 2026-09-11 there are no comments, and the "New
  App" label is not set yet (only maintainers can set it).
* The recipe was tested beforehand on F-Droid's own buildserver image
  (section 5), both from local commits and from the published tags.

## 3. Following the review

### 3.1 Reading the maintainers' feedback

The maintainers (for geogram they were `linsui` and `licaon-kter`) comment on
the merge request. GitLab emails every comment to the `brito500` account's
address, maxbrito@pm.me. There are three ways to read the thread.

**In the browser.** Open the merge request link above while logged in as
`brito500`. Logged out, GitLab may hide the discussion.

**From the command line, with the GitLab token.** The token for `brito500`
(scopes `api` and `write_repository`, expiring 2027-09-09) is stored in
`~/.config/gitlab-token`, mode 600. Always read it from the file and never
print it:

```sh
T=$(cat ~/.config/gitlab-token)
MR=https://gitlab.com/api/v4/projects/36528/merge_requests/48456   # 36528 = fdroid/fdroiddata

# State, labels, number of comments, and the latest pipeline:
curl -s -H "PRIVATE-TOKEN: $T" $MR | python3 -c "import json,sys; d=json.load(sys.stdin); \
  print(d['state'], d['labels'], d['user_notes_count'], (d.get('head_pipeline') or {}).get('status'))"

# Every comment, oldest first (system notes are label and status changes):
curl -s -H "PRIVATE-TOKEN: $T" "$MR/notes?sort=asc&per_page=100" | python3 -c "import json,sys; \
  [print(n['author']['username'], n['created_at'][:16], n['body']) for n in json.load(sys.stdin) if not n['system']]"

# Review threads, including comments attached to lines of the recipe and
# "suggestion" blocks, with their resolved state:
curl -s -H "PRIVATE-TOKEN: $T" "$MR/discussions?per_page=100" | python3 -m json.tool | less
```

**The issue bot.** F-Droid's issuebot (https://gitlab.com/fdroid/issuebot)
posts a report on the merge request once a maintainer runs it (the template
says contributors may trigger it manually, but not repeatedly). It lists what
the scanner found and what the app connects to. Read it like any other
comment.

### 3.2 Checking the pipelines

A merge request from a fork runs its CI in the fork:

```sh
P=https://gitlab.com/api/v4/projects/brito500%2Ffdroiddata
curl -s -H "PRIVATE-TOKEN: $T" "$P/pipelines?ref=com.xprs.app&per_page=5" | python3 -c "import json,sys; \
  [print(p['id'], p['status'], p['web_url']) for p in json.load(sys.stdin)]"
curl -s -H "PRIVATE-TOKEN: $T" "$P/pipelines/<id>/jobs" | python3 -c "import json,sys; \
  [print(j['id'], j['name'], j['status']) for j in json.load(sys.stdin)]"
curl -s -H "PRIVATE-TOKEN: $T" "$P/jobs/<job id>/trace" | tail -100    # a job's log
```

The job that matters most is `fdroid build`. It runs the same
`fdroid build --on-server` as section 5.

### 3.3 Answering, and changing the recipe

To reply on a thread, use the browser, or the API:

```sh
curl -s -X POST -H "PRIVATE-TOKEN: $T" --data-urlencode "body=..." \
  "$MR/discussions/<discussion id>/notes"
```

When a maintainer asks for a recipe change, edit the branch and push it; the
merge request updates itself:

```sh
git clone https://gitlab.com/brito500/fdroiddata.git && cd fdroiddata
git remote add upstream https://gitlab.com/fdroid/fdroiddata.git
git checkout com.xprs.app
# edit metadata/com.xprs.app.yml, test it (section 5), then:
git commit -am "com.xprs.app: <what changed>"
git -c credential.helper= \
    -c 'credential.helper=!f() { echo username=oauth2; echo "password=$(cat ~/.config/gitlab-token)"; }; f' \
    push https://gitlab.com/brito500/fdroiddata.git com.xprs.app
```

Commits in the fork are authored as `Max Brito <maxbrito@pm.me>`, the identity
the geogram submission used. Do not rebase the branch unless there is a
conflict (the template asks for this). When a change needs new app code, cut a
release first and point the build entry at the new release commit.

## 4. The merge request, as submitted

The description follows fdroiddata's "App inclusion" template. It is kept in
`~/code/xprs/fdroid-submission/merge-request.md`, next to the patch that adds
the three files. The main points: the author is submitting; everything is built
from source (the Flutter app, the Rust WebAssembly runtime, every bundled wapp
module, and dav1d); there are no Play Services, no DependencyInfoBlock, and no
self-updater; Flutter is pinned in the repository; it lists the network hosts;
and it was tested on the buildserver image.

Two template items were left open on purpose. **Reproducible builds** was
declined for now. That means F-Droid signs XPRS with its own key, and switching
to the developer's signature later is not possible. **Per-ABI APKs** were not
set up: the F-Droid APK is universal (arm64, arm and x86_64, 134 MB). Three
build entries with `--split-per-abi --target-platform ...` and distinct
versionCodes would cut each download to about a third.

## 5. Testing a recipe locally

Test every recipe change before pushing it, exactly the way fdroiddata's CI
does. This caught six failures before the first submission.

```sh
# a shallow clone of fdroiddata, with the recipe and srclibs copied in
git clone --depth 1 https://gitlab.com/fdroid/fdroiddata.git && cd fdroiddata
# the long-lived buildserver container (1.6 GB image)
docker run -d --name fdroidtest --memory=10g --cpus=4 \
    -v $PWD:/fdroiddata -v ~/code/xprs:/xprs:ro \
    registry.gitlab.com/fdroid/fdroidserver:buildserver-trixie sleep infinity
```

Inside the container, as root: source `/etc/profile.d/bsenv.sh`, install
fdroidserver master into `$fdroidserver`
(https://gitlab.com/fdroid/fdroidserver/-/archive/master/fdroidserver-master.tar.gz),
install `sudo` and `openjdk-21-jdk-headless`, copy the recipe to
`/home/vagrant/metadata/`, and chown everything to `vagrant`. Then, as
`vagrant` with `HOME=/home/vagrant`:

```sh
fdroid lint com.xprs.app            # run from /fdroiddata
fdroid rewritemeta com.xprs.app     # normalises the layout; CI checks it
fdroid fetchsrclibs com.xprs.app:<versionCode>
fdroid build --verbose --test --refresh-scanner --on-server --no-tarball com.xprs.app:<versionCode>
```

On this machine, wrap the build in `~/bin/android-build-locked docker exec ...`,
like every heavy build. Give the container a small Gradle heap in
`/home/vagrant/.gradle/gradle.properties`
(`org.gradle.jvmargs=-Xmx1536m`, `org.gradle.workers.max=2`,
`kotlin.compiler.execution.strategy=in-process`), otherwise the host's
earlyoom kills Gradle. That setting is for this laptop, not for the recipe.
Reinstall `sudo` before each run: `--on-server` uninstalls it. Run
`fetchsrclibs` again after deleting `build/com.xprs.app`, or fdroidserver
master fails before it clones the app.

The recipe's `Repo:` and srclib `Repo:` can point at local paths such as
`/xprs/app` to test unpushed commits; lint then complains only that the URLs
are not https. Check the APK it produces with `python3 tool/fdroid_scan.py
<apk>` and `aapt2 dump badging <apk>` (the versionCode, and no
`REQUEST_INSTALL_PACKAGES`).

## 6. The recipe

`metadata/com.xprs.app.yml`, as submitted:

```yaml
Categories:
  - Connectivity
  - Internet
  - Messaging
License: BSD-3-Clause
AuthorName: Max Brito
WebSite: https://xprs.dev
SourceCode: https://github.com/xprs-dev/app
IssueTracker: https://github.com/xprs-dev/app/issues
Changelog: https://github.com/xprs-dev/app/releases

AutoName: XPRS

RepoType: git
Repo: https://github.com/xprs-dev/app.git

Builds:
  - versionName: 1.2.15
    versionCode: 353
    commit: bc86ce6caa3991f028616898ac56ee93b46adb9a
    sudo:
      - apt-get update
      - apt-get install -y make clang-19 lld-19 llvm-19 wasi-libc libclang-rt-19-dev-wasm32
        libc++-19-dev-wasm32 libc++abi-19-dev-wasm32 meson ninja-build python3 rustup
        gcc libc-dev
    output: build/app/outputs/flutter-apk/app-release.apk
    srclibs:
      - flutter@stable
      - xprs-reticulum-dart@5ec49acdb6322cff20f7bf3f7f063c6e619f76fd
      - xprs-wapps@7c14e24a469bddac1edb438f4c5217b90fce6016
      - dav1d@1.4.3
    rm:
      - artwork
      - assets/editor/app-creator/app.wasm
      - desktop
      - ios
      - linux
      - macos
      - web
      - windows
    prebuild:
      - flutterVersion=$(cat .flutter-version)
      - '[[ $flutterVersion ]]'
      - git -C $$flutter$$ checkout -f $flutterVersion
      - cp -r $$xprs-reticulum-dart$$ ../reticulum-dart
      - sed -i -e '/REQUEST_INSTALL_PACKAGES/d' android/app/src/main/AndroidManifest.xml
      - export PUB_CACHE=$(pwd)/.pub-cache
      - $$flutter$$/bin/flutter config --no-analytics
      - $$flutter$$/bin/flutter pub get --enforce-lockfile
    scandelete:
      - .pub-cache
    build:
      - WASI_SYSROOT=/usr WASM_CLANG=clang-19 WASM_CLANGXX=clang++-19 WASM_AR=llvm-ar-19
        DAV1D_SRC=$$dav1d$$ python3 tool/build_bundled_wapps.py $$xprs-wapps$$
      - rustup default 1.89.0
      - rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android
      - export PUB_CACHE=$(pwd)/.pub-cache
      - $$flutter$$/bin/flutter build apk --release --dart-define=SELF_UPDATE=false
    ndk: r28c

AutoUpdateMode: Version
UpdateCheckMode: Tags ^v\d+\.\d+\.\d+$
UpdateCheckData: pubspec.yaml|version:\s.+\+(\d+)|.|version:\s(.+)\+
CurrentVersion: 1.2.15
CurrentVersionCode: 353
```

The two new srclibs, `srclibs/xprs-wapps.yml` and
`srclibs/xprs-reticulum-dart.yml`:

```yaml
RepoType: git
Repo: https://github.com/xprs-dev/wapps.git
```

```yaml
RepoType: git
Repo: https://github.com/xprs-dev/reticulum-dart.git
```

`flutter` and `dav1d` are existing fdroiddata srclibs.

What each part is for, and what taught it:

* **`.flutter-version`** in this repository names the Flutter release F-Droid
  builds with; prebuild checks it out of `flutter@stable`. Bump the file when
  upgrading Flutter. (Geogram review.)
* **`commit:` is the release commit's hash**, not the tag. The tag is how
  `UpdateCheckMode` finds new releases. (Geogram review.)
* **No DependencyInfoBlock.** `android/app/build.gradle.kts` sets
  `dependenciesInfo { includeInApk = false; includeInBundle = false }`.
  Otherwise the Android Gradle plugin adds a signing block that lists the
  dependencies, encrypted with Google's public key. (Geogram review.)
* **The self-updater is compiled out** by `--dart-define=SELF_UPDATE=false`.
  Its permission `REQUEST_INSTALL_PACKAGES` is deleted by `sed`, so it must
  stay on one line of the manifest, and no comment near it may contain the
  word.
* **reticulum-dart is copied next to the app**, because `pubspec.yaml`
  depends on it by path. `$$srclib$$` expands to an absolute path.
* **The scanner refuses any WebAssembly file** in the source tree, and it runs
  after `prebuild`. The committed App Creator module is therefore deleted with
  `rm:`, and every bundled wapp module is rebuilt in `build:`, after the scan,
  by `tool/build_bundled_wapps.py` with Debian's clang and wasi-libc. The
  modules inside `.wapp` packages (zip files) are not flagged, and the same
  step replaces them.
* **`gcc` and `libc-dev`** are needed because cargo compiles its build scripts
  for the host.
* **Rust** comes from Debian's `rustup` package, pinned to 1.89.0 (the
  version the wasm_run lockfiles were resolved for). The Gradle task
  `cargoBuildWasmRun` compiles `libwasm_run_dart.so` for the three ABIs.

## 7. Releasing through F-Droid

Once the merge request is merged, F-Droid's `checkupdates` looks for new tags
matching `^v\d+\.\d+\.\d+$`, reads the versionCode from `pubspec.yaml` at
the tag, and adds a build entry by copying the last one with the new version
and commit. `release.sh` already does what that needs: it tags `vX.Y.Z` and
writes `version: X.Y.Z+<commit count>` into `pubspec.yaml`, so the versionCode
always rises.

For each release:

1. Add `fastlane/metadata/android/en-US/changelogs/<versionCode>.txt` (500
   characters at most) **before** running `release.sh`. The versionCode is
   the commit count including that commit, so the file is named
   `$(( $(git rev-list --count HEAD) + 1 )).txt`.
2. Keep `.flutter-version` equal to the Flutter the app builds with.
3. Run `python3 tool/fdroid_scan.py` on a `SELF_UPDATE=false` build, and
   `python3 tool/build_bundled_wapps.py ../wapps --check` (every bundled
   module must match its source build). See section 8.

**The one limit of auto-update: the srclib pins do not move.** A new build
entry keeps `xprs-reticulum-dart@<commit>` and `xprs-wapps@<commit>` from the
previous one. So whenever a release needs newer reticulum-dart code (it is a
path dependency, so the build would not compile against the old pin), or
bundles wapps built from a newer wapps commit, open an update merge request in
fdroiddata that raises those two pins. Otherwise the F-Droid build fails, or
it ships modules that do not match the bundled manifests. Two ways to remove
this chore, neither done yet:

* Record the wapps and reticulum-dart commits in this repository (for example
  `.wapps-commit` and `.reticulum-dart-commit`) and have prebuild
  `git -C $$xprs-wapps$$ checkout -f $(cat .wapps-commit)`, the same way
  `.flutter-version` works.
* Make both repositories git submodules of this one, as fdroiddata's template
  suggests (`submodules: true`), and copy them into place in prebuild.

## 8. The audit behind the submission

Every network host the Android binary can reach, and every non-free piece
inside it. The audit scans the **built APK**, not the source: constants that
survive into `libapp.so`, and blobs that dependencies bring in, never show up
in a search over `lib/`. Both cases occurred here, twice.

```sh
~/bin/android-build-locked flutter build apk --release --split-per-abi \
    --dart-define=SELF_UPDATE=false
python3 tool/fdroid_scan.py build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
```

`tool/fdroid_scan.py` lists URL hosts in every file (inside every bundled
`.wapp` too), bare `host:port` names in `libapp.so` and the wapps, the native
libraries, and any `github.com` URL. It exits 1 on proprietary classes in the
dex (Play Services, Firebase, ML Kit, ...) or a native executable inside a
wapp. `test/bundled_wapps_no_executables_test.dart` keeps native executables
out of `assets/wapps/` in CI.

### 8.1 What was fixed

**Google Play Services, removed (was `NonFreeDep`).** `geolocator_android`
depended on `com.google.android.gms:play-services-location`, the only Google
Play code in the APK. It is vendored in `third_party/geolocator_android`
without its Fused client and without the dependency; location comes from the
platform `LocationManager`. See `third_party/geolocator_android/README.xprs.md`.

**`api.ipify.org`, removed.** The vendored BitTorrent engine
(`third_party/dtorrent_task_v2`) asked `api.ipify.org` for the device's public
IP every time a torrent or a metadata download started, telling a third party,
unprompted, that this address runs a torrent client. Trackers and the peers'
extended handshake (`yourip`) already report the address, so the lookup and
the `dart_ipify` dependency are gone.

**`libwasm_run_dart.so` is built from source, with no GitHub download.**
`wasm_run_flutter` registered `WasmRunFlutterNative.registerWith()` at every
app start, and whenever the bundled library failed to load it downloaded a
prebuilt library from `github.com/juancastillo0/wasm_run/releases` and loaded
it. Separately, the Android and Linux builds downloaded that prebuilt library
(compiled in 2023 on a macOS CI runner) on every clean build. Now
`third_party/wasm_run` has no downloader, and the vendored
`third_party/wasm_run_flutter` compiles the Rust crate with cargo (a Gradle
task per ABI on Android, a CMake target on Linux), pinned to the versions
upstream shipped: wasmtime 14.0.4 on 64-bit, wasmi 0.31.2 on 32-bit,
flutter_rust_bridge 1.82.4, with committed lockfiles and `--locked`. The
exported symbols match the old library exactly, and the arm64 build is now
16 KB page-aligned. See `third_party/wasm_run_flutter/README.xprs.md`.

**The AI Robot is gone from the core.** The wapp editor's Robot tab carried
presets for `api.openai.com`, `api.anthropic.com` and `api.deepseek.com`. AI
has no place in the core app; a wapp can offer it, installed by the user's
choice. `lib/ai/`, the Robot screen, `HttpTransport.postStream` and the stored
`ai.*` preferences (a plaintext API key among them) are deleted.

**mp4player's desktop binaries are out of the APK.** The bundled
`mp4player.wapp` carried static ffmpeg for Linux and Windows (21 MB of
executables a phone can never run) and its whole `vendor/` tree. The full
package now lives in `desktop/wapps/`, installed only by the Linux and Windows
bundles; `assets/wapps/` carries the same release without `bin/` and
`vendor/`.

**Every bundled wasm module builds from source.** `tool/build_bundled_wapps.py
<wapps-checkout>` rebuilds each `app.wasm` and `tests.wasm` from
`xprs-dev/wapps` and swaps it into its package; `--check` only compares. A
clean wasi-sdk build reproduces every bundled module byte for byte (after
fixing `functionalities`, which shipped the Tester's module with no source, a
stale pre-rename App Creator build, and FDK-AAC's build-date stamps, now
pinned with `SOURCE_DATE_EPOCH`). The wapps' `sdk/toolchain.mk` also accepts
Debian's clang and wasi-libc (`WASI_SYSROOT=/usr`), and mp4player's dav1d is
compiled from dav1d 1.4.3 source (`make dav1d DAV1D_SRC=...`). On Debian
trixie, all 17 modules and dav1d build and reproduce themselves byte for byte.
bookworm's wasi-libc is too old for mp4player.

**FDK-AAC replaced by Android's PacketVideo decoder (Apache-2.0).** FDK-AAC's
licence grants no patent rights; Fedora classifies it as not allowed and
Debian keeps it out of main. mp4player now decodes AAC-LC, HE-AAC and HE-AACv2
with the decoder Android shipped before FDK (AOSP `android-4.1.2_r2.1`). It
needs `-fno-strict-aliasing` (without it clang's wasm output is garbage) and
one patch so Parametric Stereo does not assume 32-bit pointers. On 21 streams
it matches fdk-aac 2.0.3 at 64-75 dB SNR. The one loss is AAC with more than
two channels (5.1), which now plays without sound. Every `.wapp` carries
`licenses/` with the notices of the code linked into it. See
`mp4player/vendor/pvaac/README.xprs.md` in the wapps repository.

**One licence: BSD-3-Clause**, copyright "Max Brito and XPRS contributors", in
every XPRS repository. The app and wapps had none, which F-Droid would have
refused. Vendored third-party code keeps its own licence, listed in each
README.

**Earlier rounds:** `mobile_scanner` (ML Kit, with a proprietary native
library) was removed with the CAMERA permission; the default map tiles moved
from Esri's `server.arcgisonline.com` to `tile.openstreetmap.org`; and
`install.wapp` no longer rewrites `github.com` URLs (the default catalog is a
Reticulum address).

### 8.2 Hosts that remain

**Contacted with no user action** (a fresh install, default settings, after a
profile is created; before that the app opens no sockets at all):

| Host | Purpose |
|---|---|
| `rns.wisco.network`, `rns.birdsnet.com.br`, `sydney.reticulum.au`, `use.inertia.chat` (all `:4242`) | Community Reticulum TCP hubs, tried in order until one answers. Editable in Settings; `rns.autoStart` turns the node off. |

Watched for 100 seconds after creating a profile, the desktop build opened only
a UDP listener on port 4242 (the LAN transport). NOSTR is off by default
(`nostr.enabled`), I2P is off (`i2p.enabled`), and the update feed is compiled
out of the F-Droid build.

**Contacted when the user uses a feature:**

| Host | When |
|---|---|
| `tile.openstreetmap.org`, `nominatim.openstreetmap.org` | A map is shown, or a place is searched. |
| `router.bittorrent.com`, `router.utorrent.com`, `dht.transmissionbt.com` (`:6881`) | DHT bootstrap, when a torrent starts. |
| `tracker.opentrackr.org`, `open.demonii.com`, `exodus.desync.com`, `tracker.torrent.eu.org` | Default open trackers added to a torrent. |
| `blossom.primal.net`, `nostr.download` | Blossom blob servers: a picture or file attached to an outgoing message is uploaded there, so a recipient on another network can fetch it. Not gated by the NOSTR switch. |
| `relay.damus.io`, `nos.lol`, `relay.nostr.band`, `relay.primal.net`, `purplepag.es` | NOSTR relays, only if the user turns NOSTR on. |
| `reseed.i2p-projekt.de`, `reseed.stormycloud.org`, `reseed.diva.exchange`, `banana.incognet.io`, `i2pseed.creativecowpat.net`, `reseed-fr.i2pd.xyz`, `reseed.onion.im` | Standard I2P reseeds, only if the user turns I2P on. |
| `ice1.somafm.com` (in `mp4player.wapp`) | Three seeded demo radio streams, over plain http. |

**Never contacted by the F-Droid build:** `xprs.dev`, the self-updater's feed.
xprs.dev is served by GitHub Pages and the feed's APK links point to GitHub
releases, so the direct-download build does reach GitHub, and the F-Droid
build never does. The `https://xprs.dev/circle/...` deep link is an intent
filter, not a request.

**A question a reviewer may ask:** the Reticulum hubs run the Python
reference implementation, whose "Reticulum License" is MIT with added use
restrictions, not an OSI licence. XPRS speaks the protocol with its own Dart
implementation (`reticulum-dart`), and every hub is replaceable in Settings.

### 8.3 Strings that are not network calls

| String | Where | Why it is inert |
|---|---|---|
| `github.com/flutter/flutter/issues`, `github.com/dart-lang/sdk/...` | `libflutter.so` | Engine error text |
| `github.com/Baseflow/flutter-permission-handler/issues`, `github.com/flutter/flutter/issues/165510` | `classes.dex` | Exception messages |
| `github.com/bytecodealliance/wasmtime/issues/...` | `libwasm_run_dart.so` | wasmtime panic text, compiled from source |
| `github.com`, `raw.githubusercontent.com` | `install.wapp:main.c` | A comment recording that the rewriter is gone |
| `schemas.android.com`, `www.w3.org`, `www.apache.org`, `android.googlesource.com`, `developers.google.com/tink`, `issuetracker.google.com`, `docs.flutter.dev`, `dartbug.com`, `youtrack.jetbrains.com`, `bytecodealliance.org`, `docs.rs` | toolchain and runtime | XML namespaces, licence headers and documentation links |
| `blossom.example.com`, `relay.example.com`, `rns.example.net`, `yourdomain.com` | `libapp.so`, `mail.wapp` | Placeholder hints in text fields |

The dex is free of Firebase, Play Services, Google Analytics, Crashlytics and
any advertising or tracking SDK. `com.google.crypto.tink` (Apache-2.0, pulled
in by `flutter_secure_storage`) is free software. The native libraries are
`libapp.so`, `libflutter.so`, `libwasm_run_dart.so` (built from source),
`libsqlcipher.so` (`net.zetetic:sqlcipher-android` from Maven Central, BSD),
`libdartjni.so` and `libdatastore_shared_counter.so` (AndroidX).

### 8.4 Permissions worth explaining

`INTERNET`, `ACCESS_NETWORK_STATE`, `BLUETOOTH_*` and `ACCESS_FINE_LOCATION`
(the BLE mesh: Android ties BLE scanning to location, and `BLUETOOTH_SCAN` is
declared `neverForLocation`), `READ/WRITE/MANAGE_EXTERNAL_STORAGE` (identity
backup and shared files), `FOREGROUND_SERVICE*` (the mesh and Reticulum node
must survive screen-off), `RECEIVE_BOOT_COMPLETED` (restart the node after a
reboot), `NEARBY_WIFI_DEVICES` and the Wi-Fi state permissions (the LAN
transport), and `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` (the node is a
long-running relay). `REQUEST_INSTALL_PACKAGES` is removed from the F-Droid
build.
