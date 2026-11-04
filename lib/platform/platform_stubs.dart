/*
 * Platform abstraction — web stubs.
 *
 * This file is selected by `platform.dart` on every target that does
 * NOT have `dart.library.io` (i.e. Flutter web). Every function here
 * has a no-op / default implementation so the rest of the codebase
 * can call through without knowing which platform it's running on.
 *
 * The native equivalent lives in `platform_io.dart` and uses
 * Platform/Process/File/Directory. Keep the signatures in sync.
 */

// The plain-Dart half is the core's (package:xprs_core/src/platform/os.dart).
export 'package:xprs_core/src/platform/os_web.dart';

/// The user's preferred locale. On web we fall back to English;
/// callers override via [PreferencesService.localePreference] anyway.
/// Tell the host that Dart owns a root widget. Android-only concern
/// (the engine started by the boot receiver); no-op on web.
Future<void> signalDartReady() async {}

/// The Android API level. Always 0 on web.
Future<int> androidSdkInt() async => 0;

/// Whether this engine has a view to draw into. Always true on web —
/// there is no headless engine there.
bool get hasImplicitView => true;

/// Fire a desktop system notification. No-op on web: the browser
/// has its own Notification API but gating it behind permission
/// prompts is out of scope for this abstraction.
Future<bool> showSystemNotification({
  required String title,
  String? body,
  bool error = false,
  String? wapp,
  String? convo,
  String? view,
}) async {
  // no-op: on web the in-app layer is the only notification surface
  return false;
}

Future<void> raiseAppWindow() async {
  // no-op: a browser tab presents itself
}

/// Remove app-posted OS notifications. No-op on web (there are none).
Future<void> clearSystemNotifications() async {}

/// Withdraw the OS notifications about one target (see platform_io). No-op on
/// web: the in-app layer is the only notification surface there.
Future<void> withdrawSystemNotifications(
    {required String wapp, String? convo, String? view, bool all = false}) async {}

/// True when the current platform supports spawning subprocesses
/// (Linux / macOS / Windows). Web and mobile return false so
/// callers can show a graceful "not supported here" message.
