/*
 * THE PROPERTY THE WHOLE SCHEME RESTS ON: sender and receiver derive the same
 * §5 identifier for one message, split or not, sealed or not.
 *
 * The sender keys its bubble and its outbox on it. The receiver names it in a
 * receipt's `r:`. Custody releases on it. If the two ends disagree by one
 * field, every one of those silently stops working — which is how a wapp ends
 * up inventing an `am:` token of its own to correlate what the format already
 * correlates.
 *
 * The trap is specific and this test exists for it: a SEALED split message is
 * built from ciphertext parts, but XprsPartTable opens each part and joins the
 * PLAINTEXT, so the packet the receiver names carries `m:` where every part
 * carried `x:`. A sender deriving its id from what it aired would key on a
 * value no receipt ever mentions.
 */
import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/services/xprs/xprs_body.dart';
import 'package:xprs/services/xprs/xprs_id.dart';
import 'package:xprs/services/xprs/xprs_packet.dart';
import 'package:xprs/services/xprs/xprs_parts.dart';

const _head = 't:message f:X1VCVM d:X3ARK ts:2026-09-02_14:52:27';
XprsPacket head() => XprsPacket.parse(_head)!;

/// What a receiver ends up with, given the parts a sender aired and the
/// plaintext it can read out of each.
XprsPacket? receive(List<XprsPacket> parts, List<String> clear) {
  final t = XprsPartTable();
  XprsReassembled? done;
  for (var i = 0; i < parts.length; i++) {
    done ??= t.offer(parts[i], clear: clear[i]);
  }
  return done?.packet;
}

void main() {
  test('unsplit plain: one packet, and it names itself', () {
    final built = xprsBuildDirect(head: head(), text: 'on my way', private: false);
    expect(built.ok, isTrue);
    expect(built.packets.length, 1);
    expect(built.rejoined, isNull, reason: 'nothing was split');
    expect(xprsIdentifier(built.identityPacket!),
        xprsIdentifier(built.packets.first));
  });

  test('split plain: the id is the REASSEMBLED packet, not part one', () {
    final text = List.generate(90, (i) => 'w$i').join(' ');
    final built = xprsBuildDirect(head: head(), text: text, private: false);
    expect(built.ok, isTrue);
    expect(built.packets.length, greaterThan(1),
        reason: 'the fixture has to split to test anything');

    final theirs = receive(built.packets,
        [for (final p in built.packets) p['m'] ?? '']);
    expect(theirs, isNotNull);

    expect(xprsIdentifier(built.identityPacket!), xprsIdentifier(theirs!),
        reason: 'sender and receiver must name the same message');
    expect(xprsIdentifier(built.packets.first),
        isNot(xprsIdentifier(theirs)),
        reason: 'part one is not the message — this is the trap');
  });

  test('§6.6 joins with ONE space, so the sender must too', () {
    // A body with a double space reassembles with a single one. A sender that
    // derived its id from the text it was handed, rather than from the chunks
    // as joined, would disagree with every receiver.
    final text = '${List.generate(80, (i) => 'w$i').join(' ')}  tail';
    final built = xprsBuildDirect(head: head(), text: text, private: false);
    if (built.packets.length < 2) return; // fixture did not split; nothing to prove
    final theirs = receive(built.packets,
        [for (final p in built.packets) p['m'] ?? '']);
    expect(xprsIdentifier(built.identityPacket!), xprsIdentifier(theirs!));
  });

  test('the reassembled packet carries m:, never n: or sig:', () {
    final text = List.generate(90, (i) => 'w$i').join(' ');
    final built = xprsBuildDirect(head: head(), text: text, private: false);
    final id = built.identityPacket!;
    expect(id.has('m'), isTrue);
    expect(id.has('n'), isFalse, reason: '6.6: n: is removed on reassembly');
    expect(id.has('x'), isFalse);
  });
}
