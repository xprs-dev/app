/*
 * Composing what a group signs (section 26.1-26.3). These are the packets the
 * spec writes out verbatim, so the tests check the shape against those.
 */
import 'dart:typed_data';

import 'package:xprs/services/xprs/xprs_group_act.dart';
import 'package:xprs/services/xprs/xprs_groups.dart';
import 'package:xprs/services/xprs/xprs_id.dart';
import 'package:xprs/services/xprs/xprs_sig.dart';
import 'package:xprs/util/nostr_crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hex/hex.dart';

void main() {
  final kp = NostrCrypto.generateKeyPair();
  final pub = Uint8List.fromList(HEX.decode(kp.publicKeyHex));
  final d = () {
    var v = BigInt.zero;
    for (final b in HEX.decode(NostrCrypto.decodeNsec(kp.nsec))) {
      v = (v << 8) | BigInt.from(b);
    }
    return v;
  }();
  final g = 'X5${NostrCrypto.deriveCallsign(kp.publicKeyHex)}';
  final now = DateTime.parse('2026-08-08T14:26:40Z').millisecondsSinceEpoch;

  test('a group announces itself with the ordinary t:identity', () {
    final p = XprsGroupAct.identity(
        group: g, npub: kp.npub, scalar: d, nick: 'lisboa-net', nowMs: now)!;
    expect(p.type, 'identity');
    expect(p['f'], g);
    expect(p['k'], kp.npub);
    expect(p['nick'], 'lisboa-net');
    // Self-signed is what proves possession of the group's private key (26.1).
    expect(xprsVerify(p, pub), XprsSigState.verified);
  });

  test('the callsign is derived from the key, so it verifies as its own', () {
    expect(NostrCrypto.callsignMatchesKey(g, kp.publicKeyHex), isTrue);
  });

  test('a grant carries a list, and role:mod appoints', () {
    final p = XprsGroupAct.grant(
        group: g, callsigns: ['X1RD89', 'X32DVA'], scalar: d, nowMs: now)!;
    expect(p.type, 'moderate');
    expect(p['f'], g, reason: 'the admin signs as the group');
    expect(p['d'], g);
    expect(p['grant'], 'X1RD89,X32DVA');
    expect(p.has('role'), isFalse, reason: 'no role word = ordinary member');

    final mod = XprsGroupAct.grant(
        group: g, callsigns: ['X32DVA'], scalar: d, role: 'mod', nowMs: now)!;
    expect(mod['role'], 'mod');
  });

  test('a suspension is a revocation with an end', () {
    final p = XprsGroupAct.revoke(
        group: g,
        callsigns: ['X1PZ4Q'],
        scalar: d,
        until: '2026-08-15_00:00:00',
        nowMs: now)!;
    expect(p['revoke'], 'X1PZ4Q');
    expect(p['until'], '2026-08-15_00:00:00');
  });

  test('since: voids a moderator record', () {
    final p = XprsGroupAct.revoke(
        group: g,
        callsigns: ['X32DVA'],
        scalar: d,
        since: '2026-08-01_00:00:00',
        nowMs: now)!;
    expect(p['since'], '2026-08-01_00:00:00');
  });

  test('hide names the packet, and cannot unsend it', () {
    final p = XprsGroupAct.hide(
        group: g, messageId: '89a9c8', scalar: d, nowMs: now)!;
    expect(p['r'], '89a9c8');
    expect(p['hide'], 'message');
  });

  test('a duplicate callsign is listed once; an empty list is no packet', () {
    final p = XprsGroupAct.grant(
        group: g, callsigns: ['X1RD89', 'x1rd89', ' '], scalar: d, nowMs: now)!;
    expect(p['grant'], 'X1RD89');
    expect(XprsGroupAct.grant(group: g, callsigns: [], scalar: d), isNull);
  });

  test('what it composes is what the roster then reads', () {
    // The two halves have to agree or nothing works end to end -- including
    // the consent half: a grant is an offer until the member signs (26.3.1).
    final member = NostrCrypto.generateKeyPair();
    final memberD = () {
      var v = BigInt.zero;
      for (final b in HEX.decode(NostrCrypto.decodeNsec(member.nsec))) {
        v = (v << 8) | BigInt.from(b);
      }
      return v;
    }();
    final mCall = 'X1${NostrCrypto.deriveCallsign(member.publicKeyHex)}';
    final mPub = Uint8List.fromList(HEX.decode(member.publicKeyHex));

    final m = XprsGroups.instance..clear();
    m.keyResolver = (c) => c == g ? pub : (c == mCall ? mPub : null);

    final offer =
        XprsGroupAct.grant(group: g, callsigns: [mCall], scalar: d, nowMs: now)!;
    m.offer(offer, nowMs: now);
    expect(m.rosterOf(g, nowMs: now).roles[mCall], XprsRole.invited,
        reason: 'an offer, not yet a membership');
    expect(m.mayPost(g, mCall, nowMs: now), isFalse);

    m.offer(
        XprsGroupAct.accept(
            group: g,
            member: mCall,
            grantId: xprsIdentifier(offer),
            scalar: memberD,
            // A minute later: an acceptance comes after the offer it names.
            // Sharing a ts: would leave the order to the section 26.4
            // identifier tie-break -- deterministic, but not the story here.
            nowMs: now + 60000)!,
        nowMs: now);
    expect(m.rosterOf(g, nowMs: now).roles[mCall], XprsRole.member);
    expect(m.mayPost(g, mCall, nowMs: now), isTrue);

    m.offer(
        XprsGroupAct.leave(
            group: g, member: mCall, scalar: memberD, nowMs: now + 120000)!,
        nowMs: now);
    expect(m.mayPost(g, mCall, nowMs: now), isFalse,
        reason: 'a signed record that they went');
  });
}
