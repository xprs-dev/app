/*
 * Section 26.4 replay. These rules exist "so that two implementations reach
 * the same answer from the same packets", so they are worth testing as rules
 * rather than as whatever the code happens to do.
 */
import 'dart:typed_data';

import 'package:xprs/services/xprs/xprs_groups.dart';
import 'package:xprs/services/xprs/xprs_packet.dart';
import 'package:xprs/services/xprs/xprs_sig.dart';
import 'package:xprs/util/nostr_crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hex/hex.dart';

const g = 'X5A3F2';
int _ts(String s) => DateTime.parse('${s}Z').millisecondsSinceEpoch;

BigInt _scalar(String privHex) {
  var d = BigInt.zero;
  for (final b in HEX.decode(privHex)) {
    d = (d << 8) | BigInt.from(b);
  }
  return d;
}

/// Every signer gets a real keypair, so the tests exercise verification too --
/// section 26 rests entirely on signatures and a roster that moved on an
/// unverified act would be worthless.
final _keys = <String, ({BigInt d, Uint8List pub})>{};
({BigInt d, Uint8List pub}) _keyFor(String callsign) =>
    _keys.putIfAbsent(callsign, () {
      final kp = NostrCrypto.generateKeyPair();
      return (
        d: _scalar(kp.privateKeyHex),
        pub: Uint8List.fromList(HEX.decode(kp.publicKeyHex))
      );
    });

/// A `t:moderate` as section 26.3 writes them, signed by its `f:`.
XprsPacket _act(String signer, String when, String rest) => xprsSign(
      XprsPacket.parse('t:moderate f:$signer d:$g ts:$when $rest')!,
      _keyFor(signer).d,
    );

void main() {
  late XprsGroups m;
  final now = _ts('2026-08-20T00:00:00');

  setUp(() {
    m = XprsGroups.instance;
    m.clear();
    m.keyResolver = (call) => _keys[call]?.pub;
  });

  group('membership', () {
    test('the admin grants; a member may post', () {
      m.offer(_act(g, '2026-08-08_10:00:00', 'grant:X1RD89,X32DVA'),
          nowMs: now);
      final r = m.rosterOf(g, nowMs: now);
      expect(r.roles['X1RD89'], XprsRole.member);
      expect(r.roles['X32DVA'], XprsRole.member);
      expect(m.mayPost(g, 'X1RD89', nowMs: now), isTrue);
      expect(m.mayPost(g, 'X1PZ4Q', nowMs: now), isFalse);
    });

    test('the group itself is the admin', () {
      m.offer(_act(g, '2026-08-08_10:00:00', 'grant:X1RD89'), nowMs: now);
      expect(m.rosterOf(g, nowMs: now).roles[g], XprsRole.admin);
    });

    test('revoke removes', () {
      m.offer(_act(g, '2026-08-08_10:00:00', 'grant:X1PZ4Q'), nowMs: now);
      m.offer(_act(g, '2026-08-09_10:00:00', 'revoke:X1PZ4Q'), nowMs: now);
      expect(m.mayPost(g, 'X1PZ4Q', nowMs: now), isFalse);
    });
  });

  group('two tiers — only the admin may appoint', () {
    test('a moderator may revoke', () {
      m.offer(_act(g, '2026-08-08_10:00:00', 'grant:X32DVA role:mod'),
          nowMs: now);
      m.offer(_act(g, '2026-08-08_11:00:00', 'grant:X1PZ4Q'), nowMs: now);
      m.offer(_act('X32DVA', '2026-08-09_10:00:00', 'revoke:X1PZ4Q'),
          nowMs: now);
      expect(m.mayPost(g, 'X1PZ4Q', nowMs: now), isFalse);
    });

    test('a moderator may NOT appoint', () {
      m.offer(_act(g, '2026-08-08_10:00:00', 'grant:X32DVA role:mod'),
          nowMs: now);
      m.offer(_act('X32DVA', '2026-08-09_10:00:00', 'grant:X1PZ4Q'),
          nowMs: now);
      expect(m.mayPost(g, 'X1PZ4Q', nowMs: now), isFalse,
          reason: 'two tiers is the whole hierarchy (26.3)');
    });

    test('a stranger may do nothing', () {
      m.offer(_act(g, '2026-08-08_10:00:00', 'grant:X1RD89'), nowMs: now);
      m.offer(_act('X1NOPE', '2026-08-09_10:00:00', 'revoke:X1RD89'),
          nowMs: now);
      expect(m.mayPost(g, 'X1RD89', nowMs: now), isTrue);
    });
  });

  group('a suspension is a revocation with an end', () {
    test('in force before its moment, lapsed after', () {
      m.offer(_act(g, '2026-08-08_10:00:00', 'grant:X1PZ4Q'), nowMs: now);
      m.offer(
          _act(g, '2026-08-09_10:00:00',
              'revoke:X1PZ4Q until:2026-08-15_00:00:00'),
          nowMs: now);
      expect(m.mayPost(g, 'X1PZ4Q', nowMs: _ts('2026-08-10T00:00:00')), isFalse);
      expect(m.mayPost(g, 'X1PZ4Q', nowMs: _ts('2026-08-16T00:00:00')), isTrue,
          reason: 'removes them until that moment and no longer');
    });

    test('an until: more than a year past its ts is discarded', () {
      m.offer(_act(g, '2026-08-08_10:00:00', 'grant:X1PZ4Q'), nowMs: now);
      m.offer(
          _act(g, '2026-08-09_10:00:00',
              'revoke:X1PZ4Q until:2030-01-01_00:00:00'),
          nowMs: now);
      expect(m.mayPost(g, 'X1PZ4Q', nowMs: now), isFalse,
          reason: 'the until: is dropped, so it is a plain revocation');
    });
  });

  group('reading the log', () {
    test('a ts far in the future is discarded', () {
      expect(m.offer(_act(g, '2030-01-01_00:00:00', 'grant:X1RD89'), nowMs: now),
          isFalse);
      expect(m.mayPost(g, 'X1RD89', nowMs: now), isFalse);
    });

    test('authority is judged at the moment of the act', () {
      // The moderator acts, and is only removed afterwards. The act stands.
      m.offer(_act(g, '2026-08-01_10:00:00', 'grant:X32DVA role:mod'),
          nowMs: now);
      m.offer(_act(g, '2026-08-01_11:00:00', 'grant:X1PZ4Q'), nowMs: now);
      m.offer(_act('X32DVA', '2026-08-02_10:00:00', 'revoke:X1PZ4Q'),
          nowMs: now);
      m.offer(_act(g, '2026-08-03_10:00:00', 'revoke:X32DVA'), nowMs: now);
      expect(m.mayPost(g, 'X1PZ4Q', nowMs: now), isFalse,
          reason: 'removing a moderator must not undo their legitimate work');
    });

    test('the admin can void a moderator record with since:', () {
      m.offer(_act(g, '2026-08-01_10:00:00', 'grant:X32DVA role:mod'),
          nowMs: now);
      m.offer(_act(g, '2026-08-01_11:00:00', 'grant:X1PZ4Q'), nowMs: now);
      m.offer(_act('X32DVA', '2026-08-02_10:00:00', 'revoke:X1PZ4Q'),
          nowMs: now);
      m.offer(
          _act(g, '2026-08-03_10:00:00',
              'revoke:X32DVA since:2026-08-02_00:00:00'),
          nowMs: now);
      expect(m.mayPost(g, 'X1PZ4Q', nowMs: now), isTrue,
          reason: 'the compromised moderator\'s acts go with them');
    });

    test('order of arrival does not change the answer', () {
      // Same packets, reversed. The replay sorts, so the result must match.
      final wires = [
        _act(g, '2026-08-01_10:00:00', 'grant:X1RD89'),
        _act(g, '2026-08-02_10:00:00', 'revoke:X1RD89'),
        _act(g, '2026-08-03_10:00:00', 'grant:X1RD89'),
      ];
      for (final w in wires) {
        m.offer(w, nowMs: now);
      }
      final forward = m.mayPost(g, 'X1RD89', nowMs: now);
      m.clear();
      for (final w in wires.reversed) {
        m.offer(w, nowMs: now);
      }
      expect(m.mayPost(g, 'X1RD89', nowMs: now), forward);
      expect(forward, isTrue);
    });

    test('a repeated act is heard once', () {
      final a = _act(g, '2026-08-08_10:00:00', 'grant:X1RD89');
      m.offer(a, nowMs: now);
      m.offer(a, nowMs: now);
      expect(m.groupJson(g)['acts'], 1);
    });
  });

  group('what a client shows', () {
    test('hide:message collects the identifier', () {
      m.offer(_act(g, '2026-08-08_10:00:00', 'grant:X32DVA role:mod'),
          nowMs: now);
      m.offer(_act('X32DVA', '2026-08-09_10:00:00', 'r:89a9c8 hide:message'),
          nowMs: now);
      expect(m.rosterOf(g, nowMs: now).hidden, contains('89a9c8'));
    });

    test('without the key it fails OPEN and says so', () {
      m.offer(_act(g, '2026-08-08_10:00:00', 'grant:X1RD89'), nowMs: now);
      final r = m.rosterOf(g, nowMs: now, haveKey: false);
      expect(r.verified, isFalse);
      expect(m.mayPost(g, 'X1PZ4Q', nowMs: now, haveKey: false), isTrue,
          reason: 'must look broken rather than empty (26.7)');
    });
  });

  group('an act that does not verify moves nothing', () {
    test('a forged grant is refused', () {
      // Signed by somebody else, wearing the group's callsign in f:.
      final impostor = xprsSign(
          XprsPacket.parse(
              't:moderate f:$g d:$g ts:2026-08-08_10:00:00 grant:X1PZ4Q')!,
          _keyFor('X1NOPE').d);
      expect(m.offer(impostor, nowMs: now), isFalse);
      expect(m.mayPost(g, 'X1PZ4Q', nowMs: now), isFalse);
    });

    test('a key we do not hold yet is counted, not trusted', () {
      m.keyResolver = (_) => null; // nothing learned yet
      expect(m.offer(_act(g, '2026-08-08_10:00:00', 'grant:X1RD89'), nowMs: now),
          isFalse);
      expect(m.statusJson()['unverified'], 1);
      expect(m.statusJson()['rejected'], 0,
          reason: 'a missing key is a bootstrap state, not a lie');
    });
  });

  test('role:sub lists a subgroup and confers nothing', () {
    m.offer(_act(g, '2026-08-08_10:00:00', 'grant:X5K2M9 role:sub'),
        nowMs: now);
    final r = m.rosterOf(g, nowMs: now);
    expect(r.roles['X5K2M9'], XprsRole.sub);
    expect(m.mayPost(g, 'X5K2M9', nowMs: now), isFalse,
        reason: 'listing confers no authority (26.2)');
  });
}
