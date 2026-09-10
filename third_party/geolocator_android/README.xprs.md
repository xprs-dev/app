# Why this package is vendored

Fork of `geolocator_android 4.6.2` (pub.dev), with Google Play Services removed.
The Dart side is upstream. The Android side has three changes, marked
`PATCHED (xprs)` where they are edits:

1. `android/build.gradle` no longer depends on
   `com.google.android.gms:play-services-location`.
2. `location/FusedLocationClient.java`, the only user of that library, is
   deleted.
3. `GeolocationManager.createLocationClient` always returns the platform
   `LocationManagerClient`, and the `GoogleApiAvailability` probe is gone.

## Why

Play Services is a proprietary library. F-Droid does not ship an APK that
contains it (anti-feature `NonFreeDep`), and before this fork it was the only
Google Play code in the release APK. It arrived through this one plugin; `lib/`
never asked for it.

Passing `forceLocationManager: true` to upstream does not help: the fused
client is still compiled in and still pulls in `play-services-location`.
Excluding the group in Gradle breaks the build, since `FusedLocationClient`
references its classes.

## What is lost

`LocationManager` is what the fused provider sits on top of on phones that do
have Play Services, so a GPS fix still arrives. The two features that are gone
are the fused provider's Wi-Fi/cell fusion (so a first fix indoors can take
longer) and the in-app "turn on location" resolution dialog. The app sends the
user to the system location settings instead: `openLocationSettings()` is
unaffected.

`example/`, `test/` and `android/src/test/` were removed to keep the tree small.

## Upgrading

Copy the new upstream `android/` and `lib/`, then re-apply the three changes
above. `grep -rn gms android/` must print nothing.
