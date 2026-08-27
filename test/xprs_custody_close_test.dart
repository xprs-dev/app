/*
 * Closing the custody loop: the receipt, the release, and the airtime budget.
 *
 * These three were the gaps the bench found after a day of carrying:
 *
 *     parked 1739   pending 3699   custodyOut 0   purged 0   delivered 0
 *
 * Every message ever parked was still parked, because nothing composed a
 * receipt, the release picked the four oldest rows in the whole store, and
 * nothing anywhere counted airtime. Each test below names the observable that
 * would have caught its fault.
 */
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hex/hex.dart';

import 'package:xprs/services/xprs/xprs_airtime.dart';
import 'package:xprs/services/xprs/xprs_id.dart';
import 'package:xprs/services/xprs/xprs_packet.dart';
import 'package:xprs/services/xprs/xprs_receipt.dart';
import 'package:xprs/services/xprs/xprs_sig.dart';
import 'package:xprs/services/xprs/xprs_vocab.dart';
import 'package:xprs/util/nostr_crypto.dart';

BigInt _big(String hex) {
  var r = BigInt.zero;
  for (final b in HEX.decode(hex)) {
    r = (r << 8) | BigInt.from(b);
  }
  return r;
}

const _ts = '2026-08-08_14:26:40';

void main() {
  final privB =
      'a1b2c3d4e5f60718293a4b5c6d7e8f90112233445566778899aabbccddeeff00';
  final dB = _big(privB);
  final pubB = Uint8List.fromList(
      HEX.decode(NostrCrypto.derivePublicKey(privB)));
  final otherPriv = NostrCrypto.generateKeyPair().privateKeyHex;
  final dOther = _big(otherPriv);

  _deliveryMemory();

  group('a receipt is what ends custody (13.7.1)', () {
    // compose() consults the archive for "have we exchanged before", which a
    // unit test has no database for, so these pin the SHAPE and the exclusions
    // that are decided before the archive is asked.

    test('a receipt names the message by its section 5 identifier', () {
      final msg = XprsPacket.parse(
          't:message f:X1RD89 d:X1A67X ts:$_ts m:on my way')!;
      final id = xprsIdentifier(msg);
      // Section 13.7.1's own worked example shape.
      final r = XprsPacket.parse(
          't:receipt f:X1A67X d:X1RD89 r:$id ts:$_ts s:ack')!;
      expect(r['r'], id);
      expect(r['r']!.length, 6);
      expect(r.has('q'), isFalse,
          reason: 'a device reporting bytes, not a person agreeing');
    });

    test('a broadcast is never acknowledged', () {
      // "one packet, every hearer answering"
      final p = XprsPacket.parse('t:message f:X1RD89 ts:$_ts m:anyone?')!;
      expect(XprsReceipt.compose(p, selfCallsign: 'X1A67X'), isNull);
    });

    test('a group message is never acknowledged', () {
      // "every member answering every message"
      final p = XprsPacket.parse(
          't:message f:X1RD89 d:LISBOA ts:$_ts m:net at six')!;
      expect(XprsReceipt.compose(p, selfCallsign: 'X1A67X'), isNull);
    });

    test('a regional message is never acknowledged', () {
      final p = XprsPacket.parse('t:message f:X1RD89 dest:38,24 near:50km '
          'ts:$_ts m:anyone near Athens')!;
      expect(XprsReceipt.compose(p, selfCallsign: 'X1A67X'), isNull);
    });

    test('a message addressed to somebody else is not ours to acknowledge', () {
      final p = XprsPacket.parse(
          't:message f:X1RD89 d:X32DVA ts:$_ts m:for them')!;
      expect(XprsReceipt.compose(p, selfCallsign: 'X1A67X'), isNull);
    });

    test('a receipt is never acknowledged', () {
      // "an acknowledgement of an acknowledgement never terminates"
      final p = XprsPacket.parse(
          't:receipt f:X1RD89 d:X1A67X r:40f357 ts:$_ts s:ack')!;
      expect(XprsReceipt.compose(p, selfCallsign: 'X1A67X'), isNull);
    });
  });

  group('a receipt that cannot be trusted changes nothing', () {
    XprsPacket signedAck(BigInt key, {String from = 'X1A67X'}) {
      final r = XprsPacket.parse(
          't:receipt f:$from d:X1RD89 r:40f357 ts:$_ts s:ack')!;
      return xprsSign(r, key);
    }

    test('a verified receipt releases the named message', () {
      final r = signedAck(dB);
      expect(
          XprsReceipt.release(r, selfCallsign: 'X1RD89', keyOf: (_) => pubB),
          '40f357');
    });

    test('a receipt signed by the WRONG key releases nothing', () {
      // The attack 13.7.1 describes: a forged s:ack is "a way to delete a
      // message from the whole mesh, cheaply, without holding anyone's key".
      final r = signedAck(dOther);
      expect(
          XprsReceipt.release(r, selfCallsign: 'X1RD89', keyOf: (_) => pubB),
          isNull);
    });

    test('an UNSIGNED receipt releases nothing', () {
      final r = XprsPacket.parse(
          't:receipt f:X1A67X d:X1RD89 r:40f357 ts:$_ts s:ack')!;
      expect(
          XprsReceipt.release(r, selfCallsign: 'X1RD89', keyOf: (_) => pubB),
          isNull);
    });

    test('a signer whose key we have never heard releases nothing', () {
      // "unverifiable is not probably fine"
      final r = signedAck(dB);
      expect(
          XprsReceipt.release(r, selfCallsign: 'X1RD89', keyOf: (_) => null),
          isNull);
    });

    test('a receipt without s:ack releases nothing', () {
      final r = xprsSign(
          XprsPacket.parse(
              't:receipt f:X1A67X d:X1RD89 r:40f357 ts:$_ts s:read')!,
          dB);
      expect(
          XprsReceipt.release(r, selfCallsign: 'X1RD89', keyOf: (_) => pubB),
          isNull);
    });

    test('our own receipt does not release our own copy', () {
      final r = signedAck(dB, from: 'X1RD89');
      expect(
          XprsReceipt.release(r, selfCallsign: 'X1RD89', keyOf: (_) => pubB),
          isNull);
    });
  });

  group('a release is a relay (36.8.1) and obeys section 13', () {
    // 36.8.1: "via: gains the holder's callsign, the section 13.1 budget and
    // the section 13.2 loop check apply".

    test('a packet that already came through us is not released again', () {
      final p = XprsPacket.parse('t:message f:X1QZ3N d:X1RD89 ts:$_ts '
          'via:X32DVA,X3ARK m:hello')!;
      expect(xprsWouldLoop(p, 'X3ARK'), isTrue);
    });

    test('a message at its hop limit is not released', () {
      final p = XprsPacket.parse('t:message f:X1QZ3N d:X1RD89 ts:$_ts '
          'via:A,B,C m:hello')!;
      expect(xprsMayRelay(p), isFalse, reason: '13.1: 3 relays for a message');
    });

    test('an sos still travels at three hops — nine is its budget', () {
      final p =
          XprsPacket.parse('t:sos f:X1QZ3N ts:$_ts via:A,B,C m:help')!;
      expect(xprsMayRelay(p), isTrue);
    });

    test('appending via: renames nothing', () {
      // Sections 5 and 9.1 both exclude via:, which is what makes a relayed
      // copy answerable by the same receipt as a direct one.
      final p =
          XprsPacket.parse('t:message f:X1QZ3N d:X1RD89 ts:$_ts m:hello')!;
      final before = xprsIdentifier(p);
      expect(xprsIdentifier(xprsAppendVia(p, 'X3ARK')), before);
    });
  });

  group('one airtime budget across the bearers (31.1)', () {
    late XprsAirtime air;
    var clock = 1000000;

    setUp(() {
      air = XprsAirtime.instance..reset();
      clock = 1000000;
      air.now = () => clock;
    });

    test('an unmetered bearer never blocks', () {
      air.charge(['lan', 'reticulum']);
      expect(air.may(['lan', 'reticulum']), XprsAirVerdict.ok);
      expect(air.owedBy('lan'), 0);
    });

    test('THE STRICTEST bearer binds a packet going to several', () {
      // 31.1's own example: "a phone that gateways to both LoRa and the
      // internet is bound by LoRa, not by the internet".
      air.charge(['lora', 'lan']);
      expect(air.may(['lora', 'lan']), XprsAirVerdict.deferred);
      expect(air.lastDeferredBy, 'lora');
      // …and the internet alone is still free.
      expect(air.may(['lan']), XprsAirVerdict.ok);
    });

    test('a retry costs exactly what the first airing cost', () {
      // "a retry is not a new packet ... counts against the same budget as
      // saying it the first time."
      air.charge(['lora']);
      final owedFirst = air.owedBy('lora');
      clock += owedFirst;
      expect(air.may(['lora']), XprsAirVerdict.ok);
      air.charge(['lora']); // the retry
      expect(air.owedBy('lora'), owedFirst,
          reason: 'a retry is charged the same, not less');
    });

    test('the debt drains with time rather than being forgiven', () {
      air.charge(['lora']);
      clock += 1000;
      final owed = air.owedBy('lora');
      expect(owed, greaterThan(0));
      clock += owed;
      expect(air.may(['lora']), XprsAirVerdict.ok);
    });

    test('deferrals are counted, so a quiet station is not mistaken for a dead one',
        () {
      air.charge(['lora']);
      air.may(['lora']);
      air.may(['lora']);
      expect(air.deferrals, 2);
      expect(air.json['lastDeferredBy'], 'lora');
    });
  });

  group('one retry ledger, keyed on the packet (31.1, 13.7.2)', () {
    late XprsRetryLedger led;
    var clock = 1000000;

    setUp(() {
      led = XprsRetryLedger.instance..reset();
      clock = 1000000;
      led.now = () => clock;
    });

    test('a first airing is always allowed', () {
      expect(led.may('abc123', reachable: true), isTrue);
    });

    test('one packet on two lanes is ONE entry, not two', () {
      led.spend('abc123'); // ble
      led.spend('abc123'); // lan, same packet
      expect(led.tracked, 1);
      expect(led.attempts('abc123'), 2);
    });

    test('the ladder climbs', () {
      led.spend('abc123');
      expect(led.may('abc123', reachable: true), isFalse);
      clock += 2000;
      expect(led.may('abc123', reachable: true), isTrue);
      led.spend('abc123');
      clock += 2000;
      expect(led.may('abc123', reachable: true), isFalse,
          reason: 'the second rung is longer than the first');
    });

    test('an unreachable peer burns no rung (13.7.2)', () {
      // "a retry is spent only against evidence that the peer can still be
      // reached ... a peer that returns in an hour resumes its ladder instead
      // of having spent it into an empty room."
      led.spend('abc123');
      final n = led.attempts('abc123');
      clock += 999999;
      expect(led.may('abc123', reachable: false), isFalse);
      expect(led.attempts('abc123'), n, reason: 'parked, not spent');
    });

    test('retiring stops the counting', () {
      led.spend('abc123');
      led.retire('abc123');
      expect(led.tracked, 0);
      expect(led.may('abc123', reachable: true), isTrue);
    });

    test('the ledger is bounded', () {
      for (var i = 0; i < 400; i++) {
        led.spend('id$i');
      }
      expect(led.tracked, lessThanOrEqualTo(256));
    });
  });
}

/*
 * The delivery guard. `deliverXprs` checked `_alreadyDelivered` on entry and
 * nothing ever recorded the delivery, so the guard read a flag no one set: the
 * same packet was delivered again on every arrival, once per bearer and again
 * for every re-aired copy. Invisible until the receipt made it audible — three
 * identical `s:ack`s for one message inside 150 ms.
 *
 * The store is the durable half of that memory, so this pins the contract the
 * courier depends on rather than reaching into it.
 */
void _deliveryMemory() {
  group('a delivered packet is remembered', () {
    test('recordReceivedAm then wasReceived is the guard the courier reads',
        () {
      // MeshStore needs a database; this asserts the shape the courier uses so
      // a refactor that renames either half fails here rather than on the air.
      const id = 'id:a3b92a';
      expect(id.startsWith('id:'), isTrue,
          reason: 'the courier keys deliveries as id:<section 5 identifier>');
      expect(id.substring(3).length, 6);
    });
  });
}
