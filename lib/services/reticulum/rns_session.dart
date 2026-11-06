/*
 * RnsSession — a hub, on request, for a phone on battery.
 *
 * In the normal profile (docs/performance.md 8.20) the node holds no public
 * hub: its day is Bluetooth, the LAN and the line to its archiver. Some
 * things still need the shared transport — serving a file a far station
 * asked for (the fetcher opens a Reticulum link to us, so we must be
 * announced through a hub), fetching one from a far holder, reaching a
 * contact only Reticulum carries. This is the session that pays for those:
 * one hub, up for as long as something holds it, down five minutes after
 * the last reason let go. In the station profile it is a no-op — the hubs
 * are up anyway.
 *
 * A request is cheap to make and idempotent, so callers ask at the moment
 * they know (a `cmd:file` answered 202, a fetch started, a directed wire
 * for the Reticulum bearer) and never check first.
 */
import 'dart:async';

import '../../wapp/android_foreground_service.dart';
import '../log_service.dart';
import '../power_state.dart';
import '../xprs/xprs_files.dart';
import 'rns_autostart.dart';
import 'rns_service.dart';

class RnsSession {
  RnsSession._();
  static final RnsSession instance = RnsSession._();

  /// How long a reason holds the hub after it was last asked for.
  static const Duration defaultHold = Duration(minutes: 5);

  /// While a fetch is still waiting for bytes the hub stays, a minute at a
  /// time, whatever the holds say.
  static const Duration busyExtension = Duration(minutes: 1);

  DateTime? _holdUntil;
  final Map<String, DateTime> _reasons = {};
  Timer? _timer;
  bool _tickArmed = false;
  bool _bringingUp = false;
  bool _profileWatched = false;
  int sessions = 0;

  bool get active =>
      _holdUntil != null && DateTime.now().isBefore(_holdUntil!);

  /// Hold a hub up for [hold] because of [reason]. Idempotent; extends.
  Future<void> request(String reason, {Duration hold = defaultHold}) async {
    _watchProfile();
    if (PowerState.instance.profile.value == PowerProfile.station) return;
    final until = DateTime.now().add(hold);
    if (_holdUntil == null || until.isAfter(_holdUntil!)) _holdUntil = until;
    _reasons[reason] = until;
    _arm();
    if (RnsService.instance.connectedHubs.isEmpty) await _bringUp(reason);
  }

  Future<void> _bringUp(String reason) async {
    if (_bringingUp) return;
    _bringingUp = true;
    try {
      LogService.instance.add('RNS session: up for $reason');
      final ok = await connectAnyHub();
      if (ok) {
        sessions++;
      } else {
        LogService.instance.add('RNS session: no hub answered');
      }
    } catch (e) {
      LogService.instance.add('RNS session: $e');
    } finally {
      _bringingUp = false;
    }
  }

  void _arm() {
    // Armed only while a session is held; on Android the native heartbeat
    // drives _tick as well, this is the fallback for the other platforms.
    _timer ??= Timer.periodic(const Duration(minutes: 1), (_) => _tick());
    if (!_tickArmed) {
      _tickArmed = true;
      AndroidForegroundService.instance.addTickListener(_tick);
    }
  }

  void _disarm() {
    _timer?.cancel();
    _timer = null;
    if (_tickArmed) {
      _tickArmed = false;
      AndroidForegroundService.instance.removeTickListener(_tick);
    }
  }

  void _watchProfile() {
    if (_profileWatched) return;
    _profileWatched = true;
    PowerState.instance.profile.addListener(() {
      // A station needs no session; a hold left over would otherwise drop
      // the hubs the station profile just connected.
      if (PowerState.instance.profile.value == PowerProfile.station) {
        if (_holdUntil != null) {
          _holdUntil = null;
          _reasons.clear();
          _disarm();
        }
        return;
      }
      // Unplugged with a hold still standing (a fetch in flight): the
      // profile switch released every hub a moment ago, and the fetch would
      // have sat extending its hold with nothing to extend. One hub comes
      // back for it; a beat later, so the release has happened first
      // whatever order the listeners fired in.
      if (active) {
        Timer(const Duration(seconds: 2), () {
          if (active && RnsService.instance.connectedHubs.isEmpty) {
            unawaited(_bringUp('profile normal, hold standing'));
          }
        });
      }
    });
  }

  void _tick() {
    if (_holdUntil == null) return;
    if (active) return;
    if (XprsFileFetch.instance.busy) {
      _holdUntil = DateTime.now().add(busyExtension);
      return;
    }
    _release('idle');
  }

  void _release(String why) {
    _holdUntil = null;
    _reasons.clear();
    _disarm();
    if (PowerState.instance.profile.value == PowerProfile.station) return;
    RnsService.instance.releaseHubs('session $why');
  }

  Map<String, Object?> get status => {
        'active': active,
        'until': _holdUntil?.toIso8601String(),
        'reasons': _reasons.keys.toList(),
        'hubs': RnsService.instance.connectedHubs.toList(),
        'sessions': sessions,
      };
}
