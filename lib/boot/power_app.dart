/*
 * The app's device inputs to the core's PowerState: the battery
 * (battery_plus), the app lifecycle (foreground/background), and the native
 * service that retunes its heartbeat from the tier.
 */
import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter/widgets.dart';
import 'package:xprs_core/src/platform/battery.dart';

import '../services/power_state.dart';

/// battery_plus behind the core's BatterySource.
class BatteryPlusSource implements BatterySource {
  BatteryPlusSource();
  final Battery _b = Battery();

  static BatteryCondition _map(BatteryState s) => switch (s) {
        BatteryState.charging => BatteryCondition.charging,
        BatteryState.connectedNotCharging => BatteryCondition.connectedNotCharging,
        BatteryState.discharging => BatteryCondition.discharging,
        BatteryState.full => BatteryCondition.full,
        BatteryState.unknown => BatteryCondition.unknown,
      };

  @override
  Future<int> level() => _b.batteryLevel;
  @override
  Future<BatteryCondition> condition() async => _map(await _b.batteryState);
  @override
  Stream<BatteryCondition> get changes => _b.onBatteryStateChanged.map(_map);
}

const MethodChannel _bgChannel = MethodChannel('com.xprs.app/bg_service');

/// Hand the tier to the native foreground service (Android only; the core
/// calls this only there).
Future<void> pushPowerTierToNative(String tier) =>
    _bgChannel.invokeMethod('power.tier', {'tier': tier});

/// Foreground/background into PowerState, which used to observe Flutter's
/// lifecycle itself.
class _LifecycleToPower with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      PowerState.instance.setForeground(state == AppLifecycleState.resumed);
}

final _lifecycle = _LifecycleToPower();

/// Start feeding the lifecycle; idempotent enough for one call at boot.
void observeLifecycleForPower() {
  try {
    WidgetsBinding.instance.addObserver(_lifecycle);
    PowerState.instance.initForeground(
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed);
  } catch (_) {}
}
