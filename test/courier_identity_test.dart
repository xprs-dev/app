/*
 * A carried message keeps its identity.
 *
 * The defect this file exists for: `sendLxmf` arms the courier with whatever
 * it was asked to send, and on the publisher's path that is a FINISHED XPRS
 * wire -- one per part, because `_ReticulumBearer` is called per part. The
 * courier sealed each of those as the BODY of a fresh `t:message`, so one
 * 3-part message became nine or more on the air, each with fresh ciphertext,
 * a fresh timestamp, and therefore a fresh section 5 identifier.
 *
 * Measured on the bench 2026-09-01: 40 logical messages produced 394 packets
 * carrying 394 distinct identifiers and zero correlation ids. A `t:receipt`
 * names one identifier, so an acknowledgement released one copy of thirty --
 * custody could never drain, the store overflowed, and the row cap shed real
 * mail (1129 purged against 351 delivered).
 *
 * Section 31.1: a retry is not a new packet. Neither is a carried copy.
 */
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/services/mesh/mesh_courier.dart';
import 'package:xprs/services/xprs/xprs_body.dart';
import 'package:xprs/services/xprs/xprs_id.dart';
import 'package:xprs/services/xprs/xprs_packet.dart';

const _ts = '2026-09-01_12:00:00';

void main() {
  // Arming starts a five-second pump that ends in `_air` and reaches for the
  // radio. Left running it outlives the test that made it, which is exactly
  // the intermittent failure this suite produced in a full run.
  tearDown(MeshCourier.instance.debugReset);

  group('one message, one arming', () {
    test('the same send armed twice is armed once', () {
      // sendLxmf arms twice for a single send: eagerly when it can hear the
      // recipient's radio, and unconditionally at the end. Both carry the
      // same text, and on the plaintext path each arming sealed it again --
      // fresh nonce, fresh timestamp, two identifiers for one message.
      final before = MeshCourierCounters.armed;
      const dest = '0f0871bcf47e4b9d896ed1969cd4dd87';
      MeshCourier.instance
          .armLxmf(destHex: dest, text: 'am:a1b2c3 hello', waitFirst: false);
      MeshCourier.instance.armLxmf(destHex: dest, text: 'am:a1b2c3 hello');
      expect(MeshCourierCounters.armed - before, 1,
          reason: 'the second arming is the same message, not a new one');
    });

    test('genuinely different messages still each arm', () {
      final before = MeshCourierCounters.armed;
      const dest = '0f0871bcf47e4b9d896ed1969cd4dd87';
      MeshCourier.instance.armLxmf(destHex: dest, text: 'am:111111 first');
      MeshCourier.instance.armLxmf(destHex: dest, text: 'am:222222 second');
      expect(MeshCourierCounters.armed - before, 2);
    });
  });

  group('what the courier carries unchanged', () {
    test('a finished 1:1 keeps its exact bytes AND its identifier', () {
      const wire = 't:message f:X1QZ3N d:X1RD89 ts:$_ts m:hello there';
      final carried = MeshCourier.carriableAsIs(wire);

      expect(carried, isNotNull, reason: 'a finished packet must be carried');
      expect(utf8.decode(carried!.bytes), wire,
          reason: 'byte-for-byte, or the identifier moves under it');
      expect(carried.to, 'X1RD89');
      expect(carried.sealed, isFalse);

      // The property the whole defect turned on.
      expect(xprsIdentifier(XprsPacket.parse(utf8.decode(carried.bytes))!),
          xprsIdentifier(XprsPacket.parse(wire)!),
          reason: 'carrying must not rename the message');
    });

    test('a sealed part is carried sealed, and is still one packet', () {
      const wire =
          't:message f:X1QZ3N d:X1RD89 ts:$_ts n:1/3 x:AAAABBBBCCCC';
      final carried = MeshCourier.carriableAsIs(wire);
      expect(carried, isNotNull);
      expect(carried!.sealed, isTrue);
      expect(utf8.decode(carried.bytes), wire);
    });

    test("a person's words are NOT a packet and must still be built", () {
      // The chat wapp's own path: `am:<6hex> <text>`, not a wire.
      expect(MeshCourier.carriableAsIs('am:a1b2c3 hello there'), isNull);
      expect(MeshCourier.carriableAsIs('just some words'), isNull);
      expect(MeshCourier.carriableAsIs(''), isNull);
    });

    test('a group post is aired, not couriered (6.3)', () {
      expect(
        MeshCourier.carriableAsIs(
            't:message f:X1QZ3N d:#LOCAL ts:$_ts m:hello room'),
        isNull,
      );
      expect(
        MeshCourier.carriableAsIs(
            't:message f:X1QZ3N d:X5AJKG ts:$_ts m:hello group'),
        isNull,
      );
    });

    test('only a message is custody material', () {
      expect(
        MeshCourier.carriableAsIs('t:status f:X1QZ3N ts:$_ts m:on the hill'),
        isNull,
      );
      expect(
        MeshCourier.carriableAsIs(
            't:command f:X1QZ3N d:X1RD89 ts:$_ts cmd:history'),
        isNull,
      );
    });

    test('re-authoring is what broke it, and still would', () {
      // This is the old behaviour, kept as a demonstration rather than a
      // description: seal a finished wire as the BODY of a new t:message,
      // exactly as `_air` used to, and watch the identifier move. Two calls
      // a second apart -- or two parts of one message -- produced two
      // identifiers for one thing somebody said once.
      const wire = 't:message f:X1QZ3N d:X1RD89 ts:$_ts m:hello there';
      final original = xprsIdentifier(XprsPacket.parse(wire)!);

      XprsPacket rewrapped(String stamp) {
        final built = xprsBuildDirect(
          head: XprsPacket.parse('t:message f:X1QZ3N d:X1RD89 ts:$stamp')!,
          text: wire,
          private: false,
        );
        expect(built.ok, isTrue);
        return built.packets.first;
      }

      final a = xprsIdentifier(rewrapped('2026-09-01_12:00:01'));
      final b = xprsIdentifier(rewrapped('2026-09-01_12:00:02'));

      expect(a, isNot(original),
          reason: 'wrapping renamed the message the sender already made');
      expect(a, isNot(b),
          reason: 'and renamed it again on the next attempt -- which is how '
              '40 messages became 394 identifiers');

      // What the courier does now.
      final carried = MeshCourier.carriableAsIs(wire)!;
      expect(xprsIdentifier(XprsPacket.parse(utf8.decode(carried.bytes))!),
          original);
    });

    test('surrounding whitespace does not make it a different packet', () {
      const wire = 't:message f:X1QZ3N d:X1RD89 ts:$_ts m:hello';
      final a = MeshCourier.carriableAsIs(wire)!;
      final b = MeshCourier.carriableAsIs('  $wire\n')!;
      expect(utf8.decode(a.bytes), utf8.decode(b.bytes));
    });
  });
}
