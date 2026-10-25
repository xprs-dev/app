/*
 * The forwarder (XPRS.md 12.8.1): where a holder sends mail it cannot
 * deliver, and the two rules that keep it from being a flood.
 *
 * Every seam injected: no radio, no profile, no Reticulum. Gossip runs on a
 * real table in a temp dir because the L3/L2 distinction the forwarder
 * routes by is the table's.
 */
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart';
import 'package:xprs/services/xprs/xprs_forwarder.dart';
import 'package:xprs/services/xprs/xprs_gossip.dart';
import 'package:xprs/services/xprs/xprs_packet.dart';

void main() {
  late Directory tmp;
  final g = XprsGossip.instance;
  final f = XprsForwarder.instance;
  // Near the real clock: whereIs applies the live TTL on the read, so a
  // sighting dated 2023 is a visit, not a live claim.
  final t0 = DateTime.now().millisecondsSinceEpoch - 60000;
  const self = 'X3ARC1';
  const mail = 't:message f:X1QZ3N d:X1BOA3 ts:2026-08-17_14:02:00 '
      'x:pQ4m9xT2vB8kRZ7cW0yLuJ3gRhN8sEiDoQ6vXaB1MnYw';

  late List<(String, String)> sent;
  late Set<String> deliverable;
  late List<String> holders;
  late List<String> named;

  setUpAll(() {
    open.overrideFor(
        OperatingSystem.linux, () => DynamicLibrary.open('libsqlite3.so.0'));
    tmp = Directory.systemTemp.createTempSync('xprsfwd');
    g.init('${tmp.path}/gossip.sqlite3');
  });

  setUp(() {
    g.debugReset();
    f.debugReset();
    sent = [];
    deliverable = {};
    holders = [];
    named = [];
    f
      ..sendTo = ((call, wire) async {
        sent.add((call, wire));
        return true;
      })
      ..canDeliver = ((c) => deliverable.contains(c))
      ..holdersOf = ((_) => holders)
      ..namedArchivers = (() => named);
  });

  tearDownAll(() {
    g.close();
    tmp.deleteSync(recursive: true);
  });

  /// [observer] signed an observation saying it hears X1BOA3 on [link].
  void heardBy(String observer, {String link = 'ble', int? at}) {
    g.noteHears(observer, ['X1BOA3'],
        link: link, verified: true, nowMs: at ?? t0);
  }

  Future<List<String>> forward() =>
      f.maybeForward('X1BOA3', mail, selfBase: self);

  test('every gateway with a live sighting gets its own copy', () async {
    heardBy('X3RLY7');
    heardBy('X3GATE', at: t0 + 1000);
    final went = await forward();
    expect(went.toSet(), {'X3RLY7', 'X3GATE'});
    expect(sent.length, 2);
    for (final (_, w) in sent) {
      final p = XprsPacket.parse(w)!;
      expect(p['via'], self, reason: 'one hop per holder, ours');
      expect(p['f'], 'X1QZ3N', reason: 'custody keeps the author');
    }
  });

  test('the recipient\'s own declaration comes first', () async {
    holders = ['X3HOME'];
    heardBy('X3RLY7');
    final went = await forward();
    expect(went.first, 'X3HOME');
    expect(went, contains('X3RLY7'));
  });

  test('a visit (L2) is used only when nothing is live, and only the freshest',
      () async {
    // Two radio hearings a week ago: live rows expired, visits remain.
    heardBy('X3OLD', at: t0 - 8 * 86400000);
    heardBy('X3OLDER', at: t0 - 9 * 86400000);
    // The table's reads apply the TTL against the real clock; both are long
    // past it, so whereIs offers them as visits only.
    expect(g.whereIs('X1BOA3').where((s) => s.live), isEmpty);
    expect(await forward(), ['X3OLD']);
  });

  test('a holder that can reach the recipient forwards nothing', () async {
    heardBy('X3RLY7');
    deliverable = {'X1BOA3'};
    expect(await forward(), isEmpty);
    expect(sent, isEmpty);
    expect(f.selfDelivers, 1);
  });

  test('once per gateway: a re-heard copy goes nowhere, a new reporter gets it',
      () async {
    heardBy('X3RLY7');
    expect(await forward(), ['X3RLY7']);
    expect(await forward(), isEmpty, reason: 'same packet, same gateway');
    heardBy('X3GATE', at: t0 + 5000);
    expect(await forward(), ['X3GATE'], reason: 'the newcomer, only');
    expect(sent.map((e) => e.$1).toList(), ['X3RLY7', 'X3GATE']);
  });

  test('never back to a hop it took, never to ourselves or the recipient',
      () async {
    heardBy('X3RLY7');
    heardBy(self);
    heardBy('X1BOA3'); // a station listing itself is nonsense gossip
    final carried = '$mail via:X3RLY7';
    final went = await f.maybeForward('X1BOA3', carried, selfBase: self);
    expect(went, isEmpty);
    expect(f.noRoute, 1);
  });

  test('a packet that already passed through us is a loop', () async {
    heardBy('X3RLY7');
    expect(await f.maybeForward('X1BOA3', '$mail via:$self', selfBase: self),
        isEmpty);
    expect(f.loops, 1);
  });

  test('our own authored wire is not relayed by its author', () async {
    heardBy('X3RLY7');
    expect(await f.maybeForward('X1BOA3', mail, selfBase: 'X1QZ3N'), isEmpty);
    expect(sent, isEmpty);
  });

  test('with no sighting at all, the mail is deposited with a named archiver',
      () async {
    named = ['X3BIG'];
    expect(await forward(), ['X3BIG']);
  });

  test('a group is never forwarded', () async {
    heardBy('X3RLY7');
    const post = 't:message f:X1QZ3N d:X5A3F2 ts:2026-08-17_14:02:00 m:hi';
    expect(await f.maybeForward('X5A3F2', post, selfBase: self), isEmpty);
  });

  // ── Part 3: the report that arrives after the mail did ──────────────────

  test('a new report re-runs the forwarder for the held mail, to the reporter '
      'only', () async {
    f.heldFor = ((c) => c == 'X1BOA3' ? [mail] : const []);
    // The mail arrived first: nothing known, deposited with the named one.
    named = ['X3BIG'];
    expect(await forward(), ['X3BIG']);
    // Then somebody reports hearing the recipient.
    heardBy('X3RLY7');
    expect(await f.retry('X1BOA3', selfBase: self, nowMs: t0), 1);
    expect(sent.map((e) => e.$1).toList(), ['X3BIG', 'X3RLY7']);
    expect(f.retries, 1);
  });

  test('a burst of reports costs one pass per half minute', () async {
    f.heldFor = ((_) => [mail]);
    heardBy('X3RLY7');
    expect(await f.retry('X1BOA3', selfBase: self, nowMs: t0), 1);
    heardBy('X3GATE', at: t0 + 1000);
    expect(await f.retry('X1BOA3', selfBase: self, nowMs: t0 + 1000), 0,
        reason: 'inside the throttle');
    expect(
        await f.retry('X1BOA3',
            selfBase: self, nowMs: t0 + XprsForwarder.retryEveryMs),
        1,
        reason: 'the newcomer gets its copy on the next pass');
    expect(sent.map((e) => e.$1).toList(), ['X3RLY7', 'X3GATE']);
  });

  test('nothing held for the reported station: nothing happens', () async {
    f.heldFor = ((_) => const []);
    heardBy('X3RLY7');
    expect(await f.retry('X1BOA3', selfBase: self, nowMs: t0), 0);
    expect(f.retries, 0);
  });

  test('gossip fires the sighting hook once per new pair, not per beacon',
      () async {
    final fired = <String>[];
    g.onSighting = (c, gw) => fired.add('$c@$gw');
    heardBy('X3RLY7');
    heardBy('X3RLY7', at: t0 + 40000); // the same claim, refreshed
    heardBy('X3GATE', at: t0 + 1000);
    expect(fired, ['X1BOA3@X3RLY7', 'X1BOA3@X3GATE']);
  });

  test('at most G gateways, freshest first', () async {
    for (var i = 0; i < 12; i++) {
      heardBy('X3G${i.toString().padLeft(2, '0')}', at: t0 + i * 1000);
    }
    final went = await forward();
    expect(went.length, XprsForwarder.maxGateways);
    expect(went.first, 'X3G11');
  });
}
