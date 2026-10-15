// XPRS.md 6.1.3: the second signature form, for a key a NOSTR signer holds.
// Told apart from 6.1.2's by the length of sig: (80 characters against 60).
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/services/xprs/xprs_id.dart';
import 'package:xprs/services/xprs/xprs_packet.dart';
import 'package:xprs/services/xprs/xprs_sig.dart';
import 'package:xprs/util/xprs_crypto.dart';

// The spec's worked example: toy key d = 7, aux fixed to zeros.
const _spec =
    't:message f:X1QZ3N d:LISBOA ts:2026-08-08_14:26:40 sig:QPxg^#t7^xDBU\$s1pg.d.u^UZ\$B0qYj%c.(I[)FY?%WouV6?)^xS[jf,ftorZ=\$fRs>JwXM_GfY&bYO@ m:net starts in ten minutes';
const _plain =
    't:message f:X1QZ3N d:LISBOA ts:2026-08-08_14:26:40 m:net starts in ten minutes';
final _d = BigInt.from(7);
final _pub = XprsCrypto.publicKeyXOnly(_d);

void main() {
  test('the spec\'s worked packet verifies, and is 163 bytes', () {
    final p = XprsPacket.parse(_spec)!;
    expect(_spec.length, 163);
    expect(p['sig']!.length, 80);
    expect(xprsVerify(p, _pub), XprsSigState.verified);
  });

  test('signing the example with aux zero reproduces the spec byte for byte', () {
    final p = xprsSignNostr(XprsPacket.parse(_plain)!, _d, aux: Uint8List(32));
    expect(p.encode(), _spec);
  });

  test('the identifier does not change with the form', () {
    final id = xprsIdentifier(XprsPacket.parse(_plain)!);
    expect(id, '399227');
    expect(xprsIdentifier(XprsPacket.parse(_spec)!), id);
    final short = xprsSign(XprsPacket.parse(_plain)!, _d);
    expect(short['sig']!.length, 60);
    expect(xprsIdentifier(short), id);
  });

  test('either form verifies, and one station may mix them', () {
    final a = xprsSign(XprsPacket.parse(_plain)!, _d);
    final b = xprsSignNostr(XprsPacket.parse(_plain)!, _d);
    expect(xprsVerify(a, _pub), XprsSigState.verified);
    expect(xprsVerify(b, _pub), XprsSigState.verified);
  });

  test('any change to the packet breaks the 80-character form', () {
    for (final change in [
      (XprsPacket p) => p.with_('m', 'net starts in nine minutes'),
      (XprsPacket p) => p.with_('d', 'PORTO'),
      (XprsPacket p) => p.with_('f', 'X1QZ3M'),
      (XprsPacket p) => p.with_('ts', '2026-08-08_14:26:41'),
    ]) {
      final p = change(XprsPacket.parse(_spec)!);
      expect(xprsVerify(p, _pub), XprsSigState.forged);
    }
  });

  test('another key, or no key, does not verify it', () {
    final p = XprsPacket.parse(_spec)!;
    expect(xprsVerify(p, XprsCrypto.publicKeyXOnly(BigInt.from(8))),
        XprsSigState.forged);
    expect(xprsVerify(p, null), XprsSigState.unverified);
  });

  test('via: is not signed, so a relayed copy still verifies', () {
    final p = XprsPacket.parse(_spec)!.with_('via', 'X3RLY7');
    expect(xprsVerify(p, _pub), XprsSigState.verified);
  });

  test('a packet with no ts: cannot use the form, and is forged if it claims to', () {
    final noTs = XprsPacket.parse(_spec)!.without({'ts'});
    expect(xprsVerify(noTs, _pub), XprsSigState.forged);
    // Signing it in this form produces nothing: it stays unsigned.
    final unsigned = xprsSignNostr(XprsPacket.parse('t:message f:X1QZ3N m:hi')!, _d);
    expect(unsigned.has('sig'), isFalse);
  });

  test('a value of any other length is not a signature', () {
    for (final n in [55, 65, 70, 75, 85, 90]) {
      final p = XprsPacket.parse(_plain)!.with_('sig', 'K' * n);
      expect(xprsVerify(p, _pub), XprsSigState.forged, reason: '$n characters');
    }
  });
}
