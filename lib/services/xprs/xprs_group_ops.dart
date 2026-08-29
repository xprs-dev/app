/*
 * xprs_group_ops.dart — doing something about a closed group (XPRS 26.3).
 *
 * Composing an act, moving our OWN roster with it, and putting it on a bearer
 * are three steps that must happen together and in that order, and getting the
 * order wrong is not visible in a screenshot: skip the middle one and the admin
 * is the last station in the world to know what it just decided, because a
 * station never hears its own packet back through the funnel.
 *
 * So they live here once, and both callers — the settings page a person taps
 * and the HTTP API a test drives — go through the same door. `XprsGroupAct`
 * stays pure (it composes and signs, nothing else) and `XprsGroups` stays a
 * replay of packets, so neither of them needs to know a publisher exists.
 */
import 'dart:async';

import '../../util/nostr_crypto.dart';
import '../reticulum/rns_service.dart';
import 'xprs_group_act.dart';
import 'xprs_group_keys.dart';
import 'xprs_groups.dart';
import 'xprs_packet.dart';
import 'xprs_publisher.dart';
import 'xprs_sig.dart';

/// What an attempt did. A refusal is never silent: every caller shows the
/// reason, because "nothing happened" is the failure mode section 26 is
/// hardest to debug through.
class XprsGroupOpResult {
  const XprsGroupOpResult.ok(this.wire) : error = null;
  const XprsGroupOpResult.failed(this.error) : wire = null;

  final String? wire;
  final String? error;
  bool get ok => error == null;
}

class XprsGroupOps {
  XprsGroupOps._();

  /// Mint a group and announce it (26.1). The callsign derives from the key,
  /// so there is nothing to choose and nothing to collide with.
  static ({String callsign, String npub, String nick})? create(
      {String nick = ''}) {
    if (!XprsGroupKeys.instance.ready) return null;
    final g = XprsGroupKeys.instance.create(nick: nick);
    if (g == null) return null;
    // Teach our own callsign→key map the group before we sign anything with
    // it: a station does not hear itself, so without this the admin could not
    // verify its own acts and its roster would stay empty.
    try {
      RnsService.instance
          .recordCallsignPubkey(g.callsign, NostrCrypto.decodeNpub(g.npub));
    } catch (_) {
      // A malformed npub cannot happen for a key we just generated, and if it
      // somehow did the group is still minted — it just stays unverifiable.
    }
    final scalar = XprsGroupKeys.instance.scalarFor(g.callsign);
    if (scalar != null) {
      final ann = XprsGroupAct.identity(
          group: g.callsign, npub: g.npub, scalar: scalar, nick: g.nick);
      // verbatim: signed by the GROUP, and publishWire signs only for our own
      // callsign.
      if (ann != null) unawaited(_air(ann));
    }
    return (callsign: g.callsign, npub: g.npub, nick: g.nick);
  }

  /// The group speaking about somebody (26.3): grant, or revoke. Signed with
  /// the group key, which only the admin holds.
  static XprsGroupOpResult grant(String group, List<String> calls,
          {String role = '', String until = ''}) =>
      _adminAct(group,
          (scalar) => XprsGroupAct.grant(
              group: group,
              callsigns: calls,
              scalar: scalar,
              role: role,
              until: until));

  static XprsGroupOpResult revoke(String group, List<String> calls,
          {String until = '', String since = ''}) =>
      _adminAct(group,
          (scalar) => XprsGroupAct.revoke(
              group: group,
              callsigns: calls,
              scalar: scalar,
              until: until,
              since: since));

  /// The member's own half (26.3.1), signed with the PROFILE key — the person
  /// speaking for themselves, not the group speaking about them.
  ///
  /// [grantId] is the section 5 identifier of the offer being accepted. It is
  /// required: consent that names no particular grant is consent to nothing.
  static XprsGroupOpResult accept(String group, String me, String grantId,
      {String role = 'member'}) {
    if (grantId.isEmpty) {
      return const XprsGroupOpResult.failed('no offer to accept');
    }
    return _selfAct(
        (scalar) => XprsGroupAct.accept(
            group: group,
            member: me,
            grantId: grantId,
            scalar: scalar,
            role: role));
  }

  static XprsGroupOpResult leave(String group, String me) => _selfAct(
      (scalar) => XprsGroupAct.leave(group: group, member: me, scalar: scalar));

  static XprsGroupOpResult _adminAct(
      String group, XprsPacket? Function(BigInt scalar) compose) {
    final scalar = XprsGroupKeys.instance.scalarFor(group);
    if (scalar == null) {
      // 26.3: a moderator's revoke is signed by THEM, which this does not yet
      // compose. Say which of the two it is rather than "failed".
      return XprsGroupOpResult.failed('only the admin of $group can do that');
    }
    return _finish(compose(scalar));
  }

  static XprsGroupOpResult _selfAct(
      XprsPacket? Function(BigInt scalar) compose) {
    final d = xprsProfileScalar();
    if (d == null) return const XprsGroupOpResult.failed('no profile open');
    return _finish(compose(d));
  }

  static XprsGroupOpResult _finish(XprsPacket? p) {
    if (p == null) {
      return const XprsGroupOpResult.failed('the act did not compose or fit');
    }
    // Our own roster moves NOW. Waiting for the funnel would mean waiting for
    // a packet that is never coming back.
    XprsGroups.instance.offer(p);
    unawaited(_air(p));
    return XprsGroupOpResult.ok(p.encode());
  }

  static Future<void> _air(XprsPacket p) =>
      XprsPublisher.instance.publishWire(p.encode(), verbatim: true);
}
