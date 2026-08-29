/*
 * The communication coordinator: which bearers carry a packet, what happens
 * when one is taken away, and what the funnel owes an arriving packet.
 *
 * Every case here is one the app got wrong before this suite existed, and every
 * one of them was invisible from the inside — nothing errored, nothing was
 * refused, a station simply did less than it claimed. So each test names the
 * observable that would have caught it.
 */
import 'package:flutter_test/flutter_test.dart';

import 'package:xprs/services/xprs/xprs_archive.dart';
import 'package:xprs/services/xprs/xprs_ingest.dart';
import 'package:xprs/services/xprs/xprs_packet.dart';
import 'package:xprs/services/xprs/xprs_airtime.dart';
import 'package:xprs/services/xprs/xprs_publisher.dart';
import 'package:xprs/services/xprs/xprs_groups.dart';
import 'package:xprs/services/xprs/xprs_sig.dart';
import 'package:xprs/services/xprs/xprs_id.dart';
import 'package:xprs/util/nostr_crypto.dart';
import 'package:hex/hex.dart';
import 'dart:typed_data';

/// A bearer that records what it was asked to carry.
class FakeBearer implements XprsBearer {
  FakeBearer(this.name,
      {this.shortRange = true,
      bool up = true,
      bool accepts = true,
      String? archive})
      : _up = up,
        _accepts = accepts,
        _archive = archive;

  @override
  final String name;
  @override
  final bool shortRange;
  final String? _archive;
  bool _up;
  bool _accepts;

  /// What this bearer answers when it will not send: `refused` by default,
  /// `queued` for a lane that stores and forwards.
  XprsSendResult result = XprsSendResult.refused;

  final List<String> sent = [];
  final List<String> slots = [];
  final List<int> parts = [];

  set up(bool v) => _up = v;
  set accepts(bool v) => _accepts = v;

  @override
  String get archiveBearer => _archive ?? name;
  @override
  Future<bool> get active async => _up;
  @override
  Future<XprsSendResult> send(String wire,
      {required int part, String slot = 'status', Duration? ttl}) async {
    if (!_accepts) return result;
    sent.add(wire);
    slots.add(slot);
    parts.add(part);
    return XprsSendResult.sent;
  }
}

const _ts = '2026-08-08_14:26:40';
String _wire({String? d, String? scope, String m = 'hello'}) =>
    't:message f:X1QZ3N${d == null ? '' : ' d:$d'} ts:$_ts'
    '${scope == null ? '' : ' scope:$scope'} m:$m';

void main() {
  late FakeBearer ble, lan, rns, lora;
  late XprsPublisher pub;

  setUp(() {
    ble = FakeBearer('ble5', archive: 'ble');
    lan = FakeBearer('lan');
    rns = FakeBearer('reticulum', shortRange: false, archive: 'rns');
    lora = FakeBearer('lora');
    XprsAirtime.instance.reset();
    pub = XprsPublisher.instance;
    pub.bearers = [ble, lan, rns, lora];
    for (final b in pub.bearers) {
      pub.setBearerEnabled(b.name, true);
    }
  });

  Future<Map<String, String>> air(String w) =>
      pub.publishWire(w, verbatim: true);

  group('a broadcast reaches every bearer that can carry it', () {
    test('all four take it when all four are up', () async {
      final r = await air(_wire());
      expect(r, {
        'ble5': 'sent',
        'lan': 'sent',
        'reticulum': 'sent',
        'lora': 'sent'
      });
      expect(ble.sent.single, contains('m:hello'));
    });

    test('a bearer whose radio is off reports inactive, and the rest still go',
        () async {
      ble.up = false;
      final r = await air(_wire());
      expect(r['ble5'], 'inactive');
      expect(r['lan'], 'sent');
      expect(ble.sent, isEmpty);
    });

    test('a bearer that refuses the frame is reported apart from one that is off',
        () async {
      // These mean different things to whoever reads the report: "the radio is
      // off" is a station state, "the controller said no" is about this frame.
      lan.accepts = false;
      final r = await air(_wire());
      expect(r['lan'], 'refused');
      expect(r['ble5'], 'sent');
    });
  });

  group('scope:local names bearers, not a distance (13.11.1)', () {
    test('a local packet never reaches a long-range bearer', () async {
      final r = await air(_wire(scope: 'local'));
      expect(r['reticulum'], 'scope');
      expect(rns.sent, isEmpty, reason: '13.11.1: local must not be gatewayed');
      expect(r['ble5'], 'sent');
      expect(r['lan'], 'sent',
          reason: '13.11.1 permits "the network it is attached to"');
    });

    test('the default is global, so an unmarked packet goes everywhere',
        () async {
      final r = await air(_wire());
      expect(r['reticulum'], 'sent');
    });
  });

  group('the bearer switchboard', () {
    test('a disabled bearer is reported apart from an inactive one', () async {
      pub.setBearerEnabled('lan', false);
      final r = await air(_wire());
      expect(r['lan'], 'disabled');
      expect(lan.sent, isEmpty);
      expect(r['ble5'], 'sent', reason: 'the others carry on');
    });

    test('disabling every bearer reaches nobody, and says so', () async {
      for (final b in pub.bearers) {
        pub.setBearerEnabled(b.name, false);
      }
      final r = await air(_wire());
      expect(r.values.every((v) => v == 'disabled'), isTrue);
      expect(r.values.any((v) => v == 'sent'), isFalse);
    });

    test('re-enabling restores it', () async {
      pub.setBearerEnabled('lan', false);
      pub.setBearerEnabled('lan', true);
      final r = await air(_wire());
      expect(r['lan'], 'sent');
    });

    test('an unknown bearer name is refused rather than silently ignored', () {
      expect(pub.setBearerEnabled('carrier-pigeon', false), isFalse);
      expect(pub.disabledBearers, isEmpty);
    });
  });

  group('one fan-out, so every publish obeys the same rules', () {
    test('a mailbox declaration does not use the status advert slot', () async {
      // A slot is a rotation key on BLE5 — one frame per slot — so sharing one
      // meant a t:mailbox evicted the discovery beacon from the air.
      await pub.publishMailboxDecl('X3RLY7');
      final used = ble.slots.toSet();
      expect(used, isNot(contains('status')));
    });

    test('scope gating applies to every publish, not just two of them',
        () async {
      // publishMailboxDecl and publishIdentity had no scope gate at all. Their
      // packets are global so the gate is a no-op — but it must BE there, or
      // the next scoped packet type added silently leaks.
      final r = await air(_wire(scope: 'local'));
      expect(r['reticulum'], 'scope');
    });
  });

  _funnel();
  _queued();

  group('preferring one path (36.0)', () {
    test('a carried preference leaves the others unused', () async {
      final r = await pub.publishWire(_wire(d: 'X1RD89'),
          verbatim: true, prefer: 'lan');
      expect(r['lan'], 'sent');
      expect(r['ble5'], 'unused');
      expect(r['reticulum'], 'unused');
      expect(ble.sent, isEmpty);
    });

    test('a preference that CANNOT carry falls back to everyone', () async {
      // 36.0: "if the arrival bearer cannot carry the answer it does not give
      // up". A preference that can become silence is not a preference.
      lan.up = false;
      final r = await pub.publishWire(_wire(d: 'X1RD89'),
          verbatim: true, prefer: 'lan');
      expect(r['lan'], 'inactive');
      expect(r['ble5'], 'sent');
      expect(r['reticulum'], 'sent');
    });

    test('a preference that is DISABLED also falls back', () async {
      pub.setBearerEnabled('lan', false);
      final r = await pub.publishWire(_wire(d: 'X1RD89'),
          verbatim: true, prefer: 'lan');
      expect(r['lan'], 'disabled');
      expect(r['ble5'], 'sent');
    });

    test('a preference naming a bearer we do not have falls back', () async {
      final r = await pub.publishWire(_wire(d: 'X1RD89'),
          verbatim: true, prefer: 'satellite');
      expect(r['ble5'], 'sent');
      expect(r['lan'], 'sent');
    });
  });
}

/*
 * The receive funnel. `XprsIngest.heard` is the one door every bearer enters
 * by, and what it owes an arriving packet is the same on all of them.
 */
void _funnel() {
  group('the funnel carries other people\'s mail, on every bearer', () {
    late List<String> carried;
    late List<String> delivered;

    setUp(() {
      carried = [];
      delivered = [];
      XprsIngest.onCarry = (wire, target) => carried.add('$target|$wire');
      XprsIngest.onDeliver = (p, bearer) => delivered.add('$bearer|${p['f']}');
      XprsArchive.instance.selfCallsign = 'X1SELF';
    });

    tearDown(() {
      XprsIngest.onCarry = null;
      XprsIngest.onDeliver = null;
    });

    void hear(String wire, String bearer) => XprsIngest.heard(
        XprsPacket.parse(wire)!,
        bearer: bearer,
        selfCallsign: 'X1SELF');

    for (final bearer in ['ble', 'lan', 'lora', 'espnow']) {
      test('a 1:1 for somebody else heard on $bearer is offered for carry', () {
        // THE defect this suite exists for. `onCarry` was fired from the
        // Reticulum lane and nowhere else, so a station carried mail that
        // arrived over the internet and carried nothing at all that arrived
        // over a radio — while a comment asserted the opposite, pointing at a
        // BLE tap wired to subtype 0x41 while XPRS airs on 0x58.
        hear('t:message f:X1QZ3N d:X1RD89 ts:$_ts m:carry me', bearer);
        expect(carried, hasLength(1), reason: 'not carried on $bearer');
        expect(carried.single, startsWith('X1RD89|'));
      });
    }

    test('a 1:1 addressed to US is delivered, not carried', () {
      hear('t:message f:X1QZ3N d:X1SELF ts:$_ts m:for me', 'ble');
      expect(delivered, hasLength(1));
      expect(carried, isEmpty, reason: 'we are the destination, not a carrier');
    });

    test('a suffixed device address still counts as us (3.1.3)', () {
      // "A station accepts a packet addressed to its own suffixed name or to
      // the bare callsign, and no other."
      hear('t:message f:X1QZ3N d:X1SELF-2 ts:$_ts m:for my tablet', 'ble');
      expect(delivered, hasLength(1));
      expect(carried, isEmpty);
    });

    test('a group message is aired, never couriered', () {
      // 6.3: a group is an address several stations read. There is no single
      // key to seal to and no mailbox to carry toward.
      hear('t:message f:X1QZ3N d:LISBOA ts:$_ts m:net at six', 'ble');
      expect(carried, isEmpty);
      expect(delivered, isEmpty);
    });

    test('a post to a group we BELONG to reaches nobody as correspondence', () {
      // The bug: `forUs` says yes to a closed group's traffic on purpose, so
      // the group has a record — and the delivery gate reused that same
      // variable. Every group post arrived as a private message from whoever
      // sent it, because the courier keys the thread on the SENDER once `d:`
      // is gone. Measured between two devices; three posts in the 1:1 thread.
      //
      // Membership is what makes this bite, so the roster has to be real: an
      // act nobody can verify moves nothing (26.4).
      const g = 'X5A3F2';
      final gk = NostrCrypto.generateKeyPair();
      final mk = NostrCrypto.generateKeyPair();
      BigInt scalar(String hex) {
        var d = BigInt.zero;
        for (final b in HEX.decode(hex)) {
          d = (d << 8) | BigInt.from(b);
        }
        return d;
      }

      final pubs = {
        g: Uint8List.fromList(HEX.decode(gk.publicKeyHex)),
        'X1SELF': Uint8List.fromList(HEX.decode(mk.publicKeyHex)),
      };
      XprsGroups.instance
        ..clear()
        ..keyResolver = (c) => pubs[c];
      final grant = xprsSign(
          XprsPacket.parse(
              't:moderate f:$g d:$g ts:2026-08-08_10:00:00 grant:X1SELF '
              'role:member')!,
          scalar(gk.privateKeyHex));
      XprsGroups.instance.offer(grant);
      XprsGroups.instance.offer(xprsSign(
          XprsPacket.parse('t:moderate f:X1SELF d:$g ts:2026-08-08_10:01:00 '
              'r:${xprsIdentifier(grant)} accept:member')!,
          scalar(mk.privateKeyHex)));
      expect(XprsGroups.instance.rosterOf(g).roles['X1SELF'], XprsRole.member,
          reason: 'the roster has to be real for this test to mean anything');

      hear('t:message f:X1QZ3N d:$g ts:$_ts m:net at six', 'ble');

      expect(delivered, isEmpty,
          reason: 'a group post is nobody\'s correspondence');
      expect(carried, isEmpty,
          reason: 'a group has no mailbox to carry toward');
      XprsGroups.instance.clear();
    });

    test('a broadcast with no d: is not carried', () {
      hear('t:message f:X1QZ3N ts:$_ts m:anyone near the gate?', 'ble');
      expect(carried, isEmpty);
    });

    test('only a message is custody material, not an observation', () {
      hear('t:observation f:X1QZ3N d:X1RD89 link:ble ts:$_ts', 'ble');
      expect(carried, isEmpty,
          reason: 'an observation is aired, not couriered');
    });

    test('our own echo is neither carried nor delivered', () {
      hear('t:message f:X1SELF d:X1RD89 ts:$_ts m:mine', 'ble');
      expect(carried, isEmpty);
      expect(delivered, isEmpty);
    });
  });
}

/*
 * `queued` — the third answer, and the one whose absence made the report lie.
 */
void _queued() {
  group('a lane that stores and forwards answers queued, not refused', () {
    late FakeBearer ble, rns;
    late XprsPublisher pub;

    setUp(() {
      ble = FakeBearer('ble5', archive: 'ble');
      rns = FakeBearer('reticulum', shortRange: false, archive: 'rns')
        ..accepts = false
        ..result = XprsSendResult.queued;
      XprsAirtime.instance.reset();
    pub = XprsPublisher.instance;
      pub.bearers = [ble, rns];
      for (final b in pub.bearers) {
        pub.setBearerEnabled(b.name, true);
      }
    });

    test('queued is reported as itself', () async {
      // Measured on the bench: a directed wire reported `reticulum: refused`
      // and arrived at the far station over Reticulum seconds later, because
      // that bearer hands the packet to two lanes and reported only one.
      final r = await pub.publishWire(_wire(d: 'X1RD89'), verbatim: true);
      expect(r['reticulum'], 'queued');
      expect(r['reticulum'], isNot('refused'));
    });

    test('a queued lane does NOT satisfy a path preference', () async {
      // Choosing one path is only worth doing if it worked. "Handed to a lane
      // that will keep trying" is not "arrived", so the others still go.
      final r = await pub.publishWire(_wire(d: 'X1RD89'),
          verbatim: true, prefer: 'reticulum');
      expect(r['reticulum'], 'queued');
      expect(r['ble5'], 'sent', reason: 'queued is not done');
    });

    test('a refused lane is still refused', () async {
      rns.result = XprsSendResult.refused;
      final r = await pub.publishWire(_wire(d: 'X1RD89'), verbatim: true);
      expect(r['reticulum'], 'refused');
    });
  });
}
