/*
 * The device's X3 is the archiver (docs/architecture.md, "The device and its
 * people"): a history ask to the X3 is answered as the X3 and signed with the
 * device key, its policy says what it serves, and a declaration naming the
 * X3 as holder is ours. An ask to the person's X1 is still served, for the
 * stations that chose it before the move.
 */
import 'dart:convert';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reticulum/reticulum.dart'
    show NostrKeyGenerator, XprsCrypto;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xprs/services/preferences_service.dart';
import 'package:xprs/services/xprs/xprs_archive.dart';
import 'package:xprs/services/xprs/xprs_history_server.dart';
import 'package:xprs/services/xprs/xprs_ingest.dart';
import 'package:xprs/services/xprs/xprs_packet.dart';
import 'package:xprs/services/xprs/xprs_sig.dart';
import 'package:xprs_core/src/profile/device_identity.dart';

final BigInt _person =
    BigInt.parse('1234567890abcdef1234567890abcdef', radix: 16);

XprsPacket _p(String wire) => XprsPacket.parse(wire)!;

void main() {
  late Directory tmp;
  late XprsArchive a;
  late XprsHistoryServer srv;
  late List<(String key, String wire)> aired;
  late String x3;
  final devKeys = NostrKeyGenerator.generateKeyPair();

  setUp(() async {
    SharedPreferences.setMockInitialValues({'flutter.xprs.public': true});
    PreferencesService.resetForTest();
    await PreferencesService.instance();
    DeviceIdentity.instance
      ..resetForTest()
      ..adoptForTest(devKeys.nsec);
    x3 = DeviceIdentity.instance.callsign;
    tmp = Directory.systemTemp.createTempSync('xprsdevarch');
    a = XprsArchive.instance
      ..selfCallsign = 'X1SELF'
      ..selfAlsoKnownAs = {x3}
      ..keyResolver = null
      ..maxBytes = 500 * 1024 * 1024
      ..maxAgeDays = 365
      ..init('${tmp.path}/xprs_archive.zx');
    srv = XprsHistoryServer.instance;
    srv.reset();
    srv.signingKey = () => _person;
    srv.serveClaim = () => 'archive';
    aired = [];
    srv.txOverride = (key, bytes, ttl) async {
      aired.add((key, utf8.decode(bytes)));
      return true;
    };
    srv.install();
    for (var i = 0; i < 3; i++) {
      a.admit(
          _p('t:info f:X1AAA ts:2026-08-13_10:0$i:00 m:packet number $i'),
          bearer: 'ble',
          nowMs: 1000 + i);
    }
    a.flush(nowMs: 100000);
  });

  tearDown(() {
    XprsIngest.onCommand = null;
    srv.txOverride = null;
    srv.serveClaim = null;
    a
      ..selfAlsoKnownAs = const {}
      ..close();
    DeviceIdentity.instance.resetForTest();
    tmp.deleteSync(recursive: true);
  });

  void ask(String wire) => XprsIngest.heard(_p(wire),
      bearer: 'ble', selfCallsign: 'X1SELF', rssi: -60);

  List<XprsPacket> results() => [
        for (final e in aired)
          if (e.$1.startsWith('xprs-hist:c')) _p(e.$2)
      ];

  test('a history ask to the X3 is served as the X3, signed by the device',
      () {
    fakeAsync((async) {
      ask('t:command f:X1BBB d:$x3 ts:2026-08-13_12:00:00 cmd:history '
          'until:2026-08-13_11:00:00');
      async.elapse(const Duration(seconds: 30));
    });
    final r = results();
    expect(r.map((p) => p['code']), containsAllInOrder(['202', '200']));
    final pub = XprsCrypto.publicKeyXOnly(DeviceIdentity.instance.scalar!);
    for (final p in r) {
      expect(p['f'], x3);
      expect(xprsVerify(p, pub), XprsSigState.verified);
    }
    // The page itself is the originals, untouched.
    expect(aired.where((e) => e.$2.startsWith('t:info f:X1AAA')),
        hasLength(3));
  });

  test('an ask to the person is still served, as the person', () {
    fakeAsync((async) {
      ask('t:command f:X1BBB d:X1SELF ts:2026-08-13_12:00:00 cmd:history '
          'until:2026-08-13_11:00:00');
      async.elapse(const Duration(seconds: 30));
    });
    final r = results();
    expect(r, isNotEmpty);
    expect(r.every((p) => p['f'] == 'X1SELF'), isTrue);
  });

  test('the person asking its own X3 is never metered', () {
    // Past the stranger budget many times over.
    for (var i = 0; i < 10; i++) {
      ask('t:command f:X1SELF d:$x3 ts:2026-08-13_12:00:0$i cmd:history '
          'since:2027-01-01_00:00:00');
    }
    expect(results().where((p) => p['code'] == '429'), isEmpty);
  });

  test("the X3's policy answer says it serves the archive", () async {
    ask('t:request f:X1BBB d:$x3 ts:2026-08-13_12:00:00 q:policy');
    await Future<void>.delayed(Duration.zero);
    final pol = aired.map((e) => _p(e.$2)).where((p) => p['s'] == 'policy');
    expect(pol, hasLength(1));
    expect(pol.single['f'], x3);
    expect(pol.single['serve'], contains('archive'));
  });

  test('another command to the X3 still gets a signed 404', () async {
    ask('t:command f:X1BBB d:$x3 ts:2026-08-13_12:00:00 cmd:reboot');
    await Future<void>.delayed(Duration.zero);
    final r = results();
    expect(r.single['code'], '404');
    expect(r.single['f'], x3);
  });

  test('a declaration naming the X3 as holder is ours, and visitors are '
      'offered the X3', () {
    final d = BigInt.parse('abcdef0123456789abcdef0123456789', radix: 16);
    a.keyResolver = (_) => XprsCrypto.publicKeyXOnly(d);
    final named = a.recordMailboxDecl(xprsSign(
        _p('t:mailbox f:X1CCC ts:2026-08-13_12:00:00 hold:$x3 '
            'until:2026-12-13_12:00:00'),
        d));
    expect(named, isTrue);
    expect(a.archiverName, x3);
  });
}
