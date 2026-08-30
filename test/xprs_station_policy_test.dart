// Section 25.9 — owning a station, and what the owner sets.
//
// Pure Dart: no radio, no store. What is tested is the decision layer — which
// claim a station accepts, which policy command earns which code, and the ONE
// send order every station that queues for others must use.

import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/services/xprs/xprs_packet.dart';
import 'package:xprs/services/xprs/xprs_station_policy.dart';

const _ts = '2026-08-08_14:26:50';
const _later = '2026-08-08_14:30:00';

XprsPacket _p(String w) => XprsPacket.parse(w)!;

void main() {
  group('wires fit and parse', () {
    test('claim ask, claim, policy set, policy ask, policy report', () {
      final wires = [
        xprsClaimAskWire('X3RLY7', ts: _ts),
        xprsClaimWire('X1QZ3N', 'X3RLY7', ts: _ts),
        xprsPolicySetWire('X1QZ3N', 'X3RLY7',
            use: 'listed',
            first: ['X1ABCD', 'X1EFGH'],
            serve: ['relay', 'archive'],
            ts: _ts),
        xprsPolicyAskWire('X1MB7K', 'X3RLY7', ts: _ts),
        xprsPolicyReportWire(
            'X3RLY7',
            'X1MB7K',
            const XprsStationPolicy(
                owners: ['X1QZ3N'],
                use: 'listed',
                first: ['X1ABCD'],
                serve: ['relay']),
            ts: _ts),
      ];
      for (final w in wires) {
        expect(w, isNotNull);
        final p = XprsPacket.parse(w!);
        expect(p, isNotNull);
        expect(p!.fits, isTrue, reason: w);
      }
      expect(wires[0], 't:request f:X3RLY7 q:owner scope:local ts:$_ts');
      expect(wires[1],
          't:command f:X1QZ3N d:X3RLY7 ts:$_ts cmd:set owner:X1QZ3N');
      expect(wires[3], 't:request f:X1MB7K d:X3RLY7 ts:$_ts q:policy');
    });

    test('a full first: list that would not fit is refused, not truncated', () {
      final many = List.generate(30, (i) => 'X1AB${i.toString().padLeft(2, '0')}');
      expect(xprsPolicySetWire('X1QZ3N', 'X3RLY7', first: many), isNull);
    });
  });

  group('policy round trip', () {
    test('report → fromPacket → toKeys is stable', () {
      const p = XprsStationPolicy(
          owners: ['X1QZ3N'],
          use: 'listed',
          first: ['X1ABCD', 'X1EFGH'],
          serve: ['relay', 'archive']);
      final w = xprsPolicyReportWire('X3RLY7', 'X1MB7K', p, ts: _ts)!;
      final back = XprsStationPolicy.fromPacket(_p(w));
      expect(back.toKeys(), p.toKeys());
      expect(back.owners, ['X1QZ3N']);
      expect(back.use, 'listed');
      expect(back.first, ['X1ABCD', 'X1EFGH']);
      expect(back.serve, ['relay', 'archive']);
    });

    test('serve:none is nothing; an unknown serve word is dropped', () {
      final a = XprsStationPolicy.fromPacket(
          _p('t:command f:X1A d:X3B ts:$_ts cmd:set serve:none'));
      expect(a.serve, isEmpty);
      expect(a.toKeys(), contains('serve:none'));
      final b = XprsStationPolicy.fromPacket(
          _p('t:command f:X1A d:X3B ts:$_ts cmd:set serve:relay,disco'));
      expect(b.serve, ['relay']);
    });

    test('absent key is unchanged on merge; unknown use: is ignored', () {
      const base = XprsStationPolicy(
          owners: ['X1QZ3N'], use: 'owners', first: ['X1ABCD']);
      final m = base.merge(
          _p('t:command f:X1QZ3N d:X3RLY7 ts:$_later cmd:set serve:relay'));
      expect(m.owners, ['X1QZ3N']);
      expect(m.use, 'owners');
      expect(m.first, ['X1ABCD']);
      expect(m.serve, ['relay']);
      expect(m.ts, _later);
      final u = base.merge(
          _p('t:command f:X1QZ3N d:X3RLY7 ts:$_later cmd:set use:disco'));
      expect(u.use, 'owners');
    });

    test('owner: caps at four and deduplicates', () {
      final p = XprsStationPolicy.fromPacket(_p(
          't:command f:X1A d:X3B ts:$_ts cmd:set owner:X1A,X1B,X1A,X1C,X1D,X1E'));
      expect(p.owners, ['X1A', 'X1B', 'X1C', 'X1D']);
    });

    test('use: gates the bridge', () {
      const p = XprsStationPolicy(
          owners: ['X1OWN'], use: 'listed', first: ['X1VIP']);
      expect(p.mayUse('X1OWN'), isTrue);
      expect(p.mayUse('X1VIP'), isTrue);
      expect(p.mayUse('X1STR'), isFalse);
      expect(const XprsStationPolicy(use: 'all').mayUse('X1STR'), isTrue);
      expect(const XprsStationPolicy(owners: ['X1OWN'], use: 'owners')
          .mayUse('X1VIP'), isFalse);
      expect(const XprsStationPolicy(use: 'none').mayUse('X1OWN'), isFalse);
    });
  });

  group('claiming', () {
    final claim = _p(xprsClaimWire('X1QZ3N', 'X3RLY7', ts: _ts)!);

    test('unowned + uncarried + names the signer: accepted', () {
      expect(
          xprsClaimCode(claim,
              policy: const XprsStationPolicy(), verified: true),
          200);
    });

    test('unverified is never acted on', () {
      expect(
          xprsClaimCode(claim,
              policy: const XprsStationPolicy(), verified: false),
          403);
    });

    test('carried (via:) is refused even when unowned', () {
      final carried = _p('${claim.encode()} via:X3FAR');
      expect(
          xprsClaimCode(carried,
              policy: const XprsStationPolicy(), verified: true),
          403);
    });

    test('a claim naming somebody else is refused', () {
      final other = _p(
          't:command f:X1EVIL d:X3RLY7 ts:$_ts cmd:set owner:X1QZ3N');
      expect(
          xprsClaimCode(other,
              policy: const XprsStationPolicy(), verified: true),
          403);
    });

    test('once owned, a non-owner cannot claim; an owner can transfer', () {
      const owned = XprsStationPolicy(owners: ['X1QZ3N'], ts: _ts);
      final stranger = _p(
          't:command f:X1EVIL d:X3RLY7 ts:$_later cmd:set owner:X1EVIL');
      expect(xprsClaimCode(stranger, policy: owned, verified: true), 403);
      final transfer = _p(
          't:command f:X1QZ3N d:X3RLY7 ts:$_later cmd:set owner:X1NEW');
      expect(xprsClaimCode(transfer, policy: owned, verified: true), 200);
      expect(owned.merge(transfer).owners, ['X1NEW']);
    });
  });

  group('policy command codes', () {
    const owned = XprsStationPolicy(owners: ['X1QZ3N'], ts: _ts);

    test('owner sets use: → 200; stranger → 403', () {
      final ok = _p('t:command f:X1QZ3N d:X3RLY7 ts:$_later cmd:set use:owners');
      expect(xprsPolicyCode(ok, policy: owned, verified: true), 200);
      final no = _p('t:command f:X1STR d:X3RLY7 ts:$_later cmd:set use:all');
      expect(xprsPolicyCode(no, policy: owned, verified: true), 403);
    });

    test('a plain cmd:set state:on is not a policy command', () {
      final s = _p('t:command f:X1QZ3N d:X3RLY7 ts:$_later cmd:set state:on');
      expect(xprsIsPolicyCommand(s), isFalse);
      expect(xprsPolicyCode(s, policy: owned, verified: true), 400);
    });

    test('replay: ts not later than the last accepted is 408', () {
      expect(xprsPolicyReplayCode(_ts, _ts), 408);
      expect(xprsPolicyReplayCode(_later, _ts), 408);
      expect(xprsPolicyReplayCode(_ts, _later), isNull);
      expect(xprsPolicyReplayCode(null, _ts), isNull);
      expect(xprsPolicyReplayCode(_ts, null), 408);
      final old = _p('t:command f:X1QZ3N d:X3RLY7 ts:$_ts cmd:set use:all');
      expect(xprsPolicyCode(old, policy: owned, verified: true), 408);
    });
  });

  group('send order (section 25.9, fixed)', () {
    const p = XprsStationPolicy(owners: ['X1OWN'], first: ['X1VIP']);
    final sos = _p('t:sos f:X1STR ts:2026-08-08_14:29:00 m:help');
    final vipLow = _p(
        't:message f:X1VIP d:X1X ts:2026-08-08_14:28:00 urg:low m:hi');
    final strUrgent = _p(
        't:message f:X1STR d:X1X ts:2026-08-08_14:20:00 urg:urgent m:now');
    final strHigh = _p(
        't:message f:X1STR d:X1X ts:2026-08-08_14:21:00 urg:high m:soon');
    final ownUrgent = _p(
        't:message f:X1OWN d:X1X ts:2026-08-08_14:27:00 urg:urgent m:mine');
    final strOld = _p('t:message f:X1STR d:X1X ts:2026-08-08_14:00:00 m:a');
    final strNew = _p('t:message f:X1STR d:X1X ts:2026-08-08_14:10:00 m:b');

    test('sos beats first beats urgency beats age', () {
      final q = [strNew, strOld, ownUrgent, strHigh, strUrgent, vipLow, sos]
        ..sort((a, b) => xprsSendOrder(a, b, p));
      expect(q, [sos, vipLow, ownUrgent, strUrgent, strHigh, strOld, strNew]);
    });

    test('a stranger\'s urgent counts as high: older high goes first', () {
      // strUrgent is capped to high; strHigh is high; strUrgent is older.
      expect(xprsSendOrder(strUrgent, strHigh, p) < 0, isTrue);
      final strHighOlder = _p(
          't:message f:X1STR d:X1X ts:2026-08-08_14:19:00 urg:high m:x');
      expect(xprsSendOrder(strHighOlder, strUrgent, p) < 0, isTrue);
    });

    test('an owner is not implicitly first', () {
      expect(xprsSendOrder(vipLow, ownUrgent, p) < 0, isTrue);
    });
  });

  group('unowned stations heard', () {
    test('records X3 asks only, most recent kept', () {
      final r = XprsUnownedStations.instance..clear();
      expect(r.note(_p('t:request f:X1QZ3N q:owner scope:local ts:$_ts')),
          isFalse);
      expect(r.note(_p('t:request f:X3RLY7 q:owner scope:local ts:$_ts')),
          isTrue);
      expect(r.note(_p('t:request f:X3RLY7 q:owner scope:local ts:$_later')),
          isTrue);
      expect(r.heard, {'X3RLY7': _later});
      r.forget('X3RLY7');
      expect(r.heard, isEmpty);
    });
  });
}
