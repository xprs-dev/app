/*
 * XprsNames — Search's question, who is there by name: the archive's names,
 * sorted into people, stations and groups, our own callsign left out, and a
 * screen's keystrokes turned into at most one archiver poke a minute.
 */
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/ecc/curves/secp256k1.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xprs/services/preferences_service.dart';
import 'package:xprs/services/xprs/xprs_archive.dart';
import 'package:xprs/services/xprs/xprs_ingest.dart';
import 'package:xprs/services/xprs/xprs_packet.dart';
import 'package:xprs/services/xprs/xprs_sig.dart';
import 'package:xprs_core/src/services/xprs/xprs_names.dart';

Uint8List _pubOf(BigInt d) {
  final q = (ECCurve_secp256k1().G * d)!;
  final xHex = q.x!.toBigInteger()!.toRadixString(16).padLeft(64, '0');
  return Uint8List.fromList([
    for (var i = 0; i < 64; i += 2)
      int.parse(xHex.substring(i, i + 2), radix: 16)
  ]);
}

void main() {
  late Directory tmp;
  final keys = {
    'X5BOOK': BigInt.from(1111111),
    'X1ANA': BigInt.from(2222222),
    'X3MAST': BigInt.from(3333333),
    'X1SELF': BigInt.from(4444444),
  };

  setUp(() async {
    SharedPreferences.setMockInitialValues({'flutter.xprs.public': true});
    await PreferencesService.instance();
    XprsIngest.reloadPolicy();
    tmp = Directory.systemTemp.createTempSync('xprsnames');
    final a = XprsArchive.instance
      ..selfCallsign = 'X1SELF'
      ..keyResolver = ((c) => keys[c] == null ? null : _pubOf(keys[c]!))
      ..maxBytes = 500 * 1024 * 1024
      ..maxAgeDays = 365
      ..init('${tmp.path}/a.zx');
    var min = 0;
    for (final e in {
      'X5BOOK': 'nick:Book_club',
      'X1ANA': 'nick:Ana',
      'X3MAST': 'nick:Hill-mast',
      'X1SELF': 'nick:Me',
    }.entries) {
      final p = XprsPacket.parse(
          't:identity f:${e.key} ts:2026-08-13_10:0${min++}:00 ${e.value}')!;
      a.admit(xprsSign(p, keys[e.key]!), bearer: 'rns', nowMs: 1000);
    }
    a.flush(nowMs: 2000);
    XprsNames.debugReset();
  });

  tearDown(() {
    XprsArchive.instance.close();
    tmp.deleteSync(recursive: true);
  });

  test('people, stations and groups, newest first, without ourselves', () {
    final rows = XprsNames.find(self: 'X1SELF');
    expect([for (final r in rows) '${r['call']}:${r['kind']}'],
        ['X3MAST:station', 'X1ANA:user', 'X5BOOK:group']);
    expect(rows.last['nick'], 'Book club',
        reason: "a group's `_` is a space on screen");
  });

  test('a kind narrows it', () {
    expect(XprsNames.find(kind: 'group').map((r) => r['call']), ['X5BOOK']);
    expect(XprsNames.find(kind: 'station').map((r) => r['call']), ['X3MAST']);
    expect(XprsNames.find(kind: 'user', self: 'X1SELF').map((r) => r['call']),
        ['X1ANA']);
  });

  test('a search box pokes the archivers at most once a minute', () {
    var pokes = 0;
    var now = 1000000;
    XprsNames.poke = () => pokes++;
    XprsNames.nowMs = () => now;
    XprsNames.find(query: 'b', ask: true);
    XprsNames.find(query: 'bo', ask: true);
    XprsNames.find(query: 'boo', ask: true);
    expect(pokes, 1);
    now += XprsNames.askEvery.inMilliseconds;
    XprsNames.find(query: 'book', ask: true);
    expect(pokes, 2);
    XprsNames.find(query: 'book');
    expect(pokes, 2, reason: 'reading without ask asks nobody');
  });
}
