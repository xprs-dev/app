/*
 * Gossip (docs/XPRS.md 36.9.4): the layered whereabouts table, its validity
 * walls, and the consumers that route by it. The DoS probes of the section
 * are here as tests: unsigned feeds nothing, one signer stops at its quota,
 * an internet-borne claim never writes the visit history, the rings hold
 * their caps.
 */
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart';
import 'package:xprs/services/xprs/xprs_gossip.dart';

void main() {
  late Directory tmp;
  final g = XprsGossip.instance;
  // A realistic clock: the per-signer meter reads ms-since-epoch, and a
  // test clock near zero looks like the epoch itself flooding.
  const t0 = 1700000000000;

  setUpAll(() {
    open.overrideFor(
        OperatingSystem.linux, () => DynamicLibrary.open('libsqlite3.so.0'));
    tmp = Directory.systemTemp.createTempSync('xprsgossip');
    g.init('${tmp.path}/gossip.sqlite3');
  });

  setUp(g.debugReset);
  tearDownAll(() {
    g.close();
    tmp.deleteSync(recursive: true);
  });

  test('own direct hearing feeds both layers on a radio bearer', () {
    g.noteDirect('X1AAAA', 'X3SELF', bearer: 'ble', nowMs: t0);
    final w = g.whereIs('X1AAAA');
    expect(w, hasLength(1));
    expect(w.first.gateway, 'X3SELF');
    expect(g.statusJson()['visits'], 1);
    expect(g.statusJson()['live'], 1);
  });

  test('an internet-borne claim never writes the visit history', () {
    // Even VERIFIED, an rns-link claim is L3 only (36.9.4: radio truth).
    g.noteHears('X3GATE', ['X1AAAA'],
        link: 'rns', verified: true, nowMs: t0);
    expect(g.statusJson()['live'], 1, reason: 'sighting recorded');
    expect(g.statusJson()['visits'], 0,
        reason: 'the durable layer takes radio truth only');
  });

  test('unsigned observations feed nothing', () {
    g.noteHears('X3GATE', ['X1AAAA'],
        link: 'lora', verified: false, nowMs: t0);
    expect(g.whereIs('X1AAAA'), isEmpty);
    expect(g.refusedUnsigned, 1);
  });

  test('one signer stops at its quota', () {
    g.noteHears('X3GATE', ['X1AAAA'],
        link: 'lora', verified: true, nowMs: t0);
    // The flood: 50 more claims inside the metering interval.
    for (var i = 0; i < 50; i++) {
      g.noteHears('X3GATE', ['X1B$i'],
          link: 'lora', verified: true, nowMs: t0 + 1000 + i);
    }
    expect(g.refusedQuota, 50);
    expect(g.whereIs('X1B0'), isEmpty, reason: 'the flood bought nothing');
    // The next period, the same signer speaks again.
    g.noteHears('X3GATE', ['X1CCCC'],
        link: 'lora', verified: true, nowMs: t0 + 40000);
    expect(g.whereIs('X1CCCC'), hasLength(1));
  });

  test('the live layer keeps at most G gateways, freshest win', () {
    for (var i = 0; i < 12; i++) {
      g.noteDirect('X1AAAA', 'X3GW$i', bearer: 'lan', nowMs: t0 + i);
    }
    final w = g.whereIs('X1AAAA', max: 20);
    // G live + up to the same gateways from visits (deduped), so count the
    // DISTINCT live rows via status.
    expect(g.statusJson()['live'], XprsGossip.liveCapG);
    expect(w.first.gateway, 'X3GW11', reason: 'freshest first');
  });

  test('the visit ring holds K distinct archivers and evicts the oldest', () {
    for (var i = 0; i < XprsGossip.visitRingK + 5; i++) {
      g.noteDirect('X1AAAA', 'X3V$i', bearer: 'espnow', nowMs: t0 + i);
    }
    expect(g.statusJson()['visits'], XprsGossip.visitRingK);
    // The oldest five are gone; the newest survives.
    final gateways = [
      for (final s in g.whereIs('X1AAAA', max: 200)) s.gateway
    ];
    expect(gateways, contains('X3V${XprsGossip.visitRingK + 4}'));
    expect(gateways, isNot(contains('X3V0')));
  });

  test('tryCandidates never names the asker itself', () {
    g.noteDirect('X1AAAA', 'X3SELF', bearer: 'ble', nowMs: t0);
    g.noteDirect('X1AAAA', 'X3OTHER', bearer: 'lan', nowMs: t0 + 1000);
    final t = g.tryCandidates('X1AAAA', selfBase: 'X3SELF');
    expect(t, ['X3OTHER']);
  });
}
