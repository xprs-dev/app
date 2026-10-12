/*
 * THREE ROOMS, from the core's side (XPRS.md 9.11).
 *
 * `scope:` names a class of bearers, and a scope binds at both ends of every
 * hop: a station sends a packet only on a bearer its scope admits, and passes
 * on only a packet it HEARD on one. Local is Bluetooth, ESP-NOW and the LAN;
 * regional adds LoRa, HaLow and radio; global is the internet and satellites.
 * A packet that came from wider than its scope is out of range: kept, never
 * passed on, filed in no room.
 */
import 'package:flutter_test/flutter_test.dart';

import 'package:xprs/services/xprs/xprs_airtime.dart';
import 'package:xprs/services/xprs/xprs_bridge.dart';
import 'package:xprs/services/xprs/xprs_packet.dart';
import 'package:xprs/services/xprs/xprs_publisher.dart';
import 'package:xprs/services/xprs/xprs_send.dart';
import 'package:xprs/services/xprs/xprs_vocab.dart';

const _ts = '2026-10-12_20:00:00';
XprsPacket _p(String w) => XprsPacket.parse(w)!;

class _FakeBearer implements XprsBearer {
  _FakeBearer(this.name, {required this.shortRange});
  @override
  final String name;
  @override
  String get archiveBearer => name;
  @override
  final bool shortRange;
  final List<String> sent = [];
  @override
  Future<bool> get active async => true;
  @override
  Future<XprsSendResult> send(String wire,
      {required int part,
      String slot = 'status',
      Duration? ttl,
      bool datagram = false,
      bool verbatim = false}) async {
    sent.add(wire);
    return XprsSendResult.sent;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the classes', () {
    test('every scope word has a reach, and an unknown one has none', () {
      expect(xprsScopeReach(_p('t:message f:A ts:$_ts m:x')), XprsReach.global);
      expect(xprsScopeReach(_p('t:message f:A ts:$_ts scope:global m:x')),
          XprsReach.global);
      expect(xprsScopeReach(_p('t:message f:A ts:$_ts scope:regional m:x')),
          XprsReach.regional);
      expect(xprsScopeReach(_p('t:message f:A ts:$_ts scope:local m:x')),
          XprsReach.local);
      expect(xprsScopeReach(_p('t:warning f:A ts:$_ts scope:PT,ES m:x')),
          XprsReach.global, reason: 'a country is global by class');
      expect(xprsScopeReach(_p('t:message f:A ts:$_ts scope:valley m:x')),
          isNull, reason: '9.11: read, never relayed');
    });

    test('bearers fall into the three classes', () {
      for (final b in ['ble', 'ble5', 'wifi', 'espnow', 'lan']) {
        expect(xprsBearerReach(b), XprsReach.local, reason: b);
      }
      for (final b in ['lora', 'halow', 'vhf', 'uhf', 'hf', 'cb', 'pmr']) {
        expect(xprsBearerReach(b), XprsReach.regional, reason: b);
      }
      for (final b in ['internet', 'satellite', 'rns', 'reticulum', 'other']) {
        expect(xprsBearerReach(b), XprsReach.global, reason: b);
      }
    });

    test('a scope admits its own class and every narrower one', () {
      expect(xprsReachAdmits(XprsReach.regional, XprsReach.local), isTrue);
      expect(xprsReachAdmits(XprsReach.regional, XprsReach.regional), isTrue);
      expect(xprsReachAdmits(XprsReach.regional, XprsReach.global), isFalse);
      expect(xprsReachAdmits(XprsReach.local, XprsReach.regional), isFalse);
      expect(xprsReachAdmits(null, XprsReach.local), isFalse);
    });

    test('local and unknown are not carried; regional is', () {
      expect(xprsMayCarry(_p('t:message f:A ts:$_ts scope:local m:x')), isFalse);
      expect(xprsMayCarry(_p('t:message f:A ts:$_ts scope:valley m:x')), isFalse);
      expect(xprsMayCarry(_p('t:message f:A ts:$_ts scope:regional m:x')), isTrue);
    });

    test('a broadcast may ask for regional', () {
      expect(XprsSend.scopeOk('regional'), isTrue);
      expect(XprsSend.scopeOk('valley'), isFalse);
    });
  });

  group('sending', () {
    late _FakeBearer ble, lan, lora, rns;
    setUp(() {
      ble = _FakeBearer('ble5', shortRange: true);
      lan = _FakeBearer('lan', shortRange: true);
      lora = _FakeBearer('lora', shortRange: false);
      rns = _FakeBearer('reticulum', shortRange: false);
      XprsPublisher.instance.bearers = [ble, lan, lora, rns];
      // Each test is a fresh station: the silence LoRa owes for the last
      // test's airing (31.1) is not this one's.
      XprsAirtime.instance.reset();
    });

    test('regional goes on the air and never onto the internet', () async {
      final r = await XprsPublisher.instance.publishWire(
          't:message f:X1VCVM ts:$_ts scope:regional m:road flooded');
      expect(r['ble5'], 'sent');
      expect(r['lan'], 'sent');
      expect(r['lora'], 'sent');
      expect(r['reticulum'], 'scope');
      expect(rns.sent, isEmpty);
    });

    test('local stays off LoRa now that LoRa is regional', () async {
      final r = await XprsPublisher.instance.publishWire(
          't:message f:X1VCVM ts:$_ts scope:local m:the room');
      expect(r['ble5'], 'sent');
      expect(r['lora'], 'scope');
      expect(r['reticulum'], 'scope');
    });

    test('an unknown scope word goes nowhere', () async {
      final r = await XprsPublisher.instance.publishWire(
          't:message f:X1VCVM ts:$_ts scope:valley m:x');
      expect(r.values.toSet(), {'scope'});
    });

    test('global goes everywhere', () async {
      await XprsPublisher.instance
          .publishWire('t:message f:X1VCVM ts:$_ts m:hello everyone');
      expect(rns.sent, hasLength(1));
      expect(lora.sent, hasLength(1));
    });
  });

  group('passing on what was heard', () {
    late List<String> lanes;
    setUp(() {
      XprsBridge.debugReset();
      lanes = [];
      XprsBridge.instance.relayable =
          (w) => XprsPacket.parse(w)?.with_('via', 'X1SELF').encode();
      XprsBridge.instance.air = (w, lane) async {
        lanes.add(lane);
        return true;
      };
    });
    tearDown(XprsBridge.debugReset);

    Future<void> heard(String wire, String bearer) async {
      XprsBridge.instance.heard(_p(wire), wire, bearer);
      await Future<void>.delayed(Duration.zero);
    }

    test('a local packet off Reticulum has left its range', () async {
      await heard('t:message f:X1QZ3N ts:$_ts scope:local m:hi', 'rns');
      expect(lanes, isEmpty);
      expect(XprsBridge.outOfRange, 1);
    });

    test('a regional packet off Reticulum has too', () async {
      await heard('t:message f:X1QZ3N ts:$_ts scope:regional m:hi', 'rns');
      expect(lanes, isEmpty);
    });

    test('a regional packet heard on BLE crosses to the LAN', () async {
      await heard('t:message f:X1QZ3N ts:$_ts scope:regional m:hi', 'ble5');
      expect(lanes, ['lan']);
    });

    test('a global packet off Reticulum is still global', () async {
      // The bridge case 9.11 names: arriving from afar does not make it
      // local, and re-airing it on BLE does not change its room.
      await heard('t:message f:X1QZ3N ts:$_ts m:hi', 'rns');
      expect(lanes, containsAll(['ble', 'lan']));
    });
  });
}
