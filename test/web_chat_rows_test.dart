// What the share server's history may show a visitor, against the real archive:
// public rows for everybody, and mail only for the callsign the visitor proved.
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/open.dart';
import 'package:xprs/services/preferences_service.dart';
import 'package:xprs/services/web_chat_api.dart';
import 'package:xprs/services/xprs/xprs_archive.dart';
import 'package:xprs/services/xprs/xprs_ingest.dart';
import 'package:xprs/services/xprs/xprs_packet.dart';

void main() {
  late Directory tmp;
  final a = XprsArchive.instance;

  setUpAll(() {
    open.overrideFor(
        OperatingSystem.linux, () => DynamicLibrary.open('libsqlite3.so.0'));
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({'flutter.xprs.public': true});
    await PreferencesService.instance();
    XprsIngest.reloadPolicy();
    tmp = Directory.systemTemp.createTempSync('webchatrows');
    a
      ..selfCallsign = 'X1SELF'
      ..keyResolver = null
      ..maxBytes = 500 * 1024 * 1024
      ..maxAgeDays = 365
      ..init('${tmp.path}/xprs_archive.sqlite3');
    void put(String w) {
      a.admit(XprsPacket.parse(w)!, bearer: 'lan', nowMs: 1000);
    }

    put('t:message f:X1AAA ts:2026-10-15_10:00:00 scope:local m:public one');
    put('t:message f:X1AAA d:X1VIS ts:2026-10-15_10:01:00 m:to the visitor');
    put('t:message f:X1VIS d:X1AAA ts:2026-10-15_10:02:00 m:from the visitor');
    put('t:message f:X1AAA d:X1OWNR ts:2026-10-15_10:03:00 m:the owner private');
    put('t:message f:X1AAA d:X5A3F2 ts:2026-10-15_10:04:00 m:a closed group');
    put('t:message f:X1VIS ts:2026-10-15_10:05:00 scope:local m:visitor public');
    a.flush(nowMs: 2000);
  });

  tearDown(() {
    a.close();
    tmp.deleteSync(recursive: true);
  });

  List<String> says(List<Map<String, dynamic>> rows) => [
        for (final r in rows)
          (r['wire'] as String).split(' m:').last,
      ];

  test('a visitor with no session sees public rows and nothing addressed', () {
    final rows = archivePublicRows(types: const ['message'], limit: 50);
    expect(says(rows).toSet(), {'public one', 'visitor public'});
  });

  test('a proven callsign adds its own mail, both ways, and nobody elses', () {
    final rows = archivePublicRows(
        types: const ['message'], visitor: 'X1VIS', limit: 50);
    expect(says(rows).toSet(), {
      'public one',
      'visitor public',
      'to the visitor',
      'from the visitor',
    });
    expect(says(rows), isNot(contains('the owner private')));
    expect(says(rows), isNot(contains('a closed group')));
  });

  test('newest first, deduplicated, and the limit holds', () {
    final rows = archivePublicRows(
        types: const ['message'], visitor: 'X1VIS', limit: 3);
    expect(rows, hasLength(3));
    final ts = [for (final r in rows) r['ts'] as int];
    expect(ts, [...ts]..sort((x, y) => y.compareTo(x)));
    expect({for (final r in rows) r['id']}, hasLength(3));
  });

  test('the count a stranger is told is of public rows only', () {
    expect(a.countOf(types: const ['message'], undirected: true), 2);
    expect(a.countOf(types: const ['message']), 6);
  });
}
