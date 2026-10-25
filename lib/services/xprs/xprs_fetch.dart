/*
 * xprs_fetch — a station's archived messages, fetched without knowing where
 * they are (XPRS.md 12.6, 12.9, 12.12.2).
 *
 * The other half of the APRS-IS-like loop. Somebody opens a conversation
 * with X1BOA3, or looks at that callsign, and the words X1BOA3 said while
 * this station was away are somewhere in the archivers. Which one is not
 * the asker's business, and it is not the wapp's either (docs/architecture.md
 * 1: a wapp hands the core a question and reads what the store holds). So
 * the core asks, in 12.6's words -- `cmd:history only:X1BOA3 kind:message`
 * -- and follows the answers:
 *
 *   1. the archiver that answered for this callsign last time, then the
 *      archivers this station chose (12.3);
 *   2. a `code:404 m:try A,B` names stations that know more (12.6, 12.9):
 *      followed ONE hop, never a hop from a hop;
 *   3. a `code:206` is continued (11.2.1), a few pages at most: this is a
 *      catch-up on one conversation, not a replay of a year.
 *
 * What comes back enters through the one receive door like any replay. The
 * admission rule would drop a stranger's public words on a pocket phone
 * (12: silence is not consent), so this file answers one more question for
 * the funnel: [askedFor] -- "is this a row this station ASKED for" -- and
 * such a row goes on the followed shelf. What you asked for, you keep;
 * bounded by what a fetch can bring (a few pages, ten minutes apart, only
 * for stations somebody looked at).
 *
 * One ask in flight per callsign, never two to one archiver (a second ask
 * from the same requester supersedes the replay running for the first,
 * XprsHistoryServer), never to an archiver the poller is talking to, and
 * never for a station in earshot -- the air already carries it, and 12.5
 * says ask the author then.
 *
 * Every send and clock is injected, so the whole dance runs in a unit test
 * and on the three-station bench (test/support/mail_relay_sim.dart).
 */
library;

import 'dart:async';

import '../log_service.dart';
import '../preferences_service.dart';
import 'xprs_archive.dart';
import 'xprs_catchup.dart';
import 'xprs_id.dart';
import 'xprs_monitor.dart';
import 'xprs_packet.dart';
import 'xprs_publisher.dart';
import 'xprs_vocab.dart';

class XprsFetch {
  XprsFetch._();
  static final XprsFetch instance = XprsFetch._();

  /// One fetch per station per this long: a conversation reopened every
  /// minute is not a new question.
  static const Duration everyPerStation = Duration(minutes: 10);

  /// A station never fetched before is asked for this far back; after that,
  /// `since:` is the newest message held from it.
  static const Duration firstWindow = Duration(days: 30);

  /// How long an unanswered ask holds the fetch before the next candidate
  /// is tried. XprsCatchup's figure, for the same reason.
  static const Duration askGrace = Duration(seconds: 40);

  /// Pages followed on `code:206`, and archivers tried, per fetch.
  static const int maxPages = 3;
  static const int maxTries = 4;

  // ── injected by the core (mesh_service); the defaults are the device ──────

  Future<void> Function(String wire)? send;
  List<String> Function()? archivers;
  String Function()? selfCallsign;
  bool Function(String call)? inEarshot;
  int? Function(String call)? newestHeldMs;
  bool Function(String archiver)? archiverBusy;
  int Function() nowMs = () => DateTime.now().millisecondsSinceEpoch;

  /// Off in tests, which drive [tick] themselves.
  bool autoTick = true;
  Timer? _wakeTimer;

  /// How long to wait before retrying an archiver the poller is talking to.
  static const Duration deferFor = Duration(seconds: 15);

  final Map<String, _Fetch> _open = {};
  final Map<String, _Fetch> _pending = {}; // ask id -> fetch
  final Map<String, int> _lastMs = {};
  final Map<String, String> _lastGood = {};
  static const int _rememberMax = 256;

  int requested = 0, skipped = 0, asks = 0, rows = 0;
  int redirects = 0, refused = 0, found = 0, empty = 0;

  /// Somebody wants [call]'s recent messages. Returns true when a fetch was
  /// opened; false when one is open already, one ran recently, the station
  /// is in earshot, or there is nobody to ask.
  bool requestStation(String call, {String reason = ''}) {
    final c = _base(call);
    final self = _base(selfCallsign?.call() ?? XprsArchive.instance.selfCallsign);
    if (c.isEmpty || self.isEmpty || c == self || !xprsAddressesStation(c)) {
      return false;
    }
    requested++;
    final now = nowMs();
    if (_open.containsKey(c) ||
        now - (_lastMs[c] ?? 0) < everyPerStation.inMilliseconds ||
        (inEarshot?.call(c) ?? XprsMonitor.instance.heardDirectly(c))) {
      skipped++;
      return false;
    }
    final candidates = <String>[];
    void add(String a) {
      final b = _base(a);
      if (b.isEmpty || b == self || b == c || candidates.contains(b)) return;
      candidates.add(b);
    }

    final good = _lastGood[c];
    if (good != null) add(good);
    for (final a in archivers?.call() ??
        PreferencesService.instanceSync?.xprsArchivers ??
        const <String>[]) {
      add(a);
    }
    if (candidates.isEmpty) {
      skipped++;
      return false;
    }
    _lastMs[c] = now;
    if (_lastMs.length > _rememberMax) _lastMs.remove(_lastMs.keys.first);
    _open[c] = _Fetch(c, candidates, self);
    LogService.instance.add('XPRS fetch: $c asked for'
        '${reason.isEmpty ? "" : " ($reason)"}, ${candidates.length} '
        'archiver(s) to try (12.6)');
    unawaited(tick());
    return true;
  }

  /// One wake, not a poll: a fetch is a person's question with an answer
  /// due within a grace, so the next look is scheduled ONCE per ask (its
  /// grace) or once per deferral, and nothing runs while no fetch is open
  /// (docs/performance.md 6.5). Results move the fetch along on arrival.
  void _wake(Duration after) {
    if (!autoTick || _open.isEmpty) return;
    _wakeTimer?.cancel();
    _wakeTimer = Timer(after, () {
      _wakeTimer = null;
      if (_open.isNotEmpty) unawaited(tick());
    });
  }

  /// Move every open fetch along: ask the next archiver when nothing is out
  /// (or the last ask outlived its grace), close what has nobody left.
  Future<void> tick() async {
    final now = nowMs();
    for (final f in List.of(_open.values)) {
      if (f.askId != null && now - f.askedAtMs < askGrace.inMilliseconds) {
        continue; // waiting on an answer
      }
      if (f.askId != null) _pending.remove(f.askId); // outlived its grace
      f.askId = null;
      await _askNext(f, now);
    }
  }

  Future<void> _askNext(_Fetch f, int now, {String? continueAt}) async {
    String? archiver;
    int? untilMs;
    if (continueAt != null) {
      archiver = continueAt;
      untilMs = f.untilMs;
    } else {
      while (f.tried < f.candidates.length && f.tried < maxTries) {
        final a = f.candidates[f.tried];
        if (archiverBusy?.call(a) ??
            XprsCatchup.instance.busyWith(a, nowMs: now)) {
          _wake(deferFor);
          return; // the poller is talking to it; look again shortly
        }
        f.tried++;
        archiver = a;
        break;
      }
      if (archiver == null) {
        _close(f, 'nobody left to ask');
        return;
      }
      f.pages = 0;
      f.untilMs = null;
      f.oldestMs = null;
    }
    final since = f.sinceMs ??= () {
      final held = newestHeldMs?.call(f.call) ??
          XprsArchive.instance.newestPts(f.call, types: const ['message']);
      return held ?? now - firstWindow.inMilliseconds;
    }();
    final wire = StringBuffer('t:command f:${f.self} d:$archiver '
        'ts:${xprsNowTs(now)} cmd:history kind:message only:${f.call} '
        'since:${xprsNowTs(since)}');
    if (untilMs != null) wire.write(' until:${xprsNowTs(untilMs)}');
    final p = XprsPacket.parse(wire.toString());
    if (p == null || !p.fits) {
      _close(f, 'ask does not fit');
      return;
    }
    final id = xprsIdentifier(p);
    f
      ..archiver = archiver
      ..askId = id
      ..askedAtMs = now
      ..rowsThisAsk = 0;
    _pending[id] = f;
    asks++;
    _wake(askGrace + const Duration(seconds: 1)); // give up on it, if unanswered
    final out = send ?? ((w) => XprsPublisher.instance.publishWire(w));
    await out(wire.toString());
  }

  /// A `t:result` arrived; ours if `r:` names an ask of ours.
  void onResult(XprsPacket p) {
    final r = p['r'] ?? '';
    final f = _pending[r];
    if (f == null) return;
    final code = int.tryParse(p['code'] ?? '') ?? 0;
    final from = f.archiver ?? '';
    switch (code) {
      case 202:
        return; // the page follows
      case 429:
        refused++;
        _pending.remove(r);
        f.askId = null;
        unawaited(_askNext(f, nowMs()));
        return;
      case 404:
        _pending.remove(r);
        f.askId = null;
        // A miss is not a dead end (12.6): follow who it names, one hop.
        final tries = _tries(p['m']);
        if (tries.isNotEmpty && !f.viaRedirect.contains(from)) {
          for (final t in tries) {
            final b = _base(t);
            if (b.isEmpty || b == f.self || b == f.call) continue;
            if (f.candidates.contains(b)) continue;
            f.candidates.add(b);
            f.viaRedirect.add(b);
            redirects++;
          }
        }
        unawaited(_askNext(f, nowMs()));
        return;
      case 206:
      case 200:
        _pending.remove(r);
        f.askId = null;
        if (f.rowsThisAsk > 0) {
          _lastGood[f.call] = from;
          if (_lastGood.length > _rememberMax) {
            _lastGood.remove(_lastGood.keys.first);
          }
        }
        if (code == 206 && f.rowsThisAsk > 0 && f.pages + 1 < maxPages) {
          // More held than served: continue before the oldest row this page
          // brought (11.2.1), and only if that is progress.
          final oldest = f.oldestMs;
          final next = oldest == null ? null : (oldest ~/ 1000) * 1000 + 1000;
          final prev = f.untilMs;
          if (next != null && (prev == null || next < prev)) {
            f.pages++;
            f.untilMs = next;
            unawaited(_askNext(f, nowMs(), continueAt: from));
            return;
          }
        }
        if (f.rowsThisAsk > 0 || f.pagesTotal > 0) {
          found++;
          _close(f, 'done, ${f.rowsTotal} row(s) from $from');
        } else {
          empty++;
          unawaited(_askNext(f, nowMs())); // it had nothing; somebody else may
        }
        return;
      default:
        return;
    }
  }

  static List<String> _tries(String? m) {
    final t = (m ?? '').trim();
    if (!t.startsWith('try ')) return const [];
    return t
        .substring(4)
        .split(RegExp(r'[, ]+'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty && s != 'or')
        .toList();
  }

  /// Every packet off every lane, before the echo check: count the rows a
  /// fetch's page brought, and move its cursor.
  void noteHeard(XprsPacket p) {
    if (_open.isEmpty) return;
    final f = _owner(p);
    if (f == null) return;
    f.rowsThisAsk++;
    f.rowsTotal++;
    rows++;
    final ts = xprsParseTs(p['ts']);
    if (ts != null && (f.oldestMs == null || ts < f.oldestMs!)) {
      f.oldestMs = ts;
    }
  }

  /// Is an ask of ours out right now (inside its grace)? XprsCatchup's
  /// gate reads it, so the poller does not send to an archiver mid-page.
  bool get askOut {
    final now = nowMs();
    return _open.values.any(
        (f) => f.askId != null && now - f.askedAtMs < askGrace.inMilliseconds);
  }

  /// Is [p] a row this station asked for? The funnel's admission consults
  /// it: such a row is kept on the followed shelf whatever the policy says
  /// about strangers.
  bool askedFor(XprsPacket p) => _open.isNotEmpty && _owner(p) != null;

  _Fetch? _owner(XprsPacket p) {
    if (!XprsArchive.kXprsTalk.contains(p.type)) return null;
    final now = nowMs();
    final from = _base(p['f'] ?? '');
    final to = _base(p['d'] ?? '');
    for (final f in _open.values) {
      if (f.askId == null || now - f.askedAtMs > askGrace.inMilliseconds) {
        continue;
      }
      if (from == f.call || to == f.call) return f;
    }
    return null;
  }

  void _close(_Fetch f, String why) {
    _open.remove(f.call);
    if (f.askId != null) _pending.remove(f.askId);
    LogService.instance.add('XPRS fetch: ${f.call} — $why');
  }

  Map<String, dynamic> get json => {
        'open': _open.keys.toList(),
        'requested': requested,
        'skipped': skipped,
        'asks': asks,
        'rows': rows,
        'redirects': redirects,
        'refused': refused,
        'found': found,
        'empty': empty,
      };

  static String _base(String c) => c.trim().toUpperCase().split('-').first;

  /// Tests: forget everything, seams included.
  void debugReset() {
    _wakeTimer?.cancel();
    _wakeTimer = null;
    _open.clear();
    _pending.clear();
    _lastMs.clear();
    _lastGood.clear();
    requested = skipped = asks = rows = 0;
    redirects = refused = found = empty = 0;
    send = null;
    archivers = null;
    selfCallsign = null;
    inEarshot = null;
    newestHeldMs = null;
    archiverBusy = null;
    nowMs = () => DateTime.now().millisecondsSinceEpoch;
    autoTick = true;
  }
}

class _Fetch {
  _Fetch(this.call, this.candidates, this.self);
  final String call;
  final String self;
  final List<String> candidates;
  final Set<String> viaRedirect = {};
  int tried = 0;
  String? archiver;
  String? askId;
  int askedAtMs = 0;
  int? sinceMs;
  int? untilMs;
  int? oldestMs;
  int pages = 0;
  int rowsThisAsk = 0;
  int rowsTotal = 0;
  int get pagesTotal => pages;
}
