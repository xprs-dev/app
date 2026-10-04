/*
 * A callsign is carried whole or not at all.
 *
 * MSP's writer used to truncate a callsign to nine characters in silence, on
 * the HELLO and on every carried-mail envelope. A truncated callsign is not a
 * shortened name, it is a different station: CT1ABC/PORT went out as
 * CT1ABC/PO, which nobody holds, and the peer filed our mail under it.
 */
import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/services/mesh/mesh_beacon.dart';
import 'package:xprs/services/mesh/mesh_session.dart';
import 'package:xprs/services/xprs/xprs_callsign.dart';

void main() {
  test('MSP carries the same width as everything else in XPRS', () {
    expect(kMspMaxCallsign, kXprsMaxCallsignChars);
    expect(kMeshMaxCallsign, kXprsMaxCallsignChars);
  });

  group('the MSP HELLO', () {
    MspHello? roundTrip(String call) {
      final f = MspHello(caps: 0, callsign: call, maxFrame: 240).encode();
      final m = mspDecode(f);
      return m is MspHello ? m : null;
    }

    test('a licensed callsign wider than the old nine-byte ceiling survives',
        () {
      // CT1ABC-9/P is ten characters: it was truncated to CT1ABC-9/ before.
      expect(roundTrip('CT1ABC-9/P')?.callsign, 'CT1ABC-9/P');
      expect(roundTrip('CT1ABC/PORT')?.callsign, 'CT1ABC/PORT');
    });

    test('a derived callsign still round-trips, as it always did', () {
      expect(roundTrip('X1ABCD')?.callsign, 'X1ABCD');
      expect(roundTrip('X1ABCD-2')?.callsign, 'X1ABCD-2');
    });

    test('one too wide is REFUSED, not sent under a truncated name', () {
      // 16 characters. The writer emits a zero-length field, so the HELLO
      // fails its own decode check rather than naming a station nobody is.
      expect(roundTrip('ABCDEFGHIJKLMNOP'), isNull);
    });
  });

  group('the mesh beacon', () {
    test('a wide callsign produces no frame rather than a wrong one', () {
      final b = MeshBeacon(
        callsign: 'ABCDEFGHIJKLMNOP',
        deviceClass: MeshDeviceClass.other,
        cond: const MeshConditions(),
      );
      expect(b.encode(), isEmpty);
      expect(MeshBeacon.decode(b.encode()), isNull);
    });

    test('a callsign at the new ceiling round-trips', () {
      final b = MeshBeacon(
        callsign: 'CT1ABC/PORT',
        deviceClass: MeshDeviceClass.other,
        cond: const MeshConditions(),
      );
      expect(MeshBeacon.decode(b.encode())?.callsign, 'CT1ABC/PORT');
    });
  });
}
