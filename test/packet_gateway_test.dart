/*
 * The one door, and the proof that every bearer goes through it.
 *
 * This suite exists because of a gap the architecture guard cannot close. The
 * guard matches lines that EXIST -- it can refuse a transport that reaches
 * past the door, and does. It cannot see a transport that simply never calls
 * the door at all, because absence matches nothing. That is precisely how
 * four lanes came to deliver to a person without the core seeing the packet,
 * and no test anywhere drove a transport and asserted where the frame landed.
 *
 * So: the demux truth table, every bearer through the door, and a regression
 * test for the defect the door fixed on the way in -- an XPRS 1:1 arriving
 * over Reticulum used to be archived and never delivered (docs/message-receive.md).
 */
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/services/receive/packet_gateway.dart';
import 'package:xprs/services/xprs/xprs_archive.dart';
import 'package:xprs/services/xprs/xprs_ingest.dart';

const _ts = '2026-09-01_12:00:00';
Uint8List _b(String s) => Uint8List.fromList(utf8.encode(s));

void main() {
  late List<String> carried;
  late List<String> delivered;
  late List<String> seen;

  setUp(() {
    carried = [];
    delivered = [];
    seen = [];
    PacketGateway.debugReset();
    XprsIngest.onCarry = (wire, target) => carried.add(target);
    XprsIngest.onDeliver = (p, bearer) => delivered.add('$bearer|${p['f']}');
    PacketGateway.onFrame = (bearer, lane, v) => seen.add('$bearer|${v.name}');
    XprsArchive.instance.selfCallsign = 'X1SELF';
  });

  tearDown(() {
    XprsIngest.onCarry = null;
    XprsIngest.onDeliver = null;
    PacketGateway.debugReset();
  });

  group('the demux, which was written out at nine call sites', () {
    test('an XPRS wire is recognised and reaches the funnel', () {
      final v = PacketGateway.instance.receive(
        _b('t:message f:X1QZ3N d:X1RD89 ts:$_ts m:carry me'),
        bearer: 'ble',
        lane: RxLane.advert,
      );
      expect(v, RxVerdict.xprs);
      expect(carried, ['X1RD89'],
          reason: 'the packet must reach XprsIngest, not just be counted');
      expect(PacketGateway.xprsFrames, 1);
    });

    test('a legacy compact frame is not mistaken for XPRS', () {
      final v = PacketGateway.instance.receive(
        Uint8List.fromList([...utf8.encode('X1QZ3N'), 0x1F,
          ...utf8.encode('X1RD89'), 0x1F, ...utf8.encode('hello')]),
        bearer: 'ble',
        lane: RxLane.advert,
      );
      expect(v, RxVerdict.compact);
      expect(PacketGateway.compactFrames, 1);
    });

    test('leftovers on a CONNECTION belong to the parcel reassembler', () {
      // The caller feeds its queue on this verdict and the reassembled result
      // comes back through the door. Before, a reassembled parcel went to the
      // wapp stream and nowhere else.
      final v = PacketGateway.instance.receive(_b('not a packet'),
          bearer: 'ble', lane: RxLane.session, peer: 'aa:bb');
      expect(v, RxVerdict.parcel);
    });

    test('junk on a BROADCAST is ignored, not swept into custody', () {
      // It used to be: anything XprsPacket.parse rejected went to the custody
      // tap as though it were a compact frame.
      final v = PacketGateway.instance.receive(_b('not a packet'),
          bearer: 'ble', lane: RxLane.advert);
      expect(v, RxVerdict.ignored);
      expect(PacketGateway.compactFrames, 0);
    });

    test('an empty frame is ignored rather than parsed', () {
      expect(
        PacketGateway.instance
            .receive(Uint8List(0), bearer: 'ble', lane: RxLane.advert),
        RxVerdict.ignored,
      );
    });
  });

  group('every bearer goes through the same door', () {
    // LoRa and ESPNow have no receive path on this device today -- both are
    // bearer labels only -- so a packet of theirs arrives relayed and enters
    // as one of the others. They are exercised anyway: the door must not care
    // which radio it was, and the day one ships, this is the test that says so.
    for (final bearer in ['ble', 'lan', 'lora', 'espnow', 'wifi']) {
      test('a 1:1 for somebody else, heard on $bearer, is offered for carry',
          () {
        PacketGateway.instance.receive(
          _b('t:message f:X1QZ3N d:X1RD89 ts:$_ts m:carry me'),
          bearer: bearer,
          lane: RxLane.advert,
        );
        expect(carried, ['X1RD89'], reason: 'not carried on $bearer');
        expect(seen.single, '$bearer|xprs',
            reason: 'the door must record the bearer it arrived on');
      });
    }
  });

  group('the Reticulum lane', () {
    test('a 1:1 addressed to us is DELIVERED, not just archived', () {
      // The defect: this lane archived a message addressed to us and stopped,
      // because `onDeliver` was wired on the radio lane and had no counterpart
      // here at all. No log line, no counter -- the message was on the device,
      // in the spool, and never shown to anybody.
      PacketGateway.instance.receiveInternet(
        'hub',
        _b('t:message f:X1QZ3N d:X1SELF ts:$_ts m:for me'),
      );
      expect(delivered, hasLength(1),
          reason: 'a message over Reticulum must reach a person');
      expect(delivered.single, endsWith('|X1QZ3N'));
    });

    test('a group post it keeps is still not delivered as correspondence', () {
      // `concernsUs` keeps a group post; `xprsRendersToPerson` is what decides
      // whether it is somebody writing TO US. Conflating the two turned every
      // group message into a private thread keyed on the sender.
      PacketGateway.instance.receiveInternet(
        'hub',
        _b('t:message f:X1QZ3N d:#LOCAL ts:$_ts m:hello room'),
      );
      expect(delivered, isEmpty);
    });
  });
}
