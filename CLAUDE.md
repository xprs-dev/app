# Working in this repo

## Architecture — read before writing code

`docs/architecture.md` governs. Two rules break most often, so they are also
machine-checked by `tool/arch_guard.dart` (pre-commit + CI):

- **Transports are CORE.** BLE5, Reticulum, LXMF, retries, custody and
  store-and-forward live in `lib/`. A wapp hands the core a payload and is
  called back when one arrives; it never decides how bytes travel. If a wapp
  needs a new `hal_*` to make a transport decision, the design is wrong.
- **Nothing blocking on the UI isolate.** No `*Sync` I/O, no `sleep`, no heavy
  crypto/sqlite in a widget or a service the UI awaits. Platform channels
  (`MethodChannel`, `Ble5Bus`) are main-isolate ONLY.

Run `dart tool/arch_guard.dart` before committing (or `./tool/install-hooks.sh`
once). It fails only on NEW violations; `docs/architecture.md` §5 explains the
baseline and the `// arch-ignore: <rule> <reason>` escape.

Transport specifics: `docs/ble5.md` (how bytes leave the device, every byte
budget on the path) and `docs/store-and-forward.md` (delivery to absent peers).

## Sibling repositories

This is the application. Three things it works with live next to it, and the
paths below assume they are checked out as siblings of this directory:

| | |
|---|---|
| `../reticulum-dart` | the library: Reticulum, NOSTR, LXMF, DHT, files, and `XprsCrypto`. A **path dependency** in `pubspec.yaml`, so it must be a sibling or the build fails |
| `../wapps` | wapp source (`xprs-dev/wapps`); `assets/wapps/*.wapp` here are built copies |
| Station firmware (ESP32, nRF52840) | `xprs-dev/xprs-firmware` (was `xprs-esp32`), formerly `esp32/` in this repo. `docs/ble5.md` and `docs/lan.md` describe transports with an end in each, so they are kept here AND there and must not drift |

`docs/XPRS.md` is a copy of the protocol specification (`xprs-dev/spec`). Keep
it byte-identical to that one -- the corpus in `test/xprs_corpus.json` is
checked against it, and the whole value of that check is that it tests against
the document rather than against another implementation.

## Running the Linux desktop app

**Automated GUI testing runs invisibly. Only put it on the user's screen when
the user has to look at it themselves.**

Driving the app with `xdotool` on the user's own display steals focus and types
into whatever they are doing. Use a private X server instead:

```sh
Xvfb :99 -screen 0 1400x900x24 &                            # once
DISPLAY=:99 ./build/linux/x64/release/bundle/xprs &        # the app
DISPLAY=:99 xdotool search --class radio.xprs.app      # find its window
DISPLAY=:99 xdotool mousemove --window <id> X Y click 1      # drive it
import -display :99 -window root shot.png                    # screenshot
```

Show it on the real display (`DISPLAY=:0`, no prefix) only when the user needs
to confirm something by eye, or asks to see it.

(`Xephyr :2 -screen 1400x900 -ac` is the middle ground: a nested server in a
window they can minimise. Xvfb is the default; Xephyr only if they want to peek
without giving up their focus.)

## Building

```sh
~/bin/android-build-locked flutter build linux --release     # desktop bundle
~/bin/android-build-locked ./launch-android.sh -- --build-number=<N>
```

Every heavy build goes through `~/bin/android-build-locked` (16GB machine; two
concurrent builds freeze it). Launch the **built bundle** directly rather than
`flutter run` — `flutter run` holds the build lock until the app quits, so a
queued APK build waits on it.

Android installs need `--build-number` above the installed `versionCode`
(`adb shell dumpsys package com.xprs.app | grep versionCode`), and other
sessions may be installing to the same phone.

### A build that vanishes was killed, not broken

`earlyoom` runs here with `--prefer=(java|dart|kotlinc?|aapt2|R8|gradle)`, so
when free RAM dips it shoots **the build** first. The symptom is not an OOM
message: it is "Gradle build daemon disappeared unexpectedly", a `flutter build`
that exits non-zero after ~20s, or a wrapper that hangs forever. Before hunting
a compile error, check whether anything is still running at all.

Ceilings are therefore deliberately low, and raising one makes builds *less*
reliable here, not more:

- `~/.gradle/gradle.properties` (machine-wide, NOT in the repo) — 1g heap,
  Kotlin in-process, 2 workers. This is where this machine's squeeze belongs,
  and it **overrides** the repo, so check it first when the numbers do not
  match what you expect.
- `android/gradle.properties` (in the repo) — a ceiling that must compile on
  EVERY machine, CI included. Do not put this laptop's numbers here: they were
  copied in once, and `:app:compileReleaseKotlin` then died on GitHub Actions
  with an `InvocationTargetException` — a Kotlin worker OOM that never prints
  "OutOfMemory". The machine-wide file already overrode it locally, so the
  repo copy bought this box nothing and broke the release build.
- `launch-android.sh` builds only the ABIs of the phones actually attached.
  `--split-per-abi` alone builds three, and two of those AOT compiles are the
  ones that push the machine over.

`tool/build-peak.sh <command>` reports peak build RSS when you need the number
rather than a guess.

**A timed-out build leaves its wrapper holding the flock**, and the next build
then blocks on "Another Android build is running". Kill the orphan by PID —
never `pkill -f`, which matches the wrapper's own command line and kills the
shell issuing it.

## Wapps

Wapp source lives in `../wapps` (the `xprs-dev/wapps` repo), not here;
`assets/wapps/*.wapp` are built copies. Ship chain:

```sh
cd ../wapps/<name> && WASI_SDK_PATH=~/wasi-sdk make          # -Werror
cd ../ && ./build-archive.sh <name>
cp binaries/<name>/<name>-<version>.wapp ../xprs-flutter/assets/wapps/<name>.wapp
```

Bump `manifest.json` version or installed copies never update.

## Debugging a wapp

`hal_log` from a **foreground page engine does not reach LogService**, so it
never shows in `/api/log` — only background-engine logs do. A wapp's own
`$type:"log"` panel (e.g. Mail's Status screen) is the reliable window into
what the page engine is doing.

The host logs every user-triggered command as `wapp <name>: cmd <command>`,
which distinguishes "the UI never sent it" from "the wapp ignored it".
