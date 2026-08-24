/*
 * xprs_history_server — answering `cmd:history` from the spool.
 *
 * docs/XPRS.md section 25.2: the station replies `code:202`, re-airs the
 * ORIGINAL packets unchanged, newest first, then `code:200` — or `code:206`
 * when that was one page and more exists, and the requester continues by
 * moving `until:` to the oldest `ts:` it received. `code:404` for a window
 * not held, without apology (31.3). `code:429` over budget, out loud (31.2).
 *
 * Airtime is the scarce thing (31.4): one replay in flight ever, one packet
 * every 1.5 s on a short-TTL advert slot so the replay never camps on the
 * presence beacons, and token buckets per requester (a station that declared
 * us, or whose key we hold, gets more than a stranger; another device of OURS
 * is unmetered — section 3.1). The replay bytes are byte-identical to what
 * was stored: no via:, no re-sign — an indexer passes on the author's packet,
 * and the signature that travels with it is the author's (36.2).
 *
 * Commands arrive through XprsIngest ([install] hooks its onCommand). A
 * command off the Reticulum lane is logged and not answered in v1 — the
 * reply lane there would be wappSendTo, a slot deliberately left open.
 */
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../util/nostr_crypto.dart';
import '../log_service.dart';
import '../preferences_service.dart';
import 'xprs_archive.dart';
import 'xprs_gossip.dart';
import '../reticulum/rns_service.dart';
import 'xprs_id.dart';
import 'xprs_ingest.dart';
import 'xprs_packet.dart';
import 'xprs_publisher.dart';
import 'xprs_sig.dart';
import 'xprs_vocab.dart';

class XprsHistoryServer {
  XprsHistoryServer._();
  static final XprsHistoryServer instance = XprsHistoryServer._();

  /// Packets per page: 12 re-aired wires ≈ 18 s of paced airtime, plus the
  /// probe row that decides 206-versus-200.
  static const int pageSize = 12;
  static const Duration interPacket = Duration(milliseconds: 1500);
  static const Duration answeredWindow = Duration(minutes: 10);

  /// Budgets (section 31.2): replays per hour. "Known" = an author that
  /// declared us as mailbox, or whose key we hold.
  static const int knownPerHour = 6;
  static const int strangerPerHour = 2;
  static const int globalPerHour = 12;

  /// Test seams. [txOverride] captures airings without a radio; [signingKey]
  /// stands in for the profile scalar.
  Future<bool> Function(String key, Uint8List bytes, Duration ttl)? txOverride;
  BigInt? Function() signingKey = xprsProfileScalar;

  int answered = 0, refused429 = 0;

  final Map<String, int> _answeredIds = {};
  final Map<String, List<int>> _asksBy = {};
  final List<int> _asksGlobal = [];
  Timer? _chain;
  String? _chainFor;
  bool get replaying => _chain != null;

  /// Route heard commands here. Called once at mesh start.
  void install() {
    XprsIngest.onCommand = _onPacket;
  }

  /// Why a replay is NOT reordered by relevance.
  ///
  /// A page is continued by narrowing `until:` to the oldest packet received
  /// (25.2.1) -- there is no cursor. That only works while the page is
  /// chronological: reorder it and the client's next `until:` skips everything
  /// between the bands. So relevance is expressed by WHICH records are
  /// eligible, not by their order.
  ///
  /// With no `kind:`, a radio replay serves conversation and leaves presence
  /// and service chatter out. Measured on a bench station, the newest 200
  /// records were 120 `t:identity`, 69 `t:observation`, 11 `t:service` and no
  /// messages at all -- so an unfiltered page of twelve was twelve beacons,
  /// every time, and the talking was never reached. A caller that genuinely
  /// wants beacons asks for them by name with `kind:observation`.
  ///
  /// The packet types a `cmd:history` asked for, or null for every type.
  ///
  /// `kind:` names a type (section 25.2); `only:` names a CALLSIGN (36.6) and
  /// is passed through separately. They are different questions, and answering
  /// `only:` by matching a type name is what made `only:message` look like it
  /// worked while `only:X5A3F2` matched nothing.
  static List<String>? _kinds(XprsPacket p) {
    final k = (p['kind'] ?? '').trim();
    if (k.isEmpty) return null;
    final types = k
        .split(',')
        .map((e) => e.trim().toLowerCase())
        .where((e) => e.isNotEmpty)
        .toList();
    return types.isEmpty ? null : types;
  }

  void _onPacket(XprsPacket p,
      {required String selfBase, required String bearer}) {
    if (p.type != 'command') return;
    if (_base(p['d'] ?? '') != selfBase) return;
    // `q:identity` (section 18.1) asks for the key binding directly instead of
    // waiting up to thirty minutes for the next announcement. Answering costs
    // one advert and saves a peer half an hour of being unable to check a
    // single signature of ours.
    if ((p['q'] ?? '') == 'identity') {
      unawaited(XprsPublisher.instance.publishIdentity());
      return;
    }
    if ((p['cmd'] ?? '') != 'history') return;
    // The rns lane is served like every other (36.0). The refusal that used
    // to sit here guarded a reply lane that did not exist; _air now goes
    // through the publisher, whose reticulum bearer IS that lane.
    if (!(PreferencesService.instanceSync?.xprsServeHistory ?? true)) return;
    final archive = XprsArchive.instance;
    if (!archive.ready) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    final cmdId = xprsIdentifier(p);
    // The requester's advert re-airs the identical wire for its TTL and the
    // 0x58 path has no payload dedup: one answer per command, then quiet.
    _answeredIds.removeWhere(
        (_, t) => now - t > answeredWindow.inMilliseconds);
    if (_answeredIds.containsKey(cmdId)) return;
    _answeredIds[cmdId] = now;

    final from = _base(p['f'] ?? '');
    if (from.isEmpty) return;

    // A forged command deserves no airtime at all.
    if (p.has('sig')) {
      final state = xprsVerify(p, archive.keyResolver?.call(from));
      if (state == XprsSigState.forged) return;
    }

    // Flush so a window ending "now" sees what was heard seconds ago.
    archive.flush(nowMs: now);

    final selfIsAsking = from == selfBase;
    if (!selfIsAsking && !_budgetAllows(from, now)) {
      refused429++;
      LogService.instance
          .add('XPRS: history for $from refused — over budget (429)');
      _airControl(selfBase, from, cmdId, 429);
      return;
    }

    final sinceMs = xprsParseTs(p['since']);
    final untilMs = xprsParseTs(p['until']) ?? (now + 1);
    final rows = archive.query(
        sinceMs: sinceMs,
        untilMs: untilMs,
        only: p['only'],
        types: _kinds(p) ?? XprsArchive.kXprsTalk.toList(),
        limit: pageSize + 1);
    answered++;

    if (rows.isEmpty) {
      // Logged because an unexpected 404 is the first thing a person
      // debugging a silent replay needs to see.
      LogService.instance
          .add('XPRS: history for $from — nothing held in that window (404)');
      // A miss is not a dead end (36.9): when the ask named a callsign and
      // gossip knows who HAS heard it, the 404 carries `m:try` naming them.
      final asked = _base(p['only'] ?? '');
      final tries = asked.isEmpty
          ? const <String>[]
          : XprsGossip.instance.tryCandidates(asked, selfBase: selfBase);
      _airControl(selfBase, from, cmdId, 404,
          m: tries.isEmpty ? null : 'try ${tries.join(',')}');
      return;
    }
    // A new ask from the requester whose replay is running supersedes it
    // (they narrowed the window; the old page is stale). Anyone else waits:
    // one replay in flight protects the channel (31.4).
    if (_chain != null) {
      if (_chainFor == from) {
        _chain?.cancel();
        _chain = null;
        _chainFor = null;
      } else {
        refused429++;
        _airControl(selfBase, from, cmdId, 429);
        return;
      }
    }
    if (!selfIsAsking) _recordAsk(from, now);

    final more = rows.length > pageSize;
    final page = [for (final r in rows.take(pageSize)) r['wire'] as String];
    // The keys ride the same page (36.9.4): an observation about the asked
    // callsign is signed by its OBSERVER, and an asker who has never met
    // that observer cannot verify it — so a page of sightings without the
    // observers' identities is a page of claims the asker must discard.
    // Prepend the newest stored `t:identity` of every observation signer on
    // the page, once each, before the observations they vouch for.
    {
      final signers = <String>{};
      for (final r in rows.take(pageSize)) {
        if (r['type'] == 'observation') {
          final s = (r['from'] as String? ?? '').trim();
          if (s.isNotEmpty && s != from) signers.add(s);
        }
      }
      final ids = <String>[];
      for (final s in signers) {
        final id = archive.query(only: s, types: const ['identity'], limit: 1);
        if (id.isNotEmpty) {
          final w = id.first['wire'] as String;
          if (!page.contains(w)) ids.add(w);
        }
      }
      page.insertAll(0, ids);
    }
    _airControl(selfBase, from, cmdId, 202);
    var i = 0;
    _chainFor = from;
    _chain = Timer.periodic(interPacket, (t) {
      if (i < page.length) {
        // The stored wire, byte for byte — the author's packet, the author's
        // signature (25.2.1, 36.2).
        unawaited(_air('xprs-hist:$i', page[i], const Duration(seconds: 10),
            to: from));
        i++;
        return;
      }
      t.cancel();
      _chain = null;
      _chainFor = null;
      _airControl(selfBase, from, cmdId, more ? 206 : 200);
    });
    LogService.instance.add('XPRS: history for $from — ${page.length} '
        'packet${page.length == 1 ? "" : "s"}${more ? ", more held" : ""}');
  }

  bool _budgetAllows(String from, int now) {
    // A super-archiver (36.9.4) exists to be leaned on: thousands of asks a
    // minute is its design point, so the reference budgets scale rather
    // than apply.
    final superScale =
        (PreferencesService.instanceSync?.xprsSuperArchiver ?? false)
            ? 1000
            : 1;
    void trim(List<int> l) => l.removeWhere((t) => now - t > 3600000);
    trim(_asksGlobal);
    final mine = _asksBy.putIfAbsent(from, () => []);
    trim(mine);
    if (_asksGlobal.length >= globalPerHour * superScale) return false;
    final known = XprsArchive.instance.hasActiveDecl(from, nowMs: now) ||
        XprsArchive.instance.keyResolver?.call(from) != null;
    return mine.length <
        (known ? knownPerHour : strangerPerHour) * superScale;
  }

  void _recordAsk(String from, int now) {
    _asksGlobal.add(now);
    _asksBy.putIfAbsent(from, () => []).add(now);
  }

  void _airControl(String self, String to, String cmdId, int code,
      {String? m}) {
    final p = _result(self, to, cmdId, code, m: m);
    if (p == null) return;
    unawaited(_air('xprs-hist:c$code', p.encode(),
        const Duration(seconds: 30), to: to));
  }

  XprsPacket? _result(String self, String to, String cmdId, int code,
      {String? m}) {
    final now = DateTime.now().toUtc();
    String two(int n) => n.toString().padLeft(2, '0');
    final ts = '${now.year}-${two(now.month)}-${two(now.day)}_'
        '${two(now.hour)}:${two(now.minute)}:${two(now.second)}';
    var p = XprsPacket.parse('t:result f:$self d:$to ts:$ts r:$cmdId '
        'code:$code${m == null ? '' : ' m:$m'}');
    if (p == null) return null;
    final d = signingKey();
    if (d != null) p = xprsSign(p, d);
    return p;
  }

  /// Serve a `cmd:history` INLINE — the TCP lane of section 24.4, where the
  /// reply travels the socket that carried the ask. No airtime, so no pacing
  /// and a larger page; no metering, because the asker's own connection is
  /// the budget. Returns the reply wires in order: the result code, the
  /// original packets newest first, then 200 or 206 — or a single 404.
  /// Empty when [cmd] is not a history command addressed to us.
  static const int inlinePageSize = 50;

  List<String> serveInline(XprsPacket cmd, {required String selfBase}) {
    if (cmd.type != 'command' || (cmd['cmd'] ?? '') != 'history') return [];
    if (_base(cmd['d'] ?? '') != selfBase) return [];
    if (!(PreferencesService.instanceSync?.xprsServeHistory ?? true)) {
      return [];
    }
    final archive = XprsArchive.instance;
    if (!archive.ready) return [];
    final from = _base(cmd['f'] ?? '');
    if (from.isEmpty) return [];
    if (cmd.has('sig')) {
      final state = xprsVerify(cmd, archive.keyResolver?.call(from));
      if (state == XprsSigState.forged) return [];
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    archive.flush(nowMs: now);
    final cmdId = xprsIdentifier(cmd);
    final rows = archive.query(
        sinceMs: xprsParseTs(cmd['since']),
        untilMs: xprsParseTs(cmd['until']) ?? (now + 1),
        only: cmd['only'],
        types: _kinds(cmd) ?? XprsArchive.kXprsTalk.toList(),
        limit: inlinePageSize + 1);
    answered++;
    if (rows.isEmpty) {
      return [
        if (_result(selfBase, from, cmdId, 404) case final p?) p.encode()
      ];
    }
    final more = rows.length > inlinePageSize;
    return [
      if (_result(selfBase, from, cmdId, 202) case final p?) p.encode(),
      for (final r in rows.take(inlinePageSize)) r['wire'] as String,
      if (_result(selfBase, from, cmdId, more ? 206 : 200) case final p?)
        p.encode(),
    ];
  }

  /// Put one wire of the answer on air.
  ///
  /// EVERY bearer, not Bluetooth. This called Ble5Bus directly, which made
  /// the archive role a Bluetooth feature by accident: a station that asked
  /// over the LAN, ESP-NOW or a LoRa link got its 202 and its records aired
  /// on a radio it was not listening to, and heard silence. Measured on the
  /// bench -- a LAN asker saw the phone's own catch-up questions arrive over
  /// UDP while every answer it sent went out on BLE alone.
  ///
  /// The publisher is the one place that knows what this device can transmit
  /// on, which is also what docs/architecture.md means by transports being
  /// core: a service decides WHAT to say, never which radio carries it.
  /// [verbatim] because a replayed record is the author's packet, not ours.
  Future<bool> _air(String key, String wire, Duration ttl, {String? to}) {
    final tx = txOverride;
    if (tx != null) {
      return tx(key, Uint8List.fromList(utf8.encode(wire)), ttl);
    }
    // The public hubs permit identity announces and messages and throttle
    // the rest, so a replayed RECORD (no d: of its own) would die on the
    // announce lane before reaching an internet asker. When the asker is
    // known and the network can name it, every page rides the directed
    // LXMF lane BESIDE the radio broadcast -- 36.0's path rule: the lane
    // with evidence of reaching the asker. Duplicates dedup on the
    // section 5 identifier.
    if (to != null && to.isNotEmpty) {
      final hex = RnsService.instance.lxmfDestForCallsign(to);
      if (hex.isNotEmpty) {
        unawaited(RnsService.instance
            .wappSendTo('xprs', hex, Uint8List.fromList(utf8.encode(wire))));
      }
    }
    return XprsPublisher.instance
        .publishWire(wire, slot: key, ttl: ttl, verbatim: true)
        .then((r) => r.values.any((v) => v == 'sent'));
  }

  /// The person, with any device suffix removed: `X1ABCD-1` -> `X1ABCD`
  /// (spec section 3.1). One definition, shared, so the person/device
  /// split cannot drift between the archive, the ingest and the server.
  static String _base(String c) => NostrCrypto.bareCallsign(c);

  /// Tests only: forget budgets, dedup and any running chain.
  void reset() {
    _answeredIds.clear();
    _asksBy.clear();
    _asksGlobal.clear();
    _chain?.cancel();
    _chain = null;
    _chainFor = null;
    answered = 0;
    refused429 = 0;
  }
}
