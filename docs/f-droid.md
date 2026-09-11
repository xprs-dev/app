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
| https://gitlab.com/fdroid/fdroiddata/-/merge_requests/31380 | The earlier geogram submission (closed without merge). Its review comments are why the XPRS recipe pins Flutter in the repository, uses a commit hash, and turns off the DependencyInfoBlock (section 7). |
| https://f-droid.org/docs/Inclusion_Policy/ | The rules an app must meet: free software throughout, built from source, no proprietary dependencies. |
| https://f-droid.org/docs/Anti-Features/ | The warning tags F-Droid attaches to apps (NonFreeNet, NonFreeDep, Tracking and others). Section 9 is how XPRS avoids them. |
| https://f-droid.org/docs/Build_Metadata_Reference/ | The reference for every field of the recipe (`Builds`, `srclibs`, `rm`, `prebuild`, `UpdateCheckMode` and so on). |
| https://gitlab.com/fdroid/fdroiddata/-/blob/master/CONTRIBUTING.md | How to contribute to fdroiddata, including the merge request templates. |
| https://gitlab.com/fdroid/fdroiddata/-/blob/master/templates/build-flutter.yml | fdroiddata's template for Flutter apps. The reviewers point to it. |
| https://f-droid.org/docs/Reproducible_Builds/ | Reproducible builds: F-Droid rebuilds the app and ships the developer's own signed APK when the two match. XPRS uses them (section 5). |
| https://f-droid.org/api/v1/packages/com.xprs.app | F-Droid's index entry for XPRS: the versions it publishes. The app reads it when "Updates only from F-Droid" is on. |
| https://xprs.dev/downloads/ | The current release files, served by the `xprs-dev/downloads` repository (GitHub Pages, deployed as an artifact, no binaries in git). The update feed's URLs point here, never at github.com. |
| https://github.com/xprs-dev/downloads | That repository. Its hourly `publish.yml` copies the newest stable and newest release's files from the GitHub releases. |
| https://gitlab.com/-/user_settings/personal_access_tokens | Where the GitLab token used by section 3 is created and revoked. |
| `fdroid/` (this repository) | The recipe as a template (`com.xprs.app.yml`), the XPRS srclibs, and `buildserver-build.sh`, which builds an APK the way F-Droid does. `tool/fdroid_recipe.py` renders the recipe for a release (section 7). |
| `fastlane/metadata/android/en-US/` (this repository) | The store listing F-Droid shows: title, short and full description, icon, screenshots, and one changelog per versionCode. F-Droid reads it from the tagged release. |
| `tool/fdroid_scan.py`, `tool/build_bundled_wapps.py` (this repository) | The APK audit scanner, and the script that rebuilds every bundled wasm module from source (sections 8 and 9). |

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

XPRS is a **reproducible build** on F-Droid. F-Droid still builds every APK
itself, but it then compares its build with the APK of the same version in our
GitHub release, and when the two are identical apart from the signature it
publishes ours, signed with the XPRS release key. So F-Droid, xprs.dev and the
in-app updater all hand out the very same APKs, and a phone can move between
them in either direction without reinstalling (which would lose its identity).

The in-app updater stays in every build, F-Droid's included, with its
`REQUEST_INSTALL_PACKAGES` permission. XPRS is multiplatform: the updater is
how Windows, Linux and non-F-Droid Android installs get new versions, and how a
phone updates from a nearby station or an always-on archiver over Reticulum
with no internet at all. What F-Droid installs is told apart at run time
instead: **"Updates only from F-Droid"** (Settings, Updates) is on by default
when an F-Droid client installed the app. With it on, XPRS never downloads
itself; it asks F-Droid's index which version it publishes and, when that is
newer, opens the F-Droid client on XPRS to install it. For geogram, F-Droid's
only objection to the updater was downloading binaries from github.com; the
update feed's files are on xprs.dev/downloads.

## 2. Current state

* **Submitted** 2026-09-10 as fdroiddata !48456, for v1.2.15 (versionCode
  353, commit `bc86ce6caa3991f028616898ac56ee93b46adb9a`), as one universal
  APK with the self-updater compiled out. Every pipeline job passed on the
  first run.
* **2026-09-11:** the merge request carries the "New App" and
  "waiting-for-upstream" labels, and `licaon-kter` asked why reproducible
  builds were declined. They are now in
  place (section 5): the release pipeline builds in F-Droid's buildserver
  image, the release key exists, and the recipe has one build per ABI with
  `binary:` and `AllowedAPKSigningKeys`.
* **Next:** cut the first release built this way (v1.2.17), render the recipe
  for it (section 7), push it to the merge request branch, let its `fdroid
  build` job verify our APKs, and then answer the question on the thread.

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
`fdroid build --on-server` as section 6.

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
# edit metadata/com.xprs.app.yml, test it (section 6), then:
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

The description follows fdroiddata's "App inclusion" template and lives on
the merge request itself; the three files it adds are the recipe and srclibs in
section 7, on the fork's `com.xprs.app` branch. (GitLab drops quick actions such
as `/label` from a description created through the API, and only maintainers
can set labels anyway.) The main points: the author is submitting; everything is built
from source (the Flutter app, the Rust WebAssembly runtime, every bundled wapp
module, and dav1d); there are no Play Services, no DependencyInfoBlock, and no
self-updater; Flutter is pinned in the repository; it lists the network hosts;
and it was tested on the buildserver image.

Two template items were left open at first. **Reproducible builds** was
declined, and `licaon-kter` asked why on 2026-09-11. The answer was to adopt
them (section 5), which also settled the second item, **per-ABI APKs**: the
first submission built one universal APK (arm64, arm and x86_64, 134 MB), the
reproducible recipe builds one APK per ABI, about 45 MB each.

## 5. Reproducible builds and the release key

**What F-Droid does.** For each build entry, F-Droid runs the recipe on its
buildserver, downloads the APK the entry's `binary:` URL names (our GitHub
release asset), and calls `common.verify_apks`: it strips any signature from
its own build, copies our APK's signature onto it with apksigcopier, and runs
apksigner on the result. If that verifies, the two APKs are the same bytes, and
F-Droid publishes ours. The certificate must also be the one
`AllowedAPKSigningKeys` names. A mismatch fails the build, and that version is
not published until it is fixed.

**How our APKs are made to match.** Not by imitating F-Droid's environment,
but by using it. `release.yml` builds each Android APK inside F-Droid's
buildserver image (`registry.gitlab.com/fdroid/fdroidserver:buildserver-trixie`)
with fdroidserver itself, from the recipe `tool/fdroid_recipe.py` renders for
the release commit: `fdroid/buildserver-build.sh` repeats the steps of the
`fdroid build` job in fdroiddata's `.gitlab-ci.yml`. The app is therefore
cloned and built by the same tool, as the same user, at the same path
(`/home/vagrant/build/com.xprs.app`), with the same Debian packages, Flutter,
NDK and Rust as F-Droid's own build. The script then signs the APK with
apksigner and runs F-Droid's `verify_apks` on the pair before the release gets
it.

What else had to line up:

* **The same sources.** `pubspec.yaml` depends on `../reticulum-dart` by path,
  and the bundled wapps are rebuilt from `xprs-dev/wapps`. `release.sh` pins
  both by commit in the release itself (`.reticulum-dart-commit`,
  `.wapps-commit`), and the recipe checks those commits out. It refuses to
  release while a sibling repository's HEAD is not on its `origin/main`.
* **The same version.** Tag builds keep the `+N` `release.sh` wrote into
  `pubspec.yaml`. (CI used to rewrite it to the commit count, which was one
  more.)
* **One versionCode scheme everywhere.** Each per-ABI APK is ABI digit x
  1,000,000 + N: armeabi-v7a 1, arm64-v8a 2, x86_64 4
  (`android/app/build.gradle.kts`, and `VercodeOperation` in the recipe).
  Flutter's own digit x 1,000 + N would collide across ABIs once N reaches
  1,000, about six weeks after this was written.
* **Signing that leaves the layout alone.** `apksigcopier` rebuilds F-Droid's
  APK entry by entry exactly as Gradle wrote it and pastes our signing block
  on. A plain `apksigner sign` re-pads every stored entry and adds a v1 JAR
  signature, and the copied signature then fails even between identical
  builds. The release is signed with `--alignment-preserved
  --v1-signing-enabled false` (minSdk 24 needs no v1).
* **No clock in the output.** Two builds of one commit first differed only
  inside `mp4player.wapp`: `tool/build_bundled_wapps.py` wrote its `licenses/`
  entries with the current time. They now keep their old entry or take
  `SOURCE_DATE_EPOCH`.
* **No reference APK while making it.** A recipe with `binary:` makes `fdroid
  build` download the published APK and compare. The release build is the one
  producing it, so it renders the recipe with `--no-binary`.

**The release key.** Until v1.2.16 every release was signed by the CI
runner's throwaway debug key: the keystore secrets `release.yml` reads were
never set, so each release had a different certificate and none could update
the one before. The XPRS release key was created on 2026-09-11:

* certificate SHA-256
  `2a4b4625895e700839415a81c091d949699167abe03c22794376d18f2f7ec2d2`
  (`AllowedAPKSigningKeys` in the recipe), RSA 4096, valid 10,000 days;
* the keystore is `~/.secrets/xprs/xprs-release.jks` on the developer's
  machine, and its passwords are in
  `~/.secrets/xprs/xprs-release-keystore.secrets.txt` next to it;
* GitHub holds it as the `xprs-dev/app` secrets `ANDROID_KEYSTORE_BASE64`,
  `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS` and `ANDROID_KEY_PASSWORD`.

**Keep an offline backup of both files.** A lost key can never be replaced:
Android refuses an update signed by any other key, and F-Droid pins this
certificate.

**Checking a build by hand.** `release.yml` can be run on any branch
(`gh workflow run release.yml -R xprs-dev/app --ref <branch>`); without a tag it
builds and signs but publishes nothing. Its `commit` input rebuilds an older
commit instead of the branch head. Each ABI's artifact holds the signed APK and,
in `unsigned/`, the build as F-Droid would see it. Two builds of one commit, on
different machines, match when F-Droid's own check passes:

```sh
PYTHONPATH=$fdroidserver python3 -c "import sys, tempfile; \
  from fdroidserver import common; common.config = common.read_config(); \
  print(common.verify_apks(sys.argv[1], sys.argv[2], tempfile.mkdtemp()) or 'identical')" \
  <signed.apk> <other-build-unsigned.apk>
```

## 6. Testing a recipe locally

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

`fdroid/buildserver-build.sh` does the whole build, the same one `release.yml`
runs. Render the recipe for a local commit, with the app and the XPRS srclibs
pointing at the local clones so unpushed commits work, and run it (the first
run sets the container up; `SKIP_SETUP=1` skips that on later runs):

```sh
python3 tool/fdroid_recipe.py --out ../fdroiddata/rb-recipe --repo /xprs/app \
    --srclib-repo xprs-wapps=/xprs/wapps --srclib-repo xprs-reticulum-dart=/xprs/reticulum-dart
~/bin/android-build-locked docker exec -e BUILD=com.xprs.app:$(python3 tool/fdroid_recipe.py --print-vercode arm64-v8a) \
    -e RECIPE=/fdroiddata/rb-recipe -e OUT=/fdroiddata/rb-out -e LOW_MEMORY=1 \
    fdroidtest bash /xprs/app/fdroid/buildserver-build.sh
```

The APK lands in `rb-out/unsigned/`. `LOW_MEMORY=1` gives Gradle a small heap
(`org.gradle.jvmargs=-Xmx1536m`, two workers, Kotlin in-process), otherwise the
host's earlyoom kills Gradle; it does not change the output. The build lock
matters here like for every heavy build.

For the recipe itself, run lint and rewritemeta from `/fdroiddata` as
`vagrant` with `HOME=/home/vagrant` and fdroidserver on the path:

```sh
fdroid lint com.xprs.app            # local paths make it complain only that URLs are not https
fdroid rewritemeta com.xprs.app     # normalises the layout; CI checks it
```

Check the APK with `python3 tool/fdroid_scan.py <apk>` and `aapt2 dump
badging <apk>` (the versionCode).

## 7. The recipe

The recipe lives in this repository as a template, `fdroid/com.xprs.app.yml`,
with the XPRS srclibs next to it (`fdroid/srclibs/xprs-wapps.yml` and
`xprs-reticulum-dart.yml`; `flutter` and `dav1d` are existing fdroiddata
srclibs). Its one build block uses placeholders (`@ABI@`, `@VERSION@`, ...);
`tool/fdroid_recipe.py` turns it into one block per ABI for a release:

```sh
python3 tool/fdroid_recipe.py --version 1.2.17 --code 362 --commit <release commit> \
    > metadata/com.xprs.app.yml       # in the fdroiddata checkout; then rewritemeta
```

Without arguments it takes the version from `pubspec.yaml` and the commit from
HEAD. `release.yml` renders it the same way for every build, so **a change to
the build steps must go into this template and into fdroiddata together**:
F-Droid's auto-update copies its own last build blocks, and a release built from
different steps than F-Droid's will not reproduce. The rendered arm64 block
(the other two differ only in the ABI names and the versionCode digit):

```yaml
  - versionName: 1.2.17
    versionCode: 2000362
    commit: <release commit>
    sudo:
      - apt-get update
      - apt-get install -y make clang-19 lld-19 llvm-19 wasi-libc libclang-rt-19-dev-wasm32
        libc++-19-dev-wasm32 libc++abi-19-dev-wasm32 meson ninja-build python3 rustup
        gcc libc-dev
    output: build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
    binary: https://github.com/xprs-dev/app/releases/download/v%v/xprs-%v-android-arm64-v8a.apk
    srclibs:
      - flutter@stable
      - xprs-reticulum-dart@main
      - xprs-wapps@main
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
      - git -C $$xprs-reticulum-dart$$ checkout -f $(cat .reticulum-dart-commit)
      - git -C $$xprs-wapps$$ checkout -f $(cat .wapps-commit)
      - cp -r $$xprs-reticulum-dart$$ ../reticulum-dart
      - export PUB_CACHE=$(pwd)/.pub-cache
      - $$flutter$$/bin/flutter config --no-analytics
      - $$flutter$$/bin/flutter pub get --enforce-lockfile
    scandelete:
      - .pub-cache
    build:
      - WASI_SYSROOT=/usr WASM_CLANG=clang-19 WASM_CLANGXX=clang++-19 WASM_AR=llvm-ar-19
        DAV1D_SRC=$$dav1d$$ python3 tool/build_bundled_wapps.py $$xprs-wapps$$
      - rustup default 1.89.0
      - rustup target add aarch64-linux-android
      - export PUB_CACHE=$(pwd)/.pub-cache
      - $$flutter$$/bin/flutter build apk --release --split-per-abi --target-platform=android-arm64
    ndk: r28c
```

and after the three blocks:

```yaml
AllowedAPKSigningKeys: 2a4b4625895e700839415a81c091d949699167abe03c22794376d18f2f7ec2d2

AutoUpdateMode: Version
UpdateCheckMode: Tags ^v\d+\.\d+\.\d+$
VercodeOperation:
  - '%c + 1000000'
  - '%c + 2000000'
  - '%c + 4000000'
UpdateCheckData: pubspec.yaml|version:\s.+\+(\d+)|.|version:\s(.+)\+
CurrentVersion: 1.2.17
CurrentVersionCode: 4000362
```

What each part is for, and what taught it:

* **`.flutter-version`** in this repository names the Flutter release F-Droid
  builds with; prebuild checks it out of `flutter@stable`. Bump the file when
  upgrading Flutter. (Geogram review.)
* **`.reticulum-dart-commit` and `.wapps-commit`** do the same for the two XPRS
  srclibs, which are fetched at `main` and then checked out at the release's
  pins. `release.sh` writes them, so F-Droid's auto-update, which copies the
  last build block, always builds the right sources.
* **`commit:` is the release commit's hash**, not the tag. The tag is how
  `UpdateCheckMode` finds new releases. (Geogram review.)
* **One block per ABI**, each building one split APK with its own versionCode.
  `VercodeOperation` derives the three from the `+N` in `pubspec.yaml`, and
  `binary:` names our signed APK of that ABI (section 5).
  `AllowedAPKSigningKeys` is the XPRS release certificate.
* **No DependencyInfoBlock.** `android/app/build.gradle.kts` sets
  `dependenciesInfo { includeInApk = false; includeInBundle = false }`.
  Otherwise the Android Gradle plugin adds a signing block that lists the
  dependencies, encrypted with Google's public key. (Geogram review.)
* **The self-updater stays**, with `REQUEST_INSTALL_PACKAGES`: F-Droid ships
  our APK, so it cannot differ from the direct download. An F-Droid install
  defaults to "Updates only from F-Droid" (section 1). The first submission
  compiled it out with `--dart-define=SELF_UPDATE=false` and deleted the
  permission with `sed`; the define still exists for anyone repackaging XPRS.
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
  `cargoBuildWasmRun` compiles `libwasm_run_dart.so` for the ABI being built.

## 8. Releasing through F-Droid

`release.sh` does everything the F-Droid side needs:

* it tags `vX.Y.Z` and writes `version: X.Y.Z+<commit count>` into
  `pubspec.yaml`, so every versionCode rises;
* it pins `../reticulum-dart` and `../wapps` by commit (both must be pushed);
* it copies the release's changelog to the three per-ABI names F-Droid looks
  for (`changelogs/1000362.txt`, `2000362.txt`, `4000362.txt`).

The tag starts `release.yml`, which builds, signs and verifies the three APKs
in the buildserver image and attaches them to the GitHub release. Once the
merge request is merged, F-Droid's `checkupdates` finds the tag, reads N from
`pubspec.yaml`, adds three build blocks by copying the last ones with the new
version and commit, builds them, and publishes our APKs when they match.

For each release:

1. Write the release notes to
   `fastlane/metadata/android/en-US/changelogs/<N>.txt` (500 characters at most)
   **before** running `release.sh`. N is the commit count including that
   commit, `$(( $(git rev-list --count HEAD) + 1 ))`; if other commits land
   first, `release.sh` still finds the file (the one changelog added since the
   last tag) and renames it.
2. Keep `.flutter-version` equal to the Flutter the app builds with.
3. Run `python3 tool/build_bundled_wapps.py ../wapps --check` (every bundled
   module must match its source build) and, after dependency bumps,
   `python3 tool/fdroid_scan.py` on a release APK. See section 9.
4. After `release.yml` has finished, check that its Android jobs printed
   `verify_apks: signed APK matches the F-Droid build`. If F-Droid later fails
   to reproduce a version, its build log (linked from the app's page on
   https://monitor.f-droid.org) shows the difference.

## 9. The audit behind the submission

Every network host the Android binary can reach, and every non-free piece
inside it. The audit scans the **built APK**, not the source: constants that
survive into `libapp.so`, and blobs that dependencies bring in, never show up
in a search over `lib/`. Both cases occurred here, twice.

```sh
~/bin/android-build-locked flutter build apk --release --split-per-abi
python3 tool/fdroid_scan.py build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
```

`tool/fdroid_scan.py` lists URL hosts in every file (inside every bundled
`.wapp` too), bare `host:port` names in `libapp.so` and the wapps, the native
libraries, and any `github.com` URL. It exits 1 on proprietary classes in the
dex (Play Services, Firebase, ML Kit, ...) or a native executable inside a
wapp. `test/bundled_wapps_no_executables_test.dart` keeps native executables
out of `assets/wapps/` in CI.

### 9.1 What was fixed

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

### 9.2 Hosts that remain

**Contacted with no user action** (a fresh install, default settings, after a
profile is created; before that the app opens no sockets at all):

| Host | Purpose |
|---|---|
| `rns.wisco.network`, `rns.birdsnet.com.br`, `sydney.reticulum.au`, `use.inertia.chat` (all `:4242`) | Community Reticulum TCP hubs, tried in order until one answers. Editable in Settings; `rns.autoStart` turns the node off. |
| `xprs.dev` (`/updates/*.json`, then `/downloads/...`) | The update check at start-up, except on an install from F-Droid: the update feed, and an update's files when no station holds them. xprs.dev is our site, served by GitHub Pages; the app never contacts github.com. |

Watched for 100 seconds after creating a profile, the desktop build opened only
a UDP listener on port 4242 (the LAN transport) besides the update feed. NOSTR
is off by default (`nostr.enabled`), and I2P is off (`i2p.enabled`).

**Contacted when the user uses a feature:**

| Host | When |
|---|---|
| `f-droid.org` (`/api/v1/packages/com.xprs.app`) | Updates is opened with "Updates only from F-Droid" on (the default for an install from F-Droid): which version F-Droid publishes. There is no start-up check in that mode; the F-Droid client notifies about updates itself. |
| `tile.openstreetmap.org`, `nominatim.openstreetmap.org` | A map is shown, or a place is searched. |
| `router.bittorrent.com`, `router.utorrent.com`, `dht.transmissionbt.com` (`:6881`) | DHT bootstrap, when a torrent starts. |
| `tracker.opentrackr.org`, `open.demonii.com`, `exodus.desync.com`, `tracker.torrent.eu.org` | Default open trackers added to a torrent. |
| `blossom.primal.net`, `nostr.download` | Blossom blob servers: a picture or file attached to an outgoing message is uploaded there, so a recipient on another network can fetch it. Not gated by the NOSTR switch. |
| `relay.damus.io`, `nos.lol`, `relay.nostr.band`, `relay.primal.net`, `purplepag.es` | NOSTR relays, only if the user turns NOSTR on. |
| `reseed.i2p-projekt.de`, `reseed.stormycloud.org`, `reseed.diva.exchange`, `banana.incognet.io`, `i2pseed.creativecowpat.net`, `reseed-fr.i2pd.xyz`, `reseed.onion.im` | Standard I2P reseeds, only if the user turns I2P on. |
| `ice1.somafm.com` (in `mp4player.wapp`) | Three seeded demo radio streams, over plain http. |

**Never contacted:** `github.com`. Build-time downloads from it are gone
(section 9.1), and since 2026-09-11 the update feed's files are on
xprs.dev/downloads instead of GitHub releases. The `https://xprs.dev/circle/...`
deep link is an intent filter, not a request.

**A question a reviewer may ask:** the Reticulum hubs run the Python
reference implementation, whose "Reticulum License" is MIT with added use
restrictions, not an OSI licence. XPRS speaks the protocol with its own Dart
implementation (`reticulum-dart`), and every hub is replaceable in Settings.

### 9.3 Strings that are not network calls

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

### 9.4 Permissions worth explaining

`INTERNET`, `ACCESS_NETWORK_STATE`, `BLUETOOTH_*` and `ACCESS_FINE_LOCATION`
(the BLE mesh: Android ties BLE scanning to location, and `BLUETOOTH_SCAN` is
declared `neverForLocation`), `READ/WRITE/MANAGE_EXTERNAL_STORAGE` (identity
backup and shared files), `FOREGROUND_SERVICE*` (the mesh and Reticulum node
must survive screen-off), `RECEIVE_BOOT_COMPLETED` (restart the node after a
reboot), `NEARBY_WIFI_DEVICES` and the Wi-Fi state permissions (the LAN
transport), and `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` (the node is a
long-running relay). `REQUEST_INSTALL_PACKAGES` is the in-app updater's; an
install from F-Droid leaves updates to F-Droid by default (section 1).
