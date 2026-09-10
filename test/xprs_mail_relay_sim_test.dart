/*
 * Two people who are never awake at the same moment, and one archiver.
 *
 * Reported from the field on 2026-09-08: a friend sent a message from another
 * phone, and nothing ever arrived. Both halves of the cause are here as
 * scenarios — the sender stopped existing before the recipient came back, and
 * no always-on station in the middle had been given a copy to deliver.
 *
 * The bench is test/support/mail_relay_sim.dart: the real receive funnel, the
 * real custody store, the real receipts and the real mailbox logic, one
 * station at a time, over an air that drops what is addressed to somebody who
 * is offline.
 */
import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart';
import 'package:xprs/services/mesh/mesh_store.dart';
import 'package:xprs/services/xprs/xprs_archiver_choice.dart';
import 'package:xprs/services/xprs/xprs_id.dart';
import 'package:xprs/services/xprs/xprs_mailbox.dart';
import 'package:xprs/services/xprs/xprs_outbox.dart';
import 'package:xprs/services/xprs/xprs_packet.dart';

import 'support/mail_relay_sim.dart';

const _ts = '2026-09-08_19:00:00';

void main() {
  setUpAll(() {
    open.overrideFor(
        OperatingSystem.linux, () => DynamicLibrary.open('libsqlite3.so.0'));
  });

  late MailRelaySim sim;
  late SimStation a, b, c;

  setUp(() {
    XprsMailboxCounters.debugReset();
    sim = MailRelaySim.build(['X1AAAA', 'X1BBBB', 'X3ARCH']);
    a = sim['X1AAAA'];
    b = sim['X1BBBB'];
    c = sim['X3ARCH'];
  });

  tearDown(() => sim.dispose());

  test('THE REPORTED FAILURE: with nobody in the middle, the message is lost',
      () async {
    // A writes while B is asleep, then puts the phone away. Every station here
    // behaves correctly and the message still dies, because the only copy was
    // on the station that left.
    b.online = false;
    a.archivers = const [];
    await sim.as(a, () async {
      final wire =
          await sim.send(a, 't:message f:X1AAAA d:X1BBBB ts:$_ts m:are you there');
      await XprsMailbox.instance.depositIfUnanswered(wire);
    });
    expect(XprsMailboxCounters.depositNoArchiver, greaterThan(0),
        reason: 'nowhere to leave a copy');

    a.online = false;
    b.online = true;
    await sim.as(b, () async => sim.drain(b));
    expect(b.delivered, isEmpty, reason: 'this is the bug, stated as a test');
  });

  test('with an archiver in the middle, the message arrives after both '
      'have been away', () async {
    a.archivers = [c.call];
    b.online = false;

    // ── A writes. B is asleep, so the direct copy goes nowhere; the deposit
    //    hands one to the archiver A chose (12.7).
    late String wire;
    await sim.as(a, () async {
      wire = await sim.send(
          a, 't:message f:X1AAAA d:X1BBBB ts:$_ts m:meet me at the mast');
      await XprsMailbox.instance.depositIfUnanswered(wire);
    });
    expect(XprsMailboxCounters.deposited, 1);

    // ── The archiver ingests it: not for us, so hold it (12.7).
    await sim.as(c, () async {
      sim.drain(c);
      expect(MeshStore.instance.countPending(), 1,
          reason: 'the archiver is holding it for X1BBBB');
    });

    // ── A goes away entirely. Nothing A does can help from here on.
    a.online = false;
    b.online = true;

    // ── The archiver notices it can reach B now and delivers (12.8.1).
    await sim.as(c, () async {
      final n = await XprsMailbox.instance.sweepHeld();
      expect(n, 1, reason: 'a path to the recipient exists — deliver');
    });

    await sim.as(b, () async => sim.drain(b));
    expect(b.delivered, hasLength(1));
    expect(b.delivered.single['m'], 'meet me at the mast');
  });

  test('the receipt releases the archiver, and waits for the sender who is '
      'still away', () async {
    a.archivers = [c.call];
    b.online = false;

    late String wire;
    await sim.as(a, () async {
      wire = await sim.send(a, 't:message f:X1AAAA d:X1BBBB ts:$_ts m:ping');
      await XprsMailbox.instance.depositIfUnanswered(wire);
      // A declares where its mailbox is, so the far side knows where to send
      // the receipt (13.12). Everyone hears it.
      await XprsMailbox.instance.declare();
    });
    await sim.as(c, () async => sim.drain(c));

    a.online = false;
    b.online = true;
    await sim.as(c, () async => XprsMailbox.instance.sweepHeld());

    // B receives it and answers. The receipt goes to A (who is away) AND to
    // A's declared mailbox, which is the station actually holding a copy.
    await sim.as(b, () async {
      sim.drain(b);
      expect(b.receiptsSent, hasLength(1));
    });
    expect(XprsMailboxCounters.receiptsToHolders, 1,
        reason: 'the holder is told too, or it re-delivers for ever');

    // The archiver hears the receipt: its copy is released, and the receipt
    // itself is mail for a station that is not here, so it holds THAT.
    await sim.as(c, () async {
      sim.drain(c);
      final held = MeshStore.instance.heldTargets();
      expect(held, contains('X1AAAA'),
          reason: 'the receipt is mail for the sleeping sender');
      expect(MeshStore.instance.releasableFor('X1BBBB'), isEmpty,
          reason: 'the delivered message is released (12.7)');
    });

    // A comes back. The archiver hands it the receipt, and A learns its
    // message arrived while it was away.
    a.online = true;
    await sim.as(c, () async => XprsMailbox.instance.sweepHeld());
    await sim.as(a, () async {
      XprsOutbox.instance.noteSent(xprsIdentifier(XprsPacket.parse(wire)!),
          'X1BBBB');
      sim.drain(a);
      expect(XprsOutbox.instance.stateOf(xprsIdentifier(XprsPacket.parse(wire)!)),
          'delivered',
          reason: 'A learns, days later and from an archiver, that it arrived');
    });
  });

  test('one copy per message, however often the ladder re-airs it', () async {
    // The retry ladder re-airs an unacknowledged 1:1 every few seconds, and
    // each re-airing used to arm a fresh deposit — ten copies of one message
    // inside ten seconds on the bench, and two archivers handing the same mail
    // back and forth. A copy is a copy.
    a.archivers = [c.call];
    b.online = false;
    await sim.as(a, () async {
      final wire =
          await sim.send(a, 't:message f:X1AAAA d:X1BBBB ts:$_ts m:say it once');
      expect(await XprsMailbox.instance.depositIfUnanswered(wire), 1);
      expect(await XprsMailbox.instance.depositIfUnanswered(wire), 0,
          reason: 'the second airing leaves no second copy');
      expect(XprsMailboxCounters.deposited, 1);
    });
  });

  test('the core carries any packet, not just chat: a file description and '
      'its ask survive the same way', () async {
    a.archivers = [c.call];
    b.online = false;
    await sim.as(a, () async {
      for (final w in [
        't:file f:X1AAAA d:X1BBBB ts:$_ts r:99aa11 '
            'file:nYxKzGm4vT2pQ8dW5jR7cL0aFbNs9hUe3oXiC6EkM1w.jpg size:3.1MB',
        't:command f:X1AAAA d:X1BBBB ts:$_ts cmd:history since:2026-09-01_00:00:00',
      ]) {
        await XprsMailbox.instance.depositIfUnanswered(await sim.send(a, w));
      }
    });
    await sim.as(c, () async {
      sim.drain(c);
      expect(MeshStore.instance.countPending(), 2,
          reason: 'the chat wapp knows nothing about either of these');
    });
  });

  test('presence is never held: an observation an hour late is a lie',
      () async {
    a.archivers = [c.call];
    b.online = false;
    await sim.as(a, () async {
      await sim.send(a,
          't:observation f:X1AAAA d:X1BBBB ts:$_ts link:lora peers:3 hears:X1BBBB');
      await sim.send(a, 't:message f:X1AAAA d:X1BBBB ts:$_ts scope:local m:in range only');
    });
    await sim.as(c, () async {
      sim.drain(c);
      expect(MeshStore.instance.countPending(), 0);
    });
  });

  test('a holder never re-airs mail addressed to itself', () async {
    // Our own copy sits in the same store the carried copies do, so a sweep
    // that does not check finds mail for US and puts it back on the air,
    // addressed to this station, for every neighbour to hear us relay to
    // nobody. Seen on the bench as a digipeat of our own message.
    a.archivers = [c.call];
    await sim.as(a, () async {
      final wire = await sim.send(a, 't:message f:X1BBBB d:X1AAAA ts:$_ts m:for me');
      MeshStore.instance.offer(
        target: 'X1AAAA',
        sender: 'X1BBBB',
        wire: Uint8List.fromList(utf8.encode(wire)),
        am: 'aa11bb',
        inTransit: true,
      );
      expect(await XprsMailbox.instance.sweepHeld(), 0);
    });
  });

  test('a station with no archiver of its own adopts the one volunteer it '
      'can hear', () {
    final now = DateTime.now().millisecondsSinceEpoch;
    String? adopted;
    final choice = XprsArchiverChoice.instance.reconsider(
      offers: [
        ArchiverOffer(
            callsign: 'X3ARCH', lastHeardMs: now - 60000, bearer: 'rns',
            uptimeS: 90000),
      ],
      selfBase: 'X1AAAA',
      autoEnabled: true,
      configured: const [],
      adoptedNow: null,
      adopt: (c) => adopted = c,
    );
    expect(choice, 'X3ARCH');
    expect(adopted, 'X3ARCH');

    // And it STAYS adopted through a quiet spell — an archiver that changes
    // every hour spreads one conversation over five stations.
    expect(
        XprsArchiverChoice.pick(
          [
            ArchiverOffer(
                callsign: 'X3ARCH',
                lastHeardMs: now - Duration(hours: 7).inMilliseconds,
                bearer: 'rns'),
            ArchiverOffer(
                callsign: 'X3NEWR', lastHeardMs: now, bearer: 'rns'),
          ],
          selfBase: 'X1AAAA',
          nowMs: now,
          current: 'X3ARCH',
        ),
        'X3ARCH');
  });

  test('a station with no neighbours keeps the archiver it has', () {
    // The internet-only case, measured on the bench (X1WATT on 5G,
    // 2026-09-10): offers are built from stations heard ON THE AIR, and a
    // phone with no LAN and no radio in earshot hears nobody — so the list is
    // empty by construction, its archiver aged out of the station table, and
    // the adoption was dropped while that archiver was perfectly reachable
    // over the internet. Its next post was then deposited nowhere, which is
    // the one thing the deposit exists to prevent.
    final now = DateTime.now().millisecondsSinceEpoch;
    expect(
        XprsArchiverChoice.pick(const [], selfBase: 'X1AAAA',
            nowMs: now, current: 'X1ARKL'),
        'X1ARKL',
        reason: 'an empty list is no evidence, and nothing to move to');

    // Silence is still not forever: with a live volunteer there to take over,
    // an archiver unheard past the forget window is replaced.
    expect(
        XprsArchiverChoice.pick(
          [
            ArchiverOffer(
                callsign: 'X1ARKL',
                lastHeardMs: now - const Duration(hours: 13).inMilliseconds,
                bearer: 'rns'),
            ArchiverOffer(callsign: 'X3NEWR', lastHeardMs: now, bearer: 'rns'),
          ],
          selfBase: 'X1AAAA',
          nowMs: now,
          current: 'X1ARKL',
        ),
        'X3NEWR');

    // And a station that never had one still adopts nobody from nothing.
    expect(
        XprsArchiverChoice.pick(const [], selfBase: 'X1AAAA', nowMs: now),
        isNull);
  });

  test('an archiver reached only over a radio loses to one on the internet',
      () {
    final now = DateTime.now().millisecondsSinceEpoch;
    expect(
        XprsArchiverChoice.pick(
          [
            ArchiverOffer(callsign: 'X3RADIO', lastHeardMs: now, bearer: 'ble'),
            ArchiverOffer(
                callsign: 'X3NET', lastHeardMs: now - 5000, bearer: 'rns'),
          ],
          selfBase: 'X1AAAA',
          nowMs: now,
        ),
        'X3NET',
        reason: 'leaning on a station you must stand next to is not leaning');
  });

  test('the operator naming an archiver overrides an adopted one', () {
    String? adopted = 'X3ARCH';
    final choice = XprsArchiverChoice.instance.reconsider(
      offers: [
        ArchiverOffer(
            callsign: 'X3ARCH',
            lastHeardMs: DateTime.now().millisecondsSinceEpoch,
            bearer: 'rns'),
      ],
      selfBase: 'X1AAAA',
      autoEnabled: true,
      configured: const ['X3MINE'],
      adoptedNow: adopted,
      adopt: (c) => adopted = c,
    );
    expect(choice, 'X3MINE');
    expect(adopted, isNull, reason: 'the adopted one stands down');
  });
}
