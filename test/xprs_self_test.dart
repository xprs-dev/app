/*
 * Which of an operator's names a packet goes out under (XprsSelf).
 *
 * The operator's rule, 2026-10-24: the X1 is the base and never changes; one
 * issued callsign is active; a conversation keeps the callsign it began under.
 */
import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/profile/iwi_profile.dart';
import 'package:xprs/services/xprs/xprs_self.dart';

IwiProfile _profile({String active = '', List<String> held = const []}) =>
    IwiProfile(
      id: 'X1AAAA',
      nickname: '',
      callsign: 'X1AAAA',
      npub: 'npub1test',
      nsec: '',
      createdAt: 0,
      licenceCallsign: active,
      licenceCallsigns: held,
    );

void main() {
  late IwiProfile current;
  final stored = <String, Map<String, String>>{};
  final self = XprsSelf.instance;

  setUp(() {
    stored.clear();
    current = _profile(active: 'CT1ABC', held: ['CT1ABC', 'EA/CT1ABC']);
    self
      ..resetForTest()
      ..profile = (() => current)
      ..load = ((id) => Map.of(stored[id] ?? const {}))
      ..save = ((id, m) => stored[id] = Map.of(m));
  });

  test('every name is ours, the X1 base included', () {
    expect(self.isMine('X1AAAA'), isTrue);
    expect(self.isMine('CT1ABC'), isTrue);
    expect(self.isMine('ea/ct1abc'), isTrue);
    expect(self.isMine('CT1ABC-2'), isTrue, reason: 'a device suffix is the same callsign');
    expect(self.isMine('CT1XYZ'), isFalse);
  });

  test('a new conversation goes out under the active callsign', () {
    expect(self.forPeer('X1PEER'), 'CT1ABC');
  });

  test('a peer who wrote to EA/CT1ABC is answered as EA/CT1ABC', () {
    self.noteInbound('X1PEER', 'EA/CT1ABC');
    expect(self.forPeer('X1PEER'), 'EA/CT1ABC');
    expect(self.forPeer('X1OTHER'), 'CT1ABC', reason: 'nobody else is affected');
  });

  test('the conversation keeps its callsign when the active one changes', () {
    self.noteOutbound('X1PEER', 'EA/CT1ABC');
    current = _profile(active: 'CT1ABC', held: ['CT1ABC', 'EA/CT1ABC']);
    expect(self.forPeer('X1PEER'), 'EA/CT1ABC');
    // ...and it survives a restart: it was stored.
    expect(stored['X1AAAA'], {'X1PEER': 'EA/CT1ABC'});
  });

  test('a callsign no longer held falls back to the active one', () {
    self.noteInbound('X1PEER', 'EA/CT1ABC');
    current = _profile(active: 'CT1ABC', held: ['CT1ABC']);
    expect(self.forPeer('X1PEER'), 'CT1ABC');
  });

  test('a peer who wrote to the X1 follows whatever is active', () {
    self.noteInbound('X1PEER', 'EA/CT1ABC');
    self.noteInbound('X1PEER', 'X1AAAA');
    expect(self.forPeer('X1PEER'), 'CT1ABC');
    current = _profile(active: 'EA/CT1ABC', held: ['CT1ABC', 'EA/CT1ABC']);
    expect(self.forPeer('X1PEER'), 'EA/CT1ABC');
  });

  test('mail to somebody else teaches nothing', () {
    self.noteInbound('X1PEER', 'CT1XYZ');
    expect(stored, isEmpty);
  });

  test('the memory is bounded, least recently used first', () {
    for (var i = 0; i < XprsSelf.cap + 5; i++) {
      self.noteInbound('X1P${i.toString().padLeft(3, '0')}', 'EA/CT1ABC');
    }
    final m = stored['X1AAAA']!;
    expect(m.length, XprsSelf.cap);
    expect(m.containsKey('X1P000'), isFalse);
    expect(m.containsKey('X1P${(XprsSelf.cap + 4).toString().padLeft(3, '0')}'), isTrue);
  });

  test('each profile has its own conversations', () {
    self.noteInbound('X1PEER', 'EA/CT1ABC');
    current = IwiProfile(
        id: 'X1BBBB', nickname: '', callsign: 'X1BBBB', npub: 'npub1b',
        nsec: '', createdAt: 0);
    expect(self.forPeer('X1PEER'), 'X1BBBB');
  });

  group('the profile model', () {
    test('an old profile with one licence reads as a list of one, active', () {
      final p = IwiProfile.fromJson({
        'id': 'X1AAAA', 'callsign': 'X1AAAA', 'npub': 'npub1x',
        'licenceCallsign': 'CT1ABC',
      });
      expect(p.heldLicences, ['CT1ABC']);
      expect(p.wireCallsign, 'CT1ABC');
      expect(p.allCallsigns, ['X1AAAA', 'CT1ABC']);
    });

    test('the list round-trips, and older builds still see the active one', () {
      final p = _profile(active: 'EA/CT1ABC', held: ['CT1ABC', 'EA/CT1ABC']);
      final j = p.toJson();
      expect(j['licenceCallsign'], 'EA/CT1ABC');
      expect(j['licenceCallsigns'], ['CT1ABC', 'EA/CT1ABC']);
      final back = IwiProfile.fromJson(j);
      expect(back.heldLicences, ['CT1ABC', 'EA/CT1ABC']);
      expect(back.wireCallsign, 'EA/CT1ABC');
    });

    test('no licence: the X1 is on the air and nothing extra is written', () {
      final p = _profile();
      expect(p.wireCallsign, 'X1AAAA');
      expect(p.toJson().containsKey('licenceCallsigns'), isFalse);
    });
  });
}
