/*
 * THE LOCAL ROOM, from the core's side.
 *
 * A broadcast is not a message with the recipient left blank. It cannot be
 * sealed (§9.2 seals to one public key), it is not carried (§13.11.3), and
 * nobody owes a receipt for it (§13.7.1) — so the send path has to differ from
 * the 1:1 in four places, and each of those is a way for it to look like it
 * worked while doing nothing.
 *
 * The last one is why this file exists at all. The Local room was write-only
 * for a week: chat sent into it and never listened, and nothing in the app
 * could tell the difference between "nobody is talking" and "the room is
 * broken".
 */
import 'package:flutter_test/flutter_test.dart';

import 'package:xprs/services/xprs/xprs_body.dart';
import 'package:xprs/services/xprs/xprs_id.dart';
import 'package:xprs/services/xprs/xprs_packet.dart';
import 'package:xprs/services/xprs/xprs_publisher.dart';
import 'package:xprs/services/xprs/xprs_receipt.dart';
import 'package:xprs/services/xprs/xprs_send.dart';
import 'package:xprs/services/xprs/xprs_vocab.dart';

/// The head `XprsSend.broadcast` composes, spelled out so a change to it has
/// to be a change to this line too.
const _head = 't:message f:X1VCVM ts:2026-09-03_11:04:00 scope:local';

class _FakeBearer implements XprsBearer {
  _FakeBearer(this.name, {required this.shortRange});
  @override
  final String name;
  @override
  String get archiveBearer => name;
  @override
  final bool shortRange;
  final List<String> sent = [];
  final List<String> slots = [];
  @override
  Future<bool> get active async => true;
  @override
  Future<XprsSendResult> send(String wire,
      {required int part, String slot = 'status', Duration? ttl}) async {
    sent.add(wire);
    slots.add(slot);
    return XprsSendResult.sent;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the wire', () {
    test('is a t:message with no d: and scope:local', () {
      final built = xprsBuildDirect(
          head: XprsPacket.parse(_head)!, text: 'anyone got a 10 mm spanner?',
          private: false);
      expect(built.ok, isTrue);
      expect(built.packets, hasLength(1));
      final p = built.packets.first;
      expect(p['d'], isNull,
          reason: 'a d: would make it mail, not a publication (§36.1)');
      expect(p['scope'], 'local');
      expect(xprsScope(p).scope, XprsScope.local);
      expect(p.fits, isTrue);
    });

    test('splits at spaces like a 1:1, and names the reassembled packet', () {
      final text = List.generate(90, (i) => 'w$i').join(' ');
      final built = xprsBuildDirect(
          head: XprsPacket.parse(_head)!, text: text, private: false);
      expect(built.ok, isTrue);
      expect(built.packets.length, greaterThan(1),
          reason: 'the fixture has to split to test anything');
      // Every part carries the scope: a relay reads it off whichever part it
      // heard, and one unscoped part is a leak.
      for (final p in built.packets) {
        expect(p['scope'], 'local');
        expect(p.fits, isTrue);
      }
      expect(built.rejoined, isNotNull);
      expect(xprsIdentifier(built.rejoined!),
          isNot(xprsIdentifier(built.packets.first)));
    });
  });

  group('the reach', () {
    test('local never leaves the short-range bearers', () async {
      final ble = _FakeBearer('ble5', shortRange: true);
      final lan = _FakeBearer('lan', shortRange: true);
      final rns = _FakeBearer('reticulum', shortRange: false);
      XprsPublisher.instance.bearers = [ble, lan, rns];

      final report = await XprsPublisher.instance
          .publishWire('$_head m:hello the room');

      expect(report['ble5'], 'sent');
      expect(report['lan'], 'sent');
      expect(report['reticulum'], 'scope',
          reason: '§13.11.1: not onto the internet, ever');
      expect(rns.sent, isEmpty);
    });

    test('without scope: it goes everywhere, which is the default', () async {
      final ble = _FakeBearer('ble5', shortRange: true);
      final rns = _FakeBearer('reticulum', shortRange: false);
      XprsPublisher.instance.bearers = [ble, rns];

      await XprsPublisher.instance.publishWire(
          't:message f:X1VCVM ts:2026-09-03_11:04:00 m:hello everyone');

      expect(rns.sent, hasLength(1),
          reason: 'absent scope: is global (§13.11), not local');
    });
  });

  group('the advert slot', () {
    // Registering an advert key REPLACES that rotation entry. The default for
    // a packet with no d: is the bare type, so every Local post this station
    // ever made keyed on the single string `message` and evicted the one
    // before it — two posts in a minute, one on the air.
    test('two posts under the default key collide', () async {
      final ble = _FakeBearer('ble5', shortRange: true);
      XprsPublisher.instance.bearers = [ble];

      await XprsPublisher.instance.publishWire('$_head m:first');
      await XprsPublisher.instance.publishWire('$_head m:second');

      expect(ble.slots, ['message', 'message'],
          reason: 'this is the trap the send path passes a slot to avoid');
    });

    test('a post per message and a slot per part', () async {
      final ble = _FakeBearer('ble5', shortRange: true);
      XprsPublisher.instance.bearers = [ble];

      // What XprsSend._airBroadcast passes: the §5 identifier and the part.
      await XprsPublisher.instance
          .publishWire('$_head m:first', slot: 'message:aaaaaa:1');
      await XprsPublisher.instance
          .publishWire('$_head m:second', slot: 'message:bbbbbb:1');

      expect(ble.slots.toSet(), hasLength(2));
    });
  });

  group('what a broadcast is not', () {
    test('nobody owes it a receipt (§13.7.1)', () {
      final p = XprsPacket.parse('$_head m:hello the room')!;
      expect(
          XprsReceipt.compose(p, selfCallsign: 'X3WWAJ'), isNull,
          reason: 'no d: means nobody was addressed, so nobody answers');
    });

    test('a scope word nobody defined is refused before it reaches a wire', () {
      expect(XprsSend.scopeOk(''), isTrue);
      expect(XprsSend.scopeOk('local'), isTrue);
      expect(XprsSend.scopeOk('global'), isTrue);
      expect(XprsSend.scopeOk('pt'), isTrue);
      expect(XprsSend.scopeOk('pt,es'), isTrue);
      // Read as a country list, these would gate every bearer and the send
      // would look exactly like a radio that is switched off.
      expect(XprsSend.scopeOk('locl'), isFalse);
      expect(XprsSend.scopeOk('near'), isFalse);
      expect(XprsSend.scopeOk('p'), isFalse);
      expect(XprsSend.scopeOk('pt,'), isFalse);
    });

    test('no profile, no packet — and it is counted as refused', () {
      final before = XprsSend.refused;
      final r = XprsSend.instance.broadcast('hello');
      expect(r.ok, isFalse);
      expect(r.code, 0, reason: 'malformed, never -1: nothing was asked to seal');
      expect(XprsSend.refused, before + 1);
    });
  });
}
