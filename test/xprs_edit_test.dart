// XPRS.md 7.8: correcting and withdrawing what was said. The packet shapes the
// core composes, and that an edit reassembles into the packet a receiver names.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/services/receive/wapp_delivery.dart';
import 'package:xprs/services/xprs/xprs_body.dart';
import 'package:xprs/services/xprs/xprs_group_act.dart';
import 'package:xprs/services/xprs/xprs_id.dart';
import 'package:xprs/services/xprs/xprs_packet.dart';
import 'package:xprs/services/xprs/xprs_parts.dart';
import 'package:xprs/services/xprs/xprs_vocab.dart';
import 'package:xprs/wapp/wapp_event_broker.dart';

const _orig = 't:message f:X1ARKL d:X16JK8 ts:2026-10-15_09:12:00';

XprsPacket head(String rest) => XprsPacket.parse('$_orig$rest')!;

void main() {
  group('an edit is a message that names its original', () {
    test('the original is named by its section 5 identifier, never by an edit', () {
      final original = xprsBuildDirect(
          head: head(''), text: 'meet at six', private: false);
      final id = xprsIdentifier(original.packets.first);
      final edited = xprsBuildDirect(
          head: XprsPacket.parse(
              't:message f:X1ARKL d:X16JK8 ts:2026-10-15_09:20:41 edit:$id')!,
          text: 'meet at seven',
          private: false);
      final e = edited.packets.single;
      expect(e['edit'], id);
      expect(e['m'], 'meet at seven');
      expect(xprsIdentifier(e), isNot(id), reason: 'a packet of its own');
      // The second edit names the SAME original, so a receiver that missed the
      // first loses nothing.
      final again = xprsBuildDirect(
          head: XprsPacket.parse(
              't:message f:X1ARKL d:X16JK8 ts:2026-10-15_09:31:07 edit:$id')!,
          text: 'meet at seven, bring the keys',
          private: false);
      expect(again.packets.single['edit'], id);
    });

    test('a long edit splits, and the reassembled packet still names the original',
        () {
      final text = List.generate(90, (i) => 'w$i').join(' ');
      final built = xprsBuildDirect(
          head: XprsPacket.parse(
              't:message f:X1ARKL d:X16JK8 ts:2026-10-15_09:20:41 edit:3f8923')!,
          text: text,
          private: false);
      expect(built.packets.length, greaterThan(1));
      final t = XprsPartTable();
      XprsReassembled? done;
      for (final p in built.packets) {
        done ??= t.offer(p, clear: p['m'] ?? '');
      }
      expect(done, isNotNull);
      expect(done!.packet['edit'], '3f8923',
          reason: 'every part carries it, so the whole does');
      expect(xprsIdentifier(built.identityPacket!), xprsIdentifier(done.packet));
    });
  });

  group('a withdrawal says one thing', () {
    test('r: names the target and remove: says what, with no body', () {
      final built = xprsBuildDirect(
          head: XprsPacket.parse(
              't:message f:X1ARKL d:X16JK8 ts:2026-10-15_09:40:00 r:3f8923 remove:message')!,
          text: '',
          private: false);
      expect(built.ok, isTrue);
      final w = built.packets.single;
      expect(w['r'], '3f8923');
      expect(w['remove'], 'message');
      expect(w.has('m'), isFalse);
      expect(w.has('x'), isFalse);
      expect(w.fits, isTrue);
    });
  });

  group('a moderator acts under t:moderate, never as the author', () {
    final key = BigInt.parse(
        '1111111111111111111111111111111111111111111111111111111111111111',
        radix: 16);

    test('an edit carries edit: and the replacement words', () {
      final p = XprsGroupAct.moderateEdit(
          group: 'X5A3F2',
          messageId: '49E3CD',
          text: '[number removed by a moderator]',
          scalar: key,
          signer: 'X32DVA')!;
      expect(p.type, 'moderate');
      expect(p['f'], 'X32DVA');
      expect(p['d'], 'X5A3F2');
      expect(p['edit'], '49e3cd', reason: 'identifiers are lower case');
      expect(p['m'], '[number removed by a moderator]');
      expect(p.has('sig'), isTrue);
    });

    test('a removal names its target in r: with remove:message', () {
      final p = XprsGroupAct.moderateRemove(
          group: 'X5A3F2', messageId: '49e3cd', scalar: key)!;
      expect(p['f'], 'X5A3F2', reason: 'the admin signs as the group');
      expect(p['r'], '49e3cd');
      expect(p['remove'], 'message');
      expect(p.has('m'), isFalse);
    });

    test('words too long for one packet are refused, not split', () {
      expect(
          XprsGroupAct.moderateEdit(
              group: 'X5A3F2',
              messageId: '49e3cd',
              text: 'x' * 400,
              scalar: key),
          isNull);
    });
  });

  group('the wapp door states what a delivery corrects or withdraws', () {
    final bus = WappEventBroker.instance;
    setUp(() {
      for (final id in bus.registeredEngines().toList()) {
        bus.unregisterEngine(id);
      }
      WappDelivery.debugReset();
      bus.registerEngine('chat');
      bus.subscribe('chat', rxTopicFor('message'));
    });

    Map<String, dynamic> deliver({String edit = '', String remove = ''}) {
      WappDelivery.instance.deliverMessage(
          call: 'X1ARKL',
          content: remove.isEmpty ? 'meet at seven' : '',
          bearer: 'lan',
          id: 'a1b2c3',
          sig: 'verified',
          edit: edit,
          remove: remove);
      return jsonDecode(bus.recv('chat')!.data) as Map<String, dynamic>;
    }

    test('an ordinary message corrects and withdraws nothing', () {
      final r = deliver();
      expect(r['edit'], '');
      expect(r['remove'], '');
    });

    test('an edit carries the original it corrects', () {
      expect(deliver(edit: '3f8923')['edit'], '3f8923');
    });

    test('a withdrawal carries the target and no content', () {
      final r = deliver(remove: '3f8923');
      expect(r['remove'], '3f8923');
      expect(r['content'], '');
    });
  });
}
