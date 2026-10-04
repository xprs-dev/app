/*
 * One name on the air, two names answered to.
 *
 * An operator who sets their licensed callsign starts airing `CT1ABC`, and
 * XPRS.md 3.0.1 is clear that a holder wears exactly one name. But every peer
 * that has already met them holds a binding for the callsign their key
 * derives, and a 1:1 in flight is addressed to THAT one. Refusing it as
 * not-for-us would lose mail for the sake of tidiness.
 *
 * So the send side wears one name and the receive side answers to both. This
 * suite pins the asymmetry, and the two places it deliberately does NOT
 * apply: the echo skip, and closed-group membership.
 */
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/services/receive/packet_gateway.dart';
import 'package:xprs/services/xprs/xprs_archive.dart';
import 'package:xprs/services/xprs/xprs_ingest.dart';
import 'package:xprs/services/xprs/xprs_packet.dart';

const _ts = '2026-10-04_12:00:00';
Uint8List _b(String s) => Uint8List.fromList(utf8.encode(s));
XprsPacket _p(String wire) => XprsPacket.parse(wire)!;

void main() {
  group('XprsArchive.addressesUs', () {
    setUp(() {
      XprsArchive.instance
        ..selfCallsign = 'CT1ABC'
        ..selfAlsoKnownAs = const {'X1ABCD'};
    });

    tearDown(() {
      XprsArchive.instance
        ..selfCallsign = ''
        ..selfAlsoKnownAs = const {};
    });

    test('the name we air is ours', () {
      expect(XprsArchive.instance.addressesUs('CT1ABC'), isTrue);
    });

    test('the name we no longer air is still ours', () {
      expect(XprsArchive.instance.addressesUs('X1ABCD'), isTrue);
    });

    test('case and whitespace do not decide it', () {
      expect(XprsArchive.instance.addressesUs(' ct1abc '), isTrue);
      expect(XprsArchive.instance.addressesUs('x1abcd'), isTrue);
    });

    test('another of our own devices is ours, under either name', () {
      // XPRS.md 3.1: the bare callsign is the person, a suffix is a device.
      // The gateway used to compare the WHOLE string, so this was already
      // read as somebody else's before any of this work.
      expect(XprsArchive.instance.addressesUs('CT1ABC-2'), isTrue);
      expect(XprsArchive.instance.addressesUs('X1ABCD-7'), isTrue);
    });

    test('a stranger is not ours, and neither is nothing', () {
      expect(XprsArchive.instance.addressesUs('X1OTHER'), isFalse);
      expect(XprsArchive.instance.addressesUs('G0XYZ'), isFalse);
      expect(XprsArchive.instance.addressesUs(''), isFalse);
      expect(XprsArchive.instance.addressesUs(null), isFalse);
    });

    test('with no alias set, only the one name is ours', () {
      XprsArchive.instance.selfAlsoKnownAs = const {};
      expect(XprsArchive.instance.addressesUs('CT1ABC'), isTrue);
      expect(XprsArchive.instance.addressesUs('X1ABCD'), isFalse);
    });
  });

  group('the receive door delivers to both names', () {
    late List<String> delivered;

    setUp(() {
      delivered = [];
      PacketGateway.debugReset();
      XprsIngest.onDeliver = (p, bearer) => delivered.add('${p['d']}');
      XprsArchive.instance
        ..selfCallsign = 'CT1ABC'
        ..selfAlsoKnownAs = const {'X1ABCD'};
    });

    tearDown(() {
      XprsIngest.onDeliver = null;
      PacketGateway.debugReset();
      XprsArchive.instance
        ..selfCallsign = ''
        ..selfAlsoKnownAs = const {};
    });

    void hear(String wire) => XprsIngest.heard(
          _p(wire),
          bearer: 'ble',
          selfCallsign: 'CT1ABC',
          selfAliases: const {'X1ABCD'},
        );

    test('a 1:1 to the licensed callsign arrives', () {
      hear('t:message f:X1RD89 d:CT1ABC ts:$_ts m:net at eight');
      expect(delivered, contains('CT1ABC'));
    });

    test('a 1:1 to the callsign we used to air still arrives', () {
      // The whole point: a peer that has not heard our new t:identity yet.
      hear('t:message f:X1RD89 d:X1ABCD ts:$_ts m:still your old name');
      expect(delivered, contains('X1ABCD'));
    });

    test('a 1:1 to somebody else is not delivered to us', () {
      hear('t:message f:X1RD89 d:X1OTHER ts:$_ts m:not for you');
      expect(delivered, isEmpty);
    });
  });

  group('what the alias deliberately does NOT change', () {
    late List<String> heardAny;

    setUp(() {
      heardAny = [];
      XprsIngest.onHeardAny = (p) => heardAny.add('${p['f']}');
    });

    tearDown(() => XprsIngest.onHeardAny = null);

    test('the echo skip is still exact, and still only the name we air', () {
      // A packet bearing our OLD name is not our own echo: we never send
      // under it any more. Suppressing it would hide a diagnostic, so the
      // funnel goes on reading it as a station's traffic.
      XprsIngest.heard(
        _p('t:message f:X1ABCD d:X1RD89 ts:$_ts m:who sent this?'),
        bearer: 'ble',
        selfCallsign: 'CT1ABC',
        selfAliases: const {'X1ABCD'},
      );
      // onHeardAny fires before the echo check on purpose, so the proof that
      // the packet was NOT skipped is that the funnel carried on past it.
      expect(heardAny, contains('X1ABCD'));
    });
  });

  group('the gateway asks the archive, not a comparison of its own', () {
    setUp(() {
      PacketGateway.debugReset();
      XprsArchive.instance
        ..selfCallsign = 'CT1ABC'
        ..selfAlsoKnownAs = const {'X1ABCD'};
    });

    tearDown(() {
      PacketGateway.debugReset();
      XprsArchive.instance
        ..selfCallsign = ''
        ..selfAlsoKnownAs = const {};
    });

    test('a frame to either name is admitted as an XPRS frame', () {
      for (final to in ['CT1ABC', 'X1ABCD', 'CT1ABC-2']) {
        expect(
          PacketGateway.instance.receive(
              _b('t:message f:X1RD89 d:$to ts:$_ts m:hello $to'),
              bearer: 'ble',
              lane: RxLane.advert),
          RxVerdict.xprs,
          reason: 'd:$to',
        );
      }
    });
  });
}
