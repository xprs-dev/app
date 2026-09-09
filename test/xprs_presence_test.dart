/*
 * The one rule, as a table.
 *
 * Written first, because the defect it replaces was three rules disagreeing:
 * the graph counted a node XPRS if it announced anything but LXMF, the stored
 * stat used a rule that differed by one word ('node'), and the header counted
 * callsign prefixes over whatever happened to be on the canvas. The screen
 * said 715 XPRS devices on a network of six, and listed a bare Reticulum hash
 * as a person you could Follow.
 */
import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/services/xprs/xprs_presence.dart';
import 'package:xprs/util/nostr_crypto.dart';

void main() {
  // A real key and the callsign it can produce, so the verification path is
  // exercised rather than mocked.
  final kp = NostrCrypto.generateKeyPair();
  final pub = NostrCrypto.derivePublicKey(kp.privateKeyHex);
  final mine = NostrCrypto.deriveCallsign(pub);
  final ownCall = 'X1$mine'.toUpperCase().substring(0, 6);

  group('who we are entitled to name', () {
    test('a station heard on the air needs no key — most have none', () {
      final d = classifyXprs(const XprsCandidate(
        announcedCallsign: 'X3DCK0',
        heardOnAir: true,
        airBearers: ['lan'],
        reachableOnAir: true,
      ))!;
      expect(d.callsign, 'X3DCK0');
      expect(d.kind, XprsKind.station);
      expect(d.fixed, isTrue);
      expect(d.evidence, XprsEvidence.air);
      expect(d.bearers, ['lan']);
      expect(d.reachable, isTrue);
    });

    test('a station heard over Reticulum is a device the screen never showed',
        () {
      // graphSnapshot only ever walked the air-heard table, so a station whose
      // packets came over the hubs was invisible — the exact population the
      // Mesh screen is supposed to include.
      final d = classifyXprs(const XprsCandidate(
        announcedCallsign: 'X1WATT',
        heardOverRns: true,
        rnsPathHeld: true,
      ))!;
      expect(d.evidence, XprsEvidence.remoteWire);
      expect(d.bearers, ['rns']);
      expect(d.reachable, isTrue);
    });

    test('an announce verified against its own key is believed', () {
      final d = classifyXprs(XprsCandidate(
        announcedCallsign: ownCall,
        nostrPubHex: pub,
        announceFresh: true,
        announceBearer: 'rns',
        services: const {'chat'},
      ))!;
      expect(d.callsign, ownCall);
      expect(d.evidence, XprsEvidence.announceVerified);
    });

    test('a name that does NOT match the key that announced it is nobody', () {
      expect(
          classifyXprs(XprsCandidate(
            announcedCallsign: 'X1FAKE',
            nostrPubHex: pub,
            services: const {'chat'},
            announceFresh: true,
          )),
          isNull);
    });

    test('a node that announced our service with a key is named BY that key',
        () {
      // Most XPRS devices arrive this way: a relay announce with a key and no
      // text. The name is arithmetic on the key, so nothing is claimed.
      final d = classifyXprs(XprsCandidate(
        derivedCallsign: ownCall,
        nostrPubHex: pub,
        services: const {'relay'},
        announceFresh: true,
        announceBearer: 'rns',
      ))!;
      expect(d.callsign, ownCall);
      expect(d.evidence, XprsEvidence.announceVerified);
    });

    test('but a key with no XPRS service of ours names nobody', () {
      expect(
          classifyXprs(XprsCandidate(
            derivedCallsign: ownCall,
            nostrPubHex: pub,
            services: const {'lxmf'},
            announceFresh: true,
          )),
          isNull);
    });

    test('a beacon that gave its callsign and its address together is trusted',
        () {
      final d = classifyXprs(const XprsCandidate(
        pairedCallsign: 'X2SHIP',
        announceBearer: 'lan',
        announceFresh: true,
      ))!;
      expect(d.evidence, XprsEvidence.beaconPairing);
      expect(d.kind, XprsKind.station);
      expect(d.fixed, isFalse, reason: 'X2 moves');
    });
  });

  group('what is not a device', () {
    test('a device suffix does not split one operator into two', () {
      // Guards the merge key: X1ARKL and X1ARKL-2 are one person's devices and
      // the header counts people, not radios.
      final a = classifyXprs(
          const XprsCandidate(announcedCallsign: 'X1ARKL', heardOnAir: true))!;
      final b = classifyXprs(const XprsCandidate(
          announcedCallsign: 'X1ARKL-2', heardOnAir: true))!;
      expect(a.callsign, b.callsign);
    });

    test('THE REPORTED FAULT: an XPRS service with no name is not a device',
        () {
      // `724d76c1` on the bench: announced on a hash we associate with an XPRS
      // service, no callsign, and the screen made it a person with a Follow
      // and a Chat button.
      expect(
          classifyXprs(const XprsCandidate(
            identityHex: '724d76c1',
            services: {'chat', 'files'},
            announceFresh: true,
            announceBearer: 'rns',
          )),
          isNull);
    });

    test('an LXMF or NomadNet node is somebody else\'s network', () {
      for (final svc in [
        {'lxmf'},
        {'lxmf', 'lxmf-prop'},
        {'node'},
        {'rv'},
      ]) {
        expect(
            classifyXprs(XprsCandidate(
              announcedCallsign: 'Some Name',
              services: svc,
              announceFresh: true,
            )),
            isNull,
            reason: '$svc');
      }
    });

    test('a closed group is an address, not a device', () {
      expect(
          classifyXprs(const XprsCandidate(
            announcedCallsign: 'X5A3F2',
            heardOnAir: true,
          )),
          isNull);
    });

    test('a name that is not callsign-shaped names nothing', () {
      expect(
          classifyXprs(const XprsCandidate(
            announcedCallsign: 'Sideband User',
            services: {'chat'},
            announceFresh: true,
          )),
          isNull);
    });
  });

  group('kind, from the callsign and nothing else', () {
    test('X1 is a person, X2/X3 are stations, X4 is equipment', () {
      XprsDevice of(String c) =>
          classifyXprs(XprsCandidate(announcedCallsign: c, heardOnAir: true))!;
      expect(of('X1ARKL').kind, XprsKind.user);
      expect(of('X2SHIP').kind, XprsKind.station);
      expect(of('X2SHIP').fixed, isFalse);
      expect(of('X3MAST').kind, XprsKind.station);
      expect(of('X3MAST').fixed, isTrue);
      expect(of('X4PUMP').kind, XprsKind.device);
      expect(of('X1ARKL').kindWord, 'user');
    });

    test('a device suffix is the same device (3.1.3)', () {
      final d = classifyXprs(const XprsCandidate(
          announcedCallsign: 'X1ARKL-2', heardOnAir: true))!;
      expect(d.callsign, 'X1ARKL', reason: 'one operator, not two rows');
    });
  });

  group('how it is reached', () {
    test('the air bearers come first and Reticulum last', () {
      final d = classifyXprs(const XprsCandidate(
        announcedCallsign: 'X1VCVM',
        heardOnAir: true,
        airBearers: ['ble', 'lan'],
        rnsPathHeld: true,
        reachableOnAir: true,
      ))!;
      expect(d.bearers, ['ble', 'lan', 'rns']);
    });

    test('seen but not reachable is a real state', () {
      final d = classifyXprs(const XprsCandidate(
        announcedCallsign: 'X16JK8',
        heardOnAir: true,
        airBearers: [],
      ))!;
      expect(d.reachable, isFalse,
          reason: 'heard within the hour, no path and no fresh bearer');
    });
  });
}
