// The status publisher against the spec: one signed packet when it fits,
// section 6.6 parts when it does not (same ts:, split at spaces, sig on the
// last part covering the REASSEMBLED packet), and scope: deciding which
// bearers may carry it. Bearers are fakes — this tests the policy, not radios.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:xprs/services/xprs/xprs_packet.dart';
import 'package:xprs/services/xprs/xprs_publisher.dart';
import 'package:xprs/services/xprs/xprs_sig.dart';
import 'package:pointycastle/ecc/curves/secp256k1.dart';

class _FakeBearer implements XprsBearer {
  _FakeBearer(this.name, {required this.shortRange});
  final bool up = true;
  @override
  final String name;
  @override
  String get archiveBearer => name;
  @override
  final bool shortRange;
  final List<String> sent = [];
  @override
  Future<bool> get active async => up;
  /// The rotation slot the publisher chose, so a test can prove two asks to
  /// two stations no longer share one advert key.
  final List<String> slots = [];
  final List<Duration?> ttls = [];
  @override
  Future<bool> send(String wire,
      {required int part, String slot = 'status', Duration? ttl}) async {
    sent.add(wire);
    slots.add(slot);
    ttls.add(ttl);
    return true;
  }
}

void main() {
  _identityAndSlots();
  TestWidgetsFlutterBinding.ensureInitialized();

  // No active profile in a unit test: the publisher must refuse politely.
  test('no profile -> nothing published', () async {
    final ble = _FakeBearer('ble5', shortRange: true);
    XprsPublisher.instance.bearers = [ble];
    final r = await XprsPublisher.instance.publishStatus('hello out there');
    expect(r, isEmpty);
    expect(ble.sent, isEmpty);
  });

  // The wire-building policy is where the spec lives; test it through the
  // publisher's splitter via a synthetic head (no profile needed).
  test('splitter: parts share ts, split at spaces, sig on last, rejoin',
      () async {
    const head = 't:status f:X1TEST ts:2026-08-13_12:00:00';
    final words = List.generate(120, (i) => 'word$i').join(' ');
    final wires = XprsPublisher.instance.debugWires(head, words);
    expect(wires.length, greaterThan(1));
    expect(wires.length, lessThanOrEqualTo(9));

    final parts = [for (final w in wires) XprsPacket.parse(w)!];
    for (var i = 0; i < parts.length; i++) {
      expect(parts[i]['ts'], '2026-08-13_12:00:00');
      expect(parts[i]['n'], '${i + 1}/${parts.length}');
      expect(parts[i].fits, true, reason: 'part ${i + 1} must fit 250B');
      // Unsigned in a test (no profile key) — sig only ever on the last.
      if (i < parts.length - 1) expect(parts[i]['sig'], isNull);
    }
    // Reassembly (6.6): joined with single spaces = the original text.
    final joined = parts.map((p) => p['m']).join(' ');
    expect(joined, words);
  });

  test('short status is one packet', () {
    const head = 't:status f:X1TEST ts:2026-08-13_12:00:00';
    final wires = XprsPublisher.instance.debugWires(head, 'all quiet here');
    expect(wires, hasLength(1));
    final p = XprsPacket.parse(wires.single)!;
    expect(p.type, 'status');
    expect(p['m'], 'all quiet here');
    expect(p['n'], isNull);
  });

  test('signed when a key is provided: sig verifies over reassembled packet',
      () {
    const head = 't:status f:X1TEST ts:2026-08-13_12:00:00';
    final d = BigInt.parse('1234567890abcdef1234567890abcdef', radix: 16);
    final words = List.generate(80, (i) => 'w$i').join(' ');
    final wires =
        XprsPublisher.instance.debugWires(head, words, signingKey: d);
    final parts = [for (final w in wires) XprsPacket.parse(w)!];
    final sig = parts.last['sig'];
    expect(sig, isNotNull);
    expect(sig!.length, 60); // base85 of a 48-byte short-Schnorr

    // The signature must cover the REASSEMBLED packet (9.1.1): rebuild it,
    // attach the sig, and verify against the x-only public key of [d].
    final joined =
        XprsPacket.parse('$head m:${parts.map((p) => p['m']).join(' ')}')!
            .with_('sig', sig);
    final q = (ECCurve_secp256k1().G * d)!;
    final xHex = q.x!.toBigInteger()!.toRadixString(16).padLeft(64, '0');
    final pub = Uint8List.fromList([
      for (var i = 0; i < 64; i += 2)
        int.parse(xHex.substring(i, i + 2), radix: 16)
    ]);
    expect(xprsVerify(joined, pub), XprsSigState.verified);
    // And it must NOT verify as a signature over any single part.
    final lastAlone = parts.last;
    expect(xprsVerify(lastAlone, pub), isNot(XprsSigState.verified));
  });
}

void _identityAndSlots() {
  // A station cannot check a single signature of ours until it has heard the
  // key our callsign signs with, and until then it meters us as a stranger:
  // two history replays an hour instead of six (section 31.2). The packet that
  // fixes that is section 9.3, and it MUST be self-signed — both station
  // firmwares drop one whose signature does not verify against the k: it
  // carries, so an unsigned announcement binds nothing anywhere.
  test('the identity announcement signs for the key it publishes', () {
    final d = BigInt.parse(
        '7b2c3d4e5f60718293a4b5c6d7e8f90112233445566778899aabbccddeeff001',
        radix: 16);
    final q = (ECCurve_secp256k1().G * d)!;
    final xHex = q.x!.toBigInteger()!.toRadixString(16).padLeft(64, '0');
    final pub = Uint8List.fromList([
      for (var i = 0; i < 64; i += 2)
        int.parse(xHex.substring(i, i + 2), radix: 16)
    ]);
    const npub =
        'npub1a67x63c0y4s79lwssfztkt9uryqlvmc2ylujaxdgfqjtu7vpc0xqtrdgfw';

    final wire = XprsPublisher.instance.debugIdentityWire(
        call: 'X1A67X', npub: npub, signingKey: d);
    expect(wire, isNotNull);

    final p = XprsPacket.parse(wire!)!;
    expect(p.type, 'identity');
    expect(p['f'], 'X1A67X');
    expect(p['k'], npub);
    expect(p.has('ts'), isTrue);
    expect(xprsVerify(p, pub), XprsSigState.verified);

    // 171 bytes in the spec; the smallest controller measured in
    // docs/ble5.md section 3 carries 184, and an oversized advert is refused
    // rather than truncated. No nick:, no room for one.
    expect(p.fits, isTrue);
    expect(wire.length, lessThanOrEqualTo(184));
  });

  // Re-registering an advert key REPLACES that rotation entry. Every publish
  // used to share one key, so a sweep asking N stations back to back put only
  // the last ask on air and took the user's status with it.
  test('two asks to two stations occupy two advert slots', () async {
    final b = _FakeBearer('ble5', shortRange: true);
    XprsPublisher.instance.bearers = [b];

    await XprsPublisher.instance
        .publishWire('t:command f:X1SELF d:X3AAAA ts:x scope:local cmd:history');
    await XprsPublisher.instance
        .publishWire('t:command f:X1SELF d:X3BBBB ts:x scope:local cmd:history');

    expect(b.sent, hasLength(2));
    expect(b.slots, ['command:X3AAAA', 'command:X3BBBB']);
    expect(b.slots.toSet(), hasLength(2),
        reason: 'sharing one slot is what silently dropped every ask but one');
  });
}
