// The profile page's "other identities" form (XPRS.md 6.3.3): what a person
// types becomes the values of one kind, and the profile keeps them.
import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/profile/iwi_profile.dart';
import 'package:xprs/profile/other_identities_editor.dart';
import 'package:xprs/services/people/xprs_people.dart';

void main() {
  test('typed text is split, normalised for its kind, and the rest named', () {
    final r = OtherIdentitiesEditor.parse(
        XprsIdType.ble, 'a4-cf-12-0b-7e-31, A4:CF:12:0B:80:02\nnonsense');
    expect(r.good, ['A4:CF:12:0B:7E:31', 'A4:CF:12:0B:80:02']);
    expect(r.bad, ['nonsense']);
    expect(OtherIdentitiesEditor.parse(XprsIdType.email, 'Joao@Example.org').good,
        ['joao@example.org']);
    expect(OtherIdentitiesEditor.parse(XprsIdType.meshtastic, 'mta1b2c3d4').good,
        ['MTA1B2C3D4']);
    expect(OtherIdentitiesEditor.parse(XprsIdType.email, 'no-at-sign').good,
        isEmpty);
  });

  test('a board address is told nearby unless its owner says otherwise', () {
    expect(XprsIdType.defaultScope(XprsIdType.ble), 'local');
    expect(XprsIdType.defaultScope(XprsIdType.wlan), 'local');
    expect(XprsIdType.defaultScope(XprsIdType.email), 'global');
  });

  test('a radio address is not offered to type: a machine fills it in', () {
    expect(XprsIdType.typed, isNot(contains(XprsIdType.ble)));
    expect(XprsIdType.typed, isNot(contains(XprsIdType.wlan)));
    expect(XprsIdType.typed.first, XprsIdType.email);
    expect(XprsIdType.statable, contains(XprsIdType.ble),
        reason: 'a station may still state the one it has');
  });

  test('the profile keeps the sets, and an older profile reads as none', () {
    const p = IwiProfile(
        id: 'p1',
        nickname: 'joao',
        callsign: 'X1QZ3N',
        npub: 'npub1x',
        nsec: 'nsec1x',
        createdAt: 1);
    expect(p.identities, isEmpty);
    expect(p.toJson().containsKey('identities'), isFalse,
        reason: 'profiles without any stay byte-identical');
    final q = p.copyWith(identities: const [
      StatedIdentities('email', ['joao@example.org'], scope: 'PT,ES'),
      StatedIdentities('ble', ['A4:CF:12:0B:7E:31'], scope: 'local'),
    ]);
    final back = IwiProfile.fromJson(q.toJson());
    expect(back.identities, hasLength(2));
    expect(back.identities.first.type, 'email');
    expect(back.identities.first.values, ['joao@example.org']);
    expect(back.identities.first.scope, 'PT,ES');
    expect(back.identities.last.scope, 'local');
  });
}
