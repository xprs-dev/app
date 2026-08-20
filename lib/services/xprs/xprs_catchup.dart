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
 * locally-reachable archiver by definition is. The watermark advances to the
 * ask's own ts: only when the archiver answers 200/206/404; a 429 or silence
 * leaves it, and the same window is asked for again next period. Ten minutes
 * is the default because section 31's reference serving budget answers a
 * known caller six times an hour — polling faster steals our own budget.
 */
import 'dart:async';

import '../log_service.dart';
import '../preferences_service.dart';
import 'xprs_id.dart';
import 'xprs_monitor.dart';
import 'xprs_packet.dart';
import 'xprs_publisher.dart';
import 'xprs_vocab.dart';

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

  /// Called by MeshService's 60 s sweep. Enforces its own period.
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

    // Archivers in DIRECT reach (no via:), fresh within the monitor's own
    // staleness window — a list is a claim about now.
    final selfBase = _base(selfCallsign);
    final fresh = XprsMonitor.instance
        .directlyHeard(nowMs: now)
        .map((c) => XprsMonitor.instance.stations[c])
        .whereType<XprsStation>()
        .where((s) =>
            s.services.contains('archive') && _base(s.callsign) != selfBase);

    for (final st in fresh) {
      final base = _base(st.callsign);
      final asked = _askedAtMs[base] ?? 0;
      if (now - asked < periodMs) continue;
      _askedAtMs[base] = now;
      await _ask(selfCallsign, base, now, prefs);
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
    final report = await send(wire);
    LogService.instance.add(
        'XPRS catch-up: asked $archiver since ${_ts(sinceSec * 1000)} — '
        '${report.entries.map((e) => '${e.key}:${e.value}').join(', ')}');
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
