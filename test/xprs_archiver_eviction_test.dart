/*
 * A large archiver hitting its disk quota evicts by CLASS first, age second
 * (XPRS.md §12.11): the spool (ordinary heard traffic) goes before custody
 * mail (a `d:` for a station that did not name us) before declared mail (a
 * `d:` for a callsign whose `t:mailbox hold:` names us). In-process, a real
 * XprsArchive filled past its byte cap.
 *
 * The discriminating move: the DECLARED mail is the OLDEST thing in the store
 * and the spool is the NEWEST. An age-only eviction (what the code did before)
 * would delete the declared mail first; §12.11 keeps it and drops the spool.
 * This is the regression test for that gap.
 */
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart';
import 'package:xprs/services/xprs/xprs_archive.dart';
import 'package:xprs/services/xprs/xprs_packet.dart';

import 'support/xprs_sim.dart';

XprsPacket _p(String w) => XprsPacket.parse(w)!;

void main() {
  late Directory tmp;
  late XprsArchive a;
  late SimKeys keys;

  setUpAll(() {
    open.overrideFor(
        OperatingSystem.linux, () => DynamicLibrary.open('libsqlite3.so.0'));
  });

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('xprsevict');
    keys = SimKeys();
    a = XprsArchive.instance;
    a
      ..selfCallsign = 'X3ARC'
      ..keyResolver = keys.resolve
      ..maxBytes = 1 << 30 // no cap while we load
      ..maxAgeDays = 1000000 // no age prune interfering
      ..init('${tmp.path}/archive.sqlite3');
  });

  tearDown(() {
    a.close();
    tmp.deleteSync(recursive: true);
  });

  int classCount(String kind) {
    switch (kind) {
      case 'spool':
        return a.countOf(types: ['info']);
      case 'declared':
        return a
            .query(sinceMs: 0, untilMs: 1 << 62, only: 'X1RECIP', types: ['message'])
            .length;
      case 'custody':
        return a
            .query(sinceMs: 0, untilMs: 1 << 62, only: 'X1NOONE', types: ['message'])
            .length;
    }
    return 0;
  }

  test('§12.11: the spool is evicted before custody mail before declared mail',
      () {
    // X1RECIP declares THIS archiver as its mailbox → its inbound mail is
    // class 3 (declared), the last thing an archiver may drop.
    final decl = keys.sign('X1RECIP',
        't:mailbox f:X1RECIP ts:2026-01-01_00:00:00 hold:X3ARC');
    expect(a.recordMailboxDecl(_p(decl)), isTrue);

    // Declared mail — the OLDEST rows in the store.
    for (var i = 0; i < 10; i++) {
      a.admit(
          _p('t:message f:X1SND d:X1RECIP ts:2026-01-02_00:00:00 m:declared $i'),
          bearer: 'rns', nowMs: 1000 + i);
    }
    // Custody mail — a d: for a station that did NOT name us. Middle age.
    for (var i = 0; i < 10; i++) {
      a.admit(
          _p('t:message f:X1SND d:X1NOONE ts:2026-01-03_00:00:00 m:custody $i'),
          bearer: 'rns', nowMs: 2000 + i);
    }
    // Spool — ordinary heard traffic, no d:. The NEWEST, and the bulk of it.
    for (var i = 0; i < 600; i++) {
      a.admit(_p('t:info f:X1SPAM$i ts:2026-01-04_00:00:00 m:chatter number $i'),
          bearer: 'ble', nowMs: 3000 + i);
    }
    a.flush(nowMs: 5000000);

    expect(classCount('declared'), 10);
    expect(classCount('custody'), 10);
    expect(classCount('spool'), 600);

    // Set the cap just under the current size, so the archiver is only
    // moderately over quota (the realistic steady state) and the eviction is a
    // small slice — which must land entirely in the spool.
    final bytes = a.statusJson()['bytes'] as int;
    a.maxBytes = bytes - 1;
    for (var i = 0; i < 30; i++) {
      a.flush(nowMs: 5000000); // the cap fires on a later flush
    }

    final spool = classCount('spool');
    final custody = classCount('custody');
    final declared = classCount('declared');
    print('After eviction under quota: spool $spool/600, custody $custody/10, '
        'declared $declared/10.');

    // The declared mail (oldest!) is untouched; custody untouched; the spool
    // (newest, bulkiest) took the whole eviction.
    expect(declared, 10, reason: '§12.11: declared mail is the last dropped');
    expect(custody, 10, reason: '§12.11: custody outranks the spool');
    expect(spool, lessThan(600), reason: 'the spool was evicted');
    expect(spool, greaterThan(0),
        reason: 'only a slice went — the store was only moderately over quota');
    print('§12.11  ✓  spool evicted, custody and declared mail kept — class '
        'beats age (declared mail was the OLDEST in the store).');
  });
}
