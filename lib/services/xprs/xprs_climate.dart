/*
 * xprs_climate — the temperature of the place this device is in, as the
 * stations around it report it.
 *
 * A weather station is a station that reports temperature (XPRS.md 15.3):
 * `temp:` is the air outdoors, `intemp:` the air indoors, and a sensor that does
 * not know where it sits sends `temp:`. This file turns the observations heard
 * nearby into at most one indoor and one outdoor reading, which the home screen
 * shows. The screen renders the answer and decides nothing (docs/architecture.md
 * §1: the core owns the verdict).
 *
 * ── Only what is in reach ────────────────────────────────────────────────
 * It is fed from [XprsIngest.heard], the door for the radio and the local links
 * (BLE, LAN, TCP, the courier), and never from the internet lane. A station on
 * a hub in another city reports the air somebody else is standing in.
 *
 * ── One source per kind, and it does not flap ────────────────────────────
 * Two sensors in reach would otherwise take turns on the screen once a minute.
 * The station already shown keeps its place while its reading is fresh; another
 * one takes over only when it goes quiet.
 *
 * ── Cost ─────────────────────────────────────────────────────────────────
 * A packet with neither key costs two map lookups. Nothing here reads a
 * preference, verifies a signature or logs per packet (performance.md 4.2 and
 * 8.10): a temperature is a cosmetic value, and a spoofed one misleads nobody
 * about anything that matters. Expiry is one one-shot timer, re-armed for the
 * next reading to go stale, never a poll.
 */
import 'dart:async';

import 'package:flutter/foundation.dart';

import 'xprs_packet.dart';

/// One temperature, as a station measured it.
@immutable
class ClimateReading {
  /// Degrees Celsius, the canonical unit (XPRS.md 15.9). A reading sent in
  /// Fahrenheit is converted here, once.
  final double celsius;

  /// Decimal places the sender used. `temp:14` was not measured to a tenth
  /// and must not be shown as `14.0` (XPRS.md 4.4).
  final int decimals;

  /// The station that measured it.
  final String station;

  /// When it was measured, not when it was heard.
  final DateTime at;

  const ClimateReading({
    required this.celsius,
    required this.decimals,
    required this.station,
    required this.at,
  });

  /// `23°C`, `14.2°C`, `-3.5°C`. Converted readings keep the sender's
  /// precision.
  String get label {
    final v = double.parse(celsius.toStringAsFixed(decimals));
    // -0.0 reads as a typo on a thermometer.
    return '${(v == 0 ? 0.0 : v).toStringAsFixed(decimals)}°C';
  }

  @override
  bool operator ==(Object other) =>
      other is ClimateReading &&
      other.celsius == celsius &&
      other.decimals == decimals &&
      other.station == station &&
      other.at == at;

  @override
  int get hashCode => Object.hash(celsius, decimals, station, at);
}

/// What the home screen shows. Either side may be absent; both absent means
/// there is nothing to show at all.
@immutable
class LocalClimate {
  final ClimateReading? inside;
  final ClimateReading? outside;

  const LocalClimate({this.inside, this.outside});

  bool get isEmpty => inside == null && outside == null;

  @override
  bool operator ==(Object other) =>
      other is LocalClimate && other.inside == inside && other.outside == outside;

  @override
  int get hashCode => Object.hash(inside, outside);
}

/// A `qty` temperature (`14.2C`, `-3.5C`, `57.6F`) in degrees Celsius and the
/// decimals it was written with, or null for anything else.
///
/// The unit is required and the set is closed (XPRS.md 15.8, 15.9): a bare
/// number or `48km/h` is a malformed value and is skipped, not guessed at. The
/// digits follow 4.4: a dot, at least one digit before it, a leading `-` only.
/// A value outside what air can be is a broken sensor, not weather.
(double, int)? xprsTemperatureC(String? v) {
  if (v == null) return null;
  final m = _qty.firstMatch(v.trim());
  if (m == null) return null;
  final n = double.tryParse(m.group(1)!);
  if (n == null) return null;
  final decimals = m.group(2)?.length ?? 0;
  final c = m.group(3) == 'F' ? (n - 32) * 5 / 9 : n;
  if (c < -100 || c > 70) return null;
  return (c, decimals);
}

final RegExp _qty = RegExp(r'^(-?\d+(?:\.(\d+))?)([CF])$');

/// When an observation was measured: `ts:` when it has one (UTC, 4.8), else
/// the moment it was heard less `age:` (15.7, a sensor with no clock), else the
/// moment it was heard. A time in the future is a clock that is ahead, and is
/// read as now.
DateTime xprsMeasuredAt(XprsPacket p, DateTime heardAt) {
  final ts = p['ts'];
  if (ts != null) {
    final m = _ts.firstMatch(ts.trim());
    if (m != null) {
      final at = DateTime.utc(
        int.parse(m.group(1)!),
        int.parse(m.group(2)!),
        int.parse(m.group(3)!),
        int.parse(m.group(4)!),
        int.parse(m.group(5)!),
        int.parse(m.group(6)!),
      );
      return at.isAfter(heardAt) ? heardAt : at;
    }
  }
  final age = int.tryParse((p['age'] ?? '').trim());
  if (age != null && age >= 0) return heardAt.subtract(Duration(seconds: age));
  return heardAt;
}

final RegExp _ts = RegExp(r'^(\d{4})-(\d\d)-(\d\d)_(\d\d):(\d\d):(\d\d)$');

class XprsClimate {
  XprsClimate({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;
  static final XprsClimate instance = XprsClimate();

  /// How long a reading stays on screen after it was measured. The ESP32
  /// reports every minute, and a phone on battery scans in LOW_POWER and
  /// misses some of them (performance.md 8.11), so this is several missed
  /// reports, and short enough that a station switched off, or left behind
  /// when the phone was carried out of reach, stops being shown as current.
  static const Duration fresh = Duration(minutes: 15);

  final DateTime Function() _clock;

  /// The readings to show. The widget listens to this and nothing else.
  final ValueNotifier<LocalClimate> current =
      ValueNotifier(const LocalClimate());

  /// Diagnostics for `/api/xprs/climate`: a new receive path is instrumented
  /// before it is trusted (performance.md 8.13).
  int accepted = 0;
  int malformed = 0;
  int stale = 0;

  Timer? _expiry;

  /// An observation heard on a local lane, from [from] (never ourselves: the
  /// funnel has already dropped our own echo).
  void heard(XprsPacket p, {required String from}) {
    final out = p['temp'];
    final ins = p['intemp'];
    if (out == null && ins == null) return;
    final now = _clock().toUtc();
    final at = xprsMeasuredAt(p, now);
    if (now.difference(at) > fresh) {
      stale++;
      return;
    }
    var inside = current.value.inside;
    var outside = current.value.outside;
    if (ins != null) inside = _take(inside, ins, from, at, now);
    if (out != null) outside = _take(outside, out, from, at, now);
    _publish(LocalClimate(inside: inside, outside: outside));
  }

  ClimateReading? _take(ClimateReading? shown, String raw, String from,
      DateTime at, DateTime now) {
    final t = xprsTemperatureC(raw);
    if (t == null) {
      malformed++;
      return shown;
    }
    final keep = shown != null &&
        now.difference(shown.at) <= fresh &&
        (shown.station != from || !at.isAfter(shown.at));
    if (keep) return shown;
    accepted++;
    return ClimateReading(
        celsius: t.$1, decimals: t.$2, station: from, at: at);
  }

  /// Drop what went stale. Called by the expiry timer; public for tests.
  void sweep() {
    final now = _clock().toUtc();
    bool live(ClimateReading? r) =>
        r != null && now.difference(r.at) <= fresh;
    final c = current.value;
    _publish(LocalClimate(
      inside: live(c.inside) ? c.inside : null,
      outside: live(c.outside) ? c.outside : null,
    ));
  }

  void _publish(LocalClimate next) {
    if (next != current.value) current.value = next;
    _armExpiry();
  }

  /// One timer, set for the moment the older reading turns stale.
  void _armExpiry() {
    _expiry?.cancel();
    _expiry = null;
    final c = current.value;
    final times = [c.inside?.at, c.outside?.at].whereType<DateTime>();
    if (times.isEmpty) return;
    final oldest = times.reduce((a, b) => a.isBefore(b) ? a : b);
    final wait = oldest.add(fresh).difference(_clock().toUtc());
    _expiry = Timer(
        wait.isNegative ? Duration.zero : wait + const Duration(seconds: 1),
        sweep);
  }

  /// Forget everything. Tests only.
  @visibleForTesting
  void reset() {
    _expiry?.cancel();
    _expiry = null;
    current.value = const LocalClimate();
    accepted = malformed = stale = 0;
  }
}
