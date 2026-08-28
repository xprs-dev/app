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
import 'package:xprs/services/xprs/xprs_ingest.dart';
import 'package:xprs/services/xprs/xprs_packet.dart';

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

  // ── The two halves of the `via:` gate (36.9.4) ─────────────────────────
  //
  // They used to share one guard, and the cost was that a station could never
  // see past its own neighbours. The distinction is not a nicety:
  //
  //   noteDirect  is about US. Only an unrelayed packet is evidence that we
  //               can hear its author, so the gate is right there.
  //   hears:      is about the OBSERVER, and 9.1 computes `sig:` with `via:`
  //               removed -- a relay cannot alter what was signed, so a
  //               relayed observation carries exactly the claim its author
  //               made. 36.9.4 asks for "a verified observation whose `link:`
  //               names a short-range bearer" and says nothing about how it
  //               arrived.
  //
  // On the bench this was the difference between knowing "X3GSLC hears
  // X1VCVM" and never knowing "X1VCVM hears X3GSLC" -- one direction of an
  // asymmetric pair (10.6.5), and with it every route toward the phone.
  test('a relayed observation still feeds hears:, but not direct', () {
    final p = XprsPacket.parse(
        't:observation f:X1VCVM link:ble peers:2 hears:X3GSLC,X3ARK '
        'via:X3GSLC ts:2026-08-27_20:32:39 m:');
    XprsIngest.heard(p!, bearer: 'lan', selfCallsign: 'X16JK8');

    // It REACHED the intake. Unsigned here, so 36.9.4's wall turns it away —
    // but being turned away by the wall and never arriving are different
    // things, and only the counter can tell them apart.
    expect(g.refusedUnsigned, 1,
        reason: 'a relayed observation must reach the hears: intake');

    // And the other half still holds: a packet that came through somebody
    // else is not evidence that WE heard its author.
    expect(g.whereIs('X1VCVM'), isEmpty,
        reason: 'a relayed packet must not count as our own direct hearing');
  });

  test('an unrelayed observation feeds both', () {
    final p = XprsPacket.parse(
        't:observation f:X1VCVM link:ble peers:1 hears:X3GSLC '
        'ts:2026-08-27_20:32:39 m:');
    XprsIngest.heard(p!, bearer: 'ble', selfCallsign: 'X16JK8');
    expect(g.refusedUnsigned, 1);
    final w = g.whereIs('X1VCVM');
    expect(w, hasLength(1));
    expect(w.first.gateway, 'X16JK8', reason: 'we are the witness');
  });

  test('edges() reads the same rows as a graph', () {
    g.noteDirect('X1AAAA', 'X3SELF', bearer: 'ble', nowMs: t0);
    final e = g.edges(selfCallsign: 'X3SELF', nowMs: t0);
    expect(e, hasLength(1));
    expect(e.first.observer, 'X3SELF');
    expect(e.first.heard, 'X1AAAA');
    expect(e.first.bearer, 'ble');
    expect(e.first.direct, isTrue);
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
