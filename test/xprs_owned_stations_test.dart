import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/services/xprs/xprs_owned_stations.dart';
import 'package:xprs/services/xprs/xprs_packet.dart';

void main() {
  final owned = XprsOwnedStations.instance;
  late List<String> saved;
  var changes = 0;

  setUp(() {
    owned.resetForTest();
    saved = ['X3HOME'];
    changes = 0;
    owned.load = () => saved;
    owned.save = (v) => saved = v;
    owned.onChanged = () => changes++;
  });

  test('what a station says about its owners is an owner statement', () {
    bool st(String w) => XprsOwnedStations.isOwnerStatement(XprsPacket.parse(w)!);
    expect(st('t:result f:X2CARD d:X1ME r:abcdef code:200 owner:X1ME'), isTrue);
    expect(st('t:observation f:X2CARD d:X1ME s:policy owner:X1ME use:all'), isTrue);
    expect(st('t:observation f:X2CARD pos:1.0,2.0 owner:X1ME'), isFalse,
        reason: 'only the policy answer of the observations');
    expect(st('t:command f:X1ME d:X2CARD cmd:set owner:X1ME'), isFalse,
        reason: 'the claim is the asker speaking, not the station');
  });

  test('learning both ways, persisted, and only changes report', () {
    expect(owned.isOwned('X3HOME'), isTrue, reason: 'loaded from preferences');
    owned.learn('X2CARD', 'X1OTHER,X1ME', 'X1ME');
    expect(owned.isOwned('x2card'), isTrue);
    expect(owned.portable, ['X2CARD'], reason: 'X3 stations are not cards');
    expect(saved, containsAll(['X2CARD', 'X3HOME']));
    owned.learn('X2CARD', 'X1ME', 'X1ME');
    expect(changes, 1, reason: 'restating ownership changes nothing');
    owned.learn('X2CARD', 'X1OTHER', 'X1ME');
    expect(owned.isOwned('X2CARD'), isFalse, reason: 'handed to somebody else');
    owned.learn('X3HOME', 'none', 'X1ME');
    expect(owned.all, isEmpty);
    expect(changes, 3);
  });

  test('a statement is worth verifying only when it would change something', () {
    expect(owned.concerns('X2NEW', 'X1ME', 'X1ME'), isTrue);
    expect(owned.concerns('X2NEW', 'X1OTHER', 'X1ME'), isFalse,
        reason: 'somebody else\'s station answering somebody else');
    expect(owned.concerns('X3HOME', 'X1OTHER', 'X1ME'), isTrue,
        reason: 'one of ours, saying it is not ours any more');
  });
}
