/*
 * XPRS.md 9.11.5: one message of another network, however many gateways
 * translated it. The section 5 identifier catches two gateways in the same
 * minute; `zmid:` catches the pair on either side of a minute boundary.
 */
import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/services/xprs/xprs_gateway_dedup.dart';
import 'package:xprs/services/xprs/xprs_packet.dart';

XprsPacket _p(String w) => XprsPacket.parse(w)!;

void main() {
  const a = 't:message f:MTA1B2C3D4 ts:2026-09-19_12:03:00 '
      'zmid:a1b2c3d44683c668 via:X3DCK0 m:anyone on the XPRS side?';
  const b = 't:message f:MTA1B2C3D4 ts:2026-09-19_12:04:00 '
      'zmid:a1b2c3d44683c668 via:X3H3MZ m:anyone on the XPRS side?';

  test('the second translation, dated a minute later, is dropped', () {
    final d = XprsGatewayDedup();
    expect(d.duplicate(_p(a), nowMs: 1000), isFalse);
    expect(d.duplicate(_p(b), nowMs: 2000), isTrue);
    expect(d.duplicates, 1);
  });

  test('an ordinary repeat is left to the identifier dedup', () {
    final d = XprsGatewayDedup();
    expect(d.duplicate(_p(a), nowMs: 1000), isFalse);
    // Same packet through another gateway in the same minute: `via:` is not
    // part of the identifier, so this is the same packet, not a second one.
    expect(
        d.duplicate(_p(a.replaceFirst('via:X3DCK0', 'via:X3H3MZ')),
            nowMs: 1500),
        isFalse);
    expect(d.duplicates, 0);
  });

  test('the parts of one translation are not repeats of each other', () {
    final d = XprsGatewayDedup();
    const p1 = 't:message f:MTA1B2C3D4 ts:2026-09-19_12:03:00 n:1/2 '
        'zmid:a1b2c3d400000009 via:X3DCK0 m:first half';
    const p2 = 't:message f:MTA1B2C3D4 ts:2026-09-19_12:03:00 n:2/2 '
        'zmid:a1b2c3d400000009 via:X3DCK0 m:second half';
    expect(d.duplicate(_p(p1), nowMs: 1), isFalse);
    expect(d.duplicate(_p(p2), nowMs: 2), isFalse);
    // The other gateway's part 2, dated a minute later: the same part twice.
    expect(
        d.duplicate(_p(p2.replaceFirst('12:03:00', '12:04:00')
            .replaceFirst('via:X3DCK0', 'via:X3H3MZ')), nowMs: 3),
        isTrue);
  });

  test('a packet with no zmid: is never touched', () {
    final d = XprsGatewayDedup();
    const w = 't:message f:X1QZ3N ts:2026-09-19_12:03:00 m:hi';
    expect(d.duplicate(_p(w), nowMs: 1), isFalse);
    expect(d.duplicate(_p(w), nowMs: 2), isFalse);
  });

  test('forgotten after the window, and bounded', () {
    final d = XprsGatewayDedup(cap: 4, windowMs: 1000);
    expect(d.duplicate(_p(a), nowMs: 0), isFalse);
    expect(d.duplicate(_p(b), nowMs: 5000), isFalse,
        reason: 'past the window: a new message as far as this table knows');
    for (var i = 0; i < 10; i++) {
      d.duplicate(_p('t:message f:MTA1B2C3D4 ts:2026-09-19_12:0$i:00 '
          'zmid:0000000${i}00000000 m:x'), nowMs: 6000);
    }
    expect(d.duplicate(_p(a), nowMs: 6000), isFalse,
        reason: 'evicted by newer entries');
  });
}
