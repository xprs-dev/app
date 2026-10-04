/*
 * Which name are we entitled to call a key by?
 *
 * A node's callsign is its own choice of prefix and length (XPRS.md 3), and
 * the observer's job is to CHECK it, not to invent a second name for it. For a
 * derived callsign the check is arithmetic. For one a radio authority issued
 * there is no arithmetic to do, so before this an announced `CT1ABC` was
 * silently replaced by the `X1`+4 its key derives: the same "a second name for
 * one device, invented by the observer" defect, for the other kind of
 * callsign.
 *
 * XPRS.md 3.0.1 names the second proof: "What makes a callsign canonical is
 * the identity announcement that declares it, which is signed."
 */
import 'package:flutter_test/flutter_test.dart';
import 'package:reticulum/reticulum.dart';
import 'package:xprs/services/reticulum/rns_service.dart';

void main() {
  // The key whose bech32 encoding starts `arkl`, so it derives X1ARKL at the
  // default length and X3ARK at three.
  const npub = 'npub1arklg83wnqy4s6stnl65hl9dt980xfgsh6vxz8jeg7r2a9hwta6s3zd263';
  final hex = NostrCrypto.decodeNpub(npub);
  final rns = RnsService.instance;

  setUp(RnsService.debugClearNameMemo);

  group('a derived callsign proves itself by arithmetic, as always', () {
    test('an announced name its key can produce is kept', () {
      expect(RnsService.debugCallsignFor(hex, 'X1ARKL'), 'X1ARKL');
      expect(RnsService.debugCallsignFor(hex, 'X3ARK'), 'X3ARK');
    });

    test('a name its key cannot produce is replaced by the derived one', () {
      expect(RnsService.debugCallsignFor(hex, 'X3ZZZ'), 'X1ARKL');
    });

    test('no announcement at all gives the derived name', () {
      expect(RnsService.debugCallsignFor(hex, ''), 'X1ARKL');
    });
  });

  group('an issued callsign proves itself by its signed identity', () {
    test('with no binding held, it is still replaced by the derived name', () {
      // We will not repeat a claim we cannot check. This is the behaviour
      // that was always right for an unknown key, and is kept.
      expect(RnsService.debugCallsignFor(hex, 'G0XYZ'), 'X1ARKL');
    });

    test('once the binding is held, the announced callsign stands', () {
      // recordCallsignPubkey is only ever reached from XprsIngest.onIdentity,
      // which _bindIdentity reaches only after the packet's self-signature
      // verified against the k: it carried (XPRS.md 6.4.2).
      rns.recordCallsignPubkey('CT1ABC', hex);
      RnsService.debugClearNameMemo();
      expect(RnsService.debugCallsignFor(hex, 'CT1ABC'), 'CT1ABC');
    });

    test('the arithmetic test still says no to it, and must', () {
      // Nothing here weakens callsignMatchesKey. An issued callsign has no
      // arithmetic relationship to any key, and claiming otherwise would be
      // the lie XPRS.md 6.4.2 spends a section warning about.
      expect(NostrCrypto.callsignMatchesKey('CT1ABC', hex), isFalse);
    });

    test('a binding held for somebody else does not transfer', () {
      rns.recordCallsignPubkey('G0ABC', 'a' * 64);
      RnsService.debugClearNameMemo();
      expect(RnsService.debugCallsignFor(hex, 'G0ABC'), 'X1ARKL');
    });

    test('a device suffix resolves by the bare name (XPRS.md 3.1)', () {
      // The bare callsign is the person. `t:identity f:CT1DEF` binds the
      // person, and `CT1DEF-9` is one of their devices.
      rns.recordCallsignPubkey('CT1DEF', hex);
      RnsService.debugClearNameMemo();
      expect(RnsService.debugCallsignFor(hex, 'CT1DEF-9'), 'CT1DEF-9');
    });

    test('a suffixed announcement also binds the bare name', () {
      // recordCallsignPubkey files both, so pubkeyForCallsign no longer
      // misses a key it is holding.
      rns.recordCallsignPubkey('CT1GHI-9', hex);
      expect(rns.pubkeyForCallsign('CT1GHI-9'), hex);
      expect(rns.pubkeyForCallsign('CT1GHI'), hex,
          reason: 'the person, not just the device');
    });
  });

  group('the memo', () {
    test('a later binding is not hidden by an earlier verdict', () {
      // The memo is cleared by recordCallsignPubkey on a real change, so a
      // station whose identity arrives AFTER we first saw its announce is not
      // stuck under the derived name for the rest of the session.
      expect(RnsService.debugCallsignFor(hex, 'G0JKL'), 'X1ARKL');
      rns.recordCallsignPubkey('G0JKL', hex);
      expect(RnsService.debugCallsignFor(hex, 'G0JKL'), 'G0JKL');
    });
  });
}
