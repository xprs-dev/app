// Which name is which, and the one that goes on the air.
//
// A profile carries three names and they are not interchangeable:
//   id                the folder on disk, devices/<id>/, never changes
//   callsign          derived from the key, self-proving, never changes
//   licenceCallsign   what an authority issued, optional
//   wireCallsign      what goes in f:, which is the licence when there is one
//
// The bug this guards against is the obvious one: reusing `callsign` for the
// licensed name would rename the profile's folder out from under it.
import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/profile/iwi_profile.dart';

IwiProfile base({String licence = '', String nickname = ''}) => IwiProfile(
      id: 'X1ABCD',
      nickname: nickname,
      callsign: 'X1ABCD',
      npub: 'npub1test',
      nsec: 'nsec1test',
      createdAt: 1700000000000,
      licenceCallsign: licence,
    );

void main() {
  group('wireCallsign', () {
    test('with no licence it is the derived callsign, exactly as before', () {
      expect(base().wireCallsign, 'X1ABCD');
    });

    test('with a licence it is the licence', () {
      expect(base(licence: 'CT1ABC').wireCallsign, 'CT1ABC');
    });

    test('setting a licence does not touch the id or the derived name', () {
      // storage_paths builds devices/<id>/ from this, so a change here moves
      // every file the profile owns.
      final p = base().copyWith(licenceCallsign: 'CT1ABC');
      expect(p.id, 'X1ABCD');
      expect(p.callsign, 'X1ABCD');
      expect(p.wireCallsign, 'CT1ABC');
    });

    test('an empty string clears it, with no separate flag to forget', () {
      final set = base(licence: 'CT1ABC');
      final cleared = set.copyWith(licenceCallsign: '');
      expect(cleared.licenceCallsign, '');
      expect(cleared.wireCallsign, 'X1ABCD');
    });

    test('copyWith with nothing passed keeps the licence', () {
      expect(base(licence: 'CT1ABC').copyWith(nickname: 'Max').wireCallsign,
          'CT1ABC');
    });
  });

  group('displayName prefers a nickname, then the name on the air', () {
    test('a nickname wins', () {
      expect(base(licence: 'CT1ABC', nickname: 'Max').displayName, 'Max');
    });

    test('with no nickname it is the wire name, not the derived one', () {
      expect(base(licence: 'CT1ABC').displayName, 'CT1ABC');
      expect(base().displayName, 'X1ABCD');
    });
  });

  group('persistence', () {
    test('round-trips when set', () {
      final p = base(licence: 'CT1ABC-9');
      expect(IwiProfile.fromJson(p.toJson()).licenceCallsign, 'CT1ABC-9');
      expect(IwiProfile.fromJson(p.toJson()).wireCallsign, 'CT1ABC-9');
    });

    test('is not written at all when unset, so an old file is unchanged', () {
      expect(base().toJson().containsKey('licenceCallsign'), isFalse);
    });

    test('a profile written before this existed loads with no licence', () {
      // The whole migration: an absent key reads as "no licence".
      final legacy = <String, dynamic>{
        'id': 'X1ABCD',
        'nickname': 'Max',
        'callsign': 'X1ABCD',
        'npub': 'npub1test',
        'nsec': 'nsec1test',
        'createdAt': 1700000000000,
      };
      final p = IwiProfile.fromJson(legacy);
      expect(p.licenceCallsign, '');
      expect(p.wireCallsign, 'X1ABCD');
      expect(p.displayName, 'Max');
    });
  });
}
