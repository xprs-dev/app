# F-Droid readiness

Every network host the Android binary can reach, and every non-free piece
inside it. The audit scans the **built APK**, not the source: constants that
survive into `libapp.so`, and blobs that dependencies bring in, never show up
in a search over `lib/`. Both cases occurred here, twice.

Re-audited 2026-09-10. The store variant is built with:

```sh
~/bin/android-build-locked flutter build apk --release --split-per-abi \
    --dart-define=SELF_UPDATE=false
python3 tool/fdroid_scan.py build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
```

`tool/fdroid_scan.py` lists URL hosts in every file (inside every bundled
`.wapp` too), bare `host:port` names in `libapp.so` and the wapps, the native
libraries, and any `github.com` URL. It exits 1 on proprietary classes in the
dex (Play Services, Firebase, ML Kit, ...) or a native executable inside a
wapp. `test/bundled_wapps_no_executables_test.dart` keeps the second one out
of `assets/wapps/` in CI.

---

## 1. What the F-Droid recipe must do

| | Why |
|---|---|
| `--dart-define=SELF_UPDATE=false` | F-Droid is the only updater for what it ships. The flag turns off every check, download and install path, and hides the Updates entry in the drawer. It also removes the app's only runtime contact with GitHub: the feed's APK URLs are GitHub release assets (section 3). |
| Remove `REQUEST_INSTALL_PACKAGES` from `android/app/src/main/AndroidManifest.xml` in prebuild | Only the self-updater uses it, and that path is compiled off. |
| Install `rustup` (stable) with the Android targets, and have the NDK available | `libwasm_run_dart.so` is compiled from `third_party/wasm_run/native` during the Gradle build (section 2.3). |
| Rebuild every bundled wasm module from `xprs-dev/wapps` with Debian's clang and wasi-libc | `tool/build_bundled_wapps.py`, section 2.6. |
| Give `../reticulum-dart` a path | `pubspec.yaml` depends on it by path, so the srclib has to sit beside the app (a symlink in prebuild). |
| Leave out `desktop/` (`rm:`) | It holds mp4player's desktop build, with static ffmpeg for Linux and Windows. Only the Linux and Windows bundles install it; the APK never contains it. |

A draft of the fdroiddata entry is in section 7.

## 2. Fixed in this audit

### 2.1 Google Play Services, removed (was `NonFreeDep`)

`geolocator_android` depended on `com.google.android.gms:play-services-location`,
and it was the only Google Play code in the APK. The dex carried
`com/google/android/gms/{location,common,auth,dynamite}`. The plugin is now
vendored in `third_party/geolocator_android` without its Fused client and
without the dependency, and location always comes from the platform
`LocationManager`. Scan result: no `com/google/android/gms` class left. Details
are in `third_party/geolocator_android/README.xprs.md`.

### 2.2 `api.ipify.org`, removed

The vendored BitTorrent engine (`third_party/dtorrent_task_v2`) asked
`api.ipify.org` for the device's public IP every time a torrent or a metadata
download started. That told a third party, unprompted, that this address runs
a torrent client. Trackers (`Task._applyTrackerExternalIp`) and the peers'
extended handshake (`yourip`) already report the same address, so the lookup
and the `dart_ipify` dependency are gone.

### 2.3 `libwasm_run_dart.so`: built from source, no GitHub at build or run time

This one was wrong in the previous audit, which called the GitHub URL in
`libapp.so` inert because "nothing calls `setUpDesktopDynamicLibrary`".
Something did. `wasm_run_flutter` registers `WasmRunFlutterNative.registerWith()`
at every app start, and whenever the bundled library failed to load it
downloaded `github.com/juancastillo0/wasm_run/releases/.../other.tar.gz`, ran
`tar` on it and loaded the result.

Separately, the Android and Linux builds downloaded a prebuilt library from the
same GitHub release on every clean build. It had been compiled in 2023 on a
macOS CI runner and could not be rebuilt from this tree.

Both are gone:

* `third_party/wasm_run` no longer has a downloader (README.xprs.md section 5).
* `third_party/wasm_run_flutter` (newly vendored) compiles the Rust crate with
  cargo. On Android, Gradle task `cargoBuildWasmRun` runs
  `native/build-android.sh` for the target ABIs. On Linux, CMake runs
  `cargo build`. Versions are pinned exactly to what upstream shipped
  (wasmtime 14.0.4 on 64-bit, wasmi 0.31.2 on 32-bit, flutter_rust_bridge
  1.82.4), two lockfiles are committed, and every build uses `--locked`. The
  exported `wire_*` symbols match the old prebuilt library exactly. See
  `third_party/wasm_run_flutter/README.xprs.md`.
* Bonus: the arm64 library is now 16 KB page-aligned (NDK r28), which the old
  one was not.

### 2.4 The AI Robot is gone from the core

The wapp editor's Robot tab (`lib/ai/`, `lib/editor/wapp_robot.dart`,
`lib/editor/robot_chat_controller.dart`) carried presets for `api.openai.com`,
`api.anthropic.com` and `api.deepseek.com`. AI has no place in the core app. A
wapp can offer it later, installed by the user's choice. The code, the Robot
screen in the bundled App Creator (0.3.7), the now-unused
`HttpTransport.postStream`, and the stored `ai.*` preferences (a plaintext API
key among them) are deleted.

### 2.5 mp4player's desktop binaries are out of the APK

`assets/wapps/mp4player.wapp` carried static ffmpeg for Linux x86_64 and for
Windows (21 MB of ELF and PE that a phone can never run), and its full
`vendor/` tree (codec sources, FDK-AAC among them, and a prebuilt
`libdav1d.a`). The full package now lives in `desktop/wapps/`, which only the
Linux and Windows bundles install (as `data/wapps/`). Seeding prefers that copy
there (`_bundledWappBytes` in `lib/launcher/seeding.dart`). `assets/wapps/`
carries the same release without `bin/` and `vendor/`: 13.9 MB down to 1.2 MB.
Without the native decoder the player uses its wasm decoders, as it always did
on Android.

### 2.6 Every bundled wasm module now builds from source, with no download

The app carries compiled wapps: an `app.wasm` (and for chat and mail a
`tests.wasm`) in each `assets/wapps/*.wapp` and `desktop/wapps/*.wapp`, plus
App Creator's `assets/editor/app-creator/app.wasm`.
`tool/build_bundled_wapps.py <wapps-checkout>` rebuilds each one from
`xprs-dev/wapps` and swaps it into the package. Everything else in a package
(manifest, screens, lang, icons, C source) is text and stays as it is.
`--check` builds without writing and fails if anything differs.

* **Provenance, checked.** A clean wasi-sdk 25 build of `xprs-dev/wapps`
  `d8bc075` reproduces every bundled module byte for byte (`--check` passes).
  Three needed fixing first. `functionalities` shipped the Tester's module
  with no source beside it; it now has a Makefile that builds exactly that
  module from `tester/main.c`. App Creator shipped a stale build from before
  the geogram rename (it looked for `geogram_wasm_hal.h`); it is now the
  build of the current source. mp4player carried FDK-AAC's `__DATE__` and
  `__TIME__` from stale `.o` files committed in the wapps repo; the script
  now pins `SOURCE_DATE_EPOCH` to the checkout's commit time.
* **No download.** The wapps' new `sdk/toolchain.mk` also accepts the
  distro toolchain: `WASI_SYSROOT=/usr` with Debian's `clang-19`, `lld-19`,
  `llvm-19`, `wasi-libc`, `libclang-rt-19-dev-wasm32`, `libc++-19-dev-wasm32`
  and `libc++abi-19-dev-wasm32`. mp4player's dav1d, previously a prebuilt
  `libdav1d.a`, is compiled from dav1d 1.4.3 source by `make dav1d
  DAV1D_SRC=...` (meson + ninja) when the script is given `DAV1D_SRC`.
* **Tested on Debian trixie** (a docker `debian:trixie` image with only
  those packages): all 17 modules and dav1d built, a second run was byte
  for byte identical to the first, and every module compiled and ran
  `module_init` plus five ticks on both wasm_run engines. bookworm's
  wasi-libc (2022) is too old for mp4player (no `pthread.h`);
  bookworm-backports' may be enough but was not tried.
* The distro build is not byte-identical to the wasi-sdk build: different
  clang, and the newer wasi-libc in wasi-sdk 25 also imports
  `wasi_snapshot_preview1.random_get` for its own use. No wapp calls
  randomness itself.
* The source manifests of mail, xprs and functionalities are one version
  behind the bundled ones (same code, only the bundle's manifest was bumped).
  The script reports this and keeps the bundle's manifest.
* The wapps repo tracks mp4player's 398 `.o` files and the prebuilt
  `libdav1d.a`. `make -B` rebuilds every object, so neither reaches the APK,
  but untracking them would spare a reviewer the question.

`assets/hello_world.wasm` had no source at all. Its only user,
`WappRunnerPage`, was dead code (never constructed), so both are gone.

### 2.7 Earlier rounds

| Was | Now |
|---|---|
| `mobile_scanner` (ML Kit, `libbarhopper_v3.so`, proprietary) for `qr.scan` | Removed with the CAMERA permission. `qr.scan` answers `nocamera` everywhere. A free decoder (`flutter_zxing`, `zxing2`) can restore it. |
| `server.arcgisonline.com` (Esri) as the default map tiles | `tile.openstreetmap.org` |
| `install.wapp` rewrote `github.com` URLs to `raw.githubusercontent.com` | Rewriter deleted. The default catalog is a Reticulum address (`rns:npub1…`), not HTTP. |

### 2.8 One licence: BSD-3-Clause

Every XPRS repository (app, wapps, reticulum-dart, spec, firmware,
esp32-ultra-range, vanity, website, .github) now carries the same
BSD-3-Clause `LICENSE`, copyright "Max Brito and XPRS contributors", with no
year so the line never needs changing. The app and wapps had no licence at
all, which F-Droid would have refused. reticulum-dart and esp32-ultra-range
were Apache-2.0, and the spec was CC BY 4.0. Vendored third-party code keeps
its own licence, listed in each README's License section.

### 2.9 FDK-AAC replaced by Android's PacketVideo decoder (Apache-2.0)

mp4player decoded AAC with Fraunhofer's FDK-AAC. Its licence grants no
patent rights and allows use "only for purposes that are authorized by
appropriate patent licenses". Fedora reclassified it as not allowed in 2022,
Debian keeps it out of main, and F-Droid requires every dependency to be
free. It is gone from the wapps repository, along with its 351 files,
committed `.o` files included.

The replacement is the AAC decoder Android itself shipped before FDK:
PacketVideo's, from AOSP (`android-4.1.2_r2.1`), Apache-2.0. It handles
AAC-LC, HE-AAC and HE-AACv2. Two things had to be found to make it work on
wasm32, and both are recorded in `mp4player/vendor/pvaac/README.xprs.md`:

* It needs `-fno-strict-aliasing`, as AOSP built it. Without that flag,
  clang's `-O2` wasm output was garbage (-7 dB against FDK).
* Its Parametric Stereo setup assumed 32-bit pointers. A one-struct patch
  makes it portable, and the wasm32 output is byte-identical with or
  without it.

Verified on 21 streams against fdk-aac 2.0.3 (LC at 8-48 kHz, HE-AAC and
HE-AACv2 with both signallings, mono and genuinely stereo material, and a
real-world stream): the same rate, channel count and length in every case,
64-75 dB SNR per channel, and the same stereo width. The objects linked into
`app.wasm` reproduce that output byte for byte. mp4player is now 2.0.2 and
`app.wasm` is 730 KB smaller.

The one feature lost: AAC with more than two channels (5.1) no longer
decodes, so such a file plays without sound. FDK decoded it.

Every `.wapp` now also carries `licenses/`, the notices of the third-party
code linked into its module (PacketVideo's Apache-2.0, OpenH264, libvpx and
its patent grant, Opus, nestegg, dav1d, and libde265's LGPL-3.0).
`build-archive.sh` packs the directory, and `tool/build_bundled_wapps.py`
takes it from source. The earlier slim repack of mp4player had dropped every
one of these notices.

## 3. Hosts that remain

**Contacted with no user action** (a fresh install, default settings)

| Host | Purpose |
|---|---|
| `rns.wisco.network`, `rns.birdsnet.com.br`, `sydney.reticulum.au`, `use.inertia.chat` (all `:4242`) | Community Reticulum TCP hubs, tried in order, until one answers. Editable in Settings; `rns.autoStart` turns the node off. |

That list is the whole of it. NOSTR is off by default (`nostr.enabled`,
retired 2026-08-30), I2P is off (`i2p.enabled`), and the update feed is
compiled off in the store variant.

**Contacted when the user uses a feature**

| Host | When |
|---|---|
| `tile.openstreetmap.org`, `nominatim.openstreetmap.org` | A map is shown / a place is searched. A wapp can set its own `tile-url`. |
| `router.bittorrent.com`, `router.utorrent.com`, `dht.transmissionbt.com` (`:6881`) | DHT bootstrap, when a torrent starts. The bootstrap server is open source. |
| `tracker.opentrackr.org`, `open.demonii.com`, `exodus.desync.com`, `tracker.torrent.eu.org` | Default open trackers added to a torrent. |
| `blossom.primal.net`, `nostr.download` | Blossom blob servers. A picture or file attached to an outgoing message is uploaded there (`maybePublishSharedMedia`), so a recipient on another network can fetch it. **Not** gated by the NOSTR switch. Editable in the wapp's internet settings. |
| `relay.damus.io`, `nos.lol`, `relay.nostr.band`, `relay.primal.net`, `purplepag.es` | NOSTR relays, only if the user turns NOSTR back on. |
| `reseed.i2p-projekt.de`, `reseed.stormycloud.org`, `reseed.diva.exchange`, `banana.incognet.io`, `i2pseed.creativecowpat.net`, `reseed-fr.i2pd.xyz`, `reseed.onion.im` | Standard I2P reseeds, only if the user turns I2P on. |
| `ice1.somafm.com` (in `mp4player.wapp`) | Three seeded demo radio streams, over plain http. Free-to-listen Icecast. |

**Never contacted by the store variant**

| Host | Why it is still in the binary |
|---|---|
| `xprs.dev` | The update feed (`https://xprs.dev/updates`), behind `SELF_UPDATE`. Note that xprs.dev is **served by GitHub Pages** (`server: GitHub.com`), and that the feed's APK URLs point to `github.com/xprs-dev/app/releases`. The direct-download build therefore does contact GitHub, and the store variant never does. It also appears as the host of the `https://xprs.dev/circle/…` deep link, which is an intent filter, not a request. |

## 4. Still open

**Reticulum's licence.** The hubs above run the Python reference implementation,
which since 2025 has been under the "Reticulum License": MIT plus use
restrictions (check the current text before submitting). That is not an OSI
licence, and a reviewer could read the default hubs as a non-free network
service. The app speaks the protocol with its own Dart implementation
(`../reticulum-dart`), and any hub is replaceable in Settings. Be ready to
explain that if asked.

## 5. Strings that are not network calls

| String | Where | Why it is inert |
|---|---|---|
| `github.com/flutter/flutter/issues`, `github.com/dart-lang/sdk/...` | `libflutter.so` | Engine error text |
| `github.com/Baseflow/flutter-permission-handler/issues`, `github.com/flutter/flutter/issues/165510` | `classes.dex` | Exception messages |
| `github.com/bytecodealliance/wasmtime/issues/...` | `libwasm_run_dart.so` | wasmtime panic text, compiled from source |
| `github.com`, `raw.githubusercontent.com` | `install.wapp:main.c` | A comment recording that the rewriter is gone |
| `schemas.android.com`, `www.w3.org`, `www.apache.org`, `android.googlesource.com`, `developers.google.com/tink`, `issuetracker.google.com`, `docs.flutter.dev`, `dartbug.com`, `youtrack.jetbrains.com`, `bytecodealliance.org`, `docs.rs` | toolchain/runtime | XML namespaces, licence headers, and doc links in AOSP/Flutter/Kotlin/Rust/Tink |
| `blossom.example.com`, `relay.example.com`, `rns.example.net`, `yourdomain.com` | `libapp.so`, `mail.wapp` | Placeholder hints in text fields |

The dex is free of Firebase, Play Services, Google Analytics, Crashlytics and
any advertising or tracking SDK. `com.google.crypto.tink` (Apache-2.0, pulled
in by `flutter_secure_storage`) is free software. The native libraries are
`libapp.so`, `libflutter.so`, `libwasm_run_dart.so` (built from source),
`libsqlcipher.so` (`net.zetetic:sqlcipher-android`, Maven Central, BSD),
`libdartjni.so` and `libdatastore_shared_counter.so` (AndroidX).

## 6. Permissions worth explaining in the submission

`INTERNET`, `ACCESS_NETWORK_STATE`, `BLUETOOTH_*` + `ACCESS_FINE_LOCATION`
(BLE mesh: Android ties BLE scanning to location, and `BLUETOOTH_SCAN` is
declared `neverForLocation`), `READ/WRITE/MANAGE_EXTERNAL_STORAGE` (identity
backup and shared files), `FOREGROUND_SERVICE*` (the mesh and Reticulum node
must survive screen-off), `RECEIVE_BOOT_COMPLETED` (restart the node after a
reboot), `NEARBY_WIFI_DEVICES` and the Wi-Fi state permissions (LAN
transport), `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` (the node is a
long-running relay). `REQUEST_INSTALL_PACKAGES` is removed for the store
build (section 1).

## 7. Draft fdroiddata entry

Untested against `fdroidserver` itself. Each step was run by hand: the wasm
toolchain and the script on `debian:trixie`, and the APK build on the
development laptop. `xprs-wapps`, `reticulum-dart` and `dav1d` would need
srclib definitions in fdroiddata. Pin the two XPRS srclibs to the commits the
release was built from.

```yaml
License: BSD-3-Clause
Builds:
  - versionName: 1.2.13
    versionCode: 337
    commit: v1.2.13
    sudo:
      - apt-get update
      - apt-get install -y make clang-19 lld-19 llvm-19 wasi-libc
        libclang-rt-19-dev-wasm32 libc++-19-dev-wasm32 libc++abi-19-dev-wasm32
        meson ninja-build
    output: build/app/outputs/flutter-apk/app-release.apk
    srclibs:
      - flutter@3.38.1
      - rustup@stable
      - reticulum-dart@<commit>
      - xprs-wapps@<commit>
      - dav1d@1.4.3
    rm:
      - desktop
    prebuild:
      - $$rustup$$/rustup-init.sh -y --default-toolchain stable --target
        aarch64-linux-android,armv7-linux-androideabi,x86_64-linux-android
      - ln -s $$reticulum-dart$$ ../reticulum-dart
      - sed -i -e '/REQUEST_INSTALL_PACKAGES/d' android/app/src/main/AndroidManifest.xml
      - WASI_SYSROOT=/usr WASM_CLANG=clang-19 WASM_CLANGXX=clang++-19
        WASM_AR=llvm-ar-19 DAV1D_SRC=$$dav1d$$
        python3 tool/build_bundled_wapps.py $$xprs-wapps$$
      - $$flutter$$/bin/flutter config --no-analytics
      - $$flutter$$/bin/flutter pub get
    build:
      - source $HOME/.cargo/env
      - $$flutter$$/bin/flutter build apk --release --dart-define=SELF_UPDATE=false
    ndk: 28.2.13676358
```

Open questions for the first real run: whether the scanner objects to the
`.wapp` archives themselves (they are zips of text plus the rebuilt modules),
and whether the Kotlin/Gradle step picks up `~/.cargo/bin` without the
`source` line.
