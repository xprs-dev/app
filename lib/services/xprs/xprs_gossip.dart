/*
 * xprs_gossip — who was heard where (docs/XPRS.md section 36.9.4).
 *
 * The layered callsign→whereabouts table every archiver keeps. Three layers,
 * consulted in this order and stored with different lifetimes, because
 * durability is what keeps the table small and the routing honest:
 *
 *   L1  declared     the callsign's own `t:mailbox hold:` -- lives in
 *                    XprsArchive.mailbox_decl (13.12); this file only READS
 *                    it, through the reverse query the archive now has.
 *   L2  visits       last K distinct archivers that heard the callsign
 *                    DIRECTLY on a short-range bearer. Never expires; the
 *                    ring evicts the oldest distinct archiver. Radio truth
 *                    only -- an internet-borne claim cannot write it.
 *   L3  sightings    freshest (gateway, bearer, ts) claims, at most G per
 *                    callsign, TTL'd. Freshest wins.
 *
 * Validity (36.9.4): every entry is credited to the SIGNER of the packet it
 * came from. Unsigned observations feed nothing here; a per-signer interval
 * meters ingestion; the whole table lives under a byte budget.
 *
 * Performance (docs/performance.md 4.2): the feeds run on the receive path
 * for every packet, so the cheap checks come first and everything here is
 * an indexed upsert on an already-parsed packet. No timers -- the TTL sweep
 * piggybacks on inserts, at most once a minute.
 */
import 'dart:async';

import 'package:sqlite3/sqlite3.dart';

import '../log_service.dart';

/// One place a callsign was seen, for routing.
class GossipSighting {
  final String callsign;
  final String gateway;
  final String bearer;
  final int tsMs;
  const GossipSighting(this.callsign, this.gateway, this.bearer, this.tsMs);
}

class XprsGossip {
  XprsGossip._();
  static final XprsGossip instance = XprsGossip._();

  /// Reference constants of 36.9.4. K and G are per-callsign caps; the TTL
  /// bounds L3; the byte budget bounds the whole table (super mode raises it).
  static const int visitRingK = 100;
  static const int liveCapG = 8;
  static const Duration liveTtl = Duration(hours: 24);
  static const int defaultMaxBytes = 5 * 1024 * 1024;

  /// Bearers that count as radio truth for L2 (36.9.4: short-range only —
  /// `rns`/internet never writes the durable layer).
  static const Set<String> kShortRange = {
    'ble', 'lan', 'espnow', 'lora', 'wifi', 'vhf', 'uhf', 'hf',
  };

  Database? _db;
  int maxBytes = defaultMaxBytes;
  int accepted = 0, refusedUnsigned = 0, refusedQuota = 0;

  /// Per-signer ingestion meter (36.9.4: one observer's gossip at the rate
  /// its own adverts arrive). 30 s matches the fastest beacon cadence.
  final Map<String, int> _signerLastMs = {};
  static const int _signerIntervalMs = 30000;
  int _lastSweepMs = 0;

  bool get ready => _db != null;

  void init(String path) {
    try {
      final db = sqlite3.open(path);
      db.execute('PRAGMA journal_mode=WAL');
      db.execute('CREATE TABLE IF NOT EXISTS gossip_visits('
          'callsign TEXT NOT NULL, gateway TEXT NOT NULL,'
          'bearer TEXT NOT NULL, first_ts INTEGER NOT NULL,'
          'last_ts INTEGER NOT NULL,'
          'PRIMARY KEY(callsign, gateway))');
      db.execute('CREATE INDEX IF NOT EXISTS idx_gv_call_last '
          'ON gossip_visits(callsign, last_ts)');
      db.execute('CREATE TABLE IF NOT EXISTS gossip_live('
          'callsign TEXT NOT NULL, gateway TEXT NOT NULL,'
          'bearer TEXT NOT NULL, ts INTEGER NOT NULL, signer TEXT NOT NULL,'
          'PRIMARY KEY(callsign, gateway))');
      db.execute('CREATE INDEX IF NOT EXISTS idx_gl_call_ts '
          'ON gossip_live(callsign, ts)');
      _db = db;
    } catch (e) {
      LogService.instance.add('Gossip: store failed to open: $e');
    }
  }

  void close() {
    _db?.dispose();
    _db = null;
  }

  /// This station heard [callsign] itself, with no `via:`. The one feed that
  /// needs no signature — our own radio is its own witness.
  void noteDirect(String callsign, String selfCallsign,
      {required String bearer, int? nowMs}) {
    final db = _db;
    if (db == null || callsign.isEmpty || selfCallsign.isEmpty) return;
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    _noteLive(db, callsign, selfCallsign, bearer, now, selfCallsign);
    if (kShortRange.contains(bearer)) {
      _noteVisit(db, callsign, selfCallsign, bearer, now);
    }
    accepted++;
    _maybeSweep(db, now);
  }

  /// A verified observation from [observer] whose `hears:` lists callsigns it
  /// hears directly on [link]. [verified] is the packet's signature verdict —
  /// an unsigned or unverifiable claim feeds nothing (36.9.4).
  void noteHears(String observer, List<String> hears,
      {required String link, required bool verified, int? nowMs}) {
    final db = _db;
    if (db == null || observer.isEmpty || hears.isEmpty) return;
    if (!verified) {
      refusedUnsigned++;
      return;
    }
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final last = _signerLastMs[observer] ?? 0;
    if (now - last < _signerIntervalMs) {
      refusedQuota++;
      return;
    }
    _signerLastMs[observer] = now;
    if (_signerLastMs.length > 512) _signerLastMs.remove(_signerLastMs.keys.first);
    final radio = kShortRange.contains(link);
    for (final c in hears) {
      final call = c.trim().toUpperCase();
      if (call.isEmpty || call == observer) continue;
      _noteLive(db, call, observer, link, now, observer);
      if (radio) _noteVisit(db, call, observer, link, now);
    }
    accepted++;
    _maybeSweep(db, now);
  }

  void _noteLive(
      Database db, String call, String gw, String bearer, int now, String by) {
    db.execute(
        'INSERT INTO gossip_live(callsign,gateway,bearer,ts,signer) '
        'VALUES(?,?,?,?,?) ON CONFLICT(callsign,gateway) DO UPDATE SET '
        'bearer=excluded.bearer, ts=MAX(ts, excluded.ts), signer=excluded.signer',
        [call, gw, bearer, now, by]);
    // The per-callsign G cap: stalest beyond G go.
    db.execute(
        'DELETE FROM gossip_live WHERE callsign=? AND gateway NOT IN '
        '(SELECT gateway FROM gossip_live WHERE callsign=? '
        'ORDER BY ts DESC LIMIT ?)',
        [call, call, liveCapG]);
  }

  void _noteVisit(
      Database db, String call, String gw, String bearer, int now) {
    db.execute(
        'INSERT INTO gossip_visits(callsign,gateway,bearer,first_ts,last_ts) '
        'VALUES(?,?,?,?,?) ON CONFLICT(callsign,gateway) DO UPDATE SET '
        'bearer=excluded.bearer, last_ts=MAX(last_ts, excluded.last_ts)',
        [call, gw, bearer, now, now]);
    // The K ring: oldest DISTINCT archiver leaves when a new one arrives.
    db.execute(
        'DELETE FROM gossip_visits WHERE callsign=? AND gateway NOT IN '
        '(SELECT gateway FROM gossip_visits WHERE callsign=? '
        'ORDER BY last_ts DESC LIMIT ?)',
        [call, call, visitRingK]);
  }

  /// TTL for L3 and the byte budget, at most once a minute, on the insert
  /// path (no timers — performance.md 8.2).
  void _maybeSweep(Database db, int now) {
    if (now - _lastSweepMs < 60000) return;
    _lastSweepMs = now;
    db.execute('DELETE FROM gossip_live WHERE ts < ?',
        [now - liveTtl.inMilliseconds]);
    try {
      final pages =
          (db.select('PRAGMA page_count').first.values.first as num).toInt();
      final pageSize =
          (db.select('PRAGMA page_size').first.values.first as num).toInt();
      if (pages * pageSize > maxBytes) {
        // Over budget: L3 stalest-first goes before L2 loses anything
        // (36.9.4 — the visit history is the layer allowed to live forever).
        db.execute('DELETE FROM gossip_live WHERE rowid IN '
            '(SELECT rowid FROM gossip_live ORDER BY ts ASC LIMIT 512)');
      }
    } catch (_) {}
  }

  /// The routing answer, freshest first: L3 sightings, then L2 visits.
  /// (L1 — the recipient's own declaration — outranks both and is read from
  /// XprsArchive.holdersFor, by the callers that route.)
  List<GossipSighting> whereIs(String callsign, {int max = 8}) {
    final db = _db;
    if (db == null) return const [];
    final call = callsign.trim().toUpperCase();
    final out = <GossipSighting>[];
    final seen = <String>{};
    for (final r in db.select(
        'SELECT gateway,bearer,ts FROM gossip_live WHERE callsign=? '
        'ORDER BY ts DESC LIMIT ?',
        [call, max])) {
      out.add(GossipSighting(
          call, r['gateway'], r['bearer'], (r['ts'] as num).toInt()));
      seen.add(r['gateway'] as String);
    }
    for (final r in db.select(
        'SELECT gateway,bearer,last_ts FROM gossip_visits WHERE callsign=? '
        'ORDER BY last_ts DESC LIMIT ?',
        [call, max])) {
      if (out.length >= max) break;
      if (seen.contains(r['gateway'] as String)) continue;
      out.add(GossipSighting(
          call, r['gateway'], r['bearer'], (r['last_ts'] as num).toInt()));
    }
    return out;
  }

  /// Gateways worth naming in a 404's `m:try` (36.9): freshest few, never us.
  List<String> tryCandidates(String callsign,
      {required String selfBase, int max = 3}) {
    return [
      for (final s in whereIs(callsign, max: max + 1))
        if (s.gateway != selfBase) s.gateway
    ].take(max).toList();
  }

  /// The miss path of 36.9.4: gossip knows nothing of [call], so ask a
  /// configured super-archiver -- over the directed lane, because the
  /// public hubs throttle everything else. Throttled per callsign; the
  /// answer flows back through the ordinary funnel and lands here.
  final Map<String, int> _askedSuperMs = {};
  int superAsks = 0;

  void askSuper(String call,
      {required Future<void> Function(String wire) publish,
      required List<String> superArchivers,
      required String selfBase,
      int? nowMs}) {
    if (superArchivers.isEmpty) return;
    final c = call.trim().toUpperCase();
    if (c.isEmpty || c == selfBase) return;
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    if (now - (_askedSuperMs[c] ?? 0) < 600000) return; // 36.10.1 cadence
    _askedSuperMs[c] = now;
    if (_askedSuperMs.length > 128) _askedSuperMs.remove(_askedSuperMs.keys.first);
    final t = DateTime.now().toUtc();
    String two(int n) => n.toString().padLeft(2, '0');
    final ts = '${t.year}-${two(t.month)}-${two(t.day)}_'
        '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
    final since = t.subtract(const Duration(days: 7));
    final sinceS = '${since.year}-${two(since.month)}-${two(since.day)}_'
        '${two(since.hour)}:${two(since.minute)}:${two(since.second)}';
    for (final sa in superArchivers) {
      final g = sa.trim().toUpperCase();
      if (g.isEmpty || g == selfBase) continue;
      // identity first in the kind list: the observation that answers the
      // question verifies against a key that may ride the same page.
      final wire = 't:command f:$selfBase d:$g ts:$ts cmd:history '
          'kind:identity,observation only:$c since:$sinceS';
      superAsks++;
      unawaited(publish(wire));
      break; // one super per miss per period
    }
  }

  Map<String, dynamic> statusJson() {
    final db = _db;
    return {
      'ready': ready,
      'visits': db == null
          ? 0
          : db.select('SELECT COUNT(*) c FROM gossip_visits').first['c'],
      'live': db == null
          ? 0
          : db.select('SELECT COUNT(*) c FROM gossip_live').first['c'],
      'accepted': accepted,
      'refusedUnsigned': refusedUnsigned,
      'refusedQuota': refusedQuota,
      'superAsks': superAsks,
    };
  }

  /// Tests: a clean slate.
  void debugReset() {
    _db?.execute('DELETE FROM gossip_visits');
    _db?.execute('DELETE FROM gossip_live');
    _signerLastMs.clear();
    _lastSweepMs = 0;
    accepted = 0;
    refusedUnsigned = 0;
    refusedQuota = 0;
  }
}
