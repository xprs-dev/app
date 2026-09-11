/*
 * Android runtime permission requests, modelled on xprs's
 * BLEPermissionService. XPRS needs BLE (scan/connect/advertise) for the
 * street mesh + APRS-over-BLE, notifications for background message alerts,
 * and broad file access for the encrypted identity backup that survives an
 * uninstall (restore-on-reinstall).
 *
 * ALL of these are requested up front from the onboarding panel
 * (PermissionsIntroPage), which does not let the user proceed to profile
 * creation until every required permission is granted — nothing should
 * surface a late prompt after the profile exists. No-op on non-Android.
 */

import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';

import '../platform/platform.dart' as platform;
import 'log_service.dart';

/// One onboarding permission the user must grant, with live status.
class AppPermission {
  final String key; // stable id
  final String title;
  final String desc;
  final String icon; // material icon name (resolved by the UI)
  final List<Permission> perms; // all must be granted for this item to be "on"
  final bool info; // true = install-time / informational (never a prompt)
  /// Special-access permissions (e.g. All-files) open a SYSTEM SETTINGS screen
  /// instead of an inline dialog; the panel re-checks status on app resume.
  final bool special;

  /// Nice-to-have, not a blocker: offered here (so the prompt happens HERE and
  /// not later, mid-app) but the user can leave the intro without it.
  final bool optional;

  /// This item also needs the system-wide LOCATION SERVICES switch, not just
  /// its runtime permission. Granting the permission while the switch is off
  /// still leaves BLE scanning dead, so the item stays un-granted and its
  /// request opens the location settings screen.
  final bool needsLocationServices;

  /// Lowest Android API level on which this permission exists. Below it the
  /// OS has nothing to grant: permission_handler then reports the permission
  /// as denied forever and a request shows no dialog at all, so a required
  /// row would lock the user out of the intro for good. Such an item is left
  /// out on older systems instead. 0 = every supported version.
  final int minSdk;

  /// Highest Android API level this item is shown on, for a permission that a
  /// newer one replaced (the same idea as `android:maxSdkVersion` in the
  /// manifest). 0 = no upper bound.
  final int maxSdk;

  const AppPermission({
    required this.key,
    required this.title,
    required this.desc,
    required this.icon,
    this.perms = const [],
    this.info = false,
    this.special = false,
    this.optional = false,
    this.needsLocationServices = false,
    this.minSdk = 0,
    this.maxSdk = 0,
  });
}

class AndroidPermissionsService {
  AndroidPermissionsService._();
  static final AndroidPermissionsService instance =
      AndroidPermissionsService._();

  bool get _isAndroid => platform.platformName() == 'android';

  /// Android 11 (API 30): the first version with MANAGE_EXTERNAL_STORAGE.
  static const int _allFilesSdk = 30;

  /// The onboarding permission list, in display order. Every non-[info] item
  /// must be granted before the user can leave the intro.
  static const List<AppPermission> items = [
    AppPermission(
      key: 'bluetooth',
      title: 'Bluetooth',
      desc: 'Discover nearby devices and exchange messages over the mesh',
      icon: 'bluetooth',
      perms: [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.bluetoothAdvertise,
      ],
    ),
    AppPermission(
      key: 'nearby_wifi',
      title: 'Nearby WiFi devices',
      desc: 'Move large files between nearby devices over a direct WiFi link '
          '(much faster than Bluetooth)',
      icon: 'wifi',
      perms: [Permission.nearbyWifiDevices],
      // NEARBY_WIFI_DEVICES arrived in Android 13. Before that WiFi Direct is
      // gated on ACCESS_FINE_LOCATION (WifiDirect.hasPermission), which the
      // Location row already requests. Many Huawei phones report API 31, and
      // there this row could never turn green, so nobody got past the intro.
      minSdk: 33,
    ),
    AppPermission(
      key: 'notifications',
      title: 'Notifications',
      desc: 'Alert you when a message arrives while the app is in the background',
      icon: 'notifications',
      perms: [Permission.notification],
    ),
    AppPermission(
      key: 'storage',
      title: 'Storage',
      desc: 'Keep an encrypted backup of your identity so it survives a '
          'reinstall, and share files',
      icon: 'folder',
      perms: [Permission.manageExternalStorage],
      special: true,
      // "All files access" arrived in Android 11. Below it permission_handler
      // reports it as restricted forever; see storage_legacy.
      minSdk: _allFilesSdk,
    ),
    AppPermission(
      // The same row for Android 10 and older, where READ/WRITE_EXTERNAL_STORAGE
      // give the same reach over public storage (on Android 10 only together
      // with requestLegacyExternalStorage in the manifest). A normal dialog,
      // not a settings screen.
      key: 'storage_legacy',
      title: 'Storage',
      desc: 'Keep an encrypted backup of your identity so it survives a '
          'reinstall, and share files',
      icon: 'folder',
      perms: [Permission.storage],
      maxSdk: _allFilesSdk - 1,
    ),
    AppPermission(
      key: 'location',
      title: 'Location',
      desc: 'Required by Android to find nearby devices over Bluetooth — with '
          'location switched off the system returns no scan results at all, so '
          'the app goes silently deaf. Also puts your position on the map.',
      icon: 'location',
      perms: [Permission.locationWhenInUse],
      // NOT optional, however much it looks like a privacy nicety: Android
      // withholds every BLE scan result while the location master switch is
      // off, whatever the app declares. A tablet in that state advertised,
      // scanned, and heard literally nothing for hours while reporting itself
      // healthy. The permission alone is not enough either — see
      // [locationServicesOn], which this item's status also requires.
      needsLocationServices: true,
    ),
    AppPermission(
      key: 'battery',
      title: 'Run in the background',
      desc: 'Let the app keep receiving messages when the screen is off — '
          'Android otherwise puts it to sleep',
      icon: 'battery',
      perms: [Permission.ignoreBatteryOptimizations],
      special: true,
      // Optional: it must not trap a user behind a disabled Continue. But it is
      // offered HERE so the prompt lands with the others instead of ambushing
      // the user right after they pick a callsign, which is what it used to do.
      optional: true,
    ),
    AppPermission(
      key: 'internet',
      title: 'Internet',
      desc: 'Connect to the internet relays and the wapp store (automatic)',
      icon: 'wifi',
      info: true,
    ),
  ];

  /// Items that BLOCK leaving the intro (excludes informational + optional rows).
  List<AppPermission> get required =>
      [for (final i in items) if (!i.info && !i.optional) i];

  /// Every item the user can actually grant — including the optional ones, so
  /// "Grant all" offers them too. Nothing here may be requested outside the
  /// intro; that is the whole contract of this screen.
  List<AppPermission> get grantable => [for (final i in items) if (!i.info) i];

  /// Whether this OS has [item] at all (see [AppPermission.minSdk] and
  /// [AppPermission.maxSdk]). An unknown API level counts as "no" for any
  /// version-bound item: a failed probe must never block the intro.
  Future<bool> applies(AppPermission item) async {
    if (item.minSdk == 0 && item.maxSdk == 0) return true;
    final sdk = await platform.androidSdkInt();
    if (sdk == 0) return false;
    if (item.minSdk != 0 && sdk < item.minSdk) return false;
    if (item.maxSdk != 0 && sdk > item.maxSdk) return false;
    return true;
  }

  /// The rows the intro shows on this device, in display order.
  Future<List<AppPermission>> shownItems() async =>
      [for (final i in items) if (await applies(i)) i];

  /// Live grant status of one item (true when all its perms are granted).
  /// Informational items, and items this OS version does not have, are always
  /// "granted". Always true off Android.
  Future<bool> isGranted(AppPermission item) async {
    if (!_isAndroid || item.info) return true;
    if (!await applies(item)) return true;
    try {
      for (final p in item.perms) {
        if (!(await p.status).isGranted) return false;
      }
      if (item.needsLocationServices && !await locationServicesOn()) {
        return false;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// The system-wide location switch (Settings → Location), not the app's
  /// permission. Android returns ZERO BLE scan results while it is off, so this
  /// is a hard requirement for finding anyone over Bluetooth.
  Future<bool> locationServicesOn() async {
    if (!_isAndroid) return true;
    try {
      // HARD timeout. This is a platform-channel call, and PermissionGate.ready
      // consults it from a BOOT TASK that runs before runApp() — where the
      // plugin side is not necessarily answering yet. Without the timeout the
      // future never completed, boot never finished, and both devices sat on a
      // blank splash forever after a reboot. Never block the app on a probe.
      return await Geolocator.isLocationServiceEnabled()
          .timeout(const Duration(seconds: 2), onTimeout: () => true);
    } catch (_) {
      return true; // unknown: never block on a failed probe
    }
  }

  /// True when a permission was denied with "don't ask again" — a plain
  /// request() then no-ops, so the panel must send the user to app settings.
  Future<bool> isPermanentlyDenied(AppPermission item) async {
    if (!_isAndroid || item.info) return false;
    try {
      for (final p in item.perms) {
        if ((await p.status).isPermanentlyDenied) return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Request one item's permissions. Special-access items (All-files) open the
  /// system settings screen; the caller re-checks status on app resume.
  /// Returns the resulting granted state.
  Future<bool> requestItem(AppPermission item) async {
    if (!_isAndroid || item.info) return true;
    if (!await applies(item)) return true;
    try {
      if (await isPermanentlyDenied(item)) {
        // A prior "don't ask again" — the only path left is app settings.
        await openAppSettings();
        return isGranted(item);
      }
      final result = await item.perms.request();
      result.forEach((perm, status) =>
          LogService.instance.add('Permission $perm: ${status.name}'));
      if (item.needsLocationServices && !await locationServicesOn()) {
        // The permission is granted but the master switch is off — only the
        // settings screen can fix that, and the panel re-checks on resume.
        LogService.instance.add(
            'permissions: location services are off — opening location settings');
        await Geolocator.openLocationSettings();
      }
      return isGranted(item);
    } catch (e) {
      LogService.instance.add('AndroidPermissions: ${item.key} request failed: $e');
      return false;
    }
  }

  /// True when every required item is granted. Off Android always true (no
  /// runtime permissions), so the onboarding panel is skipped there.
  Future<bool> allGranted() async {
    if (!_isAndroid) return true;
    for (final i in required) {
      if (!await isGranted(i)) return false;
    }
    return true;
  }

  /// Request every required permission in sequence (each shows its own system
  /// dialog / settings screen). Used by the intro panel's "Grant all" button.
  Future<void> requestAll() async {
    if (!_isAndroid) return;
    for (final i in grantable) {
      if (!await isGranted(i)) await requestItem(i);
    }
  }

  // ── Legacy helpers kept for existing callers (profile backup, disk folders).

  /// What grants broad access to public storage on this OS: "All files access"
  /// from Android 11, READ/WRITE_EXTERNAL_STORAGE before it. An unknown API
  /// level keeps the modern answer, which is what every caller always had.
  Future<Permission> _filesPermission() async {
    final sdk = await platform.androidSdkInt();
    return sdk != 0 && sdk < _allFilesSdk
        ? Permission.storage
        : Permission.manageExternalStorage;
  }

  Future<bool> hasAllFilesAccess() async {
    if (!_isAndroid) return true;
    try {
      return (await (await _filesPermission()).status).isGranted;
    } catch (_) {
      return false;
    }
  }

  Future<bool> requestAllFilesAccess() async {
    if (!_isAndroid) return true;
    try {
      final p = await _filesPermission();
      if (p == Permission.storage && (await p.status).isPermanentlyDenied) {
        // A runtime dialog refused with "don't ask again" no longer shows;
        // only app settings can grant it now.
        await openAppSettings();
        return false;
      }
      final s = await p.request();
      LogService.instance.add('Permission $p: ${s.name}');
      return s.isGranted;
    } catch (e) {
      LogService.instance
          .add('AndroidPermissions: all-files request failed: $e');
      return false;
    }
  }
}
