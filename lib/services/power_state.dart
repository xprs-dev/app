/*
 * PowerState — one source of truth for how expensive the app is allowed to be
 * right now.
 *
 * The always-on half of this app is field-proven: a foreground service, a
 * native heartbeat, a scan that is never suspended. The battery half was a set
 * of constants — a 2 s tick, a standing wake lock, a high-performance WiFi
 * lock, one scan mode — all sized for the screen being on, and all still paid
 * for at 3 a.m. with nobody awake to read the result.
 *
 * The tier is what the rest of the app keys off. It never turns delivery OFF:
 * the scan keeps running, the service stays up, the hub link stays connected.
 * Only the COST changes.
 *
 *   active   screen on / app in the foreground — behave exactly as before
 *   idle     background, on a charger — the mains case, also unchanged
 *   battery  background, discharging — the case that matters
 *   low      background, under the governor's low-battery threshold
 *
 * Two rules the consumers must respect (docs/ble5.md, docs/mesh.md):
 *
 *   - Android throttles scan starts to roughly five per thirty seconds, so a
 *     tier change must be RARE. [minDwell] enforces that: a new tier is
 *     published only after the previous one has stood for a minute, except
 *     for the jump back to `active`, which the user is waiting for.
 *   - Delivery-critical work is exempt. A consumer that is mid-handover asks
 *     [holdActive] to be treated as `active` regardless of the tier.
 */
import 'dart:async';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'log_service.dart';
import '../platform/platform.dart' as platform;

enum PowerTier { active, idle, battery, low }

class PowerState with WidgetsBindingObserver {
  PowerState._();
  static final PowerState instance = PowerState._();

  static const _channel = MethodChannel('com.xprs.app/bg_service');
  bool get _android => platform.isAndroid;

  /// The published tier. Consumers listen; nothing polls.
  final ValueNotifier<PowerTier> tier = ValueNotifier(PowerTier.active);

  /// How long a tier must stand before the next demotion is published. A scan
  /// mode follows this notifier, and Android counts scan starts.
  static const Duration minDwell = Duration(seconds: 60);

  /// Pause non-critical work at or below this level while discharging (the
  /// threshold PowerGovernor has always used).
  int lowThreshold = 20;

  final Battery _battery = Battery();
  StreamSubscription<BatteryState>? _sub;
  Timer? _poll;
  Timer? _pending;
  bool _running = false;

  bool _screenOn = true;
  bool _foreground = true;
  bool _powered = true;
  int _level = 100;
  DateTime _lastChange = DateTime.fromMillisecondsSinceEpoch(0);

  /// Named holders that force the `active` tier: an open GATT session, a
  /// custody handover, a bulk transfer, an armed file fetch. Delivery in
  /// flight is never made slower to save battery (docs/ble5.md 4).
  final Set<String> _active = {};

  bool get isBackgroundSaving =>
      tier.value == PowerTier.battery || tier.value == PowerTier.low;

  /// Plugged in: charging, full, connected-not-charging, or no battery at
  /// all (a desktop). THE definition, for everybody: MeshService, the
  /// Wi-Fi Direct coordinator and the capacity governor each used to read
  /// battery_plus on their own and disagreed on "connected, not charging".
  bool get isPowered => _powered;

  /// [isPowered] as a notifier, for consumers that act on the change.
  final ValueNotifier<bool> powered = ValueNotifier(true);

  /// Last battery percentage read (two-minute poll plus every charge event).
  int get batteryLevel => _level;

  /// The native heartbeat period for the current tier (BgService.applyTier),
  /// so a Dart fallback can tell "the service is driving" from "it stopped".
  int get nativeTickMs => switch (tier.value) {
        PowerTier.battery => 10000,
        PowerTier.low => 30000,
        PowerTier.active || PowerTier.idle => 2000,
      };

  // ── The room: is anybody there? ──────────────────────────────────────────
  //
  // A radio in an empty room costs the same as one in a crowd, and most of
  // a phone's day is the empty room. The BLE scan is filtered on our marker,
  // so "when did the scan last deliver a frame" IS "when was another XPRS
  // radio last heard"; the legacy scan's discovered presence adverts count
  // too. Five minutes of neither and the room is empty: the scan, the
  // presence advert and the beacon go to their cheapest settings
  // (docs/mesh.md 7). The first frame heard turns it back, on the next tick,
  // with no dwell — a scan-mode change costs a scan start, and after five
  // silent minutes the budget for one is there.

  /// True when no XPRS radio has been heard for [aloneAfter].
  final ValueNotifier<bool> alone = ValueNotifier(false);
  static const Duration aloneAfter = Duration(minutes: 5);
  int _lastAirMs = 0;

  /// The BLE service reports, on its tick, when the air last carried a
  /// neighbour: the scan's last marker frame and the last discovered
  /// presence advert, as ms since the epoch (0 = never).
  void noteAir(int lastFrameMs, int lastDiscoveredMs) {
    final latest = lastFrameMs > lastDiscoveredMs ? lastFrameMs : lastDiscoveredMs;
    if (latest > _lastAirMs) _lastAirMs = latest;
    final now = DateTime.now().millisecondsSinceEpoch;
    // Never heard anybody since start: measure from start, not from 1970,
    // or a fresh process would be "alone" before its scan had a chance.
    final since = _lastAirMs == 0 ? _startedMs : _lastAirMs;
    final want = now - since >= aloneAfter.inMilliseconds;
    if (want != alone.value) {
      LogService.instance.add(want
          ? 'power: alone (no XPRS radio heard for ${aloneAfter.inMinutes} min)'
          : 'power: company (an XPRS radio is in range)');
      alone.value = want;
    }
  }

  final int _startedMs = DateTime.now().millisecondsSinceEpoch;

  Future<void> start() async {
    if (_running) return;
    _running = true;
    // A headless engine gets no lifecycle events at all — the native screen
    // broadcast is what tells it the truth there (BgService.screenReceiver);
    // this observer covers the ordinary foreground/background case.
    try {
      WidgetsBinding.instance.addObserver(this);
      _foreground =
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    } catch (_) {}
    tier.addListener(_pushToNative);
    try {
      await _readBattery();
      // Charging state is event-driven; the level has no stream, and two
      // minutes is fast enough for a threshold nothing reacts to instantly.
      _sub = _battery.onBatteryStateChanged.listen((_) => _readBattery());
      _poll = Timer.periodic(const Duration(minutes: 2), (_) => _readBattery());
    } catch (e) {
      debugPrint('PowerState: battery unavailable ($e)');
    }
    _recompute();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      setForeground(state == AppLifecycleState.resumed);

  Future<void> _pushToNative() async {
    debugPrint('PowerState: tier -> ${tier.value.name} $status');
    LogService.instance.add('power: tier ${tier.value.name} '
        '(screen=${_screenOn ? 'on' : 'off'} '
        '${_powered ? 'charging' : '$_level%'}'
        '${_active.isEmpty ? '' : ' holds=${_active.length}'})');
    if (!_android) return;
    try {
      await _channel.invokeMethod('power.tier', {'tier': tier.value.name});
    } catch (e) {
      debugPrint('PowerState: tier push failed: $e');
    }
  }

  void stop() {
    tier.removeListener(_pushToNative);
    try {
      WidgetsBinding.instance.removeObserver(this);
    } catch (_) {}
    _running = false;
    _sub?.cancel();
    _sub = null;
    _poll?.cancel();
    _poll = null;
    _pending?.cancel();
    _pending = null;
  }

  /// The native service saw ACTION_SCREEN_ON/OFF.
  void setScreenOn(bool on) {
    if (_screenOn == on) return;
    debugPrint('PowerState: screen ${on ? 'on' : 'off'}');
    _screenOn = on;
    _recompute();
  }

  /// The Flutter binding's lifecycle: resumed vs anything else.
  void setForeground(bool foreground) {
    if (_foreground == foreground) return;
    debugPrint('PowerState: ${foreground ? 'foreground' : 'background'}');
    _foreground = foreground;
    _recompute();
  }

  /// Treat the device as `active` while [reason] holds — delivery in flight.
  void holdActive(String reason) {
    if (_active.add(reason)) _recompute();
  }

  void releaseActive(String reason) {
    if (_active.remove(reason)) _recompute();
  }

  bool get hasActiveHold => _active.isNotEmpty;

  Future<void> _readBattery() async {
    try {
      final level = await _battery.batteryLevel;
      final state = await _battery.batteryState;
      // A device with no battery (most desktops) reports `unknown` and a bogus
      // 0% — that is mains power, not an emergency. Getting this wrong once
      // left desktops permanently throttled at a phantom 0%.
      // Plugged in, not necessarily charging: a phone at 100% on a charger
      // reports connectedNotCharging and is on mains as far as any role is
      // concerned.
      _powered = state == BatteryState.charging ||
          state == BatteryState.full ||
          state == BatteryState.connectedNotCharging ||
          state == BatteryState.unknown;
      _level = level;
      if (powered.value != _powered) powered.value = _powered;
      _recompute();
    } catch (_) {}
  }

  PowerTier get _target {
    if (_screenOn || _foreground || _active.isNotEmpty) return PowerTier.active;
    if (_powered) return PowerTier.idle;
    if (_level <= lowThreshold) return PowerTier.low;
    return PowerTier.battery;
  }

  void _recompute() {
    final want = _target;
    if (want == tier.value) {
      _pending?.cancel();
      _pending = null;
      return;
    }
    // Going back to `active` is what the user is waiting for: publish it now.
    // Every other transition waits out the dwell, so battery-percent noise
    // around a threshold cannot spend the scan-start budget.
    final now = DateTime.now();
    final waited = now.difference(_lastChange);
    if (want == PowerTier.active || waited >= minDwell) {
      _publish(want, now);
      return;
    }
    _pending?.cancel();
    _pending = Timer(minDwell - waited, _recompute);
  }

  void _publish(PowerTier want, DateTime now) {
    _pending?.cancel();
    _pending = null;
    _lastChange = now;
    tier.value = want;
  }

  /// For the diagnostics page and `perf:` lines.
  Map<String, Object?> get status => {
        'tier': tier.value.name,
        'screenOn': _screenOn,
        'foreground': _foreground,
        'powered': _powered,
        'level': _level,
        'holds': _active.toList(),
      };
}
