/*
 * xprs_catchup — the pocket device polls its archivers (XPRS 36.10.1).
 *
 * A phone cannot tell an absence from an afternoon in a pocket, so it does
 * not try: it keeps one persisted WATERMARK — the end of the last window an
 * archiver answered for — and, on a slow cadence, asks every archiver in
 * direct reach for what came after it:
 *
 *   t:command f:<us> d:<archiver> ts:<now> scope:local cmd:history since:<watermark>
 *
 * scope:local pins the ask to the short-range bearers, which is where a
 * locally-reachable station by definition is. The watermark advances to the
 * ask's own ts: only when the station answers 200/206/404; a 429 or silence
 * leaves it, and the same window is asked for again next period.
 *
 * EVERY station in direct reach is asked, on whatever bearer heard it — not
 * only the ones advertising serve:archive. A station that holds a message for
 * us is worth asking whether or not it calls itself an archive, and a phone
 * that waits to be told there is mail never finds out when the beacon carrying
 * that news is the one advert it missed.
 *
 * The period is one minute. That is a battery setting, not a freshness setting
 * (docs/performance.md section 6.5): it costs one small frame per station per
 * minute inside an advertising window that already opens, no GATT link, no
 * crypto, no sqlite. The expensive half — dialling a station to pull what it
 * holds — stays gated on a station actually saying it holds something.
 */
import 'dart:async';
import 'dart:io' show Platform;

import '../../wapp/android_foreground_service.dart';
import '../log_service.dart';
import '../preferences_service.dart';
import 'xprs_id.dart';
import 'xprs_monitor.dart';
import 'xprs_packet.dart';
import 'xprs_publisher.dart';

class XprsCatchup {
  XprsCatchup._();
  static final XprsCatchup instance = XprsCatchup._();

  /// Test seams: fake clock and a captured send.
  int Function() nowMs = () => DateTime.now().millisecondsSinceEpoch;
  Future<Map<String, String>> Function(String wire)? sendOverride;

  /// The ask window never reaches further back than this (36.10.1 rule 4).
  static const Duration maxWindow = Duration(days: 7);

  /// One ask per archiver per period.
  final Map<String, int> _askedAtMs = {};

  /// Pending asks: section-5 id of the ask -> the ask's own ts (epoch ms).
  /// When a t:result names one of these with 200/206/404, the watermark
  /// advances to that ts.
  final Map<String, int> _pending = {};
  static const int _pendingMax = 8;

  int get watermarkSec =>
      PreferencesService.instanceSync?.xprsCatchupWatermark ?? 0;

  // ── Cadence ───────────────────────────────────────────────────────────────
  //
  // Driven from BgService's 2 s native heartbeat, NOT a Dart Timer.periodic: a
  // Dart timer is throttled to near-nothing once Android backgrounds the app
  // (docs/performance.md section 8.2), which is precisely the pocket this poll
  // exists for. MeshService's own 60 s sweep is a bare Timer and used to be
  // what called us, so the poll it drove stopped the moment the screen did.
  String _selfCallsign = '';
  int _lastTickMs = 0;
  bool _ticking = false;
  bool _armed = false;

  /// Begin polling for [selfCallsign]. Fires once immediately, then settles
  /// into the period — a timer-only poll means a silent first minute
  /// (docs/performance.md section 6.5).
  void start(String selfCallsign) {
    _selfCallsign = selfCallsign;
    if (selfCallsign.isEmpty) return;
    unawaited(tick(selfCallsign));
    if (_armed || !Platform.isAndroid) return;
    _armed = true;
    AndroidForegroundService.instance.addTickListener(_onNativeTick);
  }

  void stop() {
    if (!_armed) return;
    _armed = false;
    AndroidForegroundService.instance.removeTickListener(_onNativeTick);
  }

  void _onNativeTick() {
    final now = nowMs();
    // The 2 s heartbeat is shared; this poll only wants a minute of it. tick()
    // enforces the real per-station period on top.
    if (now - _lastTickMs < 30000) return;
    _lastTickMs = now;
    if (_ticking || _selfCallsign.isEmpty) return;
    _ticking = true;
    unawaited(tick(_selfCallsign).whenComplete(() => _ticking = false));
  }

  /// Driven from the native BgService heartbeat (see [start]) so it keeps
  /// polling with the screen off. Enforces its own period.
  Future<void> tick(String selfCallsign) async {
    final prefs = PreferencesService.instanceSync;
    if (prefs == null || !prefs.xprsCatchup) return;
    if (selfCallsign.isEmpty) return;

    final now = nowMs();
    final periodMs = prefs.xprsCatchupMinutes * 60000;

    // A fresh install has no hole: start keeping from now (36.10.1 rule 2).
    if (prefs.xprsCatchupWatermark == 0) {
      prefs.xprsCatchupWatermark = now ~/ 1000;
      return;
    }

    // Nothing to ask on when no short-range bearer is up.
    var anyLocal = false;
    for (final b in XprsPublisher.instance.bearers) {
      if (b.shortRange && await b.active) {
        anyLocal = true;
        break;
      }
    }
    if (!anyLocal) return;

    // Every station in DIRECT reach (no via:), fresh within the monitor's own
    // staleness window — a list is a claim about now. No serve:archive filter:
    // any station in earshot may be holding something for us.
    final selfBase = _base(selfCallsign);
    final fresh = XprsMonitor.instance
        .directlyHeard(nowMs: now)
        .map((c) => XprsMonitor.instance.stations[c])
        .whereType<XprsStation>()
        .where((s) => _base(s.callsign) != selfBase);

    final asked = <String>[];
    for (final st in fresh) {
      final base = _base(st.callsign);
      final last = _askedAtMs[base] ?? 0;
      if (now - last < periodMs) continue;
      _askedAtMs[base] = now;
      await _ask(selfCallsign, base, now, prefs);
      asked.add(base);
    }
    // One line per sweep, never one per station: this runs every minute for as
    // long as the app lives, into a 2000-line ring (docs/performance.md 3.3).
    if (asked.isNotEmpty) {
      LogService.instance.add('XPRS: polled ${asked.length} station(s) — '
          '${asked.join(", ")}');
    }
  }

  Future<void> _ask(String self, String archiver, int now,
      PreferencesService prefs) async {
    // since: = the watermark, floored at a week (36.10.1 rule 4).
    var sinceSec = prefs.xprsCatchupWatermark;
    final floorSec = (now - maxWindow.inMilliseconds) ~/ 1000;
    if (sinceSec < floorSec) sinceSec = floorSec;

    final wire = 't:command f:$self d:$archiver ts:${_ts(now)} scope:local '
        'cmd:history since:${_ts(sinceSec * 1000)}';
    final p = XprsPacket.parse(wire);
    if (p == null || !p.fits) return;

    // Remember the ask so its result can advance the watermark. The id is
    // computed BEFORE signing (section 5 removes sig: anyway, so it is the
    // same id the archiver derives from the signed wire).
    final id = xprsIdentifier(p);
    if (_pending.length >= _pendingMax) _pending.remove(_pending.keys.first);
    _pending[id] = now;

    final send = sendOverride ?? XprsPublisher.instance.publishWire;
    await send(wire);
  }

  /// Fed every heard t:result (XprsIngest.onResult). Advances the watermark
  /// when the result answers one of our pending asks.
  void onResult(XprsPacket p) {
    final r = p['r'] ?? '';
    final askTs = _pending[r];
    if (askTs == null) return;
    final code = int.tryParse(p['code'] ?? '') ?? 0;
    // 200 done, 206 partial (the window up to here was served), 404 the
    // archiver holds nothing — all three answer the window. 429 does not.
    if (code != 200 && code != 206 && code != 404) return;
    _pending.remove(r);
    final prefs = PreferencesService.instanceSync;
    if (prefs == null) return;
    final sec = askTs ~/ 1000;
    if (sec > prefs.xprsCatchupWatermark) {
      prefs.xprsCatchupWatermark = sec;
      LogService.instance
          .add('XPRS catch-up: watermark -> ${_ts(askTs)} (code:$code)');
    }
  }

  static String _base(String c) {
    final i = c.indexOf('-');
    return (i < 0 ? c : c.substring(0, i)).toUpperCase();
  }

  static String _ts(int epochMs) {
    final d = DateTime.fromMillisecondsSinceEpoch(epochMs, isUtc: true);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}_'
        '${two(d.hour)}:${two(d.minute)}:${two(d.second)}';
  }
}
