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

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter/services.dart';

import '../services/power_state.dart';
import 'background_wapp_manager.dart';

class AndroidForegroundService {
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

  bool get _supported => !kIsWeb && Platform.isAndroid;
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

  /// What the persistent notification says under the title.
  ///
  /// It used to enumerate the machinery: "Mesh node, Mail, Torrents running in
  /// background". That is the wrong thing to put on somebody's lock screen all
  /// day -- it reads as a list of things the phone is busy with rather than as
  /// what the app is for, and it named wapps the user may not have thought
  /// about since installing them. Android requires a foreground service to say
  /// something; this says what XPRS does.
  String _composeLabel() => 'Internet without internet';

  Future<void> _sync() async {
    if (!_supported) return;
    try {
      if (_holders.isNotEmpty) {
        // 'start' both starts the service and updates the notification text.
        await _channel.invokeMethod('start', {'text': _composeLabel()});
        _running = true;
      } else if (_running) {
        await _channel.invokeMethod('stop');
        _running = false;
      }
    } catch (e) {
      debugPrint('AndroidForegroundService: sync failed: $e');
    }
  }

  /// Add a named holder; starts the service if it wasn't running.
  Future<void> hold(String reason) async {
    _holders.add(reason);
    await _sync();
  }

  /// Release a named holder; stops the service when no holders remain.
  Future<void> release(String reason) async {
    _holders.remove(reason);
    await _sync();
  }

  void addTickListener(void Function() listener) =>
      _tickListeners.add(listener);

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
