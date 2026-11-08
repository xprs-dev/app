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
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/open.dart';
import 'package:xprs/services/mesh/mesh_store.dart';
import 'package:xprs/services/preferences_service.dart';
import 'package:xprs/services/social/retention_tier.dart';
import 'package:xprs/services/web_chat_api.dart';
import 'package:xprs/services/xprs/xprs_archive.dart';
import 'package:xprs/services/xprs/xprs_gossip.dart';
import 'package:xprs/services/xprs/xprs_monitor.dart';
import 'package:xprs/services/xprs/xprs_archive_policy.dart';
import 'package:xprs/services/xprs/xprs_history_server.dart';
import 'package:xprs/services/xprs/xprs_ingest.dart';
import 'package:xprs/services/xprs/xprs_receipt.dart';
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

  // The C61, 2026-09-15: a phone polled its archiver all evening and never
  // received the one reply held for it, because the archiver's pages were the
  // newest messages of ANYBODY to anybody (and its own junk), and the reply
  // was never among the twelve. XPRS.md 12.1: mail is never offered to a
  // third party.
  test('a recipient that polls its archiver gets its reply, however much '
      'other people\'s mail the archiver holds', () async {
    const archiverPolicy =
        XprsArchivePolicy(public: true, alwaysOn: true, keepChatter: true);
    // The archiver serves strangers only when its operator made it public
    // (12); the history server reads that from the preferences.
    SharedPreferences.setMockInitialValues({'flutter.xprs.public': true});
    await PreferencesService.instance();
    a.archivers = [c.call];
    b.online = false;
    await sim.as(a, () async {
      final wire = await sim.send(
          a, 't:message f:X1AAAA d:X1BBBB ts:$_ts m:the reply');
      await XprsMailbox.instance.depositIfUnanswered(wire);
    });

    final before = XprsIngest.policy;
    XprsIngest.policy = archiverPolicy;
    try {
      await sim.as(c, () async {
        sim.drain(c); // the deposit, spooled by a public archiver
        // Sixty newer messages between two other people.
        for (var i = 0; i < 60; i++) {
          final mm = (i % 60).toString().padLeft(2, '0');
          XprsArchive.instance.admit(
              XprsPacket.parse('t:message f:X1DDDD d:X1EEEE '
                  'ts:2026-09-08_19:30:$mm m:not yours $i')!,
              bearer: 'rns',
              tier: Tier.stranger);
        }
        XprsArchive.instance.flush();
      });

      // B is back and asks its archiver, on the socket lane's one-shot page.
      b.online = true;
      final ask = XprsPacket.parse('t:command f:X1BBBB d:X3ARCH '
          'ts:2026-09-08_20:00:00 cmd:history kind:message '
          'since:2026-09-01_20:00:00')!;
      final page = <String>[];
      await sim.as(c, () async {
        XprsHistoryServer.instance.signingKey = () => c.scalar;
        page.addAll(
            XprsHistoryServer.instance.serveInline(ask, selfBase: c.call));
      });
      expect(page.any((w) => w.contains('not yours')), isFalse,
          reason: 'somebody else\'s mail is never on the page');
      for (final w in page) {
        sim.air.sendTo(b.call, w);
      }
    } finally {
      XprsIngest.policy = before;
    }
    await sim.as(b, () async => sim.drain(b));
    expect(b.delivered.map((p) => p['m']), contains('the reply'));
  });

  // A custodian holding SEALED parts can never match the ordinary receipt: it
  // names the reassembled message (XPRS.md 7.6), whose identifier hashes
  // plaintext the holder does not have. So the recipient also signs one
  // receipt per part, which names an identifier the holder computed itself
  // from the bytes it parked, and sends those to the holders only.
  test('a receipt can name one part of a split message', () async {
    b.online = true;
    // A and B have exchanged: 13.7.1 refuses a receipt to a stranger.
    await sim.as(b, () async {
      final hello =
          sim.sign(a, 't:message f:X1AAAA d:X1BBBB ts:$_ts m:first');
      sim.air.sendTo(b.call, hello);
      sim.drain(b);
    });
    expect(b.delivered, hasLength(1));

    await sim.as(b, () async {
      final part = XprsPacket.parse(sim.sign(a,
          't:message f:X1AAAA d:X1BBBB ts:2026-09-08_19:30:00 n:2/3 x:AAAA'))!;
      const partId = 'ab12cd';
      final whole = XprsReceipt.compose(part,
          selfCallsign: b.call, signingKey: b.scalar);
      final one = XprsReceipt.compose(part,
          selfCallsign: b.call, signingKey: b.scalar, forId: partId);
      expect(whole, isNotNull);
      expect(one, isNotNull);
      expect(one!['r'], partId);
      expect(one['r'], isNot(whole!['r']),
          reason: 'the part and the message are different packets');
      expect(one['s'], 'ack');
      expect(one.has('sig'), isTrue,
          reason: '9.7.1: an unsigned receipt is a way to delete other '
              'people\'s mail');
      // And it is the shape a holder acts on: release() reads the part id.
      final released = XprsReceipt.release(one,
          selfCallsign: 'X3ARCH', keyOf: (_) => null);
      expect(released?.id, partId);
    });
  });

  // A visitor on a public archiver's web page (12.7, 12.8.3, API-HTTP.md).
  // X1VIS is a browser: never on the air, never on the directed lane; it
  // reads and posts through X3SERV's page (the core's WebChatApi), and
  // X3SERV is its mailbox. A writes to it from the other side of the
  // network, with X3ARCH as A's archiver; X3ARC2 is X3SERV's own archiver.
  group('a visitor on a public archiver\'s web page', () {
    late MailRelaySim sim2;
    late SimStation a2, c2, s2, d2, v2;

    setUp(() {
      XprsMailboxCounters.debugReset();
      sim2 = MailRelaySim.build(['X1AAAA', 'X3ARCH', 'X3SERV', 'X3ARC2', 'X1VIS']);
      a2 = sim2['X1AAAA'];
      c2 = sim2['X3ARCH'];
      s2 = sim2['X3SERV'];
      d2 = sim2['X3ARC2'];
      v2 = sim2['X1VIS'];
      v2.online = false; // a browser is not a station on the air
      v2.internet = false;
      a2.archivers = [c2.call];
      s2.archivers = [d2.call];
    });

    tearDown(() {
      XprsMailbox.instance.depositAfter = const Duration(seconds: 30);
      sim2.dispose();
    });

    test('held protected, shown through the page, released by the visitor\'s receipt, '
        'and the visitor\'s own mail deposited on their behalf', () async {
      const until = '2026-12-08_00:00:00';
      const browser = '203.0.113.7'; // across the internet, not on X3SERV's LAN
      late WebChatApi api;
      // The page's engine at X3SERV, wired as the hosts wire it: a wire is
      // heard on `lan` through the API; a proven session is a hearing; the
      // station offers itself as mailbox (MeshService.offerMailbox on a
      // public archiver with room).
      WebChatApi makeApi() => WebChatApi(
            publicRows: archivePublicRows,
            held: (_) => 0,
            receive: (_) => fail('receiveFrom is wired; receive must not be used'),
            receiveFrom: (w, {required local}) => XprsIngest.heard(
                XprsPacket.parse(w)!,
                bearer: 'lan',
                selfCallsign: s2.call,
                viaApi: true,
                localLink: local),
            onVisitor: (call, {required local}) {
              XprsMonitor.instance
                  .noteVisitor(call, nowMs: DateTime.now().millisecondsSinceEpoch);
              XprsGossip.instance
                  .noteDirect(call, s2.call, bearer: 'lan', shortRange: local);
            },
            mayAir: (_) => true,
            selfCallsign: () => s2.call,
            keyOf: sim2.keyOf,
            appPath: () => null,
            holdersOf: (c) => XprsArchive.instance.holdersFor(c),
            offerMailbox: (c) {
              XprsArchive.instance.noteServed(c);
              return s2.call;
            },
            mailFor: (c) => MeshStore.instance.heldWiresFor(c).length,
          );
      Future<Map<String, dynamic>> prove() async {
        final n = (await api.handle('GET', '/api/session', {}, '', peer: browser))
            .json['nonce'];
        final r = await api.handle('POST', '/api/session', {},
            sim2.sign(v2, 't:session f:X1VIS ts:$_ts m:$n'), peer: browser);
        expect(r.status, 200, reason: '${r.json}');
        return r.json;
      }
      Future<WebChatReply> post(String wire) => api.handle(
          'POST', '/api/xprs/send', {}, sim2.sign(v2, wire), peer: browser);

      // ── 1. The visitor opens X3SERV's page and proves its key: nobody
      //    holds its mail, so the station offers itself (12.7).
      late String decl;
      await sim2.as(s2, () async {
        XprsMonitor.instance.clear();
        api = makeApi();
        final first = await prove();
        expect(first['holders'], isEmpty);
        expect(first['offer'], 'X3SERV');
        expect(first['mail'], 0);
        // Heard on lan through the API: at our ear (`hears:` names it), a
        // live sighting in gossip and no visit -- a browser across the
        // internet is not radio truth (12.9.4).
        expect(XprsMonitor.instance.directlyHeardOn('lan'), contains('X1VIS'));
        final where = XprsGossip.instance.whereIs('X1VIS');
        expect(where.single.gateway, 'X3SERV');
        expect(where.single.live, isTrue);
        expect(XprsGossip.instance.statusJson()['visits'], 0);
        // A declaration from a key the station does not know is refused
        // (9.12: forging one collects somebody else's mail).
        final stranger = SimStation('X1NOKY', '${sim2.root.path}/X1NOKY');
        final bad = await api.handle('POST', '/api/xprs/send', {},
            sim2.sign(stranger, 't:mailbox f:X1NOKY ts:$_ts hold:X3SERV until:$until'),
            peer: browser);
        expect(bad.status, 409);
        // The page accepts the offer: the visitor's signed declaration
        // (13.12) goes through the page into the funnel and is recorded.
        final r = await post('t:mailbox f:X1VIS ts:$_ts hold:X3SERV until:$until');
        expect(r.status, 200, reason: '${r.json}');
        decl = r.json['wire'] as String;
        expect(XprsArchive.instance.declCount, 1);
        expect(XprsArchive.instance.holdersFor('X1VIS'), ['X3SERV']);
        final second = await prove();
        expect(second['holders'], ['X3SERV']);
        expect(second.containsKey('offer'), isFalse);
      });

      // ── 2. A's archiver learns who holds for X1VIS: the declaration is
      //    replayed to it by the standing `kind:mailbox` catch-up (12.9.5).
      await sim2.as(c2, () async {
        XprsIngest.reticulum('X1VIS', Uint8List.fromList(utf8.encode(decl)));
        expect(XprsArchive.instance.holdersFor('X1VIS'), ['X3SERV']);
      });

      // ── 3. A writes to the visitor, leaves a copy with its archiver,
      //    declares its own mailbox, and goes away.
      late String dm;
      await sim2.as(a2, () async {
        dm = await sim2.send(a2, 't:message f:X1AAAA d:X1VIS ts:$_ts m:hello visitor');
        expect(await XprsMailbox.instance.depositIfUnanswered(dm), 1);
        await XprsMailbox.instance.declare();
      });
      a2.online = false;

      // ── 4. A's archiver cannot reach the visitor and hands the copy to
      //    the visitor's declared holder (12.8.1, L1 first).
      await sim2.as(c2, () async {
        sim2.drain(c2);
        expect(MeshStore.instance.heldWiresFor('X1VIS'), hasLength(1));
        expect(await sim2.forwardParked(c2), ['X3SERV']);
      });

      // ── 5. The serving station: shelved protected (the stranger policy
      //    is off here and the row is kept all the same), shown to the
      //    visitor through the page and to nobody else, never forwarded
      //    away, never re-aired.
      XprsMailboxCounters.debugReset();
      final dmId = xprsIdentifier(XprsPacket.parse(dm)!);
      await sim2.as(s2, () async {
        expect(XprsIngest.policy.public, isFalse);
        sim2.drain(s2);
        XprsArchive.instance.flush();
        final mine = archivePublicRows(types: const ['message'], visitor: 'X1VIS', limit: 50);
        expect(mine.where((r) => '${r['wire']}'.contains('hello visitor')), hasLength(1));
        expect(archivePublicRows(types: const ['message'], limit: 50), isEmpty,
            reason: 'mail is never offered to a third party (12.1)');
        expect(MeshStore.instance.heldWiresFor('X1VIS'), hasLength(1));
        expect(await sim2.forwardParked(s2), isEmpty,
            reason: 'the station IS the holder: nothing moves away');
        expect(await XprsMailbox.instance.sweepHeld(), 0,
            reason: 'a browser hears no re-air');
        api = makeApi();
        expect((await prove())['mail'], 1);

        // ── 6. The visitor read it on the page and posts its signed receipt
        //    (12.8.3 step 5): the held copy is released; the receipt, being
        //    mail for the sleeping sender, is held, handed toward A's
        //    declared holder (step 6) and -- as a served visitor's outgoing
        //    mail -- deposited with X3SERV's own archiver (step 1, on their
        //    behalf, after the deposit window).
        XprsMailbox.instance.depositAfter = const Duration(milliseconds: 1);
        final r = await post('t:receipt f:X1VIS d:X1AAAA r:$dmId ts:$_ts s:ack');
        expect(r.status, 200, reason: '${r.json}');
        expect(MeshStore.instance.heldWiresFor('X1VIS'), isEmpty,
            reason: 'the verified receipt released the copy (12.7)');
        expect(MeshStore.instance.heldTargets(), contains('X1AAAA'));
        expect(await sim2.forwardParked(s2), ['X3ARCH']);
        await Future<void>.delayed(const Duration(milliseconds: 60));
      });
      expect(c2.inbox.where((w) => w.startsWith('t:receipt') && w.contains('via:X3SERV')),
          hasLength(1), reason: 'toward the sender\'s holder, as custody');
      expect(d2.inbox.where((w) => w.startsWith('t:receipt') && !w.contains('via:')),
          hasLength(1), reason: 'deposited verbatim with the serving station\'s archiver');
      expect(XprsMailboxCounters.deposited, 1);

      // ── 7. The visitor writes back (12.8.3 step 1 on their behalf): parked
      //    for A, forwarded toward A's holder, and deposited verbatim with
      //    X3SERV's archiver, which holds it for A.
      await sim2.as(s2, () async {
        api = makeApi();
        XprsMailbox.instance.depositAfter = const Duration(milliseconds: 1);
        final r = await post('t:message f:X1VIS d:X1AAAA ts:2026-09-08_19:01:00 m:thanks, got it');
        expect(r.status, 200, reason: '${r.json}');
        expect(MeshStore.instance.heldWiresFor('X1AAAA').where((w) => w.contains('thanks')),
            hasLength(1));
        expect(await sim2.forwardParked(s2), ['X3ARCH']);
        await Future<void>.delayed(const Duration(milliseconds: 60));
        XprsArchive.instance.flush();
        expect(
            archivePublicRows(types: const ['message'], visitor: 'X1VIS', limit: 50)
                .where((r) => '${r['wire']}'.contains('thanks')),
            hasLength(1),
            reason: 'the visitor\'s own words are its mail too, kept protected');
      });
      final copies = d2.inbox.where((w) => w.contains('thanks, got it')).toList();
      expect(copies, hasLength(1));
      expect(copies.single, isNot(contains('via:')), reason: 'a deposit is not a relay');
      expect(XprsMailboxCounters.deposited, 2);
      await sim2.as(d2, () async {
        sim2.drain(d2);
        expect(MeshStore.instance.heldWiresFor('X1AAAA').where((w) => w.contains('thanks')),
            hasLength(1), reason: 'the archiver holds the visitor\'s mail for A');
      });
    });
  });
}
