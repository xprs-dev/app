/*
 * "Is this protocol, or is this a person's words?"
 *
 * Two places used to answer with `content.startsWith('t:')` — the host's
 * inbound LXMF handler and the chat wapp's lxmf_drain. A sealed packet reaches
 * a peer with `x:` leading, so both missed it, and the wire was filed as
 * correspondence: a chat bubble and an Android notification, hundreds of times.
 */
import 'package:xprs/services/xprs/xprs_vocab.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('protocol is recognised wherever its fields sit', () {
    test('the ordinary shape, t: first', () {
      expect(
          xprsLooksLikeWire(
              't:message f:X3ARK d:X1VCVM ts:2026-08-28_14:30:52 m:hello'),
          isTrue);
    });

    test('THE BUG: a sealed wire with x: leading', () {
      expect(
          xprsLooksLikeWire(
              'x:jREsSRrpqrL_2P3qFH6oxdn-niwYgygrHA20LX0UniY t:message '
              'f:X3ARK d:X1VCVM ts:2026-08-28_15:07:06 n:2/3 sig:oo+lJV'),
          isTrue);
    });

    test('machinery of every kind', () {
      for (final w in [
        't:receipt f:X3ARK d:X1VCVM r:571e06 s:ack',
        't:result f:X1VCVM d:X3ARK r:dea8c5 code:200',
        't:command f:X1VCVM d:X3ARK cmd:history since:2026-08-27_00:00:00',
        't:identity f:X3ARK k:npub1abcdef',
        't:observation f:X3ARK pos:52.1,8.7',
      ]) {
        expect(xprsLooksLikeWire(w), isTrue, reason: w);
      }
    });
  });

  group('a FRAGMENT of a wire is protocol too', () {
    // Tails that lost their t:/f: on the way here, every one of them observed
    // rendered as somebody's message on the bench.
    test('the bench residue', () {
      for (final w in [
        'x:J6vbktsijxG0-fF8IkmBH9uh69 sig:E^2L#[[TmF6A%) code:202 sO',
        'sig:OfdVATNg/Jy#!,)JKB+TkUW94WMM4j%C9Ux',
        's:ack s3',
        'until:2026-08-28_14:47:50 *D',
        'x:blob sig:abc until:2026-08-28_14:47:50',
      ]) {
        expect(xprsLooksLikeWire(w), isTrue, reason: w);
      }
    });

    test('but it is NOT recoverable, so it is dropped rather than mangled', () {
      expect(xprsNormaliseWire('sig:OfdVATNg/Jy#!'), isNull);
    });

    test('A REAL MESSAGE CARRIES am: AND MUST SURVIVE', () {
      // The delivered form is `am:<handle> the words` — this is exactly what
      // we are trying to show, and a fragment rule that ate it would be worse
      // than the bug.
      expect(xprsLooksLikeWire('am:a1b3db ALPHA1'), isFalse);
      expect(xprsLooksLikeWire('am:7f2c01 see you at the harbour'), isFalse);
      expect(xprsLooksLikeWire('m:hello there'), isFalse);
    });
  });

  group("and a person's words are left alone", () {
    test('plain text', () {
      expect(xprsLooksLikeWire('hello, are you still at the harbour?'), isFalse);
    });

    test('a colon in prose is not a field', () {
      expect(xprsLooksLikeWire('meet me at 5: the pub'), isFalse);
      expect(xprsLooksLikeWire('ratio 3:1 on the last run'), isFalse);
    });

    test('n: mid-sentence must not be mistaken for a part', () {
      expect(xprsLooksLikeWire('the answer is n: 42'), isFalse);
    });

    test('a type word alone, with no sender, is not a packet', () {
      expect(xprsLooksLikeWire('t:message'), isFalse);
      expect(xprsLooksLikeWire('send me a t:message when you land'), isFalse);
    });

    test('an unknown type is not a packet either (section 4.2 is closed)', () {
      expect(xprsLooksLikeWire('t:banana f:X3ARK d:X1VCVM m:hi'), isFalse);
    });

    test('empty and tiny inputs', () {
      expect(xprsLooksLikeWire(''), isFalse);
      expect(xprsLooksLikeWire('ok'), isFalse);
      expect(xprsLooksLikeWire('t:'), isFalse);
    });
  });
}
