import 'dart:convert';
import 'dart:typed_data';

import 'package:xprs/services/mesh/mesh_courier.dart';
import 'package:xprs/services/receive/wapp_delivery.dart';
import 'package:xprs/services/xprs/xprs_vocab.dart';
import 'package:xprs/wapp/wapp_event_broker.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List wire(String from, String to, String text) =>
    Uint8List.fromList(utf8.encode('$from\x1F$to\x1F$text'));

void main() {
  group('the courier envelope', () {
    test('a carrier can read who a message is for, sealed body or not', () {
      // The whole point of the public envelope: a device that cannot read the
      // recipient cannot decide whom to hand the message to.
      final w = wire('X1A33T', 'X1RD89', 'am:40c124 ENC1:AAAA ~sig');
      final s = utf8.decode(w);
      expect(s.split('\x1F').length, 3);
      expect(s.split('\x1F')[1], 'X1RD89');
    });

    test('a frame no custodian could take whole is refused, not truncated',
        () {
      // The ESP32 parks up to 252 bytes. A longer frame would be carried by the
      // phones for days and dropped by the dongle at the end of the chain.
      expect(MeshCourier.maxWire, lessThan(252));
    });

    test('the wait outlives the direct-link attempt', () {
      // sendLxmf gives up on a direct link at 10s. Asking sooner would air a
      // copy for a message that was about to arrive.
      expect(MeshCourier.wait.inSeconds, greaterThan(10));
      expect(MeshCourier.giveUp, greaterThan(MeshCourier.wait));
    });
  });

  group('ingest', () {
    test('a frame addressed to somebody else is not ours to render', () {
      // No mesh service is running in the test VM, so tableCallsign is empty
      // and every frame must be refused rather than misattributed.
      expect(
        MeshCourier.instance.ingest(wire('X1A33T', 'X9ZZZZ', 'hello'),
            via: 'test'),
        isFalse,
      );
    });

    test('a malformed frame is refused', () {
      expect(
        MeshCourier.instance
            .ingest(Uint8List.fromList(utf8.encode('nonsense')), via: 'test'),
        isFalse,
      );
    });
  });

  group('the wapp door: an XPRS message, by callsign, no LXMF', () {
    final bus = WappEventBroker.instance;

    setUp(() {
      for (final id in bus.registeredEngines().toList()) {
        bus.unregisterEngine(id);
      }
      WappDelivery.debugReset();
      bus.registerEngine('chat');
      bus.subscribe('chat', rxTopicFor('message'));
    });

    test('a station 1:1 is delivered with its callsign, ts and sig — no hex',
        () {
      final n = WappDelivery.instance.deliverMessage(
          call: 'X3DCK0',
          content: 'from a keyboard station',
          bearer: 'ble',
          id: 'a1b2c3',
          sig: 'unsigned',
          ts: xprsParseTs('2026-09-05_08:00:00')! / 1000.0);
      expect(n, XprsDelivery.delivered,
          reason: 'the chat engine asked for this topic');
      final row = jsonDecode(bus.recv('chat')!.data) as Map<String, dynamic>;
      expect(row['call'], 'X3DCK0');
      expect(row['from'], '', reason: 'no LXMF destination is involved');
      expect(row['content'], 'from a keyboard station');
      expect(row['bearer'], 'ble', reason: 'the only word chat learns about how it travelled');
      expect(row['sig'], 'unsigned',
          reason: 'unsigned still reaches a person (XPRS.md §9.1)');
      expect(row['id'], 'a1b2c3');
    });

    test('a body that is itself an XPRS wire never reaches a person', () {
      final before = WappDelivery.refusedProtocol;
      final n = WappDelivery.instance.deliverMessage(
          call: 'X3DCK0',
          content: 't:message f:X3DCK0 d:X1WATT m:leaked wire',
          bearer: 'ble');
      expect(n, XprsDelivery.refused);
      expect(WappDelivery.refusedProtocol, before + 1);
      expect(bus.queueDepth('chat'), 0);
    });
  });

  // 2026-09-15, the C61: every `t:result` it sent a phone it could not reach
  // over Reticulum was sealed into a NEW t:message to that phone, 474 of them
  // in fifty minutes, burying the one real reply it held.
  group('a carrier carries mail, not answers', () {
    test('an XPRS wire that is not a person\'s mail is never wrapped', () {
      for (final w in [
        't:result f:X1ARKL d:X1WATT ts:2026-09-15_21:29:18 r:1a2b3c code:206',
        't:receipt f:X1WATT d:X1UDP4 r:40f357 s:ack',
        't:command f:X1WATT d:X1ARKL ts:2026-09-15_21:29:17 cmd:history kind:message',
        't:pong f:X1ARKL d:X1WATT ts:2026-09-15_21:29:18',
        't:message f:X1ARKL d:X5A3F2 ts:2026-09-15_21:29:18 m:a group post',
      ]) {
        expect(MeshCourier.notMail(w), isTrue, reason: w);
      }
    });

    test('a person\'s mail is carried as it is, and plain text is a body', () {
      expect(
          MeshCourier.notMail(
              't:message f:X1UDP4 d:X1WATT ts:2026-09-15_20:51:51 n:1/3 x:abc'),
          isFalse);
      expect(MeshCourier.notMail('see you at eight'), isFalse,
          reason: 'not a wire: the courier seals it into one');
      expect(MeshCourier.notMail('t:not a packet at all'), isFalse);
    });

    test('arming an answer holds nothing for the courier', () {
      final armed = MeshCourierCounters.armed;
      final notMail = MeshCourierCounters.notMail;
      MeshCourier.instance.armLxmf(
          destHex: '0123456789abcdef0123456789abcdef',
          text: 't:result f:X1ARKL d:X1WATT ts:2026-09-15_21:29:18 r:1a2b3c code:206');
      expect(MeshCourierCounters.armed, armed);
      expect(MeshCourierCounters.notMail, notMail + 1);
    });
  });
}
