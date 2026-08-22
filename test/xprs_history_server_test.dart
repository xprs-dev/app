/*
 * XprsHistoryServer tests — the cmd:history responder: 404 with the
 * command's id, 202 → byte-identical replay → 200/206 paging, only: filter,
 * metering tiers, one-replay-in-flight, and advert-echo dedup.
 */
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:aurora/services/xprs/xprs_archive.dart';
import 'package:aurora/services/xprs/xprs_history_server.dart';
import 'package:aurora/services/xprs/xprs_id.dart';
import 'package:aurora/services/xprs/xprs_ingest.dart';
import 'package:aurora/services/xprs/xprs_packet.dart';
import 'package:aurora/services/xprs/xprs_publisher.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart';

final BigInt _d =
    BigInt.parse('1234567890abcdef1234567890abcdef', radix: 16);

XprsPacket _p(String wire) => XprsPacket.parse(wire)!;

/// A bearer that only records. Two of these stand in for "this device has
/// more than one radio", which is the whole point of the test below.
class _RecordingBearer implements XprsBearer {
  _RecordingBearer(this.name);
  @override
  final String name;
  @override
  String get archiveBearer => name;
  @override
  bool get shortRange => true;
  @override
  Future<bool> get active async => true;
  final List<String> sent = [];
  final List<Duration?> ttls = [];
  @override
  Future<bool> send(String wire,
      {required int part, String slot = 'status', Duration? ttl}) async {
    sent.add(wire);
    ttls.add(ttl);
    return true;
  }
}


void main() {
  late Directory tmp;
  late XprsArchive a;
  late XprsHistoryServer srv;
  late List<(String key, String wire)> aired;

  setUpAll(() {
    open.overrideFor(
        OperatingSystem.linux, () => DynamicLibrary.open('libsqlite3.so.0'));
  });

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('xprshist');
    a = XprsArchive.instance;
    a
      ..selfCallsign = 'X1SELF'
      ..keyResolver = null
      ..protectedCallsigns = null
      ..maxBytes = 500 * 1024 * 1024
      ..maxAgeDays = 365
      ..init('${tmp.path}/xprs_archive.sqlite3');
    srv = XprsHistoryServer.instance;
    srv.reset();
    srv.signingKey = () => _d;
    aired = [];
    srv.txOverride = (key, bytes, ttl) async {
      aired.add((key, utf8.decode(bytes)));
      return true;
    };
    srv.install();
  });

  tearDown(() {
    XprsIngest.onCommand = null;
    srv.txOverride = null;
    a.close();
    tmp.deleteSync(recursive: true);
  });

  void seed(int n, {String from = 'X1AAA', int startMin = 0}) {
    for (var i = 0; i < n; i++) {
      final min = startMin + i;
      a.admit(
          _p('t:info f:$from ts:2026-08-13_10:${min.toString().padLeft(2, '0')}'
              ':00 m:packet number $i'),
          bearer: 'ble',
          nowMs: 1000 + i);
    }
    a.flush(nowMs: 100000);
  }

  void ask(String wire) => XprsIngest.heard(_p(wire),
      bearer: 'ble', selfCallsign: 'X1SELF', rssi: -60);

  List<XprsPacket> results() => [
        for (final e in aired)
          if (e.$1.startsWith('xprs-hist:c')) _p(e.$2)
      ];

  test('empty window: one signed 404 carrying the command id', () {
    final cmd = _p('t:command f:X1BBB d:X1SELF ts:2026-08-13_12:00:00 '
        'cmd:history since:2027-01-01_00:00:00');
    ask(cmd.encode());
    expect(aired, hasLength(1));
    final r = results().single;
    expect(r['code'], '404');
    expect(r['r'], xprsIdentifier(cmd));
    expect(r['sig'], isNotNull);
    expect(r['d'], 'X1BBB');
  });

  test('202, byte-identical page, 206 when more held, continuation to 200',
      () {
    seed(14);
    fakeAsync((async) {
      // until: bounds the window so the command itself stays out of it.
      ask('t:command f:X1BBB d:X1SELF ts:2026-08-13_12:00:00 cmd:history '
          'until:2026-08-13_11:00:00');
      expect(results().single['code'], '202');
      async.elapse(const Duration(seconds: 30));
      final wires = [
        for (final e in aired)
          if (!e.$1.startsWith('xprs-hist:c')) e.$2
      ];
      expect(wires, hasLength(12));
      // Newest first, and byte-identical to what was admitted.
      expect(wires.first, contains('m:packet number 13'));
      expect(wires.last, contains('m:packet number 2'));
      expect(results().last['code'], '206');

      // Continue: until = oldest ts received (10:02). Different command id.
      aired.clear();
      ask('t:command f:X1BBB d:X1SELF ts:2026-08-13_12:01:00 cmd:history '
          'until:2026-08-13_10:02:00');
      async.elapse(const Duration(seconds: 10));
      final tail = [
        for (final e in aired)
          if (!e.$1.startsWith('xprs-hist:c')) e.$2
      ];
      expect(tail, hasLength(2));
      expect(results().last['code'], '200');
    });
  });

  test('only: filters by sender or addressee', () {
    seed(3, from: 'X1AAA');
    seed(2, from: 'X1CCC', startMin: 30);
    fakeAsync((async) {
      ask('t:command f:X1BBB d:X1SELF ts:2026-08-13_12:00:00 cmd:history '
          'only:X1CCC until:2026-08-13_11:00:00');
      async.elapse(const Duration(seconds: 20));
      final wires = [
        for (final e in aired)
          if (!e.$1.startsWith('xprs-hist:c')) e.$2
      ];
      expect(wires, hasLength(2));
      expect(wires.every((w) => w.contains('f:X1CCC')), true);
    });
  });

  test('advert echo of the same command answers once', () {
    seed(2);
    fakeAsync((async) {
      const cmd = 't:command f:X1BBB d:X1SELF ts:2026-08-13_12:00:00 '
          'cmd:history until:2026-08-13_11:00:00';
      ask(cmd);
      async.elapse(const Duration(seconds: 20));
      final n = aired.length;
      ask(cmd); // the sender's advert re-airing the identical bytes
      async.elapse(const Duration(seconds: 20));
      expect(aired.length, n);
    });
  });

  test('stranger metering: third replay inside the hour refused out loud',
      () {
    seed(3);
    fakeAsync((async) {
      for (var i = 0; i < 3; i++) {
        ask('t:command f:X1BBB d:X1SELF ts:2026-08-13_12:0$i:00 cmd:history '
            'until:2026-08-13_11:00:00');
        async.elapse(const Duration(seconds: 30));
      }
      final codes = [for (final r in results()) r['code']];
      expect(codes.where((c) => c == '202'), hasLength(2));
      expect(codes.last, '429');
    });
  });

  test('serveInline: 202 + wires + 200 on the socket lane, 404 when empty',
      () {
    seed(3);
    final page = srv.serveInline(
        _p('t:command f:X1BBB d:X1SELF ts:2026-08-13_12:00:00 cmd:history '
            'until:2026-08-13_11:00:00'),
        selfBase: 'X1SELF');
    expect(page, hasLength(5));
    expect(_p(page.first)['code'], '202');
    expect(_p(page.last)['code'], '200');
    // The middle is the stored wires, newest first, byte-identical.
    expect(page[1], contains('m:packet number 2'));
    expect(page[3], contains('m:packet number 0'));

    final empty = srv.serveInline(
        _p('t:command f:X1BBB d:X1SELF ts:2026-08-13_12:01:00 cmd:history '
            'since:2027-01-01_00:00:00'),
        selfBase: 'X1SELF');
    expect(empty, hasLength(1));
    expect(_p(empty.single)['code'], '404');

    // Not for us / not a history command: nothing.
    expect(
        srv.serveInline(
            _p('t:command f:X1BBB d:X1ELSE ts:2026-08-13_12:02:00 '
                'cmd:history'),
            selfBase: 'X1SELF'),
        isEmpty);
  });

  test('one replay in flight: a second requester gets 429, self unmetered',
      () {
    seed(14);
    fakeAsync((async) {
      ask('t:command f:X1BBB d:X1SELF ts:2026-08-13_12:00:00 cmd:history '
          'until:2026-08-13_11:00:00');
      // Mid-chain, someone else asks.
      async.elapse(const Duration(seconds: 3));
      ask('t:command f:X1CCC d:X1SELF ts:2026-08-13_12:00:05 cmd:history '
          'until:2026-08-13_11:00:00');
      final second =
          results().where((r) => r['d'] == 'X1CCC').toList();
      expect(second.single['code'], '429');
      async.elapse(const Duration(seconds: 30));

      // Our own second device asks four times: never metered.
      aired.clear();
      for (var i = 0; i < 4; i++) {
        ask('t:command f:X1SELF-2 d:X1SELF ts:2026-08-13_13:0$i:00 '
            'cmd:history until:2026-08-13_11:00:00');
        async.elapse(const Duration(seconds: 30));
      }
      final codes = [
        for (final r in results())
          if (r['d'] == 'X1SELF') r['code']
      ];
      expect(codes.where((c) => c == '202'), hasLength(4));
    });
  });

  // The bug this pins: _air used to call Ble5Bus directly, so a station that
  // asked over the LAN got its answer aired on Bluetooth and heard nothing.
  // Every other test here installs txOverride, which replaces exactly the
  // code that was wrong -- so the whole suite passed while the archive role
  // only worked on one radio. This one lets the real path run.
  group('the answer goes out on every bearer, not just Bluetooth', () {
    late _RecordingBearer ble;
    late _RecordingBearer lan;
    late List<XprsBearer> saved;

    setUp(() {
      srv.txOverride = null;               // let _air do its real work
      saved = XprsPublisher.instance.bearers;
      ble = _RecordingBearer('ble5');
      lan = _RecordingBearer('lan');
      XprsPublisher.instance.bearers = [ble, lan];
    });

    tearDown(() => XprsPublisher.instance.bearers = saved);

    test('202 and the replayed records reach both bearers', () async {
      seed(2);
      ask('t:command f:X1BBB d:X1SELF cmd:history '
          'ts:2026-08-13_12:00:00 since:2026-08-13_09:00:00');
      // The 202 is composed and aired without awaiting; give the bearer
      // probes (each an async `active`) a turn before looking.
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(ble.sent, isNotEmpty, reason: 'Bluetooth heard the answer');
      expect(lan.sent, isNotEmpty,
          reason: 'the LAN asker must hear it too — this is the regression');
      expect(lan.sent.first, contains('code:202'));
      expect(lan.sent.first, equals(ble.sent.first));

      // ...and the records that follow, not only the control packet.
      await Future<void>.delayed(
          XprsHistoryServer.interPacket + const Duration(milliseconds: 200));
      expect(lan.sent.length, greaterThan(1));
      expect(lan.sent[1], contains('packet number'));

      // A paced replay must not hold an advert slot for the advertiser's
      // 120 s default: the caller's ttl has to survive the trip.
      expect(ble.ttls.first, isNotNull);
      expect(ble.ttls.first!.inSeconds, lessThan(60));
    });

    test('a replayed record keeps the author\'s bytes and is not refiled',
        () async {
      seed(1, from: 'X1AAA');
      final stored = a
          .query(limit: 50)
          .firstWhere((r) => (r['wire'] as String).contains('packet number'));
      ask('t:command f:X1BBB d:X1SELF cmd:history '
          'ts:2026-08-13_12:00:00 since:2026-08-13_09:00:00');
      await Future<void>.delayed(
          XprsHistoryServer.interPacket + const Duration(milliseconds: 250));

      final record = lan.sent.firstWhere((w) => w.contains('packet number'));
      // Byte for byte: no signature added, so the identifier still matches
      // the row the asker will page against with until: (25.2.1, 36.2).
      expect(record, equals(stored['wire']));
      expect(record, contains('f:X1AAA'));
      // Re-airing another station's packet must not file a second copy of it
      // under our own name.
      final copies = a
          .query(limit: 50)
          .where((r) => r['wire'] == record)
          .toList();
      expect(copies, hasLength(1));
      expect(copies.single['own'], isFalse);
    });
  });
}
