/*
 * Platform abstraction — native (dart:io) implementation.
 *
 * Selected by `platform.dart` on every target that exposes
 * `dart.library.io`: Linux / macOS / Windows desktop, plus mobile.
 * Web picks up `platform_stubs.dart` instead. Keep the public API
 * of this file byte-identical to the stubs file so the conditional
 * import is a drop-in.
 */

import 'dart:async';
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/services.dart' show MethodChannel;

// The plain-Dart half (OS predicates, paths, subprocesses, locale) is the
// core's: package:xprs_core/src/platform/os.dart.
export 'package:xprs_core/src/platform/os_io.dart';

/// Tell the Android host that Dart got far enough to own a root widget, so a
/// view may safely be attached to this engine.
///
/// The engine created at boot has no Activity, so anything that throws before
/// the first `runApp` leaves it rootless — and [MainActivity] would hand that
/// rootless engine to the UI, which renders black forever. The host keeps this
/// flag and refuses to reuse an engine that never sent it. No-op off Android.
Future<void> signalDartReady() async {
  try {
    if (!Platform.isAndroid) return;
    await _bgChannel.invokeMethod('dartReady');
  } catch (_) {
    // Nothing to report to: a missing host handler only means the engine is
    // not reusable, which is exactly the safe default.
  }
}

/// The Android API level (`Build.VERSION.SDK_INT`), or 0 off Android and when
/// the host does not answer. Asked once, then cached: it cannot change while
/// the process lives. The bg_service channel is bound before `main()` runs on
/// every engine, so this is safe from boot tasks too, but it still has a hard
/// timeout because nothing may block boot on a probe.
Future<int> androidSdkInt() => _sdkInt ??= _querySdkInt();
Future<int>? _sdkInt;

Future<int> _querySdkInt() async {
  if (!Platform.isAndroid) return 0;
  try {
    final v = await _bgChannel
        .invokeMethod<int>('sdkInt')
        .timeout(const Duration(seconds: 2));
    return v ?? 0;
  } catch (_) {
    _sdkInt = null; // let a later call try again
    return 0;
  }
}

/// Whether this engine has a view to draw into. False on the headless engine
/// the boot receiver starts, where UI-only platform channels have no handler.
bool get hasImplicitView => PlatformDispatcher.instance.implicitView != null;

/// Show the OS notification. Returns true when the person ACTED on it --
/// pressed its button -- so the caller can take them where it was about.
///
/// On Linux a notification is a `notify-send` toast, and a toast with no
/// action is a dead rectangle: it says a doorbell rang and leaves the person
/// to go and find the doorbell. `--action` gives it a button and prints the
/// action's name when it is pressed, which is the whole of the routing.
Future<bool> showSystemNotification({
  required String title,
  String? body,
  bool error = false,
  String? wapp,
  String? convo,
  String? view,
}) async {
  try {
    if (Platform.isLinux) {
      final routable = wapp != null && wapp.isNotEmpty;
      final args = <String>[
        '--app-name=xprs',
        if (error) '--urgency=critical',
        // Two actions on purpose. `default` is the one a desktop fires when
        // the person clicks the NOTIFICATION ITSELF, which is what anybody
        // does and what did nothing before this: without it a toast is a
        // rectangle that says a doorbell rang and swallows the click. `open`
        // is a visible button beside it, for shells that show actions but
        // have no notion of a default one.
        if (routable) ...['--action=default=Open', '--action=open=Open', '--wait'],
        title,
        if (body != null && body.isNotEmpty) body,
      ];
      if (!routable) {
        await Process.run('notify-send', args);
        return false;
      }
      // Started rather than run, because `--wait` sits there until the
      // notification is answered or dismissed: a doorbell nobody came back
      // to would leave the process for the life of the session, and there
      // is one per ring. Ten minutes is longer than anybody's walk to the
      // phone and shorter than forever.
      final proc = await Process.start('notify-send', args);
      final timer = Timer(const Duration(minutes: 10), () {
        try {
          proc.kill();
        } catch (_) {}
      });
      final out = await proc.stdout.transform(const SystemEncoding().decoder).join();
      timer.cancel();
      // Line-wise: notify-send prints the action it was given, and may have
      // printed other things (an id) before it.
      for (final line in out.split('\n')) {
        final k = line.trim();
        if (k == 'open' || k == 'default') return true;
      }
      return false;
    } else if (Platform.isMacOS) {
      final escaped = (body ?? '').replaceAll('"', '\\"');
      final titleEsc = title.replaceAll('"', '\\"');
      await Process.run('osascript', [
        '-e',
        'display notification "$escaped" with title "$titleEsc"',
      ]);
    } else if (Platform.isAndroid) {
      // Route to the native foreground-service bridge, which posts a heads-up
      // notification (works while backgrounded / headless from boot). Ids
      // cycle inside 9000..9099 — BgBridge.clearEvents sweeps exactly that
      // range, and the service (7001) / media (7002) ids stay clear of it.
      _androidNotifId = 9000 + ((_androidNotifId - 9000 + 1) % 100);
      await _bgChannel.invokeMethod('notify', {
        'id': _androidNotifId,
        'title': title,
        if (body != null && body.isNotEmpty) 'body': body,
        if (wapp != null && wapp.isNotEmpty) 'wapp': wapp,
        if (convo != null && convo.isNotEmpty) 'convo': convo,
        if (view != null && view.isNotEmpty) 'view': view,
      });
    }
    // Windows native balloon not implemented — use winrt toast later.
  } catch (_) {
    // Ignore — the in-app overlay is the source of truth anyway.
  }
  return false;
}

/// Bring this app's window in front of whatever the person is looking at.
///
/// Opening the right screen is half the answer to a notification: the other
/// half is being able to see it. Flutter's desktop embedder has no "present
/// yourself" call, so this asks the window manager through whichever of the
/// usual two tools is installed, and does nothing at all where neither is.
Future<void> raiseAppWindow() async {
  if (!Platform.isLinux) return;
  for (final attempt in [
    ['wmctrl', '-a', 'XPRS'],
    ['xdotool', 'search', '--name', '^XPRS\$', 'windowactivate'],
  ]) {
    try {
      final r = await Process.run(attempt.first, attempt.sublist(1));
      if (r.exitCode == 0) return;
    } catch (_) {
      // not installed; try the next one
    }
  }
}

/// Remove every event notification this app put in the OS shade. Called when
/// the user reads (or clears) the in-app notification center, so the shade —
/// and the launcher-icon dot it feeds — always agrees with what the user has
/// seen. Android only; desktop notifications are transient toasts already.
Future<void> clearSystemNotifications() async {
  try {
    if (Platform.isAndroid) {
      await _bgChannel.invokeMethod('notify_clear');
    }
  } catch (_) {}
}

/// Withdraw the OS notifications about what the person is now looking at: a
/// conversation [convo] or a view [view] inside [wapp], or, with neither, the
/// notifications of [wapp] that named no target. The rule that decides what
/// counts as seen is NotificationService.markSeen's; this only carries it to
/// the shade. Android only: a desktop toast is transient already.
Future<void> withdrawSystemNotifications(
    {required String wapp, String? convo, String? view, bool all = false}) async {
  try {
    if (Platform.isAndroid) {
      await _bgChannel.invokeMethod('notify_seen', {
        'wapp': wapp,
        if (all) 'all': true,
        if (convo != null && convo.isNotEmpty) 'convo': convo,
        if (view != null && view.isNotEmpty) 'view': view,
      });
    }
  } catch (_) {}
}

// Native bridge for Android system notifications (shared with the foreground
// service). A rolling id so distinct events stack instead of replacing.
const MethodChannel _bgChannel = MethodChannel('com.xprs.app/bg_service');
int _androidNotifId = 9000;

