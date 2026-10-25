/*
 * A gateway's reachability claim (XPRS.md 12.1, 15.6.3), and when a phone
 * deposits it with its archivers.
 */
import 'dart:convert';
import 'dart:typed_data';

import 'package:hex/hex.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/services/xprs/xprs_observation.dart';
import 'package:xprs/services/xprs/xprs_packet.dart';
import 'package:xprs/services/xprs/xprs_sig.dart';
import 'package:xprs/util/nostr_crypto.dart';

BigInt _scalar(String hex) => BigInt.parse(hex, radix: 16);

void main() {
  group('xprsComposeObservation', () {
    final pair = NostrCrypto.generateKeyPair();
    final key = _scalar(pair.privateKeyHex);
    final pub = Uint8List.fromList(
        HEX.decode(NostrCrypto.derivePublicKey(pair.privateKeyHex)));

    test('says who was heard, on which radio, signed, inside the budget', () {
      final p = xprsComposeObservation(
          self: 'X3RLY7',
          link: 'ble',
          heard: ['X1BOA3', 'CT1ABC-9'],
          budget: XprsPacket.maxBytes,
          lx: 'a' * 32,
          uptimeS: 9 * 86400,
          signingKey: key)!;
      expect(p.type, 'observation');
      expect(p['f'], 'X3RLY7');
      expect(p['link'], 'ble');
      expect(p['hears'], 'X1BOA3,CT1ABC-9');
      expect(p['peers'], '2');
      expect(p['uptime'], '9day');
      expect(p.has('sig'), isTrue);
      expect(utf8.encode(p.encode()).length, lessThanOrEqualTo(250));
      expect(xprsVerify(p, pub), XprsSigState.verified);
    });

    test('a crowd is cut to the budget, and peers: keeps the true count', () {
      final crowd = [for (var i = 0; i < 60; i++) 'X1A${i.toString().padLeft(3, '0')}'];
      final p = xprsComposeObservation(
          self: 'X3RLY7',
          link: 'lan',
          heard: crowd,
          budget: XprsPacket.maxBytes,
          signingKey: key)!;
      expect(utf8.encode(p.encode()).length, lessThanOrEqualTo(250),
          reason: 'the SIGNED packet fits, not just the unsigned envelope');
      expect(p['peers'], '60');
      expect(p['hears']!.split(',').length, lessThan(60));
      expect(p['hears'], startsWith('X1A000,'), reason: 'most relevant first');
    });

    test('nobody heard: no hears:, peers:0, still a packet', () {
      final p = xprsComposeObservation(
          self: 'X3RLY7', link: 'ble', heard: const [], budget: 250)!;
      expect(p.has('hears'), isFalse);
      expect(p['peers'], '0');
    });

    test('optional fields appear only when given', () {
      final p = xprsComposeObservation(
          self: 'X3RLY7', link: 'ble', heard: const [], budget: 250, mail: 3,
          serve: 'archive')!;
      expect(p['mail'], '3');
      expect(p['serve'], 'archive');
      expect(p.has('lx'), isFalse);
      expect(p.has('uptime'), isFalse);
    });

    test('no callsign, no packet', () {
      expect(xprsComposeObservation(self: '', link: 'ble', heard: const [], budget: 250),
          isNull);
    });
  });

  group('XprsHearsReporter', () {
    const t0 = 1700000000000;
    late XprsHearsReporter r;
    setUp(() => r = XprsHearsReporter());

    test('nobody heard: nothing to say, ever', () {
      expect(r.due(const [], t0), isNull);
      expect(r.due(const [], t0 + 3600000), isNull);
    });

    test('the first hearing is reported at once', () {
      expect(r.due(['X1BOA3'], t0), 'period');
    });

    test('a station that just appeared is reported, within the minute gap', () {
      r.noteReported(['X1BOA3'], t0);
      expect(r.due(['X1BOA3'], t0 + 30000), isNull, reason: 'nothing new');
      expect(r.due(['X1BOA3', 'X1NEW1'], t0 + 30000), isNull,
          reason: 'new, but inside the minimum gap');
      expect(r.due(['X1BOA3', 'X1NEW1'], t0 + 60000), 'new');
    });

    test('a device suffix is not a new station', () {
      r.noteReported(['X1BOA3'], t0);
      expect(r.due(['X1BOA3-2'], t0 + 120000), isNull);
    });

    test('the same crowd is repeated on the period', () {
      r.noteReported(['X1BOA3'], t0);
      expect(r.due(['X1BOA3'], t0 + 299000), isNull);
      expect(r.due(['X1BOA3'], t0 + 300000), 'period');
    });

    test('somebody leaving is not news', () {
      r.noteReported(['X1BOA3', 'X1OTHR'], t0);
      expect(r.due(['X1BOA3'], t0 + 120000), isNull);
    });
  });
}
