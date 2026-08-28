/*
 * A carried body that is itself a wire is protocol, not correspondence.
 *
 * The courier carries whatever it is handed, and that is sometimes an XPRS
 * packet wrapped as mail. Reassembled and shown verbatim, it produced every
 * raw-wire chat bubble on the bench — and hid the real message, which was
 * sealed inside that inner packet.
 */
import 'package:xprs/services/xprs/xprs_packet.dart';
import 'package:xprs/services/xprs/xprs_vocab.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a t:-first wire is already usable', () {
    const w = 't:message f:X3ARK d:X1VCVM ts:2026-08-28_17:51:10 m:hello';
    expect(xprsNormaliseWire(w), w);
    expect(XprsPacket.parse(xprsNormaliseWire(w)!), isNotNull);
  });

  test('THE BENCH CASE: an x:-first wire becomes parseable', () {
    const w = 'x:iSQKF1iMTn0-RiwIHlA2slq0yR4hf2w6TMatY2YWHZlF '
        't:message f:X3ARK d:X1VCVM ts:2026-08-28_17:51:10 n:4/4 sig:vZO';
    final fixed = xprsNormaliseWire(w);
    expect(fixed, isNotNull);
    expect(fixed!.startsWith('t:message'), isTrue);
    final p = XprsPacket.parse(fixed);
    expect(p, isNotNull, reason: 'the inner packet must be recoverable');
    // Nothing invented, nothing lost — every field survives the rotation.
    expect(p!['f'], 'X3ARK');
    expect(p['d'], 'X1VCVM');
    expect(p['n'], '4/4');
    expect(p['x'], 'iSQKF1iMTn0-RiwIHlA2slq0yR4hf2w6TMatY2YWHZlF');
    expect(p['ts'], '2026-08-28_17:51:10');
  });

  test("a person's words are never treated as a wire", () {
    expect(xprsNormaliseWire('hello, are you at the harbour?'), isNull);
    expect(xprsNormaliseWire('meet me at 5: the pub'), isNull);
    expect(xprsNormaliseWire(''), isNull);
  });

  test('a wire with no t: token at all is refused, not mangled', () {
    expect(xprsNormaliseWire('x:blob sig:abc until:2026-08-28_14:47:50'), isNull);
  });
}
