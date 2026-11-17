/*
 * XprsHistoryServer tests — the cmd:history responder: 404 with the
 * command's id, 202 → byte-identical replay → 200/206 paging, only: filter,
 * metering tiers, one-replay-in-flight, and advert-echo dedup.
 */
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:reticulum/reticulum.dart' show XprsCrypto;
import 'package:xprs/services/xprs/xprs_archive.dart';
import 'package:xprs/services/xprs/xprs_gossip.dart';
import 'package:xprs/services/xprs/xprs_group_read.dart';
import 'package:xprs/services/xprs/xprs_groups.dart';
import 'package:xprs/util/nostr_crypto.dart';
import 'package:hex/hex.dart';
import 'package:xprs/services/xprs/xprs_history_server.dart';
import 'package:xprs/services/xprs/xprs_sig.dart';
import 'package:xprs/services/xprs/xprs_folder.dart';
import 'package:xprs/services/xprs/xprs_files.dart';
import 'package:xprs/services/xprs/xprs_id.dart';
import 'package:xprs/services/xprs/xprs_ingest.dart';
import 'package:xprs/services/xprs/xprs_packet.dart';
import 'package:xprs/services/xprs/xprs_publisher.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xprs/services/preferences_service.dart';

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
  Future<XprsSendResult> send(String wire,
      {required int part, String slot = 'status', Duration? ttl, bool datagram = false, bool verbatim = false}) async {
    sent.add(wire);
    ttls.add(ttl);
    return XprsSendResult.sent;
  }
}


void main() {
  late Directory tmp;
  late XprsArchive a;
  late XprsHistoryServer srv;
  late List<(String key, String wire)> aired;


  setUp(() async {
    // This station answers for other people, which since the archiver tiers
    // (XPRS.md 12) is a deliberate choice rather than the default: a private
    // station serves a stranger only its own publications.
    SharedPreferences.setMockInitialValues({'flutter.xprs.public': true});
    await PreferencesService.instance();
    tmp = Directory.systemTemp.createTempSync('xprshist');
    a = XprsArchive.instance;
    a
      ..selfCallsign = 'X1SELF'
      ..keyResolver = null
      ..maxBytes = 500 * 1024 * 1024
      ..maxAgeDays = 365
      ..init('${tmp.path}/xprs_archive.zx');
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

  /// The same command arriving off the Reticulum hub lane.
  void ask2(String wire) => XprsIngest.heard(_p(wire),
      bearer: 'rns', selfCallsign: 'X1SELF', rssi: 0);

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

  // 26.4: a member who joined late, or was away, reads a closed group's talk
  // from another member. A private station (Public archiver off) keeps that
  // talk as its own mail, and serves it to a fellow member asking `only:` the
  // group; anybody else still gets this station's own publications only.
  group('a closed group, asked by a member', () {
    const g = 'X5FAM1';
    final keys = <String, ({BigInt d, Uint8List pub})>{};
    ({BigInt d, Uint8List pub}) keyFor(String c) => keys.putIfAbsent(c, () {
          final kp = NostrCrypto.generateKeyPair();
          var d = BigInt.zero;
          for (final b in HEX.decode(kp.privateKeyHex)) {
            d = (d << 8) | BigInt.from(b);
          }
          return (d: d, pub: Uint8List.fromList(HEX.decode(kp.publicKeyHex)));
        });
    void join(String who, String at) {
      final grant = xprsSign(
          _p('t:moderate f:$g d:$g ts:2026-08-13_09:00:00 grant:$who'), keyFor(g).d);
      XprsGroups.instance.offer(grant);
      XprsGroups.instance.offer(xprsSign(
          _p('t:moderate f:$who d:$g ts:$at r:${xprsIdentifier(grant)} accept:member'),
          keyFor(who).d));
    }

    setUp(() async {
      await PreferencesService.instanceSync!.setXprsPublicArchiver(false);
      XprsGroups.instance
        ..clear()
        ..keyResolver = (c) => keyFor(c).pub;
      join('X1SELF', '2026-08-13_09:01:00');
      join('X1CAI', '2026-08-13_09:02:00');
      a.admit(_p('t:message f:X1BEA d:$g ts:2026-08-13_10:00:00 m:lunch on sunday'),
          bearer: 'ble', nowMs: 1000);
      a.flush(nowMs: 100000);
    });
    tearDown(() async {
      XprsGroups.instance.clear();
      await PreferencesService.instanceSync!.setXprsPublicArchiver(true);
    });

    List<String> replayed(FakeAsync async, String asker) {
      aired.clear();
      ask('t:command f:$asker d:X1SELF ts:2026-08-13_12:00:00 cmd:history '
          'kind:message only:$g until:2026-08-13_11:00:00');
      async.elapse(const Duration(seconds: 30));
      return [
        for (final e in aired)
          if (!e.$1.startsWith('xprs-hist:c')) e.$2
      ];
    }

    test('a fellow member gets what was said', () {
      fakeAsync((async) {
        expect(replayed(async, 'X1CAI').single, contains('m:lunch on sunday'));
      });
    });

    test('somebody outside the group does not', () {
      fakeAsync((async) {
        expect(replayed(async, 'X1EVE'), isEmpty);
      });
    });

    // 10.7.1: a public group is read by anyone, so a member serves its talk
    // to whoever asks; a private one still goes to members only.
    test('a public group is served to anybody', () {
      final tmpR = Directory.systemTemp.createTempSync('xprsread');
      addTearDown(() {
        XprsGroupRead.instance.close();
        tmpR.deleteSync(recursive: true);
      });
      XprsGroupRead.instance
        ..init('${tmpR.path}/r.zx')
        ..autoTend = false;
      XprsGroupRead.instance.takeKeyMessage(g, 'nsec:-');
      fakeAsync((async) {
        expect(replayed(async, 'X1EVE').single, contains('m:lunch on sunday'));
      });
    });
  });

  // 7.3: an open group is public. A private station that follows one serves
  // what it kept of it to whoever asks for it by name -- and naming a PERSON
  // in only: still serves none of their mail.
  group('an open group this station follows', () {
    setUp(() async {
      await PreferencesService.instanceSync!.setXprsPublicArchiver(false);
      XprsArchive.instance.followedGroups = {'PICNIC'};
      a.admit(_p('t:message f:X1BEA d:PICNIC ts:2026-08-13_10:00:00 m:picnic on saturday'),
          bearer: 'ble', nowMs: 1000);
      a.admit(_p('t:message f:X1CAI d:X1BEA ts:2026-08-13_10:01:00 m:a private word'),
          bearer: 'ble', nowMs: 1001);
      a.flush(nowMs: 100000);
    });
    tearDown(() async {
      XprsArchive.instance.followedGroups = const {};
      await PreferencesService.instanceSync!.setXprsPublicArchiver(true);
    });

    List<String> replayed(FakeAsync async, String only) {
      aired.clear();
      ask('t:command f:X1EVE d:X1SELF ts:2026-08-13_12:00:00 cmd:history '
          'kind:message only:$only until:2026-08-13_11:00:00');
      async.elapse(const Duration(seconds: 30));
      return [
        for (final e in aired)
          if (!e.$1.startsWith('xprs-hist:c')) e.$2
      ];
    }

    test('its talk is served to anybody asking by its name', () {
      fakeAsync((async) {
        expect(replayed(async, 'PICNIC').single, contains('m:picnic on saturday'));
      });
    });

    test("a person's callsign in only: serves none of their mail", () {
      fakeAsync((async) {
        expect(replayed(async, 'X1BEA'), isEmpty);
      });
    });
  });

  test('a direct cmd:history kind:mailbox replays the station own t:mailbox (13.12/36.5)',
      () {
    // The station's own declaration, archived like its daily airing would.
    a.admit(_p('t:mailbox f:X1SELF ts:2026-08-13_10:30:00 hold:X3RLY7,X32DVA'),
        bearer: 'ble', own: true, nowMs: 5000);
    a.flush(nowMs: 100000);
    fakeAsync((async) {
      ask('t:command f:X1BBB d:X1SELF ts:2026-08-13_12:00:00 cmd:history '
          'kind:mailbox only:X1SELF until:2026-08-13_11:00:00');
      async.elapse(const Duration(seconds: 30));
      final wires = [
        for (final e in aired)
          if (!e.$1.startsWith('xprs-hist:c')) e.$2
      ];
      expect(results().first['code'], '202');
      expect(
          wires.any((w) =>
              w.contains('t:mailbox') && w.contains('hold:X3RLY7,X32DVA')),
          isTrue,
          reason: 'a direct ask is answered with the station mailbox list');
    });
  });

  // 10.9 / 12.9.4: a station that never heard a group finds it by its name
  // because an archiver replays the group's identity with everybody else's.
  // A station with a web API (hostedRoom set) used to strip every group's
  // identity from such an answer; only its own unshared rooms are held back.
  test('a bulk identity ask carries groups, but not an unshared hosted room',
      () {
    a.admit(_p('t:identity f:X5BOOK ts:2026-08-13_10:00:00 nick:Book-club'),
        bearer: 'rns', nowMs: 1000);
    a.admit(_p('t:identity f:X5ROOM ts:2026-08-13_10:01:00 nick:Our_room'),
        bearer: 'rns', nowMs: 1000);
    a.admit(_p('t:identity f:X1ANA ts:2026-08-13_10:02:00 nick:Ana'),
        bearer: 'rns', nowMs: 1000);
    a.flush(nowMs: 100000);
    srv.hostedRoom = (g, asker) => g == 'X5ROOM' ? false : null;
    addTearDown(() => srv.hostedRoom = null);
    fakeAsync((async) {
      ask('t:command f:X1BBB d:X1SELF ts:2026-08-13_12:00:00 '
          'cmd:history kind:identity since:2026-08-01_00:00:00');
      async.elapse(const Duration(seconds: 30));
      final wires = [
        for (final e in aired)
          if (!e.$1.startsWith('xprs-hist:c')) e.$2
      ];
      expect(wires.where((w) => w.contains('f:X5BOOK')), hasLength(1));
      expect(wires.where((w) => w.contains('f:X1ANA')), hasLength(1));
      expect(wires.where((w) => w.contains('f:X5ROOM')), isEmpty);
    });
    // The socket lane answers the same, from the same rule.
    final inline = srv.serveInline(
        _p('t:command f:X1BBB d:X1SELF ts:2026-08-13_12:00:01 '
            'cmd:history kind:identity since:2026-08-01_00:00:00'),
        selfBase: 'X1SELF');
    expect(inline.where((w) => w.contains('f:X5BOOK')), hasLength(1));
    expect(inline.where((w) => w.contains('f:X5ROOM')), isEmpty);
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

  // XPRS.md 12.1: mail is held for its addressee and never offered to a third
  // party. On the C61 a phone's page was twelve of everybody's sealed DMs and
  // its own reply competed with all of them (2026-09-15).
  test('somebody else\'s mail is never on the asker\'s page', () {
    for (final w in [
      't:message f:X1UDP4 d:X1BBB ts:2026-08-13_10:01:00 m:for the asker',
      't:message f:X1CCC d:X1DDD ts:2026-08-13_10:02:00 m:for somebody else',
      't:message f:X1CCC ts:2026-08-13_10:03:00 m:for everybody',
    ]) {
      a.admit(_p(w), bearer: 'ble', nowMs: 1000);
    }
    a.flush(nowMs: 100000);
    fakeAsync((async) {
      ask('t:command f:X1BBB d:X1SELF ts:2026-08-13_12:00:00 cmd:history '
          'kind:message until:2026-08-13_11:00:00');
      async.elapse(const Duration(seconds: 20));
      final wires = [
        for (final e in aired)
          if (!e.$1.startsWith('xprs-hist:c')) e.$2
      ];
      expect(wires, hasLength(2));
      expect(wires.any((w) => w.contains('for somebody else')), isFalse);
      expect(results().last['code'], '200');
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

  test('a freely served digest (the firmware mirror) is answered past the budget',
      () {
    const sha =
        '5bf7bf3bb2f6a3d6a4b7ba7f1ad4a6a6a0d1d2d3d4d5d6d7d8d9dadbdcdddedf';
    XprsFileServer.instance.resolver = (h) => h == sha
        ? XprsHeldFile(
            path: '/tmp/tdeck.bin', shaHex: sha, size: 5000, name: 'tdeck.bin',
            ext: 'bin')
        : null;
    XprsHistoryServer.instance.freelyServed = (h) => h == sha;
    addTearDown(() {
      XprsFileServer.instance.resolver = null;
      XprsHistoryServer.instance.freelyServed = null;
    });
    fakeAsync((async) {
      for (var i = 0; i < 5; i++) {
        ask('t:command f:X1BBB d:X1SELF ts:2026-08-13_12:0$i:00 cmd:file '
            'file:${xprsFileRefOf(sha, 'bin')}');
        async.elapse(const Duration(seconds: 30));
      }
      final codes = [for (final r in results()) r['code']];
      expect(codes, hasLength(5));
      expect(codes.where((c) => c == '429'), isEmpty, reason: 'a stranger updating its firmware is not metered');
    });
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

    test('an ask off the internet lane is served like any other (36.0)',
        () async {
      // The bug this pins: bearer 'rns' used to be refused outright -- the
      // guard predated the bearer-abstract _air, so an archiver on the hubs
      // beaconed serve:archive and answered nothing across the internet.
      seed(2);
      ask2('t:command f:X1BBB d:X1SELF cmd:history '
          'ts:2026-08-13_12:00:00 since:2026-08-13_09:00:00');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(lan.sent, isNotEmpty,
          reason: 'the rns ask must be answered, not counted and dropped');
      expect(lan.sent.first, contains('code:202'));
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

  // A miss is not a dead end (XPRS.md 12.9): the 404 names who to try, the
  // callsign's own declared holders first (13.12), then the archivers whose
  // directories list it, then whoever gossip saw it at.
  group('a miss names who to try (12.9)', () {
    late Directory gtmp;
    final g = XprsGossip.instance;
    final key = BigInt.parse('abcdef0123456789abcdef0123456789', radix: 16);

    setUp(() {
      gtmp = Directory.systemTemp.createTempSync('xprshist-gossip');
      g.init('${gtmp.path}/gossip.zx');
      g.debugReset();
      a.keyResolver = (c) => c == 'X1MOBL' ? XprsCrypto.publicKeyXOnly(key) : null;
    });
    tearDown(() {
      g.close();
      gtmp.deleteSync(recursive: true);
    });

    test('a replayed t:mailbox is consumed: holdersFor answers it, and the next miss names it first',
        () {
      // The declaration, replayed over the hubs by a peer archiver's
      // `cmd:history kind:mailbox` answer (12.9.5): the original, verifying
      // on the declaring station's signature.
      final decl = xprsSign(_p('t:mailbox f:X1MOBL ts:2026-08-13_10:00:00 hold:X3HOLD'), key);
      XprsIngest.reticulum('X1MOBL', Uint8List.fromList(utf8.encode(decl.encode())));
      expect(a.holdersFor('X1MOBL'), ['X3HOLD']);
      // Unverifiable: not acted on (9.12).
      XprsIngest.reticulum('X1FAKE', Uint8List.fromList(utf8.encode(
          't:mailbox f:X1FAKE ts:2026-08-13_10:00:00 hold:X3EVIL')));
      expect(a.holdersFor('X1FAKE'), isEmpty);

      final now = DateTime.now().millisecondsSinceEpoch;
      g.notePointers('X3KEEP', [('X1MOBL', now)]);
      g.noteHears('X3SEEN', ['X1MOBL'], link: 'ble', verified: true, nowMs: now);
      // The asker and this station know of it too: neither is named.
      g.noteHears('X1BBB', ['X1MOBL'], link: 'ble', verified: true, nowMs: now);
      g.notePointers('X1SELF', [('X1MOBL', now)]);

      ask('t:command f:X1BBB d:X1SELF ts:2026-08-13_12:00:00 cmd:history '
          'only:X1MOBL since:2027-01-01_00:00:00');
      final r = results().single;
      expect(r['code'], '404');
      expect(r['m'], 'try X3HOLD,X3KEEP,X3SEEN');
    });

    test('tryFor: each once, never us or the asker, three at most', () {
      final now = DateTime.now().millisecondsSinceEpoch;
      g.notePointers('X3ARC1', [('X1MOBL', now)]);
      g.notePointers('X3ARC2', [('X1MOBL', now - 1000)]);
      g.noteHears('X3ARC1', ['X1MOBL'], link: 'lan', verified: true, nowMs: now);
      g.noteHears('X3GW', ['X1MOBL'], link: 'lan', verified: true, nowMs: now);
      g.noteHears('X3GW2', ['X1MOBL'], link: 'lan', verified: true, nowMs: now - 5000);
      expect(XprsHistoryServer.tryFor('X1MOBL', selfBase: 'X1SELF', asker: 'X3ARC2'),
          ['X3ARC1', 'X3GW', 'X3GW2']);
      expect(XprsHistoryServer.tryFor('X1MOBL', selfBase: 'X3ARC1', asker: 'X1BBB'),
          ['X3ARC2', 'X3GW', 'X3GW2']);
      expect(XprsHistoryServer.tryFor('X1NOBODY', selfBase: 'X1SELF'), isEmpty);
    });
  });
}
