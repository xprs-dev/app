/*
 * Receipts, per XPRS.md 13.7 / 13.7.1 — in the core, where they belong.
 *
 * The chat wapp invented `?ACK <am> d|r` and an `am:` correlation id, neither
 * of which appears anywhere in the specification, and aired the receipt BEFORE
 * its own render gate -- so a sender saw a tick for a message the recipient
 * never saw. The spec's answer already existed in the core and was half-wired:
 * `s:read` had no producer and no consumer, and a receipt arriving over
 * Reticulum was dropped on the floor.
 */
import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/services/receive/wapp_delivery.dart';
import 'package:xprs/services/xprs/xprs_id.dart';
import 'package:xprs/services/xprs/xprs_outbox.dart';
import 'package:xprs/services/xprs/xprs_packet.dart';
import 'package:xprs/services/xprs/xprs_receipt.dart';

const _ts = '2026-09-02_10:00:00';
XprsPacket _p(String w) => XprsPacket.parse(w)!;

void main() {
  setUp(XprsOutbox.debugReset);
  tearDown(XprsOutbox.debugReset);

  group('what a receipt names', () {
    test("r: is the section 5 identifier of the message, exactly", () {
      // The property the whole scheme rests on: a relayed copy and a directly
      // heard one produce the same identifier, so one receipt names both.
      final msg = _p('t:message f:X1QZ3N d:X1SELF ts:$_ts m:on my way');
      final id = xprsIdentifier(msg);

      final relayed =
          _p('t:message f:X1QZ3N d:X1SELF ts:$_ts via:X3ARK m:on my way');
      expect(xprsIdentifier(relayed), id,
          reason: 'via: is excluded from the identifier (section 5)');
    });
  });

  group('the outbox is what a receipt advances', () {
    test('sent becomes delivered on ack, and read on read', () {
      XprsOutbox.instance.noteSent('abc123', 'X1RD89');
      expect(XprsOutbox.instance.stateOf('abc123'), TxState.sent);

      XprsOutbox.instance.noteReceipt('abc123', state: 'ack');
      expect(XprsOutbox.instance.stateOf('abc123'), TxState.delivered);

      XprsOutbox.instance.noteReceipt('abc123', state: 'read');
      expect(XprsOutbox.instance.stateOf('abc123'), TxState.read);
    });

    test('a late ack cannot walk read backwards', () {
      XprsOutbox.instance.noteSent('abc123', 'X1RD89');
      XprsOutbox.instance.noteReceipt('abc123', state: 'read');
      XprsOutbox.instance.noteReceipt('abc123', state: 'ack');
      expect(XprsOutbox.instance.stateOf('abc123'), TxState.read,
          reason: 'two copies of one receipt must not undo a state');
    });

    test('a receipt for something we never sent is counted, not crashed', () {
      XprsOutbox.instance.noteReceipt('nosuch', state: 'ack');
      expect(XprsOutbox.unknown, 1);
    });

    test('a state change is published for the wapp that drew the bubble', () {
      final seen = <String>[];
      WappDelivery.onPublish = (topic, row) =>
          seen.add('$topic|${row['id']}|${row['state']}');
      XprsOutbox.instance.noteSent('abc123', 'X1RD89');
      XprsOutbox.instance.noteReceipt('abc123', state: 'ack');
      expect(seen, ['xprs.status.tx|abc123|delivered']);
      WappDelivery.onPublish = null;
    });
  });

  group('release reports which state, and refuses what it cannot check', () {
    test('an unsigned receipt releases nothing (13.7.1)', () {
      final r = _p('t:receipt f:X1QZ3N d:X1SELF r:abc123 ts:$_ts s:ack');
      expect(XprsReceipt.release(r, selfCallsign: 'X1SELF', keyOf: (_) => null),
          isNull,
          reason: 'a forged s:ack is a way to delete mail from the whole mesh');
    });

    test('our own receipt releases nothing', () {
      final r = _p('t:receipt f:X1SELF d:X1QZ3N r:abc123 ts:$_ts s:ack');
      expect(
          XprsReceipt.release(r, selfCallsign: 'X1SELF', keyOf: (_) => null),
          isNull);
    });

    test('a receipt naming nothing usable releases nothing', () {
      for (final w in [
        't:receipt f:X1QZ3N d:X1SELF ts:$_ts s:ack', // no r:
        't:receipt f:X1QZ3N d:X1SELF r:short ts:$_ts s:ack', // not 6 hex
        't:receipt f:X1QZ3N d:X1SELF r:abc123 ts:$_ts s:sign', // not ack/read
      ]) {
        expect(
            XprsReceipt.release(_p(w),
                selfCallsign: 'X1SELF', keyOf: (_) => null),
            isNull,
            reason: w);
      }
    });
  });

  group('the read half, which only a wapp can know', () {
    // The core composes `s:ack` at delivery because arrival is a fact about
    // bytes. That a PERSON opened the message is a fact about a screen, so the
    // wapp reports it — by identifier, and by nothing else. Composing the
    // receipt, applying 13.7.1 and choosing the lane stay here.
    test('composeRead needs the message it names, and answers by id', () {
      XprsReceipt.debugForget();
      final msg = _p('t:message f:X1QZ3N d:X1SELF ts:$_ts m:on my way');
      final id = xprsIdentifier(msg);

      // Nothing remembered yet: an id the core cannot place changes nothing.
      // A wapp cannot conjure a receipt for a message we never handled.
      expect(XprsReceipt.composeRead(id, selfCallsign: 'X1SELF'), isNull);

      XprsReceipt.remember(msg);
      // Still refused: 13.7.1 wants an exchange, and this test has no archive.
      // What matters is that it is the EXCLUSION table refusing, not a missing
      // packet — the counter tells the two apart.
      final before = XprsReceiptCounters.readUnknown;
      XprsReceipt.composeRead(id, selfCallsign: 'X1SELF');
      expect(XprsReceiptCounters.readUnknown, before,
          reason: 'the packet was found; any refusal came from 13.7.1');
    });

    test('a remembered id is the one the sender keyed its bubble on', () {
      final msg = _p('t:message f:X1QZ3N d:X1SELF ts:$_ts m:on my way');
      XprsReceipt.debugForget();
      XprsReceipt.remember(msg);
      // The sender derived the same value from the bytes it sent, which is why
      // one identifier serves the outbox, the receipt and the wapp's bubble —
      // and why the `am:` token this replaced was redundant.
      expect(XprsReceipt.debugRemembers(xprsIdentifier(msg)), isTrue);
      expect(XprsReceipt.debugRemembers('000000'), isFalse);
    });
  });
}
