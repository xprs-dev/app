/*
 * What the person actually allowed, as live state every feature reads.
 *
 * Android lets anyone refuse any runtime permission, at the intro or later in
 * the system settings. XPRS has to run with whatever subset it got: the
 * internet side needs no permission at all, the nearby mesh needs Bluetooth,
 * the map needs Location, and so on. This is the one place a feature asks
 * "may I use X?", so a refused permission switches its feature off instead of
 * leaving a service that fails on every heartbeat.
 *
 * Refreshed at boot, when the app comes back to the foreground (the person may
 * have granted something in the system settings) and after any request.
 * Revoking a permission kills the process on Android, so within one run the
 * only change ever seen is a grant. Off Android every capability is on.
 */

import 'package:flutter/widgets.dart';
import 'package:xprs_core/src/util/observable.dart';

import '../platform/platform.dart' as platform;
import 'android_permissions_service.dart';

class PermissionState {
  PermissionState._();
  static final PermissionState instance = PermissionState._();

  static bool get _android => platform.platformName() == 'android';

  /// Keys of the intro rows ([AndroidPermissionsService.items]) this device
  /// has but the person has not granted. Empty off Android.
  final Observable<Set<String>> missing = Observable(const <String>{});

  /// Bluetooth may be used: scan, advertise and connect, and on Android 11
  /// and older also the location permission those versions demand for a scan.
  /// Synchronous so the core's CoreHost.radioAllowed can read it. Off until
  /// the first [refresh] on Android, so nothing touches the radio early.
  final Observable<bool> bluetooth = Observable(!_android);

  /// Nearby WiFi devices (WiFi Direct): NEARBY_WIFI_DEVICES from Android 13,
  /// the location permission before it.
  final Observable<bool> nearbyWifi = Observable(!_android);

  /// The system-wide Location switch; null when the probe could not answer.
  final Observable<bool?> locationSwitch = Observable(true);

  bool _refreshed = !_android;
  bool get refreshed => _refreshed;

  bool granted(String key) => !missing.value.contains(key);

  /// What the refused rows ([missing] keys) cost on Android API [sdk]
  /// (0 = unknown, read as a current version).
  /// - Bluetooth: the bluetooth row; on Android 11 and older also the
  ///   location permission, which those versions demand for a BLE scan.
  /// - Nearby WiFi: its own row from Android 13, the location row before
  ///   (WifiDirect.hasPermission on the native side checks the same).
  static ({bool bluetooth, bool nearbyWifi}) capabilities(
      Set<String> missing, int sdk) {
    final legacy = sdk != 0 && sdk <= 30;
    return (
      bluetooth: !missing.contains('bluetooth') &&
          !(legacy && missing.contains('location')),
      nearbyWifi: (sdk == 0 || sdk >= 33)
          ? !missing.contains('nearby_wifi')
          : !missing.contains('location'),
    );
  }

  Future<void>? _running;

  _ResumeWatch? _watch;

  /// Re-read whenever the app returns to the foreground: the person may have
  /// granted something in the system settings meanwhile. Idempotent.
  void watchResume() {
    if (_watch != null || !_android) return;
    _watch = _ResumeWatch(refresh);
    WidgetsBinding.instance.addObserver(_watch!);
  }

  /// Re-read every permission. Concurrent calls share one pass.
  Future<void> refresh() => _running ??= _refresh().whenComplete(() {
        _running = null;
      });

  Future<void> _refresh() async {
    if (!_android) return;
    final svc = AndroidPermissionsService.instance;
    final gone = <String>{};
    for (final item in await svc.shownItems()) {
      if (item.info) continue;
      if (!await svc.isGranted(item)) gone.add(item.key);
    }
    final caps = capabilities(gone, await platform.androidSdkInt());
    missing.value = gone;
    bluetooth.value = caps.bluetooth;
    nearbyWifi.value = caps.nearbyWifi;
    locationSwitch.value = await svc.locationServicesState();
    _refreshed = true;
  }
}

class _ResumeWatch with WidgetsBindingObserver {
  _ResumeWatch(this._onResume);
  final Future<void> Function() _onResume;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _onResume();
  }
}
