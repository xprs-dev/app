/*
 * What this station keeps, and for whom — as a table.
 *
 * XPRS.md 12 gives three tiers: a pocket phone keeps "its operator's own words
 * and those of the callsigns they follow"; a powered station keeps everything
 * it hears; and nobody keeps a stranger's traffic until the operator says so,
 * because "silence is not consent". The app had one boolean covering all of
 * that, defaulting to keeping everything a phone overheard.
 */
import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/services/social/retention_tier.dart';
import 'package:xprs/services/xprs/xprs_archive_policy.dart';

void main() {
  const private = XprsArchivePolicy(); // a phone: public off, follows kept
  const public = XprsArchivePolicy(public: true);
  const alwaysOn =
      XprsArchivePolicy(public: true, alwaysOn: true, keepChatter: true);

  Tier? admit(
    Tier tier,
    String type, {
    XprsArchivePolicy policy = private,
    bool publication = false,
    bool declared = false,
    bool internet = false,
  }) =>
      xprsAdmitTier(
        tier: tier,
        type: type,
        publication: publication,
        declared: declared,
        internet: internet,
        policy: policy,
      );

  group('mine, whatever the switches say', () {
    test('my own conversation is never governed by a preference', () {
      for (final p in [private, public, alwaysOn]) {
        expect(admit(Tier.self, 'message', policy: p), Tier.self);
        expect(admit(Tier.self, 'file', policy: p), Tier.self);
        expect(admit(Tier.self, 'moderate', policy: p), Tier.self,
            reason: 'a group act is the only record of a roster (26.4)');
      }
    });

    test('my own beacons are chatter, and only an archiver keeps them', () {
      expect(admit(Tier.self, 'observation'), isNull);
      expect(admit(Tier.self, 'observation', policy: alwaysOn), Tier.self);
    });

    test('but presence ADDRESSED to us is an answer, not chatter', () {
      expect(
          xprsAdmitTier(
            tier: Tier.self,
            type: 'observation',
            publication: false,
            declared: false,
            internet: false,
            policy: private,
            addressedToUs: true,
          ),
          Tier.self);
    });
  });

  group('the people I follow — the tier the phone is for', () {
    test('their conversation is kept on a private phone', () {
      expect(admit(Tier.followed, 'message'), Tier.followed);
      expect(admit(Tier.followed, 'status'), Tier.followed);
    });

    test('and over the internet, with no declaration needed', () {
      // A followed friend's publications reaching us through a hub are
      // exactly what we meant to keep; the declaration rule exists to stop
      // the hub replaying the WORLD at us, not them.
      expect(admit(Tier.followed, 'message', internet: true), Tier.followed);
    });

    test('turning the tier off demotes them to a stranger', () {
      const noFollows = XprsArchivePolicy(keepFollowed: false);
      expect(admit(Tier.followed, 'message', policy: noFollows), isNull);
    });
  });

  group('everyone else — silence is not consent', () {
    test('a private station holds nothing for a stranger', () {
      expect(admit(Tier.stranger, 'message'), isNull);
      expect(admit(Tier.stranger, 'status', publication: true), isNull);
      expect(admit(Tier.stranger, 'observation'), isNull);
    });

    test('not even mail that names us in somebody else\'s hold:', () {
      // Being named in a stranger's t:mailbox is their choice, not ours.
      expect(admit(Tier.stranger, 'message', declared: true, internet: true),
          isNull);
    });

    test('a public archiver keeps what it hears on the air', () {
      expect(admit(Tier.stranger, 'message', policy: public), Tier.stranger);
    });

    test('but off the internet only under the declaration rule', () {
      expect(admit(Tier.stranger, 'message', policy: public, internet: true),
          isNull);
      expect(
          admit(Tier.stranger, 'message',
              policy: public, internet: true, publication: true),
          Tier.stranger);
      expect(
          admit(Tier.stranger, 'message',
              policy: public, internet: true, declared: true),
          Tier.stranger);
      expect(
          admit(Tier.stranger, 'message', policy: alwaysOn, internet: true),
          Tier.stranger,
          reason: 'an always-on archiver has the budget for the whole street');
    });

    test('a stranger\'s chatter needs the archiver to want chatter', () {
      expect(admit(Tier.stranger, 'observation', policy: public), isNull);
      expect(admit(Tier.stranger, 'observation', policy: alwaysOn),
          Tier.stranger);
    });
  });

  group('what nobody keeps, and what everybody does', () {
    test('answers are not records', () {
      for (final t in ['receipt', 'result', 'ping', 'pong']) {
        expect(admit(Tier.self, t, policy: alwaysOn), isNull, reason: t);
      }
    });

    test('a key binding is not chatter (18.1)', () {
      // Without t:identity a station cannot verify a signature, seal a reply
      // or trust a receipt — from anyone, at any tier, however private.
      expect(admit(Tier.self, 'identity'), Tier.self);
      expect(admit(Tier.followed, 'identity'), Tier.followed);
      expect(admit(Tier.stranger, 'identity'), Tier.stranger,
          reason: 'kept even on a private phone: it is what makes the rest '
              'checkable, and it is collapsed to one row per station');
    });
  });

  group('who the middle tier is (16.2)', () {
    // Bare stand-ins: the real callers pass NostrCrypto.deriveCallsign and
    // bareCallsign. What is under test is which names end up on the shelf.
    String derive(String hex) => hex == 'zz' ? '' : 'X1${hex.toUpperCase()}';
    String base(String c) => c.split('-').first.toUpperCase();

    Set<String> names(Set<String> hex, Map<String, String> callPub) =>
        xprsFollowedCallsigns(
            followedHex: hex, callPub: callPub, derive: derive, base: base);

    test('a followed key is followed under the name we can derive', () {
      expect(names({'ab'}, const {}), {'X1AB'});
    });

    test('and under the name its holder actually transmits', () {
      // A station announcing X3ARK is the same key as the X1ARKL we derive.
      // Shelving only the derived name would leave every packet it ever sends
      // on the stranger shelf, under the byte cap, for a station we follow.
      expect(names({'ark'}, {'X3ARK': 'ark'}), {'X1ARK', 'X3ARK'});
    });

    test('an issued callsign has no key arithmetic and still counts', () {
      expect(names({'ct'}, {'CT1ABC': 'CT'}), contains('CT1ABC'),
          reason: 'the binding is what we hold, whatever the name derives to');
    });

    test('SSIDs are one shelf', () {
      expect(names({'ab'}, {'X1AB-7': 'ab'}), {'X1AB'});
    });

    test('nobody followed, nobody promoted', () {
      expect(names(const {}, {'X3ARK': 'ark'}), isEmpty);
    });

    test('a callsign we know but do not follow stays a stranger', () {
      expect(names({'ab'}, {'X3ARK': 'ark'}), {'X1AB'});
    });

    test('a key too short to derive from is skipped, not crashed on', () {
      expect(names({'zz'}, const {}), isEmpty);
    });
  });
}
