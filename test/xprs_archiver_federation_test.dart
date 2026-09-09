/*
 * Archiver federation, end to end, in one process and no hardware.
 *
 * Three scenarios the operator asked for, each exercised through the CORE the
 * way architecture.md §6 sanctions: a packet enters an archiver through the one
 * receive door (`XprsIngest.heard`), and the archiver's spool, its cmd:history
 * responder and its gossip table are the real singletons. A wapp decides none
 * of this (architecture.md §1): the chat wapp hands the core a message and is
 * called back, so what these tests drive is precisely the surface the wapp
 * cannot reach around.
 *
 *   1) A writes a chat message; the copy reaches its chosen archiver C and C
 *      STORES it (the "so it can store it there" half — the store is the core's
 *      job, XprsArchive). A's outbound push of that copy to C is the
 *      publisher's addressed LXMF copy to each configured archiver
 *      (`XprsPublisher`, xprsNamedArchivers); that hop is a live Reticulum
 *      transport call, bench-validated per the spec §12.12.2 status, not a unit
 *      seam, so here we deliver A's signed wire into C's door exactly as the
 *      transport would and prove C spools it.
 *
 *   2) B asks C for recent packets from A (`cmd:history only:A`) and C replays
 *      the byte-identical originals — the filter that replaces an APRS-IS
 *      subscription (§12.6).
 *
 *   3) C tells D "A deposits at C" so a global user can find A by asking D. The
 *      implemented vehicle is a signed original relayed verbatim (§12.9.1): A's
 *      own `t:mailbox hold:C`, carried on to D with `via:C`. D records it and
 *      can then answer "where is A → C". The asymmetry the operator described —
 *      large archivers synchronise broadly and are leaned on, small ones report
 *      upward and are not pulled hard — is the peer-class floor: an always-on
 *      archiver may be asked every 15 s, an ordinary one no faster than 10 min.
 *      (The bulk XDIR directory FILE of §12.9 and the `m:try` miss-redirect are
 *      specified but not yet implemented; the gossip propagation tested here is
 *      what achieves the same routing today.)
 */
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hex/hex.dart';
import 'package:sqlite3/open.dart';
import 'package:xprs/services/preferences_service.dart';
import 'package:xprs/services/xprs/xprs_archive.dart';
import 'package:xprs/services/xprs/xprs_cadence.dart';
import 'package:xprs/services/xprs/xprs_gossip.dart';
import 'package:xprs/services/xprs/xprs_history_server.dart';
import 'package:xprs/services/xprs/xprs_id.dart';
import 'package:xprs/services/xprs/xprs_ingest.dart';
import 'package:xprs/services/xprs/xprs_packet.dart';
import 'package:xprs/services/xprs/xprs_sig.dart';
import 'package:xprs/util/nostr_crypto.dart';

XprsPacket _p(String wire) => XprsPacket.parse(wire)!;

/// A secp256k1 (nostr) keypair per callsign, and the resolver the core uses to
/// verify what that callsign signed — the same idiom as xprs_publisher_test.
class _Keys {
  final _priv = <String, BigInt>{};
  final _pub = <String, Uint8List>{};

  void ensure(String call) {
    _priv.putIfAbsent(call, () {
      final kp = NostrCrypto.generateKeyPair();
      var d = BigInt.zero;
      for (final b in HEX.decode(kp.privateKeyHex)) {
        d = (d << 8) | BigInt.from(b);
      }
      _pub[call] = Uint8List.fromList(HEX.decode(kp.publicKeyHex));
      return d;
    });
  }

  /// Sign [wire] as [call], the way the author's own station would.
  String sign(String call, String wire) {
    ensure(call);
    return xprsSign(_p(wire), _priv[call]!).encode();
  }

  Uint8List? resolve(String call) => _pub[call.split('-').first.toUpperCase()];
}

void main() {
  late Directory tmp;
  late XprsArchive a;
  late XprsHistoryServer srv;
  late XprsGossip g;
  late _Keys keys;
  late List<(String key, String wire)> aired;

  setUpAll(() {
    open.overrideFor(
        OperatingSystem.linux, () => DynamicLibrary.open('libsqlite3.so.0'));
  });

  setUp(() async {
    // This station keeps other people's traffic, which since XPRS.md 12's
    // tiers is a choice rather than the default.
    SharedPreferences.setMockInitialValues({'flutter.xprs.public': true});
    await PreferencesService.instance();
    XprsIngest.reloadPolicy();

    tmp = Directory.systemTemp.createTempSync('xprsfed');
    keys = _Keys();

    a = XprsArchive.instance;
    a
      ..selfCallsign = 'X3ARC1' // the archiver under test, renamed per scenario
      ..maxBytes = 500 * 1024 * 1024
      ..maxAgeDays = 365
      ..keyResolver = keys.resolve
      ..init('${tmp.path}/xprs_archive.sqlite3');

    g = XprsGossip.instance;
    g.init('${tmp.path}/gossip.sqlite3');
    g.debugReset();

    srv = XprsHistoryServer.instance;
    srv.reset();
    srv.signingKey = () => BigInt.parse('1234567890abcdef1234567890abcdef',
        radix: 16); // the archiver signs its own results/replay control
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
    g.close();
    tmp.deleteSync(recursive: true);
  });

  /// A packet arriving at this archiver through the one receive door, on a
  /// short-range radio bearer (architecture.md "one-receive-door").
  void arrive(String wire, {String bearer = 'ble'}) => XprsIngest.heard(
      _p(wire),
      bearer: bearer,
      selfCallsign: a.selfCallsign,
      rssi: -55);

  /// The originals the archiver replayed (its cmd:history answer), in order.
  List<String> replayed() => [
        for (final e in aired)
          if (!e.$1.startsWith('xprs-hist:c')) e.$2
      ];

  /// The signed control packets (202/200/206/404) the archiver aired.
  List<XprsPacket> control() => [
        for (final e in aired)
          if (e.$1.startsWith('xprs-hist:c')) _p(e.$2)
      ];

  // ── Scenario 1 ──────────────────────────────────────────────────────────
  // A writes a chat message; the copy reaches archiver C, and C stores it.
  test('1) archiver C stores the chat message copy it receives from A', () {
    a.selfCallsign = 'X3ARC1'; // C

    // A's public chat message, exactly as A's station signed and aired it. A
    // #LOCAL post carries no d:, which is what makes it a publication C keeps
    // for anybody (§12.1), and what the publisher pushes to a chosen archiver.
    final msgWire = keys.sign('X1AAA1',
        't:message f:X1AAA1 ts:2026-08-13_10:14:00 m:morning from the ridge');

    arrive(msgWire); // the copy lands at C, through C's receive door
    a.flush(nowMs: 100000);

    // C spooled it: one message record, byte-identical to what A signed.
    expect(a.countOf(types: ['message']), 1,
        reason: 'the archiver keeps the copy it heard (§12.1, serve:archive)');
    final id = xprsIdentifier(_p(msgWire));
    expect(a.wireById(id), msgWire,
        reason: 'stored verbatim — the archiver keeps the packet, not a '
            'description of it (§12.2)');
  });

  // ── Scenario 2 ──────────────────────────────────────────────────────────
  // B queries C for recent packets from A and gets the list back.
  test('2) B asks C cmd:history only:A and C replays A recent packets', () {
    a.selfCallsign = 'X3ARC1'; // C

    // A has been depositing at C: five of A's, and two of someone else's, so
    // only: has something to exclude.
    for (var i = 0; i < 5; i++) {
      arrive(keys.sign('X1AAA1',
          't:message f:X1AAA1 ts:2026-08-13_10:${i.toString().padLeft(2, "0")}'
          ':00 m:from A number $i'));
    }
    for (var i = 0; i < 2; i++) {
      arrive(keys.sign('X1ZZZ9',
          't:message f:X1ZZZ9 ts:2026-08-13_10:3$i:00 m:from Z number $i'));
    }
    a.flush(nowMs: 100000);

    fakeAsync((async) {
      // B's question: everything about A, up to now. until: keeps the command
      // itself out of the window.
      arrive('t:command f:X1BEE2 d:X3ARC1 ts:2026-08-13_12:00:00 '
          'cmd:history only:X1AAA1 until:2026-08-13_11:00:00');
      async.elapse(const Duration(seconds: 30));

      final wires = replayed();
      expect(wires, hasLength(5), reason: 'exactly A five packets');
      expect(wires.every((w) => w.contains('f:X1AAA1')), isTrue,
          reason: 'only: filtered out Z (§12.6)');
      // Newest first, byte-identical originals (§12.2).
      expect(wires.first, contains('m:from A number 4'));
      final codes = [for (final c in control()) c['code']];
      expect(codes.first, '202', reason: 'replay opens with 202');
      expect(codes.last, anyOf('200', '206'), reason: 'and closes the page');
    });
  });

  // ── Scenario 3 ──────────────────────────────────────────────────────────
  // C tells D that A deposits at C; D can then answer "where is A".
  test('3) A whereabouts propagate C→D: D learns A rests at C', () {
    a.selfCallsign = 'X3ARC2'; // D, a different archiver

    // A declared C as the archiver holding its data (§13.12 t:mailbox hold:).
    // C relays that signed declaration on to D verbatim, appending via:C — the
    // signature is computed with via: removed (§9.1), so it still verifies as
    // A's. This is the one thing §12.9.1 lets cross between archivers: a signed
    // original, checked against A's key, not against C honesty.
    final declByA = keys.sign('X1AAA1',
        't:mailbox f:X1AAA1 ts:2026-08-13_10:30:00 hold:X3ARC1');
    final relayedByC = _p(declByA).encode().replaceFirst(
        ' ts:', ' via:X3ARC1 ts:'); // C appends itself to via:
    expect(_p(relayedByC)['via'], 'X3ARC1');

    arrive(relayedByC, bearer: 'rns'); // reaches D over the internet lane

    // D now knows where A data can be found, without ever holding A packets.
    expect(a.holdersFor('X1AAA1'), ['X3ARC1'],
        reason: 'the directory answer: A rests at C (§12.9.4 L1)');
    // And a global user asking D resolves A → C by that same record.
    expect(a.hasActiveDecl('X1AAA1'), isFalse,
        reason: 'the decl names C, not D — D routes, it is not the mailbox');

    // A signed sighting also crosses: C observed A on the air, and that
    // observation, relayed to D, feeds D live layer so D can point at C as the
    // gateway one hop from A (§12.9.1, §12.9.4 L3).
    final sightByC = keys.sign('X3ARC1',
        't:observation f:X3ARC1 link:lora peers:3 hears:X1AAA1 '
        'ts:2026-08-13_10:59:00');
    arrive(sightByC, bearer: 'ble');
    final where = g.whereIs('X1AAA1');
    expect(where, isNotEmpty, reason: 'D can point somewhere for A');
    expect(where.first.gateway, 'X3ARC1',
        reason: 'A was last at C ear — that is where to reach A');
  });

  // The asymmetry the operator described: not every archiver synchronises the
  // whole network. A large ("super", always-on) archiver absorbs a fast caller
  // and is the place global users pull a stream from; an ordinary archiver is
  // never pulled harder than its metered floor, which is why small archivers
  // report UPWARD to an always-on one rather than it crawling all of them.
  test('3b) an always-on archiver may be asked far faster than an ordinary one', () {
    expect(XprsCadence.floorFor(XprsPeerClass.fast, visible: true),
        const Duration(seconds: 15),
        reason: 'an always-on archiver is leaned on: 15 s floor (§12.9.4, §12.10.2)');
    expect(XprsCadence.floorFor(XprsPeerClass.ordinary, visible: true),
        const Duration(minutes: 10),
        reason: 'an ordinary archiver keeps its metered 10 min floor');
    // Nobody awake: even an always-on archiver drops to the quiet floor — a fast tier only
    // exists to feed a screen someone is looking at (performance.md 6.5).
    expect(XprsCadence.floorFor(XprsPeerClass.fast, visible: false),
        const Duration(minutes: 10));
  });
}
