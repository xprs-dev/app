/*
 * PowerGovernor — pauses non-critical background tasks on low battery and
 * resumes them when power recovers, complementing the task monitor's CPU-budget
 * governor. Host-generic: it operates on the task monitor, not on any specific
 * service, so every BackgroundService (priority != critical) is throttled
 * uniformly via its onPause()/onResume() hooks.
 *
 * The battery reading itself now lives in [PowerState], which every part of the
 * app keys off — the BLE scan mode, the native heartbeat, the wake and WiFi
 * locks, the wapp tick rates. This governor became one of its consumers rather
 * than a second, separate battery poll with its own thresholds: it reaches
 * three registered services, and the tier reaches everything else.
 */
import 'dart:async';

import 'log_service.dart';
import 'power_state.dart';
import 'task_monitor_service.dart';

class PowerGovernor {
  PowerGovernor._();
  static final PowerGovernor instance = PowerGovernor._();

  bool _throttled = false;
  bool _running = false;

  /// Pause non-critical tasks at or below this level while discharging.
  /// Published to [PowerState], which owns the reading.
  int lowThreshold = 20;

  Future<void> start() async {
    if (_running) return;
    _running = true;
    PowerState.instance.lowThreshold = lowThreshold;
    await PowerState.instance.start();
    PowerState.instance.tier.addListener(_evaluate);
    _evaluate();
  }

  void _evaluate() {
    final low = PowerState.instance.tier.value == PowerTier.low;
    if (low == _throttled) return;
    _throttled = low;
    if (low) {
      final n = TaskMonitorService.instance.pauseAllNonCritical();
      LogService.instance.add('PowerGovernor: low battery, paused $n '
          'background task(s)');
    } else {
      final n = TaskMonitorService.instance.resumeAll();
      LogService.instance.add('PowerGovernor: power ok, resumed $n '
          'background task(s)');
    }
  }

  void stop() {
    _running = false;
    PowerState.instance.tier.removeListener(_evaluate);
  }
}
