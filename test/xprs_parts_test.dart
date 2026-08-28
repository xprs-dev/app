/*
 * Section 6.6 reassembly — "A partial message is never displayed."
 *
 * XprsPartTable implemented this clause in full and had no caller, so every
 * part of a split message was delivered as its own chat entry: one message from
 * a neighbour arrived as four lines of `n:3/4 x:TH`, and draining a backlog
 * turned that into hundreds. MeshCourier.deliverXprs is the caller now.
 */
import 'package:xprs/services/xprs/xprs_id.dart';
import 'package:xprs/services/xprs/xprs_packet.dart';
import 'package:xprs/services/xprs/xprs_parts.dart';
import 'package:flutter_test/flutter_test.dart';

XprsPacket _part(String n, String text,
        {String ts = '2026-08-28_14:52:27', String f = 'X1VCVM'}) =>
    XprsPacket.parse('t:message f:$f d:X3ARK ts:$ts n:$n m:$text')!;

void main() {
  test('a partial set yields nothing — no part is ever displayed', () {
    final t = XprsPartTable();
    expect(t.offer(_part('1/4', 'the'), clear: 'the'), isNull);
    expect(t.offer(_part('2/4', 'quick'), clear: 'quick'), isNull);
    expect(t.offer(_part('3/4', 'brown'), clear: 'brown'), isNull);
    expect(t.pending, 1, reason: 'held, not dropped and not shown');
  });

  test('the completed set is one message, joined with single spaces', () {
    final t = XprsPartTable();
    t.offer(_part('1/4', 'the'), clear: 'the');
    t.offer(_part('2/4', 'quick'), clear: 'quick');
    t.offer(_part('3/4', 'brown'), clear: 'brown');
    final done = t.offer(_part('4/4', 'fox'), clear: 'fox');
    expect(done, isNotNull);
    expect(done!.text, 'the quick brown fox');
    expect(t.pending, 0);
  });

  test('parts may arrive in any order, and a repeat is ignored', () {
    final t = XprsPartTable();
    expect(t.offer(_part('3/3', 'three'), clear: 'three'), isNull);
    expect(t.offer(_part('1/3', 'one'), clear: 'one'), isNull);
    expect(t.offer(_part('1/3', 'IMPOSTOR'), clear: 'IMPOSTOR'), isNull);
    final done = t.offer(_part('2/3', 'two'), clear: 'two');
    expect(done!.text, 'one two three');
  });

  test('a sealed part we cannot open never completes the set', () {
    final t = XprsPartTable();
    t.offer(_part('1/2', 'half'), clear: 'half');
    // clear: null is "this part did not arrive" — a hole must not close.
    expect(t.offer(_part('2/2', 'x'), clear: null), isNull);
  });

  test('the identifier is the reassembled message, not any part', () {
    final t = XprsPartTable();
    t.offer(_part('1/2', 'hello'), clear: 'hello');
    final done = t.offer(_part('2/2', 'world'), clear: 'world');
    final whole = xprsIdentifier(done!.packet);
    expect(whole, isNot(xprsIdentifier(_part('1/2', 'hello'))));
    expect(done.packet.has('n'), isFalse, reason: 'n: is removed (6.6)');
    expect(xprsIdentifier(XprsPacket.parse(
            't:message f:X1VCVM d:X3ARK ts:2026-08-28_14:52:27 '
            'm:hello world')!),
        whole);
  });

  test('two messages from one station do not merge', () {
    final t = XprsPartTable();
    t.offer(_part('1/2', 'first', ts: '2026-08-28_14:52:27'), clear: 'first');
    expect(
        t.offer(_part('2/2', 'other', ts: '2026-08-28_14:59:00'),
            clear: 'other'),
        isNull,
        reason: 'a different ts is a different set (keyed on f,ts)');
  });
}
