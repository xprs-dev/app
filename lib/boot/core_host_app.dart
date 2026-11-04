/*
 * This app's answers to CoreHost (package:xprs_core): the few things the core
 * needs from the program it runs in, backed here by Flutter and Android.
 * The server edition wires its own; tests keep the defaults (see
 * test/flutter_test_config.dart for the ones the app's tests rely on).
 */
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:xprs_core/src/platform/core_host.dart';
import 'package:xprs_core/src/services/notifications/notification.dart';

import '../services/android_permissions_service.dart';
import '../services/hero/launcher_visibility.dart';
import '../services/notification_service.dart';
import '../wapp/android_foreground_service.dart';
import '../wapp/geoui/widgets/media_view.dart' show sharedMediaArchive;
import '../connections/bluetooth/ble_rns_radio.dart';
import '../services/files/open_path.dart';
import '../services/flash/flash_service.dart';
import '../services/location_service.dart';
import 'core_stores_app.dart';
import 'power_app.dart';
import 'radio_app.dart';
import 'sqlite_prepare.dart';

/// Which wapp shows a notification the core raised about a topic. The core
/// says what a notification is about (`core:nostr`); which wapp handles that
/// here is this app's decision, not the core's (architecture.md §3).
const Map<String, String> coreNotificationWapps = {
  'core:nostr': 'social',
  'core:archiver': 'archiver',
};

/// [n] with a core topic replaced by `wapp:<the wapp that handles it>`.
XprsNotification routeCoreNotification(XprsNotification n) {
  final wapp = coreNotificationWapps[n.source];
  return wapp == null ? n : n.withSource('wapp:$wapp');
}

/// Called once at boot, before any core service starts.
void wireCoreHost() {
  CoreHost.keepAlive = AndroidForegroundService.instance;
  CoreHost.anyoneLooking = () => LauncherVisibility.instance.visible.value;
  CoreHost.mediaArchive = sharedMediaArchive;
  CoreHost.notify = (n) => NotificationService.instance.show(routeCoreNotification(n));
  CoreHost.openPreferences = SharedPreferencesStore.open;
  CoreHost.secureStore = const FlutterSecureStore(FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  ));
  CoreHost.assets = const BundleAssets();
  CoreHost.appSupportDir = () async {
    try {
      return (await getApplicationSupportDirectory()).path;
    } catch (_) {
      return null;
    }
  };
  CoreHost.hasView = () => PlatformDispatcher.instance.views.isNotEmpty;
  CoreHost.prepareSqlite = prepareAppSqlite;
  CoreHost.hasAllFilesAccess =
      AndroidPermissionsService.instance.hasAllFilesAccess;
  CoreHost.battery = BatteryPlusSource();
  CoreHost.pushPowerTier = pushPowerTierToNative;
  observeLifecycleForPower();
  CoreHost.radio = const AppAdvertRadio();
  CoreHost.newBle5RnsRadio = Ble5ChunkedRnsRadio.new;
  CoreHost.newGattRnsRadio = BleServiceRnsRadio.new;
  CoreHost.openFile = openFileWithSystem;
  CoreHost.openFolder = openFolderOnDisk;
  CoreHost.locationFix = LocationService.instance.fixForPeer;
  CoreHost.perfSources['flash'] = FlashService.instance.drainStats;
}
