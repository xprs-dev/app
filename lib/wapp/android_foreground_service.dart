/*
 * Android foreground-service bridge.
 *
 * Keeps the app process alive (with a persistent notification) while one or
 * more wapps run in the background, so BLE/APRS-IS receive keeps working with
 * the screen off / app backgrounded. The native service also drives a periodic
 * heartbeat via the method channel ('onTick'), because Dart Timers are
 * throttled in the background while a native Handler is not — see
 * BackgroundWappManager.tickAllFromNative.
 *
 * No-op on every non-Android platform (desktop keeps the process alive anyway).
 */


import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter/services.dart';

import '../services/i18n/core_i18n.dart';
import '../profile/profile_service.dart';
import '../services/power_state.dart';
import '../services/xprs/xprs_monitor.dart';
import 'background_wapp_manager.dart';
import '../platform/platform.dart' as platform;
import 'package:xprs_core/src/platform/core_host.dart' show KeepAlive;

class AndroidForegroundService implements KeepAlive {
  AndroidForegroundService._() {
    if (_supported) _channel.setMethodCallHandler(_onCall);
  }
  static final AndroidForegroundService instance = AndroidForegroundService._();

  static const _channel = MethodChannel('com.xprs.app/bg_service');
  bool _running = false;

  // Ref-counted holders. The native foreground service is started when the
  // first holder appears and stopped only when the last one is released, so
  // several subsystems (background wapps, the Reticulum node) can each keep the
  // process alive independently without stomping on each other.
  final Set<String> _holders = {};
  final Set<void Function()> _tickListeners = {};

  bool get _supported => platform.isAndroid;

  /// The native heartbeat exists only on Android.
  @override
  bool get ticks => _supported;
  bool get isRunning => _running;

  /// Set by the wapp page that currently owns media playback; the native
  /// MediaSession routes lock-screen / notification button presses here.
  void Function(String action)? onMediaAction;

  Future<dynamic> _onCall(MethodCall call) async {
    if (call.method == 'onTick') {
      // Native heartbeat — advance every live background engine.
      BackgroundWappManager.instance.tickAllFromNative();
      for (final listener in List<void Function()>.of(_tickListeners)) {
        listener();
      }
      unawaited(_refreshLabel());
    } else if (call.method == 'power.screen') {
      // The native service saw ACTION_SCREEN_ON/OFF. This is the only screen
      // signal a headless engine ever gets.
      PowerState.instance.setScreenOn(call.arguments == true);
    } else if (call.method == 'media.action') {
      final action = (call.arguments is Map)
          ? (call.arguments['action']?.toString() ?? '')
          : call.arguments?.toString() ?? '';
      if (action.isNotEmpty) onMediaAction?.call(action);
    }
    return null;
  }

  /// Push the current media-session state to the native MediaSession so the
  /// lock-screen / notification panel shows it with transport controls.
  Future<void> mediaUpdate(Map<String, dynamic> info) async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod('media.update', info);
    } catch (e) {
      debugPrint('AndroidForegroundService: media.update failed: $e');
    }
  }

  /// Tear down the media notification/session (playback stopped).
  Future<void> mediaStop() async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod('media.stop');
    } catch (e) {
      debugPrint('AndroidForegroundService: media.stop failed: $e');
    }
  }

  /// What the persistent notification says under the title: who this device
  /// is on the air, and how many XPRS stations it can reach without the
  /// internet -- "Active as X1ABCD · 3 reachable". Tapping it opens the Mesh
  /// wapp, which lists them (BgService.buildNotification).
  ///
  /// It once enumerated the machinery ("Mesh node, Mail, Torrents running in
  /// background"), then became the tagline "Internet without internet". The
  /// tagline stays for a start with no profile yet (a headless boot, the
  /// welcome screen) and before the translation tables load.
  String _composeLabel() {
    final call = ProfileService.instance.activeProfile?.wireCallsign ?? '';
    if (!CoreI18n.instance.ready) {
      return call.isEmpty ? 'Internet without internet' : 'Active as $call';
    }
    if (call.isEmpty) return tr('wapp_host.service.label');
    final n = XprsMonitor.instance.reachableCount();
    final active = tr('wapp_host.service.active', {'callsign': call});
    return n == 0 ? active : '$active · ${trn('wapp_host.service.reachable', n)}';
  }

  /// The text the notification shows now, so a tick only crosses the
  /// channel when it changed.
  String? _shownLabel;

  /// Re-reads the label on every native tick: stations come and go (and age
  /// out without any event), and the profile can switch.
  Future<void> _refreshLabel() async {
    if (!_supported || !_running || _holders.isEmpty) return;
    final label = _composeLabel();
    if (label == _shownLabel) return;
    _shownLabel = label;
    try {
      await _channel.invokeMethod('text', {'text': label});
    } catch (e) {
      debugPrint('AndroidForegroundService: text failed: $e');
    }
  }

  Future<void> _sync() async {
    if (!_supported) return;
    try {
      if (_holders.isNotEmpty) {
        // 'start' both starts the service and updates the notification text.
        // false: Android refused the foreground start (BgBridge). The app
        // runs on without it; the next hold asks again.
        final label = _composeLabel();
        final ok =
            await _channel.invokeMethod<bool>('start', {'text': label});
        _running = ok ?? true;
        _shownLabel = label;
      } else if (_running) {
        await _channel.invokeMethod('stop');
        _running = false;
      }
    } catch (e) {
      debugPrint('AndroidForegroundService: sync failed: $e');
    }
  }

  /// Add a named holder; starts the service if it wasn't running.
  @override
  Future<void> hold(String reason) async {
    _holders.add(reason);
    await _sync();
  }

  /// Release a named holder; stops the service when no holders remain.
  @override
  Future<void> release(String reason) async {
    _holders.remove(reason);
    await _sync();
  }

  @override
  void addTickListener(void Function() listener) =>
      _tickListeners.add(listener);

  @override
  void removeTickListener(void Function() listener) =>
      _tickListeners.remove(listener);

  /// Background-wapp holder: start the service for the given running wapps.
  /// Releasing happens via [stop].
  ///
  /// [wappNames] no longer reaches the notification -- it used to be joined
  /// into the text, which is how a lock screen ended up listing somebody's
  /// wapps all day. Kept in the signature because it is what the call sites
  /// have, and because what is running is worth having here if the text ever
  /// needs to vary again.
  Future<void> start(List<String> wappNames) async {
    await hold('wapps');
  }

  /// Release the background-wapp holder (the service stays up if e.g. the
  /// Reticulum node still holds it).
  Future<void> stop() async {
    await release('wapps');
  }

  /// The person asked to exit: drop every holder and stop the service
  /// whatever this side believes is running. The service is START_STICKY,
  /// so a process that died with it still started would be brought back.
  Future<void> shutdown() async {
    _holders.clear();
    if (!_supported) return;
    try {
      await _channel.invokeMethod('stop');
    } catch (e) {
      debugPrint('AndroidForegroundService: stop failed: $e');
    }
    _running = false;
  }

  /// Post a heads-up Android notification for a message/event. No-op off Android.
  Future<void> notify({
    required int id,
    required String title,
    String? body,
  }) async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod('notify', {
        'id': id,
        'title': title,
        if (body != null) 'body': body,
      });
    } catch (e) {
      debugPrint('AndroidForegroundService: notify failed: $e');
    }
  }
}
