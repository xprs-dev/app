# TODO

## Finish the battery-tier measurement on TANK2 (paused 2026-08-31)

The optimisation work is **written, committed and building**; what is missing is
proof that it does anything. The first A/B on TANK2 says it does not — because
the tier never engaged. Whoever picks this up starts at the diagnosis, not at
the code.

### Where it stands

Committed on `main` (release-signed builds of both sides were measured):

| commit | what |
|---|---|
| `5740933` | chat memo restored (`_castList`), feed query memoised on `_activityRev` |
| `74dc259` | arch_guard: `lib/wapp/**`, `no-scan-for-one-row`, `no-unbounded-select` |
| `62c68ac` | per-card sqlite memo + key→index map in the activity feed |
| `0d1e27b` | `byMid()` instead of 300-row scans; batched migration SELECT |
| `85e232a` | `LocalSigner.signEvent` on `Isolate.run` |
| `237c0a0` | `cacheWidth` at five bounded decode sites |
| `fdd9338` | `ListView.builder` in the editor; const lints on + applied |
| `df5b72a` | **the tier**: `PowerState`, BgService heartbeat/locks, BLE scan mode, ble5.md §9.4 fix |
| `2b6e8d8` | tick coalescing, GPS hygiene, RNS retry backoff |
| `73c31a0`, `2517ef2` | performance.md §8.11 + drift, ble5.md §9.4 closed |

`flutter analyze` clean in `lib/`, `arch_guard` clean, 900 tests pass.

### The measurement, as taken

TANK2, release arm64, screen off (`mWakefulness=Asleep` verified), framework
forced to discharging, 5-minute window after a 5-minute settle, per
docs/performance.md §4:

| | before (`7ff6062`) | after (this work) |
|---|---|---|
| process CPU | **4.96%** of one core | **4.99%** |
| main thread | 3.57% | 3.72% |
| `ble5-worker` | 0.45% | 0.44% |
| BT scan time | 10m36s (100% of window) | 10m36s (100%) |

Raw data: `m-before.txt` / `m-after.txt` (+ `.raw`) in the session scratchpad —
copy them somewhere durable if this sits for long.

### Why it is a null result

The tier system is **inert, not ineffective**. Evidence, all with the screen
off and the framework reporting discharging (`dumpsys battery unplug` +
`set status 3`):

- no `scan mode ->` line from `Ble5` in logcat — the scan never left BALANCED;
- `dumpsys power` still shows `PARTIAL_WAKE_LOCK 'aurora:bg' ... LONG` held,
  which the `battery` tier is supposed to release;
- the app's own screen/tier decisions were invisible: `LogService.add` writes to
  the in-app ring, which never reaches logcat. **That is the same defect this
  work just wrote up for the BLE scan** — a system that silently never fires
  looks exactly like one that is working.

Three candidates, in order of suspicion:

1. **`PowerState.start()` never ran.** `_powered` initialises to `true`, so
   without `_readBattery()` the tier can only ever be `active`/`idle`, and
   `idle` costs exactly what the old code cost — which is the measurement.
   `PowerGovernor.instance.start()` (main.dart:396) is what calls it.
2. **The `power.screen` broadcast never reaches Dart.** The receiver IS
   registered (`dumpsys activity broadcasts` shows the SCREEN_ON/SCREEN_OFF
   filter under the app's uid), so suspect the Dart handler:
   `AndroidForegroundService._onCall` only exists once that singleton has been
   constructed.
3. **`battery_plus` reports charging anyway** under the `dumpsys battery`
   override, leaving `_powered` true.

### Next step (the trace build is already made)

`lib/services/power_state.dart` and `lib/connections/bluetooth/ble_service_io.dart`
now `debugPrint` every tier decision, screen change and scan-mode change —
`debugPrint` DOES reach logcat in release (tag `flutter`), `LogService` does not.

**The trace APK is already built and saved**: `~/.xprs/xprs-trace-1003813.apk`
(release, arm64, versionCode 1003813). Skip straight to the install below —
the build block is only there for when the sources move on.

```sh
# release builds OOM on this machine at the default 384m metaspace (below)
sed -i 's/MaxMetaspaceSize=384m/MaxMetaspaceSize=1g/' ~/.gradle/gradle.properties
~/bin/android-build-locked flutter build apk --release \
    --target-platform android-arm64 --build-number=1003813
cp ~/.gradle/gradle.properties.bak ~/.gradle/gradle.properties   # restore!

adb install -r build/app/outputs/flutter-apk/app-release.apk
adb logcat -c
adb shell am force-stop com.xprs.app
adb shell dumpsys battery unplug && adb shell dumpsys battery set status 3
adb shell am start -n com.xprs.app/.MainActivity
sleep 25 && adb shell input keyevent 26 && sleep 90
adb logcat -d | grep -aiE "PowerState|scan mode"
adb shell dumpsys power | grep -i aurora     # the lock must be GONE in `battery`
adb shell dumpsys battery reset              # ALWAYS, or the phone lies about power
```

Expected within ~70 s of screen-off: `PowerState: screen off`,
`PowerState: background`, `PowerState: tier -> battery`, `BLE5: scan mode ->
low-power`. Whichever line is missing names the cause.

Then re-run the A/B: `scratchpad/measure-frozen.sh <label> 300 300` (force-stop,
launch, screen off, settle, one-command per-thread sample, batterystats).

### Still unverified even after that

- **BLE delivery 10-of-10 both directions in the `battery` tier** — needs a
  second station; only TANK2 was attached. This is the GATE: docs/ble5.md §4
  measured a scan change taking delivery from 10-of-10 to 0-of-10, and no CPU
  number is worth shipping without it.
- **Overnight `batterystats` soak** (wakelock hold time, BLE scan time, WiFi
  lock time, CPU ms) on C61 and TANK2, before vs after.
- **The wake-lock diet (A2) as a field test**: exempt + asleep, is the app still
  LAN-reachable and does a BLE message still arrive? If not, revert it and
  record why in performance.md — the plan said so up front.

### Housekeeping left behind

- `../app-before` is a **git worktree at `7ff6062`** built for the A/B. Remove
  with `git worktree remove ../app-before` when done (or keep it — a second
  build there is ~4 min).
- TANK2 currently holds **versionCode 1003812** (this work). Your own 1.2.3 was
  `1003810`, so re-installing it needs a bump or an uninstall; the phone's data
  was preserved throughout (same debug signature, upgrade installs only).
- `~/.gradle/gradle.properties` is restored to 384m. Verify with
  `grep jvmargs ~/.gradle/gradle.properties` before trusting a build.

## Release builds OOM on this machine (found 2026-08-31)

`flutter build apk --release` fails on this box, **and failed identically at
`7ff6062`** — it is not caused by the tier work:

```
ERROR: R8: java.lang.OutOfMemoryError: Metaspace
Execution failed for task ':shared_preferences_android:lintVitalAnalyzeRelease'
  ... Message: Metaspace
```

`~/.gradle/gradle.properties` caps `MaxMetaspaceSize=384m`. R8 and lint's Kotlin
analyser both need more. Metaspace is NATIVE memory, outside `-Xmx`, so raising
it to 1g does not touch the heap ceiling earlyoom cares about — but the file's
own comment says raising ceilings here makes builds less reliable, so this is
recorded rather than changed. Decide once: raise the machine cap, or disable
`lintVital` + R8 for local release builds.
