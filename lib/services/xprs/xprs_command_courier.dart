// A command a wapp hands the core is delivered by the core: aired, aired
// again until the station answers, and given up when XPRS.md 11.4's window
// closes.
//
// Why here and not in the wapp (docs/architecture.md 1 and 3): retrying is a
// transport decision. The Firmwares wapp first did it itself, re-sending on a
// schedule of its own and subscribing to every observation on the air to have
// a clock to do it by, which is the store-and-forward mistake chat made once.
// The wapp now sends once and is told: the answer arrives on `xprs.result`
// like any packet, and a command that never got a final answer is reported
// on `xprs.status.tx` as `unanswered` (nothing heard) or `unfinished` (a 202
// and nothing after it).
//
// The SIGNED wire is aired each time. Its section 5 identifier is what the
// station recognises a repeat by (11.4, 11.10), so a re-stamped command would
// be a new command, and re-signing it would be a curve operation per re-air
// on the UI isolate for nothing (docs/performance.md 8.13).
//
// A re-air fans out. The first send takes section 36.0's path choice; silence
// after it is evidence that the chosen path did not reach the station, which
// is the case the section's own fallback is for.
//
// Driven by BgService's native heartbeat on Android (docs/performance.md
// 8.2), and only while something is in flight: nothing here runs when no
// command is waiting.
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../platform/platform.dart' as platform;
import '../../wapp/android_foreground_service.dart';
import '../log_service.dart';
import '../receive/wapp_delivery.dart';
import 'xprs_id.dart';
import 'xprs_packet.dart';
import 'xprs_publisher.dart';
import 'xprs_vocab.dart';

class XprsCommandCourier {
  XprsCommandCourier._();
  static final XprsCommandCourier instance = XprsCommandCourier._();

  /// When to air it again, counted from the first send: a station being set
  /// up may be restarting, joining a network, or at the edge of a link.
  static const List<Duration> schedule = [
    Duration(seconds: 30),
    Duration(seconds: 60),
    Duration(seconds: 100),
    Duration(seconds: 160),
  ];

  /// XPRS.md 11.4: a command expires 300 seconds after its `ts:`.
  static const Duration window = Duration(seconds: 300);

  /// How long an advert-style bearer keeps each copy on air: until just past
  /// the next re-air, so an answered command leaves the rotation soon after.
  static const Duration advertTtl = Duration(seconds: 45);

  static const int maxPending = 16;

  /// Airs [wire] and returns the exact wire that went out (signed when it
  /// speaks as this station). Injected so the loop runs in a test with no
  /// radio (docs/architecture.md 4, the mail relay's pattern).
  @visibleForTesting
  String Function(String wire, {required String slot, required bool spread}) air =
      (wire, {required slot, required spread}) {
    final pub = XprsPublisher.instance;
    // publishWire signs and records lastWire before its first await, so the
    // signed bytes are readable the moment the call returns.
    unawaited(pub.publishWire(wire,
        slot: slot, ttl: advertTtl, spread: spread));
    return pub.lastWire ?? wire;
  };

  @visibleForTesting
  void Function(String slot) withdraw =
      (slot) => unawaited(XprsPublisher.instance.withdraw(slot));

  @visibleForTesting
  void Function(String id, String peer, String state) report =
      (id, peer, state) =>
          WappDelivery.instance.deliverStatus(id: id, peer: peer, state: state);

  @visibleForTesting
  int Function() nowMs = () => DateTime.now().millisecondsSinceEpoch;

  final Map<String, _Pending> _pending = {};
  bool _armed = false;
  Timer? _timer;

  int get pending => _pending.length;
  int answered = 0, unanswered = 0, reaired = 0;

  /// Deliver [wire] when it is a `t:command` addressed to one station, and
  /// return true. False for anything else, which the caller airs as usual.
  bool send(String wire) {
    final p = XprsPacket.parse(wire);
    if (p == null || p.type != 'command') return false;
    final dest = (p['d'] ?? '').trim().toUpperCase();
    if (dest.isEmpty || !xprsAddressesStation(dest)) return false;
    final id = xprsIdentifier(p);
    final slot = 'command:$id';
    final known = _pending[id];
    if (known != null) {
      // The wapp said it again: the same bytes, so the same copy.
      air(known.wire, slot: slot, spread: true);
      return true;
    }
    final signed = air(wire, slot: slot, spread: false);
    if (_pending.length >= maxPending) {
      final oldest = _pending.keys.first;
      _pending.remove(oldest);
    }
    _pending[id] = _Pending(id, signed, dest, slot, nowMs());
    _arm();
    return true;
  }

  /// Every heard `t:result` (XprsIngest.onResult). A final code naming a
  /// command in flight ends it. A 202 does not: the station has taken the
  /// command and will say how it ended (11.10), and if that follow-up is
  /// lost, the next copy of the same command is what asks for it again,
  /// because a station answers a repeat of the last command it took with
  /// where it stands. The identifier ties answer to command, not the
  /// callsign: a station under a key it has just made answers from its new
  /// one.
  void onResult(XprsPacket p) {
    final r = p['r'];
    if (r == null || _pending.isEmpty) return;
    final e = _pending[r];
    if (e == null) return;
    if (p['code'] == '202') {
      e.taken = true;
      return;
    }
    _pending.remove(r);
    answered++;
    withdraw(e.slot);
    if (_pending.isEmpty) _disarm();
  }

  /// One pass over what is in flight. Cheap when nothing is due: a compare
  /// per pending command, of which there are at most [maxPending].
  @visibleForTesting
  void tick() {
    if (_pending.isEmpty) {
      _disarm();
      return;
    }
    final now = nowMs();
    for (final e in _pending.values.toList()) {
      final age = now - e.sentMs;
      if (age >= window.inMilliseconds) {
        _pending.remove(e.id);
        unanswered++;
        withdraw(e.slot);
        // Taken and never finished is a different thing to tell a person
        // than never heard at all.
        final state = e.taken ? 'unfinished' : 'unanswered';
        report(e.id, e.dest, state);
        LogService.instance.add(
            'XPRS: command ${e.id} to ${e.dest} $state after '
            '${e.tries + 1} airing(s)');
        continue;
      }
      if (e.tries < schedule.length &&
          age >= schedule[e.tries].inMilliseconds) {
        e.tries++;
        reaired++;
        air(e.wire, slot: e.slot, spread: true);
      }
    }
    if (_pending.isEmpty) _disarm();
  }

  int _lastTickMs = 0;

  void _onNativeTick() {
    // The heartbeat is 2 s; the schedule is in tens of seconds.
    final now = nowMs();
    if (now - _lastTickMs < 5000) return;
    _lastTickMs = now;
    tick();
  }

  void _arm() {
    if (_armed) return;
    _armed = true;
    if (platform.isAndroid) {
      AndroidForegroundService.instance.addTickListener(_onNativeTick);
    } else {
      _chain();
    }
  }

  // Off Android nothing throttles a Dart timer, and one short one-shot timer
  // exists only while a command is in flight.
  void _chain() {
    _timer = Timer(const Duration(seconds: 5), () {
      if (!_armed) return;
      tick();
      if (_armed) _chain();
    });
  }

  void _disarm() {
    if (!_armed) return;
    _armed = false;
    _timer?.cancel();
    _timer = null;
    if (platform.isAndroid) {
      AndroidForegroundService.instance.removeTickListener(_onNativeTick);
    }
  }

  @visibleForTesting
  void reset() {
    _disarm();
    _pending.clear();
    answered = unanswered = reaired = 0;
  }
}

class _Pending {
  _Pending(this.id, this.wire, this.dest, this.slot, this.sentMs);
  final String id;
  final String wire;
  final String dest;
  final String slot;
  final int sentMs;
  int tries = 0;
  bool taken = false;
}
