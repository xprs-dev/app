/*
 * When a 1:1 may skip the air and go point to point (docs/ble5.md §9).
 *
 * The advert window is five seconds a minute shared by every registered frame,
 * so a 1:1 broadcast to the whole street is airtime taken from the street. It
 * may be suppressed ONLY for a peer we hear ourselves, both ways, right now,
 * and only for a device that can hold a GATT session. Every other case keeps
 * the broadcast — getting this wrong costs 120 s of silence, so the tests are
 * about what must NOT be suppressed.
 */
import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/services/mesh/mesh_beacon.dart';
import 'package:xprs/services/mesh/mesh_custody.dart';
import 'package:xprs/services/mesh/mesh_table.dart';

MeshBeacon _beacon(
  String cs, {
  MeshDeviceClass cls = MeshDeviceClass.phone,
  List<MeshDvEntry> dv = const [],
}) =>
    MeshBeacon(
      callsign: cs,
      deviceClass: cls,
      cond: const MeshConditions(
          powered: false, uptimeBucket: 0, mobility: MeshMobility.unknown),
      dv: dv,
    );

/// A neighbour that lists ME at cost 1 — i.e. it hears us too.
MeshNeighbor? _twoWay(String cs, MeshDeviceClass cls) {
  final t = MeshTable('ME');
  t.ingest(_beacon(cs, cls: cls, dv: [MeshDvEntry(meshHash('ME'), 1)]));
  return t.neighbors[cs];
}

/// A neighbour we hear, that does not list us: a one-way link.
MeshNeighbor? _oneWay(String cs, MeshDeviceClass cls) {
  final t = MeshTable('ME');
  t.ingest(_beacon(cs, cls: cls));
  return t.neighbors[cs];
}

void main() {
  final now = DateTime.now();

  group('a 1:1 may go point to point', () {
    test('to a phone that hears us back', () {
      expect(
          MeshCustodyDelegate.pointToPointOk(
              _twoWay('PHONE', MeshDeviceClass.phone), now),
          isTrue);
    });

    test('to a tablet that hears us back', () {
      expect(
          MeshCustodyDelegate.pointToPointOk(
              _twoWay('TAB', MeshDeviceClass.tablet), now),
          isTrue);
    });
  });

  group('and must NOT, for anything else', () {
    test('an ESP32 keeps the broadcast — relaying is what it is for', () {
      // A dongle cannot scan and advertise at the same time, and it has to
      // OVERHEAR a frame to carry it. Suppressing the air for a dongle removes
      // the reason it is on the street.
      expect(
          MeshCustodyDelegate.pointToPointOk(
              _twoWay('DONGLE', MeshDeviceClass.esp32), now),
          isFalse);
    });

    test('a desktop keeps the broadcast until its BLE duty cycle is proven', () {
      expect(
          MeshCustodyDelegate.pointToPointOk(
              _twoWay('DESK', MeshDeviceClass.computer), now),
          isFalse);
    });

    test('a router and a base station keep the broadcast', () {
      for (final c in [MeshDeviceClass.router, MeshDeviceClass.baseStation]) {
        expect(MeshCustodyDelegate.pointToPointOk(_twoWay('INFRA', c), now),
            isFalse,
            reason: '$c must keep relaying');
      }
    });

    test('a ONE-WAY neighbour is a black hole, however loudly we hear it', () {
      // We hear them; nothing says they hear us. A suppressed broadcast would
      // be a message sent into a hole with nobody else holding a copy.
      expect(
          MeshCustodyDelegate.pointToPointOk(
              _oneWay('DEAF', MeshDeviceClass.phone), now),
          isFalse);
    });

    test('a neighbour that has gone quiet past the TTL', () {
      final n = _twoWay('GONE', MeshDeviceClass.phone);
      // kNeighborTtl past its last beacon: still in the table, not reachable.
      final later = now.add(kNeighborTtl).add(const Duration(seconds: 1));
      expect(MeshCustodyDelegate.pointToPointOk(n, later), isFalse);
    });

    test('a peer we have no neighbour record for at all', () {
      expect(MeshCustodyDelegate.pointToPointOk(null, now), isFalse);
    });
  });

  group('the fallback deadline', () {
    test('is longer than the scheduler is allowed to spend on one dial', () {
      // A dial alone gets 110 s in the scheduler, so a shorter deadline would
      // re-air a message that is still being delivered.
      expect(MeshCustodyDelegate.suppressedGrace.inSeconds, greaterThan(110));
    });
  });
}
