/*
 * When a 1:1 may skip the air and go point to point (docs/ble5.md §9).
 *
 * The advert window is five seconds a minute shared by every registered frame,
 * so a 1:1 broadcast to the whole street is airtime taken from the street. It
 * may be suppressed ONLY for a peer we can dial right now AND that told us, in
 * its own MSP HELLO, that it takes custody of messages.
 *
 * The previous version of this gate asked `MeshTable.neighbors` for a device
 * class and a bidirectional flag. Both look right; both are structurally
 * absent, because the table is fed only by the 0x4D mesh beacon and a phone
 * deliberately airs none. Those tests passed against a feature that was dead on
 * hardware — so these ones assert on the signal that is actually transmitted,
 * and are mostly about what must NOT be suppressed.
 */
import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/services/mesh/mesh_custody.dart';
import 'package:xprs/services/mesh/mesh_session.dart';

/// What a phone offers: msgCustody | bulkRx | bulkTx | gossip — the `caps=0xf`
/// observed from X3ARK on the bench (docs/ble5.md §9.1).
const int kPhoneCaps = MspCaps.msgCustody |
    MspCaps.bulkRx |
    MspCaps.bulkTx |
    MspCaps.gossip;

void main() {
  group('a 1:1 may go point to point', () {
    test('to a peer we can dial that offered msgCustody', () {
      expect(
          MeshCustodyDelegate.pointToPointOk(
              dialableNow: true, peerCaps: kPhoneCaps),
          isTrue);
    });

    test('msgCustody alone is enough — the bulk lane is a separate question',
        () {
      expect(
          MeshCustodyDelegate.pointToPointOk(
              dialableNow: true, peerCaps: MspCaps.msgCustody),
          isTrue);
    });
  });

  group('and must NOT, for anything else', () {
    test('a peer we have never held a session with', () {
      // No HELLO, no caps. The FIRST 1:1 to a peer is always aired; the session
      // it provokes records the caps and the next one goes direct. Suppressing
      // on a guess costs two minutes of silence.
      expect(
          MeshCustodyDelegate.pointToPointOk(dialableNow: true, peerCaps: 0),
          isFalse);
    });

    test('a peer whose caps do not include msgCustody', () {
      // An ESP32 excludes itself here: a dongle goes deaf during an MSP session
      // and relaying is what dongles are FOR, so it needs to overhear the
      // broadcast. No device-class byte is required to reach that conclusion.
      const dongle = MspCaps.bulkRx | MspCaps.bulkTx;
      expect(
          MeshCustodyDelegate.pointToPointOk(
              dialableNow: true, peerCaps: dongle),
          isFalse);
    });

    test('a peer that has gone stale in the dial registry', () {
      // It offered custody once; it is not in range now. The radio has moved on
      // and the message must take its chances on the air.
      expect(
          MeshCustodyDelegate.pointToPointOk(
              dialableNow: false, peerCaps: kPhoneCaps),
          isFalse);
    });

    test('a peer that is neither dialable nor known', () {
      expect(
          MeshCustodyDelegate.pointToPointOk(dialableNow: false, peerCaps: 0),
          isFalse);
    });

    test('gossip-only caps — a peer that swaps tables but takes no mail', () {
      expect(
          MeshCustodyDelegate.pointToPointOk(
              dialableNow: true, peerCaps: MspCaps.gossip),
          isFalse);
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
