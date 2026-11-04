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

import '../services/android_permissions_service.dart';
import '../services/hero/launcher_visibility.dart';
import '../services/notification_service.dart';
import '../wapp/android_foreground_service.dart';
import '../wapp/geoui/widgets/media_view.dart' show sharedMediaArchive;
import 'core_stores_app.dart';
import 'sqlite_prepare.dart';

/// Called once at boot, before any core service starts.
void wireCoreHost() {
  CoreHost.keepAlive = AndroidForegroundService.instance;
  CoreHost.anyoneLooking = () => LauncherVisibility.instance.visible.value;
  CoreHost.mediaArchive = sharedMediaArchive;
  CoreHost.notify = NotificationService.instance.show;
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
}
