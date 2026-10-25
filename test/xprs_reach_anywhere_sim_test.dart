/*
 * Reaching a callsign from anywhere (XPRS.md 12.12), on the bench.
 *
 * The APRS-IS-like loop with no server in it: A is a BLE-only pocket
 * station. B is a phone that shares a radio with A and has the internet. X
 * is an always-on archiver on the internet. C, anywhere, writes to A.
 *
 *   1. A beacons; B hears it.                            (15.6.3)
 *   2. B tells X "A is at my ear, on ble".               (12.1)
 *   3. C hands its message to X.                         (12.7)
 *   4. X looks A up in its gossip and forwards to B,
 *      as custody, via: growing.                         (12.8.1)
 *   5. B holds it and hands it over when it hears A.     (12.8.1)
 *   6. A's receipt walks back and releases B and X.      (9.7.1, 12.8.3)
 *
 * The bench runs the real funnel, store, gossip, forwarder, mailbox and
 * receipts (test/support/mail_relay_sim.dart); only the air is virtual.
 */
import 'dart:ffi';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/open.dart';
import 'package:xprs/services/mesh/mesh_store.dart';
import 'package:xprs/services/preferences_service.dart';
import 'package:xprs/services/xprs/xprs_archive.dart';
import 'package:xprs/services/xprs/xprs_archive_policy.dart';
import 'package:xprs/services/xprs/xprs_fetch.dart';
import 'package:xprs/services/xprs/xprs_history_server.dart';
import 'package:xprs/services/xprs/xprs_ingest.dart';
import 'package:xprs/services/xprs/xprs_forwarder.dart';
import 'package:xprs/services/xprs/xprs_gossip.dart';
import 'package:xprs/services/xprs/xprs_id.dart';
import 'package:xprs/services/xprs/xprs_mailbox.dart';
import 'package:xprs/services/xprs/xprs_outbox.dart';
import 'package:xprs/services/xprs/xprs_packet.dart';

import 'support/mail_relay_sim.dart';

const _ts = '2026-10-25_10:00:00';

void main() {
  setUpAll(() {
    open.overrideFor(
        OperatingSystem.linux, () => DynamicLibrary.open('libsqlite3.so.0'));
  });

  late MailRelaySim sim;
  late SimStation a, b, b2, c, x;

  setUp(() {
    XprsMailboxCounters.debugReset();
    sim = MailRelaySim.build(['X1AAAA', 'X1BBBB', 'X1BBB2', 'X1CCCC', 'X3ARCH']);
    a = sim['X1AAAA']..internet = false; // the pocket, Bluetooth only
    b = sim['X1BBBB']..archivers = ['X3ARCH'];
    b2 = sim['X1BBB2']..archivers = ['X3ARCH'];
    c = sim['X1CCCC']..archivers = ['X3ARCH'];
    x = sim['X3ARCH'];
    sim.air.link(a.call, b.call);
  });

  tearDown(() => sim.dispose());

  /// Steps 1 and 2: A beacons, B hears it and tells X.
  Future<void> bHearsA(SimStation gw) async {
    sim.beacon(a);
    await sim.as(gw, () async {
      sim.drain(gw);
      expect(XprsGossip.instance.whereIs(a.call).map((s) => s.gateway),
          contains(gw.call),
          reason: 'our own radio is its own witness');
      expect(sim.report(gw, heard: [a.call]), 1);
    });
    await sim.as(x, () async {
      sim.drain(x);
      final where = XprsGossip.instance.whereIs(a.call);
      expect(where.map((s) => s.gateway), contains(gw.call),
          reason: 'X learned where A is from ${gw.call}\'s signed claim');
      expect(where.first.bearer, 'ble');
    });
  }

  /// Step 3: C writes to A; the copy lands with X.
  Future<String> cWritesToA(String text) async {
    late String wire;
    await sim.as(c, () async {
      wire = await sim.send(c, 't:message f:X1CCCC d:X1AAAA ts:$_ts m:$text');
      // The direct lane has nowhere to go (A is not on the internet), so
      // the deposit is what carries it.
      await XprsMailbox.instance.depositIfUnanswered(wire);
    });
    expect(XprsMailboxCounters.deposited, greaterThanOrEqualTo(1));
    return wire;
  }

  test('THE LOOP: a message from anywhere reaches a BLE-only station through '
      'the gateway that reported hearing it', () async {
    await bHearsA(b);
    final wire = await cWritesToA('hello from the other side');

    // Step 4: X holds it, consults gossip, forwards to B as custody.
    await sim.as(x, () async {
      sim.drain(x);
      expect(MeshStore.instance.countPending(), 1, reason: 'X holds it');
      final went = await sim.forwardParked(x);
      expect(went, [b.call]);
    });

    // B receives the forwarded copy over the internet: not for B, so B
    // parks it -- and does NOT forward it further: B hears A itself.
    await sim.as(b, () async {
      sim.drain(b);
      expect(MeshStore.instance.heldTargets(), contains(a.call));
      final held = XprsPacket.parse(
          MeshStore.instance.heldWiresFor(a.call).single)!;
      expect(held['via'], x.call, reason: 'custody: X signed itself in');
      expect(held['f'], c.call, reason: 'the author is untouched');
      // B's own forwarder would send it on only if B could not deliver;
      // B shares a radio with A, so it keeps it for release-on-hearing.
      expect(await sim.forwardParked(b), isEmpty);
      expect(XprsForwarder.instance.selfDelivers, 1);
      // Step 5: A beacons again; B releases over the radio.
      expect(sim.releaseOnRadio(b, a), 1);
    });

    // A hears it on Bluetooth: delivered to the person, receipt on the air.
    await sim.as(a, () async {
      sim.drain(a);
      expect(a.delivered, hasLength(1));
      expect(a.delivered.single['m'], 'hello from the other side');
      expect(a.receiptsSent, hasLength(1));
    });

    // Step 6: B hears the receipt. Its copy is released; the receipt is
    // mail for C (12.8.3 step 6), which B parks like any mail heard on a
    // radio -- and, having a path to C, delivers itself rather than
    // forwarding. B's bridge also offers what it heard to its archiver.
    await sim.as(b, () async {
      sim.drain(b);
      expect(MeshStore.instance.releasableFor(a.call), isEmpty,
          reason: 'the receipt released B\'s copy');
      expect(MeshStore.instance.heldTargets(), contains(c.call),
          reason: 'a receipt heard on the radio is mail, and is carried');
      expect(await sim.forwardParked(b), isEmpty,
          reason: 'B can reach C: it delivers, it does not forward');
      expect(await XprsMailbox.instance.sweepHeld(), 1);
    });

    // X overhears the receipt through B's bridge: its copy is released
    // (9.7.1: a verified receipt releases every holder that hears it).
    await sim.as(x, () async {
      sim.drain(x);
      expect(MeshStore.instance.releasableFor(a.call), isEmpty,
          reason: 'the one receipt releases every holder');
    });

    // C, who was never awake at the same time as A, learns it arrived.
    await sim.as(c, () async {
      final id = xprsIdentifier(XprsPacket.parse(wire)!);
      XprsOutbox.instance.noteSent(id, a.call);
      sim.drain(c);
      expect(c.delivered, isEmpty, reason: 'a receipt is not a message');
      expect(XprsOutbox.instance.stateOf(id), 'delivered');
    });
  });

  test('two gateways report A: both get a copy, one receipt clears both',
      () async {
    sim.air.link(a.call, b2.call);
    await bHearsA(b);
    await bHearsA(b2);
    await cWritesToA('to whoever meets you first');

    await sim.as(x, () async {
      sim.drain(x);
      final went = await sim.forwardParked(x);
      expect(went.toSet(), {b.call, b2.call});
    });
    for (final gw in [b, b2]) {
      await sim.as(gw, () async {
        sim.drain(gw);
        expect(MeshStore.instance.heldWiresFor(a.call), hasLength(1));
      });
    }
    // B meets A first.
    await sim.as(b, () async {
      sim.drain(b);
      expect(sim.releaseOnRadio(b, a), 1);
    });
    await sim.as(a, () async {
      sim.drain(a);
      expect(a.delivered, hasLength(1));
    });
    // Both gateways share the radio with A and both hear the receipt.
    for (final gw in [b, b2]) {
      await sim.as(gw, () async {
        sim.drain(gw);
        expect(MeshStore.instance.releasableFor(a.call), isEmpty,
            reason: '${gw.call} released on overhearing the receipt (9.7.1)');
      });
    }
  });

  test('mail deposited before anybody reported A waits, then moves the '
      'moment a report arrives', () async {
    await cWritesToA('early bird');
    await sim.as(x, () async {
      sim.drain(x);
      // Nobody has reported A: nothing to forward to (X IS the named
      // archiver, so the miss path has nowhere else either).
      expect(await sim.forwardParked(x), isEmpty);
      expect(MeshStore.instance.countPending(), 1, reason: 'held, not lost');
    });

    // Now B meets A and tells X.
    await bHearsA(b);
    await sim.as(x, () async {
      // The drain inside bHearsA fed gossip, and gossip fired the sighting
      // hook for a NEW (A, B) pair: the device re-runs the forwarder.
      expect(sim.forwardRetries, contains(a.call));
      expect(await sim.retryHeld(x), 1);
    });
    await sim.as(b, () async {
      sim.drain(b);
      expect(MeshStore.instance.heldWiresFor(a.call), hasLength(1));
    });
  });

  test('a repeated report is not a new sighting, and costs no second copy',
      () async {
    await bHearsA(b);
    await cWritesToA('once');
    await sim.as(x, () async {
      sim.drain(x);
      expect(await sim.forwardParked(x), [b.call]);
      sim.forwardRetries.clear();
    });
    // B keeps reporting A every few minutes.
    await sim.as(b, () async => sim.report(b, heard: [a.call]));
    await sim.as(x, () async {
      sim.drain(x);
      expect(sim.forwardRetries, isEmpty,
          reason: 'the pair was already known: no hook, no retry');
    });
  });

  // ── The other direction: C asks for what A said while C was away ───────
  //
  // A's words reached the archiver the only way a BLE-only station's words
  // can: B heard them and its bridge offered them to its archiver (12.12.2).
  // C never learns which archiver held them; the core asks the ones C chose
  // in turn (12.6), and what comes back is kept because C asked for it.
  test('C fetches A\'s archived messages without knowing where they are',
      () async {
    final y = SimStation('X3EMPT', '${sim.root.path}/X3EMPT');
    sim.stations[y.call] = y;
    c.archivers = [y.call, x.call]; // Y first, and Y has nothing
    const archiverPolicy =
        XprsArchivePolicy(public: true, alwaysOn: true, keepChatter: true);
    SharedPreferences.setMockInitialValues({'flutter.xprs.public': true});
    await PreferencesService.instance();

    // A talks to the room; B hears it and its bridge offers it to X.
    await sim.as(a, () async {
      sim.air.radio(a.call,
          sim.sign(a, 't:message f:X1AAAA ts:2026-10-20_09:00:00 m:anyone on the hill?'));
      sim.air.radio(a.call,
          sim.sign(a, 't:message f:X1AAAA ts:2026-10-20_09:05:00 m:view is great'));
    });
    await sim.as(b, () async => sim.drain(b));
    final before = XprsIngest.policy;
    XprsIngest.policy = archiverPolicy;
    try {
      await sim.as(x, () async {
        sim.drain(x);
        XprsArchive.instance.flush();
        expect(XprsArchive.instance.query(from: a.call), hasLength(2),
            reason: 'a public archiver keeps a stranger\'s publication');
      });
    } finally {
      XprsIngest.policy = before;
    }

    // C, on a pocket phone with the default policy, opens A's conversation:
    // the wapp reads the store, the core fetches.
    final fetch = XprsFetch.instance;
    fetch.debugReset();
    fetch
      ..autoTick = false
      ..archivers = (() => c.archivers)
      ..selfCallsign = (() => c.call)
      ..inEarshot = ((_) => false)
      ..archiverBusy = ((_) => false)
      ..send = ((w) async {
        final d = XprsPacket.parse(w)!['d']!;
        sim.air.sendTo(d, sim.sign(c, w));
      });
    XprsIngest.onResult = fetch.onResult;
    XprsIngest.onHeardAny = fetch.noteHeard;
    XprsIngest.askedFor = fetch.askedFor;
    try {
      await sim.as(c, () async {
        expect(XprsArchive.instance.query(from: a.call), isEmpty);
        expect(fetch.requestStation(a.call, reason: 'chat opened'), isTrue);
      });
      // Y serves the ask: nothing held, 404.
      Future<void> serve(SimStation arch) => sim.as(arch, () async {
            final asks = [...arch.inbox];
            arch.inbox.clear();
            XprsHistoryServer.instance.signingKey = () => arch.scalar;
            for (final w in asks) {
              final cmd = XprsPacket.parse(w)!;
              for (final out in XprsHistoryServer.instance
                  .serveInline(cmd, selfBase: arch.call)) {
                sim.air.sendTo(c.call, out);
              }
            }
          });
      await serve(y);
      await sim.as(c, () async {
        sim.drain(c);
        expect(fetch.asks, 2, reason: 'Y\'s 404 moved the fetch on to X');
        expect(x.inbox, hasLength(1));
      });
      // The 404 moved the fetch on to X, which has them.
      await serve(x);
      await sim.as(c, () async {
        sim.drain(c);
        XprsArchive.instance.flush();
        expect(fetch.json['open'], isEmpty, reason: 'answered');
        expect(fetch.rows, 2);
        final got = XprsArchive.instance.query(from: a.call);
        expect(got.map((r) => XprsPacket.parse(r['wire'] as String)!['m']),
            containsAll(['anyone on the hill?', 'view is great']),
            reason: 'what C asked for, C keeps -- on a pocket phone');
        expect(c.delivered, isEmpty,
            reason: 'a replay of public words is history, not new mail');
      });
    } finally {
      XprsIngest.onResult = null;
      XprsIngest.onHeardAny = null;
      XprsIngest.askedFor = null;
      fetch.debugReset();
    }
  });

  test('the archiver that hears A itself delivers, and forwards nothing',
      () async {
    // A shares a radio with X directly (X has a radio too).
    sim.air.link(a.call, x.call);
    sim.beacon(a);
    await cWritesToA('next door');
    await sim.as(x, () async {
      sim.drain(x);
      // X's own hearing of A is in its gossip, under X's own name...
      expect(XprsGossip.instance.whereIs(a.call).map((s) => s.gateway),
          contains(x.call));
      // ...and a gateway is never itself: nothing to forward to.
      expect(await sim.forwardParked(x), isEmpty);
      expect(sim.releaseOnRadio(x, a), 1, reason: 'X delivers it itself');
    });
    await sim.as(a, () async {
      sim.drain(a);
      expect(a.delivered, hasLength(1));
    });
  });
}
