/*
 * This app's answers to CoreHost (package:xprs_core): the few things the core
 * needs from the program it runs in, backed here by Flutter and Android.
 * The server edition wires its own; tests keep the defaults.
 */
import 'package:xprs_core/src/platform/core_host.dart';

import '../services/hero/launcher_visibility.dart';
import '../wapp/android_foreground_service.dart';
import '../wapp/geoui/widgets/media_view.dart' show sharedMediaArchive;

/// Called once at boot, before any core service starts.
void wireCoreHost() {
  CoreHost.keepAlive = AndroidForegroundService.instance;
  CoreHost.anyoneLooking = () => LauncherVisibility.instance.visible.value;
  CoreHost.mediaArchive = sharedMediaArchive;
}
